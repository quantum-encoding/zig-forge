//! Externally-anchored parity tests for zshuf.
//!
//! ANCHOR: every test compares zshuf's behaviour against the real GNU
//! coreutils `shuf` binary (GNU coreutils 9.10, /opt/homebrew/bin/gshuf) that
//! ships with Homebrew — inputs AND expected outputs come from a program this
//! repo did not write. There are NO roundtrip-only tests here (see
//! zig-forge/CLAUDE.md golden rule §1).
//!
//! `shuf` output is random, so for shuffle cases we sort BOTH implementations'
//! output and assert the sorted streams are byte-identical: a permutation of a
//! multiset sorts to a unique canonical form, so `sort(zshuf) == sort(gshuf)`
//! proves zshuf emitted exactly the multiset of lines GNU does. That is what
//! catches the blank-line-drop bug (zshuf would emit 2 lines where GNU emits
//! 4, and the sorted streams diverge). Deterministic cases (errors, empty
//! ranges, single values, -o truncation) are compared exactly, rc included.
//!
//! The binary paths are injected by build.zig via env vars ZSHUF_BIN / GSHUF_BIN.

const std = @import("std");
const testing = std.testing;

extern "c" fn popen(command: [*:0]const u8, mode: [*:0]const u8) ?*anyopaque;
extern "c" fn pclose(stream: *anyopaque) c_int;
extern "c" fn fread(ptr: [*]u8, size: usize, nmemb: usize, stream: *anyopaque) usize;
extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;

const Result = struct {
    out: []u8,
    code: u8,
    fn deinit(self: Result, a: std.mem.Allocator) void {
        a.free(self.out);
    }
};

fn envOr(name: [*:0]const u8, default: []const u8) []const u8 {
    if (getenv(name)) |v| return std.mem.span(v);
    return default;
}

fn zbin() []const u8 {
    return envOr("ZSHUF_BIN", "./zig-out/bin/zshuf");
}
fn gbin() []const u8 {
    return envOr("GSHUF_BIN", "/opt/homebrew/bin/gshuf");
}

/// Run a shell command via popen, capturing stdout and the exit code.
fn run(a: std.mem.Allocator, cmd: []const u8) !Result {
    const cmd_z = try a.dupeZ(u8, cmd);
    defer a.free(cmd_z);

    const stream = popen(cmd_z.ptr, "r") orelse return error.PopenFailed;

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(a);
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = fread(&buf, 1, buf.len, stream);
        if (n == 0) break;
        try out.appendSlice(a, buf[0..n]);
    }

    const status = pclose(stream);
    // BSD/macOS pclose returns a wait(2) status; WEXITSTATUS == (status>>8)&0xff.
    const code: u8 = @intCast((status >> 8) & 0xff);

    return .{ .out = try out.toOwnedSlice(a), .code = code };
}

fn sortCmd(a: std.mem.Allocator, comptime template: []const u8, bin: []const u8) ![]u8 {
    // template contains exactly one {s} for the binary path.
    return std.fmt.allocPrint(a, template, .{bin});
}

/// Assert zshuf and gshuf produce the SAME multiset of lines for a pipeline
/// whose template embeds the binary once ({s}) and is post-sorted by the caller.
fn expectSameSorted(comptime template: []const u8) !void {
    const a = testing.allocator;
    const zc = try sortCmd(a, template, zbin());
    defer a.free(zc);
    const gc = try sortCmd(a, template, gbin());
    defer a.free(gc);

    const zr = try run(a, zc);
    defer zr.deinit(a);
    const gr = try run(a, gc);
    defer gr.deinit(a);

    try testing.expectEqualStrings(gr.out, zr.out);
    try testing.expectEqual(gr.code, zr.code);
}

/// Assert zshuf and gshuf produce byte-identical stdout AND the same exit code
/// (for deterministic pipelines: errors, empty output, single values).
fn expectExact(comptime template: []const u8) !void {
    const a = testing.allocator;
    const zc = try sortCmd(a, template, zbin());
    defer a.free(zc);
    const gc = try sortCmd(a, template, gbin());
    defer a.free(gc);

    const zr = try run(a, zc);
    defer zr.deinit(a);
    const gr = try run(a, gc);
    defer gr.deinit(a);

    try testing.expectEqualStrings(gr.out, zr.out);
    try testing.expectEqual(gr.code, zr.code);
}

// --- deterministic parity (exact bytes + exit code, anchored to gshuf) ---

test "negative input range rejected (rc matches gshuf)" {
    // GNU: `shuf -i -3-3` -> "invalid input range", rc 1, no stdout.
    try expectExact("{s} -i -3-3 2>/dev/null; echo rc=$?");
}

test "empty range LO==HI+1 is valid empty output (rc 0)" {
    // GNU: `shuf -i 5-4` -> no output, rc 0.
    try expectExact("{s} -i 5-4 2>/dev/null; echo rc=$?");
}

test "range LO>HI+1 rejected" {
    // GNU: `shuf -i 9-4` -> invalid input range, rc 1.
    try expectExact("{s} -i 9-4 2>/dev/null; echo rc=$?");
}

test "extra file operand alongside -i rejected" {
    // GNU: `shuf -i 1-3 FILE` -> "extra operand", rc 1.
    try expectExact("{s} -i 1-3 /etc/hosts 2>/dev/null; echo rc=$?");
}

test "single value range" {
    try expectExact("{s} -i 5-5");
}

test "empty input produces no output" {
    try expectExact("printf '' | {s}; echo rc=$?");
}

test "single newline input yields one empty line" {
    // GNU keeps the empty line: output is exactly "\n".
    try expectExact("printf '\\n' | {s} | od -An -c");
}

// --- multiset parity for random shuffles (sort both, anchored to gshuf) ---

test "blank/empty lines are preserved (not dropped)" {
    // The core bug: `printf 'a\n\n\nb\n'` must shuffle 4 lines (a, "", "", b),
    // not 2. sort(zshuf) must equal sort(gshuf).
    try expectSameSorted("printf 'a\\n\\n\\nb\\n' | {s} | sort");
}

test "-e treats a bare dash as a literal line" {
    // GNU: `shuf -e a - b` shuffles {a, -, b}; the '-' is not stdin.
    try expectSameSorted("{s} -e a - b | sort");
}

test "integer range is a full permutation" {
    try expectSameSorted("{s} -i 1-50 | sort -n");
}

test "file input full permutation" {
    try expectSameSorted("printf 'one\\ntwo\\nthree\\nfour\\nfive\\n' | {s} | sort");
}

test "trailing line without terminator is kept" {
    // No final newline: input is {alpha, beta}; both impls emit 2 lines.
    try expectSameSorted("printf 'alpha\\nbeta' | {s} | sort");
}

test "-z zero-terminated permutation" {
    try expectSameSorted("printf 'a\\0b\\0c\\0' | {s} -z | tr '\\0' '\\n' | sort");
}

// --- structural parity (line count / membership, anchored to GNU contract) ---

test "-n limits output to COUNT lines like gshuf" {
    const a = testing.allocator;
    const zc = try std.fmt.allocPrint(a, "{s} -i 1-100 -n 3 | wc -l | tr -d ' '", .{zbin()});
    defer a.free(zc);
    const gc = try std.fmt.allocPrint(a, "{s} -i 1-100 -n 3 | wc -l | tr -d ' '", .{gbin()});
    defer a.free(gc);
    const zr = try run(a, zc);
    defer zr.deinit(a);
    const gr = try run(a, gc);
    defer gr.deinit(a);
    try testing.expectEqualStrings("3\n", zr.out);
    try testing.expectEqualStrings(gr.out, zr.out);
}

test "-r repeat emits COUNT lines from the set like gshuf" {
    const a = testing.allocator;
    const zc = try std.fmt.allocPrint(a, "{s} -r -n 8 -e a b c | wc -l | tr -d ' '", .{zbin()});
    defer a.free(zc);
    const gc = try std.fmt.allocPrint(a, "{s} -r -n 8 -e a b c | wc -l | tr -d ' '", .{gbin()});
    defer a.free(gc);
    const zr = try run(a, zc);
    defer zr.deinit(a);
    const gr = try run(a, gc);
    defer gr.deinit(a);
    try testing.expectEqualStrings("8\n", zr.out);
    try testing.expectEqualStrings(gr.out, zr.out);
}

// --- -o truncation (the Darwin O_TRUNC bug), anchored to gshuf ---

test "-o truncates an existing longer file" {
    const a = testing.allocator;
    // Pre-fill with content longer than the new output, then overwrite via -o.
    // GNU truncates; the pre-fix zshuf left stale trailing bytes on macOS.
    const zc = try std.fmt.allocPrint(a,
        \\f=$(mktemp); printf 'LONGLINE1\nLONGLINE2\nLONGLINE3\n' > "$f"; printf 'x\n' | {s} -o "$f"; od -An -c "$f"; rm -f "$f"
    , .{zbin()});
    defer a.free(zc);
    const gc = try std.fmt.allocPrint(a,
        \\f=$(mktemp); printf 'LONGLINE1\nLONGLINE2\nLONGLINE3\n' > "$f"; printf 'x\n' | {s} -o "$f"; od -An -c "$f"; rm -f "$f"
    , .{gbin()});
    defer a.free(gc);
    const zr = try run(a, zc);
    defer zr.deinit(a);
    const gr = try run(a, gc);
    defer gr.deinit(a);
    // Both should show exactly "   x  \n" — a 2-byte file, no stale bytes.
    try testing.expectEqualStrings(gr.out, zr.out);
}
