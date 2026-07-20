//! GNU/POSIX-parity tests for zkill.
//!
//! These are EXTERNALLY ANCHORED, not roundtrip tests:
//!
//!  1. The signal name<->number mapping is diffed against a REFERENCE
//!     IMPLEMENTATION zkill did not author: the shell builtin `kill -l`
//!     (bash 3.2's `/bin/bash`). That builtin reads the running kernel's
//!     signal table via the C library, so it is the authority for what
//!     number a named signal must map to on THIS platform. This is the anchor
//!     that catches the critical bug in the audit: the old table hardcoded
//!     Linux x86_64 numbers (SIGUSR1=10, SIGSTOP=19, SIGCONT=18) while the
//!     binary calls the native macOS kill(2) where SIGUSR1=30, SIGSTOP=17,
//!     SIGCONT=19. Under the old table `zkill -l 17` printed CHLD; the kernel
//!     (and bash) say STOP.
//!
//!  2. A literal per-platform anchor table (macos_map) is written out in bytes,
//!     sourced from BSD `/bin/kill -l` and `bash -c 'kill -l N'` captured on
//!     macOS 15 (Darwin 27). On macOS it is asserted directly, so the test is
//!     meaningful even if no shell is present; on other platforms it is skipped
//!     and only the live-bash diff runs.
//!
//!  3. Exit-status decoding (`kill -l 137` -> KILL, i.e. 137-128=9) is anchored
//!     to the same shell builtin and to the documented WIFSIGNALED convention.
//!
//!  4. Behavioural anchors for the two safety fixes:
//!       - `-l ""` must NOT abort (was an out-of-bounds panic, exit 134);
//!       - a negative PID after `--` or after a chosen signal must reach
//!         kill(2) as a process-group target (was swallowed as a signal spec).
//!
//! The zkill binary path is injected by build.zig via `build_options`.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const build_options = @import("build_options");

// Reference shell: its `kill -l` builtin reads the OS signal table.
const bash_candidates = [_][]const u8{
    "/bin/bash",
    "/usr/bin/bash",
    "/usr/local/bin/bash",
    "/opt/homebrew/bin/bash",
};

// Literal per-platform anchor: name -> number as reported by BSD `/bin/kill -l`
// and `bash -c 'kill -l NAME'` on macOS (Darwin). Only asserted when the test
// itself runs on macOS.
const NameNum = struct { name: []const u8, num: u8 };
const macos_map = [_]NameNum{
    .{ .name = "HUP", .num = 1 },
    .{ .name = "INT", .num = 2 },
    .{ .name = "QUIT", .num = 3 },
    .{ .name = "ILL", .num = 4 },
    .{ .name = "TRAP", .num = 5 },
    .{ .name = "ABRT", .num = 6 },
    .{ .name = "EMT", .num = 7 },
    .{ .name = "FPE", .num = 8 },
    .{ .name = "KILL", .num = 9 },
    .{ .name = "BUS", .num = 10 },
    .{ .name = "SEGV", .num = 11 },
    .{ .name = "SYS", .num = 12 },
    .{ .name = "PIPE", .num = 13 },
    .{ .name = "ALRM", .num = 14 },
    .{ .name = "TERM", .num = 15 },
    .{ .name = "URG", .num = 16 },
    .{ .name = "STOP", .num = 17 },
    .{ .name = "TSTP", .num = 18 },
    .{ .name = "CONT", .num = 19 },
    .{ .name = "CHLD", .num = 20 },
    .{ .name = "TTIN", .num = 21 },
    .{ .name = "TTOU", .num = 22 },
    .{ .name = "IO", .num = 23 },
    .{ .name = "XCPU", .num = 24 },
    .{ .name = "XFSZ", .num = 25 },
    .{ .name = "VTALRM", .num = 26 },
    .{ .name = "PROF", .num = 27 },
    .{ .name = "WINCH", .num = 28 },
    .{ .name = "INFO", .num = 29 },
    .{ .name = "USR1", .num = 30 },
    .{ .name = "USR2", .num = 31 },
};

const Run = struct {
    stdout: []u8,
    stderr: []u8,
    exit: u8,
    signaled: bool,

    fn deinit(self: Run, a: std.mem.Allocator) void {
        a.free(self.stdout);
        a.free(self.stderr);
    }
};

fn runBinary(allocator: std.mem.Allocator, io: Io, prog: []const u8, args: []const []const u8) !Run {
    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, prog);
    for (args) |a| try argv.append(allocator, a);

    const res = try std.process.run(allocator, io, .{ .argv = argv.items });
    var exit: u8 = 0;
    var signaled = false;
    switch (res.term) {
        .exited => |c| exit = c,
        else => {
            exit = 255;
            signaled = true;
        },
    }
    return .{ .stdout = res.stdout, .stderr = res.stderr, .exit = exit, .signaled = signaled };
}

// Run the shell builtin `kill -l <arg>`; returns trimmed stdout (name or number)
// or null if that shell isn't present / the arg is rejected.
fn bashKillL(allocator: std.mem.Allocator, io: Io, bash: []const u8, arg: []const u8) !?[]u8 {
    var cmd: std.ArrayListUnmanaged(u8) = .empty;
    defer cmd.deinit(allocator);
    try cmd.appendSlice(allocator, "kill -l ");
    try cmd.appendSlice(allocator, arg);
    const r = try runBinary(allocator, io, bash, &.{ "-c", cmd.items });
    defer r.deinit(allocator);
    if (r.exit != 0) return null;
    const trimmed = std.mem.trim(u8, r.stdout, " \t\r\n");
    return try allocator.dupe(u8, trimmed);
}

fn findBash(allocator: std.mem.Allocator, io: Io) ?[]const u8 {
    for (bash_candidates) |c| {
        const r = bashKillL(allocator, io, c, "9") catch continue;
        if (r) |s| {
            allocator.free(s);
            return c;
        }
    }
    return null;
}

test "zkill signal name<->number mapping matches the OS signal table" {
    const allocator = std.testing.allocator;
    var threaded = Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const zpath = build_options.zkill_path;
    const bash = findBash(allocator, io);

    var failures: usize = 0;

    // (1) Live diff against the shell builtin, if present. For every signal the
    // reference reports, zkill must agree in both directions.
    if (bash) |bash_path| {
        var n: u8 = 1;
        while (n <= 31) : (n += 1) {
            var numbuf: [4]u8 = undefined;
            const nums = std.fmt.bufPrint(&numbuf, "{d}", .{n}) catch unreachable;

            const ref_name = (try bashKillL(allocator, io, bash_path, nums)) orelse continue;
            defer allocator.free(ref_name);

            // number -> name
            const zn = try runBinary(allocator, io, zpath, &.{ "-l", nums });
            defer zn.deinit(allocator);
            const zn_out = std.mem.trim(u8, zn.stdout, " \t\r\n");
            if (!std.mem.eql(u8, zn_out, ref_name)) {
                std.debug.print("MISMATCH num->name {d}: zkill='{s}' bash='{s}'\n", .{ n, zn_out, ref_name });
                failures += 1;
            }

            // name -> number (round-trips through the reference's own name)
            const zm = try runBinary(allocator, io, zpath, &.{ "-l", ref_name });
            defer zm.deinit(allocator);
            const zm_out = std.mem.trim(u8, zm.stdout, " \t\r\n");
            if (!std.mem.eql(u8, zm_out, nums)) {
                std.debug.print("MISMATCH name->num {s}: zkill='{s}' bash='{s}'\n", .{ ref_name, zm_out, nums });
                failures += 1;
            }
        }
    }

    // (2) Literal macOS anchor (bytes captured from BSD kill / bash on Darwin).
    if (builtin.os.tag == .macos) {
        for (macos_map) |m| {
            var numbuf: [4]u8 = undefined;
            const nums = std.fmt.bufPrint(&numbuf, "{d}", .{m.num}) catch unreachable;

            const zn = try runBinary(allocator, io, zpath, &.{ "-l", nums });
            defer zn.deinit(allocator);
            const zn_out = std.mem.trim(u8, zn.stdout, " \t\r\n");
            if (!std.mem.eql(u8, zn_out, m.name)) {
                std.debug.print("ANCHOR num->name {d}: zkill='{s}' expected='{s}'\n", .{ m.num, zn_out, m.name });
                failures += 1;
            }

            const zm = try runBinary(allocator, io, zpath, &.{ "-l", m.name });
            defer zm.deinit(allocator);
            const zm_out = std.mem.trim(u8, zm.stdout, " \t\r\n");
            if (!std.mem.eql(u8, zm_out, nums)) {
                std.debug.print("ANCHOR name->num {s}: zkill='{s}' expected='{s}'\n", .{ m.name, zm_out, nums });
                failures += 1;
            }
        }
    }

    if (bash == null and builtin.os.tag != .macos) {
        std.debug.print("NOTE: no reference shell and not macOS; mapping unanchored on this host.\n", .{});
    }
    try std.testing.expectEqual(@as(usize, 0), failures);
}

test "zkill -l decodes wait(2) exit status (128+signum)" {
    const allocator = std.testing.allocator;
    var threaded = Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const zpath = build_options.zkill_path;
    const bash = findBash(allocator, io);

    // status -> expected name. Anchored to `bash -c 'kill -l N'`:
    //   130 -> INT (130-128=2), 137 -> KILL (9), 143 -> TERM (15).
    const Dec = struct { status: []const u8, name: []const u8 };
    const decs = [_]Dec{
        .{ .status = "130", .name = "INT" },
        .{ .status = "137", .name = "KILL" },
        .{ .status = "143", .name = "TERM" },
    };

    var failures: usize = 0;
    for (decs) |d| {
        // Cross-check the literal against the live shell where available.
        if (bash) |bash_path| {
            const ref = (try bashKillL(allocator, io, bash_path, d.status)) orelse {
                std.debug.print("NOTE: reference shell rejected 'kill -l {s}'\n", .{d.status});
                continue;
            };
            defer allocator.free(ref);
            if (!std.mem.eql(u8, ref, d.name)) {
                std.debug.print("ANCHOR DRIFT: bash kill -l {s} = '{s}', table = '{s}'\n", .{ d.status, ref, d.name });
                failures += 1;
                continue;
            }
        }
        const z = try runBinary(allocator, io, zpath, &.{ "-l", d.status });
        defer z.deinit(allocator);
        const out = std.mem.trim(u8, z.stdout, " \t\r\n");
        if (!std.mem.eql(u8, out, d.name)) {
            std.debug.print("MISMATCH exit-status {s}: zkill='{s}' want='{s}'\n", .{ d.status, out, d.name });
            failures += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 0), failures);
}

test "zkill -l with an empty argument does not crash (was OOB panic)" {
    const allocator = std.testing.allocator;
    var threaded = Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const zpath = build_options.zkill_path;

    const z = try runBinary(allocator, io, zpath, &.{ "-l", "" });
    defer z.deinit(allocator);
    // The bug: `args[i+1][0]` indexed an empty slice -> "index out of bounds"
    // panic, which aborts with SIGABRT (a non-`exited` termination). A clean
    // error exit is acceptable; a signal-terminated process is not.
    try std.testing.expect(!z.signaled);
    try std.testing.expect(z.exit != 134); // 128+SIGABRT
}

test "negative PID after a signal or -- reaches kill(2) as a process group" {
    const allocator = std.testing.allocator;
    var threaded = Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const zpath = build_options.zkill_path;

    // A huge, certainly-nonexistent process group. Signal 0 delivers nothing;
    // it only probes existence, so this is safe. Both forms must route the
    // negative number to kill(2) (reported back as the target in the error),
    // NOT reject it with "invalid signal specification".
    const forms = [_][]const []const u8{
        &.{ "-0", "--", "-2000000000" }, // via end-of-options
        &.{ "-0", "-2000000000" }, // via already-set signal
    };
    for (forms) |args| {
        const z = try runBinary(allocator, io, zpath, args);
        defer z.deinit(allocator);
        try std.testing.expect(!z.signaled);
        // The pgid must appear in the error (it reached kill), and the parser
        // must not have treated it as a bad signal.
        try std.testing.expect(std.mem.indexOf(u8, z.stderr, "-2000000000") != null);
        try std.testing.expect(std.mem.indexOf(u8, z.stderr, "invalid signal") == null);
    }
}

test "zkill -0 on the running test process succeeds (POSIX null-signal probe)" {
    const allocator = std.testing.allocator;
    var threaded = Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const zpath = build_options.zkill_path;

    const self = std.c.getpid();
    var buf: [16]u8 = undefined;
    const pid_str = std.fmt.bufPrint(&buf, "{d}", .{self}) catch unreachable;

    // Signal 0 to a process that provably exists (us) -> success, exit 0.
    const ok = try runBinary(allocator, io, zpath, &.{ "-0", pid_str });
    defer ok.deinit(allocator);
    try std.testing.expectEqual(@as(u8, 0), ok.exit);

    // Signal 0 to a certainly-nonexistent PID -> ESRCH -> exit 1.
    const gone = try runBinary(allocator, io, zpath, &.{ "-0", "2000000000" });
    defer gone.deinit(allocator);
    try std.testing.expectEqual(@as(u8, 1), gone.exit);
}
