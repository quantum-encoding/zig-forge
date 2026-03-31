const std = @import("std");
const libc = std.c;
const crypto = std.crypto;

const Algorithm = enum {
    md5,
    sha1,
    sha224,
    sha256,
    sha384,
    sha512,
    blake2b256,
    blake2s256,
    blake3,
};

const OutputBuffer = struct {
    buf: [4096]u8 = undefined,
    pos: usize = 0,

    fn write(self: *OutputBuffer, data: []const u8) void {
        for (data) |c| self.writeByte(c);
    }

    fn writeByte(self: *OutputBuffer, c: u8) void {
        self.buf[self.pos] = c;
        self.pos += 1;
        if (self.pos == self.buf.len) self.flush();
    }

    fn flush(self: *OutputBuffer) void {
        if (self.pos > 0) {
            _ = libc.write(libc.STDOUT_FILENO, &self.buf, self.pos);
            self.pos = 0;
        }
    }
};

fn writeHex(out: *OutputBuffer, bytes: []const u8) void {
    const hex = "0123456789abcdef";
    for (bytes) |b| {
        out.writeByte(hex[b >> 4]);
        out.writeByte(hex[b & 0x0f]);
    }
}

fn hashFile(path: []const u8, algo: Algorithm, out: *OutputBuffer, binary_mode: bool) bool {
    _ = binary_mode;

    const is_stdin = std.mem.eql(u8, path, "-");

    var fd: c_int = undefined;
    var need_close = false;
    if (is_stdin) {
        fd = libc.STDIN_FILENO;
    } else {
        var path_buf: [4096]u8 = undefined;
        @memcpy(path_buf[0..path.len], path);
        path_buf[path.len] = 0;
        const path_z: [*:0]const u8 = @ptrCast(&path_buf);

        fd = libc.open(path_z, .{ .ACCMODE = .RDONLY }, @as(libc.mode_t, 0));
        if (fd < 0) {
            _ = libc.write(libc.STDERR_FILENO, "zhashsum: ", 10);
            _ = libc.write(libc.STDERR_FILENO, path.ptr, path.len);
            _ = libc.write(libc.STDERR_FILENO, ": No such file or directory\n", 28);
            return false;
        }
        need_close = true;
    }
    defer {
        if (need_close) _ = libc.close(fd);
    }

    var buf: [8192]u8 = undefined;

    switch (algo) {
        .md5 => {
            var h = crypto.hash.Md5.init(.{});
            while (true) {
                const n = libc.read(fd, &buf, buf.len);
                if (n <= 0) break;
                h.update(buf[0..@intCast(n)]);
            }
            var digest: [16]u8 = undefined;
            h.final(&digest);
            writeHex(out, &digest);
        },
        .sha1 => {
            var h = crypto.hash.Sha1.init(.{});
            while (true) {
                const n = libc.read(fd, &buf, buf.len);
                if (n <= 0) break;
                h.update(buf[0..@intCast(n)]);
            }
            var digest: [20]u8 = undefined;
            h.final(&digest);
            writeHex(out, &digest);
        },
        .sha224 => {
            var h = crypto.hash.sha2.Sha224.init(.{});
            while (true) {
                const n = libc.read(fd, &buf, buf.len);
                if (n <= 0) break;
                h.update(buf[0..@intCast(n)]);
            }
            var digest: [28]u8 = undefined;
            h.final(&digest);
            writeHex(out, &digest);
        },
        .sha256 => {
            var h = crypto.hash.sha2.Sha256.init(.{});
            while (true) {
                const n = libc.read(fd, &buf, buf.len);
                if (n <= 0) break;
                h.update(buf[0..@intCast(n)]);
            }
            var digest: [32]u8 = undefined;
            h.final(&digest);
            writeHex(out, &digest);
        },
        .sha384 => {
            var h = crypto.hash.sha2.Sha384.init(.{});
            while (true) {
                const n = libc.read(fd, &buf, buf.len);
                if (n <= 0) break;
                h.update(buf[0..@intCast(n)]);
            }
            var digest: [48]u8 = undefined;
            h.final(&digest);
            writeHex(out, &digest);
        },
        .sha512 => {
            var h = crypto.hash.sha2.Sha512.init(.{});
            while (true) {
                const n = libc.read(fd, &buf, buf.len);
                if (n <= 0) break;
                h.update(buf[0..@intCast(n)]);
            }
            var digest: [64]u8 = undefined;
            h.final(&digest);
            writeHex(out, &digest);
        },
        .blake2b256 => {
            var h = crypto.hash.blake2.Blake2b256.init(.{});
            while (true) {
                const n = libc.read(fd, &buf, buf.len);
                if (n <= 0) break;
                h.update(buf[0..@intCast(n)]);
            }
            var digest: [32]u8 = undefined;
            h.final(&digest);
            writeHex(out, &digest);
        },
        .blake2s256 => {
            var h = crypto.hash.blake2.Blake2s256.init(.{});
            while (true) {
                const n = libc.read(fd, &buf, buf.len);
                if (n <= 0) break;
                h.update(buf[0..@intCast(n)]);
            }
            var digest: [32]u8 = undefined;
            h.final(&digest);
            writeHex(out, &digest);
        },
        .blake3 => {
            var h = crypto.hash.Blake3.init(.{});
            while (true) {
                const n = libc.read(fd, &buf, buf.len);
                if (n <= 0) break;
                h.update(buf[0..@intCast(n)]);
            }
            var digest: [32]u8 = undefined;
            h.final(&digest);
            writeHex(out, &digest);
        },
    }

    out.write("  ");
    out.write(if (is_stdin) "-" else path);
    out.writeByte('\n');

    return true;
}

pub fn main(init: std.process.Init) void {
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next();

    var algo: Algorithm = .sha256; // default
    var binary_mode = false;
    var files_count: usize = 0;
    var files: [256][]const u8 = undefined;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            const help =
                \\Usage: zhashsum [OPTION]... [FILE]...
                \\Print or check checksums using various hash algorithms.
                \\
                \\Algorithm options (default is SHA256):
                \\      --md5           use MD5 algorithm
                \\      --sha1          use SHA-1 algorithm
                \\      --sha224        use SHA-224 algorithm
                \\      --sha256        use SHA-256 algorithm (default)
                \\      --sha384        use SHA-384 algorithm
                \\      --sha512        use SHA-512 algorithm
                \\      --blake2b       use BLAKE2b-256 algorithm
                \\      --blake2s       use BLAKE2s-256 algorithm
                \\      --blake3        use BLAKE3 algorithm
                \\
                \\Other options:
                \\  -b, --binary        read in binary mode
                \\      --help          display this help and exit
                \\
                \\With no FILE, or when FILE is -, read standard input.
                \\
            ;
            _ = libc.write(libc.STDOUT_FILENO, help.ptr, help.len);
            return;
        } else if (std.mem.eql(u8, arg, "--md5")) {
            algo = .md5;
        } else if (std.mem.eql(u8, arg, "--sha1")) {
            algo = .sha1;
        } else if (std.mem.eql(u8, arg, "--sha224")) {
            algo = .sha224;
        } else if (std.mem.eql(u8, arg, "--sha256")) {
            algo = .sha256;
        } else if (std.mem.eql(u8, arg, "--sha384")) {
            algo = .sha384;
        } else if (std.mem.eql(u8, arg, "--sha512")) {
            algo = .sha512;
        } else if (std.mem.eql(u8, arg, "--blake2b")) {
            algo = .blake2b256;
        } else if (std.mem.eql(u8, arg, "--blake2s")) {
            algo = .blake2s256;
        } else if (std.mem.eql(u8, arg, "--blake3")) {
            algo = .blake3;
        } else if (std.mem.eql(u8, arg, "-b") or std.mem.eql(u8, arg, "--binary")) {
            binary_mode = true;
        } else if (arg.len > 0 and arg[0] != '-') {
            if (files_count < files.len) {
                files[files_count] = arg;
                files_count += 1;
            }
        }
    }

    var out = OutputBuffer{};
    var had_error = false;

    if (files_count == 0) {
        // Read from stdin
        if (!hashFile("-", algo, &out, binary_mode)) {
            had_error = true;
        }
    } else {
        for (files[0..files_count]) |path| {
            if (!hashFile(path, algo, &out, binary_mode)) {
                had_error = true;
            }
        }
    }

    out.flush();

    if (had_error) std.process.exit(1);
}
