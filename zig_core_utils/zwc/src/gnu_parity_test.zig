//! GNU-parity differential tests for zwc.
//!
//! External anchor (see zig-forge/CLAUDE.md "golden rule" §1): these tests do
//! NOT check zwc against itself. They shell out to BOTH the built zwc binary and
//! the real GNU `wc` (coreutils 9.x) and compare stdout byte-for-byte, plus a
//! set of golden checks whose expected bytes are literal GNU coreutils 9.10
//! output (cited inline) so an anchor still bites when no GNU binary is present.
//!
//! The zwc binary path is injected by build.zig via the `build_options` module.
//! The GNU binary is discovered at runtime from the usual Homebrew/Linux paths;
//! if none is found the differential test is skipped (the golden test still
//! runs), and that skip is surfaced by `zig build test`.

const std = @import("std");
const testing = std.testing;
const build_options = @import("build_options");

const zwc_exe: []const u8 = build_options.zwc_exe;

const gnu_candidates = [_][]const u8{
    "/opt/homebrew/opt/coreutils/libexec/gnubin/wc",
    "/opt/homebrew/bin/gwc",
    "/usr/local/opt/coreutils/libexec/gnubin/wc",
    "/usr/local/bin/gwc",
    "/usr/bin/gwc",
};

// A real threaded Io backed by libc's allocator and the *actual* process
// environment. The std `global_single_threaded` instance uses a failing
// allocator (can't spawn) and an empty environ (children would have no PATH,
// breaking the /bin/sh pipelines and `cat`/`rm`/`mktemp` used below).
var g_threaded: std.Io.Threaded = undefined;
var g_threaded_ready = false;

fn io() std.Io {
    if (!g_threaded_ready) {
        const c_env = std.c.environ;
        var n: usize = 0;
        while (c_env[n] != null) : (n += 1) {}
        const block: std.process.Environ.Block = .{ .slice = @ptrCast(c_env[0..n :null]) };
        g_threaded = std.Io.Threaded.init(std.heap.c_allocator, .{ .environ = .{ .block = block } });
        g_threaded_ready = true;
    }
    return g_threaded.io();
}

/// libc allocator for all process plumbing (avoids leak-checker false positives
/// from std's spawn internals; these tests assert parity, not allocation).
const gpa_impl = std.heap.c_allocator;

/// build.zig injects `zwc_exe` as a path relative to the build root. Child
/// processes below run with `cwd = tmp`, so that relative path would not
/// resolve — turn it into an absolute path against the (unchanged) test-process
/// cwd once, and reuse it.
var g_zwc_abs: ?[]const u8 = null;

fn zwcAbs() []const u8 {
    if (g_zwc_abs) |p| return p;
    if (std.fs.path.isAbsolute(zwc_exe)) {
        g_zwc_abs = zwc_exe;
        return zwc_exe;
    }
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    if (std.c.getcwd(&cwd_buf, cwd_buf.len) == null) @panic("getcwd failed");
    const cwd = std.mem.sliceTo(&cwd_buf, 0);
    g_zwc_abs = std.fs.path.join(gpa_impl, &.{ cwd, zwc_exe }) catch @panic("OOM");
    return g_zwc_abs.?;
}

const Run = struct {
    stdout: []u8,
    stderr: []u8,
    exit: u8,

    fn free(self: Run, gpa: std.mem.Allocator) void {
        gpa.free(self.stdout);
        gpa.free(self.stderr);
    }
};

fn termExit(term: std.process.Child.Term) u8 {
    return switch (term) {
        .exited => |c| c,
        else => 255,
    };
}

/// Run argv (argv[0] must be a path), optionally with a working directory.
fn runArgs(gpa: std.mem.Allocator, cwd: ?[]const u8, argv: []const []const u8) !Run {
    const r = try std.process.run(gpa, io(), .{
        .argv = argv,
        .cwd = if (cwd) |c| .{ .path = c } else .inherit,
    });
    return .{ .stdout = r.stdout, .stderr = r.stderr, .exit = termExit(r.term) };
}

/// Run a /bin/sh command line in `cwd`.
fn runSh(gpa: std.mem.Allocator, cwd: ?[]const u8, cmd: []const u8) !Run {
    return runArgs(gpa, cwd, &.{ "/bin/sh", "-c", cmd });
}

/// Discover a GNU wc binary; returns null if none is installed.
fn findGnu(gpa: std.mem.Allocator) ?[]const u8 {
    for (gnu_candidates) |cand| {
        const r = runArgs(gpa, null, &.{ cand, "--version" }) catch continue;
        defer r.free(gpa);
        // GNU wc --version prints "wc (GNU coreutils) ..."; reject BSD wc.
        if (r.exit == 0 and std.mem.indexOf(u8, r.stdout, "GNU coreutils") != null)
            return cand;
    }
    return null;
}

/// Create a fresh temp dir with the fixture files/dirs both binaries read.
/// Returns the absolute temp dir path (caller frees).
fn makeFixtures(gpa: std.mem.Allocator) ![]u8 {
    const mk = try runArgs(gpa, null, &.{ "mktemp", "-d" });
    defer mk.free(gpa);
    const tmp = try gpa.dupe(u8, std.mem.trimEnd(u8, mk.stdout, "\n"));
    errdefer gpa.free(tmp);

    // f1: 3 lines / 3 words / 9 bytes
    // f2: 1 line  / 3 words / 6 bytes
    // f3: 2 lines / 3 words / 16 bytes
    // empty: 0/0/0
    // wide (UTF-8, octal escapes are POSIX-portable in printf):
    //   h é(C3 A9) l l o SP 中(E4 B8 AD) 文(E6 96 87) SP 😀(F0 9F 98 80) NL
    // adir: a directory (for "Is a directory" parity)
    const setup =
        "printf 'a\\nbb\\nccc\\n' > f1 && " ++
        "printf 'x y z\\n' > f2 && " ++
        "printf 'hello world\\nfoo\\n' > f3 && " ++
        "printf '' > empty && " ++
        "printf 'h\\303\\251llo \\344\\270\\255\\346\\226\\207 \\360\\237\\230\\200\\n' > wide && " ++
        "mkdir -p adir";
    const s = try runSh(gpa, tmp, setup);
    defer s.free(gpa);
    try testing.expectEqual(@as(u8, 0), s.exit);
    return tmp;
}

fn rmrf(gpa: std.mem.Allocator, path: []const u8) void {
    const r = runArgs(gpa, null, &.{ "rm", "-rf", path }) catch return;
    r.free(gpa);
}

const Case = struct {
    name: []const u8,
    args: []const []const u8,
    /// When set, pipe this fixture file into stdin instead of passing file args,
    /// so the input is a real pipe (exercises GNU's fallback column width).
    stdin_fixture: ?[]const u8 = null,
};

const cases = [_]Case{
    // --- file arguments ---
    .{ .name = "single file default", .args = &.{"f1"} },
    .{ .name = "two files + total", .args = &.{ "f1", "f2" } },
    // The critical redirect bug lives in a separate test (needs stdout=file);
    // here we still assert three-file totals/format via pipe capture.
    .{ .name = "three files + total", .args = &.{ "f1", "f2", "f3" } },
    .{ .name = "-l three files", .args = &.{ "-l", "f1", "f2", "f3" } },
    .{ .name = "-w single", .args = &.{ "-w", "f1" } },
    .{ .name = "-c two files", .args = &.{ "-c", "f1", "f2" } },
    .{ .name = "-m wide utf8", .args = &.{ "-m", "wide" } },
    .{ .name = "-L wide utf8", .args = &.{ "-L", "wide" } },
    .{ .name = "-lwc combined", .args = &.{ "-lwc", "f1" } },
    .{ .name = "-L two files", .args = &.{ "-L", "f1", "f2" } },
    .{ .name = "--total=only", .args = &.{ "--total=only", "f1", "f2" } },
    .{ .name = "--total=always single", .args = &.{ "--total=always", "f1" } },
    .{ .name = "--total=never two", .args = &.{ "--total=never", "f1", "f2" } },
    .{ .name = "empty file", .args = &.{"empty"} },
    .{ .name = "-c directory", .args = &.{ "-c", "adir" } },
    .{ .name = "default directory", .args = &.{"adir"} },
    .{ .name = "directory + file + total", .args = &.{ "adir", "f1" } },
    .{ .name = "nonexistent file", .args = &.{"does_not_exist"} },
    .{ .name = "file + nonexistent + total", .args = &.{ "f1", "does_not_exist", "f2" } },
    // --- piped stdin (real pipe: fallback width) ---
    .{ .name = "pipe default (3 col width 7)", .args = &.{}, .stdin_fixture = "f1" },
    .{ .name = "pipe -l (single col width 1)", .args = &.{"-l"}, .stdin_fixture = "f1" },
    .{ .name = "pipe -lw (width 7)", .args = &.{"-lw"}, .stdin_fixture = "f1" },
    .{ .name = "pipe empty default", .args = &.{}, .stdin_fixture = "empty" },
    .{ .name = "pipe -L wide", .args = &.{"-L"}, .stdin_fixture = "wide" },
    .{ .name = "pipe -m wide", .args = &.{"-m"}, .stdin_fixture = "wide" },
};

/// Build a single-quoted shell token (fixture/arg names contain no quotes).
fn quoted(gpa: std.mem.Allocator, list: *std.ArrayListUnmanaged(u8), tok: []const u8) !void {
    try list.append(gpa, '\'');
    try list.appendSlice(gpa, tok);
    try list.appendSlice(gpa, "' ");
}

/// Run one case against `bin` in `cwd`, returning its stdout+exit.
fn runCase(gpa: std.mem.Allocator, cwd: []const u8, bin: []const u8, c: Case) !Run {
    if (c.stdin_fixture) |fix| {
        var cmd: std.ArrayListUnmanaged(u8) = .empty;
        defer cmd.deinit(gpa);
        try cmd.appendSlice(gpa, "cat ");
        try quoted(gpa, &cmd, fix);
        try cmd.appendSlice(gpa, "| ");
        try quoted(gpa, &cmd, bin);
        for (c.args) |a| try quoted(gpa, &cmd, a);
        return runSh(gpa, cwd, cmd.items);
    }
    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.append(gpa, bin);
    for (c.args) |a| try argv.append(gpa, a);
    return runArgs(gpa, cwd, argv.items);
}

test "zwc matches GNU wc (differential)" {
    const gpa = gpa_impl;

    const gnu = findGnu(gpa) orelse {
        std.debug.print("SKIP: no GNU wc found in {any}\n", .{gnu_candidates});
        return error.SkipZigTest;
    };

    const tmp = try makeFixtures(gpa);
    defer {
        rmrf(gpa, tmp);
        gpa.free(tmp);
    }

    var failures: usize = 0;
    for (cases) |c| {
        const z = try runCase(gpa, tmp, zwcAbs(), c);
        defer z.free(gpa);
        const g = try runCase(gpa, tmp, gnu, c);
        defer g.free(gpa);

        if (!std.mem.eql(u8, z.stdout, g.stdout)) {
            failures += 1;
            std.debug.print(
                "\nSTDOUT mismatch [{s}]:\n  zwc: \"{f}\"\n  gnu: \"{f}\"\n",
                .{ c.name, std.zig.fmtString(z.stdout), std.zig.fmtString(g.stdout) },
            );
        }
        if (z.exit != g.exit) {
            failures += 1;
            std.debug.print(
                "\nEXIT mismatch [{s}]: zwc={d} gnu={d}\n",
                .{ c.name, z.exit, g.exit },
            );
        }
    }

    try testing.expectEqual(@as(usize, 0), failures);
}

// The critical bug: when stdout is a REGULAR FILE, a per-line stdout writer
// re-seeks to offset 0 each line and clobbers all but the last. A pipe (as used
// above) hides it because positional writes fall back to streaming. This test
// forces the file-redirect path and compares the redirected bytes to GNU's.
test "multi-file output survives a stdout redirect to a regular file" {
    const gpa = gpa_impl;

    const gnu = findGnu(gpa) orelse return error.SkipZigTest;

    const tmp = try makeFixtures(gpa);
    defer {
        rmrf(gpa, tmp);
        gpa.free(tmp);
    }

    // zwc with stdout redirected to a real file, then read the file back.
    const redir = try std.fmt.allocPrint(gpa, "'{s}' f1 f2 f3 > out.txt", .{zwcAbs()});
    defer gpa.free(redir);
    const rr = try runSh(gpa, tmp, redir);
    rr.free(gpa);

    const got = try runArgs(gpa, tmp, &.{ "cat", "out.txt" });
    defer got.free(gpa);

    const want = try runArgs(gpa, tmp, &.{ gnu, "f1", "f2", "f3" });
    defer want.free(gpa);

    // All four lines (three files + total) must be present and identical.
    try testing.expectEqualStrings(want.stdout, got.stdout);
    // Sanity: four newline-terminated lines survived, not just the total.
    try testing.expectEqual(@as(usize, 4), std.mem.count(u8, got.stdout, "\n"));
}

// Golden anchor: literal GNU coreutils 9.10 output, so a regression is caught
// even without a GNU binary present. Produced by:
//   printf 'a\nbb\nccc\n' > f1   # 3 lines, 3 words, 9 bytes
// and running GNU `wc` with the flags shown.
test "golden GNU coreutils 9.10 byte-exact output" {
    const gpa = gpa_impl;

    const tmp = try makeFixtures(gpa);
    defer {
        rmrf(gpa, tmp);
        gpa.free(tmp);
    }

    const Golden = struct { args: []const []const u8, want: []const u8 };
    const goldens = [_]Golden{
        // wc f1              -> "3 3 9 f1\n"   (single file, minimum width 1)
        .{ .args = &.{"f1"}, .want = "3 3 9 f1\n" },
        // wc -c f1           -> "9 f1\n"
        .{ .args = &.{ "-c", "f1" }, .want = "9 f1\n" },
        // wc -l f1           -> "3 f1\n"
        .{ .args = &.{ "-l", "f1" }, .want = "3 f1\n" },
        // wc -w f1           -> "3 f1\n"
        .{ .args = &.{ "-w", "f1" }, .want = "3 f1\n" },
        // wc -L f1           -> "3 f1\n"  (longest line "ccc" = 3)
        .{ .args = &.{ "-L", "f1" }, .want = "3 f1\n" },
        // wc f1 f2           -> width from summed sizes (15 -> 2 digits)
        //   " 3  3  9 f1\n 1  3  6 f2\n 4  6 15 total\n"
        .{ .args = &.{ "f1", "f2" }, .want = " 3  3  9 f1\n 1  3  6 f2\n 4  6 15 total\n" },
        // wc --total=only f1 f2 -> "4 6 15\n" (no "total" label)
        .{ .args = &.{ "--total=only", "f1", "f2" }, .want = "4 6 15\n" },
    };

    var failures: usize = 0;
    for (goldens) |gd| {
        var argv: std.ArrayListUnmanaged([]const u8) = .empty;
        defer argv.deinit(gpa);
        try argv.append(gpa, zwcAbs());
        for (gd.args) |a| try argv.append(gpa, a);
        const z = try runArgs(gpa, tmp, argv.items);
        defer z.free(gpa);
        if (!std.mem.eql(u8, z.stdout, gd.want)) {
            failures += 1;
            std.debug.print(
                "\nGOLDEN mismatch [{s}]:\n  got:  \"{f}\"\n  want: \"{f}\"\n",
                .{ gd.args[0], std.zig.fmtString(z.stdout), std.zig.fmtString(gd.want) },
            );
        }
    }
    try testing.expectEqual(@as(usize, 0), failures);
}
