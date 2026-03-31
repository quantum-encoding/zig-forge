//! zsum - Checksum and count the blocks in a file
//!
//! Compatible with GNU sum:
//! - Default: BSD checksum algorithm
//! - -r: use BSD algorithm (default)
//! - -s, --sysv: use System V algorithm
//! - Output format: CHECKSUM BLOCKS FILENAME

const std = @import("std");
const libc = std.c;
const Io = std.Io;

const Algorithm = enum { bsd, sysv };

const Config = struct {
    algorithm: Algorithm = .bsd,
    files: [64][]const u8 = undefined,
    file_count: usize = 0,
};

fn sumFile(path: ?[]const u8, algo: Algorithm) !void {
    const fd: c_int = if (path) |p| blk: {
        if (std.mem.eql(u8, p, "-")) break :blk 0;
        var path_buf: [4096]u8 = undefined;
        const path_z = std.fmt.bufPrintZ(&path_buf, "{s}", .{p}) catch return error.PathTooLong;
        const fd_ret = libc.open(path_z.ptr, .{ .ACCMODE = .RDONLY }, @as(libc.mode_t, 0));
        if (fd_ret < 0) return error.OpenFailed;
        break :blk fd_ret;
    } else 0;
    defer {
        if (path != null and !std.mem.eql(u8, path.?, "-")) _ = libc.close(fd);
    }

    var buf: [65536]u8 = undefined;
    var total_bytes: u64 = 0;

    const io = Io.Threaded.global_single_threaded.io();
    var out_buf: [256]u8 = undefined;
    const stdout = Io.File.stdout();
    var writer = stdout.writer(io, &out_buf);

    switch (algo) {
        .bsd => {
            var checksum: u16 = 0;
            while (true) {
                const n_raw = libc.read(fd, &buf, buf.len);
                if (n_raw <= 0) break;
                const n: usize = @intCast(n_raw);
                total_bytes += n;
                for (buf[0..n]) |b| {
                    // Rotate right by 1 bit
                    checksum = (checksum >> 1) + ((checksum & 1) << 15);
                    checksum +%= b;
                }
            }
            const blocks = (total_bytes + 1023) / 1024;
            if (path) |p| {
                writer.interface.print("{d:>5} {d:>5} {s}\n", .{ checksum, blocks, p }) catch {};
            } else {
                writer.interface.print("{d:>5} {d:>5}\n", .{ checksum, blocks }) catch {};
            }
        },
        .sysv => {
            var checksum: u32 = 0;
            while (true) {
                const n_raw = libc.read(fd, &buf, buf.len);
                if (n_raw <= 0) break;
                const n: usize = @intCast(n_raw);
                total_bytes += n;
                for (buf[0..n]) |b| {
                    checksum +%= b;
                }
            }
            // Fold 32-bit to 16-bit
            checksum = (checksum & 0xFFFF) + (checksum >> 16);
            checksum = (checksum & 0xFFFF) + (checksum >> 16);
            const blocks = (total_bytes + 511) / 512;
            if (path) |p| {
                writer.interface.print("{d} {d} {s}\n", .{ checksum, blocks, p }) catch {};
            } else {
                writer.interface.print("{d} {d}\n", .{ checksum, blocks }) catch {};
            }
        },
    }
    writer.interface.flush() catch {};
}

pub fn main(init: std.process.Init) void {
    var cfg = Config{};

    var args_iter = std.process.Args.Iterator.init(init.minimal.args);
    _ = args_iter.next(); // skip program name

    while (args_iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "--help")) {
            const io = Io.Threaded.global_single_threaded.io();
            var buf: [512]u8 = undefined;
            const stdout = Io.File.stdout();
            var writer = stdout.writer(io, &buf);
            writer.interface.writeAll(
                \\Usage: sum [OPTION]... [FILE]...
                \\Print checksum and block counts for each FILE.
                \\
                \\  -r         use BSD sum algorithm (default)
                \\  -s, --sysv use System V sum algorithm
                \\      --help display this help and exit
                \\      --version output version information and exit
                \\
            ) catch {};
            writer.interface.flush() catch {};
            return;
        } else if (std.mem.eql(u8, arg, "--version")) {
            const io = Io.Threaded.global_single_threaded.io();
            var buf: [64]u8 = undefined;
            const stdout = Io.File.stdout();
            var writer = stdout.writer(io, &buf);
            writer.interface.writeAll("zsum 1.0.0\n") catch {};
            writer.interface.flush() catch {};
            return;
        } else if (std.mem.eql(u8, arg, "-r")) {
            cfg.algorithm = .bsd;
        } else if (std.mem.eql(u8, arg, "-s") or std.mem.eql(u8, arg, "--sysv")) {
            cfg.algorithm = .sysv;
        } else if (arg.len > 0 and arg[0] != '-') {
            if (cfg.file_count < cfg.files.len) {
                cfg.files[cfg.file_count] = arg;
                cfg.file_count += 1;
            }
        } else if (std.mem.eql(u8, arg, "-")) {
            if (cfg.file_count < cfg.files.len) {
                cfg.files[cfg.file_count] = "-";
                cfg.file_count += 1;
            }
        }
    }

    if (cfg.file_count == 0) {
        sumFile(null, cfg.algorithm) catch {
            std.debug.print("sum: error reading stdin\n", .{});
            std.process.exit(1);
        };
    } else {
        for (cfg.files[0..cfg.file_count]) |path| {
            sumFile(path, cfg.algorithm) catch {
                std.debug.print("sum: {s}: No such file or directory\n", .{path});
            };
        }
    }
}
