//! Externally-anchored parity tests for zsha256sum.
//!
//! The anchor is the REAL GNU coreutils `sha256sum` binary (installed here as
//! `gsha256sum` from Homebrew coreutils 9.10). For a spread of representative
//! inputs and flags we run zsha256sum and GNU with identical argv/stdin and
//! assert their stdout AND exit codes match byte-for-byte. GNU's output was not
//! authored by this library, so these are true external vectors — not
//! roundtrip self-consistency (see zig-forge/CLAUDE.md golden rule §1).
//!
//! A couple of digests are ALSO asserted against their published FIPS-180-4 /
//! well-known values (SHA-256 of "" and of "hello") so the tests still anchor
//! to something external even if the GNU binary is ever absent.
//!
//! The zsha256sum binary path is provided by build.zig via the ZSHA_BIN env
//! var; the GNU binary via GNU_SHA (default /opt/homebrew/bin/gsha256sum).

const std = @import("std");
const build_options = @import("build_options");
const testing = std.testing;
const io = std.testing.io;
const Io = std.Io;
const StdIo = std.process.SpawnOptions.StdIo;

const RunResult = struct {
    stdout: []u8,
    stderr: []u8,
    exit_code: u8,

    fn deinit(self: *RunResult, a: std.mem.Allocator) void {
        a.free(self.stdout);
        a.free(self.stderr);
    }
};

fn zshaBin() []const u8 {
    return build_options.zsha_bin;
}

fn gnuBin() ?[]const u8 {
    const p = build_options.gnu_bin;
    Io.Dir.cwd().access(io, p, .{}) catch return null;
    return p;
}

/// Run `bin` with `args` (argv[1..]) with working directory `cwd_dir` and the
/// given stdin behavior. Captures stdout/stderr and the process exit code.
fn run(
    a: std.mem.Allocator,
    bin: []const u8,
    args: []const []const u8,
    cwd_dir: Io.Dir,
    stdin: StdIo,
) !RunResult {
    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    defer argv.deinit(a);
    try argv.append(a, bin);
    for (args) |arg| try argv.append(a, arg);

    var child = try std.process.spawn(io, .{
        .argv = argv.items,
        .cwd = .{ .dir = cwd_dir },
        .stdin = stdin,
        .stdout = .pipe,
        .stderr = .pipe,
    });

    // Outputs are tiny (a few checksum lines), so draining stdout fully and
    // then stderr before wait() cannot deadlock.
    var obuf: [4096]u8 = undefined;
    var ebuf: [4096]u8 = undefined;
    var out_reader = child.stdout.?.readerStreaming(io, &obuf);
    const stdout = try out_reader.interface.allocRemaining(a, .unlimited);
    errdefer a.free(stdout);
    var err_reader = child.stderr.?.readerStreaming(io, &ebuf);
    const stderr = try err_reader.interface.allocRemaining(a, .unlimited);
    errdefer a.free(stderr);

    const term = try child.wait(io);
    const code: u8 = switch (term) {
        .exited => |c| c,
        else => 255,
    };
    return .{ .stdout = stdout, .stderr = stderr, .exit_code = code };
}

/// The core external-anchor assertion: zsha256sum and GNU produce identical
/// stdout and identical exit codes for the same argv + stdin.
fn expectParity(a: std.mem.Allocator, args: []const []const u8, dir: Io.Dir, stdin: StdIo) !void {
    const gnu = gnuBin() orelse return error.SkipZigTest;
    var zr = try run(a, zshaBin(), args, dir, stdin);
    defer zr.deinit(a);
    var gr = try run(a, gnu, args, dir, stdin);
    defer gr.deinit(a);

    if (!std.mem.eql(u8, zr.stdout, gr.stdout) or zr.exit_code != gr.exit_code) {
        std.debug.print(
            \\PARITY MISMATCH ({d} args)
            \\  zsha exit={d} stdout=<<{s}>> stderr=<<{s}>>
            \\  gnu  exit={d} stdout=<<{s}>> stderr=<<{s}>>
            \\
        , .{ args.len, zr.exit_code, zr.stdout, zr.stderr, gr.exit_code, gr.stdout, gr.stderr });
    }
    try testing.expectEqualStrings(gr.stdout, zr.stdout);
    try testing.expectEqual(gr.exit_code, zr.exit_code);
}

const Fixture = struct {
    tmp: testing.TmpDir,

    fn deinit(self: *Fixture) void {
        self.tmp.cleanup();
    }
    fn dir(self: *Fixture) Io.Dir {
        return self.tmp.dir;
    }
    fn write(self: *Fixture, sub_path: []const u8, data: []const u8) !void {
        try self.tmp.dir.writeFile(io, .{ .sub_path = sub_path, .data = data });
    }
};

fn makeFixture() !Fixture {
    var tmp = testing.tmpDir(.{});
    errdefer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "hello.txt", .data = "hello" });
    try tmp.dir.writeFile(io, .{ .sub_path = "empty.txt", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "big.bin", .data = "The quick brown fox jumps over the lazy dog\n" ** 5000 });
    try tmp.dir.createDirPath(io, "adir");
    return .{ .tmp = tmp };
}

// ---------------------------------------------------------------------------
// Published-value anchors (independent of the GNU binary).
// ---------------------------------------------------------------------------

test "digest of empty input matches FIPS-180-4 known value" {
    const a = testing.allocator;
    var fx = try makeFixture();
    defer fx.deinit();

    var r = try run(a, zshaBin(), &.{"empty.txt"}, fx.dir(), .ignore);
    defer r.deinit(a);
    // e3b0c442... is the canonical SHA-256 of the empty string.
    try testing.expect(std.mem.startsWith(u8, r.stdout, "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"));
    try testing.expectEqual(@as(u8, 0), r.exit_code);
}

test "digest of \"hello\" matches well-known value" {
    const a = testing.allocator;
    var fx = try makeFixture();
    defer fx.deinit();

    var r = try run(a, zshaBin(), &.{"hello.txt"}, fx.dir(), .ignore);
    defer r.deinit(a);
    try testing.expect(std.mem.startsWith(u8, r.stdout, "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"));
    try testing.expectEqual(@as(u8, 0), r.exit_code);
}

// ---------------------------------------------------------------------------
// GNU parity — hashing modes
// ---------------------------------------------------------------------------

test "parity: hash a single file (default/text)" {
    var fx = try makeFixture();
    defer fx.deinit();
    try expectParity(testing.allocator, &.{"hello.txt"}, fx.dir(), .ignore);
}

test "parity: hash multiple files at once" {
    var fx = try makeFixture();
    defer fx.deinit();
    try expectParity(testing.allocator, &.{ "hello.txt", "empty.txt", "big.bin" }, fx.dir(), .ignore);
}

test "parity: binary mode marker" {
    var fx = try makeFixture();
    defer fx.deinit();
    try expectParity(testing.allocator, &.{ "-b", "hello.txt" }, fx.dir(), .ignore);
}

test "parity: BSD tag output" {
    var fx = try makeFixture();
    defer fx.deinit();
    try expectParity(testing.allocator, &.{ "--tag", "big.bin" }, fx.dir(), .ignore);
}

test "parity: hash stdin from a file" {
    const a = testing.allocator;
    var fx = try makeFixture();
    defer fx.deinit();
    try fx.write("stdin_input.txt", "streamed via standard input\n");

    const gnu = gnuBin() orelse return error.SkipZigTest;
    // Feed the file as the child's stdin for both binaries.
    var zf = try fx.dir().openFile(io, "stdin_input.txt", .{});
    var zr = try run(a, zshaBin(), &.{"-"}, fx.dir(), .{ .file = zf });
    zf.close(io);
    defer zr.deinit(a);
    var gf = try fx.dir().openFile(io, "stdin_input.txt", .{});
    var gr = try run(a, gnu, &.{"-"}, fx.dir(), .{ .file = gf });
    gf.close(io);
    defer gr.deinit(a);

    try testing.expectEqualStrings(gr.stdout, zr.stdout);
    try testing.expectEqual(gr.exit_code, zr.exit_code);
}

test "parity: hash empty stdin" {
    var fx = try makeFixture();
    defer fx.deinit();
    // No args, /dev/null stdin -> hash of empty input, exit 0, for both.
    try expectParity(testing.allocator, &.{}, fx.dir(), .ignore);
}

// ---------------------------------------------------------------------------
// GNU parity — error handling (the high-severity findings)
// ---------------------------------------------------------------------------

test "parity: hashing a directory errors (not empty-hash + exit 0)" {
    var fx = try makeFixture();
    defer fx.deinit();
    // Regression anchor for the "read error treated as EOF" finding: GNU emits
    // no stdout and exits 1; the old code printed e3b0c442... and exited 0.
    try expectParity(testing.allocator, &.{"adir"}, fx.dir(), .ignore);
}

test "parity: missing file errors" {
    var fx = try makeFixture();
    defer fx.deinit();
    try expectParity(testing.allocator, &.{"does-not-exist.txt"}, fx.dir(), .ignore);
}

test "parity: unknown short option is rejected" {
    var fx = try makeFixture();
    defer fx.deinit();
    // stdout empty for both; exit code 1 for both.
    try expectParity(testing.allocator, &.{ "-Z", "hello.txt" }, fx.dir(), .ignore);
}

test "parity: unknown long option is rejected" {
    var fx = try makeFixture();
    defer fx.deinit();
    try expectParity(testing.allocator, &.{ "--bogus", "hello.txt" }, fx.dir(), .ignore);
}

// ---------------------------------------------------------------------------
// GNU parity — check mode
// ---------------------------------------------------------------------------

/// Generate a real GNU sums file for `files` and write it as `sums.txt`.
fn sumsFor(a: std.mem.Allocator, fx: *Fixture, files: []const []const u8) !void {
    const gnu = gnuBin() orelse return error.SkipZigTest;
    var r = try run(a, gnu, files, fx.dir(), .ignore);
    defer r.deinit(a);
    try fx.write("sums.txt", r.stdout);
}

test "parity: check mode all OK" {
    const a = testing.allocator;
    var fx = try makeFixture();
    defer fx.deinit();
    try sumsFor(a, &fx, &.{ "hello.txt", "empty.txt" });
    try expectParity(a, &.{ "-c", "sums.txt" }, fx.dir(), .ignore);
}

test "parity: check mode with no trailing newline verifies last line" {
    const a = testing.allocator;
    var fx = try makeFixture();
    defer fx.deinit();
    const gnu = gnuBin() orelse return error.SkipZigTest;
    var r = try run(a, gnu, &.{"hello.txt"}, fx.dir(), .ignore);
    defer r.deinit(a);
    const trimmed = std.mem.trimEnd(u8, r.stdout, "\n");
    try fx.write("nonl.txt", trimmed);
    // Regression anchor for "drops final line without trailing newline".
    try expectParity(a, &.{ "-c", "nonl.txt" }, fx.dir(), .ignore);
}

test "parity: check mode mismatch fails" {
    var fx = try makeFixture();
    defer fx.deinit();
    try fx.write("bad.txt", "0000000000000000000000000000000000000000000000000000000000000000  hello.txt\n");
    try expectParity(testing.allocator, &.{ "-c", "bad.txt" }, fx.dir(), .ignore);
}

test "parity: check mode with no valid lines errors" {
    var fx = try makeFixture();
    defer fx.deinit();
    try fx.write("junk.txt", "not a checksum line\nanother garbage line\n");
    // Regression anchor for "no properly formatted checksum lines found".
    try expectParity(testing.allocator, &.{ "-c", "junk.txt" }, fx.dir(), .ignore);
}

test "parity: check mode --status quiet on success and failure" {
    const a = testing.allocator;
    var fx = try makeFixture();
    defer fx.deinit();
    try sumsFor(a, &fx, &.{"hello.txt"});
    try expectParity(a, &.{ "--status", "-c", "sums.txt" }, fx.dir(), .ignore);
    try fx.write("bad.txt", "0000000000000000000000000000000000000000000000000000000000000000  hello.txt\n");
    try expectParity(a, &.{ "--status", "-c", "bad.txt" }, fx.dir(), .ignore);
}

test "parity: check mode referencing a directory reports FAILED" {
    var fx = try makeFixture();
    defer fx.deinit();
    try fx.write("dir.txt", "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855  adir\n");
    try expectParity(testing.allocator, &.{ "-c", "dir.txt" }, fx.dir(), .ignore);
}
