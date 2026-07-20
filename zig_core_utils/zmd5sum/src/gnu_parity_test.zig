//! Externally-anchored parity tests for zmd5sum.
//!
//! TWO kinds of external anchor are used here (per zig-forge/CLAUDE.md's golden
//! rule — no roundtrip-only tests):
//!
//!  1. DIFF-AGAINST-GNU: most tests run the real GNU coreutils `md5sum`
//!     (Homebrew `gmd5sum`, coreutils 9.10) on the SAME inputs and byte-compare
//!     stdout + exit code (and, where relevant, normalized stderr). GNU is the
//!     reference implementation; its output is an input the library author did
//!     not write. If gmd5sum is not installed the diff tests SkipZigTest.
//!
//!  2. LITERAL SPEC VECTORS: the MD5 digests in `test "RFC 1321 …"` are the
//!     published test vectors from RFC 1321 Appendix A.5 (the MD5 spec). They
//!     are hard-coded expected bytes, independent of any binary being present.
//!
//! The built zmd5sum binary path is injected by build.zig via build options.

const std = @import("std");
const Io = std.Io;
const File = std.Io.File;
const build_options = @import("build_options");

const ZMD5SUM = build_options.zmd5sum_bin;

// build.zig injects zmd5sum_bin as a path relative to the build root, but the
// test children run with cwd set to a scratch dir. Resolve it to absolute once.
var abs_cwd_buf: [8192]u8 = undefined;
var abs_bin_buf: [8192]u8 = undefined;
var abs_bin_cached: ?[]const u8 = null;

fn zmdBin() []const u8 {
    if (abs_bin_cached) |p| return p;
    if (ZMD5SUM.len > 0 and ZMD5SUM[0] == '/') {
        abs_bin_cached = ZMD5SUM;
        return ZMD5SUM;
    }
    const n = std.process.currentPath(std.testing.io, &abs_cwd_buf) catch @panic("currentPath failed");
    const full = std.fmt.bufPrint(&abs_bin_buf, "{s}/{s}", .{ abs_cwd_buf[0..n], ZMD5SUM }) catch @panic("zmd5sum path too long");
    abs_bin_cached = full;
    return full;
}

/// Candidate paths for the real GNU md5sum on this machine.
const GNU_CANDIDATES = [_][]const u8{
    "/opt/homebrew/opt/coreutils/libexec/gnubin/md5sum",
    "/opt/homebrew/bin/gmd5sum",
    "/usr/bin/md5sum", // GNU on Linux
};

fn findGnu() ?[]const u8 {
    const io = std.testing.io;
    for (GNU_CANDIDATES) |c| {
        Io.Dir.accessAbsolute(io, c, .{}) catch continue;
        return c;
    }
    return null;
}

const RunResult = struct {
    stdout: []u8,
    stderr: []u8,
    exit_code: u8,

    fn deinit(self: RunResult, a: std.mem.Allocator) void {
        a.free(self.stdout);
        a.free(self.stderr);
    }
};

fn termCode(term: std.process.Child.Term) u8 {
    return switch (term) {
        .exited => |c| c,
        else => 255,
    };
}

/// Spawn `argv` with cwd `dir`, optional `stdin_file`, capture stdout+stderr.
/// Modeled on std.process.run's deadlock-safe MultiReader drain, with stdin
/// support added (run() hardcodes stdin=.ignore).
fn runChild(
    a: std.mem.Allocator,
    argv: []const []const u8,
    dir: Io.Dir,
    stdin_file: ?File,
) !RunResult {
    const io = std.testing.io;
    var child = std.process.spawn(io, .{
        .argv = argv,
        .cwd = .{ .dir = dir },
        .stdin = if (stdin_file) |f| .{ .file = f } else .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
    }) catch |e| {
        std.debug.print("spawn failed: {s}  argv0={s}\n", .{ @errorName(e), argv[0] });
        return e;
    };
    defer child.kill(io);

    var mr_buf: File.MultiReader.Buffer(2) = undefined;
    var mr: File.MultiReader = undefined;
    mr.init(a, io, mr_buf.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer mr.deinit();

    while (mr.fill(64, .none)) |_| {} else |err| switch (err) {
        error.EndOfStream => {},
        else => |e| return e,
    }
    try mr.checkAnyError();

    const term = try child.wait(io);
    const out = try mr.toOwnedSlice(0);
    errdefer a.free(out);
    const errbuf = try mr.toOwnedSlice(1);

    return .{ .stdout = out, .stderr = errbuf, .exit_code = termCode(term) };
}

/// Rewrite our diagnostic program-name prefix ("zmd5sum") to whatever basename
/// GNU was invoked under (e.g. "md5sum" via the coreutils gnubin symlink, or
/// "gmd5sum") so stderr lines up for comparison. (Filenames in these tests
/// never contain the substring "zmd5sum".)
fn normalizeProg(a: std.mem.Allocator, s: []const u8, gnu_name: []const u8) ![]u8 {
    return std.mem.replaceOwned(u8, a, s, "zmd5sum", gnu_name);
}

const CompareOpts = struct {
    compare_stderr: bool = false,
};

/// The core anchor: run identical args through zmd5sum and GNU md5sum with the
/// same cwd/stdin and assert byte-identical stdout + exit code (+ optional
/// normalized stderr). `args` excludes argv[0].
fn expectMatchesGnu(
    a: std.mem.Allocator,
    dir: Io.Dir,
    args: []const []const u8,
    stdin_bytes: ?[]const u8,
    opts: CompareOpts,
) !void {
    const gnu = findGnu() orelse return error.SkipZigTest;
    const io = std.testing.io;

    var z_argv: std.ArrayListUnmanaged([]const u8) = .empty;
    defer z_argv.deinit(a);
    try z_argv.append(a, zmdBin());
    try z_argv.appendSlice(a, args);

    var g_argv: std.ArrayListUnmanaged([]const u8) = .empty;
    defer g_argv.deinit(a);
    try g_argv.append(a, gnu);
    try g_argv.appendSlice(a, args);

    // Each child gets a freshly-opened stdin file (no seeking API available).
    if (stdin_bytes) |bytes| {
        try dir.writeFile(io, .{ .sub_path = "_stdin", .data = bytes });
    }

    var zf: ?File = if (stdin_bytes != null) try dir.openFile(io, "_stdin", .{}) else null;
    const z = try runChild(a, z_argv.items, dir, zf);
    if (zf) |*f| f.close(io);
    defer z.deinit(a);

    var gf: ?File = if (stdin_bytes != null) try dir.openFile(io, "_stdin", .{}) else null;
    const g = try runChild(a, g_argv.items, dir, gf);
    if (gf) |*f| f.close(io);
    defer g.deinit(a);

    const joined = try std.mem.join(a, " ", args);
    defer a.free(joined);

    if (!std.mem.eql(u8, z.stdout, g.stdout) or z.exit_code != g.exit_code) {
        std.debug.print(
            \\
            \\PARITY MISMATCH for args=[{s}]
            \\  zmd5sum exit={d} stdout=<<{s}>>
            \\  gmd5sum exit={d} stdout=<<{s}>>
            \\
        , .{ joined, z.exit_code, z.stdout, g.exit_code, g.stdout });
        return error.ParityMismatch;
    }

    if (opts.compare_stderr) {
        const z_err = try normalizeProg(a, z.stderr, std.fs.path.basename(gnu));
        defer a.free(z_err);
        if (!std.mem.eql(u8, z_err, g.stderr)) {
            std.debug.print(
                \\
                \\STDERR PARITY MISMATCH for args=[{s}]
                \\  zmd5sum stderr=<<{s}>>
                \\  gmd5sum stderr=<<{s}>>
                \\
            , .{ joined, z_err, g.stderr });
            return error.ParityMismatch;
        }
    }
}

const Fixture = struct {
    tmp: std.testing.TmpDir,

    fn create() Fixture {
        return .{ .tmp = std.testing.tmpDir(.{}) };
    }

    fn dir(self: *Fixture) Io.Dir {
        return self.tmp.dir;
    }

    fn writeFile(self: *Fixture, name: []const u8, bytes: []const u8) !void {
        try self.tmp.dir.writeFile(std.testing.io, .{ .sub_path = name, .data = bytes });
    }

    /// Write `bytes` to a scratch file and return it opened read-only, for use
    /// as a child's stdin.
    fn stdinFile(self: *Fixture, bytes: []const u8) !File {
        try self.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "_stdin", .data = bytes });
        return self.tmp.dir.openFile(std.testing.io, "_stdin", .{});
    }

    fn deinit(self: *Fixture) void {
        self.tmp.cleanup();
    }
};

const H_HELLO = "b1946ac92492d2347c6235b4d2611184"; // md5("hello\n")

// ---------------------------------------------------------------------------
// Literal spec-vector anchors (RFC 1321 Appendix A.5) — no external binary.
// ---------------------------------------------------------------------------

test "RFC 1321 A.5 MD5 test vectors (stdin)" {
    const a = std.testing.allocator;
    var fx = Fixture.create();
    defer fx.deinit();

    const Vec = struct { in: []const u8, hex: []const u8 };
    const vecs = [_]Vec{
        .{ .in = "", .hex = "d41d8cd98f00b204e9800998ecf8427e" },
        .{ .in = "a", .hex = "0cc175b9c0f1b6a831c399e269772661" },
        .{ .in = "abc", .hex = "900150983cd24fb0d6963f7d28e17f72" },
        .{ .in = "message digest", .hex = "f96b697d7cb7938d525a2f31aaf161d0" },
        .{ .in = "abcdefghijklmnopqrstuvwxyz", .hex = "c3fcd3d76192e4007dfb496cca67e13b" },
        .{ .in = "12345678901234567890123456789012345678901234567890123456789012345678901234567890", .hex = "57edf4a22be3c955ac49da2e2107b67a" },
    };
    for (vecs) |v| {
        var f = try fx.stdinFile(v.in);
        defer f.close(std.testing.io);
        const r = try runChild(a, &.{ zmdBin(), "-" }, fx.dir(), f);
        defer r.deinit(a);
        // Output form: "<hex>  -\n"
        var expected: std.ArrayListUnmanaged(u8) = .empty;
        defer expected.deinit(a);
        try expected.appendSlice(a, v.hex);
        try expected.appendSlice(a, "  -\n");
        try std.testing.expectEqualStrings(expected.items, r.stdout);
        try std.testing.expectEqual(@as(u8, 0), r.exit_code);
    }
}

// ---------------------------------------------------------------------------
// Diff-against-GNU anchors.
// ---------------------------------------------------------------------------

test "hash: basic file, binary, tag, zero" {
    const a = std.testing.allocator;
    var fx = Fixture.create();
    defer fx.deinit();
    try fx.writeFile("a.txt", "hello\n");
    try fx.writeFile("b.bin", &[_]u8{ 0, 1, 2, 3, 255, 254 });

    try expectMatchesGnu(a, fx.dir(), &.{"a.txt"}, null, .{});
    try expectMatchesGnu(a, fx.dir(), &.{ "-b", "a.txt" }, null, .{});
    try expectMatchesGnu(a, fx.dir(), &.{ "--tag", "a.txt" }, null, .{});
    try expectMatchesGnu(a, fx.dir(), &.{ "-z", "a.txt" }, null, .{});
    try expectMatchesGnu(a, fx.dir(), &.{"b.bin"}, null, .{});
    try expectMatchesGnu(a, fx.dir(), &.{ "a.txt", "b.bin" }, null, .{});
}

test "hash: filename escaping (backslash, newline, CR)" {
    const a = std.testing.allocator;
    var fx = Fixture.create();
    defer fx.deinit();
    try fx.writeFile("back\\slash.txt", "y");
    try fx.writeFile("a\nb", "x");
    try fx.writeFile("c\rd", "z");

    try expectMatchesGnu(a, fx.dir(), &.{"back\\slash.txt"}, null, .{});
    try expectMatchesGnu(a, fx.dir(), &.{"a\nb"}, null, .{});
    try expectMatchesGnu(a, fx.dir(), &.{"c\rd"}, null, .{});
    // -z disables escaping
    try expectMatchesGnu(a, fx.dir(), &.{ "-z", "a\nb" }, null, .{});
    // tag mode escaping
    try expectMatchesGnu(a, fx.dir(), &.{ "--tag", "a\nb" }, null, .{});
}

// HIGH finding: last line without a trailing newline was silently dropped and
// -c reported success without verifying anything.
test "check: last line without trailing newline is verified" {
    const a = std.testing.allocator;
    var fx = Fixture.create();
    defer fx.deinit();
    try fx.writeFile("a.txt", "hello\n");
    // No trailing newline after the entry.
    try fx.writeFile("sums.txt", H_HELLO ++ "  a.txt");
    try expectMatchesGnu(a, fx.dir(), &.{ "-c", "sums.txt" }, null, .{ .compare_stderr = true });
}

// HIGH finding: a file with no properly-formatted lines must exit 1 with the
// GNU diagnostic, not silently succeed.
test "check: no properly formatted lines -> exit 1" {
    const a = std.testing.allocator;
    var fx = Fixture.create();
    defer fx.deinit();
    try fx.writeFile("garbage.txt", "this is not a checksum line\nnor is this\n");
    try expectMatchesGnu(a, fx.dir(), &.{ "-c", "garbage.txt" }, null, .{ .compare_stderr = true });

    try fx.writeFile("empty.txt", "");
    try expectMatchesGnu(a, fx.dir(), &.{ "-c", "empty.txt" }, null, .{ .compare_stderr = true });

    try fx.writeFile("onlyblank.txt", "\n\n\n");
    try expectMatchesGnu(a, fx.dir(), &.{ "-c", "onlyblank.txt" }, null, .{ .compare_stderr = true });
}

// HIGH finding: -c must read the checksum list from stdin when file is '-'.
test "check: checksum list from stdin" {
    const a = std.testing.allocator;
    var fx = Fixture.create();
    defer fx.deinit();
    try fx.writeFile("a.txt", "hello\n");
    const list = H_HELLO ++ "  a.txt\n";
    try expectMatchesGnu(a, fx.dir(), &.{ "-c", "-" }, list, .{ .compare_stderr = true });
    // Default file is '-', so bare -c reads stdin too.
    try expectMatchesGnu(a, fx.dir(), &.{"-c"}, list, .{ .compare_stderr = true });
}

// MEDIUM finding: checksum lines longer than the old fixed 1024-byte buffer
// were silently truncated, verifying the wrong filename.
test "check: very long checksum line is not truncated" {
    const a = std.testing.allocator;
    var fx = Fixture.create();
    defer fx.deinit();

    // Build a relative path ~1005 bytes long: four 250-byte directory
    // components (each within NAME_MAX) plus a file. The whole checksum LINE is
    // then 32 (hash) + 2 (sep) + ~1005 = ~1039 bytes, past the old fixed
    // 1024-byte line buffer that silently truncated the filename. The path
    // itself stays under PATH_MAX (1024) so it remains openable.
    var longname: std.ArrayListUnmanaged(u8) = .empty;
    defer longname.deinit(a);
    var i: usize = 0;
    while (i < 4) : (i += 1) {
        try longname.appendNTimes(a, 'x', 250);
        try longname.append(a, '/');
    }
    try longname.appendSlice(a, "f.txt");

    // Create the directory chain, then the target file.
    const dirpart = longname.items[0 .. longname.items.len - "f.txt".len - 1];
    try fx.dir().createDirPath(std.testing.io, dirpart);
    try fx.writeFile(longname.items, "hello\n");

    var list: std.ArrayListUnmanaged(u8) = .empty;
    defer list.deinit(a);
    try list.appendSlice(a, H_HELLO);
    try list.appendSlice(a, "  ");
    try list.appendSlice(a, longname.items);
    try list.append(a, '\n');
    try fx.writeFile("sums.txt", list.items);

    try expectMatchesGnu(a, fx.dir(), &.{ "-c", "sums.txt" }, null, .{ .compare_stderr = true });
}

test "check: separator variants (one space, star, two-space, tab, uppercase)" {
    const a = std.testing.allocator;
    var fx = Fixture.create();
    defer fx.deinit();
    try fx.writeFile("a.txt", "hello\n");

    try fx.writeFile("one.txt", H_HELLO ++ " a.txt\n");
    try expectMatchesGnu(a, fx.dir(), &.{ "-c", "one.txt" }, null, .{ .compare_stderr = true });

    try fx.writeFile("star.txt", H_HELLO ++ " *a.txt\n");
    try expectMatchesGnu(a, fx.dir(), &.{ "-c", "star.txt" }, null, .{ .compare_stderr = true });

    try fx.writeFile("two.txt", H_HELLO ++ "  a.txt\n");
    try expectMatchesGnu(a, fx.dir(), &.{ "-c", "two.txt" }, null, .{ .compare_stderr = true });

    try fx.writeFile("tab.txt", H_HELLO ++ "\ta.txt\n");
    try expectMatchesGnu(a, fx.dir(), &.{ "-c", "tab.txt" }, null, .{ .compare_stderr = true });

    // Uppercase digest must still verify.
    try fx.writeFile("upper.txt", "B1946AC92492D2347C6235B4D2611184  a.txt\n");
    try expectMatchesGnu(a, fx.dir(), &.{ "-c", "upper.txt" }, null, .{ .compare_stderr = true });
}

test "check: mismatch and unreadable-file wording differ" {
    const a = std.testing.allocator;
    var fx = Fixture.create();
    defer fx.deinit();
    try fx.writeFile("a.txt", "hello\n");

    // Wrong digest -> FAILED, "computed checksum did NOT match".
    try fx.writeFile("mism.txt", "deadbeefdeadbeefdeadbeefdeadbeef  a.txt\n");
    try expectMatchesGnu(a, fx.dir(), &.{ "-c", "mism.txt" }, null, .{ .compare_stderr = true });

    // Missing target -> FAILED open or read, "listed file could not be read".
    try fx.writeFile("miss.txt", "deadbeefdeadbeefdeadbeefdeadbeef  nonexist.txt\n");
    try expectMatchesGnu(a, fx.dir(), &.{ "-c", "miss.txt" }, null, .{ .compare_stderr = true });
}

test "check: blank lines are ignored among valid lines" {
    const a = std.testing.allocator;
    var fx = Fixture.create();
    defer fx.deinit();
    try fx.writeFile("a.txt", "hello\n");
    try fx.writeFile("blank.txt", "\n" ++ H_HELLO ++ "  a.txt\n\n");
    try expectMatchesGnu(a, fx.dir(), &.{ "-c", "blank.txt" }, null, .{ .compare_stderr = true });
}

test "check: improper lines with --warn / --strict" {
    const a = std.testing.allocator;
    var fx = Fixture.create();
    defer fx.deinit();
    try fx.writeFile("a.txt", "hello\n");
    try fx.writeFile("mixed.txt", H_HELLO ++ "  a.txt\nbad line 1\nbad line 2\n");

    try expectMatchesGnu(a, fx.dir(), &.{ "-c", "mixed.txt" }, null, .{ .compare_stderr = true });
    try expectMatchesGnu(a, fx.dir(), &.{ "-c", "-w", "mixed.txt" }, null, .{ .compare_stderr = true });
    try expectMatchesGnu(a, fx.dir(), &.{ "-c", "--strict", "mixed.txt" }, null, .{ .compare_stderr = true });
}

test "check: --ignore-missing" {
    const a = std.testing.allocator;
    var fx = Fixture.create();
    defer fx.deinit();
    try fx.writeFile("a.txt", "hello\n");

    try fx.writeFile("im.txt", H_HELLO ++ "  a.txt\ndeadbeefdeadbeefdeadbeefdeadbeef  gone.txt\n");
    try expectMatchesGnu(a, fx.dir(), &.{ "-c", "--ignore-missing", "im.txt" }, null, .{ .compare_stderr = true });

    try fx.writeFile("im2.txt", "deadbeefdeadbeefdeadbeefdeadbeef  gone.txt\n");
    try expectMatchesGnu(a, fx.dir(), &.{ "-c", "--ignore-missing", "im2.txt" }, null, .{ .compare_stderr = true });
}

test "check: BSD --tag lines are parsed (self-verify)" {
    const a = std.testing.allocator;
    var fx = Fixture.create();
    defer fx.deinit();
    try fx.writeFile("a.txt", "hello\n");
    try fx.writeFile("tag.txt", "MD5 (a.txt) = " ++ H_HELLO ++ "\n");
    try expectMatchesGnu(a, fx.dir(), &.{ "-c", "tag.txt" }, null, .{ .compare_stderr = true });
}

test "check: escaped filename round-trips through -c" {
    const a = std.testing.allocator;
    var fx = Fixture.create();
    defer fx.deinit();
    try fx.writeFile("back\\slash.txt", "y");
    try fx.writeFile("a\nb", "x");

    // The escaped checksum lines exactly as GNU would emit them.
    try fx.writeFile("bs.txt", "\\415290769594460e2e485922904f345d  back\\\\slash.txt\n");
    try expectMatchesGnu(a, fx.dir(), &.{ "-c", "bs.txt" }, null, .{ .compare_stderr = true });

    try fx.writeFile("nl.txt", "\\9dd4e461268c8034f5c8564e155c67a6  a\\nb\n");
    try expectMatchesGnu(a, fx.dir(), &.{ "-c", "nl.txt" }, null, .{ .compare_stderr = true });
}

test "check: --quiet and --status suppress output correctly" {
    const a = std.testing.allocator;
    var fx = Fixture.create();
    defer fx.deinit();
    try fx.writeFile("a.txt", "hello\n");
    try fx.writeFile("sums.txt", H_HELLO ++ "  a.txt\n");
    try fx.writeFile("bad.txt", "deadbeefdeadbeefdeadbeefdeadbeef  a.txt\n");

    try expectMatchesGnu(a, fx.dir(), &.{ "-c", "--quiet", "sums.txt" }, null, .{ .compare_stderr = true });
    try expectMatchesGnu(a, fx.dir(), &.{ "-c", "--status", "sums.txt" }, null, .{ .compare_stderr = true });
    try expectMatchesGnu(a, fx.dir(), &.{ "-c", "--status", "bad.txt" }, null, .{});
}

test "self-verify: --tag output feeds back into -c" {
    const a = std.testing.allocator;
    var fx = Fixture.create();
    defer fx.deinit();
    try fx.writeFile("a.txt", "hello\n");

    // Produce tag output with zmd5sum, verify it with zmd5sum -c, compare the
    // whole pipeline's verification result against GNU doing the same.
    const tag = try runChild(a, &.{ zmdBin(), "--tag", "a.txt" }, fx.dir(), null);
    defer tag.deinit(a);
    try expectMatchesGnu(a, fx.dir(), &.{ "-c", "-" }, tag.stdout, .{ .compare_stderr = true });
}
