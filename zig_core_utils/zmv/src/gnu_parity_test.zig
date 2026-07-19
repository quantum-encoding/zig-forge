//! Externally-anchored tests for zmv.
//!
//! Primary anchor: the real GNU coreutils `mv` binary (9.10, Homebrew
//! coreutils). Every parity test builds two identical fixture trees, runs
//! GNU mv in one and zmv in the other with the same argv/stdin, then
//! compares exit code, stdout, normalized stderr, and a recursive snapshot
//! of the resulting tree (names, kinds, modes, contents, symlink targets).
//! Nothing here is a roundtrip through zmv's own code.
//!
//! Secondary anchor (unit tests at the bottom): POSIX.1-2017 `mv` step 5 /
//! the GNU coreutils manual, which require that when a move degrades to
//! copy+unlink (EXDEV), symbolic links are duplicated as symbolic links and
//! FIFOs as FIFOs — never dereferenced/content-copied. Those tests call the
//! copy fallback directly (it works on a single filesystem too) and assert
//! literal expected results.

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const zmv = @import("main.zig");
const Io = std.Io;

extern "c" fn mkfifo(path: [*:0]const u8, mode: std.c.mode_t) c_int;

const gnu_candidates = [_][:0]const u8{
    "/opt/homebrew/opt/coreutils/libexec/gnubin/mv",
    "/opt/homebrew/bin/gmv",
    "/usr/local/opt/coreutils/libexec/gnubin/mv",
};

/// build_options.zmv_exe may be relative to the build root (the test
/// runner's cwd); children run with a different cwd, so absolutize it.
fn zmvExePath(gpa: std.mem.Allocator) ![]u8 {
    const rel = build_options.zmv_exe;
    const rel_z = try gpa.dupeZ(u8, rel);
    defer gpa.free(rel_z);
    var buf: [4096]u8 = undefined;
    const abs = std.c.realpath(rel_z.ptr, &buf) orelse return error.RealpathFailed;
    return gpa.dupe(u8, std.mem.span(abs));
}

fn findGnuMv() ?[:0]const u8 {
    for (gnu_candidates) |c| {
        if (std.c.access(c.ptr, 1) == 0) return c; // X_OK
    }
    return null;
}

const RunOut = struct {
    exit: u8,
    stdout: []u8,
    stderr: []u8,

    fn deinit(self: *RunOut, gpa: std.mem.Allocator) void {
        gpa.free(self.stdout);
        gpa.free(self.stderr);
    }
};

fn runMv(
    gpa: std.mem.Allocator,
    io: Io,
    exe: []const u8,
    argv_tail: []const []const u8,
    root: Io.Dir,
    sub: []const u8,
    use_stdin: bool,
) !RunOut {
    var argv_list: std.ArrayListUnmanaged([]const u8) = .empty;
    defer argv_list.deinit(gpa);
    try argv_list.append(gpa, exe);
    try argv_list.appendSlice(gpa, argv_tail);

    var work = try root.openDir(io, sub, .{});
    defer work.close(io);

    var stdin_file: ?Io.File = null;
    if (use_stdin) stdin_file = try root.openFile(io, "stdin.txt", .{});
    defer if (stdin_file) |f| f.close(io);

    var child = try std.process.spawn(io, .{
        .argv = argv_list.items,
        .cwd = .{ .dir = work },
        .stdin = if (stdin_file) |f| .{ .file = f } else .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    defer child.kill(io);

    var mr_buffer: Io.File.MultiReader.Buffer(2) = undefined;
    var mr: Io.File.MultiReader = undefined;
    mr.init(gpa, io, mr_buffer.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer mr.deinit();

    while (mr.fill(64, .none)) |_| {} else |err| switch (err) {
        error.EndOfStream => {},
        else => |e| return e,
    }
    try mr.checkAnyError();

    const term = try child.wait(io);

    const out = try mr.toOwnedSlice(0);
    errdefer gpa.free(out);
    const errs = try mr.toOwnedSlice(1);

    return .{
        .exit = switch (term) {
            .exited => |code| code,
            else => 255,
        },
        .stdout = out,
        .stderr = errs,
    };
}

/// GNU mv prints error prefixes as "mv: ", prompts and the Try-help line
/// with the full invocation path; zmv uses the literal "zmv" everywhere.
/// Both are folded to a neutral "@MV@" token before comparison.
fn normalizeGnuStderr(gpa: std.mem.Allocator, s: []const u8, gnu_path: []const u8) ![]u8 {
    const step1 = try std.mem.replaceOwned(u8, gpa, s, gnu_path, "@MV@");
    defer gpa.free(step1);
    return std.mem.replaceOwned(u8, gpa, step1, "mv: ", "@MV@: ");
}

fn normalizeZmvStderr(gpa: std.mem.Allocator, s: []const u8) ![]u8 {
    return std.mem.replaceOwned(u8, gpa, s, "zmv", "@MV@");
}

fn snapshotWalk(
    gpa: std.mem.Allocator,
    io: Io,
    dir: Io.Dir,
    prefix: []const u8,
    lines: *std.ArrayListUnmanaged([]u8),
) !void {
    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        const label = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ prefix, entry.name });
        defer gpa.free(label);

        const name_z = try gpa.dupeZ(u8, entry.name);
        defer gpa.free(name_z);

        var st: std.c.Stat = undefined;
        const have_stat = std.c.fstatat(dir.handle, name_z.ptr, &st, std.c.AT.SYMLINK_NOFOLLOW) == 0;
        const mode: u32 = if (have_stat) @as(u32, @intCast(st.mode)) & 0o777 else 0;

        switch (entry.kind) {
            .directory => {
                try lines.append(gpa, try std.fmt.allocPrint(gpa, "d {s} m{o:0>3}", .{ label, mode }));
                var sub = try dir.openDir(io, entry.name, .{ .iterate = true });
                defer sub.close(io);
                try snapshotWalk(gpa, io, sub, label, lines);
            },
            .sym_link => {
                var buf: [1024]u8 = undefined;
                const n = try dir.readLink(io, entry.name, &buf);
                try lines.append(gpa, try std.fmt.allocPrint(gpa, "l {s} -> {s}", .{ label, buf[0..n] }));
            },
            .file => {
                const content = try dir.readFileAlloc(io, entry.name, gpa, .unlimited);
                defer gpa.free(content);
                try lines.append(gpa, try std.fmt.allocPrint(gpa, "f {s} m{o:0>3} {s}", .{ label, mode, content }));
            },
            else => {
                try lines.append(gpa, try std.fmt.allocPrint(gpa, "o {s} kind={s}", .{ label, @tagName(entry.kind) }));
            },
        }
    }
}

fn snapshotTree(gpa: std.mem.Allocator, io: Io, root: Io.Dir, sub: []const u8) ![]u8 {
    var dir = try root.openDir(io, sub, .{ .iterate = true });
    defer dir.close(io);

    var lines: std.ArrayListUnmanaged([]u8) = .empty;
    defer {
        for (lines.items) |l| gpa.free(l);
        lines.deinit(gpa);
    }
    try snapshotWalk(gpa, io, dir, "", &lines);

    std.mem.sort([]u8, lines.items, {}, struct {
        fn lessThan(_: void, a: []u8, b: []u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(gpa);
    for (lines.items) |l| {
        try out.appendSlice(gpa, l);
        try out.append(gpa, '\n');
    }
    return out.toOwnedSlice(gpa);
}

const Setup = *const fn (dir: Io.Dir, io: Io) anyerror!void;

/// Run the same invocation under GNU mv and zmv on identical fixture trees
/// and require identical exit code, stdout, normalized stderr, and
/// resulting directory tree.
fn runCase(setup: Setup, argv_tail: []const []const u8, stdin_bytes: ?[]const u8) !void {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const gnu = findGnuMv() orelse return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var gdir = try tmp.dir.createDirPathOpen(io, "g", .{ .open_options = .{ .iterate = true } });
    defer gdir.close(io);
    var zdir = try tmp.dir.createDirPathOpen(io, "z", .{ .open_options = .{ .iterate = true } });
    defer zdir.close(io);

    try setup(gdir, io);
    try setup(zdir, io);

    if (stdin_bytes) |sb| {
        try tmp.dir.writeFile(io, .{ .sub_path = "stdin.txt", .data = sb });
    }

    const zmv_exe = try zmvExePath(gpa);
    defer gpa.free(zmv_exe);

    var g_res = try runMv(gpa, io, gnu, argv_tail, tmp.dir, "g", stdin_bytes != null);
    defer g_res.deinit(gpa);
    var z_res = try runMv(gpa, io, zmv_exe, argv_tail, tmp.dir, "z", stdin_bytes != null);
    defer z_res.deinit(gpa);

    // Exit codes
    try std.testing.expectEqual(g_res.exit, z_res.exit);

    // stdout must match byte-for-byte (e.g. -v output)
    try std.testing.expectEqualStrings(g_res.stdout, z_res.stdout);

    // stderr must match after folding the program identity
    const g_err = try normalizeGnuStderr(gpa, g_res.stderr, gnu);
    defer gpa.free(g_err);
    const z_err = try normalizeZmvStderr(gpa, z_res.stderr);
    defer gpa.free(z_err);
    try std.testing.expectEqualStrings(g_err, z_err);

    // Resulting trees must be identical
    const g_tree = try snapshotTree(gpa, io, tmp.dir, "g");
    defer gpa.free(g_tree);
    const z_tree = try snapshotTree(gpa, io, tmp.dir, "z");
    defer gpa.free(z_tree);
    try std.testing.expectEqualStrings(g_tree, z_tree);
}

// ---------------------------------------------------------------------------
// Fixture setups
// ---------------------------------------------------------------------------

fn setupNothing(dir: Io.Dir, io: Io) !void {
    _ = dir;
    _ = io;
}

fn setupOneFile(dir: Io.Dir, io: Io) !void {
    try dir.writeFile(io, .{ .sub_path = "a", .data = "alpha\n" });
}

fn setupFileAndDir(dir: Io.Dir, io: Io) !void {
    try dir.writeFile(io, .{ .sub_path = "a", .data = "alpha\n" });
    try dir.createDirPath(io, "d");
}

fn setupSymlinkDirDest(dir: Io.Dir, io: Io) !void {
    try dir.createDirPath(io, "real");
    try dir.symLink(io, "real", "cur", .{ .is_directory = true });
    try dir.writeFile(io, .{ .sub_path = "report", .data = "r\n" });
}

fn setupDanglingSymlink(dir: Io.Dir, io: Io) !void {
    try dir.symLink(io, "/nonexistent-target", "broken", .{});
    try dir.createDirPath(io, "dir");
}

fn setupSameFile(dir: Io.Dir, io: Io) !void {
    try dir.writeFile(io, .{ .sub_path = "s", .data = "self\n" });
}

fn setupHardlinks(dir: Io.Dir, io: Io) !void {
    try dir.writeFile(io, .{ .sub_path = "h1", .data = "h\n" });
    try Io.Dir.hardLink(dir, "h1", dir, "h2", io, .{});
}

fn setupTwoFiles(dir: Io.Dir, io: Io) !void {
    try dir.writeFile(io, .{ .sub_path = "one", .data = "one\n" });
    try dir.writeFile(io, .{ .sub_path = "two", .data = "two\n" });
}

fn setupUnwritableDest(dir: Io.Dir, io: Io) !void {
    try dir.writeFile(io, .{ .sub_path = "one", .data = "one\n" });
    try dir.writeFile(io, .{ .sub_path = "two", .data = "two\n" });
    const f = try dir.openFile(io, "two", .{});
    defer f.close(io);
    if (std.c.fchmod(f.handle, 0o444) != 0) return error.ChmodFailed;
}

fn setupOneDir(dir: Io.Dir, io: Io) !void {
    try dir.createDirPath(io, "ta");
}

fn setupTwoDirsOneNonEmpty(dir: Io.Dir, io: Io) !void {
    try dir.createDirPath(io, "tb");
    try dir.createDirPath(io, "tc");
    try dir.writeFile(io, .{ .sub_path = "tc/f", .data = "x\n" });
}

fn setupTwoEmptyDirs(dir: Io.Dir, io: Io) !void {
    try dir.createDirPath(io, "ea");
    try dir.createDirPath(io, "eb");
}

fn setupFileAndTargetDir(dir: Io.Dir, io: Io) !void {
    try dir.writeFile(io, .{ .sub_path = "tf", .data = "tf\n" });
    try dir.createDirPath(io, "td");
}

fn setupThreeFiles(dir: Io.Dir, io: Io) !void {
    try dir.writeFile(io, .{ .sub_path = "a1", .data = "a1\n" });
    try dir.writeFile(io, .{ .sub_path = "b1", .data = "b1\n" });
    try dir.writeFile(io, .{ .sub_path = "c1", .data = "c1\n" });
}

fn setupDirOverFile(dir: Io.Dir, io: Io) !void {
    try dir.createDirPath(io, "d2");
    try dir.writeFile(io, .{ .sub_path = "f3", .data = "f3\n" });
}

fn setupFileOverDirViaBasename(dir: Io.Dir, io: Io) !void {
    try dir.createDirPath(io, "dd3/ff3");
    try dir.writeFile(io, .{ .sub_path = "ff3", .data = "ff3\n" });
}

fn setupUpdateDestNewer(dir: Io.Dir, io: Io) !void {
    try dir.writeFile(io, .{ .sub_path = "u1", .data = "old-src\n" });
    const s1 = try dir.statFile(io, "u1", .{});
    // Ensure the destination is strictly newer than the source so -u must
    // skip; APFS has ns timestamps, so this loop exits on the first pass in
    // practice.
    var attempts: usize = 0;
    while (attempts < 100_000) : (attempts += 1) {
        try dir.writeFile(io, .{ .sub_path = "u2", .data = "new-dest\n" });
        const s2 = try dir.statFile(io, "u2", .{});
        if (s2.mtime.nanoseconds > s1.mtime.nanoseconds) return;
    }
    return error.CouldNotMakeNewerDest;
}

fn setupSymlinkSource(dir: Io.Dir, io: Io) !void {
    try dir.createDirPath(io, "realsrc");
    try dir.symLink(io, "realsrc", "lsrc", .{ .is_directory = true });
}

fn setupFileWithLinkToIt(dir: Io.Dir, io: Io) !void {
    try dir.writeFile(io, .{ .sub_path = "sf", .data = "sf\n" });
    try dir.symLink(io, "sf", "sfl", .{});
}

fn setupTrailingSlash(dir: Io.Dir, io: Io) !void {
    try dir.createDirPath(io, "ts");
    try dir.writeFile(io, .{ .sub_path = "ts/inner", .data = "inner\n" });
    try dir.createDirPath(io, "dird");
}

fn setupMultiIntoDir(dir: Io.Dir, io: Io) !void {
    try dir.writeFile(io, .{ .sub_path = "x1", .data = "x1\n" });
    try dir.writeFile(io, .{ .sub_path = "x2", .data = "x2\n" });
    try dir.createDirPath(io, "dd");
}

fn setupPromptThenConflict(dir: Io.Dir, io: Io) !void {
    try dir.createDirPath(io, "pd");
    try dir.writeFile(io, .{ .sub_path = "pf", .data = "pf\n" });
}

fn setupDirTree(dir: Io.Dir, io: Io) !void {
    try dir.createDirPath(io, "tree/sub");
    try dir.writeFile(io, .{ .sub_path = "tree/f1", .data = "f1\n" });
    try dir.writeFile(io, .{ .sub_path = "tree/sub/f2", .data = "f2\n" });
    try dir.symLink(io, "f1", "tree/rel", .{});
}

// ---------------------------------------------------------------------------
// GNU parity tests (anchored to the real GNU mv binary)
// ---------------------------------------------------------------------------

test "gnu parity: plain rename" {
    try runCase(setupOneFile, &.{ "a", "b" }, null);
}

test "gnu parity: move file into directory" {
    try runCase(setupFileAndDir, &.{ "a", "d" }, null);
}

test "gnu parity: move directory tree into directory" {
    try runCase(setupDirTree, &.{ "tree", "newtree" }, null);
}

test "gnu parity: destination symlink to directory receives file inside (symlink preserved)" {
    try runCase(setupSymlinkDirDest, &.{ "report", "cur" }, null);
}

test "gnu parity: dangling symlink source is moved" {
    try runCase(setupDanglingSymlink, &.{ "broken", "dir" }, null);
}

test "gnu parity: symlink source stays a symlink after move" {
    try runCase(setupSymlinkSource, &.{ "lsrc", "moved" }, null);
}

test "gnu parity: mv s s is 'same file', exit 1" {
    try runCase(setupSameFile, &.{ "s", "s" }, null);
}

test "gnu parity: hardlinks are the same file, exit 1" {
    try runCase(setupHardlinks, &.{ "h1", "h2" }, null);
}

test "gnu parity: -f does not bypass the same-file check" {
    try runCase(setupSameFile, &.{ "-f", "s", "s" }, null);
}

test "gnu parity: moving file onto a symlink pointing at it replaces the link" {
    try runCase(setupFileWithLinkToIt, &.{ "sf", "sfl" }, null);
}

test "gnu parity: moving symlink onto its referent is 'same file'" {
    try runCase(setupFileWithLinkToIt, &.{ "sfl", "sf" }, null);
}

test "gnu parity: -n skips existing destination silently, exit 0" {
    try runCase(setupTwoFiles, &.{ "-n", "one", "two" }, null);
}

test "gnu parity: -n on same file exits 0 (skip happens before same-file check)" {
    try runCase(setupSameFile, &.{ "-n", "s", "s" }, null);
}

test "gnu parity: -i declined leaves files and exits 1" {
    try runCase(setupTwoFiles, &.{ "-i", "one", "two" }, "n\n");
}

test "gnu parity: -i accepted overwrites, exit 0" {
    try runCase(setupTwoFiles, &.{ "-i", "one", "two" }, "y\n");
}

test "gnu parity: -i with EOF on stdin declines, exit 1" {
    try runCase(setupTwoFiles, &.{ "-i", "one", "two" }, "");
}

test "gnu parity: -f -i prompts (last flag wins)" {
    try runCase(setupTwoFiles, &.{ "-f", "-i", "one", "two" }, "n\n");
}

test "gnu parity: -i -f does not prompt (last flag wins)" {
    try runCase(setupTwoFiles, &.{ "-i", "-f", "one", "two" }, null);
}

test "gnu parity: -n -i prompts and overwrites on y (last flag wins)" {
    try runCase(setupTwoFiles, &.{ "-n", "-i", "one", "two" }, "y\n");
}

test "gnu parity: unwritable destination with non-tty stdin is overwritten, exit 0" {
    try runCase(setupUnwritableDest, &.{ "one", "two" }, null);
}

test "gnu parity: -i prompt comes before the dir-over-file conflict error" {
    try runCase(setupPromptThenConflict, &.{ "-i", "pd", "pf" }, "y\n");
}

test "gnu parity: moving a directory into itself" {
    try runCase(setupOneDir, &.{ "ta", "ta/sub" }, null);
}

test "gnu parity: -T dir over non-empty dir fails with 'Directory not empty'" {
    try runCase(setupTwoDirsOneNonEmpty, &.{ "-T", "tb", "tc" }, null);
}

test "gnu parity: -T dir over empty dir succeeds" {
    try runCase(setupTwoEmptyDirs, &.{ "-T", "ea", "eb" }, null);
}

test "gnu parity: combining -t and -T is rejected" {
    try runCase(setupFileAndTargetDir, &.{ "-T", "-t", "td", "tf" }, null);
}

test "gnu parity: extra operand with -T" {
    try runCase(setupThreeFiles, &.{ "-T", "a1", "b1", "c1" }, null);
}

test "gnu parity: multi-source with missing target" {
    try runCase(setupTwoFiles, &.{ "one", "two", "nosuchdir" }, null);
}

test "gnu parity: multi-source with non-directory target" {
    try runCase(setupThreeFiles, &.{ "a1", "b1", "c1" }, null);
}

test "gnu parity: -t with non-directory target" {
    try runCase(setupTwoFiles, &.{ "-t", "two", "one" }, null);
}

test "gnu parity: -t with missing target" {
    try runCase(setupOneFile, &.{ "-t", "nosuchdir", "a" }, null);
}

test "gnu parity: -t moves multiple sources into directory" {
    try runCase(setupMultiIntoDir, &.{ "-t", "dd", "x1", "x2" }, null);
}

test "gnu parity: multiple sources into directory" {
    try runCase(setupMultiIntoDir, &.{ "x1", "x2", "dd" }, null);
}

test "gnu parity: directory over existing file" {
    try runCase(setupDirOverFile, &.{ "d2", "f3" }, null);
}

test "gnu parity: file over existing directory (basename routing)" {
    try runCase(setupFileOverDirViaBasename, &.{ "ff3", "dd3" }, null);
}

test "gnu parity: -u skips when destination is newer" {
    try runCase(setupUpdateDestNewer, &.{ "-u", "u1", "u2" }, null);
}

test "gnu parity: -u moves onto missing destination" {
    try runCase(setupOneFile, &.{ "-u", "a", "b" }, null);
}

test "gnu parity: -v prints renamed line" {
    try runCase(setupOneFile, &.{ "-v", "a", "b" }, null);
}

test "gnu parity: -v move into directory" {
    try runCase(setupFileAndDir, &.{ "-v", "a", "d" }, null);
}

test "gnu parity: missing source" {
    try runCase(setupNothing, &.{ "nosuch", "dest" }, null);
}

test "gnu parity: missing file operand" {
    try runCase(setupNothing, &.{}, null);
}

test "gnu parity: missing destination operand" {
    try runCase(setupNothing, &.{"onearg"}, null);
}

test "gnu parity: invalid short option" {
    try runCase(setupOneFile, &.{ "-Q", "a", "b" }, null);
}

test "gnu parity: unrecognized long option" {
    try runCase(setupOneFile, &.{ "--bogus", "a", "b" }, null);
}

test "gnu parity: trailing slash on source directory" {
    try runCase(setupTrailingSlash, &.{ "ts/", "dird" }, null);
}

// ---------------------------------------------------------------------------
// Copy-fallback unit tests (spec-anchored).
//
// The EXDEV fallback cannot be integration-tested here (no second
// filesystem), but copyAndDelete works on one filesystem too. Expected
// behavior is anchored to POSIX.1-2017 `mv` (step 5: duplicate the source
// hierarchy as if by `cp -r` "preserving file characteristics"; a symbolic
// link is duplicated as a symbolic link, a FIFO as a FIFO) and to the GNU
// coreutils manual (`mv` falls back to `cp -a`-style copy then delete).
// ---------------------------------------------------------------------------

fn tmpRelPath(gpa: std.mem.Allocator, tmp: *std.testing.TmpDir, comptime rest: []const u8) ![:0]u8 {
    // std.testing.tmpDir always creates .zig-cache/tmp/<sub> relative to the
    // process cwd, so cwd-relative paths reach into it.
    return std.fmt.allocPrintSentinel(gpa, ".zig-cache/tmp/{s}/" ++ rest, .{&tmp.sub_path}, 0);
}

test "copy fallback: symlink is recreated, not dereferenced (POSIX mv step 5)" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "src");
    try tmp.dir.writeFile(io, .{ .sub_path = "src/data", .data = "payload\n" });
    // Relative symlink inside the tree, and a dangling one: both must be
    // duplicated as links with identical targets.
    try tmp.dir.symLink(io, "data", "src/rel", .{});
    try tmp.dir.symLink(io, "/no/such/target", "src/dangling", .{});

    const src = try tmpRelPath(gpa, &tmp, "src");
    defer gpa.free(src);
    const dst = try tmpRelPath(gpa, &tmp, "dst");
    defer gpa.free(dst);

    const config = zmv.Config{};
    try zmv.copyAndDelete(gpa, src, dst, src, dst, &config);

    // Source fully removed
    try std.testing.expect(zmv.getFileType(src) == null);

    // Destination: regular file with identical contents...
    const content = try tmp.dir.readFileAlloc(io, "dst/data", gpa, .unlimited);
    defer gpa.free(content);
    try std.testing.expectEqualStrings("payload\n", content);

    // ...and both symlinks recreated with byte-identical targets.
    var buf: [256]u8 = undefined;
    var n = try tmp.dir.readLink(io, "dst/rel", &buf);
    try std.testing.expectEqualStrings("data", buf[0..n]);
    n = try tmp.dir.readLink(io, "dst/dangling", &buf);
    try std.testing.expectEqualStrings("/no/such/target", buf[0..n]);
}

test "copy fallback: FIFO is recreated as a FIFO, never opened for reading" {
    // Opening a FIFO with no writer blocks forever; the fallback must
    // mkfifo() a new one instead (POSIX mv step 5 / cp -r FIFO duplication).
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    _ = io;

    const src = try tmpRelPath(gpa, &tmp, "pipe");
    defer gpa.free(src);
    const dst = try tmpRelPath(gpa, &tmp, "pipe-moved");
    defer gpa.free(dst);

    if (mkfifo(src.ptr, 0o644) != 0) return error.MkFifoFailed;

    const config = zmv.Config{};
    try zmv.copyAndDelete(gpa, src, dst, src, dst, &config);

    try std.testing.expect(zmv.getFileType(src) == null);
    try std.testing.expect(zmv.getFileType(dst) == .fifo);
}

test "basename ignores trailing slashes (GNU strip semantics for dest routing)" {
    try std.testing.expectEqualStrings("ts", zmv.basename("ts/"));
    try std.testing.expectEqualStrings("ts", zmv.basename("a/ts//"));
    try std.testing.expectEqualStrings("b", zmv.basename("a/b"));
    try std.testing.expectEqualStrings("b", zmv.basename("b"));
    try std.testing.expectEqualStrings("/", zmv.basename("/"));
}
