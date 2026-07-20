//! GNU-parity tests for ztrue.
//!
//! These are EXTERNALLY ANCHORED, not roundtrip tests. `true` has almost no
//! observable surface, so the anchors are:
//!
//!  1. EXIT CODE. GNU `true` returns 0 for EVERY invocation — no args, extra
//!     args, unknown flags, `--`, and even `--help` / `--version`. This is the
//!     entire functional contract of the program (POSIX: "true - return true
//!     value ... exit with a zero exit code"). When a real GNU `true` binary is
//!     present (Homebrew coreutils: gnubin/true or `gtrue`), each case FIRST
//!     confirms the live GNU binary returns exactly the table's exit code, then
//!     diffs ztrue against it. So ztrue is checked against a status it did not
//!     author.
//!
//!  2. STDOUT BYTES. GNU `true` writes NOTHING to stdout in every case except
//!     when the SOLE argument is exactly `--help` or `--version` (coreutils
//!     true.c: the `argc == 2` guard). For all the "silent" cases the test
//!     diffs ztrue's stdout byte-for-byte against the live GNU binary's stdout
//!     (both empty) — a true external diff.
//!
//!  3. HELP/VERSION PRESENCE. For the lone `--help` / `--version` cases, GNU's
//!     stdout is NON-EMPTY but embeds GNU's own program identity ("true (GNU
//!     coreutils) 9.10", the invoked path in the Usage line, terminal hyperlink
//!     escapes), so byte-identical parity with ztrue is neither possible nor
//!     desirable (impersonation). The anchor there is: GNU emits >0 bytes to
//!     stdout and exits 0, and ztrue likewise emits >0 bytes and exits 0. The
//!     exact ztrue banner text is additionally pinned as a self-drift-lock
//!     (clearly labeled as such — this is NOT an external anchor, it just
//!     catches accidental banner edits).
//!
//! The ztrue binary path is injected by build.zig via `build_options` (the
//! emitted-binary path of the exe target), so `zig build test` always exercises
//! the freshly-built binary.

const std = @import("std");
const Io = std.Io;
const build_options = @import("build_options");

const gnu_candidates = [_][]const u8{
    "/opt/homebrew/opt/coreutils/libexec/gnubin/true",
    "/opt/homebrew/bin/gtrue",
    "/usr/local/opt/coreutils/libexec/gnubin/true",
    "/usr/local/bin/gtrue",
};

const Case = struct {
    /// argv passed after the program name.
    args: []const []const u8,
    /// exact bytes GNU true writes to stdout (empty for every silent case).
    stdout: []const u8,
    /// exit code GNU true returns (always 0).
    exit: u8,
};

// Anchor table: inputs + GNU-documented stdout/exit. Every silent case pins
// stdout == "" and exit == 0, diffed live against the GNU binary when present.
const cases = [_]Case{
    // No arguments — the shell-primitive case.
    .{ .args = &.{}, .stdout = "", .exit = 0 },
    // Ignored positional arguments.
    .{ .args = &.{"foo"}, .stdout = "", .exit = 0 },
    .{ .args = &.{ "foo", "bar", "baz" }, .stdout = "", .exit = 0 },
    // Unknown flags are ignored, NOT rejected (unlike most coreutils).
    .{ .args = &.{"-x"}, .stdout = "", .exit = 0 },
    .{ .args = &.{"--nope"}, .stdout = "", .exit = 0 },
    .{ .args = &.{"-h"}, .stdout = "", .exit = 0 },
    // End-of-options marker is itself ignored.
    .{ .args = &.{"--"}, .stdout = "", .exit = 0 },
    .{ .args = &.{ "--", "--help" }, .stdout = "", .exit = 0 },
    // --help/--version are honored ONLY as the sole argument. With any extra
    // operand, or in any non-exact form, GNU prints nothing and still exits 0.
    .{ .args = &.{ "--help", "extra" }, .stdout = "", .exit = 0 },
    .{ .args = &.{ "extra", "--help" }, .stdout = "", .exit = 0 },
    .{ .args = &.{ "--version", "foo" }, .stdout = "", .exit = 0 },
    .{ .args = &.{"--hel"}, .stdout = "", .exit = 0 },
    .{ .args = &.{"--ver"}, .stdout = "", .exit = 0 },
    .{ .args = &.{"--help=x"}, .stdout = "", .exit = 0 },
};

// Cases where GNU emits a non-empty banner to stdout and still exits 0.
// Byte-identical parity is impossible (GNU embeds its own program identity),
// so these anchor on PRESENCE (>0 bytes) + exit code against the GNU binary.
const banner_cases = [_][]const []const u8{
    &.{"--help"},
    &.{"--version"},
};

// Self-drift-lock (NOT an external anchor): the exact ztrue banner text. This
// only catches accidental edits to our own help/version strings — GNU's bytes
// differ by design, so this is pinned against ztrue's own output.
const ztrue_help_text =
    "Usage: ztrue [ignored command line arguments]\n" ++
    "  or:  ztrue OPTION\n" ++
    "Exit with a status code indicating success.\n" ++
    "\n" ++
    "      --help        display this help and exit\n" ++
    "      --version     output version information and exit\n" ++
    "\n" ++
    "Your shell may have its own version of true, which usually supersedes\n" ++
    "the version described here.  Please refer to your shell's documentation\n" ++
    "for details about the options it supports.\n";

const ztrue_version_text =
    "ztrue (zig_core_utils) 1.0\n" ++
    "GNU true compatible.\n";

const Run = struct { stdout: []u8, exit: u8 };

fn runBinary(allocator: std.mem.Allocator, io: Io, prog: []const u8, args: []const []const u8) !Run {
    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, prog);
    for (args) |a| try argv.append(allocator, a);

    const res = try std.process.run(allocator, io, .{ .argv = argv.items });
    allocator.free(res.stderr);
    const exit: u8 = switch (res.term) {
        .exited => |c| c,
        else => 255,
    };
    return .{ .stdout = res.stdout, .exit = exit };
}

fn findGnu(allocator: std.mem.Allocator, io: Io) ?[]const u8 {
    for (gnu_candidates) |c| {
        // Probe by actually spawning it; a missing binary yields a spawn error.
        const r = runBinary(allocator, io, c, &.{}) catch continue;
        allocator.free(r.stdout);
        return c;
    }
    return null;
}

test "ztrue matches GNU true: exit code + silent stdout across representative inputs" {
    const allocator = std.testing.allocator;
    var threaded = Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const zpath = build_options.ztrue_path;
    const gnu = findGnu(allocator, io);

    var failures: usize = 0;
    for (cases) |case| {
        // 1. If a real GNU binary exists, prove the anchor table equals its output.
        if (gnu) |gnu_path| {
            const g = try runBinary(allocator, io, gnu_path, case.args);
            defer allocator.free(g.stdout);
            if (!std.mem.eql(u8, g.stdout, case.stdout) or g.exit != case.exit) {
                std.debug.print(
                    "ANCHOR DRIFT: GNU disagrees with table for args={any}\n  gnu stdout={x} exit={d}\n  table     ={x} exit={d}\n",
                    .{ case.args, g.stdout, g.exit, case.stdout, case.exit },
                );
                failures += 1;
                continue;
            }
        }

        // 2. Diff ztrue against the (GNU-confirmed) anchor.
        const z = try runBinary(allocator, io, zpath, case.args);
        defer allocator.free(z.stdout);
        if (!std.mem.eql(u8, z.stdout, case.stdout) or z.exit != case.exit) {
            std.debug.print(
                "MISMATCH: ztrue args={any}\n  got  stdout={x} exit={d}\n  want stdout={x} exit={d}\n",
                .{ case.args, z.stdout, z.exit, case.stdout, case.exit },
            );
            failures += 1;
        }
    }

    if (gnu == null) {
        std.debug.print("NOTE: no GNU true found; anchored to literal GNU-documented bytes only.\n", .{});
    }
    try std.testing.expectEqual(@as(usize, 0), failures);
}

test "ztrue --help/--version: non-empty banner + exit 0, presence-anchored to GNU" {
    const allocator = std.testing.allocator;
    var threaded = Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const zpath = build_options.ztrue_path;
    const gnu = findGnu(allocator, io);

    for (banner_cases) |args| {
        // GNU emits a non-empty banner to stdout and still exits 0.
        if (gnu) |gnu_path| {
            const g = try runBinary(allocator, io, gnu_path, args);
            defer allocator.free(g.stdout);
            try std.testing.expect(g.stdout.len > 0); // GNU prints a banner
            try std.testing.expectEqual(@as(u8, 0), g.exit); // ...and succeeds
        }

        // ztrue must likewise emit a non-empty banner and exit 0.
        const z = try runBinary(allocator, io, zpath, args);
        defer allocator.free(z.stdout);
        try std.testing.expect(z.stdout.len > 0);
        try std.testing.expectEqual(@as(u8, 0), z.exit);
    }
}

test "ztrue banner text drift-lock (self-anchored, NOT external)" {
    const allocator = std.testing.allocator;
    var threaded = Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const zpath = build_options.ztrue_path;

    const h = try runBinary(allocator, io, zpath, &.{"--help"});
    defer allocator.free(h.stdout);
    try std.testing.expectEqualStrings(ztrue_help_text, h.stdout);
    try std.testing.expectEqual(@as(u8, 0), h.exit);

    const v = try runBinary(allocator, io, zpath, &.{"--version"});
    defer allocator.free(v.stdout);
    try std.testing.expectEqualStrings(ztrue_version_text, v.stdout);
    try std.testing.expectEqual(@as(u8, 0), v.exit);
}
