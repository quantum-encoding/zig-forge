const std = @import("std");
const builtin = @import("builtin");
const libc = std.c;

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

extern "c" fn fstat(fd: c_int, buf: *Stat) c_int;
extern "c" fn ftruncate(fd: c_int, length: i64) c_int;

const SizeMode = enum { absolute, extend, shrink };

fn parseSize(s: []const u8) ?struct { size: i64, mode: SizeMode } {
    if (s.len == 0) return null;

    var mode: SizeMode = .absolute;
    var start: usize = 0;

    if (s[0] == '+') {
        mode = .extend;
        start = 1;
    } else if (s[0] == '-') {
        mode = .shrink;
        start = 1;
    }

    if (start >= s.len) return null;

    // Find where digits end
    var end = start;
    while (end < s.len and ((s[end] >= '0' and s[end] <= '9') or s[end] == '.')) {
        end += 1;
    }

    const num_str = s[start..end];
    var num = std.fmt.parseInt(i64, num_str, 10) catch return null;

    // Parse suffix
    if (end < s.len) {
        const suffix = s[end];
        const multiplier: i64 = switch (suffix) {
            'K', 'k' => 1024,
            'M', 'm' => 1024 * 1024,
            'G', 'g' => 1024 * 1024 * 1024,
            'T', 't' => 1024 * 1024 * 1024 * 1024,
            else => return null,
        };
        num *= multiplier;
    }

    return .{ .size = num, .mode = mode };
}

fn getFileSize(path_z: [*:0]const u8) ?i64 {
    const fd = libc.open(path_z, .{ .ACCMODE = .RDONLY }, @as(libc.mode_t, 0));
    if (fd < 0) return null;
    defer _ = libc.close(fd);
    var stat_buf: Stat = undefined;
    if (fstat(fd, &stat_buf) != 0) return null;
    return stat_buf.size;
}

fn truncateFile(path: []const u8, size: i64, mode: SizeMode) bool {
    // Need null-terminated path
    var path_buf: [4096]u8 = undefined;
    if (path.len >= path_buf.len) return false;
    @memcpy(path_buf[0..path.len], path);
    path_buf[path.len] = 0;
    const path_z: [*:0]const u8 = @ptrCast(&path_buf);

    var final_size: i64 = size;

    if (mode != .absolute) {
        const current_size = getFileSize(path_z) orelse {
            printError("cannot stat", path);
            return false;
        };
        if (mode == .extend) {
            final_size = current_size + size;
        } else {
            final_size = current_size - size;
        }
    }

    if (final_size < 0) final_size = 0;

    // Use ftruncate via open + ftruncate
    const fd = libc.open(path_z, .{ .ACCMODE = .WRONLY }, @as(libc.mode_t, 0));
    if (fd < 0) {
        printError("cannot open", path);
        return false;
    }
    defer _ = libc.close(fd);

    if (ftruncate(fd, final_size) != 0) {
        printError("cannot truncate", path);
        return false;
    }

    return true;
}

fn printError(msg: []const u8, path: []const u8) void {
    _ = libc.write(libc.STDERR_FILENO, "ztruncate: ", 11);
    _ = libc.write(libc.STDERR_FILENO, msg.ptr, msg.len);
    _ = libc.write(libc.STDERR_FILENO, " '", 2);
    _ = libc.write(libc.STDERR_FILENO, path.ptr, path.len);
    _ = libc.write(libc.STDERR_FILENO, "'\n", 2);
}

pub fn main(init: std.process.Init) void {
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next(); // skip program name

    var size_spec: ?[]const u8 = null;
    var files_count: usize = 0;
    var files: [256][]const u8 = undefined;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--help")) {
            const help =
                \\Usage: ztruncate OPTION... FILE...
                \\Shrink or extend the size of each FILE to the specified size.
                \\
                \\  -s, --size=SIZE    set or adjust the size
                \\      --help         display this help and exit
                \\
                \\SIZE may have a suffix: K (1024), M, G, T
                \\SIZE may be prefixed with + (extend) or - (shrink)
                \\
            ;
            _ = libc.write(libc.STDOUT_FILENO, help.ptr, help.len);
            return;
        } else if (std.mem.eql(u8, arg, "-s")) {
            size_spec = args.next();
        } else if (std.mem.startsWith(u8, arg, "-s")) {
            size_spec = arg[2..];
        } else if (std.mem.startsWith(u8, arg, "--size=")) {
            size_spec = arg[7..];
        } else if (arg.len > 0 and arg[0] != '-') {
            if (files_count < files.len) {
                files[files_count] = arg;
                files_count += 1;
            }
        }
    }

    if (size_spec == null) {
        _ = libc.write(libc.STDERR_FILENO, "ztruncate: missing file operand\n", 33);
        std.process.exit(1);
    }

    if (files_count == 0) {
        _ = libc.write(libc.STDERR_FILENO, "ztruncate: missing file operand\n", 33);
        std.process.exit(1);
    }

    const parsed = parseSize(size_spec.?) orelse {
        _ = libc.write(libc.STDERR_FILENO, "ztruncate: invalid size\n", 25);
        std.process.exit(1);
    };

    var had_error = false;
    for (files[0..files_count]) |path| {
        if (!truncateFile(path, parsed.size, parsed.mode)) {
            had_error = true;
        }
    }

    if (had_error) std.process.exit(1);
}
