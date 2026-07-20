//! Externally-anchored parity tests for zstdbuf (GNU stdbuf clone).
//!
//! Two layers of anchoring, neither of which is a roundtrip:
//!
//!  1. UNIT tests over the size grammar (main.parseSize). Every expected value
//!     is a literal number produced by real GNU coreutils 9.10 `stdbuf`
//!     (captured with `gstdbuf -o <MODE> env | grep _STDBUF_O`). The source of
//!     truth is an external binary, not this library.
//!
//!  2. INTEGRATION tests that actually execute the freshly-built `zstdbuf`
//!     binary AND the real GNU `gstdbuf`, then diff exit status and the
//!     `_STDBUF_O=` line each emits into the child environment. If GNU stdbuf
//!     is not installed the integration tests SkipZigTest (they never silently
//!     pass); the unit layer still holds the line with literal GNU values.
//!
//! Anchor binary: GNU coreutils 9.10 `stdbuf` (Homebrew `gstdbuf`).
//! Grammar reference: coreutils stdbuf.c parse_size (xstrtoumax, valid
//! suffixes "EGkKMPTYZ0"); KB=1000, K=1024, MB=1000000, M=1048576, and so on.
//!
//! Process spawning uses libc popen/pclose directly (this Zig std ships the
//! Io-threaded process API, which a plain `test` block has no Io handle for).

const std = @import("std");
const testing = std.testing;
const main = @import("main.zig");

// ===========================================================================
// Layer 1 — size grammar unit tests (literal GNU-9.10 values)
// ===========================================================================

test "parseSize: bare decimals pass through unchanged" {
    // gstdbuf -o N env  ->  _STDBUF_O=N
    try testing.expectEqual(@as(usize, 0), try main.parseSize("0"));
    try testing.expectEqual(@as(usize, 512), try main.parseSize("512"));
    try testing.expectEqual(@as(usize, 4096), try main.parseSize("4096"));
    try testing.expectEqual(@as(usize, 100000), try main.parseSize("100000"));
}

test "parseSize: binary (1024) suffixes match GNU" {
    // gstdbuf -o 1K env -> _STDBUF_O=1024, etc.
    try testing.expectEqual(@as(usize, 1024), try main.parseSize("1K"));
    try testing.expectEqual(@as(usize, 2048), try main.parseSize("2k")); // lowercase k allowed
    try testing.expectEqual(@as(usize, 1048576), try main.parseSize("1M"));
    try testing.expectEqual(@as(usize, 1073741824), try main.parseSize("1G"));
    try testing.expectEqual(@as(usize, 3221225472), try main.parseSize("3G"));
    try testing.expectEqual(@as(usize, 1099511627776), try main.parseSize("1T"));
    try testing.expectEqual(@as(usize, 1125899906842624), try main.parseSize("1P"));
    try testing.expectEqual(@as(usize, 1152921504606846976), try main.parseSize("1E"));
}

test "parseSize: iB suffix is the same as the bare 1024 form" {
    // gstdbuf -o 1KiB env -> _STDBUF_O=1024
    try testing.expectEqual(@as(usize, 1024), try main.parseSize("1KiB"));
    try testing.expectEqual(@as(usize, 1048576), try main.parseSize("1MiB"));
    try testing.expectEqual(@as(usize, 1073741824), try main.parseSize("1GiB"));
}

test "parseSize: B suffix is the decimal (1000) form" {
    // gstdbuf -o 1KB env -> _STDBUF_O=1000
    try testing.expectEqual(@as(usize, 1000), try main.parseSize("1KB"));
    try testing.expectEqual(@as(usize, 1000000), try main.parseSize("1MB"));
    try testing.expectEqual(@as(usize, 1000000000), try main.parseSize("1GB"));
}

test "parseSize: leading-zero-with-suffix is a number, not the '0' mode" {
    // gstdbuf -o 0K env -> _STDBUF_O=0  (0*1024)
    try testing.expectEqual(@as(usize, 0), try main.parseSize("0K"));
}

test "parseSize: invalid modes are rejected (GNU exit 125, 'Invalid argument')" {
    // gstdbuf rejects these with exit 125.
    try testing.expectError(error.InvalidMode, main.parseSize("")); // empty
    try testing.expectError(error.InvalidMode, main.parseSize("xyz")); // no digits
    try testing.expectError(error.InvalidMode, main.parseSize("-1")); // sign
    try testing.expectError(error.InvalidMode, main.parseSize("1.5")); // fraction
    try testing.expectError(error.InvalidMode, main.parseSize("1t")); // lowercase t not allowed
    try testing.expectError(error.InvalidMode, main.parseSize("1e")); // lowercase e not allowed
    try testing.expectError(error.InvalidMode, main.parseSize("1Kb")); // lowercase b
    try testing.expectError(error.InvalidMode, main.parseSize("1kb")); // lowercase kb
    try testing.expectError(error.InvalidMode, main.parseSize("1Gib")); // lowercase i
    try testing.expectError(error.InvalidMode, main.parseSize("1KB2")); // trailing junk
    try testing.expectError(error.InvalidMode, main.parseSize("0L")); // 0 then bad suffix
}

test "parseSize: overflow is TooLarge, not a panic (audit finding #2)" {
    // The pre-fix code did `size *= mult` and panicked on integer overflow.
    // GNU: exit 125 'Value too large to be stored in data type'.
    // gstdbuf -o 1Z -> Value too large;  1Y likewise (1024^7/^8 exceed u64).
    try testing.expectError(error.TooLarge, main.parseSize("1Z"));
    try testing.expectError(error.TooLarge, main.parseSize("1Y"));
    // A digit string larger than u64.
    try testing.expectError(error.TooLarge, main.parseSize("99999999999999999999999999"));
    // The exact crasher from the audit report.
    try testing.expectError(error.TooLarge, main.parseSize("18000000000000000000K"));
}

test "parseMode: L is line mode; everything else is a size" {
    try testing.expectEqual(main.Mode.line, try main.parseMode("L"));
    try testing.expectEqual(main.Mode{ .size = 0 }, try main.parseMode("0"));
    try testing.expectEqual(main.Mode{ .size = 1024 }, try main.parseMode("1K"));
    // Lowercase l is NOT line mode in GNU (only 'L'); it is an invalid size.
    try testing.expectError(error.InvalidMode, main.parseMode("l"));
}

// ===========================================================================
// Layer 2 — integration parity against the real GNU stdbuf binary
// ===========================================================================

extern "c" fn popen(cmd: [*:0]const u8, mode: [*:0]const u8) ?*anyopaque;
extern "c" fn pclose(stream: *anyopaque) c_int;
extern "c" fn fread(ptr: [*]u8, size: usize, nmemb: usize, stream: *anyopaque) usize;
extern "c" fn fopen(path: [*:0]const u8, mode: [*:0]const u8) ?*anyopaque;
extern "c" fn fputs(s: [*:0]const u8, stream: *anyopaque) c_int;
extern "c" fn fclose(stream: *anyopaque) c_int;
extern "c" fn access(path: [*:0]const u8, mode: c_int) c_int;
const F_OK: c_int = 0;

const gnu_candidates = [_][]const u8{
    "/opt/homebrew/opt/coreutils/libexec/gnubin/stdbuf",
    "/opt/homebrew/bin/gstdbuf",
    "/usr/local/bin/gstdbuf",
};

const zstdbuf_candidates = [_][]const u8{
    "zig-out/bin/zstdbuf",
};

fn firstExisting(paths: []const []const u8) ?[]const u8 {
    var buf: [512]u8 = undefined;
    for (paths) |p| {
        const z = std.fmt.bufPrintZ(&buf, "{s}", .{p}) catch continue;
        if (access(z.ptr, F_OK) == 0) return p;
    }
    return null;
}

fn getBins() !struct { gnu: []const u8, z: []const u8 } {
    const gnu = firstExisting(&gnu_candidates) orelse return error.SkipZigTest;
    const z = firstExisting(&zstdbuf_candidates) orelse return error.SkipZigTest;
    return .{ .gnu = gnu, .z = z };
}

const Captured = struct {
    code: u8,
    out: []u8,
    fn deinit(self: *Captured, a: std.mem.Allocator) void {
        a.free(self.out);
    }
};

/// Run a shell command via popen, capturing stdout and the exit status.
fn shCapture(a: std.mem.Allocator, cmd: [:0]const u8) !Captured {
    const f = popen(cmd.ptr, "r") orelse return error.PopenFailed;
    var out = std.ArrayListUnmanaged(u8).empty;
    errdefer out.deinit(a);
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = fread(&buf, 1, buf.len, f);
        if (n == 0) break;
        try out.appendSlice(a, buf[0..n]);
    }
    const status = pclose(f);
    // POSIX wait status: low 7 bits == 0 means normal exit; code is bits 8..15.
    const code: u8 = if (status >= 0 and (status & 0x7f) == 0)
        @intCast((status >> 8) & 0xff)
    else
        255;
    return .{ .code = code, .out = try out.toOwnedSlice(a) };
}

/// Build `'bin' 'arg1' 'arg2' ...` with each token single-quoted. Test inputs
/// contain no single quotes, so naive quoting is safe here.
fn buildCmd(a: std.mem.Allocator, bin: []const u8, args: []const []const u8) ![:0]u8 {
    var s = std.ArrayListUnmanaged(u8).empty;
    defer s.deinit(a);
    try s.append(a, '\'');
    try s.appendSlice(a, bin);
    try s.append(a, '\'');
    for (args) |arg| {
        try s.appendSlice(a, " '");
        try s.appendSlice(a, arg);
        try s.append(a, '\'');
    }
    return try a.dupeZ(u8, s.items);
}

fn runBin(a: std.mem.Allocator, bin: []const u8, args: []const []const u8) !Captured {
    const cmd = try buildCmd(a, bin, args);
    defer a.free(cmd);
    return shCapture(a, cmd);
}

/// Extract the "_STDBUF_O=..." line (no trailing newline) from an env dump.
fn stdbufOLine(a: std.mem.Allocator, dump: []const u8) !?[]u8 {
    var it = std.mem.splitScalar(u8, dump, '\n');
    while (it.next()) |line| {
        if (std.mem.startsWith(u8, line, "_STDBUF_O=")) return try a.dupe(u8, line);
    }
    return null;
}

test "integration: _STDBUF_O output matches GNU for a spread of modes" {
    const a = testing.allocator;
    const bins = try getBins();

    const modes = [_][]const u8{
        "0",    "L",    "512",  "4096", "100000",
        "1K",   "2k",   "1KB",  "1M",   "1MB",
        "1G",   "3G",   "1T",   "1P",   "1E",
        "1KiB", "1MiB", "1GiB", "0K",
    };
    for (modes) |m| {
        var zr = try runBin(a, bins.z, &.{ "-o", m, "env" });
        defer zr.deinit(a);
        var gr = try runBin(a, bins.gnu, &.{ "-o", m, "env" });
        defer gr.deinit(a);

        try testing.expectEqual(@as(u8, 0), gr.code);
        try testing.expectEqual(gr.code, zr.code);

        const zl = try stdbufOLine(a, zr.out);
        defer if (zl) |l| a.free(l);
        const gl = try stdbufOLine(a, gr.out);
        defer if (gl) |l| a.free(l);

        try testing.expect(zl != null);
        try testing.expect(gl != null);
        testing.expectEqualStrings(gl.?, zl.?) catch |e| {
            std.debug.print("mode '{s}': GNU='{s}' zstdbuf='{s}'\n", .{ m, gl.?, zl.? });
            return e;
        };
    }
}

test "integration: exit codes match GNU for invalid/error inputs" {
    const a = testing.allocator;
    const bins = try getBins();

    const cases = [_][]const []const u8{
        &.{ "-o", "xyz", "true" }, // invalid mode
        &.{ "-o", "1Z", "true" }, // overflow -> Value too large
        &.{ "-o", "18000000000000000000K", "true" }, // the audit crasher
        &.{ "-o", "1t", "true" }, // bad suffix case
        &.{ "-o", "1Gib", "true" }, // bad iB case
        &.{ "-i", "L", "true" }, // line-buffering stdin is meaningless
        &.{ "-o", "4096", "true" }, // valid: should exit 0
        &.{ "-o", "0", "echo", "hi" }, // valid run, exit 0
        &.{"echo"}, // no mode option -> "must specify a buffering mode"
        &.{}, // no operand -> missing operand
        &.{ "-o", "0", "no_such_cmd_zzz_123" }, // command not found -> 127
    };
    for (cases, 0..) |extra, idx| {
        var zr = try runBin(a, bins.z, extra);
        defer zr.deinit(a);
        var gr = try runBin(a, bins.gnu, extra);
        defer gr.deinit(a);
        testing.expectEqual(gr.code, zr.code) catch |e| {
            std.debug.print("case[{d}]: GNU exit={d} zstdbuf exit={d}\n", .{ idx, gr.code, zr.code });
            return e;
        };
    }
}

test "integration: --version and --help exit 0 like GNU" {
    const a = testing.allocator;
    const bins = try getBins();
    for ([_][]const u8{ "--version", "--help" }) |flag| {
        var zr = try runBin(a, bins.z, &.{flag});
        defer zr.deinit(a);
        var gr = try runBin(a, bins.gnu, &.{flag});
        defer gr.deinit(a);
        try testing.expectEqual(@as(u8, 0), gr.code);
        try testing.expectEqual(gr.code, zr.code);
        try testing.expect(zr.out.len > 0);
    }
}

test "integration: buffering is actually applied (finding #1, functional)" {
    // The core bug: zstdbuf used to be a no-op. This proves the shipped
    // libstdbuf is pre-loaded and setvbuf() takes effect. A C-stdio producer
    // prints one line, then _exit()s WITHOUT flushing stdio (so buffered output
    // is discarded, never written to the pipe). Piped to `head -1`:
    //   * default full buffering  -> line stays in the buffer, is discarded at
    //                                _exit, head sees nothing.
    //   * zstdbuf -o0 (unbuffered) -> printf writes straight to the pipe, head
    //                                 sees FIRSTLINE.
    // GNU `gstdbuf -o0` is the external anchor: identical flushed result.
    const a = testing.allocator;
    const bins = try getBins();

    const src = "/tmp/zstdbuf_parity_producer.c";
    const exe = "/tmp/zstdbuf_parity_producer";

    // Write the producer via libc stdio (this std's file IO needs an Io handle).
    const f = fopen(src, "w") orelse return error.SkipZigTest;
    _ = fputs("#include <stdio.h>\n#include <unistd.h>\n" ++
        "int main(void){printf(\"FIRSTLINE\\n\");usleep(700000);_exit(0);}\n", f);
    _ = fclose(f);

    // Compile. cc may be absent in some sandboxes -> skip cleanly.
    var cc = try shCapture(a, "cc -O2 -o " ++ exe ++ " " ++ src ++ " 2>/dev/null; echo done");
    cc.deinit(a);
    if (access(exe, F_OK) != 0) return error.SkipZigTest;

    const plain_cmd = exe ++ " | head -1";
    var plain = try shCapture(a, plain_cmd);
    defer plain.deinit(a);

    const zcmd = try std.fmt.allocPrintSentinel(a, "'{s}' -o0 {s} | head -1", .{ bins.z, exe }, 0);
    defer a.free(zcmd);
    var zout = try shCapture(a, zcmd);
    defer zout.deinit(a);

    const gcmd = try std.fmt.allocPrintSentinel(a, "'{s}' -o0 {s} | head -1", .{ bins.gnu, exe }, 0);
    defer a.free(gcmd);
    var gout = try shCapture(a, gcmd);
    defer gout.deinit(a);

    const plain_trim = std.mem.trim(u8, plain.out, " \n\r\t");
    const z_trim = std.mem.trim(u8, zout.out, " \n\r\t");
    const g_trim = std.mem.trim(u8, gout.out, " \n\r\t");

    // Fully SIP-locked environment where even GNU can't inject: nothing to
    // distinguish, skip rather than assert a platform limitation.
    if (g_trim.len == 0 and z_trim.len == 0) return error.SkipZigTest;

    // zstdbuf must behave exactly like GNU stdbuf, and must actually flush.
    try testing.expectEqualStrings(g_trim, z_trim);
    try testing.expectEqualStrings("FIRSTLINE", z_trim);
    // The un-buffered control really was buffered: nothing flushed before exit.
    try testing.expectEqualStrings("", plain_trim);
}
