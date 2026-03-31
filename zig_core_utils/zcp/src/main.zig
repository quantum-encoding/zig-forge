//! zcp - Copy files and directories
//!
//! Compatible with GNU cp:
//! - Copy files
//! - -r, -R, --recursive: copy directories recursively
//! - -f, --force: overwrite existing files
//! - -i, --interactive: prompt before overwrite
//! - -n, --no-clobber: don't overwrite existing files
//! - -v, --verbose: explain what is being done
//! - -p, --preserve: preserve mode, ownership, timestamps
//! - -a, --archive: same as -dR --preserve=all
//! - -t, --target-directory=DIR: copy all SOURCE to DIRECTORY
//! - -T, --no-target-directory: treat DEST as normal file

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
        pub fn atime(self: @This()) libc.timespec { return self.atim; }
        pub fn mtime(self: @This()) libc.timespec { return self.mtim; }
    },
    .macos, .ios, .tvos, .watchos => extern struct {
        dev: i32, mode: u16, nlink: u16, ino: u64, uid: u32, gid: u32, rdev: i32,
        atim: libc.timespec, mtim: libc.timespec, ctim: libc.timespec, birthtim: libc.timespec,
        size: i64, blocks: i64, blksize: i32, flags: u32, gen: u32, lspare: i32, qspare: [2]i64,
        pub fn atime(self: @This()) libc.timespec { return self.atim; }
        pub fn mtime(self: @This()) libc.timespec { return self.mtim; }
    },
    else => libc.Stat,
};

extern "c" fn lstat(path: [*:0]const u8, buf: *Stat) c_int;
extern "c" fn stat(path: [*:0]const u8, buf: *Stat) c_int;
extern "c" fn unlink(path: [*:0]const u8) c_int;
extern "c" fn chmod(path: [*:0]const u8, mode: libc.mode_t) c_int;
extern "c" fn symlink(target: [*:0]const u8, linkpath: [*:0]const u8) c_int;

fn promptOverwrite(dest: []const u8) bool {
    // Write prompt to stderr (fd 2)
    const prefix = "zcp: overwrite '";
    const suffix = "'? ";
    _ = std.c.write(2, prefix.ptr, prefix.len);
    _ = std.c.write(2, dest.ptr, dest.len);
    _ = std.c.write(2, suffix.ptr, suffix.len);

    // Read response from stdin (fd 0)
    var buf: [128]u8 = undefined;
    const n = std.c.read(0, &buf, buf.len);
    if (n <= 0) return false;
    return (buf[0] == 'y' or buf[0] == 'Y');
}

// Mode constants
const S_IFMT: u32 = 0o170000;
const S_IFREG: u32 = 0o100000;
const S_IFDIR: u32 = 0o40000;
const S_IFLNK: u32 = 0o120000;

const Config = struct {
    recursive: bool = false,
    force: bool = false,
    interactive: bool = false,
    no_clobber: bool = false,
    verbose: bool = false,
    preserve: bool = false,
    archive: bool = false,
    update: bool = false,
    no_target_directory: bool = false,
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

fn fileExists(path: [:0]const u8) bool {
    return libc.access(path.ptr, 0) == 0;
}

// Get file modification time (returns null if file doesn't exist)
fn getFileMtime(path: [:0]const u8) ?i128 {
    var stat_buf: Stat = undefined;
    const result = stat(path.ptr, &stat_buf);
    if (result != 0) return null;

    // Return as nanoseconds for precise comparison
    const mtime = stat_buf.mtime();
    return @as(i128, mtime.sec) * 1_000_000_000 + mtime.nsec;
}

// Check if source is newer than destination
fn sourceIsNewer(src_z: [:0]const u8, dst_z: [:0]const u8) bool {
    const src_mtime = getFileMtime(src_z) orelse return true; // Source doesn't exist = error handled elsewhere
    const dst_mtime = getFileMtime(dst_z) orelse return true; // Destination doesn't exist = copy
    return src_mtime > dst_mtime;
}

const Timespec = extern struct {
    sec: i64,
    nsec: i64,
};

extern "c" fn utimensat(dirfd: c_int, pathname: [*:0]const u8, times: ?*const [2]Timespec, flags: c_int) c_int;

// Fallback copy using read/write when copy_file_range is not available
fn copyFileFallback(io: Io, src_file: Io.File, dst_file: Io.File) !void {
    var buf: [65536]u8 = undefined;
    while (true) {
        const bytes_read = src_file.readStreaming(io, &.{&buf}) catch |err| {
            return err;
        };
        if (bytes_read == 0) break;

        dst_file.writeStreamingAll(io, buf[0..bytes_read]) catch |err| {
            return err;
        };
    }
}

fn copyFile(allocator: std.mem.Allocator, src: []const u8, dst: []const u8, config: *const Config) !void {
    const io = Io.Threaded.global_single_threaded.io();

    const src_z = try allocator.dupeZ(u8, src);
    defer allocator.free(src_z);

    const dst_z = try allocator.dupeZ(u8, dst);
    defer allocator.free(dst_z);

    // Check if destination exists
    if (fileExists(dst_z)) {
        if (config.no_clobber) {
            return; // Don't overwrite
        }
        // Update mode: skip if destination is newer or same age
        if (config.update) {
            if (!sourceIsNewer(src_z, dst_z)) {
                return; // Destination is newer or same age, skip
            }
        }
        // Interactive mode: prompt before overwriting
        if (config.interactive and !config.force) {
            if (!promptOverwrite(dst)) {
                return;
            }
        }
        if (!config.force) {
            // Check if writable
            if (libc.access(dst_z.ptr, 2) != 0) { // W_OK = 2
                printErrorFmt("cannot create regular file '{s}': Permission denied", .{dst});
                return error.AccessDenied;
            }
        }
    }

    // Get source file info for permissions and timestamps
    var src_stat: Stat = undefined;
    const stat_result = stat(src_z.ptr, &src_stat);
    if (stat_result != 0) {
        printErrorFmt("cannot stat '{s}': No such file or directory", .{src});
        return error.FileNotFound;
    }

    // Open source file
    const src_file = Dir.openFile(Dir.cwd(), io, src, .{}) catch |err| {
        printErrorFmt("cannot open '{s}' for reading: {s}", .{ src, @errorName(err) });
        return err;
    };
    defer src_file.close(io);

    // Create destination file
    const dst_file = Dir.createFile(Dir.cwd(), io, dst_z, .{ .truncate = true }) catch |err| {
        printErrorFmt("cannot create '{s}': {s}", .{ dst, @errorName(err) });
        return err;
    };
    defer dst_file.close(io);

    // Use zero-copy transfer via copy_file_range/sendfile when available
    // Create a reader from source and writer for destination
    var read_buf: [65536]u8 = undefined;
    var write_buf: [65536]u8 = undefined;

    var src_reader = src_file.reader(io, &read_buf);
    var dst_writer = dst_file.writer(io, &write_buf);

    // Use sendFile for zero-copy transfer (uses copy_file_range internally)
    while (true) {
        const n = dst_writer.interface.sendFile(&src_reader, .unlimited) catch |err| switch (err) {
            error.EndOfStream => break,
            error.Unimplemented => {
                // Fallback to regular read/write
                try copyFileFallback(io, src_file, dst_file);
                break;
            },
            else => {
                printErrorFmt("error copying '{s}': {s}", .{ src, @errorName(err) });
                return err;
            },
        };
        if (n == 0) break;
    }

    // Flush any remaining buffered data
    dst_writer.interface.flush() catch |err| {
        printErrorFmt("error flushing '{s}': {s}", .{ dst, @errorName(err) });
        return err;
    };

    // Preserve permissions if requested
    if (config.preserve or config.archive) {
        // Set permissions
        const chmod_result = chmod(dst_z.ptr, src_stat.mode & 0o7777);
        if (chmod_result != 0) {
            // Non-fatal, just warn
        }

        // Set timestamps
        const atime = src_stat.atime();
        const mtime = src_stat.mtime();
        const times: [2]Timespec = .{
            .{ .sec = @intCast(atime.sec), .nsec = atime.nsec },
            .{ .sec = @intCast(mtime.sec), .nsec = mtime.nsec },
        };
        _ = utimensat(-100, dst_z.ptr, &times, 0);
    }

    if (config.verbose) {
        printVerbose(src, dst);
    }
}

fn copySymlink(allocator: std.mem.Allocator, src: []const u8, dst: []const u8, config: *const Config) !void {
    const src_z = try allocator.dupeZ(u8, src);
    defer allocator.free(src_z);

    const dst_z = try allocator.dupeZ(u8, dst);
    defer allocator.free(dst_z);

    // Read the symlink target
    var link_buf: [4096]u8 = undefined;
    const link_result = libc.readlink(src_z.ptr, &link_buf, link_buf.len);
    if (link_result < 0) {
        printErrorFmt("cannot read symbolic link '{s}'", .{src});
        return error.ReadLinkFailed;
    }
    const link_target = link_buf[0..@intCast(link_result)];

    // Remove existing if force
    if (fileExists(dst_z)) {
        if (config.no_clobber) {
            return;
        }
        if (config.force) {
            _ = unlink(dst_z.ptr);
        } else {
            printErrorFmt("cannot create symbolic link '{s}': File exists", .{dst});
            return error.FileExists;
        }
    }

    // Create the symlink
    const link_target_z = try allocator.dupeZ(u8, link_target);
    defer allocator.free(link_target_z);

    const symlink_result = symlink(link_target_z.ptr, dst_z.ptr);
    if (symlink_result != 0) {
        printErrorFmt("cannot create symbolic link '{s}'", .{dst});
        return error.SymlinkFailed;
    }

    if (config.verbose) {
        printVerbose(src, dst);
    }
}

fn copyDirectory(allocator: std.mem.Allocator, src: []const u8, dst: []const u8, config: *const Config) !void {
    const io = Io.Threaded.global_single_threaded.io();

    const src_z = try allocator.dupeZ(u8, src);
    defer allocator.free(src_z);

    const dst_z = try allocator.dupeZ(u8, dst);
    defer allocator.free(dst_z);

    // Get source directory info
    var src_stat: Stat = undefined;
    _ = stat(src_z.ptr, &src_stat);

    // Create destination directory if it doesn't exist
    if (!fileExists(dst_z)) {
        if (libc.mkdir(dst_z.ptr, src_stat.mode & 0o7777) != 0) {
            printErrorFmt("cannot create directory '{s}': mkdir failed", .{dst});
            return error.MkdirFailed;
        }
        if (config.verbose) {
            printVerboseDir(dst);
        }
    }

    // Open source directory
    var dir = Dir.openDir(Dir.cwd(), io, src, .{ .iterate = true }) catch |err| {
        printErrorFmt("cannot open directory '{s}': {s}", .{ src, @errorName(err) });
        return err;
    };
    defer dir.close(io);

    // Iterate and copy contents
    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        const entry_name = entry.name;

        const src_full = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ src, entry_name });
        defer allocator.free(src_full);

        const dst_full = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dst, entry_name });
        defer allocator.free(dst_full);

        const src_full_z = try allocator.dupeZ(u8, src_full);
        defer allocator.free(src_full_z);

        const file_type = getFileType(src_full_z);
        if (file_type) |ft| {
            switch (ft) {
                .directory => {
                    try copyDirectory(allocator, src_full, dst_full, config);
                },
                .symlink => {
                    if (config.archive) {
                        try copySymlink(allocator, src_full, dst_full, config);
                    } else {
                        // Follow symlinks by default (copy target)
                        try copyFile(allocator, src_full, dst_full, config);
                    }
                },
                .file, .other => {
                    try copyFile(allocator, src_full, dst_full, config);
                },
            }
        }
    }
}

fn copy(allocator: std.mem.Allocator, src: []const u8, dst: []const u8, config: *const Config) !void {
    const src_z = try allocator.dupeZ(u8, src);
    defer allocator.free(src_z);

    const file_type = getFileType(src_z);

    if (file_type == null) {
        printErrorFmt("cannot stat '{s}': No such file or directory", .{src});
        return error.FileNotFound;
    }

    switch (file_type.?) {
        .directory => {
            if (!config.recursive and !config.archive) {
                printErrorFmt("omitting directory '{s}'", .{src});
                return error.IsDir;
            }
            try copyDirectory(allocator, src, dst, config);
        },
        .symlink => {
            if (config.archive) {
                try copySymlink(allocator, src, dst, config);
            } else {
                try copyFile(allocator, src, dst, config);
            }
        },
        .file, .other => {
            try copyFile(allocator, src, dst, config);
        },
    }
}

fn basename(path: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |idx| {
        return path[idx + 1 ..];
    }
    return path;
}

fn printVerbose(src: []const u8, dst: []const u8) void {
    const io = Io.Threaded.global_single_threaded.io();
    var buf: [512]u8 = undefined;
    const stdout = Io.File.stdout();
    var writer = stdout.writer(io, &buf);
    writer.interface.print("'{s}' -> '{s}'\n", .{ src, dst }) catch {};
    writer.interface.flush() catch {};
}

fn printVerboseDir(dst: []const u8) void {
    const io = Io.Threaded.global_single_threaded.io();
    var buf: [512]u8 = undefined;
    const stdout = Io.File.stdout();
    var writer = stdout.writer(io, &buf);
    writer.interface.print("created directory '{s}'\n", .{dst}) catch {};
    writer.interface.flush() catch {};
}

fn printError(msg: []const u8) void {
    std.debug.print("zcp: {s}\n", .{msg});
}

fn printErrorFmt(comptime fmt: []const u8, args: anytype) void {
    std.debug.print("zcp: " ++ fmt ++ "\n", args);
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
                } else if (std.mem.eql(u8, arg, "--recursive")) {
                    config.recursive = true;
                } else if (std.mem.eql(u8, arg, "--force")) {
                    config.force = true;
                } else if (std.mem.eql(u8, arg, "--interactive")) {
                    config.interactive = true;
                } else if (std.mem.eql(u8, arg, "--no-clobber")) {
                    config.no_clobber = true;
                } else if (std.mem.eql(u8, arg, "--verbose")) {
                    config.verbose = true;
                } else if (std.mem.eql(u8, arg, "--preserve")) {
                    config.preserve = true;
                } else if (std.mem.eql(u8, arg, "--archive")) {
                    config.archive = true;
                    config.recursive = true;
                    config.preserve = true;
                } else if (std.mem.eql(u8, arg, "--update")) {
                    config.update = true;
                } else if (std.mem.eql(u8, arg, "--no-target-directory")) {
                    config.no_target_directory = true;
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
                // Short options
                for (arg[1..]) |ch| {
                    switch (ch) {
                        'r', 'R' => config.recursive = true,
                        'f' => config.force = true,
                        'i' => config.interactive = true,
                        'n' => config.no_clobber = true,
                        'v' => config.verbose = true,
                        'p' => config.preserve = true,
                        'a' => {
                            config.archive = true;
                            config.recursive = true;
                            config.preserve = true;
                        },
                        'u' => config.update = true,
                        'T' => config.no_target_directory = true,
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
        // All sources go to target directory
        if (config.sources.items.len == 0) {
            printError("missing file operand");
            std.process.exit(1);
        }
    } else {
        // Last argument is destination
        if (config.sources.items.len < 2) {
            if (config.sources.items.len == 0) {
                printError("missing file operand");
            } else {
                printErrorFmt("missing destination file operand after '{s}'", .{config.sources.items[0]});
            }
            std.debug.print("Try 'zcp --help' for more information.\n", .{});
            std.process.exit(1);
        }

        // Pop last source as destination
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
        \\Usage: zcp [OPTION]... SOURCE... DEST
        \\   or: zcp [OPTION]... -t DIRECTORY SOURCE...
        \\Copy SOURCE to DEST, or multiple SOURCEs to DIRECTORY.
        \\
        \\  -a, --archive           same as -dR --preserve=all
        \\  -f, --force             if existing destination cannot be opened, remove it
        \\  -i, --interactive       prompt before overwrite
        \\  -n, --no-clobber        do not overwrite an existing file
        \\  -p, --preserve          preserve mode, ownership, timestamps
        \\  -r, -R, --recursive     copy directories recursively
        \\  -t, --target-directory=DIR  copy all SOURCEs into DIRECTORY
        \\  -T, --no-target-directory   treat DEST as a normal file
        \\  -u, --update            copy only when SOURCE is newer than destination
        \\                          or when destination is missing
        \\  -v, --verbose           explain what is being done
        \\      --help              display this help and exit
        \\      --version           output version information and exit
        \\
        \\zcp - High-performance file copy utility in Zig
        \\
    ) catch {};
    writer.interface.flush() catch {};
}

fn printVersion() void {
    const io = Io.Threaded.global_single_threaded.io();
    var buf: [64]u8 = undefined;
    const stdout = Io.File.stdout();
    var writer = stdout.writer(io, &buf);
    writer.interface.writeAll("zcp 0.1.0\n") catch {};
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
        // Copy all sources to target directory
        const target_z = allocator.dupeZ(u8, target_dir) catch {
            printError("memory allocation failed");
            std.process.exit(1);
        };
        defer allocator.free(target_z);

        // Check target is a directory
        const target_type = getFileType(target_z);
        if (target_type != .directory) {
            printErrorFmt("target '{s}' is not a directory", .{target_dir});
            std.process.exit(1);
        }

        for (config.sources.items) |src| {
            const dst = std.fmt.allocPrint(allocator, "{s}/{s}", .{ target_dir, basename(src) }) catch {
                printError("memory allocation failed");
                error_occurred = true;
                continue;
            };
            defer allocator.free(dst);

            copy(allocator, src, dst, &config) catch {
                error_occurred = true;
            };
        }
    } else if (config.destination) |dest| {
        const dest_z = allocator.dupeZ(u8, dest) catch {
            printError("memory allocation failed");
            std.process.exit(1);
        };
        defer allocator.free(dest_z);

        const dest_type = getFileType(dest_z);

        if (config.no_target_directory) {
            // -T: treat destination as a normal file, not a directory
            if (config.sources.items.len != 1) {
                printError("extra operand when using -T");
                std.process.exit(1);
            }
            const src = config.sources.items[0];
            copy(allocator, src, dest, &config) catch {
                error_occurred = true;
            };
        } else if (config.sources.items.len == 1) {
            // Single source: cp src dest
            const src = config.sources.items[0];
            if (dest_type == .directory) {
                // Copy into directory
                const dst = std.fmt.allocPrint(allocator, "{s}/{s}", .{ dest, basename(src) }) catch {
                    printError("memory allocation failed");
                    std.process.exit(1);
                };
                defer allocator.free(dst);
                copy(allocator, src, dst, &config) catch {
                    error_occurred = true;
                };
            } else {
                // Copy to file
                copy(allocator, src, dest, &config) catch {
                    error_occurred = true;
                };
            }
        } else {
            // Multiple sources: destination must be a directory
            if (dest_type != .directory) {
                printErrorFmt("target '{s}' is not a directory", .{dest});
                std.process.exit(1);
            }

            for (config.sources.items) |src| {
                const dst = std.fmt.allocPrint(allocator, "{s}/{s}", .{ dest, basename(src) }) catch {
                    printError("memory allocation failed");
                    error_occurred = true;
                    continue;
                };
                defer allocator.free(dst);

                copy(allocator, src, dst, &config) catch {
                    error_occurred = true;
                };
            }
        }
    }

    if (error_occurred) {
        std.process.exit(1);
    }
}
