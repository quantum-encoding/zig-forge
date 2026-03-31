//! zbasename - Strip directory and suffix from filenames
//!
//! Compatible with GNU basename:
//! - Print NAME with any leading directory components removed
//! - -a, --multiple: support multiple arguments
//! - -s, --suffix=SUFFIX: remove trailing SUFFIX
//! - -z, --zero: end each output line with NUL, not newline

const std = @import("std");
const Io = std.Io;

const Config = struct {
    multiple: bool = false,
    suffix: ?[]const u8 = null,
    zero: bool = false,
    names: std.ArrayListUnmanaged([]const u8) = .empty,

    fn deinit(self: *Config, allocator: std.mem.Allocator) void {
        for (self.names.items) |item| {
            allocator.free(item);
        }
        self.names.deinit(allocator);
        if (self.suffix) |s| allocator.free(s);
    }
};

fn basename(path: []const u8) []const u8 {
    // Remove trailing slashes
    var p = path;
    while (p.len > 1 and p[p.len - 1] == '/') {
        p = p[0 .. p.len - 1];
    }

    // Find last slash
    if (std.mem.lastIndexOfScalar(u8, p, '/')) |idx| {
        return p[idx + 1 ..];
    }
    return p;
}

fn removeSuffix(name: []const u8, suffix: []const u8) []const u8 {
    if (suffix.len > 0 and name.len > suffix.len) {
        if (std.mem.endsWith(u8, name, suffix)) {
            return name[0 .. name.len - suffix.len];
        }
    }
    return name;
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
                } else if (std.mem.eql(u8, arg, "--multiple")) {
                    config.multiple = true;
                } else if (std.mem.eql(u8, arg, "--zero")) {
                    config.zero = true;
                } else if (std.mem.startsWith(u8, arg, "--suffix=")) {
                    config.suffix = try allocator.dupe(u8, arg[9..]);
                } else if (std.mem.eql(u8, arg, "--suffix")) {
                    i += 1;
                    if (i >= args.len) {
                        std.debug.print("zbasename: option '--suffix' requires an argument\n", .{});
                        std.process.exit(1);
                    }
                    config.suffix = try allocator.dupe(u8, args[i]);
                } else {
                    std.debug.print("zbasename: unrecognized option '{s}'\n", .{arg});
                    std.process.exit(1);
                }
            } else {
                for (arg[1..]) |ch| {
                    switch (ch) {
                        'a' => config.multiple = true,
                        'z' => config.zero = true,
                        's' => {
                            i += 1;
                            if (i >= args.len) {
                                std.debug.print("zbasename: option requires an argument -- 's'\n", .{});
                                std.process.exit(1);
                            }
                            config.suffix = try allocator.dupe(u8, args[i]);
                        },
                        else => {
                            std.debug.print("zbasename: invalid option -- '{c}'\n", .{ch});
                            std.process.exit(1);
                        },
                    }
                }
            }
        } else {
            try config.names.append(allocator, try allocator.dupe(u8, arg));
        }
    }

    if (config.names.items.len == 0) {
        std.debug.print("zbasename: missing operand\n", .{});
        std.debug.print("Try 'zbasename --help' for more information.\n", .{});
        std.process.exit(1);
    }

    // Traditional mode: basename NAME [SUFFIX]
    if (!config.multiple and config.suffix == null and config.names.items.len == 2) {
        config.suffix = config.names.pop();
    }

    return config;
}

fn printHelp() void {
    const io = Io.Threaded.global_single_threaded.io();
    var buf: [1024]u8 = undefined;
    const stdout = Io.File.stdout();
    var writer = stdout.writer(io, &buf);
    writer.interface.writeAll(
        \\Usage: zbasename NAME [SUFFIX]
        \\   or: zbasename OPTION... NAME...
        \\Print NAME with any leading directory components removed.
        \\If specified, also remove a trailing SUFFIX.
        \\
        \\  -a, --multiple       support multiple arguments
        \\  -s, --suffix=SUFFIX  remove a trailing SUFFIX
        \\  -z, --zero           end each output line with NUL, not newline
        \\      --help           display this help and exit
        \\      --version        output version information and exit
        \\
        \\zbasename - High-performance basename utility in Zig
        \\
    ) catch {};
    writer.interface.flush() catch {};
}

fn printVersion() void {
    const io = Io.Threaded.global_single_threaded.io();
    var buf: [64]u8 = undefined;
    const stdout = Io.File.stdout();
    var writer = stdout.writer(io, &buf);
    writer.interface.writeAll("zbasename 0.1.0\n") catch {};
    writer.interface.flush() catch {};
}

pub fn main(init: std.process.Init) void {
    const allocator = init.gpa;

    var config = parseArgs(allocator, init.minimal.args) catch {
        std.debug.print("zbasename: failed to parse arguments\n", .{});
        std.process.exit(1);
    };
    defer config.deinit(allocator);

    const io = Io.Threaded.global_single_threaded.io();
    const stdout = Io.File.stdout();
    var buf: [4096]u8 = undefined;
    var writer = stdout.writer(io, &buf);

    const terminator: []const u8 = if (config.zero) "\x00" else "\n";

    for (config.names.items) |name| {
        var result = basename(name);
        if (config.suffix) |suffix| {
            result = removeSuffix(result, suffix);
        }
        writer.interface.writeAll(result) catch {};
        writer.interface.writeAll(terminator) catch {};
    }

    writer.interface.flush() catch {};
}
