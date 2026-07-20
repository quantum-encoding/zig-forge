//! Externally-anchored parity tests for `zyes`.
//!
//! The external anchor is the real GNU coreutils `yes` binary (installed as
//! `gyes` by Homebrew, `yes (GNU coreutils) 9.10`). Every behavioral test here
//! runs BOTH `zyes` and GNU `yes` on the same input and asserts their observable
//! output / exit status agree. GNU is the authority; zyes must match it. These
//! are NOT roundtrip tests — the expected bytes come from a third-party binary
//! the zyes author did not write (zig-forge golden rule §1).
//!
//! A few tests also assert the literal expected bytes inline, sourced from the
//! documented GNU behavior and confirmed against `gyes` at authoring time.
//!
//! These tests shell out to /bin/sh and /bin/bash to build bounded pipelines
//! (`… | head -c N`, `timeout … | wc -c`) around the otherwise-infinite
//! producers. The commands are static test constants — no caller input is
//! interpolated (so this is not a SHELL-CHILD injection sink). All helper
//! binaries are referenced by absolute path so the child needs no PATH.

const std = @import("std");
const Io = std.Io;
const testing = std.testing;
const build_options = @import("build_options");

const ZYES = build_options.zyes_path;
const GYES = "/opt/homebrew/bin/gyes";
const HEAD = "/usr/bin/head";
const TR = "/usr/bin/tr";
const WC = "/usr/bin/wc";
const TIMEOUT = "/opt/homebrew/bin/timeout";

/// A test-scoped threaded Io backed by the testing allocator. `process.run`
/// needs a real allocator (the global single-threaded Io uses a failing one).
const TestIo = struct {
    threaded: Io.Threaded,
    fn init() TestIo {
        return .{ .threaded = Io.Threaded.init(testing.allocator, .{}) };
    }
    fn io(self: *TestIo) Io {
        return self.threaded.io();
    }
    fn deinit(self: *TestIo) void {
        self.threaded.deinit();
    }
};

fn gnuAvailable(io: Io) bool {
    Io.Dir.accessAbsolute(io, GYES, .{}) catch return false;
    return true;
}

/// Run a shell command and return the captured result (caller frees stdout/stderr).
fn sh(gpa: std.mem.Allocator, io: Io, shell: []const u8, cmd: []const u8) !std.process.RunResult {
    return std.process.run(gpa, io, .{ .argv = &.{ shell, "-c", cmd } });
}

/// Capture the first `n` bytes of a (possibly infinite) producer.
fn prefix(gpa: std.mem.Allocator, io: Io, bin: []const u8, args: []const u8, n: usize) ![]u8 {
    const cmd = try std.fmt.allocPrint(gpa, "{s} {s} | {s} -c {d}", .{ bin, args, HEAD, n });
    defer gpa.free(cmd);
    const res = try sh(gpa, io, "/bin/sh", cmd);
    gpa.free(res.stderr);
    return res.stdout;
}

/// Assert zyes and gyes emit the same first `n` bytes for the given args.
fn expectPrefixMatch(io: Io, args: []const u8, n: usize) !void {
    if (!gnuAvailable(io)) return error.SkipZigTest;
    const a = testing.allocator;
    const z = try prefix(a, io, ZYES, args, n);
    defer a.free(z);
    const g = try prefix(a, io, GYES, args, n);
    defer a.free(g);
    try testing.expectEqualStrings(g, z);
}

fn exitCode(gpa: std.mem.Allocator, io: Io, bin: []const u8, arg: []const u8) !u8 {
    const res = try std.process.run(gpa, io, .{ .argv = &.{ bin, arg } });
    gpa.free(res.stdout);
    gpa.free(res.stderr);
    return switch (res.term) {
        .exited => |c| c,
        else => 255,
    };
}

// ---------------------------------------------------------------------------
// Output-stream parity (bounded prefixes compared against GNU yes)
// ---------------------------------------------------------------------------

test "default output matches GNU and is 'y\\n' repeated" {
    var t = TestIo.init();
    defer t.deinit();
    const io = t.io();
    if (!gnuAvailable(io)) return error.SkipZigTest;
    const a = testing.allocator;
    const z = try prefix(a, io, ZYES, "", 8);
    defer a.free(z);
    // Documented GNU behavior: prints "y" per line.
    try testing.expectEqualStrings("y\ny\ny\ny\n", z);
    try expectPrefixMatch(io, "", 4096);
}

test "multi-arg joins with spaces + newline, matches GNU" {
    var t = TestIo.init();
    defer t.deinit();
    const io = t.io();
    if (!gnuAvailable(io)) return error.SkipZigTest;
    const a = testing.allocator;
    const z = try prefix(a, io, ZYES, "hello world", 24);
    defer a.free(z);
    try testing.expectEqualStrings("hello world\nhello world\n", z);
    try expectPrefixMatch(io, "hello world", 4096);
}

test "-- ends options; following dash-arg is an operand (matches GNU)" {
    var t = TestIo.init();
    defer t.deinit();
    const io = t.io();
    if (!gnuAvailable(io)) return error.SkipZigTest;
    const a = testing.allocator;
    const z = try prefix(a, io, ZYES, "-- --foo", 12);
    defer a.free(z);
    try testing.expectEqualStrings("--foo\n--foo\n", z);
    try expectPrefixMatch(io, "-- --foo", 2048);
}

test "operands split by -- are joined (matches GNU)" {
    var t = TestIo.init();
    defer t.deinit();
    const io = t.io();
    if (!gnuAvailable(io)) return error.SkipZigTest;
    const a = testing.allocator;
    const z = try prefix(a, io, ZYES, "a -- b", 8);
    defer a.free(z);
    try testing.expectEqualStrings("a b\na b\n", z);
    try expectPrefixMatch(io, "a -- b", 2048);
}

test "single dash is a normal operand (matches GNU)" {
    var t = TestIo.init();
    defer t.deinit();
    try expectPrefixMatch(t.io(), "-", 512);
}

// ---------------------------------------------------------------------------
// HIGH-severity anchor: output string larger than the internal write buffer.
// The pre-fix code emitted ZERO bytes and busy-looped forever. This bounds the
// producer with `timeout` so a regression fails RED (short count) instead of
// hanging the suite.
// ---------------------------------------------------------------------------

test "output string >64KiB still streams (does not busy-loop), matches GNU" {
    var t = TestIo.init();
    defer t.deinit();
    const io = t.io();
    if (!gnuAvailable(io)) return error.SkipZigTest;
    const a = testing.allocator;
    const want: usize = 200_000; // > one 64 KiB buffer's worth
    // A 70000-char argument -> output line is 70001 bytes (> 65536 buffer).
    const big = "$(" ++ HEAD ++ " -c 70000 /dev/zero | " ++ TR ++ " '\\0' x)";

    inline for (.{ ZYES, GYES }) |bin| {
        const cmd = try std.fmt.allocPrint(
            a,
            "{s} 5 {s} \"{s}\" | {s} -c {d} | {s} -c",
            .{ TIMEOUT, bin, big, HEAD, want, WC },
        );
        defer a.free(cmd);
        const res = try sh(a, io, "/bin/sh", cmd);
        defer a.free(res.stdout);
        defer a.free(res.stderr);
        const count = try std.fmt.parseInt(usize, std.mem.trim(u8, res.stdout, " \n\t"), 10);
        try testing.expectEqual(want, count);
    }

    // And the actual bytes streamed must match GNU: a 70000-'x' line + '\n'.
    const z = try prefix(a, io, ZYES, big, 70_001);
    defer a.free(z);
    const g = try prefix(a, io, GYES, big, 70_001);
    defer a.free(g);
    try testing.expectEqualStrings(g, z);
    try testing.expectEqual(@as(u8, '\n'), z[70_000]);
    try testing.expectEqual(@as(u8, 'x'), z[0]);
    try testing.expectEqual(@as(u8, 'x'), z[69_999]);
}

// ---------------------------------------------------------------------------
// Exit-status / option parity
// ---------------------------------------------------------------------------

test "unrecognized long option exits 1 (matches GNU)" {
    var t = TestIo.init();
    defer t.deinit();
    const io = t.io();
    if (!gnuAvailable(io)) return error.SkipZigTest;
    const a = testing.allocator;
    const z = try exitCode(a, io, ZYES, "--nope");
    const g = try exitCode(a, io, GYES, "--nope");
    try testing.expectEqual(@as(u8, 1), g);
    try testing.expectEqual(g, z);
}

test "unrecognized short option exits 1 (matches GNU)" {
    var t = TestIo.init();
    defer t.deinit();
    const io = t.io();
    if (!gnuAvailable(io)) return error.SkipZigTest;
    const a = testing.allocator;
    const z = try exitCode(a, io, ZYES, "-y");
    const g = try exitCode(a, io, GYES, "-y");
    try testing.expectEqual(@as(u8, 1), g);
    try testing.expectEqual(g, z);
}

test "--help and --version exit 0 (matches GNU)" {
    var t = TestIo.init();
    defer t.deinit();
    const io = t.io();
    if (!gnuAvailable(io)) return error.SkipZigTest;
    const a = testing.allocator;
    inline for (.{ "--help", "--version" }) |flag| {
        const z = try exitCode(a, io, ZYES, flag);
        const g = try exitCode(a, io, GYES, flag);
        try testing.expectEqual(@as(u8, 0), g);
        try testing.expectEqual(g, z);
    }
}

// ---------------------------------------------------------------------------
// Broken-pipe parity: GNU yes dies to SIGPIPE (shell reports exit 141).
// Uses bash for ${PIPESTATUS}.
// ---------------------------------------------------------------------------

test "dies to SIGPIPE on broken pipe -> 141 (matches GNU)" {
    var t = TestIo.init();
    defer t.deinit();
    const io = t.io();
    if (!gnuAvailable(io)) return error.SkipZigTest;
    const a = testing.allocator;
    inline for (.{ ZYES, GYES }) |bin| {
        const cmd = try std.fmt.allocPrint(
            a,
            "{s} 2>/dev/null | {s} -c 2 >/dev/null; echo ${{PIPESTATUS[0]}}",
            .{ bin, HEAD },
        );
        defer a.free(cmd);
        const res = try sh(a, io, "/bin/bash", cmd);
        defer a.free(res.stdout);
        defer a.free(res.stderr);
        try testing.expectEqualStrings("141\n", res.stdout);
    }
}
