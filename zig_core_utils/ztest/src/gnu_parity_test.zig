//! Externally-anchored parity tests for `ztest` (GNU coreutils `test` / `[` clone).
//!
//! Anchor #1 (primary, live): every case in `parity_cases` and every generated
//! file-test case is executed against BOTH the freshly built `ztest` binary
//! (path in env ZTEST_BIN, set by build.zig) AND the real GNU coreutils `test`
//! binary discovered on this machine (`/opt/homebrew/bin/gtest`, coreutils
//! 9.10). The exit code must match. GNU `test` is the external reference — its
//! results are not written by this repo, and both binaries observe the same
//! real filesystem fixtures. If no GNU binary is present the live block skips
//! (error.SkipZigTest) rather than passing vacuously.
//!
//! Anchor #2 (belt-and-suspenders, offline): `documented_cases` pins the exact
//! exit code GNU/POSIX `test` produces, taken from POSIX.1-2017 `test` and the
//! GNU coreutils manual, confirmed against gtest 9.10. These assert literal exit
//! codes even when no GNU binary is installed, so the suite always carries a
//! real external anchor. Sources cited inline per case.
//!
//! Per zig-forge/CLAUDE.md golden rule: NO roundtrip-only tests. Every case
//! compares ztest against an authority the implementation author did not write.

const std = @import("std");

// libc bits used to build fixtures deterministically without the Io-threaded fs
// API. symlink lives in std.c; the rest we declare here.
extern "c" fn mkdir(path: [*:0]const u8, mode: c_uint) c_int;
extern "c" fn mkfifo(path: [*:0]const u8, mode: c_uint) c_int;
extern "c" fn open(path: [*:0]const u8, flags: c_int, mode: c_uint) c_int;
extern "c" fn write(fd: c_int, buf: [*]const u8, n: usize) isize;
extern "c" fn close(fd: c_int) c_int;
extern "c" fn unlink(path: [*:0]const u8) c_int;

const O_WRONLY: c_int = 0x0001;
const O_CREAT: c_int = if (@import("builtin").os.tag == .linux) 0o100 else 0x0200;
const O_TRUNC: c_int = if (@import("builtin").os.tag == .linux) 0o1000 else 0x0400;

const RunResult = struct {
    stdout: []u8,
    code: u8, // 255 sentinel for signal/abnormal termination
};

fn runBin(alloc: std.mem.Allocator, io: std.Io, bin: []const u8, args: []const []const u8) !RunResult {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(alloc);
    try argv.append(alloc, bin);
    for (args) |a| try argv.append(alloc, a);

    const res = try std.process.run(alloc, io, .{ .argv = argv.items });
    alloc.free(res.stderr);
    const code: u8 = switch (res.term) {
        .exited => |c| c,
        else => 255,
    };
    return .{ .stdout = res.stdout, .code = code };
}

fn findGnuTest() ?[:0]const u8 {
    const candidates = [_][:0]const u8{
        "/opt/homebrew/opt/coreutils/libexec/gnubin/test",
        "/opt/homebrew/bin/gtest",
        "/usr/local/opt/coreutils/libexec/gnubin/test",
        "/usr/bin/test",
    };
    for (candidates) |c| {
        if (std.c.access(c.ptr, 0) == 0) return c; // F_OK == 0
    }
    return null;
}

const Case = []const []const u8;

// Path-independent cases: string, integer, logical and the POSIX argument-count
// special cases. Confirmed identical against gtest 9.10 during the audit.
const parity_cases = [_]Case{
    // --- string equality ---
    &.{ "foo", "=", "foo" },
    &.{ "foo", "=", "bar" },
    &.{ "foo", "!=", "bar" },
    &.{ "foo", "!=", "foo" },
    &.{ "", "=", "" },
    &.{ "a", "==", "a" },
    // --- -z / -n ---
    &.{ "-z", "" },
    &.{ "-z", "x" },
    &.{ "-n", "" },
    &.{ "-n", "x" },
    // --- integer comparison ---
    &.{ "5", "-eq", "5" },
    &.{ "5", "-eq", "6" },
    &.{ "5", "-ne", "6" },
    &.{ "5", "-lt", "6" },
    &.{ "6", "-le", "6" },
    &.{ "7", "-gt", "3" },
    &.{ "3", "-ge", "9" },
    &.{ "-5", "-lt", "3" },
    &.{ "+5", "-eq", "5" },
    // integer parse errors -> exit 2 (was silently exit 1 before the fix)
    &.{ "5", "-eq", "abc" },
    &.{ "abc", "-eq", "5" },
    &.{ "", "-eq", "5" },
    // --- POSIX argument-count special cases ---
    &.{"!"}, // lone '!' is a non-empty string -> true
    &.{""}, // empty string -> false
    &.{"-n"}, // single '-n' is a string, not an operator -> true
    &.{"("}, // single '(' is a string -> true
    &.{ "!", "=", "!" }, // 3-arg: binop wins -> "!" = "!" -> true
    &.{ "-f", "=", "-f" }, // 3-arg: binop wins -> "-f" = "-f" -> true
    &.{ "!", "" }, // 2-arg: not(nonempty "") -> true
    &.{ "!", "x" }, // 2-arg: not(nonempty "x") -> false
    &.{ "(", "", ")" }, // 3-arg paren: one_argument("") -> false
    &.{ "(", "x", ")" }, // 3-arg paren: one_argument("x") -> true
    &.{ "-e", "y" }, // 2-arg: -e on missing file -> false
    // --- syntax errors -> exit 2 ---
    &.{ "x", "y" }, // 2-arg, not '!' not unary -> error
    &.{ "-q", "y" }, // unknown unary operator -> error
    &.{ "x", "y", "z" }, // 3-arg, y not binop -> error
    &.{ "-f", "-f", "-f" }, // 3-arg, middle not binop -> error
    // --- compound (general grammar) ---
    &.{ "3", "-gt", "2", "-a", "4", "-gt", "1" },
    &.{ "1", "-a", "2", "-a", "3" },
    &.{ "1", "-eq", "1", "-o", "2", "-eq", "3" },
    &.{ "(", "1", "-eq", "1", ")" },
    &.{ "!", "(", "1", "-eq", "2", ")" },
    &.{ "1", "-eq", "2", "-o", "!", "3", "-eq", "4" },
    // --- '--help' / '--version' are ordinary strings for `test` (exit 0) ---
    &.{"--help"},
    &.{"--version"},
    // --- no args -> false ---
    &.{},
};

var tmp_buf: [512]u8 = undefined;
var tmp_dir: []const u8 = "";

fn fixPath(comptime name: []const u8) [:0]const u8 {
    var b: [1024]u8 = undefined;
    const s = std.fmt.bufPrintZ(&b, "{s}/" ++ name, .{tmp_dir}) catch unreachable;
    // copy into a static-lifetime store per call
    const store = std.heap.page_allocator.dupeZ(u8, s) catch unreachable;
    return store;
}

/// Build the on-disk fixtures once; returns the absolute base directory.
fn makeFixtures() ![]const u8 {
    const tmp_root = if (std.c.getenv("TMPDIR")) |t| std.mem.span(t) else "/tmp";
    const base = std.fmt.bufPrint(&tmp_buf, "{s}ztest_parity_{d}", .{ tmp_root, std.c.getpid() }) catch unreachable;
    tmp_dir = base;

    var z: [1024]u8 = undefined;
    const baseZ = std.fmt.bufPrintZ(&z, "{s}", .{base}) catch unreachable;
    _ = mkdir(baseZ.ptr, 0o755);

    // regular non-empty file
    {
        const p = std.fmt.bufPrintZ(&z, "{s}/bigfile", .{base}) catch unreachable;
        const fd = open(p.ptr, O_WRONLY | O_CREAT | O_TRUNC, 0o644);
        if (fd >= 0) {
            _ = write(fd, "hi\n", 3);
            _ = close(fd);
        }
    }
    // empty file
    {
        const p = std.fmt.bufPrintZ(&z, "{s}/emptyfile", .{base}) catch unreachable;
        const fd = open(p.ptr, O_WRONLY | O_CREAT | O_TRUNC, 0o644);
        if (fd >= 0) _ = close(fd);
    }
    // directory
    {
        const p = std.fmt.bufPrintZ(&z, "{s}/sub", .{base}) catch unreachable;
        _ = mkdir(p.ptr, 0o755);
    }
    // symlink to an existing target, and a dangling one
    {
        const target = std.fmt.bufPrintZ(&z, "bigfile", .{}) catch unreachable;
        var z2: [1024]u8 = undefined;
        const link = std.fmt.bufPrintZ(&z2, "{s}/link_ok", .{base}) catch unreachable;
        _ = unlink(link.ptr);
        _ = std.c.symlink(target.ptr, link.ptr);
    }
    {
        const target = std.fmt.bufPrintZ(&z, "nonexistent_target", .{}) catch unreachable;
        var z2: [1024]u8 = undefined;
        const link = std.fmt.bufPrintZ(&z2, "{s}/link_dead", .{base}) catch unreachable;
        _ = unlink(link.ptr);
        _ = std.c.symlink(target.ptr, link.ptr);
    }
    // fifo
    {
        const p = std.fmt.bufPrintZ(&z, "{s}/fifo", .{base}) catch unreachable;
        _ = unlink(p.ptr);
        _ = mkfifo(p.ptr, 0o644);
    }
    // two files with the SAME whole second but different nanoseconds: hi is
    // newer. This is the sub-second `-nt`/`-ot` precision anchor — a
    // whole-second-only comparison would (wrongly) call them equal.
    {
        const lo = std.fmt.bufPrintZ(&z, "{s}/m_lo", .{base}) catch unreachable;
        var fd = open(lo.ptr, O_WRONLY | O_CREAT | O_TRUNC, 0o644);
        if (fd >= 0) _ = close(fd);
        var z2: [1024]u8 = undefined;
        const hi = std.fmt.bufPrintZ(&z2, "{s}/m_hi", .{base}) catch unreachable;
        fd = open(hi.ptr, O_WRONLY | O_CREAT | O_TRUNC, 0o644);
        if (fd >= 0) _ = close(fd);
        const t_lo = [2]std.c.timespec{
            .{ .sec = 1_700_000_000, .nsec = 100 },
            .{ .sec = 1_700_000_000, .nsec = 100 },
        };
        const t_hi = [2]std.c.timespec{
            .{ .sec = 1_700_000_000, .nsec = 500_000_000 },
            .{ .sec = 1_700_000_000, .nsec = 500_000_000 },
        };
        _ = std.c.utimensat(std.c.AT.FDCWD, lo.ptr, &t_lo, 0);
        _ = std.c.utimensat(std.c.AT.FDCWD, hi.ptr, &t_hi, 0);
    }
    return base;
}

test "ztest matches GNU test exit codes (path-independent cases)" {
    const alloc = std.testing.allocator;

    const ztest_z = std.c.getenv("ZTEST_BIN") orelse {
        std.debug.print("ZTEST_BIN not set; run via `zig build test`\n", .{});
        return error.SkipZigTest;
    };
    const ztest = std.mem.span(ztest_z);

    const gnu = findGnuTest() orelse {
        std.debug.print("no GNU test found; skipping live parity block\n", .{});
        return error.SkipZigTest;
    };

    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var failures: usize = 0;
    for (parity_cases) |c| {
        const z = try runBin(alloc, io, ztest, c);
        defer alloc.free(z.stdout);
        const g = try runBin(alloc, io, gnu, c);
        defer alloc.free(g.stdout);

        if (z.code != g.code) {
            failures += 1;
            std.debug.print("DIFF {any}\n  gnu:   exit={d}\n  ztest: exit={d}\n", .{ c, g.code, z.code });
        }
    }
    try std.testing.expectEqual(@as(usize, 0), failures);
}

test "ztest matches GNU test exit codes (live filesystem fixtures)" {
    const alloc = std.testing.allocator;

    const ztest_z = std.c.getenv("ZTEST_BIN") orelse return error.SkipZigTest;
    const ztest = std.mem.span(ztest_z);
    const gnu = findGnuTest() orelse return error.SkipZigTest;

    _ = try makeFixtures();

    const bigfile = fixPath("bigfile");
    const emptyfile = fixPath("emptyfile");
    const sub = fixPath("sub");
    const link_ok = fixPath("link_ok");
    const link_dead = fixPath("link_dead");
    const fifo = fixPath("fifo");
    const nope = fixPath("does_not_exist");
    const m_lo = fixPath("m_lo");
    const m_hi = fixPath("m_hi");

    const file_cases = [_]Case{
        &.{ "-e", bigfile },     &.{ "-e", nope },
        &.{ "-f", bigfile },     &.{ "-f", sub },
        &.{ "-d", sub },         &.{ "-d", bigfile },
        &.{ "-s", bigfile },     &.{ "-s", emptyfile },
        &.{ "-r", bigfile },     &.{ "-w", bigfile },
        &.{ "-L", link_ok },     &.{ "-L", link_dead },
        &.{ "-L", bigfile },     &.{ "-h", link_ok },
        &.{ "-p", fifo },        &.{ "-p", bigfile },
        // -nt / -ot with sub-second-only difference (same whole second)
        &.{ m_hi, "-nt", m_lo }, &.{ m_lo, "-nt", m_hi },
        &.{ m_lo, "-ot", m_hi }, &.{ m_hi, "-ot", m_lo },
        // -ef (same inode)
        &.{ bigfile, "-ef", bigfile },
        &.{ bigfile, "-ef", emptyfile },
        // compound over files
        &.{ "-f", bigfile, "-a", "-d", sub },
        &.{ "!", "-f", nope },
    };

    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var failures: usize = 0;
    for (file_cases) |c| {
        const z = try runBin(alloc, io, ztest, c);
        defer alloc.free(z.stdout);
        const g = try runBin(alloc, io, gnu, c);
        defer alloc.free(g.stdout);
        if (z.code != g.code) {
            failures += 1;
            std.debug.print("DIFF {any}\n  gnu:   exit={d}\n  ztest: exit={d}\n", .{ c, g.code, z.code });
        }
    }
    try std.testing.expectEqual(@as(usize, 0), failures);
}

// Literal exit-code anchors from POSIX.1-2017 `test` and the GNU coreutils
// manual, confirmed against gtest 9.10. These run even with no GNU binary
// installed, so there is always an external anchor.
const Documented = struct {
    args: Case,
    code: u8,
    src: []const u8,
};

const documented_cases = [_]Documented{
    // POSIX `test`: with 3 args, if $2 is a binary primary, evaluate $1 OP $3 —
    // even when $1 is '!' or looks like a unary op. gtest 9.10: exit 0.
    .{ .args = &.{ "!", "=", "!" }, .code = 0, .src = "POSIX test 3-argument rule / gtest 9.10" },
    .{ .args = &.{ "-f", "=", "-f" }, .code = 0, .src = "POSIX test 3-argument rule / gtest 9.10" },
    // POSIX `test`: exactly one argument -> true iff non-empty string.
    .{ .args = &.{"!"}, .code = 0, .src = "POSIX test 1-argument rule / gtest 9.10" },
    .{ .args = &.{"-n"}, .code = 0, .src = "POSIX test 1-argument rule / gtest 9.10" },
    .{ .args = &.{""}, .code = 1, .src = "POSIX test 1-argument rule / gtest 9.10" },
    // GNU: non-numeric operand to an integer primary is a diagnostic + exit 2,
    // NOT a silent false. (Old ztest returned exit 1.)
    .{ .args = &.{ "abc", "-eq", "5" }, .code = 2, .src = "GNU coreutils test / gtest 9.10" },
    .{ .args = &.{ "5", "-eq", "abc" }, .code = 2, .src = "GNU coreutils test / gtest 9.10" },
    // basic integer + string truth values.
    .{ .args = &.{ "5", "-eq", "5" }, .code = 0, .src = "POSIX test / gtest 9.10" },
    .{ .args = &.{ "5", "-lt", "6" }, .code = 0, .src = "POSIX test / gtest 9.10" },
    .{ .args = &.{ "foo", "=", "foo" }, .code = 0, .src = "POSIX test / gtest 9.10" },
    .{ .args = &.{ "foo", "!=", "foo" }, .code = 1, .src = "POSIX test / gtest 9.10" },
    .{ .args = &.{ "-z", "" }, .code = 0, .src = "POSIX test / gtest 9.10" },
    .{ .args = &.{ "-n", "x" }, .code = 0, .src = "POSIX test / gtest 9.10" },
    // no arguments -> false.
    .{ .args = &.{}, .code = 1, .src = "POSIX test / gtest 9.10" },
    // `test --help` / `--version` are string operands, not options -> exit 0.
    .{ .args = &.{"--help"}, .code = 0, .src = "gtest 9.10 (test ignores --help/--version)" },
    .{ .args = &.{"--version"}, .code = 0, .src = "gtest 9.10 (test ignores --help/--version)" },
    // syntax errors -> exit 2.
    .{ .args = &.{ "x", "y" }, .code = 2, .src = "POSIX test 2-argument rule / gtest 9.10" },
    .{ .args = &.{ "-q", "y" }, .code = 2, .src = "POSIX test (unary operator expected) / gtest 9.10" },
};

test "ztest matches documented POSIX/GNU exit codes (offline anchor)" {
    const alloc = std.testing.allocator;
    const ztest_z = std.c.getenv("ZTEST_BIN") orelse return error.SkipZigTest;
    const ztest = std.mem.span(ztest_z);

    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    for (documented_cases) |d| {
        const z = try runBin(alloc, io, ztest, d.args);
        defer alloc.free(z.stdout);
        std.testing.expectEqual(d.code, z.code) catch |e| {
            std.debug.print("exit mismatch {any} (src: {s}): got {d}, want {d}\n", .{ d.args, d.src, z.code, d.code });
            return e;
        };
    }
}

// The sub-second mtime precision claim as a standalone, self-contained anchor:
// two files sharing a whole second but differing in nanoseconds must order by
// nanoseconds under -nt/-ot (POSIX/GNU use full timespec precision). ztest's
// exit codes are asserted directly here (documented behaviour), independent of
// any GNU binary being present.
test "ztest -nt/-ot honor sub-second mtime (offline anchor)" {
    const alloc = std.testing.allocator;
    const ztest_z = std.c.getenv("ZTEST_BIN") orelse return error.SkipZigTest;
    const ztest = std.mem.span(ztest_z);

    _ = try makeFixtures();
    const m_lo = fixPath("m_lo");
    const m_hi = fixPath("m_hi");

    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // m_hi has the larger nanosecond field within the same second.
    {
        const z = try runBin(alloc, io, ztest, &.{ m_hi, "-nt", m_lo });
        defer alloc.free(z.stdout);
        try std.testing.expectEqual(@as(u8, 0), z.code); // m_hi newer -> true
    }
    {
        const z = try runBin(alloc, io, ztest, &.{ m_lo, "-nt", m_hi });
        defer alloc.free(z.stdout);
        try std.testing.expectEqual(@as(u8, 1), z.code); // m_lo not newer -> false
    }
    {
        const z = try runBin(alloc, io, ztest, &.{ m_lo, "-ot", m_hi });
        defer alloc.free(z.stdout);
        try std.testing.expectEqual(@as(u8, 0), z.code); // m_lo older -> true
    }
}
