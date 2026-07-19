//! GNU parity tests for zdd.
//!
//! External anchor: every behavioral test here runs the REAL GNU dd
//! (coreutils, found via the candidate paths below) side by side with the
//! freshly built zdd on the same inputs, then compares output bytes, the
//! "N+M records in/out" stderr lines, and exit codes. Nothing here is a
//! roundtrip: the expected values come from GNU coreutils, not from zdd.
//!
//! If no GNU dd binary is installed the parity tests skip (SkipZigTest)
//! rather than silently pass.

const std = @import("std");
const testing = std.testing;
const io = testing.io;
const alloc = testing.allocator;

const zdd_path = @import("build_options").zdd_path;

const gnu_candidates = [_][]const u8{
    "/opt/homebrew/opt/coreutils/libexec/gnubin/dd",
    "/opt/homebrew/bin/gdd",
    "/usr/local/opt/coreutils/libexec/gnubin/dd",
    "/usr/local/bin/gdd",
    "/usr/bin/dd", // GNU on Linux; harmless elsewhere (BSD dd never matches candidates above first)
};

var gnu_cached: ?[]const u8 = null;
var gnu_checked: bool = false;

fn gnuDd() error{SkipZigTest}![]const u8 {
    if (!gnu_checked) {
        gnu_checked = true;
        for (gnu_candidates) |cand| {
            // On Linux /usr/bin/dd is GNU; on macOS only the coreutils
            // installs above are. Require "coreutils" in --version output.
            const res = std.process.run(alloc, io, .{
                .argv = &.{ cand, "--version" },
            }) catch continue;
            defer alloc.free(res.stdout);
            defer alloc.free(res.stderr);
            const ok = switch (res.term) {
                .exited => |c| c == 0,
                else => false,
            };
            if (ok and std.mem.indexOf(u8, res.stdout, "coreutils") != null) {
                gnu_cached = cand;
                break;
            }
        }
    }
    return gnu_cached orelse error.SkipZigTest;
}

const RunOut = struct {
    code: u8,
    stdout: []u8,
    stderr: []u8,

    fn deinit(self: *const RunOut) void {
        alloc.free(self.stdout);
        alloc.free(self.stderr);
    }
};

fn runTool(argv: []const []const u8, timeout_s: ?u32) !RunOut {
    const res = try std.process.run(alloc, io, .{
        .argv = argv,
        .timeout = if (timeout_s) |s| .{ .duration = .{
            .raw = .fromNanoseconds(@as(i96, s) * std.time.ns_per_s),
            .clock = .awake,
        } } else .none,
    });
    const code: u8 = switch (res.term) {
        .exited => |c| c,
        else => 255,
    };
    return .{ .code = code, .stdout = res.stdout, .stderr = res.stderr };
}

/// Extract the "A+B records in" / "C+D records out" stderr lines, skipping
/// diagnostics (which differ only by the "dd:"/"zdd:" program prefix) and the
/// wall-clock transfer line (nondeterministic). Caller frees the result.
fn recordsLines(stderr: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var it = std.mem.splitScalar(u8, stderr, '\n');
    while (it.next()) |line| {
        if (std.mem.endsWith(u8, line, " records in") or
            std.mem.endsWith(u8, line, " records out"))
        {
            try out.appendSlice(alloc, line);
            try out.append(alloc, '\n');
        }
    }
    return out.toOwnedSlice(alloc);
}

const Fixture = struct {
    tmp: testing.TmpDir,
    dir_path: [:0]const u8,

    fn init() !Fixture {
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();
        const dir_path = try tmp.dir.realPathFileAlloc(io, ".", alloc);
        return .{ .tmp = tmp, .dir_path = dir_path };
    }

    fn deinit(self: *Fixture) void {
        alloc.free(self.dir_path);
        self.tmp.cleanup();
    }

    fn path(self: *Fixture, name: []const u8) ![]u8 {
        return std.fmt.allocPrint(alloc, "{s}/{s}", .{ self.dir_path, name });
    }

    fn write(self: *Fixture, name: []const u8, data: []const u8) !void {
        try self.tmp.dir.writeFile(io, .{ .sub_path = name, .data = data });
    }

    fn read(self: *Fixture, name: []const u8) ![]u8 {
        return self.tmp.dir.readFileAlloc(io, name, alloc, .unlimited);
    }
};

fn deterministicBytes(comptime n: usize, seed: u64) [n]u8 {
    var prng = std.Random.DefaultPrng.init(seed);
    var buf: [n]u8 = undefined;
    prng.random().bytes(&buf);
    return buf;
}

/// Run gdd and zdd with identical operands (templated on input/output paths),
/// compare exit codes, output file bytes, and records lines.
fn parityCase(
    fx: *Fixture,
    in_name: ?[]const u8,
    gnu_out: []const u8,
    zdd_out: []const u8,
    extra: []const []const u8,
) !void {
    const gnu = try gnuDd();

    var gargs: std.ArrayList([]const u8) = .empty;
    defer gargs.deinit(alloc);
    var zargs: std.ArrayList([]const u8) = .empty;
    defer zargs.deinit(alloc);

    try gargs.append(alloc, gnu);
    try zargs.append(alloc, zdd_path);

    var if_g: ?[]u8 = null;
    defer if (if_g) |p| alloc.free(p);
    if (in_name) |n| {
        const in_path = try fx.path(n);
        if_g = try std.fmt.allocPrint(alloc, "if={s}", .{in_path});
        alloc.free(in_path);
        try gargs.append(alloc, if_g.?);
        try zargs.append(alloc, if_g.?);
    }

    const gnu_out_path = try fx.path(gnu_out);
    defer alloc.free(gnu_out_path);
    const zdd_out_path = try fx.path(zdd_out);
    defer alloc.free(zdd_out_path);
    const of_g = try std.fmt.allocPrint(alloc, "of={s}", .{gnu_out_path});
    defer alloc.free(of_g);
    const of_z = try std.fmt.allocPrint(alloc, "of={s}", .{zdd_out_path});
    defer alloc.free(of_z);
    try gargs.append(alloc, of_g);
    try zargs.append(alloc, of_z);

    for (extra) |e| {
        try gargs.append(alloc, e);
        try zargs.append(alloc, e);
    }

    const gres = try runTool(gargs.items, 60);
    defer gres.deinit();
    const zres = try runTool(zargs.items, 60);
    defer zres.deinit();

    try testing.expectEqual(gres.code, zres.code);
    const grecs = try recordsLines(gres.stderr);
    defer alloc.free(grecs);
    const zrecs = try recordsLines(zres.stderr);
    defer alloc.free(zrecs);
    try testing.expectEqualStrings(grecs, zrecs);

    const gbytes = try fx.read(gnu_out);
    defer alloc.free(gbytes);
    const zbytes = try fx.read(zdd_out);
    defer alloc.free(zbytes);
    try testing.expectEqualSlices(u8, gbytes, zbytes);
}

test "basic copy bs=512 matches GNU byte-for-byte" {
    var fx = try Fixture.init();
    defer fx.deinit();
    const data = deterministicBytes(1237, 0x5eed);
    try fx.write("in", &data);
    try parityCase(&fx, "in", "g.out", "z.out", &.{"bs=512"});
}

test "bs=4M count=2 copies full-size blocks (audit critical: 1 MiB cap)" {
    var fx = try Fixture.init();
    defer fx.deinit();
    // 12 MiB of deterministic data; count=2 bs=4M must copy exactly 8 MiB.
    const chunk = deterministicBytes(1 << 20, 0xb10c);
    var f = try fx.tmp.dir.createFile(io, "in", .{});
    var wbuf: [4096]u8 = undefined;
    var writer = f.writer(io, &wbuf);
    for (0..12) |_| try writer.interface.writeAll(&chunk);
    try writer.interface.flush();
    f.close(io);

    try parityCase(&fx, "in", "g.out", "z.out", &.{ "bs=4M", "count=2" });

    const zbytes = try fx.read("z.out");
    defer alloc.free(zbytes);
    try testing.expectEqual(@as(usize, 8 * 1024 * 1024), zbytes.len);
}

test "seek= preserves pre-existing prefix and truncates like GNU (audit high: O_TRUNC before lseek)" {
    var fx = try Fixture.init();
    defer fx.deinit();
    const pre = deterministicBytes(100, 0x0ff5);
    try fx.write("g.out", &pre);
    try fx.write("z.out", &pre);
    try fx.write("in", "XY");
    // GNU: keeps bytes 0..4, writes "XY" at offset 4, truncates → 6 bytes.
    try parityCase(&fx, "in", "g.out", "z.out", &.{ "bs=4", "seek=1" });
}

test "conv=notrunc preserves trailing data like GNU" {
    var fx = try Fixture.init();
    defer fx.deinit();
    const pre = deterministicBytes(300, 0x7a11);
    try fx.write("g.out", &pre);
    try fx.write("z.out", &pre);
    try fx.write("in", "hello");
    try parityCase(&fx, "in", "g.out", "z.out", &.{ "bs=2", "conv=notrunc" });
}

test "skip= skips ibs-sized input blocks like GNU" {
    var fx = try Fixture.init();
    defer fx.deinit();
    const data = deterministicBytes(1000, 0x5c1b);
    try fx.write("in", &data);
    try parityCase(&fx, "in", "g.out", "z.out", &.{ "bs=100", "skip=2" });
}

test "ibs=1 obs=512 reblocks output like GNU (audit medium: obs ignored)" {
    var fx = try Fixture.init();
    defer fx.deinit();
    try fx.write("in", "abcdefghijklmnopqrstuvwx");
    // GNU: 24+0 records in, 0+1 records out — one 24-byte partial write.
    try parityCase(&fx, "in", "g.out", "z.out", &.{ "ibs=1", "obs=512" });
}

test "conv=sync pads partial input blocks with NULs like GNU" {
    var fx = try Fixture.init();
    defer fx.deinit();
    const data = deterministicBytes(700, 0x5a9c);
    try fx.write("in", &data);
    try parityCase(&fx, "in", "g.out", "z.out", &.{ "ibs=512", "obs=512", "conv=sync" });
}

test "conv=ucase and conv=swab (odd length) match GNU" {
    var fx = try Fixture.init();
    defer fx.deinit();
    try fx.write("in", "Hello, World! dd parity 123\n");
    try parityCase(&fx, "in", "g1.out", "z1.out", &.{ "bs=8", "conv=ucase" });
    // Odd-length input exercises the trailing unpaired byte under swab.
    try fx.write("odd", "abcdefg");
    try parityCase(&fx, "odd", "g2.out", "z2.out", &.{ "bs=512", "conv=swab" });
}

test "count= accepts size suffixes like GNU (count=1K blocks)" {
    var fx = try Fixture.init();
    defer fx.deinit();
    const data = deterministicBytes(2000, 0xc047);
    try fx.write("in", &data);
    // count=1K = 1024 one-byte blocks → exactly 1024 bytes copied.
    try parityCase(&fx, "in", "g.out", "z.out", &.{ "bs=1", "count=1K" });
    const zbytes = try fx.read("z.out");
    defer alloc.free(zbytes);
    try testing.expectEqual(@as(usize, 1024), zbytes.len);
}

test "empty input: 0+0 records, exit 0, empty output" {
    var fx = try Fixture.init();
    defer fx.deinit();
    try fx.write("in", "");
    try parityCase(&fx, "in", "g.out", "z.out", &.{"bs=512"});
}

test "invalid operands rejected with exit 1 like GNU" {
    const gnu = try gnuDd();
    const bad_operands = [_][]const u8{
        "conv=notrunk", // typo GNU refuses — silently ignoring it would truncate data
        "status=bogus",
        "bs=0", // GNU: invalid number: '0'
        "bs=99999999999999999G", // overflow must be an error, not a wrap/panic
        "count=x",
    };
    for (bad_operands) |op| {
        const gres = try runTool(&.{ gnu, op }, 30);
        defer gres.deinit();
        const zres = try runTool(&.{ zdd_path, op }, 30);
        defer zres.deinit();
        try testing.expectEqual(@as(u8, 1), gres.code);
        try testing.expectEqual(@as(u8, 1), zres.code);
    }

    // zdd-only: GNU implements oflag= (gdd oflag=append exits 0), zdd does
    // not — an unimplemented operand must be refused, never silently
    // ignored (audit medium: silent operand drops).
    const zres = try runTool(&.{ zdd_path, "oflag=append" }, 30);
    defer zres.deinit();
    try testing.expectEqual(@as(u8, 1), zres.code);
    try testing.expect(std.mem.indexOf(u8, zres.stderr, "unrecognized operand") != null);
}

test "read error (if=directory) exits 1 like GNU (audit medium: exit 0 on error)" {
    var fx = try Fixture.init();
    defer fx.deinit();
    const gnu = try gnuDd();
    const if_arg = try std.fmt.allocPrint(alloc, "if={s}", .{fx.dir_path});
    defer alloc.free(if_arg);

    const gres = try runTool(&.{ gnu, if_arg, "of=/dev/null" }, 30);
    defer gres.deinit();
    const zres = try runTool(&.{ zdd_path, if_arg, "of=/dev/null" }, 30);
    defer zres.deinit();
    try testing.expectEqual(@as(u8, 1), gres.code);
    try testing.expectEqual(@as(u8, 1), zres.code);
    // Both still report the (empty) record counts on stderr.
    const grecs = try recordsLines(gres.stderr);
    defer alloc.free(grecs);
    const zrecs = try recordsLines(zres.stderr);
    defer alloc.free(zrecs);
    try testing.expectEqualStrings(grecs, zrecs);
}

test "conv=noerror on a persistently failing input terminates (audit high: livelock)" {
    // Deliberately NOT diffed against GNU: gdd 9.10 spins forever on
    // `dd if=<dir> conv=noerror` (verified 2026-07-19 — timeout killed it
    // after 10 MB of repeated diagnostics). The audit requires zdd to detect
    // the persistent-errno case (EISDIR here) and bail with a diagnostic
    // instead of livelocking; the 30 s timeout below is the regression guard.
    var fx = try Fixture.init();
    defer fx.deinit();
    const if_arg = try std.fmt.allocPrint(alloc, "if={s}", .{fx.dir_path});
    defer alloc.free(if_arg);

    const zres = try runTool(&.{ zdd_path, if_arg, "of=/dev/null", "conv=noerror" }, 30);
    defer zres.deinit();
    try testing.expectEqual(@as(u8, 1), zres.code);
    try testing.expect(std.mem.indexOf(u8, zres.stderr, "error reading") != null);
}

test "over-long path (5000 chars) errors gracefully with exit 1 like GNU (audit high: stack overflow)" {
    const gnu = try gnuDd();
    const long = try alloc.alloc(u8, 5000);
    defer alloc.free(long);
    @memset(long, 'a');
    const if_arg = try std.fmt.allocPrint(alloc, "if={s}", .{long});
    defer alloc.free(if_arg);

    const gres = try runTool(&.{ gnu, if_arg }, 30);
    defer gres.deinit();
    const zres = try runTool(&.{ zdd_path, if_arg }, 30);
    defer zres.deinit();
    try testing.expectEqual(@as(u8, 1), gres.code);
    try testing.expectEqual(@as(u8, 1), zres.code); // was: SIGABRT / stack corruption
}

test "status=noxfer suppresses the transfer line like GNU" {
    var fx = try Fixture.init();
    defer fx.deinit();
    const data = deterministicBytes(1024, 0x0f2e);
    try fx.write("in", &data);
    const gnu = try gnuDd();
    const in_path = try fx.path("in");
    defer alloc.free(in_path);
    const if_arg = try std.fmt.allocPrint(alloc, "if={s}", .{in_path});
    defer alloc.free(if_arg);

    const g_out = try fx.path("g.out");
    defer alloc.free(g_out);
    const z_out = try fx.path("z.out");
    defer alloc.free(z_out);
    const of_g = try std.fmt.allocPrint(alloc, "of={s}", .{g_out});
    defer alloc.free(of_g);
    const of_z = try std.fmt.allocPrint(alloc, "of={s}", .{z_out});
    defer alloc.free(of_z);

    const gres = try runTool(&.{ gnu, if_arg, of_g, "bs=512", "status=noxfer" }, 30);
    defer gres.deinit();
    const zres = try runTool(&.{ zdd_path, if_arg, of_z, "bs=512", "status=noxfer" }, 30);
    defer zres.deinit();
    try testing.expectEqual(gres.code, zres.code);
    // With noxfer the whole stderr is exactly the two records lines.
    try testing.expectEqualStrings(gres.stderr, zres.stderr);
}

test "--help prints to stdout and exits 0 like GNU" {
    const gnu = try gnuDd();
    const gres = try runTool(&.{ gnu, "--help" }, 30);
    defer gres.deinit();
    const zres = try runTool(&.{ zdd_path, "--help" }, 30);
    defer zres.deinit();
    try testing.expectEqual(@as(u8, 0), gres.code);
    try testing.expectEqual(@as(u8, 0), zres.code);
    try testing.expect(gres.stdout.len > 0 and gres.stderr.len == 0);
    try testing.expect(zres.stdout.len > 0 and zres.stderr.len == 0);
}
