//! GNU parity tests for zmkfifo.
//!
//! External anchor: every diff case runs live against the real GNU
//! coreutils `mkfifo` binary (Homebrew gnubin), in identical fixture
//! directories with an identical umask: exit code, stdout, stderr
//! (program-name normalized), and resulting filesystem state (FIFO
//! presence, kind, and permission bits) must all match.
//!
//! A second set of literal tests pins the exact diagnostic bytes and
//! mode results observed from GNU coreutils 9.10 `mkfifo` (LC_ALL=C,
//! macOS, 2026-07-19) so the suite still verifies GNU-documented
//! behavior byte-for-byte on machines without the GNU binary. These
//! are NOT roundtrip tests — expected outputs were captured from the
//! GNU binary, not derived from zmkfifo.

const std = @import("std");
const build_options = @import("build_options");
const testing = std.testing;
const io = testing.io;
const Io = std.Io;

const zmkfifo_bin = build_options.zmkfifo_bin;

extern "c" fn umask(mask: c_uint) c_uint;

const gnu_candidates = [_][]const u8{
    "/opt/homebrew/opt/coreutils/libexec/gnubin/mkfifo",
    "/usr/local/opt/coreutils/libexec/gnubin/mkfifo",
    "/opt/homebrew/bin/gmkfifo",
    "/usr/local/bin/gmkfifo",
};

fn findGnuMkfifo() ?[]const u8 {
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

/// GNU prints its name as argv[0] (full path) in getopt lines and as
/// "mkfifo" in error() lines; zmkfifo prints "zmkfifo" everywhere.
/// Normalize all spellings to the token "mkfifo".
fn normalize(allocator: std.mem.Allocator, output: []const u8, prog_token: []const u8) ![]u8 {
    return std.mem.replaceOwned(u8, allocator, output, prog_token, "mkfifo");
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
/// umask; run GNU mkfifo in one and zmkfifo in the other; require
/// identical exit code + normalized stdout/stderr + identical state
/// for every name in `check_names`.
fn diffAgainstGnu(
    args: []const []const u8,
    umask_value: c_uint,
    setup: ?Fixture,
    check_names: []const []const u8,
) !void {
    const gnu = findGnuMkfifo() orelse return error.SkipZigTest;
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
    var res_z = try runTool(allocator, zmkfifo_bin, args, tmp_z.dir);
    defer res_z.deinit(allocator);

    const gnu_stderr = try normalize(allocator, res_gnu.stderr, gnu);
    defer allocator.free(gnu_stderr);
    const gnu_stdout = try normalize(allocator, res_gnu.stdout, gnu);
    defer allocator.free(gnu_stdout);
    const z_stderr = try normalize(allocator, res_z.stderr, "zmkfifo");
    defer allocator.free(z_stderr);
    const z_stdout = try normalize(allocator, res_z.stdout, "zmkfifo");
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

// ---- GNU-diff tests: creation & modes ----

test "default create: mode 0666 minus umask 022" {
    try diffAgainstGnu(&.{"f"}, 0o022, null, &.{"f"});
}

test "default create under umask 077" {
    try diffAgainstGnu(&.{"f"}, 0o077, null, &.{"f"});
}

test "-m 777 sets the mode EXACTLY despite umask 022 (parity regression)" {
    // Old zmkfifo applied the umask to the explicit mode -> prwxr-xr-x.
    try diffAgainstGnu(&.{ "-m", "777", "f" }, 0o022, null, &.{"f"});
}

test "--mode=0750 exact under umask 022" {
    try diffAgainstGnu(&.{ "--mode=0750", "f" }, 0o022, null, &.{"f"});
}

test "--mode with separate argument" {
    try diffAgainstGnu(&.{ "--mode", "700", "f" }, 0o022, null, &.{"f"});
}

test "attached short form -m0755 (was silently ignored)" {
    try diffAgainstGnu(&.{ "-m0755", "f" }, 0o022, null, &.{"f"});
}

test "-m 0 creates an unreadable fifo" {
    try diffAgainstGnu(&.{ "-m", "0", "f" }, 0o022, null, &.{"f"});
}

test "symbolic mode a=rw" {
    try diffAgainstGnu(&.{ "-m", "a=rw", "f" }, 0o022, null, &.{"f"});
}

test "symbolic mode +x under umask 077 (umask masks no-who clauses)" {
    try diffAgainstGnu(&.{ "-m", "+x", "f" }, 0o077, null, &.{"f"});
}

test "symbolic mode =rwx under umask 077" {
    try diffAgainstGnu(&.{ "-m", "=rwx", "f" }, 0o077, null, &.{"f"});
}

test "symbolic clauses u+x,g-r under umask 077" {
    try diffAgainstGnu(&.{ "-m", "u+x,g-r", "f" }, 0o077, null, &.{"f"});
}

test "symbolic copy g=u" {
    try diffAgainstGnu(&.{ "-m", "g=u", "f" }, 0o022, null, &.{"f"});
}

test "symbolic u= clears user bits" {
    try diffAgainstGnu(&.{ "-m", "u=", "f" }, 0o022, null, &.{"f"});
}

test "symbolic conditional X is a no-op without existing x bits" {
    try diffAgainstGnu(&.{ "-m", "+X", "f" }, 0o022, null, &.{"f"});
}

// ---- GNU-diff tests: mode errors ----

test "invalid mode 999 rejected, nothing created" {
    try diffAgainstGnu(&.{ "-m", "999", "f" }, 0o022, null, &.{"f"});
}

test "huge octal mode rejected (old zmkfifo panicked with integer overflow)" {
    try diffAgainstGnu(&.{ "-m", "7777777777777777777777", "f" }, 0o022, null, &.{"f"});
}

test "setuid mode 4755 rejected: only file permission bits" {
    try diffAgainstGnu(&.{ "-m", "4755", "f" }, 0o022, null, &.{"f"});
}

test "symbolic sticky o+t rejected: only file permission bits" {
    try diffAgainstGnu(&.{ "-m", "o+t", "f" }, 0o022, null, &.{"f"});
}

test "empty mode string rejected" {
    try diffAgainstGnu(&.{ "-m", "", "f" }, 0o022, null, &.{"f"});
}

test "malformed symbolic mode rw rejected" {
    try diffAgainstGnu(&.{ "-m", "rw", "f" }, 0o022, null, &.{"f"});
}

test "missing operand reported before mode validation" {
    try diffAgainstGnu(&.{ "-m", "999" }, 0o022, null, &.{});
}

// ---- GNU-diff tests: option parsing ----

test "no operands: missing operand" {
    try diffAgainstGnu(&.{}, 0o022, null, &.{});
}

test "unknown short option -x rejected (was silently ignored)" {
    try diffAgainstGnu(&.{ "-x", "f" }, 0o022, null, &.{"f"});
}

test "unknown long option rejected" {
    try diffAgainstGnu(&.{ "--frobnicate", "f" }, 0o022, null, &.{"f"});
}

test "-m with no following argument" {
    try diffAgainstGnu(&.{"-m"}, 0o022, null, &.{});
}

test "--mode with no following argument" {
    try diffAgainstGnu(&.{"--mode"}, 0o022, null, &.{});
}

test "-- ends option parsing: dash-prefixed operand created" {
    try diffAgainstGnu(&.{ "--", "-dash" }, 0o022, null, &.{"-dash"});
}

test "lone dash is an operand" {
    try diffAgainstGnu(&.{"-"}, 0o022, null, &.{"-"});
}

test "empty-string operand is attempted and reports ENOENT" {
    try diffAgainstGnu(&.{""}, 0o022, null, &.{});
}

test "options are honored after operands (getopt permutation)" {
    try diffAgainstGnu(&.{ "f", "-m", "700" }, 0o022, null, &.{"f"});
}

test "unambiguous long-option abbreviation --mo=700" {
    try diffAgainstGnu(&.{ "--mo=700", "f" }, 0o022, null, &.{"f"});
}

test "ambiguous long-option abbreviation --=700" {
    try diffAgainstGnu(&.{ "--=700", "f" }, 0o022, null, &.{"f"});
}

test "-Z is accepted as a no-op on non-SELinux kernels" {
    try diffAgainstGnu(&.{ "-Z", "f" }, 0o022, null, &.{"f"});
}

test "-Zm 700 short-option cluster" {
    try diffAgainstGnu(&.{ "-Zm", "700", "f" }, 0o022, null, &.{"f"});
}

test "--context=CTX warns and is otherwise ignored" {
    try diffAgainstGnu(&.{ "--context=foo", "f" }, 0o022, null, &.{"f"});
}

test "bare --context is silently ignored" {
    try diffAgainstGnu(&.{ "--context", "f" }, 0o022, null, &.{"f"});
}

// ---- GNU-diff tests: creation failures & multiple operands ----

test "existing file: EEXIST diagnostic, exit 1" {
    try diffAgainstGnu(&.{"f"}, 0o022, fixtureFileF, &.{"f"});
}

test "path through a non-directory: ENOTDIR diagnostic" {
    try diffAgainstGnu(&.{"f/sub"}, 0o022, fixtureFileF, &.{});
}

test "missing parent directory: ENOENT diagnostic" {
    try diffAgainstGnu(&.{"nodir/sub"}, 0o022, null, &.{});
}

test "multiple operands: failure in the middle still creates the rest, exit 1" {
    try diffAgainstGnu(&.{ "a", "f", "b" }, 0o022, fixtureFileF, &.{ "a", "f", "b" });
}

test "70 operands all created (old zmkfifo silently dropped past 64)" {
    const allocator = testing.allocator;
    var names: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (names.items) |n| allocator.free(n);
        names.deinit(allocator);
    }
    var i: usize = 0;
    while (i < 70) : (i += 1) {
        const name = try std.fmt.allocPrint(allocator, "fifo{d:0>2}", .{i});
        try names.append(allocator, name);
    }
    try diffAgainstGnu(names.items, 0o022, null, names.items);
}

// ---- --help / --version (content deliberately differs from GNU;
//      anchor: GNU writes both to STDOUT and exits 0) ----

test "--help goes to stdout and exits 0" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var res = try runTool(allocator, zmkfifo_bin, &.{"--help"}, tmp.dir);
    defer res.deinit(allocator);
    try testing.expectEqual(@as(u8, 0), res.code);
    try testing.expectEqualStrings("", res.stderr);
    try testing.expect(std.mem.indexOf(u8, res.stdout, "Usage: zmkfifo") != null);
    try testing.expect(std.mem.indexOf(u8, res.stdout, "--mode") != null);
}

test "--version goes to stdout and exits 0" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var res = try runTool(allocator, zmkfifo_bin, &.{"--version"}, tmp.dir);
    defer res.deinit(allocator);
    try testing.expectEqual(@as(u8, 0), res.code);
    try testing.expectEqualStrings("", res.stderr);
    try testing.expect(std.mem.startsWith(u8, res.stdout, "zmkfifo "));
}

// ---- literal anchors (GNU coreutils 9.10 mkfifo, LC_ALL=C, macOS) ----
// Captured from the real binary; kept literal so this suite still pins
// GNU behavior byte-for-byte when no GNU binary is installed.

fn runZ(allocator: std.mem.Allocator, args: []const []const u8, cwd: Io.Dir) !RunOutcome {
    return runTool(allocator, zmkfifo_bin, args, cwd);
}

test "literal: missing operand diagnostic bytes" {
    // GNU: "mkfifo: missing operand\nTry '<argv0> --help' for more information.\n", exit 1
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var res = try runZ(allocator, &.{}, tmp.dir);
    defer res.deinit(allocator);
    try testing.expectEqual(@as(u8, 1), res.code);
    try testing.expectEqualStrings(
        "zmkfifo: missing operand\nTry 'zmkfifo --help' for more information.\n",
        res.stderr,
    );
    try testing.expectEqualStrings("", res.stdout);
}

test "literal: invalid mode diagnostic bytes (no Try line)" {
    // GNU: "mkfifo: invalid mode\n", exit 1, nothing created
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var res = try runZ(allocator, &.{ "-m", "999", "f" }, tmp.dir);
    defer res.deinit(allocator);
    try testing.expectEqual(@as(u8, 1), res.code);
    try testing.expectEqualStrings("zmkfifo: invalid mode\n", res.stderr);
    try testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "f", .{}));
}

test "literal: huge octal mode must NOT crash (overflow regression)" {
    // Old zmkfifo aborted with "thread panic: integer overflow" (exit 134).
    // GNU: "mkfifo: invalid mode\n", exit 1.
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var res = try runZ(allocator, &.{ "-m", "7777777777777777777777", "f" }, tmp.dir);
    defer res.deinit(allocator);
    try testing.expectEqual(@as(u8, 1), res.code);
    try testing.expectEqualStrings("zmkfifo: invalid mode\n", res.stderr);
}

test "literal: non-permission bits diagnostic bytes" {
    // GNU: "mkfifo: mode must specify only file permission bits\n", exit 1
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var res = try runZ(allocator, &.{ "-m", "4755", "f" }, tmp.dir);
    defer res.deinit(allocator);
    try testing.expectEqual(@as(u8, 1), res.code);
    try testing.expectEqualStrings(
        "zmkfifo: mode must specify only file permission bits\n",
        res.stderr,
    );
    try testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "f", .{}));
}

test "literal: option requires an argument -- 'm'" {
    // GNU: "<argv0>: option requires an argument -- 'm'\nTry ...\n", exit 1
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var res = try runZ(allocator, &.{"-m"}, tmp.dir);
    defer res.deinit(allocator);
    try testing.expectEqual(@as(u8, 1), res.code);
    try testing.expectEqualStrings(
        "zmkfifo: option requires an argument -- 'm'\nTry 'zmkfifo --help' for more information.\n",
        res.stderr,
    );
}

test "literal: invalid option -- 'x'" {
    // GNU: "<argv0>: invalid option -- 'x'\nTry ...\n", exit 1
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var res = try runZ(allocator, &.{ "-x", "f" }, tmp.dir);
    defer res.deinit(allocator);
    try testing.expectEqual(@as(u8, 1), res.code);
    try testing.expectEqualStrings(
        "zmkfifo: invalid option -- 'x'\nTry 'zmkfifo --help' for more information.\n",
        res.stderr,
    );
    try testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "f", .{}));
}

test "literal: EEXIST diagnostic bytes" {
    // GNU: "mkfifo: cannot create fifo 'f': File exists\n", exit 1
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try fixtureFileF(tmp.dir);
    var res = try runZ(allocator, &.{"f"}, tmp.dir);
    defer res.deinit(allocator);
    try testing.expectEqual(@as(u8, 1), res.code);
    try testing.expectEqualStrings(
        "zmkfifo: cannot create fifo 'f': File exists\n",
        res.stderr,
    );
}

test "literal: -m 777 under umask 022 yields exactly 0777 (GNU parity fix)" {
    // GNU doc (coreutils manual, mkfifo invocation): with -m the mode is
    // set exactly; observed prwxrwxrwx from GNU 9.10 under umask 022.
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const saved = umask(0o022);
    defer _ = umask(saved);
    var res = try runZ(allocator, &.{ "-m", "777", "f" }, tmp.dir);
    defer res.deinit(allocator);
    try testing.expectEqual(@as(u8, 0), res.code);
    const st = try tmp.dir.statFile(io, "f", .{});
    try testing.expectEqual(Io.File.Kind.named_pipe, st.kind);
    try testing.expectEqual(@as(u32, 0o777), @as(u32, @intCast(st.permissions.toMode() & 0o7777)));
}

test "literal: default create under umask 022 yields 0644" {
    // GNU passes 0666 and lets the kernel apply the umask: prw-r--r--.
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const saved = umask(0o022);
    defer _ = umask(saved);
    var res = try runZ(allocator, &.{"f"}, tmp.dir);
    defer res.deinit(allocator);
    try testing.expectEqual(@as(u8, 0), res.code);
    const st = try tmp.dir.statFile(io, "f", .{});
    try testing.expectEqual(Io.File.Kind.named_pipe, st.kind);
    try testing.expectEqual(@as(u32, 0o644), @as(u32, @intCast(st.permissions.toMode() & 0o7777)));
}
