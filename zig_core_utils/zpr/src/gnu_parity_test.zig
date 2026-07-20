//! Externally-anchored parity tests for zpr (GNU `pr` clone).
//!
//! These are NOT roundtrip tests. Each one anchors zpr's output against an
//! external authority:
//!
//!   * When the real GNU `pr` binary is present (coreutils 9.10, discovered at
//!     a well-known Homebrew path), the test runs BOTH binaries on identical
//!     input/flags and asserts byte-for-byte identical stdout, plus identical
//!     success/failure of the exit status. GNU coreutils `pr` is the reference
//!     implementation named in this util's audit.
//!
//!   * When no GNU binary is found, header-independent cases still assert the
//!     exact bytes documented by POSIX / GNU coreutils behaviour, written
//!     literally in the test with a citation, so the anchor still bites.
//!
//! Header-dependent modes (default paginated output) embed the current local
//! wall-clock time, which differs between the two process invocations, so those
//! are NOT byte-compared; instead they carry targeted assertions (no spurious
//! '+' on the year; exit status).
//!
//! The zpr binary under test is located via a build option (`zpr_exe_path`)
//! set by build.zig to the freshly-compiled artifact.

const std = @import("std");
const build_options = @import("build_options");
const Io = std.Io;

const gnu_candidates = [_][]const u8{
    "/opt/homebrew/opt/coreutils/libexec/gnubin/pr",
    "/opt/homebrew/bin/gpr",
    "/usr/local/opt/coreutils/libexec/gnubin/pr",
    "/usr/local/bin/gpr",
};

fn findGnuPr(io: Io) ?[]const u8 {
    for (gnu_candidates) |c| {
        const f = std.Io.Dir.openFileAbsolute(io, c, .{}) catch continue;
        f.close(io);
        return c;
    }
    return null;
}

/// Write `data` to an absolute temp path, returning the path (static buffer).
fn writeTemp(io: Io, name: []const u8, data: []const u8) ![]const u8 {
    const S = struct {
        var buf: [256]u8 = undefined;
    };
    const path = try std.fmt.bufPrint(&S.buf, "/tmp/zpr_parity_{s}.txt", .{name});
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = data });
    return path;
}

const Captured = struct {
    stdout: []u8,
    stderr: []u8,
    ok: bool, // exited with code 0

    fn deinit(self: Captured, a: std.mem.Allocator) void {
        a.free(self.stdout);
        a.free(self.stderr);
    }
};

fn runProg(a: std.mem.Allocator, io: Io, argv: []const []const u8) !Captured {
    const r = try std.process.run(a, io, .{ .argv = argv });
    const ok = switch (r.term) {
        .exited => |code| code == 0,
        else => false,
    };
    return .{ .stdout = r.stdout, .stderr = r.stderr, .ok = ok };
}

fn zprRun(a: std.mem.Allocator, io: Io, extra: []const []const u8) !Captured {
    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    defer argv.deinit(a);
    try argv.append(a, build_options.zpr_exe_path);
    for (extra) |e| try argv.append(a, e);
    return runProg(a, io, argv.items);
}

fn gnuRun(a: std.mem.Allocator, io: Io, gnu: []const u8, extra: []const []const u8) !Captured {
    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    defer argv.deinit(a);
    try argv.append(a, gnu);
    for (extra) |e| try argv.append(a, e);
    return runProg(a, io, argv.items);
}

/// Run zpr and GNU pr with `flags` on a temp file holding `input`; assert their
/// stdout is byte-identical and their exit-success matches. Skips the byte
/// compare only when no GNU binary is installed (caller then relies on the
/// literal-anchor tests below).
fn expectParity(a: std.mem.Allocator, io: Io, name: []const u8, flags: []const []const u8, input: []const u8) !void {
    const gnu = findGnuPr(io) orelse return;
    const path = try writeTemp(io, name, input);

    var zflags: std.ArrayListUnmanaged([]const u8) = .empty;
    defer zflags.deinit(a);
    for (flags) |f| try zflags.append(a, f);
    try zflags.append(a, path);

    const z = try zprRun(a, io, zflags.items);
    defer z.deinit(a);
    const g = try gnuRun(a, io, gnu, zflags.items);
    defer g.deinit(a);

    if (!std.mem.eql(u8, z.stdout, g.stdout)) {
        std.debug.print(
            "PARITY MISMATCH flags={any}\n--- zpr ({d}B) ---\n{s}\n--- gnu ({d}B) ---\n{s}\n",
            .{ flags, z.stdout.len, z.stdout, g.stdout.len, g.stdout },
        );
        return error.ParityMismatch;
    }
    try std.testing.expectEqual(g.ok, z.ok);
}

// -----------------------------------------------------------------------------
// -t / --omit-header: GNU emits exactly the content lines with NO page padding.
// (Fixed medium finding.) These bodies have no header, so output is
// time-independent and byte-comparable end to end.
// -----------------------------------------------------------------------------

test "-t emits content with no padding (GNU parity)" {
    const a = std.testing.allocator;
    try expectParity(a, std.testing.io, "t_basic", &.{"-t"}, "line1\nline2\nline3\n");
}

test "-t -n numbers lines, no padding (GNU parity)" {
    const a = std.testing.allocator;
    try expectParity(a, std.testing.io, "t_n", &.{ "-t", "-n" }, "alpha\nbeta\ngamma\n");
}

test "-t -d double-spaces, no padding (GNU parity)" {
    const a = std.testing.allocator;
    try expectParity(a, std.testing.io, "t_d", &.{ "-t", "-d" }, "one\ntwo\nthree\n");
}

test "-t single line (GNU parity)" {
    const a = std.testing.allocator;
    try expectParity(a, std.testing.io, "t_one", &.{"-t"}, "only\n");
}

test "-t empty input (GNU parity)" {
    const a = std.testing.allocator;
    try expectParity(a, std.testing.io, "t_empty", &.{"-t"}, "");
}

test "-t -n twelve lines exercises number width (GNU parity)" {
    const a = std.testing.allocator;
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(a);
    var n: usize = 1;
    while (n <= 12) : (n += 1) try buf.print(a, "row-{d}\n", .{n});
    try expectParity(a, std.testing.io, "t_n12", &.{ "-t", "-n" }, buf.items);
}

// -----------------------------------------------------------------------------
// -t literal anchors: exact documented bytes even with no GNU binary present.
// Source: POSIX `pr` / GNU coreutils manual — `-t` "Do not print the usual
// header [and trailer]"; the body is the input verbatim. `-n` default numbers
// each line right-justified in a 5-wide field followed by TAB (verified against
// coreutils 9.10 hexdump: 20 20 20 20 31 09 61 0a == "    1<TAB>a\n").
// -----------------------------------------------------------------------------

test "-t exact documented bytes (literal anchor)" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    const path = try writeTemp(io, "lit_t", "line1\nline2\nline3\n");
    const z = try zprRun(a, io, &.{ "-t", path });
    defer z.deinit(a);
    try std.testing.expectEqualStrings("line1\nline2\nline3\n", z.stdout);
    try std.testing.expect(z.ok);
}

test "-t -n exact documented bytes (literal anchor: width-5 num + TAB)" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    const path = try writeTemp(io, "lit_tn", "a\nb\n");
    const z = try zprRun(a, io, &.{ "-t", "-n", path });
    defer z.deinit(a);
    try std.testing.expectEqualStrings("    1\ta\n    2\tb\n", z.stdout);
    try std.testing.expect(z.ok);
}

// -----------------------------------------------------------------------------
// Exit status: file-open failure must be nonzero (was 0 before the fix). GNU pr
// prints an error and exits 1 for a missing file.
// -----------------------------------------------------------------------------

test "missing file exits nonzero (was 0)" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    const z = try zprRun(a, io, &.{"/tmp/zpr_definitely_missing_9f8a7b6c.txt"});
    defer z.deinit(a);
    try std.testing.expect(!z.ok);
}

// -----------------------------------------------------------------------------
// -l 0: GNU rejects with an error and exits nonzero. Pre-fix zpr looped forever
// (a header per iteration, page_num climbing to maxInt). Anchor: nonzero exit +
// a nonempty stderr diagnostic + no page body emitted; cross-checked against
// GNU when available.
// -----------------------------------------------------------------------------

test "-l 0 is rejected, exits nonzero, does not hang" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    const path = try writeTemp(io, "l0", "line1\nline2\n");
    const z = try zprRun(a, io, &.{ "-l", "0", path });
    defer z.deinit(a);
    try std.testing.expect(!z.ok);
    try std.testing.expect(z.stderr.len > 0);
    try std.testing.expectEqual(@as(usize, 0), z.stdout.len);

    if (findGnuPr(io)) |gnu| {
        const g = try gnuRun(a, io, gnu, &.{ "-l", "0", path });
        defer g.deinit(a);
        try std.testing.expect(!g.ok);
    }
}

// -----------------------------------------------------------------------------
// Header year: must not carry the spurious '+' that Zig 0.16 emits for a signed
// int with a width/fill spec. The default (headered) output's date line must
// begin with a digit, never '+'.
// -----------------------------------------------------------------------------

test "default header year has no spurious '+' prefix" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    const path = try writeTemp(io, "hdr", "hello\n");
    const z = try zprRun(a, io, &.{path});
    defer z.deinit(a);
    try std.testing.expect(z.ok);

    // Layout: "\n\n<date line>\n\n\n<body>...". The date line is the first
    // non-empty line.
    var it = std.mem.splitScalar(u8, z.stdout, '\n');
    var date_line: ?[]const u8 = null;
    while (it.next()) |line| {
        if (line.len > 0) {
            date_line = line;
            break;
        }
    }
    const dl = date_line orelse return error.NoHeaderLine;
    try std.testing.expect(dl[0] != '+'); // the bug produced "+2026-..."
    try std.testing.expect(dl[0] >= '0' and dl[0] <= '9');
}
