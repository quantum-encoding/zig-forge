//! zmv - Move (rename) files and directories
//!
//! Compatible with GNU mv (behavior verified against GNU coreutils 9.10):
//! - Move files and directories
//! - -f, --force: do not prompt before overwriting
//! - -i, --interactive: prompt before overwrite
//! - -n, --no-clobber: do not overwrite existing file
//! - -f/-i/-n override each other, last one wins (GNU semantics)
//! - -u, --update: move only when source is newer
//! - -v, --verbose: explain what is being done
//! - -t, --target-directory=DIR: move all SOURCE to DIRECTORY
//! - -T, --no-target-directory: treat DEST as normal file

const std = @import("std");
const builtin = @import("builtin");
const libc = std.c;
const Io = std.Io;
const Dir = Io.Dir;

// Libc functions not exposed through std.c. These take only path/scalar
// arguments, so there is no struct-layout (INODE64) hazard; all stat calls
// below go through std.c.fstatat / std.c.stat which bind the correct
// $INODE64 symbols on x86_64 Darwin.
extern "c" fn strerror(errnum: c_int) ?[*:0]u8;
extern "c" fn mkfifo(path: [*:0]const u8, mode: libc.mode_t) c_int;

fn errnoValue(e: libc.E) c_int {
    return @intFromEnum(e);
}

/// lstat: never follows symlinks (uses std.c.fstatat so the correct
/// $INODE64 variant is bound on x86_64 Darwin).
pub fn lstatPath(path: [:0]const u8) ?libc.Stat {
    var st: libc.Stat = undefined;
    if (libc.fstatat(libc.AT.FDCWD, path.ptr, &st, libc.AT.SYMLINK_NOFOLLOW) != 0) return null;
    return st;
}

/// stat: follows symlinks.
pub fn statPath(path: [:0]const u8) ?libc.Stat {
    var st: libc.Stat = undefined;
    if (libc.fstatat(libc.AT.FDCWD, path.ptr, &st, 0) != 0) return null;
    return st;
}

pub const FileType = enum {
    file,
    directory,
    symlink,
    fifo,
    other,
};

pub fn fileTypeOf(st: libc.Stat) FileType {
    return switch (st.mode & libc.S.IFMT) {
        libc.S.IFREG => .file,
        libc.S.IFDIR => .directory,
        libc.S.IFLNK => .symlink,
        libc.S.IFIFO => .fifo,
        else => .other,
    };
}

/// File type of the link itself (lstat semantics), or null if it does not exist.
pub fn getFileType(path: [:0]const u8) ?FileType {
    const st = lstatPath(path) orelse return null;
    return fileTypeOf(st);
}

fn promptOverwrite(dest: []const u8) bool {
    // Write prompt to stderr (fd 2); GNU mv prompts on stderr without newline.
    const prefix = "zmv: overwrite '";
    const suffix = "'? ";
    _ = std.c.write(2, prefix.ptr, prefix.len);
    _ = std.c.write(2, dest.ptr, dest.len);
    _ = std.c.write(2, suffix.ptr, suffix.len);
    return readYes();
}

/// GNU mv prompts "replace 'x', overriding mode ..." when the destination
/// exists but is not writable, -f was not given, and stdin is a tty.
fn promptReplaceMode(dest: []const u8, mode: u32) bool {
    var buf: [1024]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "zmv: replace '{s}', overriding mode {o:0>4}? ", .{ dest, mode & 0o7777 }) catch return false;
    _ = std.c.write(2, msg.ptr, msg.len);
    return readYes();
}

fn readYes() bool {
    var buf: [128]u8 = undefined;
    const n = std.c.read(0, &buf, buf.len);
    if (n <= 0) return false;
    return (buf[0] == 'y' or buf[0] == 'Y');
}

fn getFileMtime(path: [:0]const u8) ?i128 {
    const st = lstatPath(path) orelse return null;
    const ts = st.mtime();
    return @as(i128, ts.sec) * 1_000_000_000 + ts.nsec;
}

fn sourceIsNewer(src_z: [:0]const u8, dst_z: [:0]const u8) bool {
    const src_mtime = getFileMtime(src_z) orelse return true;
    const dst_mtime = getFileMtime(dst_z) orelse return true;
    return src_mtime > dst_mtime;
}

/// GNU "same file" rule as observed against coreutils 9.10:
/// - same (dev, ino) by lstat (covers `mv s s` and hardlinks) -> same file
/// - source is a symlink whose referent is the destination -> same file
///   (`mv link target` errors, while `mv target link` replaces the link).
fn isSameFile(src_z: [:0]const u8, dst_st: libc.Stat) bool {
    const src_st = lstatPath(src_z) orelse return false;
    if (src_st.dev == dst_st.dev and src_st.ino == dst_st.ino) return true;
    if (fileTypeOf(src_st) == .symlink) {
        if (statPath(src_z)) |resolved| {
            if (resolved.dev == dst_st.dev and resolved.ino == dst_st.ino) return true;
        }
    }
    return false;
}

pub const Config = struct {
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

pub fn moveFile(allocator: std.mem.Allocator, src: []const u8, dst: []const u8, config: *const Config) !void {
    const src_z = try allocator.dupeZ(u8, src);
    defer allocator.free(src_z);

    const dst_z = try allocator.dupeZ(u8, dst);
    defer allocator.free(dst_z);

    // Source existence via lstat: a dangling symlink is a movable entity
    // (GNU mv moves dangling symlinks; access(2) would wrongly follow them).
    const src_st = lstatPath(src_z) orelse {
        printErrorFmt("cannot stat '{s}': No such file or directory", .{src});
        return error.FileNotFound;
    };
    const src_type = fileTypeOf(src_st);

    // Destination existence also via lstat: a symlink (even dangling) counts
    // as an existing destination entry for overwrite decisions.
    if (lstatPath(dst_z)) |dst_st| {
        // Order verified against GNU mv 9.10:
        //   -n skips silently (even for the same file, exit 0),
        //   then the same-file check (beats -u/-i/-f, exit 1),
        //   then -u, then the -i prompt, then dir/non-dir conflicts.
        if (config.no_clobber) {
            return; // Don't overwrite
        }
        if (isSameFile(src_z, dst_st)) {
            printErrorFmt("'{s}' and '{s}' are the same file", .{ src, dst });
            return error.SameFile;
        }
        if (config.update) {
            if (!sourceIsNewer(src_z, dst_z)) {
                return; // Destination is newer or same age, skip
            }
        }
        if (config.interactive) {
            if (!promptOverwrite(dst)) {
                // GNU mv 9.10 exits 1 when an overwrite prompt is declined.
                return error.PromptDeclined;
            }
        } else if (!config.force) {
            // POSIX: prompt for an unwritable destination only when stdin is
            // a tty; otherwise behave as -f. rename(2) itself does not need
            // W_OK on the destination.
            if (libc.isatty(0) == 1 and libc.access(dst_z.ptr, 2) != 0) { // W_OK = 2
                if (!promptReplaceMode(dst, dst_st.mode)) {
                    return error.PromptDeclined;
                }
            }
        }

        const dst_type = fileTypeOf(dst_st);
        if (src_type == .directory and dst_type != .directory) {
            printErrorFmt("cannot overwrite non-directory '{s}' with directory '{s}'", .{ dst, src });
            return error.CannotOverwrite;
        }
        if (src_type != .directory and dst_type == .directory) {
            printErrorFmt("cannot overwrite directory '{s}' with non-directory '{s}'", .{ dst, src });
            return error.CannotOverwrite;
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

    const err = libc._errno().*;
    if (err == errnoValue(.XDEV)) {
        // Cross-device: fall back to copy + delete
        try copyAndDelete(allocator, src, dst, src_z, dst_z, config);
        return;
    }
    if (err == errnoValue(.INVAL)) {
        // rename(2) EINVAL: moving a directory into itself
        printErrorFmt("cannot move '{s}' to a subdirectory of itself, '{s}'", .{ src, dst });
        return error.RenameFailed;
    }
    if (err == errnoValue(.NOTEMPTY) or err == errnoValue(.EXIST)) {
        // dir-over-dir rename onto a non-empty directory
        printErrorFmt("cannot overwrite '{s}': Directory not empty", .{dst});
        return error.RenameFailed;
    }

    printErrorFmt("cannot move '{s}' to '{s}': {s}", .{ src, dst, errnoToString(err) });
    return error.RenameFailed;
}

pub fn copyAndDelete(allocator: std.mem.Allocator, src: []const u8, dst: []const u8, src_z: [:0]const u8, dst_z: [:0]const u8, config: *const Config) !void {
    const io = Io.Threaded.global_single_threaded.io();

    const src_type = getFileType(src_z) orelse {
        printErrorFmt("cannot stat '{s}': No such file or directory", .{src});
        return error.FileNotFound;
    };

    switch (src_type) {
        .directory => {
            try copyDirectoryRecursive(allocator, src, dst, config);
            try deleteDirectoryRecursive(allocator, src);
        },
        .file => {
            try copyFileContents(io, src, dst, src_z, dst_z);
            try unlinkSource(src, src_z);
        },
        .symlink => {
            // Recreate the link itself; never copy through it (a symlink in a
            // moved tree must stay a symlink, and must not leak its target's
            // contents).
            try copySymlink(src, dst, src_z, dst_z);
            try unlinkSource(src, src_z);
        },
        .fifo => {
            try copyFifo(src, dst, src_z, dst_z);
            try unlinkSource(src, src_z);
        },
        .other => {
            // Sockets/devices: refuse instead of open(2)ing them (opening a
            // FIFO/socket can block forever; devices would be content-copied).
            printErrorFmt("cannot move '{s}' to '{s}': Operation not supported", .{ src, dst });
            return error.UnsupportedFileType;
        },
    }

    if (config.verbose) {
        printVerbose(src, dst);
    }
}

fn unlinkSource(src: []const u8, src_z: [:0]const u8) !void {
    if (libc.unlink(src_z.ptr) != 0) {
        printErrorFmt("cannot remove '{s}': {s}", .{ src, errnoToString(libc._errno().*) });
        return error.UnlinkFailed;
    }
}

fn copySymlink(src: []const u8, dst: []const u8, src_z: [:0]const u8, dst_z: [:0]const u8) !void {
    var target_buf: [4096]u8 = undefined;
    const n = libc.readlink(src_z.ptr, &target_buf, target_buf.len - 1);
    if (n < 0) {
        printErrorFmt("cannot read symbolic link '{s}': {s}", .{ src, errnoToString(libc._errno().*) });
        return error.ReadLinkFailed;
    }
    target_buf[@intCast(n)] = 0;
    const target: [*:0]const u8 = @ptrCast(&target_buf);

    // Replace any existing destination entry, like rename(2) would.
    _ = libc.unlink(dst_z.ptr);
    if (libc.symlink(target, dst_z.ptr) != 0) {
        printErrorFmt("cannot create symbolic link '{s}': {s}", .{ dst, errnoToString(libc._errno().*) });
        return error.SymLinkFailed;
    }
}

fn copyFifo(src: []const u8, dst: []const u8, src_z: [:0]const u8, dst_z: [:0]const u8) !void {
    const st = lstatPath(src_z) orelse {
        printErrorFmt("cannot stat '{s}': No such file or directory", .{src});
        return error.FileNotFound;
    };
    _ = libc.unlink(dst_z.ptr);
    if (mkfifo(dst_z.ptr, @intCast(st.mode & 0o7777)) != 0) {
        printErrorFmt("cannot create fifo '{s}': {s}", .{ dst, errnoToString(libc._errno().*) });
        return error.MkFifoFailed;
    }
}

fn copyFileContents(io: Io, src: []const u8, dst: []const u8, src_z: [:0]const u8, dst_z: [:0]const u8) !void {
    _ = dst_z;

    // Get source file info for permissions; propagate failure instead of
    // reading an undefined mode (TOCTOU: source may vanish under us).
    const src_st = lstatPath(src_z) orelse {
        printErrorFmt("cannot stat '{s}': No such file or directory", .{src});
        return error.FileNotFound;
    };

    // Open source file
    const src_file = Dir.openFile(Dir.cwd(), io, src, .{}) catch |err| {
        printErrorFmt("cannot open '{s}': {s}", .{ src, @errorName(err) });
        return err;
    };
    defer src_file.close(io);

    // Create destination file
    const dst_file = Dir.createFile(Dir.cwd(), io, dst, .{ .truncate = true }) catch |err| {
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

    try dst_writer.interface.flush();

    // Preserve permissions on the open handle (chmod-by-path would follow a
    // racily-substituted symlink).
    _ = libc.fchmod(dst_file.handle, @intCast(src_st.mode & 0o7777));
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

pub fn copyDirectoryRecursive(allocator: std.mem.Allocator, src: []const u8, dst: []const u8, config: *const Config) !void {
    const io = Io.Threaded.global_single_threaded.io();

    const src_z = try allocator.dupeZ(u8, src);
    defer allocator.free(src_z);

    const dst_z = try allocator.dupeZ(u8, dst);
    defer allocator.free(dst_z);

    // Get source directory permissions; propagate failure instead of passing
    // an undefined mode to mkdir.
    const src_st = lstatPath(src_z) orelse {
        printErrorFmt("cannot stat '{s}': No such file or directory", .{src});
        return error.FileNotFound;
    };

    // Create destination directory
    if (lstatPath(dst_z) == null) {
        if (libc.mkdir(dst_z.ptr, @intCast(src_st.mode & 0o7777)) != 0) {
            printErrorFmt("cannot create directory '{s}': {s}", .{ dst, errnoToString(libc._errno().*) });
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
                .file => try copyFileContents(io, src_full, dst_full, src_full_z, dst_full_z),
                .symlink => try copySymlink(src_full, dst_full, src_full_z, dst_full_z),
                .fifo => try copyFifo(src_full, dst_full, src_full_z, dst_full_z),
                .other => {
                    printErrorFmt("cannot move '{s}' to '{s}': Operation not supported", .{ src_full, dst_full });
                    return error.UnsupportedFileType;
                },
            }
        }
    }
}

pub fn deleteDirectoryRecursive(allocator: std.mem.Allocator, path: []const u8) !void {
    const io = Io.Threaded.global_single_threaded.io();

    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);

    // Open and iterate; propagate failures so a half-deleted source is
    // reported (exit 1) instead of silently claiming success.
    var dir = Dir.openDir(Dir.cwd(), io, path, .{ .iterate = true }) catch |err| {
        printErrorFmt("cannot remove '{s}': {s}", .{ path, @errorName(err) });
        return err;
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
                .file, .symlink, .fifo, .other => try unlinkSource(full_path, full_path_z),
            }
        }
    }

    // Remove the now-empty directory
    Dir.deleteDir(Dir.cwd(), io, path_z) catch |err| {
        printErrorFmt("cannot remove '{s}': {s}", .{ path, @errorName(err) });
        return err;
    };
}

/// Basename with GNU semantics: trailing slashes are ignored
/// (`mv dir/ dest` moves as `dest/dir`, not `dest/`).
pub fn basename(path: []const u8) []const u8 {
    var end = path.len;
    while (end > 0 and path[end - 1] == '/') end -= 1;
    if (end == 0) return path; // path was "/" or all slashes
    const start = if (std.mem.lastIndexOfScalar(u8, path[0..end], '/')) |idx| idx + 1 else 0;
    return path[start..end];
}

fn errnoToString(err: c_int) []const u8 {
    // Host libc strerror: correct errno numbering on every platform
    // (a hand-numbered Linux table printed 'Unknown error' on macOS).
    if (strerror(err)) |s| return std.mem.span(s);
    return "Unknown error";
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

fn printTryHelp() void {
    std.debug.print("Try 'zmv --help' for more information.\n", .{});
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
                    setClobberMode(&config, .force);
                } else if (std.mem.eql(u8, arg, "--interactive")) {
                    setClobberMode(&config, .interactive);
                } else if (std.mem.eql(u8, arg, "--no-clobber")) {
                    setClobberMode(&config, .no_clobber);
                } else if (std.mem.eql(u8, arg, "--update")) {
                    config.update = true;
                } else if (std.mem.eql(u8, arg, "--verbose")) {
                    config.verbose = true;
                } else if (std.mem.eql(u8, arg, "--no-target-directory")) {
                    config.no_target_directory = true;
                } else if (std.mem.startsWith(u8, arg, "--target-directory=")) {
                    if (config.target_directory) |old| allocator.free(old);
                    config.target_directory = try allocator.dupe(u8, arg[19..]);
                } else if (std.mem.eql(u8, arg, "--target-directory")) {
                    i += 1;
                    if (i >= args.len) {
                        printError("option '--target-directory' requires an argument");
                        printTryHelp();
                        std.process.exit(1);
                    }
                    if (config.target_directory) |old| allocator.free(old);
                    config.target_directory = try allocator.dupe(u8, args[i]);
                } else if (std.mem.eql(u8, arg, "--")) {
                    i += 1;
                    while (i < args.len) : (i += 1) {
                        try config.sources.append(allocator, try allocator.dupe(u8, args[i]));
                    }
                    break;
                } else {
                    printErrorFmt("unrecognized option '{s}'", .{arg});
                    printTryHelp();
                    std.process.exit(1);
                }
            } else {
                for (arg[1..]) |ch| {
                    switch (ch) {
                        'f' => setClobberMode(&config, .force),
                        'i' => setClobberMode(&config, .interactive),
                        'n' => setClobberMode(&config, .no_clobber),
                        'u' => config.update = true,
                        'v' => config.verbose = true,
                        'T' => config.no_target_directory = true,
                        't' => {
                            i += 1;
                            if (i >= args.len) {
                                printError("option requires an argument -- 't'");
                                printTryHelp();
                                std.process.exit(1);
                            }
                            if (config.target_directory) |old| allocator.free(old);
                            config.target_directory = try allocator.dupe(u8, args[i]);
                        },
                        else => {
                            printErrorFmt("invalid option -- '{c}'", .{ch});
                            printTryHelp();
                            std.process.exit(1);
                        },
                    }
                }
            }
        } else {
            try config.sources.append(allocator, try allocator.dupe(u8, arg));
        }
    }

    // GNU rejects combining -t with -T.
    if (config.target_directory != null and config.no_target_directory) {
        printError("cannot combine --target-directory (-t) and --no-target-directory (-T)");
        std.process.exit(1);
    }

    // Handle target directory mode vs normal mode
    if (config.target_directory) |_| {
        if (config.sources.items.len == 0) {
            printError("missing file operand");
            printTryHelp();
            std.process.exit(1);
        }
    } else {
        if (config.sources.items.len < 2) {
            if (config.sources.items.len == 0) {
                printError("missing file operand");
            } else {
                printErrorFmt("missing destination file operand after '{s}'", .{config.sources.items[0]});
            }
            printTryHelp();
            std.process.exit(1);
        }
        config.destination = config.sources.pop();
    }

    return config;
}

const ClobberMode = enum { force, interactive, no_clobber };

/// -f/-i/-n override each other; the last one on the command line wins
/// (GNU getopt semantics).
fn setClobberMode(config: *Config, mode: ClobberMode) void {
    config.force = mode == .force;
    config.interactive = mode == .interactive;
    config.no_clobber = mode == .no_clobber;
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
        \\If you specify more than one of -i, -f, -n, only the final one takes effect.
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
    writer.interface.writeAll("zmv 0.2.0\n") catch {};
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

        // Follow symlinks: -t pointing at a symlink-to-directory is valid.
        if (statPath(target_z)) |st| {
            if (fileTypeOf(st) != .directory) {
                printErrorFmt("target directory '{s}': Not a directory", .{target_dir});
                std.process.exit(1);
            }
        } else {
            printErrorFmt("target directory '{s}': No such file or directory", .{target_dir});
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

        // Directory-ness of the destination follows symlinks (GNU: a symlink
        // to a directory receives the file inside the referenced directory;
        // it is never replaced by rename).
        const dest_st = statPath(dest_z);
        const dest_is_dir = if (dest_st) |st| fileTypeOf(st) == .directory else false;

        if (config.no_target_directory) {
            // -T: treat destination as a normal file, not a directory
            if (config.sources.items.len != 1) {
                // Operand order was SOURCE DEST EXTRA...; report the first extra.
                const extra = if (config.sources.items.len >= 3) config.sources.items[2] else dest;
                printErrorFmt("extra operand '{s}'", .{extra});
                printTryHelp();
                std.process.exit(1);
            }
            const src = config.sources.items[0];
            moveFile(allocator, src, dest, &config) catch {
                error_occurred = true;
            };
        } else if (config.sources.items.len == 1) {
            const src = config.sources.items[0];
            if (dest_is_dir) {
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
            if (dest_st == null) {
                printErrorFmt("target '{s}': No such file or directory", .{dest});
                std.process.exit(1);
            }
            if (!dest_is_dir) {
                printErrorFmt("target '{s}': Not a directory", .{dest});
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
