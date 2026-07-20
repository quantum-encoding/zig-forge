//! Externally-anchored parity tests for ztree.
//!
//! The external anchor is the real GNU `tree` binary (tree 2.2.1, path injected
//! via build_options.gnu_tree, default /opt/homebrew/bin/tree). Each parity test
//! builds a fixture directory tree, runs BOTH the real `tree` and our freshly
//! built `ztree` against it with identical arguments, and asserts byte-for-byte
//! equal stdout. This is a true external anchor: the expected output is produced
//! by a third-party implementation this repo did not write (see zig-forge
//! CLAUDE.md "golden rule" §1). None of these are roundtrip tests.
//!
//! Cosmetic normalization: GNU tree 2.x pads its indentation with U+00A0
//! (non-breaking space, bytes C2 A0); ztree deliberately uses ASCII spaces
//! (friendlier to grep/awk on downstream output). `normalizeNbsp` collapses the
//! two-byte NBSP in GNU's output to one ASCII space before comparison. This is
//! the ONLY documented divergence and it is purely visual.
//!
//! A second group of tests ("documented-behavior") hard-codes the exact bytes
//! GNU tree 2.2.1 emits for known inputs, so the suite still has an external
//! anchor (the observed GNU output, cited in comments) even on a machine where
//! the GNU binary is absent.

const std = @import("std");
const Io = std.Io;
const Dir = Io.Dir;
const build_options = @import("build_options");

// A real (multi-threaded) Io: std.process.run needs to read the child's stdout
// and stderr pipes concurrently, which the single-threaded instance cannot do.
var threaded_storage: Io.Threaded = undefined;
var threaded_ready = false;

fn io() Io {
    if (!threaded_ready) {
        threaded_storage = Io.Threaded.init(std.heap.page_allocator, .{});
        threaded_ready = true;
    }
    return threaded_storage.io();
}

/// Collapse GNU tree's U+00A0 (C2 A0) indentation padding to a single ASCII
/// space so it can be compared against ztree's ASCII-space output.
fn normalizeNbsp(a: std.mem.Allocator, input: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(a);
    var i: usize = 0;
    while (i < input.len) {
        if (i + 1 < input.len and input[i] == 0xC2 and input[i + 1] == 0xA0) {
            try out.append(a, ' ');
            i += 2;
        } else {
            try out.append(a, input[i]);
            i += 1;
        }
    }
    return out.toOwnedSlice(a);
}

const CaptureResult = struct {
    stdout: []u8,
    stderr: []u8,
    exit_code: u8,
};

/// Run `exe` (plus `tail` args) with cwd set to `base_abs`, capturing stdout,
/// stderr and the numeric exit code.
fn capture(
    a: std.mem.Allocator,
    exe: []const u8,
    tail: []const []const u8,
    base_abs: []const u8,
) !CaptureResult {
    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    defer argv.deinit(a);
    try argv.append(a, exe);
    for (tail) |t| try argv.append(a, t);

    // GNU tree picks its line-drawing charset from the locale: with no/blank
    // locale it falls back to ASCII ("|--"), with a UTF-8 locale it uses the
    // Unicode box characters ztree always emits. Pin a UTF-8 locale so both
    // sides use the same glyphs.
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("LC_ALL", "en_US.UTF-8");
    try env.put("LANG", "en_US.UTF-8");

    const res = try std.process.run(a, io(), .{
        .argv = argv.items,
        .cwd = .{ .path = base_abs },
        .environ_map = &env,
    });
    const code: u8 = switch (res.term) {
        .exited => |c| c,
        else => 255,
    };
    return .{ .stdout = res.stdout, .stderr = res.stderr, .exit_code = code };
}

/// Fast recursive teardown of an isolated, self-created test fixture. std's
/// deleteTree is superlinear in depth (tens of seconds for a few hundred
/// levels), so the deep-nesting test tears down via the system `rm -rf` (fts-
/// based, fd-relative). `name` is always a fixed literal relative to the test's
/// cwd (the project root), never user or empty input.
fn rmrf(name: []const u8) void {
    const res = std.process.run(std.heap.page_allocator, io(), .{
        .argv = &.{ "/bin/rm", "-rf", name },
    }) catch return;
    std.heap.page_allocator.free(res.stdout);
    std.heap.page_allocator.free(res.stderr);
}

fn gnuAvailable() bool {
    Dir.cwd().access(io(), build_options.gnu_tree, .{}) catch return false;
    return true;
}

/// Build a canonical fixture directory rooted at a fresh `name` under cwd and
/// return its absolute path (caller owns the returned slice; caller should
/// deleteTree(name) when done).
fn makeBase(a: std.mem.Allocator, name: []const u8) ![:0]u8 {
    const cwd = Dir.cwd();
    cwd.deleteTree(io(), name) catch {};
    try cwd.createDirPath(io(), name);

    var base = try cwd.openDir(io(), name, .{});
    defer base.close(io());

    // Plain tree "nt" (no symlinks) — used for structural / depth / count tests.
    try base.createDirPath(io(), "nt/a/b/c");
    try base.createDirPath(io(), "nt/d");
    try base.writeFile(io(), .{ .sub_path = "nt/top.txt", .data = "3\n" });
    try base.writeFile(io(), .{ .sub_path = "nt/a/f.txt", .data = "1\n" });
    try base.writeFile(io(), .{ .sub_path = "nt/a/b/g.txt", .data = "2\n" });

    // Symlink tree "sl": a file symlink and a directory symlink.
    try base.createDirPath(io(), "sl/a");
    try base.writeFile(io(), .{ .sub_path = "sl/a/f1.txt", .data = "x\n" });
    try base.writeFile(io(), .{ .sub_path = "sl/f0.txt", .data = "y\n" });
    try base.symLink(io(), "f0.txt", "sl/link", .{});
    try base.symLink(io(), "a", "sl/dlink", .{ .is_directory = true });

    // Hidden-file tree "hid".
    try base.createDirPath(io(), "hid");
    try base.writeFile(io(), .{ .sub_path = "hid/visible.txt", .data = "v\n" });
    try base.writeFile(io(), .{ .sub_path = "hid/.hidden", .data = "h\n" });

    return cwd.realPathFileAlloc(io(), name, a);
}

/// Core anchor: run GNU tree and ztree with the same args, assert equal stdout
/// (after NBSP normalization of the GNU side). Skips if the GNU binary is
/// missing.
fn expectParity(a: std.mem.Allocator, base_abs: []const u8, tail: []const []const u8) !void {
    if (!gnuAvailable()) return error.SkipZigTest;

    const gnu = try capture(a, build_options.gnu_tree, tail, base_abs);
    defer a.free(gnu.stdout);
    defer a.free(gnu.stderr);
    const zt = try capture(a, build_options.ztree_exe, tail, base_abs);
    defer a.free(zt.stdout);
    defer a.free(zt.stderr);

    const gnu_norm = try normalizeNbsp(a, gnu.stdout);
    defer a.free(gnu_norm);

    if (!std.mem.eql(u8, gnu_norm, zt.stdout)) {
        std.debug.print(
            "\n--- args: {any} ---\n=== GNU (normalized) ===\n{s}\n=== ztree ===\n{s}\n",
            .{ tail, gnu_norm, zt.stdout },
        );
        return error.OutputMismatch;
    }
}

// ===========================================================================
// Parity tests (anchored to the real GNU tree binary)
// ===========================================================================

test "parity: default tree layout, no-color" {
    const a = std.testing.allocator;
    const base = try makeBase(a, "ztst_default");
    defer a.free(base);
    defer Dir.cwd().deleteTree(io(), "ztst_default") catch {};
    // Anchors: connector glyphs, NO trailing slash on dirs, root counted in
    // the "N directories" summary, correct pluralization.
    try expectParity(a, base, &.{ "-n", "nt" });
}

test "parity: -L 1 depth limit (off-by-one regression)" {
    const a = std.testing.allocator;
    const base = try makeBase(a, "ztst_L1");
    defer a.free(base);
    defer Dir.cwd().deleteTree(io(), "ztst_L1") catch {};
    // GNU -L 1 shows exactly one level; ztree previously showed two.
    try expectParity(a, base, &.{ "-n", "-L", "1", "nt" });
}

test "parity: -L 2 depth limit" {
    const a = std.testing.allocator;
    const base = try makeBase(a, "ztst_L2");
    defer a.free(base);
    defer Dir.cwd().deleteTree(io(), "ztst_L2") catch {};
    try expectParity(a, base, &.{ "-n", "-L", "2", "nt" });
}

test "parity: -d directories only (summary omits file count)" {
    const a = std.testing.allocator;
    const base = try makeBase(a, "ztst_d");
    defer a.free(base);
    defer Dir.cwd().deleteTree(io(), "ztst_d") catch {};
    try expectParity(a, base, &.{ "-n", "-d", "nt" });
}

test "parity: --dirsfirst ordering" {
    const a = std.testing.allocator;
    const base = try makeBase(a, "ztst_df");
    defer a.free(base);
    defer Dir.cwd().deleteTree(io(), "ztst_df") catch {};
    try expectParity(a, base, &.{ "-n", "--dirsfirst", "nt" });
}

test "parity: -r reverse ordering" {
    const a = std.testing.allocator;
    const base = try makeBase(a, "ztst_r");
    defer a.free(base);
    defer Dir.cwd().deleteTree(io(), "ztst_r") catch {};
    try expectParity(a, base, &.{ "-n", "-r", "nt" });
}

test "parity: -a hidden files" {
    const a = std.testing.allocator;
    const base = try makeBase(a, "ztst_a");
    defer a.free(base);
    defer Dir.cwd().deleteTree(io(), "ztst_a") catch {};
    try expectParity(a, base, &.{ "-n", "-a", "hid" });
}

test "parity: symlink targets and symlink-to-dir counting" {
    const a = std.testing.allocator;
    const base = try makeBase(a, "ztst_sl");
    defer a.free(base);
    defer Dir.cwd().deleteTree(io(), "ztst_sl") catch {};
    // Anchors: "link -> f0.txt" real targets (not "-> ..."), and the summary
    // counts dlink (symlink to a directory) as a directory like GNU does.
    try expectParity(a, base, &.{ "-n", "sl" });
}

test "parity: multiple root arguments (no blank separator)" {
    const a = std.testing.allocator;
    const base = try makeBase(a, "ztst_multi");
    defer a.free(base);
    defer Dir.cwd().deleteTree(io(), "ztst_multi") catch {};
    try expectParity(a, base, &.{ "-n", "nt", "hid" });
}

test "parity: -P pattern match" {
    const a = std.testing.allocator;
    const base = try makeBase(a, "ztst_p");
    defer a.free(base);
    defer Dir.cwd().deleteTree(io(), "ztst_p") catch {};
    try expectParity(a, base, &.{ "-n", "-P", "*.txt", "nt" });
}

test "parity: nonexistent directory prints inline error and exits 2" {
    const a = std.testing.allocator;
    const base = try makeBase(a, "ztst_missing");
    defer a.free(base);
    defer Dir.cwd().deleteTree(io(), "ztst_missing") catch {};

    const zt = try capture(a, build_options.ztree_exe, &.{ "-n", "does_not_exist" }, base);
    defer a.free(zt.stdout);
    defer a.free(zt.stderr);

    // GNU tree behavior (observed, tree 2.2.1): exit code 2, and the missing
    // path line is annotated inline with "[error opening dir]".
    try std.testing.expectEqual(@as(u8, 2), zt.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, zt.stdout, "[error opening dir]") != null);

    if (gnuAvailable()) {
        const gnu = try capture(a, build_options.gnu_tree, &.{ "-n", "does_not_exist" }, base);
        defer a.free(gnu.stdout);
        defer a.free(gnu.stderr);
        const gnu_norm = try normalizeNbsp(a, gnu.stdout);
        defer a.free(gnu_norm);
        try std.testing.expectEqual(@as(u8, 2), gnu.exit_code);
        try std.testing.expectEqualStrings(gnu_norm, zt.stdout);
    }
}

test "parity: unreadable subdirectory annotated and exits 2" {
    const a = std.testing.allocator;
    const base = try makeBase(a, "ztst_perm");
    defer a.free(base);
    defer Dir.cwd().deleteTree(io(), "ztst_perm") catch {};

    // Make one subdirectory unreadable (chmod 000). If we can't (e.g. running
    // as root where perms are ignored), skip.
    var b = try Dir.cwd().openDir(io(), "ztst_perm", .{});
    defer b.close(io());
    try b.createDirPath(io(), "perm/readable");
    try b.createDirPath(io(), "perm/noread");
    try b.writeFile(io(), .{ .sub_path = "perm/readable/f.txt", .data = "x\n" });
    // chmod via libc since Io.Dir has no direct mode setter here.
    var pathbuf: [4096]u8 = undefined;
    const noread_abs = std.fmt.bufPrintZ(&pathbuf, "{s}/perm/noread", .{base}) catch return error.SkipZigTest;
    if (std.c.chmod(noread_abs, 0) != 0) return error.SkipZigTest;
    defer _ = std.c.chmod(noread_abs, 0o755);

    // If we can still read it (root), the anchor doesn't apply.
    {
        const probe = Dir.cwd().openDir(io(), "ztst_perm/perm/noread", .{ .iterate = true });
        if (probe) |d| {
            var dd = d;
            dd.close(io());
            return error.SkipZigTest;
        } else |_| {}
    }

    const zt = try capture(a, build_options.ztree_exe, &.{ "-n", "perm" }, base);
    defer a.free(zt.stdout);
    defer a.free(zt.stderr);
    try std.testing.expectEqual(@as(u8, 2), zt.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, zt.stdout, "[error opening dir]") != null);

    if (gnuAvailable()) {
        const gnu = try capture(a, build_options.gnu_tree, &.{ "-n", "perm" }, base);
        defer a.free(gnu.stdout);
        defer a.free(gnu.stderr);
        const gnu_norm = try normalizeNbsp(a, gnu.stdout);
        defer a.free(gnu_norm);
        try std.testing.expectEqualStrings(gnu_norm, zt.stdout);
        try std.testing.expectEqual(@as(u8, 2), gnu.exit_code);
    }
}

test "parity: -L 0 is rejected with exit 1" {
    const a = std.testing.allocator;
    const base = try makeBase(a, "ztst_L0");
    defer a.free(base);
    defer Dir.cwd().deleteTree(io(), "ztst_L0") catch {};

    const zt = try capture(a, build_options.ztree_exe, &.{ "-n", "-L", "0", "nt" }, base);
    defer a.free(zt.stdout);
    defer a.free(zt.stderr);
    // GNU tree: "Invalid level, must be greater than 0." and exit 1.
    try std.testing.expectEqual(@as(u8, 1), zt.exit_code);

    if (gnuAvailable()) {
        const gnu = try capture(a, build_options.gnu_tree, &.{ "-n", "-L", "0", "nt" }, base);
        defer a.free(gnu.stdout);
        defer a.free(gnu.stderr);
        try std.testing.expectEqual(@as(u8, 1), gnu.exit_code);
    }
}

test "regression: -f files-only descends into subdirectories" {
    const a = std.testing.allocator;
    const base = try makeBase(a, "ztst_f");
    defer a.free(base);
    defer Dir.cwd().deleteTree(io(), "ztst_f") catch {};

    // ztree's -f (files only) previously listed only top-level files and never
    // descended. It must now reach files nested in subdirectories. (No GNU
    // anchor: GNU's -f means "full path", so this is checked against ztree's
    // own documented intent, not by diff.)
    const zt = try capture(a, build_options.ztree_exe, &.{ "-n", "-f", "nt" }, base);
    defer a.free(zt.stdout);
    defer a.free(zt.stderr);
    try std.testing.expect(std.mem.indexOf(u8, zt.stdout, "g.txt") != null); // nt/a/b/g.txt
    try std.testing.expect(std.mem.indexOf(u8, zt.stdout, "f.txt") != null); // nt/a/f.txt
    try std.testing.expect(std.mem.indexOf(u8, zt.stdout, "top.txt") != null);
}

test "regression: deep nested tree traverses cleanly (no crash)" {
    const a = std.testing.allocator;
    const name = "ztst_deep";
    rmrf(name);
    defer rmrf(name);
    try Dir.cwd().createDirPath(io(), name);
    var b = try Dir.cwd().openDir(io(), name, .{});
    defer b.close(io());

    // Build 900 nested directories one level at a time (a single createDirPath
    // would blow past PATH_MAX; only one/two dir handles are held at once).
    // 900 frames of the OLD code (~12KB of stack buffers each) exceed the
    // default 8 MB main-thread stack and SIGSEGV; the fixed code heap-allocates
    // its per-frame path buffers (tiny frames) and enforces MAX_DEPTH=4096, so
    // ztree traverses and terminates cleanly (exit 0, not a .signal term).
    const depth = 900;
    try b.createDirPath(io(), "deep");
    var cur = try b.openDir(io(), "deep", .{});
    var i: usize = 0;
    while (i < depth) : (i += 1) {
        cur.createDir(io(), "d", .default_dir) catch {};
        const next = try cur.openDir(io(), "d", .{});
        cur.close(io());
        cur = next;
    }
    cur.close(io());

    const base = try Dir.cwd().realPathFileAlloc(io(), name, a);
    defer a.free(base);
    const zt = try capture(a, build_options.ztree_exe, &.{ "-n", "deep" }, base);
    defer a.free(zt.stdout);
    defer a.free(zt.stderr);
    try std.testing.expectEqual(@as(u8, 0), zt.exit_code);
}

// ===========================================================================
// Documented-behavior tests (external anchor = observed GNU tree 2.2.1 output,
// hard-coded here so the suite retains an anchor even without the GNU binary).
// ===========================================================================

test "documented: exact bytes for a minimal one-dir-one-file tree" {
    const a = std.testing.allocator;
    const name = "ztst_exact";
    Dir.cwd().deleteTree(io(), name) catch {};
    defer Dir.cwd().deleteTree(io(), name) catch {};
    try Dir.cwd().createDirPath(io(), name);
    var b = try Dir.cwd().openDir(io(), name, .{});
    defer b.close(io());
    try b.createDirPath(io(), "m/sub");
    try b.writeFile(io(), .{ .sub_path = "m/file.txt", .data = "z\n" });

    const base = try Dir.cwd().realPathFileAlloc(io(), name, a);
    defer a.free(base);
    const zt = try capture(a, build_options.ztree_exe, &.{ "-n", "m" }, base);
    defer a.free(zt.stdout);
    defer a.free(zt.stderr);

    // GNU tree 2.2.1 `tree -n m` for {m/sub (dir), m/file.txt} prints (with NBSP
    // padding normalized to ASCII spaces):
    //   m
    //   ├── file.txt
    //   └── sub
    //
    //   2 directories, 1 file
    // Entries sort by name (file.txt < sub); "sub" has no trailing slash; the
    // root "m" is included in the directory count; "1 file" is singular.
    const expected =
        "m\n" ++
        "\u{251c}\u{2500}\u{2500} file.txt\n" ++
        "\u{2514}\u{2500}\u{2500} sub\n" ++
        "\n" ++
        "2 directories, 1 file\n";
    try std.testing.expectEqualStrings(expected, zt.stdout);
}

test "documented: singular vs plural in summary" {
    const a = std.testing.allocator;
    const name = "ztst_plural";
    Dir.cwd().deleteTree(io(), name) catch {};
    defer Dir.cwd().deleteTree(io(), name) catch {};
    try Dir.cwd().createDirPath(io(), name);
    var b = try Dir.cwd().openDir(io(), name, .{});
    defer b.close(io());
    try b.createDirPath(io(), "solo");

    const base = try Dir.cwd().realPathFileAlloc(io(), name, a);
    defer a.free(base);
    // A single empty directory argument: GNU prints "1 directory, 0 files".
    const zt = try capture(a, build_options.ztree_exe, &.{ "-n", "solo" }, base);
    defer a.free(zt.stdout);
    defer a.free(zt.stderr);
    try std.testing.expect(std.mem.indexOf(u8, zt.stdout, "1 directory, 0 files") != null);
    try std.testing.expect(std.mem.indexOf(u8, zt.stdout, "1 directories") == null);
}
