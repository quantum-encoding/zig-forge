//! zrmdir - Remove empty directories
//!
//! Compatible with GNU rmdir:
//! - Remove empty directories
//! - -p, --parents: remove directory and ancestors
//! - -v, --verbose: output diagnostic for each directory
//! - --ignore-fail-on-non-empty: ignore non-empty directory errors

const std = @import("std");
const Io = std.Io;
const Dir = Io.Dir;

const Config = struct {
    parents: bool = false,
    verbose: bool = false,
    ignore_non_empty: bool = false,
    dirs: std.ArrayListUnmanaged([]const u8) = .empty,

    fn deinit(self: *Config, allocator: std.mem.Allocator) void {
        for (self.dirs.items) |item| {
            allocator.free(item);
        }
        self.dirs.deinit(allocator);
    }
};

const RmdirError = Dir.DeleteDirError;

fn removeDir(io: Io, path: []const u8) RmdirError!void {
    return Dir.deleteDir(Dir.cwd(), io, path);
}

fn rmdir(allocator: std.mem.Allocator, path: []const u8, config: *const Config) !void {
    const io = Io.Threaded.global_single_threaded.io();

    if (config.parents) {
        try rmdirParents(allocator, io, path, config);
    } else {
        removeDir(io, path) catch |err| {
            if (err == error.DirNotEmpty and config.ignore_non_empty) {
                return;
            }
            printRmdirError(path, err);
            return err;
        };
        if (config.verbose) {
            printVerbose("removed directory", path);
        }
    }
}

fn rmdirParents(allocator: std.mem.Allocator, io: Io, path: []const u8, config: *const Config) !void {
    var current_path = path;

    while (current_path.len > 0) {
        removeDir(io, current_path) catch |err| {
            // Stop on non-empty (unless ignored) or permission denied
            if (err == error.DirNotEmpty) {
                if (config.ignore_non_empty) {
                    return;
                }
                printRmdirError(current_path, err);
                return err;
            }
            // Permission denied on parent paths is expected, stop gracefully
            if (err == error.AccessDenied) {
                printRmdirError(current_path, err);
                return err;
            }
            printRmdirError(current_path, err);
            return err;
        };

        if (config.verbose) {
            printVerbose("removed directory", current_path);
        }

        // Move to parent
        if (std.mem.lastIndexOfScalar(u8, current_path, '/')) |idx| {
            if (idx == 0) {
                // Handle root-relative paths like /foo - try to remove /foo but stop there
                break;
            }
            current_path = current_path[0..idx];
        } else {
            // No more slashes - we've processed the last component
            break;
        }
    }
    _ = allocator;
}

fn printRmdirError(path: []const u8, err: RmdirError) void {
    const msg = switch (err) {
        error.DirNotEmpty => "Directory not empty",
        error.FileNotFound => "No such file or directory",
        error.AccessDenied => "Permission denied",
        error.NotDir => "Not a directory",
        error.ReadOnlyFileSystem => "Read-only file system",
        else => "Unknown error",
    };
    std.debug.print("zrmdir: failed to remove '{s}': {s}\n", .{ path, msg });
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

        if (arg.len > 0 and arg[0] == '-') {
            if (arg.len == 1) {
                printError("invalid argument '-'");
                std.process.exit(1);
            }

            if (arg[1] == '-') {
                if (std.mem.eql(u8, arg, "--help")) {
                    printHelp();
                    std.process.exit(0);
                } else if (std.mem.eql(u8, arg, "--version")) {
                    printVersion();
                    std.process.exit(0);
                } else if (std.mem.eql(u8, arg, "--parents")) {
                    config.parents = true;
                } else if (std.mem.eql(u8, arg, "--verbose")) {
                    config.verbose = true;
                } else if (std.mem.eql(u8, arg, "--ignore-fail-on-non-empty")) {
                    config.ignore_non_empty = true;
                } else if (std.mem.eql(u8, arg, "--")) {
                    i += 1;
                    while (i < args.len) : (i += 1) {
                        try config.dirs.append(allocator, try allocator.dupe(u8, args[i]));
                    }
                    break;
                } else {
                    printErrorFmt("unrecognized option '{s}'", .{arg});
                    std.process.exit(1);
                }
            } else {
                for (arg[1..]) |ch| {
                    switch (ch) {
                        'p' => config.parents = true,
                        'v' => config.verbose = true,
                        else => {
                            printErrorFmt("invalid option -- '{c}'", .{ch});
                            std.process.exit(1);
                        },
                    }
                }
            }
        } else {
            try config.dirs.append(allocator, try allocator.dupe(u8, arg));
        }
    }

    if (config.dirs.items.len == 0) {
        printError("missing operand");
        std.debug.print("Try 'zrmdir --help' for more information.\n", .{});
        std.process.exit(1);
    }

    return config;
}

fn printVerbose(action: []const u8, path: []const u8) void {
    const io = Io.Threaded.global_single_threaded.io();
    var buf: [512]u8 = undefined;
    const stdout = Io.File.stdout();
    var writer = stdout.writer(io, &buf);
    writer.interface.print("zrmdir: {s} '{s}'\n", .{ action, path }) catch {};
    writer.interface.flush() catch {};
}

fn printError(msg: []const u8) void {
    std.debug.print("zrmdir: {s}\n", .{msg});
}

fn printErrorFmt(comptime fmt: []const u8, args: anytype) void {
    std.debug.print("zrmdir: " ++ fmt ++ "\n", args);
}

fn printHelp() void {
    const io = Io.Threaded.global_single_threaded.io();
    var buf: [2048]u8 = undefined;
    const stdout = Io.File.stdout();
    var writer = stdout.writer(io, &buf);
    writer.interface.writeAll(
        \\Usage: zrmdir [OPTION]... DIRECTORY...
        \\Remove the DIRECTORY(ies), if they are empty.
        \\
        \\      --ignore-fail-on-non-empty
        \\                    ignore each failure to remove a non-empty directory
        \\  -p, --parents     remove DIRECTORY and its ancestors;
        \\                    e.g., 'zrmdir -p a/b' is similar to 'zrmdir a/b a'
        \\  -v, --verbose     output a diagnostic for every directory processed
        \\      --help        display this help and exit
        \\      --version     output version information and exit
        \\
        \\zrmdir - High-performance directory removal utility in Zig
        \\
    ) catch {};
    writer.interface.flush() catch {};
}

fn printVersion() void {
    const io = Io.Threaded.global_single_threaded.io();
    var buf: [64]u8 = undefined;
    const stdout = Io.File.stdout();
    var writer = stdout.writer(io, &buf);
    writer.interface.writeAll("zrmdir 0.1.0\n") catch {};
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

    for (config.dirs.items) |dir| {
        rmdir(allocator, dir, &config) catch {
            error_occurred = true;
        };
    }

    if (error_occurred) {
        std.process.exit(1);
    }
}

test "basic rmdir" {
    // Tests would require actual filesystem operations
    // which are better done as integration tests
}
