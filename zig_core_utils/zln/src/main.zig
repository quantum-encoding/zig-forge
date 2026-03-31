//! zln - Make links between files
//!
//! Compatible with GNU ln:
//! - Create hard links (default)
//! - -s, --symbolic: create symbolic links
//! - -f, --force: remove existing destination files
//! - -n, --no-dereference: treat LINK_NAME as normal file if it's a symlink
//! - -v, --verbose: print name of each linked file
//! - -t, --target-directory=DIR: specify the DIRECTORY in which to create the links

const std = @import("std");
const builtin = @import("builtin");
const libc = std.c;
const Io = std.Io;

// Cross-platform Stat structure
const Stat = switch (builtin.os.tag) {
    .linux => extern struct {
        dev: u64, ino: u64, nlink: u64, mode: u32, uid: u32, gid: u32,
        __pad0: u32 = 0, rdev: u64, size: i64, blksize: i64, blocks: i64,
        atim: libc.timespec, mtim: libc.timespec, ctim: libc.timespec,
        __unused: [3]i64 = .{ 0, 0, 0 },
    },
    .macos, .ios, .tvos, .watchos => extern struct {
        dev: i32, mode: u16, nlink: u16, ino: u64, uid: u32, gid: u32, rdev: i32,
        atim: libc.timespec, mtim: libc.timespec, ctim: libc.timespec, birthtim: libc.timespec,
        size: i64, blocks: i64, blksize: i32, flags: u32, gen: u32, lspare: i32, qspare: [2]i64,
    },
    else => libc.Stat,
};

extern "c" fn access(path: [*:0]const u8, mode: c_int) c_int;
extern "c" fn unlink(path: [*:0]const u8) c_int;
extern "c" fn stat(path: [*:0]const u8, buf: *Stat) c_int;

const Config = struct {
    symbolic: bool = false,
    force: bool = false,
    interactive: bool = false,
    no_dereference: bool = false,
    no_target_directory: bool = false,
    relative: bool = false,
    verbose: bool = false,
    target_directory: ?[]const u8 = null,
    sources: std.ArrayListUnmanaged([]const u8) = .empty,
    destination: ?[]const u8 = null,

    fn deinit(self: *Config, allocator: std.mem.Allocator) void {
        for (self.sources.items) |item| {
            allocator.free(item);
        }
        self.sources.deinit(allocator);
        if (self.destination) |d| allocator.free(d);
        if (self.target_directory) |t| allocator.free(t);
    }
};

fn fileExists(path: [:0]const u8) bool {
    return access(path.ptr, 0) == 0;
}

fn isDirectory(path: [:0]const u8) bool {
    var stat_buf: Stat = undefined;
    const result = stat(path.ptr, &stat_buf);
    if (result != 0) return false;
    return (stat_buf.mode & 0o170000) == 0o40000;
}

fn makeLink(allocator: std.mem.Allocator, target: []const u8, link_name: []const u8, config: *const Config) !void {
    // Compute the actual target for the symlink (may be relative)
    var effective_target = target;
    var relative_buf: ?[]const u8 = null;
    defer if (relative_buf) |buf| allocator.free(buf);

    if (config.relative and config.symbolic) {
        relative_buf = computeRelativePath(allocator, target, link_name) catch {
            printErrorFmt("failed to compute relative path for '{s}'", .{target});
            return error.RelativePathFailed;
        };
        effective_target = relative_buf.?;
    }

    const target_z = try allocator.dupeZ(u8, effective_target);
    defer allocator.free(target_z);

    const link_z = try allocator.dupeZ(u8, link_name);
    defer allocator.free(link_z);

    // Handle existing file
    if (fileExists(link_z)) {
        if (config.interactive and !config.force) {
            if (!promptUser(link_name)) {
                return; // User declined
            }
            // User said yes, remove existing
            if (unlink(link_z.ptr) != 0) {
                const err = libc._errno().*;
                printErrorFmt("cannot remove '{s}': {s}", .{ link_name, errnoToString(err) });
                return error.UnlinkFailed;
            }
        } else if (config.force) {
            if (unlink(link_z.ptr) != 0) {
                const err = libc._errno().*;
                printErrorFmt("cannot remove '{s}': {s}", .{ link_name, errnoToString(err) });
                return error.UnlinkFailed;
            }
        }
    }

    if (config.symbolic) {
        // Create symbolic link
        const result = libc.symlink(target_z.ptr, link_z.ptr);
        if (result != 0) {
            const err = libc._errno().*;
            printErrorFmt("failed to create symbolic link '{s}': {s}", .{ link_name, errnoToString(err) });
            return error.SymlinkFailed;
        }
    } else {
        // Create hard link
        const result = libc.link(target_z.ptr, link_z.ptr);
        if (result != 0) {
            const err = libc._errno().*;
            printErrorFmt("failed to create hard link '{s}' => '{s}': {s}", .{ link_name, effective_target, errnoToString(err) });
            return error.LinkFailed;
        }
    }

    if (config.verbose) {
        printVerbose(link_name, effective_target, config.symbolic);
    }
}

fn basename(path: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |idx| {
        return path[idx + 1 ..];
    }
    return path;
}

extern "c" fn realpath(path: [*:0]const u8, resolved_path: ?[*]u8) ?[*]u8;
extern "c" fn getcwd(buf: [*]u8, size: usize) ?[*]u8;

fn resolveAbsolute(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    // If path is already absolute, return a dupe
    if (path.len > 0 and path[0] == '/') {
        return try allocator.dupe(u8, path);
    }
    // Otherwise, prepend cwd
    var cwd_buf: [4096]u8 = undefined;
    const cwd_ptr = getcwd(&cwd_buf, cwd_buf.len);
    if (cwd_ptr == null) return error.GetCwdFailed;
    const cwd = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(cwd_ptr.?)), 0);
    return try std.fmt.allocPrint(allocator, "{s}/{s}", .{ cwd, path });
}

fn computeRelativePath(allocator: std.mem.Allocator, target: []const u8, link_name: []const u8) ![]const u8 {
    // Resolve both paths to absolute
    const abs_target = try resolveAbsolute(allocator, target);
    defer allocator.free(abs_target);
    const abs_link = try resolveAbsolute(allocator, link_name);
    defer allocator.free(abs_link);

    // Get directory of the link
    const link_dir = if (std.mem.lastIndexOfScalar(u8, abs_link, '/')) |idx|
        abs_link[0..idx]
    else
        ".";

    // Split both paths into components
    var target_parts: std.ArrayListUnmanaged([]const u8) = .empty;
    defer target_parts.deinit(allocator);
    var link_dir_parts: std.ArrayListUnmanaged([]const u8) = .empty;
    defer link_dir_parts.deinit(allocator);

    var t_iter = std.mem.splitScalar(u8, abs_target, '/');
    while (t_iter.next()) |part| {
        if (part.len > 0) try target_parts.append(allocator, part);
    }

    var l_iter = std.mem.splitScalar(u8, link_dir, '/');
    while (l_iter.next()) |part| {
        if (part.len > 0) try link_dir_parts.append(allocator, part);
    }

    // Find common prefix length
    var common: usize = 0;
    while (common < target_parts.items.len and common < link_dir_parts.items.len) {
        if (!std.mem.eql(u8, target_parts.items[common], link_dir_parts.items[common])) break;
        common += 1;
    }

    // Build relative path: go up from link_dir to common ancestor, then down to target
    var result: std.ArrayListUnmanaged(u8) = .empty;
    defer result.deinit(allocator);

    // Number of ".." needed
    const ups = link_dir_parts.items.len - common;
    for (0..ups) |idx| {
        if (idx > 0) try result.append(allocator, '/');
        try result.appendSlice(allocator, "..");
    }

    // Append remaining target path
    for (common..target_parts.items.len) |idx| {
        if (result.items.len > 0) try result.append(allocator, '/');
        try result.appendSlice(allocator, target_parts.items[idx]);
    }

    if (result.items.len == 0) {
        try result.append(allocator, '.');
    }

    return try allocator.dupe(u8, result.items);
}

fn promptUser(link_name: []const u8) bool {
    std.debug.print("zln: replace '{s}'? ", .{link_name});
    // Read one byte from stdin
    var buf: [16]u8 = undefined;
    const stdin_fd: c_int = 0;
    const n = libc.read(stdin_fd, &buf, buf.len);
    if (n <= 0) return false;
    return buf[0] == 'y' or buf[0] == 'Y';
}

fn errnoToString(err: c_int) []const u8 {
    return switch (err) {
        1 => "Operation not permitted",
        2 => "No such file or directory",
        13 => "Permission denied",
        17 => "File exists",
        18 => "Invalid cross-device link",
        20 => "Not a directory",
        21 => "Is a directory",
        28 => "No space left on device",
        30 => "Read-only file system",
        31 => "Too many links",
        else => "Unknown error",
    };
}

fn printVerbose(link_name: []const u8, target: []const u8, symbolic: bool) void {
    const io = Io.Threaded.global_single_threaded.io();
    var buf: [512]u8 = undefined;
    const stdout = Io.File.stdout();
    var writer = stdout.writer(io, &buf);
    if (symbolic) {
        writer.interface.print("'{s}' -> '{s}'\n", .{ link_name, target }) catch {};
    } else {
        writer.interface.print("'{s}' => '{s}'\n", .{ link_name, target }) catch {};
    }
    writer.interface.flush() catch {};
}

fn printError(msg: []const u8) void {
    std.debug.print("zln: {s}\n", .{msg});
}

fn printErrorFmt(comptime fmt: []const u8, args: anytype) void {
    std.debug.print("zln: " ++ fmt ++ "\n", args);
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
                } else if (std.mem.eql(u8, arg, "--symbolic")) {
                    config.symbolic = true;
                } else if (std.mem.eql(u8, arg, "--force")) {
                    config.force = true;
                } else if (std.mem.eql(u8, arg, "--no-dereference")) {
                    config.no_dereference = true;
                } else if (std.mem.eql(u8, arg, "--interactive")) {
                    config.interactive = true;
                } else if (std.mem.eql(u8, arg, "--relative")) {
                    config.relative = true;
                } else if (std.mem.eql(u8, arg, "--no-target-directory")) {
                    config.no_target_directory = true;
                } else if (std.mem.eql(u8, arg, "--verbose")) {
                    config.verbose = true;
                } else if (std.mem.startsWith(u8, arg, "--target-directory=")) {
                    config.target_directory = try allocator.dupe(u8, arg[19..]);
                } else if (std.mem.eql(u8, arg, "--target-directory")) {
                    i += 1;
                    if (i >= args.len) {
                        printError("option '--target-directory' requires an argument");
                        std.process.exit(1);
                    }
                    config.target_directory = try allocator.dupe(u8, args[i]);
                } else if (std.mem.eql(u8, arg, "--")) {
                    i += 1;
                    while (i < args.len) : (i += 1) {
                        try config.sources.append(allocator, try allocator.dupe(u8, args[i]));
                    }
                    break;
                } else {
                    printErrorFmt("unrecognized option '{s}'", .{arg});
                    std.process.exit(1);
                }
            } else {
                for (arg[1..]) |ch| {
                    switch (ch) {
                        's' => config.symbolic = true,
                        'f' => config.force = true,
                        'i' => config.interactive = true,
                        'n' => config.no_dereference = true,
                        'r' => config.relative = true,
                        'T' => config.no_target_directory = true,
                        'v' => config.verbose = true,
                        't' => {
                            i += 1;
                            if (i >= args.len) {
                                printError("option requires an argument -- 't'");
                                std.process.exit(1);
                            }
                            config.target_directory = try allocator.dupe(u8, args[i]);
                        },
                        else => {
                            printErrorFmt("invalid option -- '{c}'", .{ch});
                            std.process.exit(1);
                        },
                    }
                }
            }
        } else {
            try config.sources.append(allocator, try allocator.dupe(u8, arg));
        }
    }

    // Handle target directory mode vs normal mode
    if (config.target_directory) |_| {
        if (config.sources.items.len == 0) {
            printError("missing file operand");
            std.process.exit(1);
        }
    } else {
        if (config.sources.items.len < 2) {
            if (config.sources.items.len == 0) {
                printError("missing file operand");
            } else {
                printErrorFmt("missing destination file operand after '{s}'", .{config.sources.items[0]});
            }
            std.debug.print("Try 'zln --help' for more information.\n", .{});
            std.process.exit(1);
        }
        config.destination = config.sources.pop();
    }

    return config;
}

fn printHelp() void {
    const io = Io.Threaded.global_single_threaded.io();
    var buf: [2048]u8 = undefined;
    const stdout = Io.File.stdout();
    var writer = stdout.writer(io, &buf);
    writer.interface.writeAll(
        \\Usage: zln [OPTION]... TARGET LINK_NAME
        \\   or: zln [OPTION]... TARGET... DIRECTORY
        \\   or: zln [OPTION]... -t DIRECTORY TARGET...
        \\Create a link to TARGET with the name LINK_NAME.
        \\
        \\  -s, --symbolic          make symbolic links instead of hard links
        \\  -f, --force             remove existing destination files
        \\  -i, --interactive       prompt whether to remove destinations
        \\  -n, --no-dereference    treat LINK_NAME as normal file if it's a symlink
        \\  -r, --relative          create relative symbolic links
        \\  -t, --target-directory=DIR  specify the DIRECTORY in which to create the links
        \\  -T, --no-target-directory   treat LINK_NAME as a normal file always
        \\  -v, --verbose           print name of each linked file
        \\      --help              display this help and exit
        \\      --version           output version information and exit
        \\
        \\zln - High-performance link creation utility in Zig
        \\
    ) catch {};
    writer.interface.flush() catch {};
}

fn printVersion() void {
    const io = Io.Threaded.global_single_threaded.io();
    var buf: [64]u8 = undefined;
    const stdout = Io.File.stdout();
    var writer = stdout.writer(io, &buf);
    writer.interface.writeAll("zln 0.1.0\n") catch {};
    writer.interface.flush() catch {};
}

pub fn main(init: std.process.Init) void {
    const allocator = init.gpa;

    var config = parseArgs(allocator, init.minimal.args) catch {
        printError("failed to parse arguments");
        std.process.exit(1);
    };
    defer config.deinit(allocator);

    var error_occurred = false;

    if (config.target_directory) |target_dir| {
        const target_z = allocator.dupeZ(u8, target_dir) catch {
            printError("memory allocation failed");
            std.process.exit(1);
        };
        defer allocator.free(target_z);

        if (!isDirectory(target_z)) {
            printErrorFmt("target '{s}' is not a directory", .{target_dir});
            std.process.exit(1);
        }

        for (config.sources.items) |target| {
            const link_name = std.fmt.allocPrint(allocator, "{s}/{s}", .{ target_dir, basename(target) }) catch {
                printError("memory allocation failed");
                error_occurred = true;
                continue;
            };
            defer allocator.free(link_name);

            makeLink(allocator, target, link_name, &config) catch {
                error_occurred = true;
            };
        }
    } else if (config.destination) |dest| {
        const dest_z = allocator.dupeZ(u8, dest) catch {
            printError("memory allocation failed");
            std.process.exit(1);
        };
        defer allocator.free(dest_z);

        if (config.sources.items.len == 1) {
            const target = config.sources.items[0];
            if (!config.no_target_directory and isDirectory(dest_z)) {
                const link_name = std.fmt.allocPrint(allocator, "{s}/{s}", .{ dest, basename(target) }) catch {
                    printError("memory allocation failed");
                    std.process.exit(1);
                };
                defer allocator.free(link_name);
                makeLink(allocator, target, link_name, &config) catch {
                    error_occurred = true;
                };
            } else {
                makeLink(allocator, target, dest, &config) catch {
                    error_occurred = true;
                };
            }
        } else {
            if (!isDirectory(dest_z)) {
                printErrorFmt("target '{s}' is not a directory", .{dest});
                std.process.exit(1);
            }

            for (config.sources.items) |target| {
                const link_name = std.fmt.allocPrint(allocator, "{s}/{s}", .{ dest, basename(target) }) catch {
                    printError("memory allocation failed");
                    error_occurred = true;
                    continue;
                };
                defer allocator.free(link_name);

                makeLink(allocator, target, link_name, &config) catch {
                    error_occurred = true;
                };
            }
        }
    }

    if (error_occurred) {
        std.process.exit(1);
    }
}
