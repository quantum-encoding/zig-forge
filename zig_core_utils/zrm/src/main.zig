//! zrm - Remove files and directories
//!
//! Compatible with GNU rm:
//! - Remove files
//! - -f, --force: ignore nonexistent files
//! - -r, -R, --recursive: remove directories recursively
//! - -d, --dir: remove empty directories
//! - -v, --verbose: explain what is being done

const std = @import("std");
const builtin = @import("builtin");
const libc = std.c;
const Io = std.Io;
const Dir = Io.Dir;

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

extern "c" fn lstat(path: [*:0]const u8, buf: *Stat) c_int;
extern "c" fn unlink(path: [*:0]const u8) c_int;
extern "c" fn rmdir(path: [*:0]const u8) c_int;

// Mode constants
const S_IFMT: u32 = 0o170000;
const S_IFREG: u32 = 0o100000;
const S_IFDIR: u32 = 0o40000;
const S_IFLNK: u32 = 0o120000;

const Config = struct {
    force: bool = false,
    recursive: bool = false,
    remove_empty_dirs: bool = false,
    verbose: bool = false,
    interactive: bool = false,
    preserve_root: bool = true, // Safety default: prevent rm -rf /
    files: std.ArrayListUnmanaged([]const u8) = .empty,

    fn deinit(self: *Config, allocator: std.mem.Allocator) void {
        for (self.files.items) |item| {
            allocator.free(item);
        }
        self.files.deinit(allocator);
    }
};

const FileType = enum {
    file,
    directory,
    symlink,
    other,
};

fn getFileType(path: [:0]const u8) ?FileType {
    var stat_buf: Stat = undefined;
    const result = lstat(path.ptr, &stat_buf);
    if (result != 0) return null;

    const mode = stat_buf.mode & S_IFMT;
    return switch (mode) {
        S_IFREG => .file,
        S_IFDIR => .directory,
        S_IFLNK => .symlink,
        else => .other,
    };
}

// Check if path is root directory
fn isRootPath(path: []const u8) bool {
    // Normalize: "/" or "/." or "/./." etc are all root
    if (std.mem.eql(u8, path, "/")) return true;
    if (std.mem.eql(u8, path, "/.")) return true;
    if (std.mem.eql(u8, path, "/..")) return true;

    // Check resolved path - simple check for leading / with no other path component
    var normalized = path;
    // Remove trailing slashes
    while (normalized.len > 1 and normalized[normalized.len - 1] == '/') {
        normalized = normalized[0 .. normalized.len - 1];
    }
    return std.mem.eql(u8, normalized, "/");
}

// Interactive prompt - returns true if user confirms
fn promptUser(action: []const u8, path: []const u8, file_type: FileType) bool {
    const type_str = switch (file_type) {
        .file => "regular file",
        .directory => "directory",
        .symlink => "symbolic link",
        .other => "file",
    };

    // Write prompt to stderr
    var prompt_buf: [512]u8 = undefined;
    const prompt = std.fmt.bufPrint(&prompt_buf, "zrm: {s} {s} '{s}'? ", .{ action, type_str, path }) catch return false;
    _ = libc.write(libc.STDERR_FILENO, prompt.ptr, prompt.len);

    // Read response from stdin
    var response: [8]u8 = undefined;
    const n = libc.read(libc.STDIN_FILENO, &response, response.len);
    if (n <= 0) return false;

    // Check for y/Y/yes
    const resp = response[0..@min(@as(usize, @intCast(n)), response.len)];
    if (resp.len > 0) {
        return resp[0] == 'y' or resp[0] == 'Y';
    }
    return false;
}

fn removeFile(allocator: std.mem.Allocator, path: []const u8, config: *const Config) !void {
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);

    // Check preserve-root safety
    if (config.preserve_root and config.recursive and isRootPath(path)) {
        printError("it is dangerous to operate recursively on '/'");
        printError("use --no-preserve-root to override this failsafe");
        return error.PreserveRoot;
    }

    const file_type = getFileType(path_z);

    if (file_type == null) {
        if (!config.force) {
            printErrorFmt("cannot remove '{s}': No such file or directory", .{path});
            return error.FileNotFound;
        }
        return; // Force mode: ignore nonexistent
    }

    // Interactive mode: prompt user unless force is set
    if (config.interactive and !config.force) {
        if (!promptUser("remove", path, file_type.?)) {
            return; // User declined
        }
    }

    switch (file_type.?) {
        .directory => {
            if (config.recursive) {
                try removeDirectoryRecursive(allocator, path, config);
            } else if (config.remove_empty_dirs) {
                try removeEmptyDir(path, path_z, config);
            } else {
                printErrorFmt("cannot remove '{s}': Is a directory", .{path});
                return error.IsDir;
            }
        },
        .file, .symlink, .other => {
            try unlinkFile(path, path_z, config);
        },
    }
}

fn unlinkFile(path: []const u8, path_z: [:0]const u8, config: *const Config) !void {
    const result = unlink(path_z.ptr);
    if (result != 0) {
        const err = libc._errno().*;
        if (!config.force or err != 2) { // 2 = ENOENT
            printErrorFmt("cannot remove '{s}': {s}", .{ path, errnoToString(err) });
            return error.UnlinkFailed;
        }
    } else {
        if (config.verbose) {
            printVerbose("removed", path);
        }
    }
}

fn removeEmptyDir(path: []const u8, path_z: [:0]const u8, config: *const Config) !void {
    const io = Io.Threaded.global_single_threaded.io();
    Dir.deleteDir(Dir.cwd(), io, path_z) catch |err| {
        if (!config.force or err != error.FileNotFound) {
            printErrorFmt("cannot remove '{s}': {s}", .{ path, @errorName(err) });
            return err;
        }
        return;
    };
    if (config.verbose) {
        printVerbose("removed directory", path);
    }
}

fn removeDirectoryRecursive(allocator: std.mem.Allocator, path: []const u8, config: *const Config) !void {
    const io = Io.Threaded.global_single_threaded.io();

    // Open the directory
    var dir = Dir.openDir(Dir.cwd(), io, path, .{ .iterate = true }) catch |err| {
        if (config.force and err == error.FileNotFound) {
            return;
        }
        printErrorFmt("cannot open directory '{s}': {s}", .{ path, @errorName(err) });
        return err;
    };
    defer dir.close(io);

    // Iterate and remove contents
    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        const entry_name = entry.name;

        // Build full path
        const full_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ path, entry_name });
        defer allocator.free(full_path);

        const full_path_z = try allocator.dupeZ(u8, full_path);
        defer allocator.free(full_path_z);

        const entry_type = getFileType(full_path_z);
        if (entry_type) |ft| {
            switch (ft) {
                .directory => {
                    try removeDirectoryRecursive(allocator, full_path, config);
                },
                .file, .symlink, .other => {
                    try unlinkFile(full_path, full_path_z, config);
                },
            }
        }
    }

    // Now remove the empty directory
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);
    try removeEmptyDir(path, path_z, config);
}

fn errnoToString(err: c_int) []const u8 {
    return switch (err) {
        1 => "Operation not permitted",
        2 => "No such file or directory",
        13 => "Permission denied",
        17 => "File exists",
        20 => "Not a directory",
        21 => "Is a directory",
        28 => "No space left on device",
        30 => "Read-only file system",
        39 => "Directory not empty",
        else => "Unknown error",
    };
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
                } else if (std.mem.eql(u8, arg, "--force")) {
                    config.force = true;
                } else if (std.mem.eql(u8, arg, "--recursive")) {
                    config.recursive = true;
                } else if (std.mem.eql(u8, arg, "--dir")) {
                    config.remove_empty_dirs = true;
                } else if (std.mem.eql(u8, arg, "--verbose")) {
                    config.verbose = true;
                } else if (std.mem.eql(u8, arg, "--interactive")) {
                    config.interactive = true;
                } else if (std.mem.eql(u8, arg, "--preserve-root")) {
                    config.preserve_root = true;
                } else if (std.mem.eql(u8, arg, "--no-preserve-root")) {
                    config.preserve_root = false;
                } else if (std.mem.eql(u8, arg, "--")) {
                    i += 1;
                    while (i < args.len) : (i += 1) {
                        try config.files.append(allocator, try allocator.dupe(u8, args[i]));
                    }
                    break;
                } else {
                    printErrorFmt("unrecognized option '{s}'", .{arg});
                    std.process.exit(1);
                }
            } else {
                for (arg[1..]) |ch| {
                    switch (ch) {
                        'f' => config.force = true,
                        'r', 'R' => config.recursive = true,
                        'd' => config.remove_empty_dirs = true,
                        'v' => config.verbose = true,
                        'i' => config.interactive = true,
                        'I' => config.interactive = true, // prompt once before removing more than 3 files
                        else => {
                            printErrorFmt("invalid option -- '{c}'", .{ch});
                            std.process.exit(1);
                        },
                    }
                }
            }
        } else {
            try config.files.append(allocator, try allocator.dupe(u8, arg));
        }
    }

    if (config.files.items.len == 0 and !config.force) {
        printError("missing operand");
        std.debug.print("Try 'zrm --help' for more information.\n", .{});
        std.process.exit(1);
    }

    return config;
}

fn printVerbose(action: []const u8, path: []const u8) void {
    const io = Io.Threaded.global_single_threaded.io();
    var buf: [512]u8 = undefined;
    const stdout = Io.File.stdout();
    var writer = stdout.writer(io, &buf);
    writer.interface.print("zrm: {s} '{s}'\n", .{ action, path }) catch {};
    writer.interface.flush() catch {};
}

fn printError(msg: []const u8) void {
    std.debug.print("zrm: {s}\n", .{msg});
}

fn printErrorFmt(comptime fmt: []const u8, args: anytype) void {
    std.debug.print("zrm: " ++ fmt ++ "\n", args);
}

fn printHelp() void {
    const io = Io.Threaded.global_single_threaded.io();
    var buf: [2048]u8 = undefined;
    const stdout = Io.File.stdout();
    var writer = stdout.writer(io, &buf);
    writer.interface.writeAll(
        \\Usage: zrm [OPTION]... [FILE]...
        \\Remove (unlink) the FILE(s).
        \\
        \\  -f, --force           ignore nonexistent files, never prompt
        \\  -i, --interactive     prompt before every removal
        \\  -r, -R, --recursive   remove directories and their contents recursively
        \\  -d, --dir             remove empty directories
        \\  -v, --verbose         explain what is being done
        \\      --preserve-root   do not remove '/' (default)
        \\      --no-preserve-root  do not treat '/' specially
        \\      --help            display this help and exit
        \\      --version         output version information and exit
        \\
        \\By default, zrm does not remove directories.  Use -r to remove directories.
        \\To avoid accidental removal of '/', --preserve-root is enabled by default.
        \\
        \\zrm - High-performance file removal utility in Zig
        \\
    ) catch {};
    writer.interface.flush() catch {};
}

fn printVersion() void {
    const io = Io.Threaded.global_single_threaded.io();
    var buf: [64]u8 = undefined;
    const stdout = Io.File.stdout();
    var writer = stdout.writer(io, &buf);
    writer.interface.writeAll("zrm 0.1.0\n") catch {};
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

    for (config.files.items) |file| {
        removeFile(allocator, file, &config) catch {
            error_occurred = true;
        };
    }

    if (error_occurred) {
        std.process.exit(1);
    }
}
