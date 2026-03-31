//! zmv - Move (rename) files and directories
//!
//! Compatible with GNU mv:
//! - Move files and directories
//! - -f, --force: do not prompt before overwriting
//! - -i, --interactive: prompt before overwrite
//! - -n, --no-clobber: do not overwrite existing file
//! - -u, --update: move only when source is newer
//! - -v, --verbose: explain what is being done
//! - -t, --target-directory=DIR: move all SOURCE to DIRECTORY
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
extern "c" fn chmod(path: [*:0]const u8, mode: libc.mode_t) c_int;

fn promptOverwrite(dest: []const u8) bool {
    // Write prompt to stderr (fd 2)
    const prefix = "zmv: overwrite '";
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

fn getFileMtime(path: [:0]const u8) ?i128 {
    var stat_buf: Stat = undefined;
    const result = lstat(path.ptr, &stat_buf);
    if (result != 0) return null;
    return @as(i128, stat_buf.mtim.sec) * 1_000_000_000 + stat_buf.mtim.nsec;
}

fn sourceIsNewer(src_z: [:0]const u8, dst_z: [:0]const u8) bool {
    const src_mtime = getFileMtime(src_z) orelse return true;
    const dst_mtime = getFileMtime(dst_z) orelse return true;
    return src_mtime > dst_mtime;
}

// Mode constants
const S_IFMT: u32 = 0o170000;
const S_IFREG: u32 = 0o100000;
const S_IFDIR: u32 = 0o40000;
const S_IFLNK: u32 = 0o120000;

const Config = struct {
    force: bool = false,
    interactive: bool = false,
    no_clobber: bool = false,
    update: bool = false,
    verbose: bool = false,
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

fn moveFile(allocator: std.mem.Allocator, src: []const u8, dst: []const u8, config: *const Config) !void {
    const src_z = try allocator.dupeZ(u8, src);
    defer allocator.free(src_z);

    const dst_z = try allocator.dupeZ(u8, dst);
    defer allocator.free(dst_z);

    // Check if source exists
    if (!fileExists(src_z)) {
        printErrorFmt("cannot stat '{s}': No such file or directory", .{src});
        return error.FileNotFound;
    }

    // Check if destination exists
    if (fileExists(dst_z)) {
        if (config.no_clobber) {
            return; // Don't overwrite
        }
        // Update mode: skip if source is not newer than destination
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
                printErrorFmt("cannot move to '{s}': Permission denied", .{dst});
                return error.AccessDenied;
            }
        }
    }

    // Try rename first (fast path for same filesystem)
    const rename_result = libc.rename(src_z.ptr, dst_z.ptr);
    if (rename_result == 0) {
        if (config.verbose) {
            printVerbose(src, dst);
        }
        return;
    }

    // Check if it's a cross-device error
    const err = libc._errno().*;
    if (err == 18) { // EXDEV - cross-device link
        // Fall back to copy + delete
        try copyAndDelete(allocator, src, dst, src_z, dst_z, config);
        return;
    }

    // Other error
    printErrorFmt("cannot move '{s}' to '{s}': {s}", .{ src, dst, errnoToString(err) });
    return error.RenameFailed;
}

fn copyAndDelete(allocator: std.mem.Allocator, src: []const u8, dst: []const u8, src_z: [:0]const u8, dst_z: [:0]const u8, config: *const Config) !void {
    const io = Io.Threaded.global_single_threaded.io();

    const src_type = getFileType(src_z);
    if (src_type == null) {
        printErrorFmt("cannot stat '{s}': No such file or directory", .{src});
        return error.FileNotFound;
    }

    switch (src_type.?) {
        .directory => {
            try copyDirectoryRecursive(allocator, src, dst, config);
            try deleteDirectoryRecursive(allocator, src);
        },
        .file, .symlink, .other => {
            try copyFileContents(allocator, io, src, dst, src_z, dst_z);
            // Delete source
            if (unlink(src_z.ptr) != 0) {
                printErrorFmt("cannot remove '{s}'", .{src});
                return error.UnlinkFailed;
            }
        },
    }

    if (config.verbose) {
        printVerbose(src, dst);
    }
}

fn copyFileContents(allocator: std.mem.Allocator, io: Io, src: []const u8, dst: []const u8, src_z: [:0]const u8, dst_z: [:0]const u8) !void {
    _ = allocator;

    // Get source file info for permissions
    var src_stat: Stat = undefined;
    _ = lstat(src_z.ptr, &src_stat);

    // Open source file
    const src_file = Dir.openFile(Dir.cwd(), io, src, .{}) catch |err| {
        printErrorFmt("cannot open '{s}': {s}", .{ src, @errorName(err) });
        return err;
    };
    defer src_file.close(io);

    // Create destination file
    const dst_file = Dir.createFile(Dir.cwd(), io, dst_z, .{ .truncate = true }) catch |err| {
        printErrorFmt("cannot create '{s}': {s}", .{ dst, @errorName(err) });
        return err;
    };
    defer dst_file.close(io);

    // Use zero-copy transfer
    var read_buf: [65536]u8 = undefined;
    var write_buf: [65536]u8 = undefined;

    var src_reader = src_file.reader(io, &read_buf);
    var dst_writer = dst_file.writer(io, &write_buf);

    while (true) {
        const n = dst_writer.interface.sendFile(&src_reader, .unlimited) catch |err| switch (err) {
            error.EndOfStream => break,
            error.Unimplemented => {
                // Fallback to regular read/write
                try copyFileFallback(io, src_file, dst_file);
                break;
            },
            else => return err,
        };
        if (n == 0) break;
    }

    dst_writer.interface.flush() catch {};

    // Preserve permissions
    _ = chmod(dst_z.ptr, src_stat.mode & 0o7777);
}

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

fn copyDirectoryRecursive(allocator: std.mem.Allocator, src: []const u8, dst: []const u8, config: *const Config) !void {
    const io = Io.Threaded.global_single_threaded.io();

    const src_z = try allocator.dupeZ(u8, src);
    defer allocator.free(src_z);

    const dst_z = try allocator.dupeZ(u8, dst);
    defer allocator.free(dst_z);

    // Get source directory permissions
    var src_stat: Stat = undefined;
    _ = lstat(src_z.ptr, &src_stat);

    // Create destination directory
    if (!fileExists(dst_z)) {
        if (libc.mkdir(dst_z.ptr, src_stat.mode & 0o7777) != 0) {
            printErrorFmt("cannot create directory '{s}': mkdir failed", .{dst});
            return error.MkdirFailed;
        }
    }

    // Open and iterate source directory
    var dir = Dir.openDir(Dir.cwd(), io, src, .{ .iterate = true }) catch |err| {
        printErrorFmt("cannot open directory '{s}': {s}", .{ src, @errorName(err) });
        return err;
    };
    defer dir.close(io);

    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        const src_full = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ src, entry.name });
        defer allocator.free(src_full);

        const dst_full = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dst, entry.name });
        defer allocator.free(dst_full);

        const src_full_z = try allocator.dupeZ(u8, src_full);
        defer allocator.free(src_full_z);

        const dst_full_z = try allocator.dupeZ(u8, dst_full);
        defer allocator.free(dst_full_z);

        const file_type = getFileType(src_full_z);
        if (file_type) |ft| {
            switch (ft) {
                .directory => try copyDirectoryRecursive(allocator, src_full, dst_full, config),
                .file, .symlink, .other => try copyFileContents(allocator, io, src_full, dst_full, src_full_z, dst_full_z),
            }
        }
    }
}

fn deleteDirectoryRecursive(allocator: std.mem.Allocator, path: []const u8) !void {
    const io = Io.Threaded.global_single_threaded.io();

    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);

    // Open and iterate
    var dir = Dir.openDir(Dir.cwd(), io, path, .{ .iterate = true }) catch {
        return;
    };
    defer dir.close(io);

    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        const full_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ path, entry.name });
        defer allocator.free(full_path);

        const full_path_z = try allocator.dupeZ(u8, full_path);
        defer allocator.free(full_path_z);

        const file_type = getFileType(full_path_z);
        if (file_type) |ft| {
            switch (ft) {
                .directory => try deleteDirectoryRecursive(allocator, full_path),
                .file, .symlink, .other => _ = unlink(full_path_z.ptr),
            }
        }
    }

    // Remove the now-empty directory
    Dir.deleteDir(Dir.cwd(), io, path_z) catch {};
}

fn basename(path: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |idx| {
        return path[idx + 1 ..];
    }
    return path;
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
        39 => "Directory not empty",
        else => "Unknown error",
    };
}

fn printVerbose(src: []const u8, dst: []const u8) void {
    const io = Io.Threaded.global_single_threaded.io();
    var buf: [512]u8 = undefined;
    const stdout = Io.File.stdout();
    var writer = stdout.writer(io, &buf);
    writer.interface.print("renamed '{s}' -> '{s}'\n", .{ src, dst }) catch {};
    writer.interface.flush() catch {};
}

fn printError(msg: []const u8) void {
    std.debug.print("zmv: {s}\n", .{msg});
}

fn printErrorFmt(comptime fmt: []const u8, args: anytype) void {
    std.debug.print("zmv: " ++ fmt ++ "\n", args);
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
                } else if (std.mem.eql(u8, arg, "--interactive")) {
                    config.interactive = true;
                } else if (std.mem.eql(u8, arg, "--no-clobber")) {
                    config.no_clobber = true;
                } else if (std.mem.eql(u8, arg, "--update")) {
                    config.update = true;
                } else if (std.mem.eql(u8, arg, "--verbose")) {
                    config.verbose = true;
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
                for (arg[1..]) |ch| {
                    switch (ch) {
                        'f' => config.force = true,
                        'i' => config.interactive = true,
                        'n' => config.no_clobber = true,
                        'u' => config.update = true,
                        'v' => config.verbose = true,
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
            std.debug.print("Try 'zmv --help' for more information.\n", .{});
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
        \\Usage: zmv [OPTION]... SOURCE... DEST
        \\   or: zmv [OPTION]... -t DIRECTORY SOURCE...
        \\Rename SOURCE to DEST, or move SOURCE(s) to DIRECTORY.
        \\
        \\  -f, --force             do not prompt before overwriting
        \\  -i, --interactive       prompt before overwrite
        \\  -n, --no-clobber        do not overwrite an existing file
        \\  -u, --update            move only when SOURCE is newer than destination
        \\  -t, --target-directory=DIR  move all SOURCEs into DIRECTORY
        \\  -T, --no-target-directory   treat DEST as a normal file
        \\  -v, --verbose           explain what is being done
        \\      --help              display this help and exit
        \\      --version           output version information and exit
        \\
        \\zmv - High-performance file move utility in Zig
        \\
    ) catch {};
    writer.interface.flush() catch {};
}

fn printVersion() void {
    const io = Io.Threaded.global_single_threaded.io();
    var buf: [64]u8 = undefined;
    const stdout = Io.File.stdout();
    var writer = stdout.writer(io, &buf);
    writer.interface.writeAll("zmv 0.1.0\n") catch {};
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

            moveFile(allocator, src, dst, &config) catch {
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
            moveFile(allocator, src, dest, &config) catch {
                error_occurred = true;
            };
        } else if (config.sources.items.len == 1) {
            const src = config.sources.items[0];
            if (dest_type == .directory) {
                const dst = std.fmt.allocPrint(allocator, "{s}/{s}", .{ dest, basename(src) }) catch {
                    printError("memory allocation failed");
                    std.process.exit(1);
                };
                defer allocator.free(dst);
                moveFile(allocator, src, dst, &config) catch {
                    error_occurred = true;
                };
            } else {
                moveFile(allocator, src, dest, &config) catch {
                    error_occurred = true;
                };
            }
        } else {
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

                moveFile(allocator, src, dst, &config) catch {
                    error_occurred = true;
                };
            }
        }
    }

    if (error_occurred) {
        std.process.exit(1);
    }
}
