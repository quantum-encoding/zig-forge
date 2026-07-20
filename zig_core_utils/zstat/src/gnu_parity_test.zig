//! Externally-anchored parity tests for zstat.
//!
//! Primary anchor: the real GNU coreutils `stat` binary. Each case runs the
//! same arguments through GNU stat and through zstat and asserts byte-identical
//! stdout and identical exit status. Because both binaries read the *same*
//! inode at (effectively) the same instant, the timestamp fields are stable and
//! the comparison is deterministic. This is a true external anchor: the expected
//! bytes are produced by an implementation this repo did not write.
//!
//! Secondary anchor (runs even if no GNU binary is installed): a handful of
//! assertions whose expected bytes are fixed by documented POSIX / GNU stat
//! semantics and are timezone-independent (`%s` == byte size, `%A` == mode
//! string, `%F` == file type, `%a` == octal perms, `%Y`/`%X` == raw epoch
//! seconds — negative for pre-1970 files). Sources: POSIX stat(1)/(2),
//! `info coreutils 'stat invocation'`.
//!
//! The pre-1970 cases (`neg.txt`, mtime = -315619200) are the regression guard
//! for the integer-cast panic in formatTime that crashed zstat (exit 134) on
//! any file with a negative epoch timestamp.

const std = @import("std");
const builtin = @import("builtin");

const alloc = std.testing.allocator;

// build.zig runs the test with cwd = project root and depends on the install
// step, so the freshly built binary is here.
const zstat_bin = "zig-out/bin/zstat";

const gnu_stat_candidates = [_][]const u8{
    "/opt/homebrew/opt/coreutils/libexec/gnubin/stat",
    "/opt/homebrew/bin/gstat",
    "gstat",
};
const gnu_touch_candidates = [_][]const u8{
    "/opt/homebrew/opt/coreutils/libexec/gnubin/touch",
    "/opt/homebrew/bin/gtouch",
    "gtouch",
};

const RunOut = struct {
    stdout: []u8,
    stderr: []u8,
    code: ?u8, // exit code, or null if killed by signal

    fn free(self: RunOut) void {
        alloc.free(self.stdout);
        alloc.free(self.stderr);
    }
};

fn run(argv: []const []const u8) !RunOut {
    const r = try std.process.run(alloc, std.testing.io, .{ .argv = argv });
    return .{
        .stdout = r.stdout,
        .stderr = r.stderr,
        .code = switch (r.term) {
            .exited => |c| c,
            else => null,
        },
    };
}

/// Return the first candidate binary that is present (spawns and exits 0 on
/// `--version`), or null if none are installed.
fn findBin(cands: []const []const u8) ?[]const u8 {
    for (cands) |c| {
        const r = run(&.{ c, "--version" }) catch continue;
        defer r.free();
        if (r.code) |code| {
            if (code == 0) return c;
        }
    }
    return null;
}

fn buildArgv(bin: []const u8, rest: []const []const u8) ![]const []const u8 {
    const list = try alloc.alloc([]const u8, rest.len + 1);
    list[0] = bin;
    @memcpy(list[1..], rest);
    return list;
}

/// Assert GNU stat and zstat produce identical stdout and exit code for `rest`.
fn expectParity(gnu: []const u8, rest: []const []const u8) !void {
    const gnu_argv = try buildArgv(gnu, rest);
    defer alloc.free(gnu_argv);
    const zst_argv = try buildArgv(zstat_bin, rest);
    defer alloc.free(zst_argv);

    const g = try run(gnu_argv);
    defer g.free();
    const z = try run(zst_argv);
    defer z.free();

    if (!std.mem.eql(u8, g.stdout, z.stdout) or g.code != z.code) {
        std.debug.print(
            \\
            \\PARITY MISMATCH for args: {any}
            \\  GNU  (exit {?d}): {s}
            \\  zstat(exit {?d}): {s}
            \\
        , .{ rest, g.code, g.stdout, z.code, z.stdout });
        return error.ParityMismatch;
    }
}

/// Set up a fixture directory. Returns the absolute path (caller frees) and
/// whether the negative/positive fixed-epoch files were created (requires GNU
/// touch, which supports `-d @<epoch>`).
const Fixtures = struct {
    dir: []u8,
    have_epoch: bool,

    fn deinit(self: Fixtures) void {
        const argv = [_][]const u8{ "/bin/rm", "-rf", self.dir };
        if (run(&argv)) |r| r.free() else |_| {}
        alloc.free(self.dir);
    }
};

fn makeFixtures(gnu_touch: ?[]const u8) !Fixtures {
    const base =
        \\set -e
        \\D=$(mktemp -d /tmp/zstat_test.XXXXXX)
        \\printf 'hello\n' > "$D/reg.txt"
        \\chmod 644 "$D/reg.txt"
        \\ln -s reg.txt "$D/link"
        \\mkdir "$D/sub"
        \\
    ;
    const epoch = if (gnu_touch) |gt|
        try std.fmt.allocPrint(alloc,
            \\{s} -d @-315619200 "$D/neg.txt"
            \\{s} -d @1234567890 "$D/pos.txt"
            \\
        , .{ gt, gt })
    else
        try alloc.dupe(u8, "");
    defer alloc.free(epoch);

    const script = try std.fmt.allocPrint(alloc, "{s}{s}printf %s \"$D\"\n", .{ base, epoch });
    defer alloc.free(script);

    const argv = [_][]const u8{ "/bin/sh", "-c", script };
    const r = try run(&argv);
    defer r.free();
    if (r.code != 0) return error.FixtureSetupFailed;
    const dir = try alloc.dupe(u8, r.stdout);
    return .{ .dir = dir, .have_epoch = gnu_touch != null };
}

fn joinPath(dir: []const u8, name: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc, "{s}/{s}", .{ dir, name });
}

// ---------------------------------------------------------------------------
// Secondary anchor: documented, timezone-independent expected bytes.
// ---------------------------------------------------------------------------

test "documented: %s is exact byte size, %A/%a/%F match POSIX semantics" {
    const fx = try makeFixtures(findBin(&gnu_touch_candidates));
    defer fx.deinit();

    const reg = try joinPath(fx.dir, "reg.txt");
    defer alloc.free(reg);
    const sub = try joinPath(fx.dir, "sub");
    defer alloc.free(sub);

    // "hello\n" is 6 bytes; created with chmod 644.
    try expectLiteral(&.{ "-c", "%s", reg }, "6\n");
    try expectLiteral(&.{ "-c", "%a", reg }, "644\n");
    try expectLiteral(&.{ "-c", "%A", reg }, "-rw-r--r--\n");
    try expectLiteral(&.{ "-c", "%F", reg }, "regular file\n");
    try expectLiteral(&.{ "-c", "%F", sub }, "directory\n");
}

test "documented: pre-1970 file yields negative %Y/%X and does not crash" {
    const gnu_touch = findBin(&gnu_touch_candidates);
    if (gnu_touch == null) return error.SkipZigTest; // needs GNU touch for @epoch
    const fx = try makeFixtures(gnu_touch);
    defer fx.deinit();

    const neg = try joinPath(fx.dir, "neg.txt");
    defer alloc.free(neg);
    const pos = try joinPath(fx.dir, "pos.txt");
    defer alloc.free(pos);

    // Regression guard: the old formatTime @intCast(day) panicked (exit 134)
    // on negative epoch seconds. Raw-second fields must round-trip the value
    // set by `touch -d @-315619200` regardless of the host timezone.
    try expectLiteral(&.{ "-c", "%Y", neg }, "-315619200\n");
    try expectLiteral(&.{ "-c", "%X", neg }, "-315619200\n");
    try expectLiteral(&.{ "-c", "%Y", pos }, "1234567890\n");

    // And the human-readable form must not panic — exit 0, non-empty output.
    const r = try run(&.{ zstat_bin, "-c", "%y", neg });
    defer r.free();
    try std.testing.expect(r.code.? == 0);
    try std.testing.expect(r.stdout.len > 0);
}

fn expectLiteral(rest: []const []const u8, expected: []const u8) !void {
    const argv = try buildArgv(zstat_bin, rest);
    defer alloc.free(argv);
    const r = try run(argv);
    defer r.free();
    if (!std.mem.eql(u8, r.stdout, expected)) {
        std.debug.print("\nLITERAL MISMATCH args {any}\n  expected: {s}\n  got:      {s}\n", .{ rest, expected, r.stdout });
        return error.LiteralMismatch;
    }
}

// ---------------------------------------------------------------------------
// Behavioral anchors that do not depend on GNU stat being installed.
// ---------------------------------------------------------------------------

test "error on missing file: exit 1 and errno string present" {
    const r = try run(&.{ zstat_bin, "definitely-no-such-file-xyz" });
    defer r.free();
    try std.testing.expectEqual(@as(?u8, 1), r.code);
    // GNU appends the strerror text; we anchor on that documented substring.
    try std.testing.expect(std.mem.indexOf(u8, r.stderr, "No such file or directory") != null);
}

test "--help and --version go to stdout and exit 0 (GNU convention)" {
    {
        const r = try run(&.{ zstat_bin, "--help" });
        defer r.free();
        try std.testing.expectEqual(@as(?u8, 0), r.code);
        try std.testing.expect(r.stdout.len > 0);
        try std.testing.expectEqual(@as(usize, 0), r.stderr.len);
    }
    {
        const r = try run(&.{ zstat_bin, "--version" });
        defer r.free();
        try std.testing.expectEqual(@as(?u8, 0), r.code);
        try std.testing.expect(r.stdout.len > 0);
    }
}

// ---------------------------------------------------------------------------
// Primary anchor: diff every representative case against the real GNU binary.
// ---------------------------------------------------------------------------

test "GNU parity: default, terse and per-field formats across file kinds" {
    const gnu = findBin(&gnu_stat_candidates);
    if (gnu == null) {
        std.debug.print("\n(skipping GNU-diff tests: no GNU stat binary found)\n", .{});
        return error.SkipZigTest;
    }
    const g = gnu.?;

    const fx = try makeFixtures(findBin(&gnu_touch_candidates));
    defer fx.deinit();

    const reg = try joinPath(fx.dir, "reg.txt");
    defer alloc.free(reg);
    const link = try joinPath(fx.dir, "link");
    defer alloc.free(link);
    const sub = try joinPath(fx.dir, "sub");
    defer alloc.free(sub);

    // Every public single-field format specifier, on a regular file.
    const fields = [_][]const u8{
        "%a", "%A", "%b", "%B", "%d", "%D", "%f", "%F", "%g", "%G",
        "%h", "%i", "%n", "%N", "%o", "%s", "%t", "%T", "%u", "%U",
        "%w", "%W", "%x", "%X", "%y", "%Y", "%z", "%Z",
    };
    for (fields) |f| {
        try expectParity(g, &.{ "-c", f, reg });
    }

    // Full default output and terse form for each kind of file.
    const targets = [_][]const u8{ reg, sub, link, "/dev/null" };
    for (targets) |t| {
        try expectParity(g, &.{t});
        try expectParity(g, &.{ "-t", t });
    }

    // Symlink target rendering (%N and default File: line).
    try expectParity(g, &.{ "-c", "%N", link });

    // Device node: major/minor decoding and the "Device type:" line.
    for ([_][]const u8{ "%t", "%T", "%d", "%D" }) |f| {
        try expectParity(g, &.{ "-c", f, "/dev/null" });
    }

    // Pre-1970 timestamps — the crash regression, diffed against GNU.
    if (fx.have_epoch) {
        const neg = try joinPath(fx.dir, "neg.txt");
        defer alloc.free(neg);
        try expectParity(g, &.{neg});
        for ([_][]const u8{ "%y", "%Y", "%x", "%X", "%z", "%Z" }) |f| {
            try expectParity(g, &.{ "-c", f, neg });
        }
    }
}
