//! Externally-anchored GNU parity tests for zls.
//!
//! Primary anchor: the real GNU coreutils `ls` binary (9.x, the audit
//! reference at /opt/homebrew/opt/coreutils/libexec/gnubin/ls). Every parity
//! case runs BOTH binaries on the same fixture tree with a controlled
//! environment (LC_ALL, TZ) and byte-compares stdout plus the exit code.
//! None of the expected outputs are produced by zls itself.
//!
//! Secondary anchor: literal-expected cases transcribed from documented GNU
//! behavior (coreutils ls.c / POSIX), so the suite still asserts real bytes
//! if no GNU binary is installed.
//!
//! Run via `zig build test`.

const std = @import("std");
const Io = std.Io;
const builtin = @import("builtin");
const build_options = @import("build_options");

const zls_exe: []const u8 = build_options.zls_exe;

/// build_options.zls_exe may be relative to the package root; the children
/// run with cwd set to the fixture dir, so resolve it to an absolute path.
fn absExe(arena: std.mem.Allocator, io: Io) ![]const u8 {
    if (std.fs.path.isAbsolute(zls_exe)) return zls_exe;
    return try Io.Dir.cwd().realPathFileAlloc(io, zls_exe, arena);
}

extern "c" fn chmod(path: [*:0]const u8, mode: std.c.mode_t) c_int;
extern "c" fn geteuid() std.c.uid_t;

/// Locations where a GNU coreutils `ls` may live. The audit reference is
/// the homebrew coreutils gnubin path; /usr/bin/ls is GNU on Linux.
const gnu_candidates = [_][]const u8{
    "/opt/homebrew/opt/coreutils/libexec/gnubin/ls",
    "/opt/homebrew/bin/gls",
    "/usr/local/opt/coreutils/libexec/gnubin/ls",
    "/usr/local/bin/gls",
};

fn findGnuLs(io: Io) ?[]const u8 {
    for (gnu_candidates) |path| {
        const f = Io.Dir.openFile(Io.Dir.cwd(), io, path, .{}) catch continue;
        f.close(io);
        return path;
    }
    if (builtin.os.tag == .linux) {
        const f = Io.Dir.openFile(Io.Dir.cwd(), io, "/usr/bin/ls", .{}) catch return null;
        f.close(io);
        return "/usr/bin/ls";
    }
    return null;
}

const RunResult = struct {
    stdout: []u8,
    stderr: []u8,
    exit_code: u8,
};

/// Spawn `exe` with the case's args, cwd set to the fixture dir, with a
/// fixed environment (TZ=UTC plus the case's LC_ALL) so time formatting and
/// collation are deterministic and identical for both binaries.
fn runTool(
    arena: std.mem.Allocator,
    io: Io,
    exe: []const u8,
    case: Case,
    fixture_dir: Io.Dir,
) !RunResult {
    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    try argv.append(arena, exe);
    for (case.args) |a| try argv.append(arena, a);

    var env = std.process.Environ.Map.init(arena);
    try env.put("LC_ALL", case.lc_all);
    try env.put("TZ", "UTC");

    var child = try std.process.spawn(io, .{
        .argv = argv.items,
        .cwd = .{ .dir = fixture_dir },
        .environ_map = &env,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    defer child.kill(io);

    var multi_reader_buffer: Io.File.MultiReader.Buffer(2) = undefined;
    var multi_reader: Io.File.MultiReader = undefined;
    multi_reader.init(arena, io, multi_reader_buffer.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer multi_reader.deinit();

    while (multi_reader.fill(4096, .none)) |_| {} else |err| switch (err) {
        error.EndOfStream => {},
        else => |e| return e,
    }
    try multi_reader.checkAnyError();

    const term = try child.wait(io);
    const stdout = try multi_reader.toOwnedSlice(0);
    const stderr = try multi_reader.toOwnedSlice(1);

    return .{
        .stdout = stdout,
        .stderr = stderr,
        .exit_code = switch (term) {
            .exited => |code| code,
            else => 255,
        },
    };
}

const Case = struct {
    name: []const u8,
    args: []const []const u8,
    lc_all: []const u8 = "C",
    /// Expected exit code shared by both binaries (cross-checked against
    /// what GNU actually returned so a stale expectation is caught).
    expect_exit: u8 = 0,
    /// Also require stderr to match after program-name normalization.
    compare_stderr: bool = false,
    /// Skip when running as root (permission-denied fixtures).
    needs_nonroot: bool = false,
};

/// Normalize a tool's stderr so the two binaries' outputs are comparable:
/// occurrences of the exe path become "PROG", and a "NAME: " message prefix
/// at the start of a line becomes "PROG: " (GNU prints "ls: cannot access
/// ..." but "Try '/full/path/ls --help'").
fn normalizeStderr(arena: std.mem.Allocator, s: []const u8, exe: []const u8, prog: []const u8) ![]u8 {
    const no_path = try std.mem.replaceOwned(u8, arena, s, exe, "PROG");
    const prefixed = try std.mem.concat(arena, u8, &.{ "\n", no_path });
    const needle = try std.mem.concat(arena, u8, &.{ "\n", prog, ": " });
    const replaced = try std.mem.replaceOwned(u8, arena, prefixed, needle, "\nPROG: ");
    return replaced[1..];
}

fn setMtime(io: Io, dir: Io.Dir, sub_path: []const u8, sec: i64) !void {
    const f = try dir.openFile(io, sub_path, .{});
    defer f.close(io);
    try f.setTimestamps(io, .{
        .access_timestamp = .{ .new = .{ .nanoseconds = @as(i96, sec) * std.time.ns_per_s } },
        .modify_timestamp = .{ .new = .{ .nanoseconds = @as(i96, sec) * std.time.ns_per_s } },
    });
}

const t_old: i64 = 1577836800; // 2020-01-01 00:00:00 UTC (">6 months ago" branch)
const t_old2: i64 = 1609459200; // 2021-01-01 00:00:00 UTC

fn writeFixtures(arena: std.mem.Allocator, io: Io, dir: Io.Dir) !void {
    // basic/: plain sorted-listing fodder, incl. a hidden file for -a/-A
    try dir.createDirPath(io, "basic");
    for ([_][]const u8{ "basic/alpha.txt", "basic/beta.md", "basic/gamma", "basic/.hidden" }) |p| {
        try dir.writeFile(io, .{ .sub_path = p, .data = "" });
    }

    // ties/: -t/-S tie-break + reverse-sort crash fixtures. Three files share
    // an mtime second (the `-ltr` abort case from the audit), one is newer,
    // one is recent (exercises the "recent" default time-style branch).
    try dir.createDirPath(io, "ties");
    for ([_][]const u8{ "ties/zebra", "ties/alpha", "ties/mid", "ties/newer", "ties/recent" }) |p| {
        try dir.writeFile(io, .{ .sub_path = p, .data = "" });
    }
    try setMtime(io, dir, "ties/zebra", t_old);
    try setMtime(io, dir, "ties/alpha", t_old);
    try setMtime(io, dir, "ties/mid", t_old);
    try setMtime(io, dir, "ties/newer", t_old2);
    const now_sec: i64 = @intCast(@divTrunc(Io.Timestamp.now(io, .real).nanoseconds, std.time.ns_per_s));
    try setMtime(io, dir, "ties/recent", now_sec - 3600);

    // sizes/: -S ties (two 0-byte files) + -h formatting edges. 10444 bytes
    // is the human_ceiling case: GNU prints "11K", naive rounding gives "10K".
    try dir.createDirPath(io, "sizes");
    const big = try arena.alloc(u8, 1500000);
    @memset(big, 'x');
    try dir.writeFile(io, .{ .sub_path = "sizes/f3", .data = "abc" });
    try dir.writeFile(io, .{ .sub_path = "sizes/f4096", .data = big[0..4096] });
    try dir.writeFile(io, .{ .sub_path = "sizes/f10444", .data = big[0..10444] });
    try dir.writeFile(io, .{ .sub_path = "sizes/f1500000", .data = big });
    try dir.writeFile(io, .{ .sub_path = "sizes/a0", .data = "" });
    try dir.writeFile(io, .{ .sub_path = "sizes/z0", .data = "" });
    for ([_][]const u8{ "sizes/f3", "sizes/f4096", "sizes/f10444", "sizes/f1500000", "sizes/a0", "sizes/z0" }) |p| {
        try setMtime(io, dir, p, t_old);
    }

    // coll/: locale collation (the Darwin LC_ALL=6 bug fixture): C locale
    // sorts "Banana Cherry aardvark apple", en_US.UTF-8 sorts case-insensitively.
    try dir.createDirPath(io, "coll");
    for ([_][]const u8{ "coll/aardvark", "coll/apple", "coll/Banana", "coll/Cherry" }) |p| {
        try dir.writeFile(io, .{ .sub_path = p, .data = "" });
    }

    // kinds/: file-type classification (-F/-p) incl. symlink-to-dir
    try dir.createDirPath(io, "kinds");
    try dir.createDirPath(io, "kinds/d1");
    try dir.writeFile(io, .{ .sub_path = "kinds/reg", .data = "data" });
    try dir.writeFile(io, .{ .sub_path = "kinds/exec1", .data = "#!/bin/sh\n" });
    try dir.symLink(io, "reg", "kinds/lnk", .{});
    try dir.symLink(io, "d1", "kinds/dlnk", .{});
    try setMtime(io, dir, "kinds/reg", t_old);
    try setMtime(io, dir, "kinds/exec1", t_old);

    // ctrl/: hostile names (terminal escape injection fixtures)
    try dir.createDirPath(io, "ctrl");
    try dir.writeFile(io, .{ .sub_path = "ctrl/evil\x1bname", .data = "" });
    try dir.writeFile(io, .{ .sub_path = "ctrl/line\nname", .data = "" });
    try dir.writeFile(io, .{ .sub_path = "ctrl/normal", .data = "" });

    // rec/: -R shape (headers, blank-line separators, empty subdir)
    try dir.createDirPath(io, "rec/sub1/deep");
    try dir.createDirPath(io, "rec/sub2");
    try dir.writeFile(io, .{ .sub_path = "rec/f1", .data = "" });
    try dir.writeFile(io, .{ .sub_path = "rec/sub1/g1", .data = "" });
    try dir.writeFile(io, .{ .sub_path = "rec/sub1/deep/h1", .data = "" });

    // ext/: -X extension sort
    try dir.createDirPath(io, "ext");
    for ([_][]const u8{ "ext/b.txt", "ext/a.txt", "ext/c.md", "ext/z", "ext/nodot" }) |p| {
        try dir.writeFile(io, .{ .sub_path = p, .data = "" });
    }

    // cdiru/: uniform-width names for -C/-x/-m column comparison
    try dir.createDirPath(io, "cdiru");
    for ([_][]const u8{ "cdiru/f01", "cdiru/f02", "cdiru/f03", "cdiru/f04", "cdiru/f05", "cdiru/f06", "cdiru/f07", "cdiru/f08" }) |p| {
        try dir.writeFile(io, .{ .sub_path = p, .data = "" });
    }

    // loose file operand + symlink-to-dir operand
    try dir.writeFile(io, .{ .sub_path = "loose.txt", .data = "x" });
    try setMtime(io, dir, "loose.txt", t_old);
    try dir.symLink(io, "rec", "linkdir", .{});

    // noperm/: unreadable directory (chmod 000 below, via absolute path)
    try dir.createDirPath(io, "noperm");
}

const parity_cases = [_]Case{
    // Defaults & hidden files
    .{ .name = "plain dir, piped default (one per line)", .args = &.{"basic"} },
    .{ .name = "-a shows . and ..", .args = &.{ "-a", "basic" } },
    .{ .name = "--all long form (audit: was rejected)", .args = &.{ "--all", "basic" } },
    .{ .name = "-A hides . and ..", .args = &.{ "-A", "basic" } },
    .{ .name = "--almost-all long form (audit: was rejected)", .args = &.{ "--almost-all", "basic" } },

    // The audit's crash: -tr/-Sr with tied keys aborted in std.sort
    .{ .name = "-ltr tied mtimes (audit crash: exit 134)", .args = &.{ "-ltr", "ties" } },
    .{ .name = "-lt tied mtimes name tie-break", .args = &.{ "-lt", "ties" } },
    .{ .name = "-t tie-break", .args = &.{ "-t", "ties" } },
    .{ .name = "-tr reverse", .args = &.{ "-tr", "ties" } },
    .{ .name = "-S with 0-byte ties", .args = &.{ "-S", "sizes" } },
    .{ .name = "-Sr reverse (audit crash)", .args = &.{ "-Sr", "sizes" } },
    .{ .name = "-lS long size sort", .args = &.{ "-lS", "sizes" } },

    // Long format & time styles
    .{ .name = "-l default time style (old + recent)", .args = &.{ "-l", "ties" } },
    .{ .name = "-l fixed old times", .args = &.{ "-l", "sizes" } },
    .{ .name = "-lh human sizes incl. ceil case + total (audit)", .args = &.{ "-lh", "sizes" } },
    .{ .name = "-lh long-iso", .args = &.{ "-lh", "--time-style=long-iso", "sizes" } },
    .{ .name = "-l full-iso (ns + tz offset)", .args = &.{ "-l", "--time-style=full-iso", "sizes" } },
    .{ .name = "-l iso", .args = &.{ "-l", "--time-style=iso", "sizes" } },
    .{ .name = "-l posix-long-iso", .args = &.{ "-l", "--time-style=posix-long-iso", "sizes" } },
    .{ .name = "-l +FORMAT custom style", .args = &.{ "-l", "--time-style=+%Y-%m-%dT%H:%M", "sizes" } },

    // Operand ordering (audit: files first, then dirs, both sorted)
    .{ .name = "file operand before dir operand", .args = &.{ "rec", "loose.txt" } },
    .{ .name = "multiple dir operands sorted", .args = &.{ "rec", "basic" } },
    .{ .name = "-d lists dirs themselves", .args = &.{ "-d", "basic" } },
    .{ .name = "-d multiple", .args = &.{ "-d", "rec", "basic" } },
    .{ .name = "symlink-to-dir operand dereferenced", .args = &.{"linkdir"} },
    .{ .name = "symlink-to-dir operand with -l (not deref)", .args = &.{ "-l", "linkdir" } },

    // Control-character quoting (audit security finding)
    .{ .name = "-1q hides control chars", .args = &.{ "-1q", "ctrl" } },
    .{ .name = "-1 piped emits raw bytes (GNU default off-tty)", .args = &.{ "-1", "ctrl" } },

    // Locale collation (audit: Darwin setlocale bug)
    .{ .name = "UTF-8 locale collation", .args = &.{"coll"}, .lc_all = "en_US.UTF-8" },
    .{ .name = "C locale collation", .args = &.{"coll"} },

    // Recursion, columns, comma format
    .{ .name = "-R recursive shape", .args = &.{ "-R", "rec" } },
    .{ .name = "-C columns (uniform names, width 80)", .args = &.{ "-C", "cdiru" } },
    .{ .name = "-x across rows", .args = &.{ "-x", "cdiru" } },
    .{ .name = "-m comma separated", .args = &.{ "-m", "cdiru" } },

    // Classification
    .{ .name = "-1F indicators", .args = &.{ "-1F", "kinds" } },
    .{ .name = "-lF classifies symlink target (not link name)", .args = &.{ "-lF", "kinds" } },
    .{ .name = "-p slash on dirs", .args = &.{ "-p", "kinds" } },
    .{ .name = "-lp long with slash", .args = &.{ "-lp", "kinds" } },

    // Blocks / id columns
    .{ .name = "-s allocated blocks", .args = &.{ "-s", "sizes" } },
    .{ .name = "-ls long with blocks", .args = &.{ "-ls", "sizes" } },
    .{ .name = "-n numeric ids", .args = &.{ "-n", "sizes" } },
    .{ .name = "-o no group", .args = &.{ "-o", "sizes" } },
    .{ .name = "-g no owner", .args = &.{ "-g", "sizes" } },
    .{ .name = "-og neither", .args = &.{ "-og", "sizes" } },

    // Grouping & extension sort
    .{ .name = "--group-directories-first", .args = &.{ "--group-directories-first", "kinds" } },
    .{ .name = "--group-directories-first with -r (dirs stay first)", .args = &.{ "--group-directories-first", "-r", "kinds" } },
    .{ .name = "-X extension sort", .args = &.{ "-X", "ext" } },
    .{ .name = "-Xr reverse extension sort", .args = &.{ "-Xr", "ext" } },
    .{ .name = "-U unsorted (directory order)", .args = &.{ "-U", "cdiru" } },
    .{ .name = "-f = -aU", .args = &.{ "-f", "cdiru" } },

    // Error paths: exit codes must match GNU (audit: was 1, GNU uses 2)
    .{ .name = "nonexistent operand exits 2", .args = &.{"/nonexistent-zls-parity-fixture"}, .expect_exit = 2, .compare_stderr = true },
    .{ .name = "unreadable dir exits 2", .args = &.{"noperm"}, .expect_exit = 2, .compare_stderr = true, .needs_nonroot = true },
    .{ .name = "unrecognized long option exits 2", .args = &.{"--definitely-bogus"}, .expect_exit = 2, .compare_stderr = true },
    .{ .name = "invalid short option exits 2", .args = &.{"-%"}, .expect_exit = 2, .compare_stderr = true },
    .{ .name = "invalid --color arg (GNU 9.10 exits 1)", .args = &.{"--color=bogus"}, .expect_exit = 1, .compare_stderr = true },
    .{ .name = "invalid --time-style arg exits 2", .args = &.{ "--time-style=bogus", "-l" }, .expect_exit = 2, .compare_stderr = true },
    .{ .name = "nonexistent + valid dir still lists (exit 2)", .args = &.{ "/nonexistent-zls-parity-fixture", "basic" }, .expect_exit = 2 },
};

test "GNU parity: stdout bytes and exit codes match the real GNU ls" {
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const gnu = findGnuLs(io) orelse return error.SkipZigTest;
    const zls = try absExe(arena, io);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFixtures(arena, io, tmp.dir);

    // chmod fixtures need absolute paths (libc chmod)
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &root_buf);
    const root = root_buf[0..root_len];
    const exec_path = try std.fmt.allocPrintSentinel(arena, "{s}/kinds/exec1", .{root}, 0);
    const noperm_path = try std.fmt.allocPrintSentinel(arena, "{s}/noperm", .{root}, 0);
    try std.testing.expectEqual(@as(c_int, 0), chmod(exec_path.ptr, 0o755));
    try std.testing.expectEqual(@as(c_int, 0), chmod(noperm_path.ptr, 0o000));
    defer _ = chmod(noperm_path.ptr, 0o755);

    const is_root = geteuid() == 0;

    var failures: usize = 0;
    for (parity_cases) |case| {
        if (case.needs_nonroot and is_root) continue;

        const z = try runTool(arena, io, zls, case, tmp.dir);
        const g = try runTool(arena, io, gnu, case, tmp.dir);

        if (!std.mem.eql(u8, z.stdout, g.stdout)) {
            std.debug.print("FAIL [{s}]: stdout differs\n--- zls ---\n{s}\n--- gnu ---\n{s}\n", .{
                case.name, z.stdout, g.stdout,
            });
            failures += 1;
            continue;
        }
        if (z.exit_code != g.exit_code) {
            std.debug.print("FAIL [{s}]: exit code zls={d} gnu={d}\n", .{ case.name, z.exit_code, g.exit_code });
            failures += 1;
            continue;
        }
        if (g.exit_code != case.expect_exit) {
            std.debug.print("FAIL [{s}]: test expectation stale — GNU itself exited {d}, expected {d}\n", .{
                case.name, g.exit_code, case.expect_exit,
            });
            failures += 1;
            continue;
        }
        if (case.compare_stderr) {
            const zn = try normalizeStderr(arena, z.stderr, zls, "zls");
            const gn = try normalizeStderr(arena, g.stderr, gnu, "ls");
            if (!std.mem.eql(u8, zn, gn)) {
                std.debug.print("FAIL [{s}]: stderr differs\n--- zls ---\n{s}\n--- gnu ---\n{s}\n", .{
                    case.name, zn, gn,
                });
                failures += 1;
            }
        }
    }
    try std.testing.expectEqual(@as(usize, 0), failures);
}

// The audit's highest-severity finding, asserted standalone so it fails
// loudly even if the parity harness is skipped: `-ltr` in a directory where
// files share an mtime second used to abort (invalid comparator violated
// strict weak ordering; std.sort.block asserts). Exit must be 0, and the
// listing must contain every entry.
test "regression: -ltr with tied mtimes must not crash" {
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const zls = try absExe(arena, io);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "d");
    for ([_][]const u8{ "d/a", "d/b", "d/c", "d/e" }) |p| {
        try tmp.dir.writeFile(io, .{ .sub_path = p, .data = "" });
        try setMtime(io, tmp.dir, p, t_old);
    }

    for ([_][]const []const u8{
        &.{ "-ltr", "d" },
        &.{ "-lSr", "d" },
        &.{ "-tr", "d" },
        &.{ "-Sr", "d" },
    }) |args| {
        const r = try runTool(arena, io, zls, .{ .name = "crash", .args = args }, tmp.dir);
        try std.testing.expectEqual(@as(u8, 0), r.exit_code);
        for ([_][]const u8{ "a", "b", "c", "e" }) |n| {
            try std.testing.expect(std.mem.indexOf(u8, r.stdout, n) != null);
        }
    }
}

// Literal-expected anchors, independent of an installed GNU binary. Bytes
// transcribed from documented GNU/POSIX behavior, NOT generated by zls.
test "literal anchors: documented GNU ls behavior" {
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const zls = try absExe(arena, io);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "q");
    try tmp.dir.writeFile(io, .{ .sub_path = "q/evil\x1bname", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "q/line\nname", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "q/normal", .data = "" });
    try tmp.dir.createDirPath(io, "s");
    const big = try arena.alloc(u8, 10444);
    @memset(big, 'x');
    try tmp.dir.writeFile(io, .{ .sub_path = "s/f10444", .data = big });

    // GNU ls manual, -q/--hide-control-chars: "print ? instead of
    // nongraphic characters". ESC (0x1b) and LF in names each become one '?'.
    {
        const r = try runTool(arena, io, zls, .{
            .name = "-1q literal",
            .args = &.{ "-1q", "q" },
        }, tmp.dir);
        try std.testing.expectEqual(@as(u8, 0), r.exit_code);
        try std.testing.expectEqualStrings("evil?name\nline?name\nnormal\n", r.stdout);
    }
    // Without -q and with stdout not a tty, GNU emits names verbatim
    // (--show-control-chars is the default when output is not a terminal).
    {
        const r = try runTool(arena, io, zls, .{
            .name = "-1 raw literal",
            .args = &.{ "-1", "q" },
        }, tmp.dir);
        try std.testing.expectEqual(@as(u8, 0), r.exit_code);
        try std.testing.expectEqualStrings("evil\x1bname\nline\nname\nnormal\n", r.stdout);
    }
    // GNU coreutils human.h: -h rounds UP to at most one decimal
    // (human_ceiling): 10444 bytes = 10.199..K prints "11K", never "10K".
    {
        const r = try runTool(arena, io, zls, .{
            .name = "-lh ceil literal",
            .args = &.{ "-lh", "s" },
        }, tmp.dir);
        try std.testing.expectEqual(@as(u8, 0), r.exit_code);
        try std.testing.expect(std.mem.indexOf(u8, r.stdout, "11K") != null);
        try std.testing.expect(std.mem.indexOf(u8, r.stdout, "10K") == null);
    }
    // POSIX ls: "If an operand names a nonexistent file... write a
    // diagnostic to standard error" — GNU exits 2 for command-line operands.
    {
        const r = try runTool(arena, io, zls, .{
            .name = "enoent literal",
            .args = &.{"/nonexistent-zls-parity-fixture"},
        }, tmp.dir);
        try std.testing.expectEqual(@as(u8, 2), r.exit_code);
        try std.testing.expectEqual(@as(usize, 0), r.stdout.len);
        try std.testing.expect(std.mem.indexOf(u8, r.stderr, "No such file or directory") != null);
    }
}
