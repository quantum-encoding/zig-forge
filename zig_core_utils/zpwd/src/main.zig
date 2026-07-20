//! zpwd - Print working directory
//!
//! High-performance pwd implementation in Zig.
//! Supports both logical (-L) and physical (-P) modes.
//!
//! Behavior tracks GNU coreutils `pwd` (9.x):
//!   * default mode is PHYSICAL; POSIXLY_CORRECT flips the default to LOGICAL
//!   * -L / --logical uses $PWD only when it is an absolute path free of
//!     "." and ".." components AND names the same dir as "." (dev+ino match),
//!     else it falls back to the physical path
//!   * --help / --version are written to STDOUT with exit 0
//!   * a bare "--" ends option parsing; other non-option operands are ignored
//!     with a diagnostic

const std = @import("std");
const libc = std.c;

extern "c" fn getcwd(buf: [*]u8, size: usize) ?[*:0]u8;
extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;
extern "c" fn stat(path: [*:0]const u8, buf: *std.c.Stat) c_int;

const VERSION = "1.0.0";
const PATH_MAX = 4096;

const Mode = enum {
    logical, // -L: use $PWD from environment when it validates
    physical, // -P: resolve all symlinks to get the physical path
};

fn writeAll(fd: c_int, data: []const u8) bool {
    var off: usize = 0;
    while (off < data.len) {
        const n = libc.write(fd, data.ptr + off, data.len - off);
        if (n < 0) {
            // Retry on EINTR; treat anything else as a hard I/O error.
            if (libc._errno().* == @intFromEnum(std.c.E.INTR)) continue;
            return false;
        }
        if (n == 0) return false; // no progress; avoid spinning
        off += @intCast(n);
    }
    return true;
}

fn writeStdout(data: []const u8) void {
    _ = writeAll(libc.STDOUT_FILENO, data);
}

fn writeStderr(data: []const u8) void {
    _ = writeAll(libc.STDERR_FILENO, data);
}

fn printUsage() void {
    const usage =
        \\Usage: zpwd [OPTION]...
        \\Print the full filename of the current working directory.
        \\
        \\  -L, --logical   use PWD from environment, even if it contains symlinks
        \\  -P, --physical  resolve all symlinks
        \\      --help      display this help and exit
        \\      --version   output version information and exit
        \\
        \\If no option is specified, -P is assumed (POSIXLY_CORRECT selects -L).
        \\
    ;
    // GNU writes --help to stdout, exit 0.
    writeStdout(usage);
}

fn printVersion() void {
    // GNU writes --version to stdout, exit 0.
    writeStdout("zpwd " ++ VERSION ++ "\n");
}

/// getcwd into `buf`; on ERANGE grow a heap buffer until it fits.
/// Returns a slice that is either a sub-slice of `buf` or of `grown.*`
/// (in which case the caller owns freeing `grown.*`).
fn getPhysicalCwd(buf: []u8, grown: *?[]u8) ?[]const u8 {
    if (getcwd(buf.ptr, buf.len)) |ptr| {
        return std.mem.span(ptr);
    }
    if (libc._errno().* != @intFromEnum(std.c.E.RANGE)) return null;

    // Path is longer than PATH_MAX; grow the buffer like GNU does.
    var size: usize = buf.len;
    const alloc = std.heap.page_allocator;
    while (size < 1 << 24) { // 16 MiB sanity ceiling
        size *= 2;
        const heap = alloc.alloc(u8, size) catch return null;
        if (getcwd(heap.ptr, heap.len)) |ptr| {
            grown.* = heap;
            return std.mem.span(ptr);
        }
        alloc.free(heap);
        if (libc._errno().* != @intFromEnum(std.c.E.RANGE)) return null;
    }
    return null;
}

/// True when `path` is absolute and contains no "." or ".." path component.
/// POSIX/GNU require the logical PWD to be free of dot components.
fn isCleanAbsolute(path: []const u8) bool {
    if (path.len == 0 or path[0] != '/') return false;
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |seg| {
        if (seg.len == 0) continue; // empty from leading/duplicate slashes
        if (std.mem.eql(u8, seg, ".") or std.mem.eql(u8, seg, "..")) return false;
    }
    return true;
}

/// Stat `path` and ".", return true when both name the same inode.
fn namesCurrentDir(path: [:0]const u8) bool {
    var st_pwd: std.c.Stat = undefined;
    var st_dot: std.c.Stat = undefined;
    if (stat(path.ptr, &st_pwd) != 0) return false;
    if (stat(".", &st_dot) != 0) return false;
    return st_pwd.dev == st_dot.dev and st_pwd.ino == st_dot.ino;
}

fn getLogicalCwd(buf: []u8, grown: *?[]u8) ?[]const u8 {
    if (getenv("PWD")) |pwd_ptr| {
        const pwd = std.mem.span(pwd_ptr);
        // $PWD must be a clean absolute path AND actually name "." — otherwise
        // a stale/attacker-set PWD would be trusted. Fall back to physical.
        if (isCleanAbsolute(pwd) and namesCurrentDir(pwd) and pwd.len < buf.len) {
            @memcpy(buf[0..pwd.len], pwd);
            return buf[0..pwd.len];
        }
    }
    return getPhysicalCwd(buf, grown);
}

pub fn main(init: std.process.Init) !void {
    // GNU default is physical; POSIXLY_CORRECT selects logical.
    var mode: Mode = if (getenv("POSIXLY_CORRECT") != null) .logical else .physical;
    var saw_operand = false;
    var end_of_options = false;

    var args_iter = std.process.Args.Iterator.init(init.minimal.args);
    _ = args_iter.next(); // skip program name

    while (args_iter.next()) |arg| {
        if (!end_of_options and std.mem.eql(u8, arg, "--")) {
            end_of_options = true;
            continue;
        }
        if (!end_of_options and std.mem.eql(u8, arg, "--help")) {
            printUsage();
            return;
        }
        if (!end_of_options and std.mem.eql(u8, arg, "--version")) {
            printVersion();
            return;
        }
        if (!end_of_options and std.mem.eql(u8, arg, "--logical")) {
            mode = .logical;
            continue;
        }
        if (!end_of_options and std.mem.eql(u8, arg, "--physical")) {
            mode = .physical;
            continue;
        }
        // A long option we don't recognize.
        if (!end_of_options and arg.len > 2 and arg[0] == '-' and arg[1] == '-') {
            writeStderr("zpwd: unrecognized option '");
            writeStderr(arg);
            writeStderr("'\nTry 'zpwd --help' for more information.\n");
            std.process.exit(1);
        }
        // A bundle of short options like -L, -P, -LP (last wins). A bare "-"
        // is not an option; it is a non-option operand.
        if (!end_of_options and arg.len > 1 and arg[0] == '-') {
            for (arg[1..]) |ch| {
                switch (ch) {
                    'L' => mode = .logical,
                    'P' => mode = .physical,
                    'h' => {
                        printUsage();
                        return;
                    },
                    else => {
                        writeStderr("zpwd: invalid option -- '");
                        writeStderr(&[_]u8{ch});
                        writeStderr("'\nTry 'zpwd --help' for more information.\n");
                        std.process.exit(1);
                    },
                }
            }
            continue;
        }
        // Anything else (including a bare "-") is a non-option operand.
        saw_operand = true;
    }

    if (saw_operand) {
        // GNU emits this once, then still prints the directory (exit 0).
        writeStderr("zpwd: ignoring non-option arguments\n");
    }

    var buf: [PATH_MAX]u8 = undefined;
    var grown: ?[]u8 = null;
    defer if (grown) |g| std.heap.page_allocator.free(g);

    const cwd = switch (mode) {
        .logical => getLogicalCwd(&buf, &grown),
        .physical => getPhysicalCwd(&buf, &grown),
    };

    if (cwd) |path| {
        writeStdout(path);
        writeStdout("\n");
    } else {
        writeStderr("zpwd: error getting current directory\n");
        std.process.exit(1);
    }
}
