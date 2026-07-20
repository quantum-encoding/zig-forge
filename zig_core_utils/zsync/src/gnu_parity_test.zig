//! Externally-anchored GNU-parity tests for zsync.
//!
//! ANCHOR: every expectation below is checked against the REAL GNU `sync`
//! binary (GNU coreutils, discovered at build time — see build.zig), not
//! against zsync's own output. Each test runs the same argv through both
//! binaries and asserts they agree on exit code and (program-name-normalized)
//! diagnostics. This is a true external anchor per zig-forge/CLAUDE.md: the
//! expected bytes come from an implementation zsync's author did not write.
//!
//! Program-name normalization: GNU emits its own argv[0] (a full path for
//! getopt errors, the basename "sync"/"gsync" for its own errors); zsync emits
//! "zsync". Both are collapsed to "PROG" before comparison so the messages —
//! not the program identity — are what is anchored.

const std = @import("std");
const build_options = @import("build_options");

const zsync_path = build_options.zsync_path;
const io = std.testing.io;

/// Resolve the first GNU `sync` candidate that exists on this machine.
/// Returns null if none are present (parity tests then skip). Must be called
/// at runtime — it touches the filesystem.
fn resolveGnu() ?[]const u8 {
    var it = std.mem.splitScalar(u8, build_options.gnu_sync_candidates, ':');
    while (it.next()) |cand| {
        if (cand.len == 0) continue;
        std.Io.Dir.accessAbsolute(io, cand, .{}) catch continue;
        return cand;
    }
    return null;
}

const Captured = struct {
    code: i32, // exit status; -1 for signal/other
    stdout: []u8,
    stderr: []u8,

    fn deinit(self: Captured, a: std.mem.Allocator) void {
        a.free(self.stdout);
        a.free(self.stderr);
    }
};

fn run(a: std.mem.Allocator, exe: []const u8, extra: []const []const u8) !Captured {
    var argv = std.ArrayList([]const u8).empty;
    defer argv.deinit(a);
    try argv.append(a, exe);
    for (extra) |x| try argv.append(a, x);

    const res = try std.process.run(a, std.testing.io, .{ .argv = argv.items });
    const code: i32 = switch (res.term) {
        .exited => |c| @intCast(c),
        else => -1,
    };
    return .{ .code = code, .stdout = res.stdout, .stderr = res.stderr };
}

/// Replace every occurrence of `needle` in `s` with "PROG" (allocating).
fn replaceAlloc(a: std.mem.Allocator, s: []const u8, needle: []const u8) ![]u8 {
    if (needle.len == 0) return a.dupe(u8, s);
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(a);
    var i: usize = 0;
    while (i < s.len) {
        if (i + needle.len <= s.len and std.mem.eql(u8, s[i .. i + needle.len], needle)) {
            try out.appendSlice(a, "PROG");
            i += needle.len;
        } else {
            try out.append(a, s[i]);
            i += 1;
        }
    }
    return out.toOwnedSlice(a);
}

/// Collapse program-name identity in a diagnostic to "PROG".
/// `full` is the invoked path; `base` is its basename.
fn normalize(a: std.mem.Allocator, s: []const u8, full: []const u8, base: []const u8) ![]u8 {
    // Replace the longer full path first, then the basename.
    const step1 = try replaceAlloc(a, s, full);
    defer a.free(step1);
    return replaceAlloc(a, step1, base);
}

fn basename(p: []const u8) []const u8 {
    return std.fs.path.basename(p);
}

/// Returns the resolved GNU sync path, or SkipZigTest if unavailable.
fn gnuOrSkip() ![]const u8 {
    const gnu = resolveGnu() orelse return error.SkipZigTest;
    std.Io.Dir.accessAbsolute(io, zsync_path, .{}) catch return error.SkipZigTest;
    return gnu;
}

/// Core anchor: for the given argv, both binaries must agree on exit code and
/// on the program-name-normalized stderr.
fn expectParity(argv: []const []const u8) !void {
    const gnu_path = try gnuOrSkip();
    const a = std.testing.allocator;

    const g = try run(a, gnu_path, argv);
    defer g.deinit(a);
    const z = try run(a, zsync_path, argv);
    defer z.deinit(a);

    const gn = try normalize(a, g.stderr, gnu_path, basename(gnu_path));
    defer a.free(gn);
    const zn = try normalize(a, z.stderr, zsync_path, basename(zsync_path));
    defer a.free(zn);

    if (g.code != z.code or !std.mem.eql(u8, gn, zn)) {
        std.debug.print(
            \\PARITY MISMATCH for argv={any}
            \\  GNU   exit={d} stderr(norm)={s}
            \\  zsync exit={d} stderr(norm)={s}
            \\
        , .{ argv, g.code, gn, z.code, zn });
        return error.ParityMismatch;
    }
}

// ---- Exit-code + diagnostic parity (content anchored to GNU) ----

test "unrecognized long option -> exit 1 + message (anchored to GNU)" {
    try expectParity(&.{"--bogus"});
}

test "invalid short option -> exit 1 + message (anchored to GNU)" {
    try expectParity(&.{"-z"});
}

test "data and file-system conflict -> exit 1 (anchored to GNU)" {
    try expectParity(&.{ "-d", "-f", "/tmp" });
}

test "bundled -df conflict -> exit 1 (anchored to GNU)" {
    try expectParity(&.{ "-df", "/tmp" });
}

test "-d with no operand -> --data needs at least one argument (anchored to GNU)" {
    try expectParity(&.{"-d"});
}

test "--data with no operand -> exit 1 (anchored to GNU)" {
    try expectParity(&.{"--data"});
}

test "open error carries strerror suffix (anchored to GNU)" {
    // GNU: "sync: error opening '/nonexistent/xyz': No such file or directory"
    try expectParity(&.{"/nonexistent/xyz"});
}

test "single dash is a file operand, not an option (anchored to GNU)" {
    try expectParity(&.{"-"});
}

test "overlong path -> File name too long, no crash (anchored to GNU)" {
    // The pre-fix code copied the arg into a fixed 4096-byte stack buffer and
    // overflowed here (panic in Debug, OOB write in ReleaseFast). GNU reports
    // ENAMETOOLONG and exits 1; zsync must now do the same.
    const a = std.testing.allocator;
    const long = try a.alloc(u8, 5000);
    defer a.free(long);
    long[0] = '/';
    @memset(long[1..], 'a');
    try expectParity(&.{long});
}

// ---- Exit-code-only anchors (output empty or intentionally differs) ----

fn expectExitParity(argv: []const []const u8) !void {
    const gnu_path = try gnuOrSkip();
    const a = std.testing.allocator;
    const g = try run(a, gnu_path, argv);
    defer g.deinit(a);
    const z = try run(a, zsync_path, argv);
    defer z.deinit(a);
    try std.testing.expectEqual(g.code, z.code);
}

test "-f with no operand syncs all, exit 0 (only --data needs an arg; anchored to GNU)" {
    try expectExitParity(&.{"-f"});
}

test "--file-system with no operand -> exit 0 (anchored to GNU)" {
    try expectExitParity(&.{"--file-system"});
}

test "option precedence: --bogus before --help -> exit 1 (anchored to GNU)" {
    try expectExitParity(&.{ "--bogus", "--help" });
}

test "option precedence: --help before --bogus -> exit 0 (anchored to GNU)" {
    try expectExitParity(&.{ "--help", "--bogus" });
}

test "sync a real existing file after -- -> exit 0 (anchored to GNU)" {
    _ = try gnuOrSkip();
    // Create a real file to sync.
    const path = "zig-out/zsync_parity_probe.tmp";
    {
        const f = try std.Io.Dir.cwd().createFile(io, path, .{});
        f.close(io);
    }
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};
    try expectExitParity(&.{ "--", path });
}

// ---- Stream-routing anchors (GNU writes --help/--version to STDOUT) ----

test "--version routes to stdout, not stderr, exit 0 (anchored to GNU routing)" {
    const gnu_path = try gnuOrSkip();
    const a = std.testing.allocator;

    const g = try run(a, gnu_path, &.{"--version"});
    defer g.deinit(a);
    // Confirm the anchor: GNU itself puts version text on stdout, none on stderr.
    try std.testing.expect(g.stdout.len > 0);
    try std.testing.expectEqual(@as(usize, 0), g.stderr.len);
    try std.testing.expectEqual(@as(i32, 0), g.code);

    const z = try run(a, zsync_path, &.{"--version"});
    defer z.deinit(a);
    try std.testing.expect(z.stdout.len > 0); // zsync matches: stdout, not stderr
    try std.testing.expectEqual(@as(usize, 0), z.stderr.len);
    try std.testing.expectEqual(@as(i32, 0), z.code);
}

test "--help routes to stdout, not stderr, exit 0 (anchored to GNU routing)" {
    const gnu_path = try gnuOrSkip();
    const a = std.testing.allocator;

    const g = try run(a, gnu_path, &.{"--help"});
    defer g.deinit(a);
    try std.testing.expect(g.stdout.len > 0);
    try std.testing.expectEqual(@as(usize, 0), g.stderr.len);
    try std.testing.expectEqual(@as(i32, 0), g.code);

    const z = try run(a, zsync_path, &.{"--help"});
    defer z.deinit(a);
    try std.testing.expect(z.stdout.len > 0);
    try std.testing.expectEqual(@as(usize, 0), z.stderr.len);
    try std.testing.expectEqual(@as(i32, 0), z.code);
}
