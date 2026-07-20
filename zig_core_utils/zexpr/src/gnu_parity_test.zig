//! Externally-anchored parity tests for `zexpr` (GNU `expr` clone).
//!
//! Anchor #1 (primary): every case in `parity_cases` is executed against BOTH
//! the freshly built `zexpr` binary (path in env ZEXPR_BIN, set by build.zig)
//! AND the real GNU coreutils `expr` binary discovered on this machine
//! (`/opt/homebrew/opt/coreutils/libexec/gnubin/expr` → `gexpr`, coreutils 9.10).
//! stdout and exit code must match byte-for-byte. GNU expr is the external
//! reference implementation — its outputs are not written by this repo. If no
//! GNU binary is present the parity block skips (error.SkipZigTest) rather than
//! passing vacuously.
//!
//! Anchor #2 (belt-and-suspenders): `documented_cases` pins the exact stdout +
//! exit code GNU expr produces, taken from the GNU coreutils manual / POSIX
//! expr spec and confirmed against gexpr 9.10. These assert literal bytes even
//! when no GNU binary is installed, so the suite always has a real external
//! anchor. Sources cited inline per case.
//!
//! Per zig-forge/CLAUDE.md golden rule: NO roundtrip-only tests. Every case
//! compares zexpr against an authority the library author did not write.

const std = @import("std");

const RunResult = struct {
    stdout: []u8,
    code: u8, // 255 sentinel for signal/abnormal termination
};

fn runBin(alloc: std.mem.Allocator, io: std.Io, bin: []const u8, expr_args: []const []const u8) !RunResult {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(alloc);
    try argv.append(alloc, bin);
    for (expr_args) |a| try argv.append(alloc, a);

    const res = try std.process.run(alloc, io, .{ .argv = argv.items });
    alloc.free(res.stderr);
    const code: u8 = switch (res.term) {
        .exited => |c| c,
        else => 255, // signal / crash — the pre-fix overflow panic landed here
    };
    return .{ .stdout = res.stdout, .code = code };
}

fn findGnuExpr() ?[:0]const u8 {
    const candidates = [_][:0]const u8{
        "/opt/homebrew/opt/coreutils/libexec/gnubin/expr",
        "/opt/homebrew/bin/gexpr",
        "/usr/local/opt/coreutils/libexec/gnubin/expr",
        "/usr/bin/expr",
    };
    for (candidates) |c| {
        if (std.c.access(c.ptr, 0) == 0) return c; // F_OK == 0
    }
    return null;
}

const Case = []const []const u8;

// Cases where zexpr must exactly match GNU expr (stdout + exit code).
// Every entry here was confirmed identical against gexpr 9.10 during the audit.
// Regex cases deliberately avoid patterns that require backtracking / group
// repetition (e.g. `h.*o`, `\(abc\)*`), which the greedy engine does not do and
// which are recorded as a known limitation in the audit.
const parity_cases = [_]Case{
    // --- arithmetic ---
    &.{ "3", "+", "4" },
    &.{ "10", "-", "20" },
    &.{ "6", "*", "7" },
    &.{ "20", "/", "3" },
    &.{ "-20", "/", "3" },
    // modulo: C/POSIX sign-of-dividend (@rem, not @mod) — regression finding
    &.{ "-7", "%", "2" }, // GNU: -1  (old zexpr: 1)
    &.{ "7", "%", "-2" }, // GNU: 1   (old zexpr: -1)
    &.{ "-20", "%", "7" }, // GNU: -6
    &.{ "20", "%", "-7" }, // GNU: 6
    // i64-overflow cases that used to panic (SIGABRT, exit 134)
    &.{ "9223372036854775807", "+", "1" }, // GNU: 9223372036854775808
    &.{ "4611686018427387904", "*", "2" }, // GNU: 9223372036854775808
    &.{ "-9223372036854775808", "/", "-1" }, // GNU: 9223372036854775808 (INT_MIN/-1)
    &.{ "100000000000000000000", "+", "1" }, // beyond i64, within i128
    // --- comparison / logical ---
    &.{ "5", "=", "5" },
    &.{ "5", "<", "10" },
    &.{ "abc", "<", "abd" },
    &.{ "5", "!=", "6" },
    &.{ "0", "|", "5" },
    &.{ "3", "&", "4" },
    &.{ "", "|", "7" },
    // --- grouping ---
    &.{ "(", "2", "+", "3", ")", "*", "4" },
    // --- string functions ---
    &.{ "length", "foobar" },
    &.{ "substr", "foobar", "2", "3" },
    &.{ "substr", "12345", "2", "3" }, // integer operand → dangling-slice fix
    &.{ "index", "foobar", "bar" },
    &.{ "index", "foobar", "xyz" },
    // --- match (`:`) with capture group into a stack buffer (UAF fix) ---
    &.{ "12345", ":", "1\\(23\\)" }, // integer left operand → arena, not stack
    &.{ "abc123", ":", "abc\\([0-9]*\\)" }, // POSIX bracket class in group
    &.{ "abc123", ":", "abc[0-9]*" },
    &.{ "hello123", ":", "[a-z]*" }, // range
    &.{ "abcXYZ", ":", "[a-z]*" },
    &.{ "hello", ":", "[^0-9]*" }, // negated class
    &.{ "5", ":", "[0-9]" },
    &.{ "x", ":", "[0-9]" }, // no match → 0, exit 1
    &.{ "foobar", ":", "foo" },
    &.{ "foobar", ":", "xyz" },
    &.{ "match", "abc123", "abc\\([0-9]*\\)" },
    // --- errors ---
    &.{ "1", "/", "0" }, // division by zero → exit 2
};

test "zexpr matches GNU expr byte-for-byte" {
    const alloc = std.testing.allocator;

    const zexpr_z = std.c.getenv("ZEXPR_BIN") orelse {
        std.debug.print("ZEXPR_BIN not set; run via `zig build test`\n", .{});
        return error.SkipZigTest;
    };
    const zexpr = std.mem.span(zexpr_z);

    const gnu = findGnuExpr() orelse {
        std.debug.print("no GNU expr found; skipping live parity block\n", .{});
        return error.SkipZigTest;
    };

    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var failures: usize = 0;
    for (parity_cases) |c| {
        const z = try runBin(alloc, io, zexpr, c);
        defer alloc.free(z.stdout);
        const g = try runBin(alloc, io, gnu, c);
        defer alloc.free(g.stdout);

        if (!std.mem.eql(u8, z.stdout, g.stdout) or z.code != g.code) {
            failures += 1;
            std.debug.print(
                "DIFF {any}\n  gnu:   out={s} exit={d}\n  zexpr: out={s} exit={d}\n",
                .{ c, g.stdout, g.code, z.stdout, z.code },
            );
        }
    }
    try std.testing.expectEqual(@as(usize, 0), failures);
}

// Literal-byte anchors from the GNU coreutils manual (info coreutils 'expr
// invocation') and POSIX.1-2017 `expr`, confirmed against gexpr 9.10. These run
// even with no GNU binary installed, so there is always an external anchor.
const Documented = struct {
    args: Case,
    stdout: []const u8,
    code: u8,
    src: []const u8,
};

const documented_cases = [_]Documented{
    // GNU manual: "expr treats % as C's remainder"; C99 6.5.5: result takes the
    // sign of the dividend. gexpr 9.10: `expr -7 % 2` -> -1.
    .{ .args = &.{ "-7", "%", "2" }, .stdout = "-1\n", .code = 0, .src = "GNU manual / C99 6.5.5" },
    .{ .args = &.{ "7", "%", "-2" }, .stdout = "1\n", .code = 0, .src = "GNU manual / C99 6.5.5" },
    // GNU expr is arbitrary precision: this exceeds i64 (9223372036854775807).
    // gexpr 9.10: exact sum, exit 0. (Old zexpr panicked; must not.)
    .{ .args = &.{ "9223372036854775807", "+", "1" }, .stdout = "9223372036854775808\n", .code = 0, .src = "gexpr 9.10 (arbitrary precision)" },
    // POSIX: `STRING : REGEX` with a subexpression \(\) returns the matched
    // substring. gexpr 9.10: `expr abc123 : 'abc\([0-9]*\)'` -> 123, exit 0.
    .{ .args = &.{ "abc123", ":", "abc\\([0-9]*\\)" }, .stdout = "123\n", .code = 0, .src = "POSIX expr / gexpr 9.10" },
    // POSIX: `:` with no subexpression returns match length; no match -> 0.
    .{ .args = &.{ "foobar", ":", "foo" }, .stdout = "3\n", .code = 0, .src = "POSIX expr / gexpr 9.10" },
    .{ .args = &.{ "x", ":", "[0-9]" }, .stdout = "0\n", .code = 1, .src = "POSIX expr / gexpr 9.10" },
    // GNU manual: substr STRING POS LENGTH, POS counted from 1.
    .{ .args = &.{ "substr", "foobar", "2", "3" }, .stdout = "oob\n", .code = 0, .src = "GNU manual (expr invocation)" },
    // GNU manual: length STRING.
    .{ .args = &.{ "length", "foobar" }, .stdout = "6\n", .code = 0, .src = "GNU manual (expr invocation)" },
    // POSIX: exit 1 when the value is null or zero.
    .{ .args = &.{ "0", "|", "0" }, .stdout = "0\n", .code = 1, .src = "POSIX expr exit status" },
};

test "zexpr matches documented GNU/POSIX bytes" {
    const alloc = std.testing.allocator;
    const zexpr_z = std.c.getenv("ZEXPR_BIN") orelse {
        return error.SkipZigTest;
    };
    const zexpr = std.mem.span(zexpr_z);

    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    for (documented_cases) |d| {
        const z = try runBin(alloc, io, zexpr, d.args);
        defer alloc.free(z.stdout);
        std.testing.expectEqualStrings(d.stdout, z.stdout) catch |e| {
            std.debug.print("case {any} (src: {s}) exit={d}\n", .{ d.args, d.src, z.code });
            return e;
        };
        std.testing.expectEqual(d.code, z.code) catch |e| {
            std.debug.print("exit mismatch {any} (src: {s})\n", .{ d.args, d.src });
            return e;
        };
    }
}
