const std = @import("std");
const libc = std.c;
const crypto = std.crypto;

extern "c" fn strerror(errnum: c_int) [*:0]const u8;

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

fn digestLenOf(algo: Algorithm) usize {
    return switch (algo) {
        .md5 => 16,
        .sha1 => 20,
        .sha224 => 28,
        .sha256 => 32,
        .sha384 => 48,
        .sha512 => 64,
        .blake2b256, .blake2s256, .blake3 => 32,
    };
}

// ---------------------------------------------------------------------------
// Low-level fd I/O helpers (loop on short/interrupted writes — a checksum tool
// must never silently truncate its own output on a slow/full pipe).
// ---------------------------------------------------------------------------

fn writeAllFd(fd: c_int, bytes: []const u8) void {
    var off: usize = 0;
    while (off < bytes.len) {
        const n = libc.write(fd, bytes.ptr + off, bytes.len - off);
        if (n < 0) {
            if (libc._errno().* == @intFromEnum(libc.E.INTR)) continue;
            return;
        }
        if (n == 0) return;
        off += @intCast(n);
    }
}

fn diag(parts: []const []const u8) void {
    for (parts) |p| writeAllFd(libc.STDERR_FILENO, p);
}

fn diagErrno(path: []const u8, errnum: c_int) void {
    const msg = std.mem.span(strerror(errnum));
    diag(&.{ "zhashsum: ", path, ": ", msg, "\n" });
}

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
            writeAllFd(libc.STDOUT_FILENO, self.buf[0..self.pos]);
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

fn hexEncodeLower(bytes: []const u8, dst: []u8) void {
    const hex = "0123456789abcdef";
    for (bytes, 0..) |b, i| {
        dst[i * 2] = hex[b >> 4];
        dst[i * 2 + 1] = hex[b & 0x0f];
    }
}

// ---------------------------------------------------------------------------
// Hashing
// ---------------------------------------------------------------------------

/// Drive one hasher over fd until EOF. Returns false on a genuine read()
/// failure (errno preserved for the caller); distinguishes a real error from
/// a clean 0-byte EOF — the pre-fix `if (n <= 0) break;` conflated the two and
/// happily reported success for directories / mid-stream I/O errors.
fn hashStream(comptime H: type, fd: c_int, digest_out: *[64]u8) bool {
    var h = H.init(.{});
    var buf: [8192]u8 = undefined;
    while (true) {
        const n = libc.read(fd, &buf, buf.len);
        if (n < 0) {
            if (libc._errno().* == @intFromEnum(libc.E.INTR)) continue;
            return false;
        }
        if (n == 0) break;
        h.update(buf[0..@intCast(n)]);
    }
    h.final(digest_out[0..H.digest_length]);
    return true;
}

/// Compute the digest of `path` (or stdin). On failure returns null and stores
/// the responsible errno in `errno_out` (captured before any close() so the
/// caller can render an accurate strerror message). Returns the digest byte
/// length on success.
fn computeDigest(
    allocator: std.mem.Allocator,
    path: []const u8,
    is_stdin: bool,
    algo: Algorithm,
    digest_out: *[64]u8,
    errno_out: *c_int,
) ?usize {
    var fd: c_int = undefined;
    var need_close = false;
    if (is_stdin) {
        fd = libc.STDIN_FILENO;
    } else {
        const path_z = allocator.dupeZ(u8, path) catch {
            errno_out.* = @intFromEnum(libc.E.NOMEM);
            return null;
        };
        defer allocator.free(path_z);
        fd = libc.open(path_z.ptr, .{ .ACCMODE = .RDONLY }, @as(libc.mode_t, 0));
        if (fd < 0) {
            errno_out.* = libc._errno().*;
            return null;
        }
        need_close = true;
    }
    defer if (need_close) {
        _ = libc.close(fd);
    };

    const ok = switch (algo) {
        .md5 => hashStream(crypto.hash.Md5, fd, digest_out),
        .sha1 => hashStream(crypto.hash.Sha1, fd, digest_out),
        .sha224 => hashStream(crypto.hash.sha2.Sha224, fd, digest_out),
        .sha256 => hashStream(crypto.hash.sha2.Sha256, fd, digest_out),
        .sha384 => hashStream(crypto.hash.sha2.Sha384, fd, digest_out),
        .sha512 => hashStream(crypto.hash.sha2.Sha512, fd, digest_out),
        .blake2b256 => hashStream(crypto.hash.blake2.Blake2b256, fd, digest_out),
        .blake2s256 => hashStream(crypto.hash.blake2.Blake2s256, fd, digest_out),
        .blake3 => hashStream(crypto.hash.Blake3, fd, digest_out),
    };
    if (!ok) {
        errno_out.* = libc._errno().*;
        return null;
    }
    return digestLenOf(algo);
}

// ---------------------------------------------------------------------------
// GNU filename escaping (coreutils digest.c). When a name contains a newline
// or backslash the whole output line is prefixed with '\' and those two bytes
// are escaped as "\n" / "\\". `-c` reverses this on read.
// ---------------------------------------------------------------------------

fn nameNeedsEscape(name: []const u8) bool {
    for (name) |c| {
        if (c == '\n' or c == '\\') return true;
    }
    return false;
}

fn writeEscapedName(out: *OutputBuffer, name: []const u8) void {
    for (name) |c| {
        switch (c) {
            '\\' => out.write("\\\\"),
            '\n' => out.write("\\n"),
            else => out.writeByte(c),
        }
    }
}

/// Un-escape a '\'-prefixed name from a checksum file into `dst`, returning the
/// used length. `dst` must be at least `src.len`.
fn unescapeName(src: []const u8, dst: []u8) usize {
    var i: usize = 0;
    var j: usize = 0;
    while (i < src.len) {
        if (src[i] == '\\' and i + 1 < src.len) {
            i += 1;
            dst[j] = switch (src[i]) {
                'n' => '\n',
                '\\' => '\\',
                'r' => '\r',
                't' => '\t',
                else => src[i],
            };
        } else {
            dst[j] = src[i];
        }
        i += 1;
        j += 1;
    }
    return j;
}

fn printChecksumLine(
    out: *OutputBuffer,
    digest: []const u8,
    name: []const u8,
    is_stdin: bool,
    binary_mode: bool,
) void {
    const escaped = !is_stdin and nameNeedsEscape(name);
    if (escaped) out.writeByte('\\');
    writeHex(out, digest);
    out.writeByte(' ');
    out.writeByte(if (binary_mode) '*' else ' ');
    if (is_stdin) {
        out.write("-");
    } else if (escaped) {
        writeEscapedName(out, name);
    } else {
        out.write(name);
    }
    out.writeByte('\n');
}

// ---------------------------------------------------------------------------
// -c / --check
// ---------------------------------------------------------------------------

fn readAllFd(allocator: std.mem.Allocator, fd: c_int, errno_out: *c_int) ?[]u8 {
    var list: std.ArrayListUnmanaged(u8) = .empty;
    var buf: [8192]u8 = undefined;
    while (true) {
        const n = libc.read(fd, &buf, buf.len);
        if (n < 0) {
            if (libc._errno().* == @intFromEnum(libc.E.INTR)) continue;
            errno_out.* = libc._errno().*;
            list.deinit(allocator);
            return null;
        }
        if (n == 0) break;
        list.appendSlice(allocator, buf[0..@intCast(n)]) catch {
            errno_out.* = @intFromEnum(libc.E.NOMEM);
            list.deinit(allocator);
            return null;
        };
    }
    return list.toOwnedSlice(allocator) catch {
        errno_out.* = @intFromEnum(libc.E.NOMEM);
        return null;
    };
}

const CheckOptions = struct {
    status: bool = false,
    quiet: bool = false,
    warn: bool = false,
    strict: bool = false,
    ignore_missing: bool = false,
};

fn isHexLower(c: u8) bool {
    return (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
}

fn toLowerHex(c: u8) u8 {
    return if (c >= 'A' and c <= 'F') c + 32 else c;
}

/// Verify the checksum list in `sums_path` (or stdin). Returns true iff every
/// listed file was read and matched. Mirrors GNU sha*sum -c stdout/exit shape.
fn checkFile(
    allocator: std.mem.Allocator,
    out: *OutputBuffer,
    sums_path: []const u8,
    is_stdin: bool,
    algo: Algorithm,
    opts: CheckOptions,
) bool {
    var e: c_int = 0;
    var fd: c_int = undefined;
    var need_close = false;
    if (is_stdin) {
        fd = libc.STDIN_FILENO;
    } else {
        const sums_z = allocator.dupeZ(u8, sums_path) catch return false;
        defer allocator.free(sums_z);
        fd = libc.open(sums_z.ptr, .{ .ACCMODE = .RDONLY }, @as(libc.mode_t, 0));
        if (fd < 0) {
            diagErrno(sums_path, libc._errno().*);
            return false;
        }
        need_close = true;
    }
    defer if (need_close) {
        _ = libc.close(fd);
    };

    const data = readAllFd(allocator, fd, &e) orelse {
        diagErrno(sums_path, e);
        return false;
    };
    defer allocator.free(data);

    const hex_len = digestLenOf(algo) * 2;

    var all_ok = true;
    var properly_formatted: usize = 0;
    var verified: usize = 0;
    var mismatches: usize = 0;
    var read_failures: usize = 0;
    var improper: usize = 0;

    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |raw_line| {
        // Trim a trailing CR so CRLF checksum files parse.
        var line = raw_line;
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
        if (line.len == 0) continue;

        // GNU escaped line: leading '\' flags an escaped filename field.
        var s = line;
        const escaped = s[0] == '\\';
        if (escaped) s = s[1..];

        if (s.len < hex_len + 2) {
            improper += 1;
            if (opts.warn) diag(&.{ "zhashsum: ", sums_path, ": improperly formatted checksum line\n" });
            continue;
        }
        // Validate the hex field.
        var hex_ok = true;
        for (s[0..hex_len]) |c| {
            if (!isHexLower(c)) {
                hex_ok = false;
                break;
            }
        }
        // Separator: "<hex>  name" (text) or "<hex> *name" (binary).
        if (hex_ok and (s[hex_len] != ' ' or (s[hex_len + 1] != ' ' and s[hex_len + 1] != '*'))) {
            hex_ok = false;
        }
        if (!hex_ok) {
            improper += 1;
            if (opts.warn) diag(&.{ "zhashsum: ", sums_path, ": improperly formatted checksum line\n" });
            continue;
        }

        properly_formatted += 1;
        const listed_hex = s[0..hex_len];
        const escaped_body = s[hex_len + 2 ..]; // escaped filename body (no marker)

        // Resolve the real filename (un-escape a '\'-flagged line).
        var name_buf: [4096]u8 = undefined;
        var name_heap: ?[]u8 = null;
        defer if (name_heap) |h| allocator.free(h);
        const real_name: []const u8 = blk: {
            if (!escaped) break :blk escaped_body;
            if (escaped_body.len <= name_buf.len) {
                break :blk name_buf[0..unescapeName(escaped_body, &name_buf)];
            }
            const h = allocator.alloc(u8, escaped_body.len) catch break :blk escaped_body;
            name_heap = h;
            break :blk h[0..unescapeName(escaped_body, h)];
        };

        var digest: [64]u8 = undefined;
        var derr: c_int = 0;
        const dlen = computeDigest(allocator, real_name, false, algo, &digest, &derr);
        if (dlen == null) {
            if (opts.ignore_missing and derr == @intFromEnum(libc.E.NOENT)) {
                // A properly-formatted line naming a missing file; --ignore-missing
                // suppresses the failure but the line still counts as "seen", so an
                // all-missing list reports "no file was verified" (not "no lines").
                continue;
            }
            diagErrno(real_name, derr);
            if (!opts.status) {
                if (escaped) out.writeByte('\\');
                out.write(escaped_body);
                out.write(": FAILED open or read\n");
                out.flush();
            }
            read_failures += 1;
            all_ok = false;
            continue;
        }

        var computed_hex: [128]u8 = undefined;
        hexEncodeLower(digest[0..dlen.?], computed_hex[0 .. dlen.? * 2]);

        var match = true;
        for (listed_hex, 0..) |c, i| {
            if (toLowerHex(c) != computed_hex[i]) {
                match = false;
                break;
            }
        }

        if (match) {
            verified += 1;
            if (!opts.quiet and !opts.status) {
                if (escaped) out.writeByte('\\');
                out.write(escaped_body);
                out.write(": OK\n");
                out.flush();
            }
        } else {
            mismatches += 1;
            all_ok = false;
            if (!opts.status) {
                if (escaped) out.writeByte('\\');
                out.write(escaped_body);
                out.write(": FAILED\n");
                out.flush();
            }
        }
    }

    if (properly_formatted == 0) {
        // No usable lines at all.
        if (!opts.status)
            diag(&.{ "zhashsum: ", sums_path, ": no properly formatted checksum lines found\n" });
        return false;
    }

    if (verified == 0 and mismatches == 0 and read_failures == 0) {
        // Everything was an ignored-missing entry (--ignore-missing).
        diag(&.{ "zhashsum: ", sums_path, ": no file was verified\n" });
        all_ok = false;
    }

    var numbuf: [128]u8 = undefined;
    if (!opts.status and mismatches > 0) {
        const s = std.fmt.bufPrint(&numbuf, "zhashsum: WARNING: {d} computed checksum{s} did NOT match\n", .{ mismatches, if (mismatches == 1) "" else "s" }) catch "";
        writeAllFd(libc.STDERR_FILENO, s);
    }
    if (!opts.status and read_failures > 0) {
        const s = std.fmt.bufPrint(&numbuf, "zhashsum: WARNING: {d} listed file{s} could not be read\n", .{ read_failures, if (read_failures == 1) "" else "s" }) catch "";
        writeAllFd(libc.STDERR_FILENO, s);
    }
    if (opts.strict and improper > 0) all_ok = false;

    return all_ok;
}

// ---------------------------------------------------------------------------
// Argument parsing / main
// ---------------------------------------------------------------------------

const help_text =
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
    \\  -t, --text          read in text mode (default)
    \\  -c, --check         read checksums from the FILEs and check them
    \\      --ignore-missing don't fail or report status for missing files
    \\      --quiet         don't print OK for each successfully verified file
    \\      --status        don't output anything, status code shows success
    \\      --strict        exit non-zero for improperly formatted checksum lines
    \\  -w, --warn          warn about improperly formatted checksum lines
    \\      --help          display this help and exit
    \\      --version       output version information and exit
    \\
    \\When checking, the input should be a former output of this program.
    \\With no FILE, or when FILE is -, read standard input.
    \\
;

fn matchAlgo(arg: []const u8) ?Algorithm {
    if (std.mem.eql(u8, arg, "--md5")) return .md5;
    if (std.mem.eql(u8, arg, "--sha1")) return .sha1;
    if (std.mem.eql(u8, arg, "--sha224")) return .sha224;
    if (std.mem.eql(u8, arg, "--sha256")) return .sha256;
    if (std.mem.eql(u8, arg, "--sha384")) return .sha384;
    if (std.mem.eql(u8, arg, "--sha512")) return .sha512;
    if (std.mem.eql(u8, arg, "--blake2b")) return .blake2b256;
    if (std.mem.eql(u8, arg, "--blake2s")) return .blake2s256;
    if (std.mem.eql(u8, arg, "--blake3")) return .blake3;
    return null;
}

pub fn main(init: std.process.Init) void {
    const allocator = init.gpa;

    var algo: Algorithm = .sha256;
    var binary_mode = false;
    var check_mode = false;
    var copts = CheckOptions{};
    var no_more_opts = false;

    var files: std.ArrayListUnmanaged([]const u8) = .empty;
    defer files.deinit(allocator);

    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next();

    while (args.next()) |arg| {
        if (!no_more_opts and std.mem.eql(u8, arg, "--")) {
            no_more_opts = true;
            continue;
        }

        if (!no_more_opts and arg.len > 1 and arg[0] == '-') {
            if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
                writeAllFd(libc.STDOUT_FILENO, help_text);
                return;
            } else if (std.mem.eql(u8, arg, "--version")) {
                writeAllFd(libc.STDOUT_FILENO, "zhashsum (zig_core_utils)\n");
                return;
            } else if (matchAlgo(arg)) |a| {
                algo = a;
            } else if (std.mem.eql(u8, arg, "-b") or std.mem.eql(u8, arg, "--binary")) {
                binary_mode = true;
            } else if (std.mem.eql(u8, arg, "-t") or std.mem.eql(u8, arg, "--text")) {
                binary_mode = false;
            } else if (std.mem.eql(u8, arg, "-c") or std.mem.eql(u8, arg, "--check")) {
                check_mode = true;
            } else if (std.mem.eql(u8, arg, "--status")) {
                copts.status = true;
            } else if (std.mem.eql(u8, arg, "--quiet")) {
                copts.quiet = true;
            } else if (std.mem.eql(u8, arg, "-w") or std.mem.eql(u8, arg, "--warn")) {
                copts.warn = true;
            } else if (std.mem.eql(u8, arg, "--strict")) {
                copts.strict = true;
            } else if (std.mem.eql(u8, arg, "--ignore-missing")) {
                copts.ignore_missing = true;
            } else {
                diag(&.{ "zhashsum: unrecognized option '", arg, "'\nTry 'zhashsum --help' for more information.\n" });
                std.process.exit(1);
            }
        } else {
            files.append(allocator, arg) catch {
                diag(&.{"zhashsum: out of memory\n"});
                std.process.exit(1);
            };
        }
    }

    var out = OutputBuffer{};
    var had_error = false;

    if (check_mode) {
        if (files.items.len == 0) {
            if (!checkFile(allocator, &out, "-", true, algo, copts)) had_error = true;
        } else {
            for (files.items) |sums| {
                const is_stdin = std.mem.eql(u8, sums, "-");
                if (!checkFile(allocator, &out, sums, is_stdin, algo, copts)) had_error = true;
            }
        }
    } else if (files.items.len == 0) {
        var digest: [64]u8 = undefined;
        var derr: c_int = 0;
        if (computeDigest(allocator, "-", true, algo, &digest, &derr)) |dlen| {
            printChecksumLine(&out, digest[0..dlen], "-", true, binary_mode);
        } else {
            diagErrno("-", derr);
            had_error = true;
        }
    } else {
        for (files.items) |path| {
            const is_stdin = std.mem.eql(u8, path, "-");
            var digest: [64]u8 = undefined;
            var derr: c_int = 0;
            if (computeDigest(allocator, path, is_stdin, algo, &digest, &derr)) |dlen| {
                printChecksumLine(&out, digest[0..dlen], path, is_stdin, binary_mode);
            } else {
                diagErrno(path, derr);
                had_error = true;
            }
        }
    }

    out.flush();

    if (had_error) std.process.exit(1);
}
