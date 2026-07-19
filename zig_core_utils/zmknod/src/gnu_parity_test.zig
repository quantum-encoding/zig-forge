//! GNU parity tests for zmknod.
//!
//! External anchor: every diff case is run live against the real GNU
//! coreutils `mknod` binary (Homebrew gnubin), in an identical fixture
//! directory: exit code, stdout, stderr (program-name normalized), and
//! the resulting filesystem node (kind + permission bits) must all match.
//!
//! A second set of literal tests pins the exact diagnostic bytes and
//! resulting modes observed from GNU coreutils 9.10 `mknod` (LC_ALL=C,
//! macOS, 2026-07-19) so the suite still verifies GNU-documented
//! behavior byte-for-byte on machines without the GNU binary. These are
//! NOT roundtrip tests — expected outputs were captured from the GNU
//! binary, not derived from zmknod.

const std = @import("std");
const build_options = @import("build_options");
const testing = std.testing;
const io = testing.io;
const Io = std.Io;

const zmknod_bin = build_options.zmknod_bin;

const gnu_candidates = [_][]const u8{
    "/opt/homebrew/opt/coreutils/libexec/gnubin/mknod",
    "/usr/local/opt/coreutils/libexec/gnubin/mknod",
    "/opt/homebrew/bin/gmknod",
    "/usr/local/bin/gmknod",
};

fn findGnuMknod() ?[]const u8 {
    for (gnu_candidates) |candidate| {
        Io.Dir.accessAbsolute(io, candidate, .{}) catch continue;
        return candidate;
    }
    return null;
}

const RunOutcome = struct {
    code: u8,
    stdout: []u8,
    stderr: []u8,

    fn deinit(self: *RunOutcome, allocator: std.mem.Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
    }
};

/// Run `bin` with `args` inside `cwd`, LC_ALL=C, capturing everything.
fn runTool(
    allocator: std.mem.Allocator,
    bin: []const u8,
    args: []const []const u8,
    cwd: Io.Dir,
) !RunOutcome {
    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, bin);
    try argv.appendSlice(allocator, args);

    // C locale so GNU quoting is ASCII '...' regardless of host locale.
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put("LC_ALL", "C");

    const result = try std.process.run(allocator, io, .{
        .argv = argv.items,
        .cwd = .{ .dir = cwd },
        .environ_map = &env,
    });
    const code: u8 = switch (result.term) {
        .exited => |c| c,
        else => {
            allocator.free(result.stdout);
            allocator.free(result.stderr);
            return error.ChildCrashed;
        },
    };
    return .{ .code = code, .stdout = result.stdout, .stderr = result.stderr };
}

/// GNU prints its own name from argv[0] ("mknod:" in error() lines, the
/// full binary path in Try/getopt lines); zmknod hardcodes "zmknod".
/// Normalize both to the token "mknod" so the bytes can be compared.
fn normalize(allocator: std.mem.Allocator, output: []const u8, prog_token: []const u8) ![]u8 {
    return std.mem.replaceOwned(u8, allocator, output, prog_token, "mknod");
}

const Fixture = *const fn (dir: Io.Dir) anyerror!void;

extern "c" fn umask(mask: c_uint) c_uint;

const NodeStat = struct {
    kind: u32, // S_IFMT bits
    perm: u32, // low 12 permission bits
};

/// lstat-style stat of `path` relative to `dir` via fstatat (statFile
/// would open() the node — opening a FIFO read-only blocks forever).
fn statNode(dir: Io.Dir, path: []const u8) !?NodeStat {
    var buf: [512]u8 = undefined;
    const path_z = try std.fmt.bufPrintZ(&buf, "{s}", .{path});
    var st: std.c.Stat = undefined;
    if (std.c.fstatat(dir.handle, path_z, &st, 0) != 0) return null;
    const mode: u32 = @intCast(st.mode);
    return .{ .kind = mode & 0o170000, .perm = mode & 0o7777 };
}

/// Core harness: identical fixtures in two temp dirs, run GNU mknod in
/// one and zmknod in the other, require identical exit code + normalized
/// stdout/stderr, and — when `state_path` is given — an identical
/// resulting node (same existence, kind, permission bits) in both dirs.
fn diffAgainstGnu(args: []const []const u8, setup: ?Fixture, state_path: ?[]const u8) !void {
    const gnu = findGnuMknod() orelse return error.SkipZigTest;
    const allocator = testing.allocator;

    var tmp_gnu = testing.tmpDir(.{});
    defer tmp_gnu.cleanup();
    var tmp_z = testing.tmpDir(.{});
    defer tmp_z.cleanup();

    if (setup) |s| {
        try s(tmp_gnu.dir);
        try s(tmp_z.dir);
    }

    var res_gnu = try runTool(allocator, gnu, args, tmp_gnu.dir);
    defer res_gnu.deinit(allocator);
    var res_z = try runTool(allocator, zmknod_bin, args, tmp_z.dir);
    defer res_z.deinit(allocator);

    const gnu_stderr = try normalize(allocator, res_gnu.stderr, gnu);
    defer allocator.free(gnu_stderr);
    const gnu_stdout = try normalize(allocator, res_gnu.stdout, gnu);
    defer allocator.free(gnu_stdout);
    const z_stderr = try normalize(allocator, res_z.stderr, "zmknod");
    defer allocator.free(z_stderr);
    const z_stdout = try normalize(allocator, res_z.stdout, "zmknod");
    defer allocator.free(z_stdout);

    try testing.expectEqualStrings(gnu_stderr, z_stderr);
    try testing.expectEqualStrings(gnu_stdout, z_stdout);
    try testing.expectEqual(res_gnu.code, res_z.code);

    if (state_path) |p| {
        const st_gnu = try statNode(tmp_gnu.dir, p);
        const st_z = try statNode(tmp_z.dir, p);
        try testing.expectEqual(st_gnu == null, st_z == null);
        if (st_gnu) |g| {
            try testing.expectEqual(g.kind, st_z.?.kind);
            try testing.expectEqual(g.perm, st_z.?.perm);
        }
    }
}

// ---- fixtures ----

fn fixtureFileF(dir: Io.Dir) anyerror!void {
    try dir.writeFile(io, .{ .sub_path = "f", .data = "x\n" });
}

// ---- GNU-diff tests: success paths ----

test "fifo: plain create, silent, exit 0, same kind+mode" {
    try diffAgainstGnu(&.{ "f", "p" }, null, "f");
}

test "fifo: -m 600 applied exactly, umask NOT applied (high finding)" {
    try diffAgainstGnu(&.{ "-m", "600", "f", "p" }, null, "f");
}

test "fifo: attached -m600 form (high finding: was silently ignored)" {
    try diffAgainstGnu(&.{ "-m600", "f", "p" }, null, "f");
}

test "fifo: symbolic mode a=rw (high finding: was silently ignored)" {
    try diffAgainstGnu(&.{ "-m", "a=rw", "f", "p" }, null, "f");
}

test "fifo: symbolic mode u=rwx,g=rx,o=" {
    try diffAgainstGnu(&.{ "-m", "u=rwx,g=rx,o=", "f", "p" }, null, "f");
}

test "fifo: option after operands (getopt permutation)" {
    try diffAgainstGnu(&.{ "f", "p", "-m", "400" }, null, "f");
}

test "fifo: -m consumes a following dash argument as its mode (-w)" {
    try diffAgainstGnu(&.{ "-m", "-w", "f", "p" }, null, "f");
}

test "fifo: -- ends options, creates a dash-named node (medium finding)" {
    try diffAgainstGnu(&.{ "--", "-dash", "p" }, null, "-dash");
}

test "fifo: multi-char TYPE 'pp' accepted (only first char examined)" {
    try diffAgainstGnu(&.{ "f", "pp" }, null, "f");
}

// ---- GNU-diff tests: operand validation ----

test "missing operand: no arguments" {
    try diffAgainstGnu(&.{}, null, null);
}

test "missing operand after NAME" {
    try diffAgainstGnu(&.{"f"}, null, "f");
}

test "char with no device numbers: Special-files hint" {
    try diffAgainstGnu(&.{ "f", "c" }, null, "f");
}

test "block missing minor: missing operand after '1', no hint" {
    try diffAgainstGnu(&.{ "f", "b", "1" }, null, "f");
}

test "fifo with major/minor: extra operand + Fifos hint (medium finding)" {
    try diffAgainstGnu(&.{ "f", "p", "1", "3" }, null, "f");
}

test "fifo with three extras: extra operand, no hint" {
    try diffAgainstGnu(&.{ "f", "p", "1", "3", "9" }, null, "f");
}

test "block with five operands: extra operand '3'" {
    try diffAgainstGnu(&.{ "f", "b", "1", "2", "3" }, null, "f");
}

test "invalid device type" {
    try diffAgainstGnu(&.{ "f", "x", "1", "3" }, null, "f");
}

// ---- GNU-diff tests: device number parsing ----

test "overflowing major: diagnostic, not a panic (high finding)" {
    try diffAgainstGnu(&.{ "f", "c", "99999999999999999999", "0" }, null, "f");
}

test "overflowing minor: diagnostic, not a panic" {
    try diffAgainstGnu(&.{ "f", "c", "0", "99999999999999999999" }, null, "f");
}

test "non-numeric major" {
    try diffAgainstGnu(&.{ "f", "c", "abc", "0" }, null, "f");
}

test "major 4294967296 rejected (one past u32 max)" {
    try diffAgainstGnu(&.{ "f", "c", "4294967296", "0" }, null, "f");
}

test "Darwin NODEV: makedev(255,16777215) == -1 -> invalid device" {
    try diffAgainstGnu(&.{ "f", "c", "255", "16777215" }, null, "f");
}

test "char device as non-root: EPERM diagnostic with reason (low finding)" {
    // As root both create the node; as a user both fail with
    // "Operation not permitted" — either way the outputs must match.
    try diffAgainstGnu(&.{ "f", "c", "1", "3" }, null, null);
}

// ---- GNU-diff tests: mode validation ----

test "invalid mode 999 is a hard error (high finding: was ignored)" {
    try diffAgainstGnu(&.{ "-m", "999", "f", "p" }, null, "f");
}

test "overflowing octal mode: diagnostic, not a panic (high finding)" {
    try diffAgainstGnu(&.{ "-m", "7777777777777777777777", "f", "p" }, null, "f");
}

test "empty --mode= rejected (low finding: created mode 000)" {
    try diffAgainstGnu(&.{ "--mode=", "f", "p" }, null, "f");
}

test "mode parse error beats missing operands (-m bogus, no operands)" {
    try diffAgainstGnu(&.{ "-m", "bogus" }, null, null);
}

test "symbolic setuid rejected: mode must specify only file permission bits" {
    try diffAgainstGnu(&.{ "-m", "u+s", "f", "p" }, null, "f");
}

test "octal setuid rejected" {
    try diffAgainstGnu(&.{ "-m", "4755", "f", "p" }, null, "f");
}

// ---- GNU-diff tests: option errors ----

test "invalid short option (medium finding: was silently swallowed)" {
    try diffAgainstGnu(&.{ "-x", "f", "p" }, null, "f");
}

test "unrecognized long option" {
    try diffAgainstGnu(&.{ "--bogus", "f", "p" }, null, "f");
}

test "trailing -m: option requires an argument (medium finding)" {
    try diffAgainstGnu(&.{ "f", "p", "-m" }, null, "f");
}

test "bare --mode: option '--mode' requires an argument" {
    try diffAgainstGnu(&.{"--mode"}, null, null);
}

// ---- GNU-diff tests: creation errors ----

test "EEXIST: name already exists" {
    try diffAgainstGnu(&.{ "f", "p" }, fixtureFileF, null);
}

test "ENOENT: missing parent directory" {
    try diffAgainstGnu(&.{ "nosuchdir/f", "p" }, null, null);
}

// ---------------------------------------------------------------------------
// Literal tests (run even without a GNU binary installed).
//
// Expected bytes below are exactly what GNU coreutils 9.10 mknod printed
// (LC_ALL=C, macOS, 2026-07-19), with the program name token replaced by
// zmknod's. Exit codes and node modes were observed from the same runs.
// ---------------------------------------------------------------------------

fn runZ(allocator: std.mem.Allocator, args: []const []const u8, cwd: Io.Dir) !RunOutcome {
    return runTool(allocator, zmknod_bin, args, cwd);
}

test "literal: missing operand bytes" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var res = try runZ(allocator, &.{}, tmp.dir);
    defer res.deinit(allocator);
    try testing.expectEqualStrings(
        "zmknod: missing operand\nTry 'zmknod --help' for more information.\n",
        res.stderr,
    );
    try testing.expectEqualStrings("", res.stdout);
    try testing.expectEqual(@as(u8, 1), res.code);
}

test "literal: extra operand + Fifos hint bytes" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var res = try runZ(allocator, &.{ "f", "p", "1", "3" }, tmp.dir);
    defer res.deinit(allocator);
    try testing.expectEqualStrings(
        "zmknod: extra operand '1'\n" ++
            "Fifos do not have major and minor device numbers.\n" ++
            "Try 'zmknod --help' for more information.\n",
        res.stderr,
    );
    try testing.expectEqual(@as(u8, 1), res.code);
    try testing.expectEqual(@as(?NodeStat, null), try statNode(tmp.dir, "f"));
}

test "literal: overflowing major prints GNU diagnostic instead of panicking" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var res = try runZ(allocator, &.{ "f", "b", "99999999999999999999", "0" }, tmp.dir);
    defer res.deinit(allocator);
    try testing.expectEqualStrings(
        "zmknod: invalid major device number '99999999999999999999'\n",
        res.stderr,
    );
    try testing.expectEqual(@as(u8, 1), res.code);
}

test "literal: invalid mode bytes" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var res = try runZ(allocator, &.{ "-m", "999", "f", "p" }, tmp.dir);
    defer res.deinit(allocator);
    try testing.expectEqualStrings("zmknod: invalid mode\n", res.stderr);
    try testing.expectEqual(@as(u8, 1), res.code);
    try testing.expectEqual(@as(?NodeStat, null), try statNode(tmp.dir, "f"));
}

test "literal: -m 600 fifo gets exactly 0600 (gmknod: prw-------)" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var res = try runZ(allocator, &.{ "-m", "600", "f", "p" }, tmp.dir);
    defer res.deinit(allocator);
    try testing.expectEqual(@as(u8, 0), res.code);
    try testing.expectEqualStrings("", res.stderr);
    const st = (try statNode(tmp.dir, "f")).?;
    try testing.expectEqual(@as(u32, 0o010000), st.kind); // S_IFIFO
    try testing.expectEqual(@as(u32, 0o600), st.perm);
}

test "literal: symbolic -m a=rw fifo gets 0666 (gmknod: prw-rw-rw-)" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var res = try runZ(allocator, &.{ "-m", "a=rw", "f", "p" }, tmp.dir);
    defer res.deinit(allocator);
    try testing.expectEqual(@as(u8, 0), res.code);
    const st = (try statNode(tmp.dir, "f")).?;
    try testing.expectEqual(@as(u32, 0o010000), st.kind);
    try testing.expectEqual(@as(u32, 0o666), st.perm);
}

test "literal: default fifo mode is 0666 & ~umask" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const old = umask(0o022);
    defer _ = umask(old);
    var res = try runZ(allocator, &.{ "f", "p" }, tmp.dir);
    defer res.deinit(allocator);
    try testing.expectEqual(@as(u8, 0), res.code);
    const st = (try statNode(tmp.dir, "f")).?;
    try testing.expectEqual(@as(u32, 0o010000), st.kind);
    try testing.expectEqual(@as(u32, 0o644), st.perm); // gmknod: prw-r--r--
}

test "literal: --help goes to stdout, exit 0 (low finding: was stderr)" {
    // GNU coreutils convention (and observed: gmknod --help emits all
    // bytes on stdout, none on stderr, exit 0).
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var res = try runZ(allocator, &.{"--help"}, tmp.dir);
    defer res.deinit(allocator);
    try testing.expectEqual(@as(u8, 0), res.code);
    try testing.expectEqualStrings("", res.stderr);
    try testing.expect(res.stdout.len > 0);
    try testing.expect(std.mem.indexOf(u8, res.stdout, "Usage:") != null);
}

test "literal: --version goes to stdout, exit 0" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var res = try runZ(allocator, &.{"--version"}, tmp.dir);
    defer res.deinit(allocator);
    try testing.expectEqual(@as(u8, 0), res.code);
    try testing.expectEqualStrings("", res.stderr);
    try testing.expect(std.mem.startsWith(u8, res.stdout, "zmknod "));
}

test "gnu binary present on this machine" {
    // Fails (rather than silently skipping every diff test) if the GNU
    // anchor disappears; delete this test only if the suite must run on
    // machines without Homebrew coreutils.
    try testing.expect(findGnuMknod() != null);
}
