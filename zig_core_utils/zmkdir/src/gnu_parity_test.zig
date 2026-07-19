//! GNU parity tests for zmkdir.
//!
//! External anchor: every diff case runs live against the real GNU
//! coreutils `mkdir` binary (Homebrew gnubin), in identical fixture
//! directories with an identical umask: exit code, stdout, stderr
//! (program-name normalized), and resulting filesystem state (entry
//! presence, kind, and permission bits) must all match.
//!
//! A second set of literal tests pins the exact diagnostic bytes and
//! mode results observed from GNU coreutils 9.10 `mkdir` (LC_ALL=C,
//! macOS, 2026-07-19) so the suite still verifies GNU-documented
//! behavior byte-for-byte on machines without the GNU binary. These
//! are NOT roundtrip tests — expected outputs were captured from the
//! GNU binary, not derived from zmkdir.

const std = @import("std");
const build_options = @import("build_options");
const testing = std.testing;
const io = testing.io;
const Io = std.Io;

const zmkdir_bin = build_options.zmkdir_bin;

extern "c" fn umask(mask: c_uint) c_uint;

const gnu_candidates = [_][]const u8{
    "/opt/homebrew/opt/coreutils/libexec/gnubin/mkdir",
    "/usr/local/opt/coreutils/libexec/gnubin/mkdir",
    "/opt/homebrew/bin/gmkdir",
    "/usr/local/bin/gmkdir",
};

fn findGnuMkdir() ?[]const u8 {
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
            return error.ChildCrashed; // e.g. the old integer-overflow abort
        },
    };
    return .{ .code = code, .stdout = result.stdout, .stderr = result.stderr };
}

/// GNU prints its name as argv[0] (full path) in getopt/verbose lines and
/// as "mkdir" in error() lines; zmkdir prints "zmkdir" everywhere.
/// Normalize all spellings to the token "mkdir".
fn normalize(allocator: std.mem.Allocator, output: []const u8, prog_token: []const u8) ![]u8 {
    return std.mem.replaceOwned(u8, allocator, output, prog_token, "mkdir");
}

/// Compare the post-state of one name in the two fixture dirs: both
/// missing, or both present with the same kind and permission bits.
fn expectSameEntry(gnu_dir: Io.Dir, z_dir: Io.Dir, name: []const u8) !void {
    const g = gnu_dir.statFile(io, name, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            try testing.expectError(error.FileNotFound, z_dir.statFile(io, name, .{}));
            return;
        },
        else => return err,
    };
    const z = try z_dir.statFile(io, name, .{});
    try testing.expectEqual(g.kind, z.kind);
    try testing.expectEqual(
        g.permissions.toMode() & 0o7777,
        z.permissions.toMode() & 0o7777,
    );
}

const Fixture = *const fn (dir: Io.Dir) anyerror!void;

/// Core harness: identical fixtures in two temp dirs and an identical
/// umask; run GNU mkdir in one and zmkdir in the other; require
/// identical exit code + normalized stdout/stderr + identical state
/// for every name in `check_names`.
fn diffAgainstGnu(
    args: []const []const u8,
    umask_value: c_uint,
    setup: ?Fixture,
    check_names: []const []const u8,
) !void {
    const gnu = findGnuMkdir() orelse return error.SkipZigTest;
    const allocator = testing.allocator;

    var tmp_gnu = testing.tmpDir(.{});
    defer tmp_gnu.cleanup();
    var tmp_z = testing.tmpDir(.{});
    defer tmp_z.cleanup();

    if (setup) |s| {
        try s(tmp_gnu.dir);
        try s(tmp_z.dir);
    }

    // The default test runner executes tests serially, so mutating the
    // process umask (inherited by the children) is safe here.
    const saved_umask = umask(umask_value);
    defer _ = umask(saved_umask);

    var res_gnu = try runTool(allocator, gnu, args, tmp_gnu.dir);
    defer res_gnu.deinit(allocator);
    var res_z = try runTool(allocator, zmkdir_bin, args, tmp_z.dir);
    defer res_z.deinit(allocator);

    const gnu_stderr = try normalize(allocator, res_gnu.stderr, gnu);
    defer allocator.free(gnu_stderr);
    const gnu_stdout = try normalize(allocator, res_gnu.stdout, gnu);
    defer allocator.free(gnu_stdout);
    const z_stderr = try normalize(allocator, res_z.stderr, "zmkdir");
    defer allocator.free(z_stderr);
    const z_stdout = try normalize(allocator, res_z.stdout, "zmkdir");
    defer allocator.free(z_stdout);

    try testing.expectEqualStrings(gnu_stderr, z_stderr);
    try testing.expectEqualStrings(gnu_stdout, z_stdout);
    try testing.expectEqual(res_gnu.code, res_z.code);

    for (check_names) |name| {
        try expectSameEntry(tmp_gnu.dir, tmp_z.dir, name);
    }
}

// ---- fixtures ----

fn fixtureFileF(dir: Io.Dir) anyerror!void {
    try dir.writeFile(io, .{ .sub_path = "f", .data = "existing\n" });
}

fn fixtureDirD(dir: Io.Dir) anyerror!void {
    try dir.makeDir(io, "d");
}

fn fixtureDirPv1(dir: Io.Dir) anyerror!void {
    try dir.makeDir(io, "pv1");
}

fn fixtureSymlinks(dir: Io.Dir) anyerror!void {
    try dir.makeDir(io, "d");
    try dir.writeFile(io, .{ .sub_path = "f", .data = "existing\n" });
    try dir.symLink(io, "d", "symdir", .{});
    try dir.symLink(io, "f", "symfile", .{});
}

// ---- GNU-diff tests: creation & modes ----

test "default create: mode 0777 minus umask 022" {
    try diffAgainstGnu(&.{"d"}, 0o022, null, &.{"d"});
}

test "default create under umask 077" {
    try diffAgainstGnu(&.{"d"}, 0o077, null, &.{"d"});
}

test "-m 777 sets the mode EXACTLY despite umask 022 (parity regression)" {
    // Old zmkdir let the kernel apply the umask -> drwxr-xr-x.
    try diffAgainstGnu(&.{ "-m", "777", "d" }, 0o022, null, &.{"d"});
}

test "--mode=0750 exact under umask 022" {
    try diffAgainstGnu(&.{ "--mode=0750", "d" }, 0o022, null, &.{"d"});
}

test "--mode with separate argument" {
    try diffAgainstGnu(&.{ "--mode", "700", "d" }, 0o022, null, &.{"d"});
}

test "attached short form -m0755" {
    try diffAgainstGnu(&.{ "-m0755", "d" }, 0o022, null, &.{"d"});
}

test "-m 0 creates an unenterable directory" {
    try diffAgainstGnu(&.{ "-m", "0", "d" }, 0o022, null, &.{"d"});
}

test "-m 4755 sets setuid on the directory (special bits allowed)" {
    try diffAgainstGnu(&.{ "-m", "4755", "d" }, 0o022, null, &.{"d"});
}

test "-m 1777 sets the sticky bit" {
    try diffAgainstGnu(&.{ "-m", "1777", "d" }, 0o022, null, &.{"d"});
}

test "symbolic mode u=rwx,go=rx" {
    try diffAgainstGnu(&.{ "-m", "u=rwx,go=rx", "d" }, 0o022, null, &.{"d"});
}

test "symbolic mode +x under umask 077 starts from a=rwx" {
    try diffAgainstGnu(&.{ "-m", "+x", "d" }, 0o077, null, &.{"d"});
}

test "symbolic u=,+x: no-who clause masked by umask 022" {
    try diffAgainstGnu(&.{ "-m", "u=,+x", "d" }, 0o022, null, &.{"d"});
}

test "symbolic conditional X always applies to a directory" {
    try diffAgainstGnu(&.{ "-m", "u=,u+X", "d" }, 0o022, null, &.{"d"});
}

test "symbolic copy g=u" {
    try diffAgainstGnu(&.{ "-m", "g=u", "d" }, 0o022, null, &.{"d"});
}

test "symbolic clauses u+w,go-r" {
    try diffAgainstGnu(&.{ "-m", "u+w,go-r", "d" }, 0o022, null, &.{"d"});
}

test "symbolic sticky o+t allowed on directories" {
    try diffAgainstGnu(&.{ "-m", "o+t", "d" }, 0o022, null, &.{"d"});
}

// ---- GNU-diff tests: mode errors ----

test "invalid mode 999 rejected, nothing created" {
    try diffAgainstGnu(&.{ "-m", "999", "d" }, 0o022, null, &.{"d"});
}

test "huge octal mode rejected (old zmkdir panicked with integer overflow)" {
    try diffAgainstGnu(&.{ "-m", "77777777777777", "d" }, 0o022, null, &.{"d"});
}

test "mode 777777 rejected (old zmkdir panicked at @intCast to mode_t)" {
    try diffAgainstGnu(&.{ "-m", "777777", "d" }, 0o022, null, &.{"d"});
}

test "empty mode string rejected" {
    try diffAgainstGnu(&.{ "-m", "", "d" }, 0o022, null, &.{"d"});
}

test "malformed symbolic mode rw rejected" {
    try diffAgainstGnu(&.{ "-m", "rw", "d" }, 0o022, null, &.{"d"});
}

test "missing operand reported before mode validation" {
    try diffAgainstGnu(&.{ "-m", "999" }, 0o022, null, &.{});
}

// ---- GNU-diff tests: option parsing ----

test "no operands: missing operand" {
    try diffAgainstGnu(&.{}, 0o022, null, &.{});
}

test "unknown short option -x rejected" {
    try diffAgainstGnu(&.{ "-x", "d" }, 0o022, null, &.{"d"});
}

test "unknown long option rejected" {
    try diffAgainstGnu(&.{ "--frobnicate", "d" }, 0o022, null, &.{"d"});
}

test "-m with no following argument" {
    try diffAgainstGnu(&.{"-m"}, 0o022, null, &.{});
}

test "--mode with no following argument" {
    try diffAgainstGnu(&.{"--mode"}, 0o022, null, &.{});
}

test "-- ends option parsing: dash-prefixed operand created" {
    try diffAgainstGnu(&.{ "--", "-p" }, 0o022, null, &.{"-p"});
}

test "lone dash is an operand (was hard-rejected)" {
    try diffAgainstGnu(&.{"-"}, 0o022, null, &.{"-"});
}

test "empty-string operand is attempted and reports ENOENT" {
    try diffAgainstGnu(&.{""}, 0o022, null, &.{});
}

test "options are honored after operands (getopt permutation)" {
    try diffAgainstGnu(&.{ "d", "-m", "700" }, 0o022, null, &.{"d"});
}

test "short cluster -pv" {
    try diffAgainstGnu(&.{ "-pv", "a/b" }, 0o022, null, &.{ "a", "a/b" });
}

test "unambiguous long-option abbreviation --par" {
    try diffAgainstGnu(&.{ "--par", "a/b" }, 0o022, null, &.{ "a", "a/b" });
}

test "unambiguous long-option abbreviation --verb prints verbose line" {
    try diffAgainstGnu(&.{ "--verb", "d" }, 0o022, null, &.{"d"});
}

test "unambiguous long-option abbreviation --m consumes an argument" {
    try diffAgainstGnu(&.{ "--m", "700", "d" }, 0o022, null, &.{"d"});
}

test "ambiguous long-option abbreviation --v" {
    try diffAgainstGnu(&.{ "--v", "d" }, 0o022, null, &.{"d"});
}

test "ambiguous long-option abbreviation --v=1 keeps the value in the message" {
    try diffAgainstGnu(&.{ "--v=1", "d" }, 0o022, null, &.{"d"});
}

test "ambiguous long-option abbreviation --=700 lists all options" {
    try diffAgainstGnu(&.{ "--=700", "d" }, 0o022, null, &.{"d"});
}

test "no-argument long option rejects a value: --parents=x" {
    try diffAgainstGnu(&.{ "--parents=x", "d" }, 0o022, null, &.{"d"});
}

test "-Z is accepted as a no-op on non-SELinux kernels" {
    try diffAgainstGnu(&.{ "-Z", "d" }, 0o022, null, &.{"d"});
}

test "-Zm 700 short-option cluster" {
    try diffAgainstGnu(&.{ "-Zm", "700", "d" }, 0o022, null, &.{"d"});
}

test "--context=CTX warns and is otherwise ignored" {
    try diffAgainstGnu(&.{ "--context=foo", "d" }, 0o022, null, &.{"d"});
}

test "bare --context is silently ignored and does not eat the operand" {
    try diffAgainstGnu(&.{ "--context", "d" }, 0o022, null, &.{"d"});
}

// ---- GNU-diff tests: creation failures & errno diagnostics ----

test "existing directory: File exists, exit 1" {
    try diffAgainstGnu(&.{"d"}, 0o022, fixtureDirD, &.{"d"});
}

test "existing file: File exists" {
    try diffAgainstGnu(&.{"f"}, 0o022, fixtureFileF, &.{"f"});
}

test "path through a non-directory: Not a directory" {
    try diffAgainstGnu(&.{"f/sub"}, 0o022, fixtureFileF, &.{});
}

test "missing parent directory: No such file or directory" {
    try diffAgainstGnu(&.{"nodir/sub"}, 0o022, null, &.{});
}

test "multiple operands: failure in the middle still creates the rest, exit 1" {
    try diffAgainstGnu(&.{ "a", "f", "b" }, 0o022, fixtureFileF, &.{ "a", "f", "b" });
}

test "trailing slash on a plain create" {
    try diffAgainstGnu(&.{"d/"}, 0o022, null, &.{"d"});
}

// ---- GNU-diff tests: -p / --parents ----

test "-p creates the whole chain with default modes" {
    try diffAgainstGnu(&.{ "-p", "a/b/c" }, 0o022, null, &.{ "a", "a/b", "a/b/c" });
}

test "-p existing directory succeeds silently" {
    try diffAgainstGnu(&.{ "-p", "d" }, 0o022, fixtureDirD, &.{"d"});
}

test "-p existing file: File exists" {
    try diffAgainstGnu(&.{ "-p", "f" }, 0o022, fixtureFileF, &.{"f"});
}

test "-p through a file names the offending ancestor: Not a directory" {
    try diffAgainstGnu(&.{ "-p", "f/sub" }, 0o022, fixtureFileF, &.{});
}

test "-p -m 700: ancestors keep default mode, final gets 700" {
    try diffAgainstGnu(&.{ "-p", "-m", "700", "a/b" }, 0o022, null, &.{ "a", "a/b" });
}

test "-p -m 4755: special bits only on the final directory" {
    try diffAgainstGnu(&.{ "-p", "-m", "4755", "a/b" }, 0o022, null, &.{ "a", "a/b" });
}

test "-p -m 700 does NOT chmod an already-existing final directory" {
    try diffAgainstGnu(&.{ "-p", "-m", "700", "d" }, 0o022, fixtureDirD, &.{"d"});
}

test "-p under restrictive umask 0377: ancestors get u+wx (parity regression)" {
    // Old zmkdir let the umask strip u+wx from intermediates, so creating
    // the child then failed; GNU guarantees traversable ancestors.
    try diffAgainstGnu(&.{ "-p", "a/b" }, 0o377, null, &.{ "a", "a/b" });
}

test "-p collapses repeated slashes" {
    try diffAgainstGnu(&.{ "-p", "a//b///c" }, 0o022, null, &.{ "a", "a/b", "a/b/c" });
}

test "-p trailing slash: final component still gets the -m mode" {
    try diffAgainstGnu(&.{ "-p", "-m", "700", "a/b/" }, 0o022, null, &.{ "a", "a/b" });
}

test "-p ." {
    try diffAgainstGnu(&.{ "-p", "." }, 0o022, null, &.{});
}

test "-p symlink to a directory succeeds" {
    try diffAgainstGnu(&.{ "-p", "symdir" }, 0o022, fixtureSymlinks, &.{"d"});
}

test "-p symlink to a file: File exists" {
    try diffAgainstGnu(&.{ "-p", "symfile" }, 0o022, fixtureSymlinks, &.{"f"});
}

test "-pv prints one line per actually-created directory" {
    try diffAgainstGnu(&.{ "-pv", "pv1/pv2" }, 0o022, fixtureDirPv1, &.{ "pv1", "pv1/pv2" });
}

test "-v prints created directory" {
    try diffAgainstGnu(&.{ "-v", "d" }, 0o022, null, &.{"d"});
}

test "-v -m 750" {
    try diffAgainstGnu(&.{ "-v", "-m", "750", "d" }, 0o022, null, &.{"d"});
}

// ---- --help / --version (content deliberately differs from GNU;
//      anchor: GNU writes both to STDOUT and exits 0) ----

test "--help goes to stdout and exits 0" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var res = try runTool(allocator, zmkdir_bin, &.{"--help"}, tmp.dir);
    defer res.deinit(allocator);
    try testing.expectEqual(@as(u8, 0), res.code);
    try testing.expectEqualStrings("", res.stderr);
    try testing.expect(std.mem.indexOf(u8, res.stdout, "Usage: zmkdir") != null);
    try testing.expect(std.mem.indexOf(u8, res.stdout, "--parents") != null);
}

test "--version goes to stdout and exits 0" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var res = try runTool(allocator, zmkdir_bin, &.{"--version"}, tmp.dir);
    defer res.deinit(allocator);
    try testing.expectEqual(@as(u8, 0), res.code);
    try testing.expectEqualStrings("", res.stderr);
    try testing.expect(std.mem.startsWith(u8, res.stdout, "zmkdir "));
}

// ---- literal anchors (GNU coreutils 9.10 mkdir, LC_ALL=C, macOS) ----
// Captured from the real binary; kept literal so this suite still pins
// GNU behavior byte-for-byte when no GNU binary is installed.

fn runZ(allocator: std.mem.Allocator, args: []const []const u8, cwd: Io.Dir) !RunOutcome {
    return runTool(allocator, zmkdir_bin, args, cwd);
}

test "literal: missing operand diagnostic bytes" {
    // GNU: "mkdir: missing operand\nTry '<argv0> --help' for more information.\n", exit 1
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var res = try runZ(allocator, &.{}, tmp.dir);
    defer res.deinit(allocator);
    try testing.expectEqual(@as(u8, 1), res.code);
    try testing.expectEqualStrings(
        "zmkdir: missing operand\nTry 'zmkdir --help' for more information.\n",
        res.stderr,
    );
    try testing.expectEqualStrings("", res.stdout);
}

test "literal: invalid mode diagnostic includes the mode string" {
    // GNU: "mkdir: invalid mode '999'\n", exit 1, nothing created
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var res = try runZ(allocator, &.{ "-m", "999", "d" }, tmp.dir);
    defer res.deinit(allocator);
    try testing.expectEqual(@as(u8, 1), res.code);
    try testing.expectEqualStrings("zmkdir: invalid mode '999'\n", res.stderr);
    try testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "d", .{}));
}

test "literal: huge octal mode must NOT crash (overflow regression)" {
    // Old zmkdir aborted with "thread panic: integer overflow" (exit 134).
    // GNU: "mkdir: invalid mode '77777777777777'\n", exit 1.
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var res = try runZ(allocator, &.{ "-m", "77777777777777", "d" }, tmp.dir);
    defer res.deinit(allocator);
    try testing.expectEqual(@as(u8, 1), res.code);
    try testing.expectEqualStrings("zmkdir: invalid mode '77777777777777'\n", res.stderr);
}

test "literal: mode 777777 must NOT crash (@intCast regression)" {
    // Old zmkdir aborted with "integer does not fit in destination type".
    // GNU: "mkdir: invalid mode '777777'\n", exit 1.
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var res = try runZ(allocator, &.{ "-m", "777777", "d" }, tmp.dir);
    defer res.deinit(allocator);
    try testing.expectEqual(@as(u8, 1), res.code);
    try testing.expectEqualStrings("zmkdir: invalid mode '777777'\n", res.stderr);
}

test "literal: EEXIST diagnostic bytes (was error.Unknown)" {
    // GNU: "mkdir: cannot create directory 'd': File exists\n", exit 1
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makeDir(io, "d");
    var res = try runZ(allocator, &.{"d"}, tmp.dir);
    defer res.deinit(allocator);
    try testing.expectEqual(@as(u8, 1), res.code);
    try testing.expectEqualStrings(
        "zmkdir: cannot create directory 'd': File exists\n",
        res.stderr,
    );
}

test "literal: ENOENT diagnostic bytes (was error.Unknown)" {
    // GNU: "mkdir: cannot create directory 'nodir/sub': No such file or directory\n"
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var res = try runZ(allocator, &.{"nodir/sub"}, tmp.dir);
    defer res.deinit(allocator);
    try testing.expectEqual(@as(u8, 1), res.code);
    try testing.expectEqualStrings(
        "zmkdir: cannot create directory 'nodir/sub': No such file or directory\n",
        res.stderr,
    );
}

test "literal: ENOTDIR diagnostic bytes (was error.Unknown)" {
    // GNU: "mkdir: cannot create directory 'f/sub': Not a directory\n"
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "f", .data = "x" });
    var res = try runZ(allocator, &.{"f/sub"}, tmp.dir);
    defer res.deinit(allocator);
    try testing.expectEqual(@as(u8, 1), res.code);
    try testing.expectEqualStrings(
        "zmkdir: cannot create directory 'f/sub': Not a directory\n",
        res.stderr,
    );
}

test "literal: option requires an argument -- 'm'" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var res = try runZ(allocator, &.{"-m"}, tmp.dir);
    defer res.deinit(allocator);
    try testing.expectEqual(@as(u8, 1), res.code);
    try testing.expectEqualStrings(
        "zmkdir: option requires an argument -- 'm'\nTry 'zmkdir --help' for more information.\n",
        res.stderr,
    );
}

test "literal: invalid option -- 'x'" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var res = try runZ(allocator, &.{ "-x", "d" }, tmp.dir);
    defer res.deinit(allocator);
    try testing.expectEqual(@as(u8, 1), res.code);
    try testing.expectEqualStrings(
        "zmkdir: invalid option -- 'x'\nTry 'zmkdir --help' for more information.\n",
        res.stderr,
    );
    try testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "d", .{}));
}

test "literal: ambiguous --v lists only verbose and version" {
    // GNU: "<argv0>: option '--v' is ambiguous; possibilities: '--verbose' '--version'\n"
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var res = try runZ(allocator, &.{ "--v", "d" }, tmp.dir);
    defer res.deinit(allocator);
    try testing.expectEqual(@as(u8, 1), res.code);
    try testing.expectEqualStrings(
        "zmkdir: option '--v' is ambiguous; possibilities: '--verbose' '--version'\n" ++
            "Try 'zmkdir --help' for more information.\n",
        res.stderr,
    );
}

test "literal: -m 777 under umask 022 yields exactly 0777 (GNU parity fix)" {
    // GNU doc (coreutils manual, mkdir invocation): with -m the mode is
    // set exactly; observed drwxrwxrwx from GNU 9.10 under umask 022.
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const saved = umask(0o022);
    defer _ = umask(saved);
    var res = try runZ(allocator, &.{ "-m", "777", "d" }, tmp.dir);
    defer res.deinit(allocator);
    try testing.expectEqual(@as(u8, 0), res.code);
    const st = try tmp.dir.statFile(io, "d", .{});
    try testing.expectEqual(Io.File.Kind.directory, st.kind);
    try testing.expectEqual(@as(u32, 0o777), @as(u32, @intCast(st.permissions.toMode() & 0o7777)));
}

test "literal: default create under umask 022 yields 0755" {
    // GNU passes 0777 and lets the umask apply: drwxr-xr-x.
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const saved = umask(0o022);
    defer _ = umask(saved);
    var res = try runZ(allocator, &.{"d"}, tmp.dir);
    defer res.deinit(allocator);
    try testing.expectEqual(@as(u8, 0), res.code);
    const st = try tmp.dir.statFile(io, "d", .{});
    try testing.expectEqual(Io.File.Kind.directory, st.kind);
    try testing.expectEqual(@as(u32, 0o755), @as(u32, @intCast(st.permissions.toMode() & 0o7777)));
}

test "literal: -p tolerates a directory that already exists mid-chain (race fix)" {
    // Old zmkdir pre-scanned with access() and treated a later EEXIST as
    // error.Unknown, so a concurrent creator made `-p` fail; GNU exits 0.
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makeDir(io, "a");
    try tmp.dir.makeDir(io, "a/b");
    var res = try runZ(allocator, &.{ "-p", "a/b/c" }, tmp.dir);
    defer res.deinit(allocator);
    try testing.expectEqual(@as(u8, 0), res.code);
    try testing.expectEqualStrings("", res.stderr);
    const st = try tmp.dir.statFile(io, "a/b/c", .{});
    try testing.expectEqual(Io.File.Kind.directory, st.kind);
}

test "literal: -p under umask 0377 creates traversable ancestors (GNU behavior)" {
    // GNU manual (mkdir invocation): parent directories are created with
    // u+wx regardless of umask. Observed: 'a' -> drwx------, 'a/b' -> dr--------.
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const saved = umask(0o377);
    defer _ = umask(saved);
    var res = try runZ(allocator, &.{ "-p", "a/b" }, tmp.dir);
    defer res.deinit(allocator);
    try testing.expectEqual(@as(u8, 0), res.code);
    try testing.expectEqualStrings("", res.stderr);
    const a = try tmp.dir.statFile(io, "a", .{});
    try testing.expectEqual(@as(u32, 0o700), @as(u32, @intCast(a.permissions.toMode() & 0o7777)));
    const b = try tmp.dir.statFile(io, "a/b", .{});
    try testing.expectEqual(@as(u32, 0o400), @as(u32, @intCast(b.permissions.toMode() & 0o7777)));
}

test "literal: verbose line bytes on stdout" {
    // GNU: "<argv0>: created directory 'd'\n" on STDOUT, exit 0.
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var res = try runZ(allocator, &.{ "-v", "d" }, tmp.dir);
    defer res.deinit(allocator);
    try testing.expectEqual(@as(u8, 0), res.code);
    try testing.expectEqualStrings("", res.stderr);
    try testing.expectEqualStrings("zmkdir: created directory 'd'\n", res.stdout);
}

test "literal: lone dash creates a directory named '-' (was rejected)" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var res = try runZ(allocator, &.{"-"}, tmp.dir);
    defer res.deinit(allocator);
    try testing.expectEqual(@as(u8, 0), res.code);
    try testing.expectEqualStrings("", res.stderr);
    const st = try tmp.dir.statFile(io, "-", .{});
    try testing.expectEqual(Io.File.Kind.directory, st.kind);
}
