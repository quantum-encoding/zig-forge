//! zreadlink - Print symbolic link target or canonical path
//!
//! High-performance readlink implementation in Zig.

const std = @import("std");
const posix = std.posix;
const libc = std.c;

const VERSION = "1.0.0";

extern "c" fn readlink(path: [*:0]const u8, buf: [*]u8, bufsiz: usize) isize;
extern "c" fn realpath(path: [*:0]const u8, resolved: ?[*]u8) ?[*:0]u8;
extern "c" fn lstat(path: [*:0]const u8, buf: *Stat) c_int;

const Stat = extern struct {
    st_dev: u64,
    st_ino: u64,
    st_nlink: u64,
    st_mode: u32,
    st_uid: u32,
    st_gid: u32,
    __pad0: u32,
    st_rdev: u64,
    st_size: i64,
    st_blksize: i64,
    st_blocks: i64,
    st_atime: i64,
    st_atime_nsec: i64,
    st_mtime: i64,
    st_mtime_nsec: i64,
    st_ctime: i64,
    st_ctime_nsec: i64,
    __unused: [3]i64,
};

const S_IFMT: u32 = 0o170000;
const S_IFLNK: u32 = 0o120000;

const Mode = enum {
    raw,           // Just read symlink
    canonicalize,  // -f: resolve all, don't require existence
    canon_exist,   // -e: resolve all, must exist
    canon_missing, // -m: resolve all, allow missing
};

const Config = struct {
    mode: Mode = .raw,
    no_newline: bool = false,
    zero: bool = false,
    verbose: bool = false,
    files: [64][]const u8 = undefined,
    file_count: usize = 0,
};

fn writeStdout(data: []const u8) void {
    _ = libc.write(libc.STDOUT_FILENO, data.ptr, data.len);
}

fn writeStderr(data: []const u8) void {
    _ = libc.write(libc.STDERR_FILENO, data.ptr, data.len);
}

fn printUsage() void {
    const usage =
        \\Usage: zreadlink [OPTION]... FILE...
        \\Print value of a symbolic link or canonical file name.
        \\
        \\Options:
        \\  -f, --canonicalize      Canonicalize by following all symlinks
        \\  -e, --canonicalize-existing  Like -f, all components must exist
        \\  -m, --canonicalize-missing   Like -f, missing components allowed
        \\  -n, --no-newline        Do not output trailing newline
        \\  -v, --verbose           Report error messages
        \\  -z, --zero              End each output line with NUL, not newline
        \\      --help              Display this help and exit
        \\      --version           Output version information and exit
        \\
    ;
    writeStderr(usage);
}

fn printVersion() void {
    writeStderr("zreadlink " ++ VERSION ++ "\n");
}

fn readSymlink(path: []const u8, buf: []u8) ?[]const u8 {
    var path_buf: [4096]u8 = undefined;
    const path_z = std.fmt.bufPrintZ(&path_buf, "{s}", .{path}) catch return null;

    const result = readlink(path_z, buf.ptr, buf.len);
    if (result < 0) return null;
    return buf[0..@intCast(result)];
}

fn getCanonical(path: []const u8, buf: []u8) ?[]const u8 {
    var path_buf: [4096]u8 = undefined;
    const path_z = std.fmt.bufPrintZ(&path_buf, "{s}", .{path}) catch return null;

    const result = realpath(path_z, buf.ptr);
    if (result == null) return null;

    // Find length of result
    var len: usize = 0;
    while (len < buf.len and buf[len] != 0) : (len += 1) {}
    return buf[0..len];
}

fn isSymlink(path: []const u8) bool {
    var path_buf: [4096]u8 = undefined;
    const path_z = std.fmt.bufPrintZ(&path_buf, "{s}", .{path}) catch return false;

    var st: Stat = undefined;
    if (lstat(path_z, &st) != 0) return false;
    return (st.st_mode & S_IFMT) == S_IFLNK;
}

fn processFile(path: []const u8, cfg: *const Config) bool {
    var buf: [4096]u8 = undefined;

    const result: ?[]const u8 = switch (cfg.mode) {
        .raw => readSymlink(path, &buf),
        .canonicalize, .canon_exist, .canon_missing => getCanonical(path, &buf),
    };

    if (result) |target| {
        writeStdout(target);
        if (cfg.zero) {
            writeStdout("\x00");
        } else if (!cfg.no_newline) {
            writeStdout("\n");
        }
        return true;
    } else {
        if (cfg.verbose) {
            writeStderr("zreadlink: ");
            writeStderr(path);
            if (cfg.mode == .raw) {
                writeStderr(": not a symbolic link or read error\n");
            } else {
                writeStderr(": cannot resolve path\n");
            }
        }
        return false;
    }
}

pub fn main(init: std.process.Init) void {
    var cfg = Config{};

    var args_iter = std.process.Args.Iterator.init(init.minimal.args);
    _ = args_iter.next(); // skip program name

    while (args_iter.next()) |arg| {

        if (std.mem.eql(u8, arg, "--help")) {
            printUsage();
            return;
        } else if (std.mem.eql(u8, arg, "--version")) {
            printVersion();
            return;
        } else if (std.mem.eql(u8, arg, "-f") or std.mem.eql(u8, arg, "--canonicalize")) {
            cfg.mode = .canonicalize;
        } else if (std.mem.eql(u8, arg, "-e") or std.mem.eql(u8, arg, "--canonicalize-existing")) {
            cfg.mode = .canon_exist;
        } else if (std.mem.eql(u8, arg, "-m") or std.mem.eql(u8, arg, "--canonicalize-missing")) {
            cfg.mode = .canon_missing;
        } else if (std.mem.eql(u8, arg, "-n") or std.mem.eql(u8, arg, "--no-newline")) {
            cfg.no_newline = true;
        } else if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--verbose")) {
            cfg.verbose = true;
        } else if (std.mem.eql(u8, arg, "-z") or std.mem.eql(u8, arg, "--zero")) {
            cfg.zero = true;
        } else if (arg.len > 0 and arg[0] != '-') {
            if (cfg.file_count < cfg.files.len) {
                cfg.files[cfg.file_count] = arg;
                cfg.file_count += 1;
            }
        } else if (std.mem.eql(u8, arg, "--")) {
            while (args_iter.next()) |file_arg| {
                if (cfg.file_count < cfg.files.len) {
                    cfg.files[cfg.file_count] = file_arg;
                    cfg.file_count += 1;
                }
            }
            break;
        } else {
            writeStderr("zreadlink: unrecognized option '");
            writeStderr(arg);
            writeStderr("'\n");
            std.process.exit(1);
        }
    }

    if (cfg.file_count == 0) {
        writeStderr("zreadlink: missing operand\n");
        writeStderr("Try 'zreadlink --help' for more information.\n");
        std.process.exit(1);
    }

    var all_ok = true;
    for (cfg.files[0..cfg.file_count]) |path| {
        if (!processFile(path, &cfg)) {
            all_ok = false;
        }
    }

    if (!all_ok) {
        std.process.exit(1);
    }
}
