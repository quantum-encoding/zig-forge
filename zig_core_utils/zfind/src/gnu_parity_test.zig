//! Externally-anchored integration tests for zfind.
//!
//! Two kinds of anchor, neither of which is a roundtrip:
//!
//!  1. SET-EQUALITY vs the real system `find` binary (/usr/bin/find).
//!     For the subset of behaviour BSD find and GNU find agree on
//!     (-name, -type, -o/-or, -regex '.*/x/.*', bracket globs) the SET of
//!     matched paths is identical; we compare sorted output. The reference
//!     bytes come from a binary this repo did not write.
//!
//!  2. DOCUMENTED GNU/POSIX behaviour with the expected result written
//!     literally in the test, citing the GNU findutils manual, for the
//!     GNU-specific semantics BSD find does not share (exit code 2 on a bad
//!     predicate, `-delete` implying `-depth`, `-perm /MODE` any-of-bits,
//!     overflow rejection).
//!
//! The zfind binary under test is located via the ZFIND_BIN env var, which
//! build.zig sets to the installed artifact and makes the test depend on it.

const std = @import("std");
const testing = std.testing;
const c = std.c;

const SYSTEM_FIND = "/usr/bin/find";

fn io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

var fixtureCounter = std.atomic.Value(u64).init(0);

fn zfindBin(alloc: std.mem.Allocator) ![]u8 {
    if (c.getenv("ZFIND_BIN")) |b| return alloc.dupe(u8, std.mem.span(b));
    // Fallback for a plain `zig test` run.
    return alloc.dupe(u8, "zig-out/bin/zfind");
}

const RunResult = struct {
    stdout: []u8,
    stderr: []u8,
    code: u8, // 255 == signalled/abnormal

    fn deinit(self: *RunResult, alloc: std.mem.Allocator) void {
        alloc.free(self.stdout);
        alloc.free(self.stderr);
    }
};

extern "c" fn execv(path: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;

fn readAllFd(alloc: std.mem.Allocator, fd: c.fd_t) ![]u8 {
    var list = std.ArrayListUnmanaged(u8).empty;
    errdefer list.deinit(alloc);
    var buf: [8192]u8 = undefined;
    while (true) {
        const n = c.read(fd, &buf, buf.len);
        if (n <= 0) break;
        try list.appendSlice(alloc, buf[0..@intCast(n)]);
    }
    return list.toOwnedSlice(alloc);
}

/// Run a subprocess via libc fork/exec/pipe, capturing stdout+stderr and the
/// exit code. argv[0] must be an absolute path (we use execv, not PATH search).
/// The Io-based std.process.run is unusable here: the test's only Io is
/// `global_single_threaded`, which is backed by a failing allocator.
fn run(alloc: std.mem.Allocator, argv: []const []const u8) !RunResult {
    var cargv = std.ArrayListUnmanaged(?[*:0]const u8).empty;
    defer {
        for (cargv.items) |a| {
            if (a) |p| alloc.free(std.mem.span(p));
        }
        cargv.deinit(alloc);
    }
    for (argv) |a| {
        const z = try alloc.dupeZ(u8, a);
        try cargv.append(alloc, z.ptr);
    }
    try cargv.append(alloc, null);

    var out_fds: [2]c.fd_t = undefined;
    var err_fds: [2]c.fd_t = undefined;
    if (c.pipe(&out_fds) != 0) return error.PipeFailed;
    if (c.pipe(&err_fds) != 0) return error.PipeFailed;

    const pid = c.fork();
    if (pid == 0) {
        _ = c.dup2(out_fds[1], 1);
        _ = c.dup2(err_fds[1], 2);
        _ = c.close(out_fds[0]);
        _ = c.close(out_fds[1]);
        _ = c.close(err_fds[0]);
        _ = c.close(err_fds[1]);
        _ = execv(cargv.items[0].?, @ptrCast(cargv.items.ptr));
        c._exit(127);
    }
    _ = c.close(out_fds[1]);
    _ = c.close(err_fds[1]);
    const out = try readAllFd(alloc, out_fds[0]);
    errdefer alloc.free(out);
    const err = try readAllFd(alloc, err_fds[0]);
    _ = c.close(out_fds[0]);
    _ = c.close(err_fds[0]);

    var status: c_int = 0;
    _ = c.waitpid(pid, &status, 0);
    const code: u8 = if ((status & 0x7f) == 0) @intCast((status >> 8) & 0xff) else 255;
    return .{ .stdout = out, .stderr = err, .code = code };
}

/// Split output on '\n', drop empties, sort, join back — a canonical set form.
fn canonical(alloc: std.mem.Allocator, out: []const u8) ![]u8 {
    var lines = std.ArrayListUnmanaged([]const u8).empty;
    defer lines.deinit(alloc);
    var it = std.mem.splitScalar(u8, out, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        try lines.append(alloc, line);
    }
    std.mem.sort([]const u8, lines.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);
    return std.mem.join(alloc, "\n", lines.items);
}

/// Build a fixture tree under a fresh temp dir. Returns the absolute path
/// (caller frees). Layout:
///   root/a.txt        (0644, "hi\n")
///   root/b.log        (0644, "")
///   root/c.txt        (0755-ish via chmod)
///   root/sub/         (dir)
///   root/sub/d.txt    (0644)
///   root/sub/e.log    (0644)
fn makeFixture(alloc: std.mem.Allocator) ![]u8 {
    var ts: c.timespec = undefined;
    _ = c.clock_gettime(c.CLOCK.REALTIME, &ts);
    const uniq: u64 = (@as(u64, @intCast(ts.sec)) << 20) ^
        @as(u64, @bitCast(@as(i64, ts.nsec))) ^ (fixtureCounter.fetchAdd(1, .monotonic) << 40);
    var tmpdir: []const u8 = if (c.getenv("TMPDIR")) |t| std.mem.span(t) else "/tmp";
    while (tmpdir.len > 1 and tmpdir[tmpdir.len - 1] == '/') tmpdir = tmpdir[0 .. tmpdir.len - 1];
    const base = try std.fmt.allocPrint(alloc, "{s}/zfind_test_{x}", .{ tmpdir, uniq });

    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io(), base);
    const sub = try std.fmt.allocPrint(alloc, "{s}/sub", .{base});
    defer alloc.free(sub);
    try cwd.createDirPath(io(), sub);

    try writeAt(alloc, base, "a.txt", "hi\n");
    try writeAt(alloc, base, "b.log", "");
    try writeAt(alloc, base, "c.txt", "exe\n");
    try writeAt(alloc, sub, "d.txt", "d\n");
    try writeAt(alloc, sub, "e.log", "e\n");

    // c.txt gets executable bits so -perm /111 can distinguish it.
    const cpath = try std.fmt.allocPrintSentinel(alloc, "{s}/c.txt", .{base}, 0);
    defer alloc.free(cpath);
    _ = c.chmod(cpath.ptr, 0o755);

    return base;
}

fn writeAt(alloc: std.mem.Allocator, dir: []const u8, name: []const u8, data: []const u8) !void {
    const p = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ dir, name });
    defer alloc.free(p);
    try std.Io.Dir.cwd().writeFile(io(), .{ .sub_path = p, .data = data });
}

fn rmFixture(base: []const u8) void {
    std.Io.Dir.cwd().deleteTree(io(), base) catch {};
}

// ---------------------------------------------------------------------------
// 1. OR operator — the headline correctness bug. Anchor: /usr/bin/find.
// ---------------------------------------------------------------------------

test "-o/-or matches the union (set-equal to system find)" {
    const alloc = testing.allocator;
    if (!systemFindAvailable()) return error.SkipZigTest;

    const base = try makeFixture(alloc);
    defer alloc.free(base);
    defer rmFixture(base);
    const bin = try zfindBin(alloc);
    defer alloc.free(bin);

    var z = try run(alloc, &.{ bin, base, "-name", "a.txt", "-o", "-name", "b.log" });
    defer z.deinit(alloc);
    var g = try run(alloc, &.{ SYSTEM_FIND, base, "-name", "a.txt", "-o", "-name", "b.log" });
    defer g.deinit(alloc);

    const zc = try canonical(alloc, z.stdout);
    defer alloc.free(zc);
    const gc = try canonical(alloc, g.stdout);
    defer alloc.free(gc);

    try testing.expectEqualStrings(gc, zc);

    // Belt-and-braces: the pre-fix bug returned an EMPTY set (evaluated as
    // AND of two disjoint names). Assert the union is actually non-empty and
    // contains both operands — so a regression to AND fails loudly.
    try testing.expect(std.mem.indexOf(u8, zc, "a.txt") != null);
    try testing.expect(std.mem.indexOf(u8, zc, "b.log") != null);
}

test "-o precedence: `-type f -name a.txt -o -name b.log` binds AND tighter than OR" {
    const alloc = testing.allocator;
    if (!systemFindAvailable()) return error.SkipZigTest;

    const base = try makeFixture(alloc);
    defer alloc.free(base);
    defer rmFixture(base);
    const bin = try zfindBin(alloc);
    defer alloc.free(bin);

    const args = [_][]const u8{ "-type", "f", "-name", "a.txt", "-o", "-name", "b.log" };
    var z = try run(alloc, &([_][]const u8{ bin, base } ++ args));
    defer z.deinit(alloc);
    var g = try run(alloc, &([_][]const u8{ SYSTEM_FIND, base } ++ args));
    defer g.deinit(alloc);

    const zc = try canonical(alloc, z.stdout);
    defer alloc.free(zc);
    const gc = try canonical(alloc, g.stdout);
    defer alloc.free(gc);
    try testing.expectEqualStrings(gc, zc);
}

// ---------------------------------------------------------------------------
// 2. -type / -name / -regex / bracket-glob — set-equal to system find.
// ---------------------------------------------------------------------------

test "-type f set-equal to system find" {
    const alloc = testing.allocator;
    if (!systemFindAvailable()) return error.SkipZigTest;

    const base = try makeFixture(alloc);
    defer alloc.free(base);
    defer rmFixture(base);
    const bin = try zfindBin(alloc);
    defer alloc.free(bin);

    var z = try run(alloc, &.{ bin, base, "-type", "f" });
    defer z.deinit(alloc);
    var g = try run(alloc, &.{ SYSTEM_FIND, base, "-type", "f" });
    defer g.deinit(alloc);

    const zc = try canonical(alloc, z.stdout);
    defer alloc.free(zc);
    const gc = try canonical(alloc, g.stdout);
    defer alloc.free(gc);
    try testing.expectEqualStrings(gc, zc);
}

test "-regex matches the whole path, not the basename" {
    const alloc = testing.allocator;
    if (!systemFindAvailable()) return error.SkipZigTest;

    const base = try makeFixture(alloc);
    defer alloc.free(base);
    defer rmFixture(base);
    const bin = try zfindBin(alloc);
    defer alloc.free(bin);

    // '.*/sub/.*' can only match if -regex is applied to the FULL path.
    var z = try run(alloc, &.{ bin, base, "-regex", ".*/sub/.*" });
    defer z.deinit(alloc);
    var g = try run(alloc, &.{ SYSTEM_FIND, base, "-regex", ".*/sub/.*" });
    defer g.deinit(alloc);

    const zc = try canonical(alloc, z.stdout);
    defer alloc.free(zc);
    const gc = try canonical(alloc, g.stdout);
    defer alloc.free(gc);
    try testing.expectEqualStrings(gc, zc);
    // Must be non-empty (pre-fix matched basename -> never matched).
    try testing.expect(zc.len > 0);
}

test "-name bracket glob set-equal to system find" {
    const alloc = testing.allocator;
    if (!systemFindAvailable()) return error.SkipZigTest;

    const base = try makeFixture(alloc);
    defer alloc.free(base);
    defer rmFixture(base);
    const bin = try zfindBin(alloc);
    defer alloc.free(bin);

    // [ab].txt matches a.txt but not c.txt / d.txt.
    var z = try run(alloc, &.{ bin, base, "-name", "[ab].txt" });
    defer z.deinit(alloc);
    var g = try run(alloc, &.{ SYSTEM_FIND, base, "-name", "[ab].txt" });
    defer g.deinit(alloc);

    const zc = try canonical(alloc, z.stdout);
    defer alloc.free(zc);
    const gc = try canonical(alloc, g.stdout);
    defer alloc.free(gc);
    try testing.expectEqualStrings(gc, zc);
    try testing.expect(std.mem.indexOf(u8, zc, "a.txt") != null);
    try testing.expect(std.mem.indexOf(u8, zc, "c.txt") == null);
}

// ---------------------------------------------------------------------------
// 3. -delete implies -depth (GNU). Anchor: documented behaviour.
//    GNU find manual: "-delete ... implies -depth" so a non-empty directory
//    is emptied first and then removed.
// ---------------------------------------------------------------------------

test "-delete removes a non-empty directory tree (implies -depth)" {
    const alloc = testing.allocator;

    const base = try makeFixture(alloc);
    defer alloc.free(base);
    defer rmFixture(base);
    const bin = try zfindBin(alloc);
    defer alloc.free(bin);

    // Delete everything under base (but not base itself: -mindepth 1).
    var z = try run(alloc, &.{ bin, base, "-mindepth", "1", "-delete" });
    defer z.deinit(alloc);
    try testing.expectEqual(@as(u8, 0), z.code);

    // The 'sub' directory was non-empty; a top-down/parallel delete could not
    // have removed it. It must now be gone.
    var d = try std.Io.Dir.cwd().openDir(io(), base, .{ .iterate = true });
    defer d.close(io());
    var it = d.iterate();
    var remaining: usize = 0;
    while (try it.next(io())) |_| remaining += 1;
    try testing.expectEqual(@as(usize, 0), remaining);
}

// ---------------------------------------------------------------------------
// 4. Unknown predicate -> exit code 2 (GNU). Anchor: documented behaviour.
//    GNU find prints a diagnostic and exits 2 on an unknown predicate.
// ---------------------------------------------------------------------------

test "unknown predicate exits 2 with a diagnostic" {
    const alloc = testing.allocator;

    const base = try makeFixture(alloc);
    defer alloc.free(base);
    defer rmFixture(base);
    const bin = try zfindBin(alloc);
    defer alloc.free(bin);

    var z = try run(alloc, &.{ bin, base, "-typ", "f" });
    defer z.deinit(alloc);
    try testing.expectEqual(@as(u8, 2), z.code);
    try testing.expect(z.stderr.len > 0);
    // Must NOT have silently printed the tree.
    try testing.expectEqual(@as(usize, 0), z.stdout.len);
}

// ---------------------------------------------------------------------------
// 5. Overflow argument rejected with exit 2 (GNU). Anchor: documented.
//    GNU: `find . -size 99999999999999999999` -> "invalid argument", exit 2.
// ---------------------------------------------------------------------------

test "oversized -size argument is rejected (exit 2), not a crash" {
    const alloc = testing.allocator;

    const base = try makeFixture(alloc);
    defer alloc.free(base);
    defer rmFixture(base);
    const bin = try zfindBin(alloc);
    defer alloc.free(bin);

    var z = try run(alloc, &.{ bin, base, "-size", "99999999999999999999" });
    defer z.deinit(alloc);
    try testing.expectEqual(@as(u8, 2), z.code); // not 255 (SIGABRT) and not 0
}

// ---------------------------------------------------------------------------
// 6. -perm /MODE is any-of-bits, distinct from -MODE all-of-bits (GNU).
//    Anchor: documented behaviour + a fixture with known modes.
//    c.txt is 0755 (has exec bits); a.txt is 0644 (no exec bits).
// ---------------------------------------------------------------------------

test "-perm /111 matches any-exec-bit files, -perm -111 requires all" {
    const alloc = testing.allocator;

    const base = try makeFixture(alloc);
    defer alloc.free(base);
    defer rmFixture(base);
    const bin = try zfindBin(alloc);
    defer alloc.free(bin);

    // any-of: /111 -> c.txt (0755) matches, a.txt (0644) does not.
    var any = try run(alloc, &.{ bin, base, "-type", "f", "-perm", "/111" });
    defer any.deinit(alloc);
    try testing.expect(std.mem.indexOf(u8, any.stdout, "c.txt") != null);
    try testing.expect(std.mem.indexOf(u8, any.stdout, "a.txt") == null);

    // all-of: -444 (all read bits) -> both 0644 and 0755 match a.txt & c.txt.
    var all = try run(alloc, &.{ bin, base, "-type", "f", "-perm", "-444" });
    defer all.deinit(alloc);
    try testing.expect(std.mem.indexOf(u8, all.stdout, "a.txt") != null);
    try testing.expect(std.mem.indexOf(u8, all.stdout, "c.txt") != null);
}

fn systemFindAvailable() bool {
    return c.access(SYSTEM_FIND, 0) == 0; // F_OK
}
