//! GNU-parity tests for zbasename.
//!
//! These are EXTERNALLY ANCHORED, not roundtrip tests:
//!
//!  1. Every expected value below is the DOCUMENTED behavior of GNU coreutils
//!     `basename` (GNU coreutils 9.x / POSIX). The bytes are written out
//!     literally in the table so the anchor is legible without running anything.
//!
//!  2. When a real GNU `basename` binary is present on this machine
//!     (Homebrew coreutils: /opt/homebrew/.../gnubin/basename or `gbasename`),
//!     the test FIRST confirms the live GNU binary emits exactly those literal
//!     bytes / exit code — i.e. it proves the anchor table itself matches the
//!     reference implementation — and THEN diffs the zbasename binary against
//!     the same table. So zbasename is checked against output it did not author.
//!
//! The zbasename binary path is injected by build.zig via `build_options`
//! (the emitted-binary path of the exe target), so `zig build test` always
//! exercises the freshly-built binary.

const std = @import("std");
const Io = std.Io;
const build_options = @import("build_options");

const gnu_candidates = [_][]const u8{
    "/opt/homebrew/opt/coreutils/libexec/gnubin/basename",
    "/opt/homebrew/bin/gbasename",
    "/usr/local/opt/coreutils/libexec/gnubin/basename",
    "/usr/local/bin/gbasename",
};

const Case = struct {
    /// argv passed after the program name.
    args: []const []const u8,
    /// exact bytes GNU basename writes to stdout.
    stdout: []const u8,
    /// exit code GNU basename returns.
    exit: u8,
};

// Anchor table: inputs + GNU-documented stdout/exit.
const cases = [_]Case{
    // Root / all-slash: GNU prints "/", NOT an empty line. (the primary bug)
    .{ .args = &.{"/"}, .stdout = "/\n", .exit = 0 },
    .{ .args = &.{"//"}, .stdout = "/\n", .exit = 0 },
    .{ .args = &.{"///"}, .stdout = "/\n", .exit = 0 },
    // Ordinary directory stripping.
    .{ .args = &.{"/usr/lib"}, .stdout = "lib\n", .exit = 0 },
    .{ .args = &.{"/usr/lib/"}, .stdout = "lib\n", .exit = 0 },
    .{ .args = &.{"usr"}, .stdout = "usr\n", .exit = 0 },
    .{ .args = &.{"/usr/"}, .stdout = "usr\n", .exit = 0 },
    .{ .args = &.{"dir/file.txt"}, .stdout = "file.txt\n", .exit = 0 },
    // Single dash is an operand, not an option.
    .{ .args = &.{"-"}, .stdout = "-\n", .exit = 0 },
    // Traditional NAME [SUFFIX].
    .{ .args = &.{ "stdio.h", ".h" }, .stdout = "stdio\n", .exit = 0 },
    // Suffix that equals the whole basename is NOT removed (GNU keeps it).
    .{ .args = &.{ "/usr/lib", ".lib" }, .stdout = "lib\n", .exit = 0 },
    // -a / --multiple.
    .{ .args = &.{ "-a", "foo", "bar", "baz" }, .stdout = "foo\nbar\nbaz\n", .exit = 0 },
    .{ .args = &.{ "--multiple", "a/x", "b/y" }, .stdout = "x\ny\n", .exit = 0 },
    // -s implies multiple.
    .{ .args = &.{ "-s", ".txt", "a.txt", "b.txt" }, .stdout = "a\nb\n", .exit = 0 },
    .{ .args = &.{ "--suffix=.txt", "d/a.txt" }, .stdout = "a\n", .exit = 0 },
    // -z / --zero: NUL terminator instead of newline.
    .{ .args = &.{ "-z", "/usr/lib" }, .stdout = "lib\x00", .exit = 0 },
    // "--" end-of-options: subsequent dash-prefixed arg is an operand.
    .{ .args = &.{ "--", "-x" }, .stdout = "-x\n", .exit = 0 },
    .{ .args = &.{ "--", "/a/b" }, .stdout = "b\n", .exit = 0 },
    // Traditional mode rejects a third operand.
    .{ .args = &.{ "foo", "bar", "baz" }, .stdout = "", .exit = 1 },
    // Missing operand.
    .{ .args = &.{}, .stdout = "", .exit = 1 },
};

const Run = struct { stdout: []u8, exit: u8 };

fn runBinary(allocator: std.mem.Allocator, io: Io, prog: []const u8, args: []const []const u8) !Run {
    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, prog);
    for (args) |a| try argv.append(allocator, a);

    const res = try std.process.run(allocator, io, .{ .argv = argv.items });
    allocator.free(res.stderr);
    const exit: u8 = switch (res.term) {
        .exited => |c| c,
        else => 255,
    };
    return .{ .stdout = res.stdout, .exit = exit };
}

fn findGnu(allocator: std.mem.Allocator, io: Io) ?[]const u8 {
    for (gnu_candidates) |c| {
        // Probe by actually spawning it; missing binary yields a spawn error.
        const r = runBinary(allocator, io, c, &.{"/"}) catch continue;
        allocator.free(r.stdout);
        return c;
    }
    return null;
}

test "zbasename matches GNU basename across representative inputs" {
    const allocator = std.testing.allocator;
    // global_single_threaded uses a `.failing` allocator, which cannot spawn
    // child processes. Build a real threaded Io backed by the test allocator.
    var threaded = Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const zpath = build_options.zbasename_path;
    const gnu = findGnu(allocator, io);

    var failures: usize = 0;
    for (cases) |case| {
        // 1. If a real GNU binary exists, prove the anchor table equals its output.
        if (gnu) |gnu_path| {
            const g = try runBinary(allocator, io, gnu_path, case.args);
            defer allocator.free(g.stdout);
            if (!std.mem.eql(u8, g.stdout, case.stdout) or g.exit != case.exit) {
                std.debug.print(
                    "ANCHOR DRIFT: GNU disagrees with table for args={any}\n  gnu stdout={x} exit={d}\n  table     ={x} exit={d}\n",
                    .{ case.args, g.stdout, g.exit, case.stdout, case.exit },
                );
                failures += 1;
                continue;
            }
        }

        // 2. Diff zbasename against the (GNU-confirmed) anchor.
        const z = try runBinary(allocator, io, zpath, case.args);
        defer allocator.free(z.stdout);
        if (!std.mem.eql(u8, z.stdout, case.stdout) or z.exit != case.exit) {
            std.debug.print(
                "MISMATCH: zbasename args={any}\n  got  stdout={x} exit={d}\n  want stdout={x} exit={d}\n",
                .{ case.args, z.stdout, z.exit, case.stdout, case.exit },
            );
            failures += 1;
        }
    }

    if (gnu == null) {
        std.debug.print("NOTE: no GNU basename found; anchored to literal GNU-documented bytes only.\n", .{});
    }
    try std.testing.expectEqual(@as(usize, 0), failures);
}
