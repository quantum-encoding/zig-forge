//! Externally-anchored tests for zbasenc (GNU `basenc` clone).
//!
//! Two independent anchors, neither authored by this codebase:
//!
//!  1. RFC 4648 §10 test vectors (the literal `f`/`fo`/`foo`/`foob`/`fooba`/
//!     `foobar` encodings for base16/base32/base32hex/base64). These bytes are
//!     copied verbatim from the RFC; they are NOT roundtrip-derived. Both encode
//!     (input -> expected) and decode (expected -> input) directions are checked
//!     against the RFC literals, satisfying the zig-forge golden rule §1.
//!
//!  2. The real GNU `basenc` binary (coreutils 9.10). When present on the host,
//!     every case below is diffed byte-for-byte (stdout AND exit status) against
//!     GNU. This is the true external oracle: if zbasenc and GNU disagree on any
//!     input the test fails. base2msbf/base2lsbf (a GNU extension, not in RFC
//!     4648) are anchored this way plus documented bit-order literals.
//!
//! The path to the freshly-built zbasenc exe is injected by build.zig via the
//! `build_options` module so the test always exercises the current binary.

const std = @import("std");
const build_options = @import("build_options");

// The zig_core_utils tree runs on the Io-threaded std: process spawning, file
// I/O and directory access all take an explicit `std.Io`. In test builds
// `std.testing.io` is the ready-to-use threaded instance.
const io = std.testing.io;

const zbasenc_path: []const u8 = build_options.zbasenc_path;

const gnu_candidates = [_][]const u8{
    "/opt/homebrew/opt/coreutils/libexec/gnubin/basenc",
    "/opt/homebrew/bin/gbasenc",
    "/usr/bin/basenc",
    "/bin/basenc",
};

fn gnuPath() ?[]const u8 {
    for (gnu_candidates) |p| {
        std.Io.Dir.accessAbsolute(io, p, .{}) catch continue;
        return p;
    }
    return null;
}

const RunResult = struct {
    stdout: []u8,
    stderr: []u8,
    exit_code: u8, // process exit code; 255 for a signal/abnormal termination

    fn deinit(self: *RunResult, a: std.mem.Allocator) void {
        a.free(self.stdout);
        a.free(self.stderr);
    }
};

/// Spawn `exe` with `argv_tail` args, feed `stdin` on its stdin pipe, and
/// capture stdout, stderr and the exit code. `argv_tail` omits the program name.
/// Payloads here are small (well under a pipe buffer), so writing stdin fully
/// and then draining stdout/stderr sequentially cannot deadlock.
fn run(
    a: std.mem.Allocator,
    exe: []const u8,
    argv_tail: []const []const u8,
    stdin: []const u8,
) !RunResult {
    var argv = std.ArrayListUnmanaged([]const u8).empty;
    defer argv.deinit(a);
    try argv.append(a, exe);
    for (argv_tail) |arg| try argv.append(a, arg);

    var child = try std.process.spawn(io, .{
        .argv = argv.items,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    errdefer child.kill(io);

    // Write stdin then close it so the child observes EOF.
    try child.stdin.?.writeStreamingAll(io, stdin);
    child.stdin.?.close(io);
    child.stdin = null;

    var stdout_buf = std.ArrayListUnmanaged(u8).empty;
    var stderr_buf = std.ArrayListUnmanaged(u8).empty;
    errdefer stdout_buf.deinit(a);
    errdefer stderr_buf.deinit(a);

    try drain(a, child.stdout.?, &stdout_buf);
    try drain(a, child.stderr.?, &stderr_buf);

    const term = try child.wait(io);
    const code: u8 = switch (term) {
        .exited => |c| c,
        else => 255,
    };

    return .{
        .stdout = try stdout_buf.toOwnedSlice(a),
        .stderr = try stderr_buf.toOwnedSlice(a),
        .exit_code = code,
    };
}

fn drain(a: std.mem.Allocator, file: std.Io.File, out: *std.ArrayListUnmanaged(u8)) !void {
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = file.readStreaming(io, &.{buf[0..]}) catch |e| switch (e) {
            error.EndOfStream => break,
            else => return e,
        };
        if (n == 0) break;
        try out.appendSlice(a, buf[0..n]);
    }
}

fn runZ(a: std.mem.Allocator, argv: []const []const u8, stdin: []const u8) !RunResult {
    return run(a, zbasenc_path, argv, stdin);
}

// ---------------------------------------------------------------------------
// Anchor 1: RFC 4648 §10 literal vectors (external — copied from the RFC).
// ---------------------------------------------------------------------------

const Vec = struct { plain: []const u8, enc: []const u8 };

// RFC 4648 §10 BASE64
const base64_vectors = [_]Vec{
    .{ .plain = "", .enc = "" },
    .{ .plain = "f", .enc = "Zg==" },
    .{ .plain = "fo", .enc = "Zm8=" },
    .{ .plain = "foo", .enc = "Zm9v" },
    .{ .plain = "foob", .enc = "Zm9vYg==" },
    .{ .plain = "fooba", .enc = "Zm9vYmE=" },
    .{ .plain = "foobar", .enc = "Zm9vYmFy" },
};

// RFC 4648 §10 BASE32
const base32_vectors = [_]Vec{
    .{ .plain = "", .enc = "" },
    .{ .plain = "f", .enc = "MY======" },
    .{ .plain = "fo", .enc = "MZXQ====" },
    .{ .plain = "foo", .enc = "MZXW6===" },
    .{ .plain = "foob", .enc = "MZXW6YQ=" },
    .{ .plain = "fooba", .enc = "MZXW6YTB" },
    .{ .plain = "foobar", .enc = "MZXW6YTBOI======" },
};

// RFC 4648 §10 BASE32-HEX
const base32hex_vectors = [_]Vec{
    .{ .plain = "", .enc = "" },
    .{ .plain = "f", .enc = "CO======" },
    .{ .plain = "fo", .enc = "CPNG====" },
    .{ .plain = "foo", .enc = "CPNMU===" },
    .{ .plain = "foob", .enc = "CPNMUOG=" },
    .{ .plain = "fooba", .enc = "CPNMUOJ1" },
    .{ .plain = "foobar", .enc = "CPNMUOJ1E8======" },
};

// RFC 4648 §10 BASE16 (GNU basenc emits uppercase)
const base16_vectors = [_]Vec{
    .{ .plain = "", .enc = "" },
    .{ .plain = "f", .enc = "66" },
    .{ .plain = "fo", .enc = "666F" },
    .{ .plain = "foo", .enc = "666F6F" },
    .{ .plain = "foob", .enc = "666F6F62" },
    .{ .plain = "fooba", .enc = "666F6F6261" },
    .{ .plain = "foobar", .enc = "666F6F626172" },
};

fn checkVectors(a: std.mem.Allocator, flag: []const u8, vectors: []const Vec) !void {
    for (vectors) |v| {
        // encode: plain -> enc (+trailing newline unless output is empty)
        var er = try runZ(a, &.{ flag, "-w", "0" }, v.plain);
        defer er.deinit(a);
        try std.testing.expectEqual(@as(u8, 0), er.exit_code);
        try std.testing.expectEqualStrings(v.enc, er.stdout);

        // decode: enc -> plain
        var dr = try runZ(a, &.{ flag, "-d" }, v.enc);
        defer dr.deinit(a);
        try std.testing.expectEqual(@as(u8, 0), dr.exit_code);
        try std.testing.expectEqualStrings(v.plain, dr.stdout);
    }
}

test "RFC 4648 §10 base64 vectors (encode+decode, literal)" {
    try checkVectors(std.testing.allocator, "--base64", &base64_vectors);
}
test "RFC 4648 §10 base32 vectors (encode+decode, literal)" {
    try checkVectors(std.testing.allocator, "--base32", &base32_vectors);
}
test "RFC 4648 §10 base32hex vectors (encode+decode, literal)" {
    try checkVectors(std.testing.allocator, "--base32hex", &base32hex_vectors);
}
test "RFC 4648 §10 base16 vectors (encode+decode, literal)" {
    try checkVectors(std.testing.allocator, "--base16", &base16_vectors);
}

test "base2 bit-order literals (GNU extension; derived from byte bits)" {
    const a = std.testing.allocator;
    // 'f' = 0x66 = 0b01100110. MSB-first spells the byte high-bit -> low-bit.
    // LSB-first spells low-bit -> high-bit; for the palindromic 0x66 it is the same.
    {
        var r = try runZ(a, &.{ "--base2msbf", "-w", "0" }, "f");
        defer r.deinit(a);
        try std.testing.expectEqualStrings("01100110", r.stdout);
    }
    // 'o' = 0x6F = 0b01101111. LSB-first => 1,1,1,1,0,1,1,0 = "11110110".
    {
        var r = try runZ(a, &.{ "--base2lsbf", "-w", "0" }, "fo");
        defer r.deinit(a);
        try std.testing.expectEqualStrings("0110011011110110", r.stdout);
    }
    // decode round to the same literal must reproduce the byte
    {
        var r = try runZ(a, &.{ "--base2msbf", "-d" }, "01100110");
        defer r.deinit(a);
        try std.testing.expectEqual(@as(u8, 0), r.exit_code);
        try std.testing.expectEqualStrings("f", r.stdout);
    }
}

// ---------------------------------------------------------------------------
// Anchor: documented GNU rejection behavior (exit 1 + "invalid input").
// These expectations were captured from GNU basenc 9.10 and are the exact
// bytes/exit codes GNU produces; verified independently below when GNU exists.
// ---------------------------------------------------------------------------

const NegCase = struct {
    flag: []const u8,
    input: []const u8,
    // bytes GNU still emits to stdout before erroring, as lowercase hex
    out_hex: []const u8,
};

const negatives = [_]NegCase{
    .{ .flag = "--base64", .input = "@@@", .out_hex = "" }, // invalid char, nothing decodable
    .{ .flag = "--base64", .input = "A", .out_hex = "" }, // 4n+1: lone sextet
    .{ .flag = "--base64", .input = "AB", .out_hex = "00" }, // trailing bits nonzero
    .{ .flag = "--base64", .input = "ABC", .out_hex = "0010" }, // trailing bits nonzero
    .{ .flag = "--base64", .input = "QR", .out_hex = "41" }, // trailing bits nonzero
    .{ .flag = "--base64", .input = "Zm9@", .out_hex = "666f" }, // invalid char mid-stream
    .{ .flag = "--base16", .input = "A", .out_hex = "" }, // dangling nibble
    .{ .flag = "--base16", .input = "ABC", .out_hex = "ab" }, // dangling nibble after 1 byte
    .{ .flag = "--base32", .input = "AB", .out_hex = "00" }, // trailing bits nonzero
    .{ .flag = "--base2msbf", .input = "0100000", .out_hex = "" }, // 7 bits, incomplete byte
    .{ .flag = "--base2msbf", .input = "010000010", .out_hex = "41" }, // 9 bits, 1 trailing
};

fn hexToBytes(a: std.mem.Allocator, hex: []const u8) ![]u8 {
    const out = try a.alloc(u8, hex.len / 2);
    _ = try std.fmt.hexToBytes(out, hex);
    return out;
}

test "invalid decode input -> exit 1 + partial stdout (GNU-documented)" {
    const a = std.testing.allocator;
    for (negatives) |n| {
        var r = try runZ(a, &.{ n.flag, "-d" }, n.input);
        defer r.deinit(a);
        try std.testing.expectEqual(@as(u8, 1), r.exit_code);
        const want = try hexToBytes(a, n.out_hex);
        defer a.free(want);
        try std.testing.expectEqualSlices(u8, want, r.stdout);
        try std.testing.expectEqualStrings("zbasenc: invalid input\n", r.stderr);
    }
}

test "valid unpadded/short groups accepted like GNU (QQ -> A, ABA -> 2 bytes)" {
    const a = std.testing.allocator;
    {
        var r = try runZ(a, &.{ "--base64", "-d" }, "QQ"); // trailing bits zero
        defer r.deinit(a);
        try std.testing.expectEqual(@as(u8, 0), r.exit_code);
        try std.testing.expectEqualStrings("A", r.stdout);
    }
    {
        var r = try runZ(a, &.{ "--base64", "-d" }, "ABA"); // 3 sextets, trailing zero
        defer r.deinit(a);
        try std.testing.expectEqual(@as(u8, 0), r.exit_code);
        const want = [_]u8{ 0x00, 0x10 };
        try std.testing.expectEqualSlices(u8, &want, r.stdout);
    }
}

test "ignore-garbage skips invalid chars but still length-validates" {
    const a = std.testing.allocator;
    {
        var r = try runZ(a, &.{ "--base64", "-d", "-i" }, "Zm@9vYmFy");
        defer r.deinit(a);
        try std.testing.expectEqual(@as(u8, 0), r.exit_code);
        try std.testing.expectEqualStrings("foobar", r.stdout);
    }
    {
        // -i must not paper over a truncated/invalid-length group
        var r = try runZ(a, &.{ "--base64", "-d", "-i" }, "AB");
        defer r.deinit(a);
        try std.testing.expectEqual(@as(u8, 1), r.exit_code);
    }
}

test "-w 0 emits no trailing newline; default wrap does" {
    const a = std.testing.allocator;
    {
        var r = try runZ(a, &.{ "--base64", "-w", "0" }, "foobar");
        defer r.deinit(a);
        try std.testing.expectEqualStrings("Zm9vYmFy", r.stdout); // no \n
    }
    {
        var r = try runZ(a, &.{"--base64"}, "foobar"); // default wrap 76
        defer r.deinit(a);
        try std.testing.expectEqualStrings("Zm9vYmFy\n", r.stdout);
    }
}

test "missing file -> GNU-style errno diagnostic, exit 1, no stack trace" {
    const a = std.testing.allocator;
    var r = try runZ(a, &.{ "--base64", "/no/such/zbasenc/path/xyz" }, "");
    defer r.deinit(a);
    try std.testing.expectEqual(@as(u8, 1), r.exit_code);
    try std.testing.expectEqualStrings(
        "zbasenc: /no/such/zbasenc/path/xyz: No such file or directory\n",
        r.stderr,
    );
    try std.testing.expectEqual(@as(usize, 0), r.stdout.len);
}

test "invalid wrap size -> diagnostic + exit 1 (does not swallow as filename)" {
    const a = std.testing.allocator;
    var r = try runZ(a, &.{ "--base64", "-w", "abc" }, "hi");
    defer r.deinit(a);
    try std.testing.expectEqual(@as(u8, 1), r.exit_code);
    try std.testing.expectEqualStrings("zbasenc: invalid wrap size: 'abc'\n", r.stderr);
}

test "no allocator-leak trace on stderr for a plain encode (Debug build)" {
    const a = std.testing.allocator;
    var r = try runZ(a, &.{"--base64"}, "foobar");
    defer r.deinit(a);
    try std.testing.expectEqual(@as(u8, 0), r.exit_code);
    // The unfreed readInput buffer used to print a DebugAllocator leak trace.
    try std.testing.expectEqual(@as(usize, 0), r.stderr.len);
}

// ---------------------------------------------------------------------------
// Anchor 2: differential test against the real GNU basenc, when installed.
// ---------------------------------------------------------------------------

const DiffCase = struct { argv: []const []const u8, input: []const u8 };

test "differential vs real GNU basenc (stdout + exit code)" {
    const a = std.testing.allocator;
    const gnu = gnuPath() orelse {
        std.debug.print("SKIP: no GNU basenc found; RFC/literal anchors still ran\n", .{});
        return error.SkipZigTest;
    };

    const inputs = [_][]const u8{
        "", "f", "fo", "foo", "foob", "fooba", "foobar",
        "hello, world!", "\x00\x01\x02\xff\xfe\x80\x7f", "the quick brown fox",
    };
    const enc_flags = [_][]const u8{
        "--base64", "--base64url", "--base32", "--base32hex", "--base16", "--base2msbf", "--base2lsbf",
    };
    const wraps = [_][]const u8{ "0", "4", "5", "76" };

    for (enc_flags) |flag| {
        for (inputs) |in| {
            for (wraps) |w| {
                // ---- encode ----
                {
                    const argv = [_][]const u8{ flag, "-w", w };
                    var zr = try run(a, zbasenc_path, &argv, in);
                    defer zr.deinit(a);
                    var gr = try run(a, gnu, &argv, in);
                    defer gr.deinit(a);
                    std.testing.expectEqualSlices(u8, gr.stdout, zr.stdout) catch |e| {
                        std.debug.print("encode mismatch flag={s} w={s} in='{s}'\n", .{ flag, w, in });
                        return e;
                    };
                    try std.testing.expectEqual(gr.exit_code, zr.exit_code);
                }
            }
            // ---- roundtrip decode: feed GNU's encoding to both decoders ----
            {
                var gr_enc = try run(a, gnu, &.{ flag, "-w", "0" }, in);
                defer gr_enc.deinit(a);
                const argv = [_][]const u8{ flag, "-d" };
                var zr = try run(a, zbasenc_path, &argv, gr_enc.stdout);
                defer zr.deinit(a);
                var gr = try run(a, gnu, &argv, gr_enc.stdout);
                defer gr.deinit(a);
                std.testing.expectEqualSlices(u8, gr.stdout, zr.stdout) catch |e| {
                    std.debug.print("decode mismatch flag={s} in='{s}'\n", .{ flag, in });
                    return e;
                };
                try std.testing.expectEqual(gr.exit_code, zr.exit_code);
            }
        }
    }

    // Negative decode cases must agree on stdout AND exit code with GNU.
    for (negatives) |n| {
        const argv = [_][]const u8{ n.flag, "-d" };
        var zr = try run(a, zbasenc_path, &argv, n.input);
        defer zr.deinit(a);
        var gr = try run(a, gnu, &argv, n.input);
        defer gr.deinit(a);
        std.testing.expectEqualSlices(u8, gr.stdout, zr.stdout) catch |e| {
            std.debug.print("neg mismatch flag={s} in='{s}'\n", .{ n.flag, n.input });
            return e;
        };
        try std.testing.expectEqual(gr.exit_code, zr.exit_code);
    }
}
