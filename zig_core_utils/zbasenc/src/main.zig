const std = @import("std");
const libc = std.c;

// strerror is not re-exported by std.c; declare it directly for GNU-style errno messages.
extern "c" fn strerror(errnum: c_int) [*:0]const u8;

const Encoding = enum {
    base64,
    base64url,
    base32,
    base32hex,
    base16,
    base2msbf,
    base2lsbf,
};

const base64_alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
const base64url_alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
const base32_alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";
const base32hex_alphabet = "0123456789ABCDEFGHIJKLMNOPQRSTUV";
const base16_alphabet = "0123456789ABCDEF";

const OutputBuffer = struct {
    buf: [8192]u8 = undefined,
    pos: usize = 0,
    col: usize = 0,
    wrap: usize = 76,

    fn write(self: *OutputBuffer, data: []const u8) void {
        for (data) |c| self.writeByte(c);
    }

    fn writeByte(self: *OutputBuffer, c: u8) void {
        self.buf[self.pos] = c;
        self.pos += 1;
        self.col += 1;
        if (self.pos == self.buf.len) self.flush();
    }

    fn writeWithWrap(self: *OutputBuffer, c: u8) void {
        if (self.wrap > 0 and self.col >= self.wrap) {
            self.writeByte('\n');
            self.col = 0;
        }
        self.writeByte(c);
    }

    fn flush(self: *OutputBuffer) void {
        if (self.pos > 0) {
            _ = libc.write(libc.STDOUT_FILENO, &self.buf, self.pos);
            self.pos = 0;
        }
    }

    fn finalize(self: *OutputBuffer) void {
        // GNU basenc appends a trailing newline only when line wrapping is active.
        // With `-w 0` (wrapping disabled) the encoded stream has no trailing newline.
        if (self.wrap > 0 and self.col > 0) {
            self.writeByte('\n');
        }
        self.flush();
    }
};

fn encodeBase64(data: []const u8, out: *OutputBuffer, alphabet: *const [64]u8) void {
    var i: usize = 0;
    while (i + 3 <= data.len) : (i += 3) {
        const b0 = data[i];
        const b1 = data[i + 1];
        const b2 = data[i + 2];

        out.writeWithWrap(alphabet[b0 >> 2]);
        out.writeWithWrap(alphabet[((b0 & 0x03) << 4) | (b1 >> 4)]);
        out.writeWithWrap(alphabet[((b1 & 0x0F) << 2) | (b2 >> 6)]);
        out.writeWithWrap(alphabet[b2 & 0x3F]);
    }

    const remaining = data.len - i;
    if (remaining == 1) {
        const b0 = data[i];
        out.writeWithWrap(alphabet[b0 >> 2]);
        out.writeWithWrap(alphabet[(b0 & 0x03) << 4]);
        out.writeWithWrap('=');
        out.writeWithWrap('=');
    } else if (remaining == 2) {
        const b0 = data[i];
        const b1 = data[i + 1];
        out.writeWithWrap(alphabet[b0 >> 2]);
        out.writeWithWrap(alphabet[((b0 & 0x03) << 4) | (b1 >> 4)]);
        out.writeWithWrap(alphabet[(b1 & 0x0F) << 2]);
        out.writeWithWrap('=');
    }
}

fn encodeBase32(data: []const u8, out: *OutputBuffer, alphabet: *const [32]u8) void {
    var i: usize = 0;
    while (i + 5 <= data.len) : (i += 5) {
        const b0 = data[i];
        const b1 = data[i + 1];
        const b2 = data[i + 2];
        const b3 = data[i + 3];
        const b4 = data[i + 4];

        out.writeWithWrap(alphabet[b0 >> 3]);
        out.writeWithWrap(alphabet[((b0 & 0x07) << 2) | (b1 >> 6)]);
        out.writeWithWrap(alphabet[(b1 >> 1) & 0x1F]);
        out.writeWithWrap(alphabet[((b1 & 0x01) << 4) | (b2 >> 4)]);
        out.writeWithWrap(alphabet[((b2 & 0x0F) << 1) | (b3 >> 7)]);
        out.writeWithWrap(alphabet[(b3 >> 2) & 0x1F]);
        out.writeWithWrap(alphabet[((b3 & 0x03) << 3) | (b4 >> 5)]);
        out.writeWithWrap(alphabet[b4 & 0x1F]);
    }

    const remaining = data.len - i;
    if (remaining > 0) {
        var buf: [5]u8 = .{ 0, 0, 0, 0, 0 };
        for (0..remaining) |j| buf[j] = data[i + j];

        out.writeWithWrap(alphabet[buf[0] >> 3]);
        out.writeWithWrap(alphabet[((buf[0] & 0x07) << 2) | (buf[1] >> 6)]);

        if (remaining >= 2) {
            out.writeWithWrap(alphabet[(buf[1] >> 1) & 0x1F]);
            out.writeWithWrap(alphabet[((buf[1] & 0x01) << 4) | (buf[2] >> 4)]);
        } else {
            out.writeWithWrap('=');
            out.writeWithWrap('=');
        }

        if (remaining >= 3) {
            out.writeWithWrap(alphabet[((buf[2] & 0x0F) << 1) | (buf[3] >> 7)]);
        } else {
            out.writeWithWrap('=');
        }

        if (remaining >= 4) {
            out.writeWithWrap(alphabet[(buf[3] >> 2) & 0x1F]);
            out.writeWithWrap(alphabet[((buf[3] & 0x03) << 3) | (buf[4] >> 5)]);
        } else {
            out.writeWithWrap('=');
            out.writeWithWrap('=');
        }

        out.writeWithWrap('=');
    }
}

fn encodeBase16(data: []const u8, out: *OutputBuffer) void {
    for (data) |b| {
        out.writeWithWrap(base16_alphabet[b >> 4]);
        out.writeWithWrap(base16_alphabet[b & 0x0F]);
    }
}

fn encodeBase2(data: []const u8, out: *OutputBuffer, msb_first: bool) void {
    for (data) |b| {
        if (msb_first) {
            var i: u3 = 7;
            while (true) : (i -= 1) {
                out.writeWithWrap(if ((b >> i) & 1 == 1) '1' else '0');
                if (i == 0) break;
            }
        } else {
            var i: u3 = 0;
            while (true) : (i += 1) {
                out.writeWithWrap(if ((b >> i) & 1 == 1) '1' else '0');
                if (i == 7) break;
            }
        }
    }
}

fn decodeBase64Char(c: u8, alphabet: *const [64]u8) ?u6 {
    for (alphabet, 0..) |a, i| {
        if (a == c) return @intCast(i);
    }
    return null;
}

// Returns true when the input was fully valid. Like GNU basenc, decoded bytes
// from every complete group (and any completeable leftover) are emitted even on
// an invalid stream; the return value only drives the exit status / diagnostic.
fn decodeBase64(data: []const u8, out: *OutputBuffer, alphabet: *const [64]u8, ignore_garbage: bool) bool {
    var buf: [4]u6 = undefined;
    var buf_len: usize = 0;
    var invalid = false;

    for (data) |c| {
        if (c == '\n' or c == '\r') continue;
        if (c == '=') continue; // padding: skip (group is length-validated at end)

        if (decodeBase64Char(c, alphabet)) |val| {
            buf[buf_len] = val;
            buf_len += 1;

            if (buf_len == 4) {
                out.writeByte((@as(u8, buf[0]) << 2) | (buf[1] >> 4));
                out.writeByte((@as(u8, buf[1] & 0x0F) << 4) | (buf[2] >> 2));
                out.writeByte((@as(u8, buf[2] & 0x03) << 6) | buf[3]);
                buf_len = 0;
            }
        } else if (ignore_garbage) {
            continue;
        } else {
            invalid = true;
            break; // stop at first non-alphabet byte, like GNU
        }
    }

    // Emit completeable leftover bytes (GNU emits these even on error).
    if (buf_len >= 2) {
        out.writeByte((@as(u8, buf[0]) << 2) | (buf[1] >> 4));
    }
    if (buf_len >= 3) {
        out.writeByte((@as(u8, buf[1] & 0x0F) << 4) | (buf[2] >> 2));
    }

    if (invalid) return false;
    // RFC 4648 length + trailing-bit validation (matches GNU exactly).
    switch (buf_len) {
        0 => {},
        1 => return false, // a lone sextet is never valid (4n+1)
        2 => if ((buf[1] & 0x0F) != 0) return false, // unused low 4 bits must be zero
        3 => if ((buf[2] & 0x03) != 0) return false, // unused low 2 bits must be zero
        else => unreachable,
    }
    return true;
}

fn decodeBase32Char(c: u8, alphabet: *const [32]u8) ?u5 {
    for (alphabet, 0..) |a, i| {
        if (a == c or (a >= 'A' and a <= 'Z' and c == a + 32)) return @intCast(i);
    }
    return null;
}

fn decodeBase32(data: []const u8, out: *OutputBuffer, alphabet: *const [32]u8, ignore_garbage: bool) bool {
    var buf: [8]u5 = undefined;
    var buf_len: usize = 0;
    var invalid = false;

    for (data) |c| {
        if (c == '\n' or c == '\r' or c == '=') continue;

        if (decodeBase32Char(c, alphabet)) |val| {
            buf[buf_len] = val;
            buf_len += 1;

            if (buf_len == 8) {
                out.writeByte((@as(u8, buf[0]) << 3) | (buf[1] >> 2));
                out.writeByte((@as(u8, buf[1] & 0x03) << 6) | (@as(u8, buf[2]) << 1) | (buf[3] >> 4));
                out.writeByte((@as(u8, buf[3] & 0x0F) << 4) | (buf[4] >> 1));
                out.writeByte((@as(u8, buf[4] & 0x01) << 7) | (@as(u8, buf[5]) << 2) | (buf[6] >> 3));
                out.writeByte((@as(u8, buf[6] & 0x07) << 5) | buf[7]);
                buf_len = 0;
            }
        } else if (ignore_garbage) {
            continue;
        } else {
            invalid = true;
            break;
        }
    }

    // Emit completeable leftover bytes.
    if (buf_len >= 2) out.writeByte((@as(u8, buf[0]) << 3) | (buf[1] >> 2));
    if (buf_len >= 4) out.writeByte((@as(u8, buf[1] & 0x03) << 6) | (@as(u8, buf[2]) << 1) | (buf[3] >> 4));
    if (buf_len >= 5) out.writeByte((@as(u8, buf[3] & 0x0F) << 4) | (buf[4] >> 1));
    if (buf_len >= 7) out.writeByte((@as(u8, buf[4] & 0x01) << 7) | (@as(u8, buf[5]) << 2) | (buf[6] >> 3));

    if (invalid) return false;
    // Valid base32 leftover counts are 0/2/4/5/7; each with its unused low bits zero.
    switch (buf_len) {
        0 => {},
        2 => if ((buf[1] & 0x03) != 0) return false,
        4 => if ((buf[3] & 0x0F) != 0) return false,
        5 => if ((buf[4] & 0x01) != 0) return false,
        7 => if ((buf[6] & 0x07) != 0) return false,
        else => return false, // 1/3/6 are impossible group lengths
    }
    return true;
}

fn decodeBase16(data: []const u8, out: *OutputBuffer, ignore_garbage: bool) bool {
    var high: ?u4 = null;
    var invalid = false;

    for (data) |c| {
        if (c == '\n' or c == '\r') continue;

        var val: ?u4 = null;
        if (c >= '0' and c <= '9') val = @intCast(c - '0');
        if (c >= 'A' and c <= 'F') val = @intCast(c - 'A' + 10);
        if (c >= 'a' and c <= 'f') val = @intCast(c - 'a' + 10);

        if (val) |v| {
            if (high) |h| {
                out.writeByte((@as(u8, h) << 4) | v);
                high = null;
            } else {
                high = v;
            }
        } else if (ignore_garbage) {
            continue;
        } else {
            invalid = true;
            break;
        }
    }

    if (invalid) return false;
    if (high != null) return false; // dangling high nibble (odd number of hex digits)
    return true;
}

fn decodeBase2(data: []const u8, out: *OutputBuffer, msb_first: bool, ignore_garbage: bool) bool {
    var byte: u8 = 0;
    var bit_count: u4 = 0;
    var invalid = false;

    for (data) |c| {
        if (c == '\n' or c == '\r') continue;

        if (c == '0' or c == '1') {
            const bit: u1 = if (c == '1') 1 else 0;
            if (msb_first) {
                byte = (byte << 1) | bit;
            } else {
                byte = byte | (@as(u8, bit) << @intCast(bit_count));
            }
            bit_count += 1;

            if (bit_count == 8) {
                out.writeByte(byte);
                byte = 0;
                bit_count = 0;
            }
        } else if (ignore_garbage) {
            continue;
        } else {
            invalid = true;
            break;
        }
    }

    if (invalid) return false;
    if (bit_count != 0) return false; // trailing bits that do not complete a byte
    return true;
}

fn writeStderr(s: []const u8) void {
    _ = libc.write(libc.STDERR_FILENO, s.ptr, s.len);
}

// `zbasenc: <path>: <errmsg>\n`, then exit 1 (no Zig stack trace).
fn fatalPath(path: []const u8, errmsg: [*:0]const u8) noreturn {
    writeStderr("zbasenc: ");
    writeStderr(path);
    writeStderr(": ");
    writeStderr(std.mem.span(errmsg));
    writeStderr("\n");
    std.process.exit(1);
}

fn fatalWrap(val: []const u8) noreturn {
    // GNU: `basenc: invalid wrap size: '<val>'` (plain quotes in the C locale).
    writeStderr("zbasenc: invalid wrap size: '");
    writeStderr(val);
    writeStderr("'\n");
    std.process.exit(1);
}

fn parseWrap(val: []const u8) usize {
    return std.fmt.parseInt(usize, val, 10) catch fatalWrap(val);
}

fn readInput(allocator: std.mem.Allocator, file: ?[]const u8) ![]const u8 {
    if (file == null or std.mem.eql(u8, file.?, "-")) {
        var content = std.ArrayListUnmanaged(u8).empty;
        var buf: [4096]u8 = undefined;
        while (true) {
            const n = libc.read(libc.STDIN_FILENO, &buf, buf.len);
            if (n <= 0) break;
            try content.appendSlice(allocator, buf[0..@intCast(n)]);
        }
        return content.toOwnedSlice(allocator);
    } else {
        var path_buf: [4096]u8 = undefined;
        const path_z = std.fmt.bufPrintZ(&path_buf, "{s}", .{file.?}) catch return error.PathTooLong;

        const fd = libc.open(path_z.ptr, .{ .ACCMODE = .RDONLY }, @as(libc.mode_t, 0));
        if (fd < 0) {
            // GNU: `basenc: <FILE>: <strerror(errno)>` on stderr, exit 1, no stack trace.
            const errnum = libc._errno().*;
            fatalPath(file.?, strerror(errnum));
        }
        defer _ = libc.close(fd);

        var content = std.ArrayListUnmanaged(u8).empty;
        var buf: [4096]u8 = undefined;
        while (true) {
            const n = libc.read(fd, &buf, buf.len);
            if (n <= 0) break;
            try content.appendSlice(allocator, buf[0..@intCast(n)]);
        }
        return content.toOwnedSlice(allocator);
    }
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next(); // skip program name

    var encoding: ?Encoding = null;
    var decode = false;
    var ignore_garbage = false;
    var wrap: usize = 76;
    var file: ?[]const u8 = null;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--help")) {
            const help =
                \\Usage: zbasenc [OPTION]... [FILE]
                \\basenc encode or decode FILE, or standard input, to standard output.
                \\
                \\      --base64          base64 encoding (RFC4648 section 4)
                \\      --base64url       file- and url-safe base64 (RFC4648 section 5)
                \\      --base32          base32 encoding (RFC4648 section 6)
                \\      --base32hex       extended hex alphabet base32 (RFC4648 section 7)
                \\      --base16          hex encoding (RFC4648 section 8)
                \\      --base2msbf       bit string with msb first
                \\      --base2lsbf       bit string with lsb first
                \\  -d, --decode          decode data
                \\  -i, --ignore-garbage  when decoding, ignore non-alphabet characters
                \\  -w, --wrap=COLS       wrap encoded lines after COLS character (default 76)
                \\      --help            display this help and exit
                \\
            ;
            _ = libc.write(libc.STDOUT_FILENO, help.ptr, help.len);
            return;
        } else if (std.mem.eql(u8, arg, "--base64")) {
            encoding = .base64;
        } else if (std.mem.eql(u8, arg, "--base64url")) {
            encoding = .base64url;
        } else if (std.mem.eql(u8, arg, "--base32")) {
            encoding = .base32;
        } else if (std.mem.eql(u8, arg, "--base32hex")) {
            encoding = .base32hex;
        } else if (std.mem.eql(u8, arg, "--base16")) {
            encoding = .base16;
        } else if (std.mem.eql(u8, arg, "--base2msbf")) {
            encoding = .base2msbf;
        } else if (std.mem.eql(u8, arg, "--base2lsbf")) {
            encoding = .base2lsbf;
        } else if (std.mem.eql(u8, arg, "--version")) {
            const ver = "zbasenc (zig_core_utils) — basenc-compatible\n";
            _ = libc.write(libc.STDOUT_FILENO, ver.ptr, ver.len);
            return;
        } else if (std.mem.eql(u8, arg, "--decode")) {
            decode = true;
        } else if (std.mem.eql(u8, arg, "--ignore-garbage")) {
            ignore_garbage = true;
        } else if (std.mem.startsWith(u8, arg, "--wrap=")) {
            wrap = parseWrap(arg[7..]);
        } else if (std.mem.eql(u8, arg, "--wrap")) {
            // Space-separated long form: consume the next token as the value.
            wrap = parseWrap(args.next() orelse fatalWrap(""));
        } else if (arg.len >= 2 and arg[0] == '-' and arg[1] != '-') {
            // Cluster of short options, e.g. `-d`, `-di`, `-w76`, `-dw 76`.
            var j: usize = 1;
            while (j < arg.len) : (j += 1) {
                switch (arg[j]) {
                    'd' => decode = true,
                    'i' => ignore_garbage = true,
                    'w' => {
                        // Rest of the cluster is the value; otherwise the next token.
                        const val = if (j + 1 < arg.len) arg[j + 1 ..] else args.next() orelse fatalWrap("");
                        wrap = parseWrap(val);
                        j = arg.len; // 'w' consumes the remainder of the cluster
                    },
                    else => {
                        writeStderr("zbasenc: invalid option\n");
                        std.process.exit(1);
                    },
                }
            }
        } else if (arg.len > 0 and arg[0] != '-') {
            file = arg;
        }
    }

    if (encoding == null) {
        const msg = "zbasenc: missing encoding type\n";
        _ = libc.write(libc.STDERR_FILENO, msg.ptr, msg.len);
        std.process.exit(1);
    }

    const data = try readInput(allocator, file);
    defer allocator.free(data);
    var out = OutputBuffer{};
    out.wrap = wrap;

    if (decode) {
        const valid = switch (encoding.?) {
            .base64 => decodeBase64(data, &out, base64_alphabet, ignore_garbage),
            .base64url => decodeBase64(data, &out, base64url_alphabet, ignore_garbage),
            .base32 => decodeBase32(data, &out, base32_alphabet, ignore_garbage),
            .base32hex => decodeBase32(data, &out, base32hex_alphabet, ignore_garbage),
            .base16 => decodeBase16(data, &out, ignore_garbage),
            .base2msbf => decodeBase2(data, &out, true, ignore_garbage),
            .base2lsbf => decodeBase2(data, &out, false, ignore_garbage),
        };
        out.flush();
        if (!valid) {
            // GNU emits decoded bytes first, then this diagnostic, then exits 1.
            writeStderr("zbasenc: invalid input\n");
            std.process.exit(1);
        }
    } else {
        switch (encoding.?) {
            .base64 => encodeBase64(data, &out, base64_alphabet),
            .base64url => encodeBase64(data, &out, base64url_alphabet),
            .base32 => encodeBase32(data, &out, base32_alphabet),
            .base32hex => encodeBase32(data, &out, base32hex_alphabet),
            .base16 => encodeBase16(data, &out),
            .base2msbf => encodeBase2(data, &out, true),
            .base2lsbf => encodeBase2(data, &out, false),
        }
        out.finalize();
    }
}
