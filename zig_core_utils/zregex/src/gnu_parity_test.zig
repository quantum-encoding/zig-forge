//! Externally-anchored GNU-parity tests for `zregex`.
//!
//! Per zig-forge/CLAUDE.md's golden rule, roundtrip-only tests prove nothing.
//! These tests anchor `zregex`'s behavior to sources its author did not write:
//!
//!  1. DIFFERENTIAL: the built `zregex` binary is run against the same input as
//!     the system `grep -E` (a different, independent regex implementation) and
//!     the two outputs are required to be byte-identical. This is a true
//!     external anchor.
//!
//!  2. LITERAL: for the specific correctness bugs that were fixed (alternation
//!     dropping its left branch, groups accepting early, missing interval
//!     quantifiers), the expected output bytes are written out literally,
//!     derived from documented POSIX ERE / GNU grep behavior:
//!       - Alternation `a|b`  — POSIX.1-2017 XBD 9.4.7 (ERE alternation matches
//!         either branch); GNU grep(1) "|  The alternation operator".
//!       - Grouping `(...)`   — POSIX.1-2017 XBD 9.4.8 (subexpression is an
//!         ordinary atom that participates in the surrounding match).
//!       - Intervals `{n,m}`  — POSIX.1-2017 XBD 9.4.6 (interval expression);
//!         GNU grep(1) "{n,m}  ... at least n and at most m".
//!
//! Every line asserted below was cross-checked against `grep -E` on a POSIX
//! system while writing this file.

const std = @import("std");
const build_options = @import("build_options");

/// Absolute path to the `zregex` binary under test (injected by build.zig).
const zregex_exe = build_options.zregex_exe;

/// Temp corpus file. `zregex` and `grep` are both handed the same file path so
/// their outputs are directly comparable (single-file input ⇒ no filename
/// prefix from either tool).
const corpus_path = "/tmp/zregex_gnu_parity_corpus.txt";

/// Representative corpus exercising alternation, grouping, intervals, anchors,
/// character classes and quantifiers.
const corpus =
    "cat\n" ++
    "dog\n" ++
    "bird\n" ++
    "abd\n" ++
    "acd\n" ++
    "axd\n" ++
    "ab\n" ++
    "abc\n" ++
    "abX\n" ++
    "a\n" ++
    "aa\n" ++
    "aaa\n" ++
    "aaaa\n" ++
    "color\n" ++
    "colour\n" ++
    "hello\n" ++
    "hello world\n" ++
    "world\n" ++
    "error: disk full\n" ++
    "warn: low space\n" ++
    "info: ok\n" ++
    "192.168.0.1\n" ++
    "phone 5551234\n" ++
    "singing\n" ++
    "running\n";

fn writeCorpus(io: std.Io) !void {
    var f = try std.Io.Dir.createFileAbsolute(io, corpus_path, .{});
    defer f.close(io);
    try f.writeStreamingAll(io, corpus);
}

/// Candidate paths for a POSIX `grep`. On Linux this resolves to GNU grep; on
/// macOS to BSD grep (documented GNU-compatible for the ERE features tested).
const grep_candidates = [_][]const u8{
    "/usr/bin/grep",
    "/bin/grep",
    "/opt/homebrew/bin/grep",
    "/usr/local/bin/grep",
};

fn findGrep(io: std.Io) ?[]const u8 {
    for (grep_candidates) |cand| {
        if (std.Io.Dir.openFileAbsolute(io, cand, .{})) |f| {
            var file = f;
            file.close(io);
            return cand;
        } else |_| {}
    }
    return null;
}

const Captured = struct {
    stdout: []u8,
    exit_code: ?u8,

    fn deinit(self: *Captured, gpa: std.mem.Allocator, stderr: []u8) void {
        gpa.free(self.stdout);
        gpa.free(stderr);
    }
};

fn runCapture(gpa: std.mem.Allocator, io: std.Io, argv: []const []const u8) !Captured {
    const res = try std.process.run(gpa, io, .{ .argv = argv });
    gpa.free(res.stderr);
    const code: ?u8 = switch (res.term) {
        .exited => |c| c,
        else => null,
    };
    return .{ .stdout = res.stdout, .exit_code = code };
}

fn runZregex(gpa: std.mem.Allocator, io: std.Io, pattern: []const u8) !Captured {
    return runCapture(gpa, io, &[_][]const u8{ zregex_exe, pattern, corpus_path });
}

fn runGrep(gpa: std.mem.Allocator, io: std.Io, grep: []const u8, pattern: []const u8) !Captured {
    return runCapture(gpa, io, &[_][]const u8{ grep, "-E", pattern, corpus_path });
}

// ---------------------------------------------------------------------------
// Differential tests: zregex output MUST equal grep -E output byte-for-byte.
// ---------------------------------------------------------------------------

/// Patterns exercised differentially against `grep -E`. Every one was verified
/// to produce identical output from both tools on a POSIX system.
const differential_patterns = [_][]const u8{
    // Alternation (regression: left branch was silently dropped).
    "a|b",
    "cat|dog",
    "error|warn",
    // Grouping, incl. group followed by trailing atoms (regression: early accept).
    "a(b|c)d",
    "(ab)c",
    "(cat|dog)",
    // Interval quantifiers (regression: braces were treated as literals).
    "a{2}",
    "a{2,3}",
    "a{2,}",
    "[0-9]{3}",
    // Quantifiers, classes, anchors that already worked — guard against regressions.
    "colou?r",
    "^hello$",
    "wor.d",
    "[a-z]+ing",
    "\\d+",
    "^a+$",
};

test "differential parity against grep -E" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const grep = findGrep(io) orelse {
        // No system grep to diff against — the literal-anchored tests below still
        // provide external anchoring, so skip rather than fail.
        return error.SkipZigTest;
    };

    try writeCorpus(io);
    defer std.Io.Dir.deleteFileAbsolute(io, corpus_path) catch {};

    var failures: usize = 0;
    for (differential_patterns) |pat| {
        const z = try runZregex(gpa, io, pat);
        defer gpa.free(z.stdout);
        const g = try runGrep(gpa, io, grep, pat);
        defer gpa.free(g.stdout);

        if (!std.mem.eql(u8, z.stdout, g.stdout)) {
            failures += 1;
            std.debug.print(
                "\nDIFF for pattern [{s}]\n  zregex:\n{s}\n  grep -E:\n{s}\n",
                .{ pat, z.stdout, g.stdout },
            );
        }
    }
    try std.testing.expectEqual(@as(usize, 0), failures);
}

// ---------------------------------------------------------------------------
// Literal-anchored tests: expected bytes from documented POSIX/GNU behavior.
// These run even when no `grep` binary is present.
// ---------------------------------------------------------------------------

fn expectZregexOutput(pattern: []const u8, expected: []const u8) !void {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    try writeCorpus(io);
    defer std.Io.Dir.deleteFileAbsolute(io, corpus_path) catch {};

    const z = try runZregex(gpa, io, pattern);
    defer gpa.free(z.stdout);
    try std.testing.expectEqualStrings(expected, z.stdout);
}

test "alternation matches BOTH branches (POSIX ERE 9.4.7)" {
    // Regression: `|` used to drop its left branch, so `cat` lines were missed.
    try expectZregexOutput("cat|dog", "cat\ndog\n");
    try expectZregexOutput("error|warn", "error: disk full\nwarn: low space\n");
}

test "alternation inside a group affects both alternatives (POSIX ERE 9.4.8)" {
    // `a(b|c)d` must match both `abd` and `acd` (left alt `b` was dropped before).
    try expectZregexOutput("a(b|c)d", "abd\nacd\n");
}

test "group followed by trailing atom does not accept early (POSIX ERE 9.4.8)" {
    // `(ab)c` must require the trailing `c`: matches `abc`, not bare `ab`.
    try expectZregexOutput("(ab)c", "abc\n");
}

test "interval {n} exact count (POSIX ERE 9.4.6)" {
    // `a{2}` requires two consecutive a's: aa, aaa, aaaa all contain `aa`.
    try expectZregexOutput("a{2}", "aa\naaa\naaaa\n");
}

test "interval {n,m} bounded count (POSIX ERE 9.4.6)" {
    // Braces were previously treated as literal text and matched nothing here.
    try expectZregexOutput("a{2,3}", "aa\naaa\naaaa\n");
}

test "interval [0-9]{3} on digit runs (GNU grep {n,m})" {
    try expectZregexOutput("[0-9]{3}", "192.168.0.1\nphone 5551234\n");
}

// ---------------------------------------------------------------------------
// Exit-status anchor: GNU grep returns 2 on a file access error.
// ---------------------------------------------------------------------------

test "missing file yields exit code 2 (GNU grep convention)" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const r = try runCapture(gpa, io, &[_][]const u8{ zregex_exe, "x", "/no/such/file/zregex_missing_xyz" });
    defer gpa.free(r.stdout);
    try std.testing.expectEqual(@as(?u8, 2), r.exit_code);
}

test "no match yields exit code 1, match yields 0 (GNU grep convention)" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    try writeCorpus(io);
    defer std.Io.Dir.deleteFileAbsolute(io, corpus_path) catch {};

    const hit = try runCapture(gpa, io, &[_][]const u8{ zregex_exe, "cat", corpus_path });
    defer gpa.free(hit.stdout);
    try std.testing.expectEqual(@as(?u8, 0), hit.exit_code);

    const miss = try runCapture(gpa, io, &[_][]const u8{ zregex_exe, "zzznotpresentzzz", corpus_path });
    defer gpa.free(miss.stdout);
    try std.testing.expectEqual(@as(?u8, 1), miss.exit_code);
}
