//! zrealpath - Print the resolved path
//!
//! Compatible with GNU realpath:
//! - Print the resolved absolute file name
//! - -e, --canonicalize-existing: all components must exist
//! - -m, --canonicalize-missing: no path components need exist
//! - -s, --strip, --no-symlinks: don't expand symlinks
//! - -z, --zero: end each output line with NUL, not newline
//! - --relative-to=DIR: print path relative to DIR
//! - --relative-base=DIR: print absolute paths unless paths below DIR

const std = @import("std");
const libc = std.c;

extern "c" fn realpath(path: [*:0]const u8, resolved: ?[*]u8) ?[*:0]u8;

fn writeStdout(data: []const u8) void {
    _ = libc.write(libc.STDOUT_FILENO, data.ptr, data.len);
}

fn writeStderr(data: []const u8) void {
    _ = libc.write(libc.STDERR_FILENO, data.ptr, data.len);
}

const Config = struct {
    canonicalize_existing: bool = true, // default: all must exist
    canonicalize_missing: bool = false,
    no_symlinks: bool = false,
    zero: bool = false,
    relative_to: ?[]const u8 = null,
    relative_base: ?[]const u8 = null,
    paths: std.ArrayListUnmanaged([]const u8) = .empty,

    fn deinit(self: *Config, allocator: std.mem.Allocator) void {
        for (self.paths.items) |item| {
            allocator.free(item);
        }
        self.paths.deinit(allocator);
        if (self.relative_to) |r| allocator.free(r);
        if (self.relative_base) |r| allocator.free(r);
    }
};

fn resolvePath(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);

    var resolved: [4096]u8 = undefined;
    const result = realpath(path_z.ptr, &resolved);

    if (result == null) {
        return error.RealpathFailed;
    }

    const len = std.mem.indexOfScalar(u8, &resolved, 0) orelse resolved.len;
    return try allocator.dupe(u8, resolved[0..len]);
}

fn makeRelative(allocator: std.mem.Allocator, path: []const u8, base: []const u8) ![]u8 {
    // Find the last common directory component
    var common_end: usize = 0;
    const min_len = @min(path.len, base.len);

    var i: usize = 0;
    while (i < min_len and path[i] == base[i]) : (i += 1) {
        if (path[i] == '/') {
            common_end = i;
        }
    }

    // Check if one path is a prefix of the other at a directory boundary
    if (i == min_len) {
        if (path.len == base.len) {
            // Same path
            return try allocator.dupe(u8, ".");
        } else if (i < path.len and path[i] == '/') {
            common_end = i;
        } else if (i < base.len and base[i] == '/') {
            common_end = i;
        }
    }

    // Count directories to go up from base (after common prefix)
    var up_count: usize = 0;
    var j = common_end + 1;
    while (j < base.len) : (j += 1) {
        if (base[j] == '/') {
            up_count += 1;
        }
    }
    // Count the final component if base doesn't end with /
    if (common_end + 1 < base.len) {
        up_count += 1;
    }

    // Build relative path
    var result: std.ArrayListUnmanaged(u8) = .empty;
    errdefer result.deinit(allocator);

    // Add "../" for each level up
    for (0..up_count) |_| {
        try result.appendSlice(allocator, "../");
    }

    // Add remaining path after common prefix
    if (common_end + 1 < path.len) {
        try result.appendSlice(allocator, path[common_end + 1 ..]);
    }

    // Handle empty result (same directory)
    if (result.items.len == 0) {
        try result.append(allocator, '.');
    }

    // Remove trailing slash if present (except for single ".")
    if (result.items.len > 1 and result.items[result.items.len - 1] == '/') {
        _ = result.pop();
    }

    return result.toOwnedSlice(allocator);
}

fn parseArgs(allocator: std.mem.Allocator, minimal_args: anytype) !Config {
    // Collect args into a slice
    var args_list: std.ArrayListUnmanaged([]const u8) = .empty;
    defer args_list.deinit(allocator);
    var args_iter = std.process.Args.Iterator.init(minimal_args);
    while (args_iter.next()) |arg| {
        try args_list.append(allocator, arg);
    }
    const args = args_list.items;

    var config = Config{};
    var i: usize = 1;

    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (arg.len > 0 and arg[0] == '-' and arg.len > 1) {
            if (arg[1] == '-') {
                if (std.mem.eql(u8, arg, "--help")) {
                    printHelp();
                    std.process.exit(0);
                } else if (std.mem.eql(u8, arg, "--version")) {
                    printVersion();
                    std.process.exit(0);
                } else if (std.mem.eql(u8, arg, "--canonicalize-existing")) {
                    config.canonicalize_existing = true;
                    config.canonicalize_missing = false;
                } else if (std.mem.eql(u8, arg, "--canonicalize-missing")) {
                    config.canonicalize_missing = true;
                    config.canonicalize_existing = false;
                } else if (std.mem.eql(u8, arg, "--no-symlinks") or std.mem.eql(u8, arg, "--strip")) {
                    config.no_symlinks = true;
                } else if (std.mem.eql(u8, arg, "--zero")) {
                    config.zero = true;
                } else if (std.mem.startsWith(u8, arg, "--relative-to=")) {
                    config.relative_to = try allocator.dupe(u8, arg[14..]);
                } else if (std.mem.eql(u8, arg, "--relative-to")) {
                    i += 1;
                    if (i >= args.len) {
                        writeStderr("zrealpath: option '--relative-to' requires an argument\n");
                        std.process.exit(1);
                    }
                    config.relative_to = try allocator.dupe(u8, args[i]);
                } else if (std.mem.startsWith(u8, arg, "--relative-base=")) {
                    config.relative_base = try allocator.dupe(u8, arg[16..]);
                } else if (std.mem.eql(u8, arg, "--relative-base")) {
                    i += 1;
                    if (i >= args.len) {
                        writeStderr("zrealpath: option '--relative-base' requires an argument\n");
                        std.process.exit(1);
                    }
                    config.relative_base = try allocator.dupe(u8, args[i]);
                } else {
                    writeStderr("zrealpath: unrecognized option '");
                    writeStderr(arg);
                    writeStderr("'\n");
                    std.process.exit(1);
                }
            } else {
                for (arg[1..]) |ch| {
                    switch (ch) {
                        'e' => {
                            config.canonicalize_existing = true;
                            config.canonicalize_missing = false;
                        },
                        'm' => {
                            config.canonicalize_missing = true;
                            config.canonicalize_existing = false;
                        },
                        's' => config.no_symlinks = true,
                        'z' => config.zero = true,
                        else => {
                            writeStderr("zrealpath: invalid option -- '");
                            var char_buf: [1]u8 = .{ch};
                            writeStderr(&char_buf);
                            writeStderr("'\n");
                            std.process.exit(1);
                        },
                    }
                }
            }
        } else {
            try config.paths.append(allocator, try allocator.dupe(u8, arg));
        }
    }

    if (config.paths.items.len == 0) {
        writeStderr("zrealpath: missing operand\n");
        writeStderr("Try 'zrealpath --help' for more information.\n");
        std.process.exit(1);
    }

    return config;
}

fn printHelp() void {
    const usage =
        \\Usage: zrealpath [OPTION]... FILE...
        \\Print the resolved absolute file name.
        \\
        \\  -e, --canonicalize-existing  all components must exist
        \\  -m, --canonicalize-missing   no path components need exist
        \\  -s, --strip, --no-symlinks   don't expand symlinks
        \\  -z, --zero                   end each output line with NUL
        \\      --relative-to=DIR        print path relative to DIR
        \\      --relative-base=DIR      print absolute unless below DIR
        \\      --help                   display this help and exit
        \\      --version                output version information and exit
        \\
        \\zrealpath - High-performance realpath utility in Zig
        \\
    ;
    writeStdout(usage);
}

fn printVersion() void {
    writeStdout("zrealpath 0.1.0\n");
}

pub fn main(init: std.process.Init) void {
    const allocator = init.gpa;

    var config = parseArgs(allocator, init.minimal.args) catch {
        writeStderr("zrealpath: failed to parse arguments\n");
        std.process.exit(1);
    };
    defer config.deinit(allocator);

    const terminator: []const u8 = if (config.zero) "\x00" else "\n";
    var error_occurred = false;

    // Resolve relative_to base path if specified
    var resolved_base: ?[]u8 = null;
    if (config.relative_to) |rel_to| {
        resolved_base = resolvePath(allocator, rel_to) catch null;
    }
    defer {
        if (resolved_base) |rb| allocator.free(rb);
    }

    for (config.paths.items) |path| {
        const resolved = resolvePath(allocator, path) catch {
            writeStderr("zrealpath: ");
            writeStderr(path);
            writeStderr(": No such file or directory\n");
            error_occurred = true;
            continue;
        };
        defer allocator.free(resolved);

        // Make relative if --relative-to was specified
        if (resolved_base) |base| {
            const relative = makeRelative(allocator, resolved, base) catch {
                writeStdout(resolved);
                writeStdout(terminator);
                continue;
            };
            defer allocator.free(relative);
            writeStdout(relative);
        } else {
            writeStdout(resolved);
        }
        writeStdout(terminator);
    }

    if (error_occurred) {
        std.process.exit(1);
    }
}
