//! zmkdir - High-performance directory creation utility in Zig
//!
//! Compatible with GNU mkdir, supporting:
//! - Creating multiple directories
//! - Parent directory creation (-p)
//! - Permission mode setting (-m)
//! - Verbose output (-v)

const std = @import("std");
const libc = std.c;

extern "c" fn umask(mask: libc.mode_t) libc.mode_t;
extern "c" fn stat(path: [*:0]const u8, buf: *libc.Stat) c_int;
extern "c" fn access(path: [*:0]const u8, mode: c_int) c_int;

// ============================================================================
// Configuration
// ============================================================================

const Config = struct {
    parents: bool = false,
    verbose: bool = false,
    mode: ?u32 = null, // null means use default (0o777 & ~umask)
    dirs: std.ArrayListUnmanaged([]const u8) = .empty,

    fn deinit(self: *Config, allocator: std.mem.Allocator) void {
        for (self.dirs.items) |item| {
            allocator.free(item);
        }
        self.dirs.deinit(allocator);
    }
};

// ============================================================================
// Mode Parsing
// ============================================================================

/// Parse octal mode string (e.g., "755", "0755")
fn parseOctalMode(mode_str: []const u8) ?u32 {
    if (mode_str.len == 0) return null;

    var result: u32 = 0;
    for (mode_str) |ch| {
        if (ch < '0' or ch > '7') return null;
        result = result * 8 + (ch - '0');
    }
    return result;
}

/// Get the current umask
fn getUmask() u32 {
    // Set umask to 0 to get current value, then restore it
    const current = umask(0);
    _ = umask(current);
    return current;
}

/// Get default mode (0o777 & ~umask)
fn getDefaultMode() u32 {
    return 0o777 & ~getUmask();
}

// ============================================================================
// Directory Creation
// ============================================================================

const MkdirError = error{
    AccessDenied,
    FileExists,
    NoSpace,
    ReadOnlyFS,
    Unknown,
    PathAlreadyExists,
    FileNotFound,
    OutOfMemory,
};

/// Create a single directory with the given mode
fn createDir(path: [:0]const u8, mode: u32) MkdirError!void {
    if (libc.mkdir(path.ptr, @intCast(mode)) != 0) {
        return error.Unknown;
    }
}

/// Check if path exists and is a directory
fn isDirectory(path: [:0]const u8) bool {
    var stat_buf: libc.Stat = undefined;
    const result = stat(path.ptr, &stat_buf);
    if (result != 0) return false;
    return (stat_buf.mode & 0o170000) == 0o40000;
}

/// Check if path exists
fn pathExists(path: [:0]const u8) bool {
    // F_OK = 0, check existence only
    return access(path.ptr, 0) == 0;
}

/// Create directory and optionally parent directories
fn mkdir(allocator: std.mem.Allocator, path: []const u8, config: *const Config) !void {
    const mode = config.mode orelse getDefaultMode();

    // Need null-terminated path for syscalls
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);

    if (config.parents) {
        try mkdirParents(allocator, path_z, mode, config.verbose);
    } else {
        createDir(path_z, mode) catch |err| {
            switch (err) {
                error.PathAlreadyExists => {
                    printErrorFmt("cannot create directory '{s}': File exists", .{path});
                    return error.PathAlreadyExists;
                },
                error.FileNotFound => {
                    printErrorFmt("cannot create directory '{s}': No such file or directory", .{path});
                    return err;
                },
                error.AccessDenied => {
                    printErrorFmt("cannot create directory '{s}': Permission denied", .{path});
                    return err;
                },
                else => {
                    printErrorFmt("cannot create directory '{s}': {}", .{ path, err });
                    return err;
                },
            }
        };
        if (config.verbose) {
            printVerbose("created directory", path);
        }
    }
}

/// Create directory with all parent directories
fn mkdirParents(allocator: std.mem.Allocator, path: [:0]const u8, mode: u32, verbose: bool) !void {
    // Collect all components that need to be created
    var components_to_create: std.ArrayListUnmanaged(usize) = .empty;
    defer components_to_create.deinit(allocator);

    // Walk up from path to find first existing ancestor
    // Store the end indices of each path component
    var end_idx = path.len;

    while (end_idx > 0) {
        // Create null-terminated path for this prefix
        const check_path = try allocator.dupeZ(u8, path[0..end_idx]);
        defer allocator.free(check_path);

        if (pathExists(check_path)) {
            break;
        }

        try components_to_create.append(allocator, end_idx);

        // Move to parent
        if (std.mem.lastIndexOfScalar(u8, path[0..end_idx], '/')) |idx| {
            if (idx == 0) {
                end_idx = 0;
            } else {
                end_idx = idx;
            }
        } else {
            break;
        }
    }

    // Create directories from root to leaf (reverse order)
    var i = components_to_create.items.len;
    while (i > 0) {
        i -= 1;
        const component_end = components_to_create.items[i];
        const dir_path = path[0..component_end];

        const dir_path_z = try allocator.dupeZ(u8, dir_path);
        defer allocator.free(dir_path_z);

        // For parent directories, use mode with u+wx (0o300) to allow traversal
        const parent_mode = if (i > 0) (getDefaultMode() | 0o300) else mode;

        createDir(dir_path_z, parent_mode) catch |err| {
            switch (err) {
                error.PathAlreadyExists => {
                    // Already exists, that's fine for -p
                    continue;
                },
                else => {
                    printErrorFmt("cannot create directory '{s}': {}", .{ dir_path, err });
                    return err;
                },
            }
        };

        if (verbose) {
            printVerbose("created directory", dir_path);
        }
    }
}

// ============================================================================
// Argument Parsing
// ============================================================================

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

    var i: usize = 1; // Skip program name

    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (arg.len > 0 and arg[0] == '-') {
            if (arg.len == 1) {
                // "-" alone is an invalid directory name for mkdir
                printError("cannot create directory '-': Invalid argument");
                std.process.exit(1);
            }

            if (arg[1] == '-') {
                // Long options
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
                } else if (std.mem.startsWith(u8, arg, "--mode=")) {
                    const mode_str = arg[7..];
                    config.mode = parseOctalMode(mode_str) orelse {
                        printErrorFmt("invalid mode: '{s}'", .{mode_str});
                        std.process.exit(1);
                    };
                } else if (std.mem.eql(u8, arg, "--mode")) {
                    i += 1;
                    if (i >= args.len) {
                        printError("option '--mode' requires an argument");
                        std.process.exit(1);
                    }
                    config.mode = parseOctalMode(args[i]) orelse {
                        printErrorFmt("invalid mode: '{s}'", .{args[i]});
                        std.process.exit(1);
                    };
                } else if (std.mem.eql(u8, arg, "--")) {
                    // End of options
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
                // Short options (can be combined: -pv)
                var j: usize = 1;
                while (j < arg.len) : (j += 1) {
                    const ch = arg[j];
                    switch (ch) {
                        'p' => config.parents = true,
                        'v' => config.verbose = true,
                        'm' => {
                            // -m requires argument
                            if (j + 1 < arg.len) {
                                // Mode attached: -m755
                                const mode_str = arg[j + 1 ..];
                                config.mode = parseOctalMode(mode_str) orelse {
                                    printErrorFmt("invalid mode: '{s}'", .{mode_str});
                                    std.process.exit(1);
                                };
                                break;
                            } else {
                                // Mode as next argument: -m 755
                                i += 1;
                                if (i >= args.len) {
                                    printError("option requires an argument -- 'm'");
                                    std.process.exit(1);
                                }
                                config.mode = parseOctalMode(args[i]) orelse {
                                    printErrorFmt("invalid mode: '{s}'", .{args[i]});
                                    std.process.exit(1);
                                };
                            }
                        },
                        else => {
                            printErrorFmt("invalid option -- '{c}'", .{ch});
                            std.process.exit(1);
                        },
                    }
                }
            }
        } else {
            // Directory argument
            try config.dirs.append(allocator, try allocator.dupe(u8, arg));
        }
    }

    if (config.dirs.items.len == 0) {
        printError("missing operand");
        std.debug.print("Try 'zmkdir --help' for more information.\n", .{});
        std.process.exit(1);
    }

    return config;
}

// ============================================================================
// Output
// ============================================================================

fn printVerbose(action: []const u8, path: []const u8) void {
    const Io = std.Io;
    const io = Io.Threaded.global_single_threaded.io();
    var buf: [512]u8 = undefined;
    const stdout_file = Io.File.stdout();
    var writer = stdout_file.writer(io, &buf);
    writer.interface.print("zmkdir: {s} '{s}'\n", .{ action, path }) catch {};
    writer.interface.flush() catch {};
}

fn printError(msg: []const u8) void {
    std.debug.print("zmkdir: {s}\n", .{msg});
}

fn printErrorFmt(comptime fmt: []const u8, args: anytype) void {
    std.debug.print("zmkdir: " ++ fmt ++ "\n", args);
}

fn printHelp() void {
    const Io = std.Io;
    const io = Io.Threaded.global_single_threaded.io();
    var buf: [4096]u8 = undefined;
    const stdout_file = Io.File.stdout();
    var writer = stdout_file.writer(io, &buf);
    writer.interface.writeAll(
        \\Usage: zmkdir [OPTION]... DIRECTORY...
        \\Create the DIRECTORY(ies), if they do not already exist.
        \\
        \\Mandatory arguments to long options are mandatory for short options too.
        \\  -m, --mode=MODE   set file mode (as in chmod), not a=rwx - umask
        \\  -p, --parents     no error if existing, make parent directories as needed
        \\  -v, --verbose     print a message for each created directory
        \\      --help        display this help and exit
        \\      --version     output version information and exit
        \\
        \\zmkdir - High-performance directory creation utility in Zig
        \\
    ) catch {};
    writer.interface.flush() catch {};
}

fn printVersion() void {
    const Io = std.Io;
    const io = Io.Threaded.global_single_threaded.io();
    var buf: [256]u8 = undefined;
    const stdout_file = Io.File.stdout();
    var writer = stdout_file.writer(io, &buf);
    writer.interface.writeAll("zmkdir 0.1.0\n") catch {};
    writer.interface.flush() catch {};
}

// ============================================================================
// Entry Point
// ============================================================================

pub fn main(init: std.process.Init) void {
    const allocator = init.gpa;

    var config = parseArgs(allocator, init.minimal.args) catch {
        printError("failed to parse arguments");
        std.process.exit(1);
    };
    defer config.deinit(allocator);

    var error_occurred = false;

    for (config.dirs.items) |dir| {
        mkdir(allocator, dir, &config) catch {
            error_occurred = true;
        };
    }

    if (error_occurred) {
        std.process.exit(1);
    }
}

// ============================================================================
// Tests
// ============================================================================

test "parse octal mode" {
    const testing = std.testing;

    try testing.expectEqual(@as(?u32, 0o755), parseOctalMode("755"));
    try testing.expectEqual(@as(?u32, 0o777), parseOctalMode("777"));
    try testing.expectEqual(@as(?u32, 0o700), parseOctalMode("700"));
    try testing.expectEqual(@as(?u32, 0o644), parseOctalMode("644"));
    try testing.expectEqual(@as(?u32, 0), parseOctalMode("0"));
    try testing.expectEqual(@as(?u32, null), parseOctalMode(""));
    try testing.expectEqual(@as(?u32, null), parseOctalMode("abc"));
    try testing.expectEqual(@as(?u32, null), parseOctalMode("888")); // 8 is not valid octal
}

test "get default mode" {
    // Just verify it returns something reasonable
    const mode = getDefaultMode();
    // Mode should be at most 0o777 and at least 0o000
    try std.testing.expect(mode <= 0o777);
}
