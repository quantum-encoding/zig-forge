//! Externally-anchored GNU parity tests for `zid`.
//!
//! The external anchor is the REAL GNU coreutils `id` binary (verified 9.10,
//! `/opt/homebrew/bin/gid`). For each representative invocation we run BOTH
//! `zid` and GNU `id` on THIS machine and assert byte-for-byte agreement on
//! stdout (or raw bytes, for NUL-delimited modes) and identical exit codes.
//! GNU is the oracle: none of the expected bytes were written by the author.
//!
//! For a handful of error paths where GNU's message text carries its own
//! program name ("id:" vs "zid:") we anchor on GNU's EXIT CODE plus the
//! documented, program-name-independent phrase (from coreutils' id.c), which is
//! quoted literally here with its source.
//!
//! Paths are injected by build.zig (`build_options`) so the test runs against
//! the freshly-installed binary. If GNU `id` is not present the tests are
//! skipped (they cannot anchor without the oracle).

const std = @import("std");
const build_options = @import("build_options");

const zid_path = build_options.zid_path;
const gid_path = build_options.gid_path;

const RunOut = struct {
    stdout: []u8,
    stderr: []u8,
    code: ?u8, // null => terminated by signal / not Exited

    fn deinit(self: RunOut, a: std.mem.Allocator) void {
        a.free(self.stdout);
        a.free(self.stderr);
    }
};

fn runCmd(a: std.mem.Allocator, argv: []const []const u8) !RunOut {
    var threaded: std.Io.Threaded = .init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const res = try std.process.run(a, io, .{
        .argv = argv,
        .stdout_limit = .limited(1 << 20),
        .stderr_limit = .limited(1 << 20),
    });
    const code: ?u8 = switch (res.term) {
        .exited => |c| c,
        else => null,
    };
    return .{ .stdout = res.stdout, .stderr = res.stderr, .code = code };
}

fn gnuAvailable(a: std.mem.Allocator) bool {
    var threaded: std.Io.Threaded = .init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    std.Io.Dir.accessAbsolute(io, gid_path, .{}) catch return false;
    return true;
}

/// Build argv = [bin, flags...] for one of the two binaries.
fn buildArgv(a: std.mem.Allocator, bin: []const u8, flags: []const []const u8) ![]const []const u8 {
    var list = try a.alloc([]const u8, flags.len + 1);
    list[0] = bin;
    for (flags, 0..) |f, i| list[i + 1] = f;
    return list;
}

/// Assert zid and GNU id produce identical stdout and identical exit codes.
fn expectStdoutParity(flags: []const []const u8) !void {
    const a = std.testing.allocator;
    if (!gnuAvailable(a)) return error.SkipZigTest;

    const zargv = try buildArgv(a, zid_path, flags);
    defer a.free(zargv);
    const gargv = try buildArgv(a, gid_path, flags);
    defer a.free(gargv);

    const z = try runCmd(a, zargv);
    defer z.deinit(a);
    const g = try runCmd(a, gargv);
    defer g.deinit(a);

    std.testing.expectEqualSlices(u8, g.stdout, z.stdout) catch |e| {
        std.debug.print("STDOUT PARITY MISMATCH ({d} flag(s))\n GNU: [{s}]\n zid: [{s}]\n", .{ flags.len, g.stdout, z.stdout });
        return e;
    };
    try std.testing.expectEqual(g.code, z.code);
}

/// For error paths: assert zid exits with the SAME code as GNU and that its
/// stderr contains the documented (program-name-independent) phrase.
fn expectErrorParity(flags: []const []const u8, phrase: []const u8) !void {
    const a = std.testing.allocator;
    if (!gnuAvailable(a)) return error.SkipZigTest;

    const zargv = try buildArgv(a, zid_path, flags);
    defer a.free(zargv);
    const gargv = try buildArgv(a, gid_path, flags);
    defer a.free(gargv);

    const z = try runCmd(a, zargv);
    defer z.deinit(a);
    const g = try runCmd(a, gargv);
    defer g.deinit(a);

    // GNU must actually be erroring on this input (guards against the test
    // going stale if GNU changes its mind about a combo).
    try std.testing.expectEqual(@as(?u8, 1), g.code);
    try std.testing.expectEqual(g.code, z.code);
    if (std.mem.indexOf(u8, z.stderr, phrase) == null) {
        std.debug.print("stderr [{s}] missing phrase [{s}]\n", .{ z.stderr, phrase });
        return error.PhraseMissing;
    }
    // The phrase is GNU's own — confirm GNU emits it too (anchor check).
    try std.testing.expect(std.mem.indexOf(u8, g.stderr, phrase) != null);
}

// ---- stdout parity: the core "same machine, same answer" anchor ----------

test "parity: -u effective uid" {
    try expectStdoutParity(&.{"-u"});
}
test "parity: -un effective username" {
    try expectStdoutParity(&.{"-un"});
}
test "parity: -g effective gid" {
    try expectStdoutParity(&.{"-g"});
}
test "parity: -gn effective group name" {
    try expectStdoutParity(&.{"-gn"});
}
test "parity: -G all group ids" {
    try expectStdoutParity(&.{"-G"});
}
test "parity: -Gn all group names" {
    try expectStdoutParity(&.{"-Gn"});
}
test "parity: -r -u real uid" {
    try expectStdoutParity(&.{ "-r", "-u" });
}
test "parity: full default format (current user)" {
    try expectStdoutParity(&.{});
}
test "parity: full info for root operand" {
    try expectStdoutParity(&.{"root"});
}
test "parity: -u for root operand" {
    try expectStdoutParity(&.{ "-u", "root" });
}
test "parity: -G for root operand" {
    // Exercises the getgrouplist() path that the OOB fix hardened.
    try expectStdoutParity(&.{ "-G", "root" });
}
test "parity: -Gn for root operand" {
    try expectStdoutParity(&.{ "-Gn", "root" });
}
test "parity: multiple USER operands prints a block each" {
    // Pre-fix zid honored only the last operand.
    try expectStdoutParity(&.{ "root", "daemon" });
}

// ---- NUL-delimited (-z) modes: raw-byte parity, incl. trailing terminator --

test "parity: -z -u trailing NUL terminator" {
    // Anchors the -z fix: GNU terminates (not separates) with NUL.
    try expectStdoutParity(&.{ "-z", "-u" });
}
test "parity: -z -g trailing NUL terminator" {
    try expectStdoutParity(&.{ "-z", "-g" });
}
test "parity: -z -G every entry NUL-terminated" {
    try expectStdoutParity(&.{ "-z", "-G" });
}

// ---- error-path parity (exit code + documented phrase) --------------------
// Phrases are copied verbatim from GNU coreutils src/id.c.

test "parity: -u -g is mutually exclusive" {
    try expectErrorParity(&.{ "-u", "-g" }, "cannot print \"only\" of more than one choice");
}
test "parity: -n without selector errors" {
    try expectErrorParity(&.{"-n"}, "printing only names or real IDs requires -u, -g, or -G");
}
test "parity: -r without selector errors" {
    try expectErrorParity(&.{"-r"}, "printing only names or real IDs requires -u, -g, or -G");
}
test "parity: -z in default format errors" {
    try expectErrorParity(&.{"-z"}, "option --zero not permitted in default format");
}
test "parity: -Z on non-SELinux kernel errors" {
    try expectErrorParity(&.{"-Z"}, "SELinux");
}
test "parity: unknown user exits 1" {
    const a = std.testing.allocator;
    if (!gnuAvailable(a)) return error.SkipZigTest;
    const flags = &[_][]const u8{"zzz_no_such_user_zzz"};
    const zargv = try buildArgv(a, zid_path, flags);
    defer a.free(zargv);
    const gargv = try buildArgv(a, gid_path, flags);
    defer a.free(gargv);
    const z = try runCmd(a, zargv);
    defer z.deinit(a);
    const g = try runCmd(a, gargv);
    defer g.deinit(a);
    try std.testing.expectEqual(@as(?u8, 1), g.code);
    try std.testing.expectEqual(g.code, z.code);
    try std.testing.expect(std.mem.indexOf(u8, z.stderr, "no such user") != null);
}

// ---- --help / --version routing: GNU writes both to STDOUT, exit 0 --------

test "parity: --help goes to stdout with exit 0" {
    const a = std.testing.allocator;
    const argv = &[_][]const u8{ zid_path, "--help" };
    const r = try runCmd(a, argv);
    defer r.deinit(a);
    try std.testing.expectEqual(@as(?u8, 0), r.code);
    try std.testing.expect(r.stdout.len > 0);
    // GNU sends the entire help text to stdout; stderr must be empty.
    try std.testing.expectEqual(@as(usize, 0), r.stderr.len);
}

test "parity: --version goes to stdout with exit 0" {
    const a = std.testing.allocator;
    const argv = &[_][]const u8{ zid_path, "--version" };
    const r = try runCmd(a, argv);
    defer r.deinit(a);
    try std.testing.expectEqual(@as(?u8, 0), r.code);
    try std.testing.expect(r.stdout.len > 0);
    try std.testing.expectEqual(@as(usize, 0), r.stderr.len);
}
