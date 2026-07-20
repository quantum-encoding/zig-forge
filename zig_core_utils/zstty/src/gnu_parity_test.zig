//! Externally-anchored parity tests for zstty.
//!
//! The anchor is the real GNU coreutils `stty` binary (`gstty`, coreutils 9.10).
//! Each test opens a fresh pseudo-terminal, drives BOTH zstty and gstty against
//! it through `-F <pts>`, and compares their output byte-for-byte. Because the
//! expected bytes come from a binary this project's authors did not write, these
//! are true external anchors — not self-consistency / roundtrip tests (see the
//! zig-forge golden rule).
//!
//! `-g` (the save format) is the load-bearing anchor: it serialises all four
//! termios flag words plus every control character in GNU's exact textual form,
//! so a byte-exact `-g` match proves the whole termios ABI (struct layout, field
//! widths, NCCS, baud encoding) and the save formatter are correct on this target.
//!
//! One test (`documented sane bytes`) additionally hard-codes the expected macOS
//! `stty sane -g` string so the suite still asserts something concrete even if no
//! GNU binary is installed.
//!
//! The zstty binary under test is located via the ZSTTY_BIN env var, set by
//! build.zig. gstty is discovered from a small list of known Homebrew paths.
//!
//! Child processes are spawned with a raw libc fork/exec/pipe rather than
//! std.process.Child so that argv is passed verbatim (values like `^\` never
//! touch a shell) and stdout is captured directly.

const std = @import("std");
const builtin = @import("builtin");

extern "c" fn openpty(amaster: *c_int, aslave: *c_int, name: [*]u8, termp: ?*anyopaque, winp: ?*anyopaque) c_int;
extern "c" fn close(fd: c_int) c_int;
extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;
extern "c" fn access(path: [*:0]const u8, mode: c_int) c_int;
extern "c" fn pipe(fds: *[2]c_int) c_int;
extern "c" fn fork() c_int;
extern "c" fn dup2(oldfd: c_int, newfd: c_int) c_int;
extern "c" fn execv(path: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;
extern "c" fn read(fd: c_int, buf: [*]u8, count: usize) isize;
extern "c" fn open(path: [*:0]const u8, flags: c_int) c_int;
extern "c" fn waitpid(pid: c_int, status: *c_int, options: c_int) c_int;

const gstty_candidates = [_][:0]const u8{
    "/opt/homebrew/bin/gstty",
    "/opt/homebrew/opt/coreutils/libexec/gnubin/stty",
    "/usr/local/bin/gstty",
    "/usr/local/opt/coreutils/libexec/gnubin/stty",
};

fn findGstty() ?[:0]const u8 {
    for (gstty_candidates) |p| {
        if (access(p.ptr, 0) == 0) return p;
    }
    return null;
}

fn zsttyBin() ![:0]const u8 {
    const v = getenv("ZSTTY_BIN") orelse {
        std.debug.print("ZSTTY_BIN not set — build.zig must export it\n", .{});
        return error.MissingBinary;
    };
    return std.mem.sliceTo(v, 0);
}

const Pty = struct {
    master: c_int,
    slave: c_int,
    name: [64]u8,
    name_len: usize,

    fn open_pty() !Pty {
        var self: Pty = undefined;
        var master: c_int = undefined;
        var slave: c_int = undefined;
        self.name = std.mem.zeroes([64]u8);
        if (openpty(&master, &slave, &self.name, null, null) != 0) return error.OpenPtyFailed;
        // Keep BOTH fds open for the Pty's lifetime. On the BSD/Darwin line
        // discipline the slave's termios is reset once its last fd closes, so we
        // must hold the slave open for settings applied by one child process to
        // still be readable by the next.
        self.master = master;
        self.slave = slave;
        self.name_len = std.mem.indexOfScalar(u8, &self.name, 0) orelse self.name.len;
        return self;
    }

    fn slaveName(self: *const Pty) []const u8 {
        return self.name[0..self.name_len];
    }

    fn deinit(self: *Pty) void {
        _ = close(self.slave);
        _ = close(self.master);
    }
};

const RunOut = struct { stdout: []u8, code: u8 };

/// Spawn `bin -F <pts> args...` via fork/exec, capturing stdout. stderr is sent
/// to /dev/null. Returns owned stdout (caller frees) and the child's exit code.
fn runTool(
    allocator: std.mem.Allocator,
    bin: [:0]const u8,
    pts: []const u8,
    args: []const []const u8,
) !RunOut {
    // Build a NULL-terminated argv of NUL-terminated C strings.
    var argv: std.ArrayListUnmanaged(?[*:0]const u8) = .empty;
    defer {
        for (argv.items) |maybe| {
            if (maybe) |p| allocator.free(std.mem.span(p));
        }
        argv.deinit(allocator);
    }
    try argv.append(allocator, try allocator.dupeZ(u8, bin));
    try argv.append(allocator, try allocator.dupeZ(u8, "-F"));
    try argv.append(allocator, try allocator.dupeZ(u8, pts));
    for (args) |a| try argv.append(allocator, try allocator.dupeZ(u8, a));
    try argv.append(allocator, null);

    var fds: [2]c_int = undefined;
    if (pipe(&fds) != 0) return error.PipeFailed;
    const rd = fds[0];
    const wr = fds[1];

    const pid = fork();
    if (pid < 0) return error.ForkFailed;
    if (pid == 0) {
        // Child: stdout -> pipe, stderr -> /dev/null, then exec.
        _ = dup2(wr, 1);
        const devnull = open("/dev/null", 1); // O_WRONLY
        if (devnull >= 0) _ = dup2(devnull, 2);
        _ = close(rd);
        _ = close(wr);
        const argv_ptr: [*:null]const ?[*:0]const u8 = @ptrCast(argv.items.ptr);
        _ = execv(argv.items[0].?, argv_ptr);
        std.c._exit(127);
    }

    // Parent: read all of stdout.
    _ = close(wr);
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = read(rd, &buf, buf.len);
        if (n <= 0) break;
        try out.appendSlice(allocator, buf[0..@intCast(n)]);
    }
    _ = close(rd);

    var status: c_int = 0;
    _ = waitpid(pid, &status, 0);
    // WIFEXITED / WEXITSTATUS
    const code: u8 = if (status & 0x7f == 0) @intCast((status >> 8) & 0xff) else 255;

    return .{ .stdout = try out.toOwnedSlice(allocator), .code = code };
}

/// Apply `args` to a fresh pty with `bin`, then read it back with gstty -g.
/// Returns the owned -g string (caller frees). `apply_code` receives the exit
/// code of the apply step.
fn applyThenSaveG(
    allocator: std.mem.Allocator,
    bin: [:0]const u8,
    gstty: [:0]const u8,
    args: []const []const u8,
    apply_code: *u8,
) ![]u8 {
    var pty = try Pty.open_pty();
    defer pty.deinit();
    const applied = try runTool(allocator, bin, pty.slaveName(), args);
    allocator.free(applied.stdout);
    apply_code.* = applied.code;
    const saved = try runTool(allocator, gstty, pty.slaveName(), &.{"-g"});
    return saved.stdout;
}

// ---------------------------------------------------------------------------

test "read path: zstty -g byte-matches gstty -g" {
    const allocator = std.testing.allocator;
    const gstty = findGstty() orelse return error.SkipZigTest;
    const zstty = try zsttyBin();

    var pty = try Pty.open_pty();
    defer pty.deinit();

    const z = try runTool(allocator, zstty, pty.slaveName(), &.{"-g"});
    defer allocator.free(z.stdout);
    const g = try runTool(allocator, gstty, pty.slaveName(), &.{"-g"});
    defer allocator.free(g.stdout);

    try std.testing.expectEqual(@as(u8, 0), z.code);
    try std.testing.expectEqualStrings(g.stdout, z.stdout);
}

test "read path: zstty -a first line matches gstty" {
    const allocator = std.testing.allocator;
    const gstty = findGstty() orelse return error.SkipZigTest;
    const zstty = try zsttyBin();

    var pty = try Pty.open_pty();
    defer pty.deinit();

    const z = try runTool(allocator, zstty, pty.slaveName(), &.{"-a"});
    defer allocator.free(z.stdout);
    const g = try runTool(allocator, gstty, pty.slaveName(), &.{"-a"});
    defer allocator.free(g.stdout);

    const zline = std.mem.sliceTo(z.stdout, '\n');
    const gline = std.mem.sliceTo(g.stdout, '\n');
    try std.testing.expectEqualStrings(gline, zline);
}

test "read path: zstty speed query matches gstty" {
    const allocator = std.testing.allocator;
    const gstty = findGstty() orelse return error.SkipZigTest;
    const zstty = try zsttyBin();

    var pty = try Pty.open_pty();
    defer pty.deinit();

    const z = try runTool(allocator, zstty, pty.slaveName(), &.{"speed"});
    defer allocator.free(z.stdout);
    const g = try runTool(allocator, gstty, pty.slaveName(), &.{"speed"});
    defer allocator.free(g.stdout);

    try std.testing.expectEqualStrings(g.stdout, z.stdout);
}

test "set path: zstty settings produce the same termios as gstty" {
    const allocator = std.testing.allocator;
    const gstty = findGstty() orelse return error.SkipZigTest;
    const zstty = try zsttyBin();

    const cases = [_][]const []const u8{
        &.{"-echo"},
        &.{"cs7"},
        &.{"cs8"},
        &.{"parenb"},
        &.{"raw"},
        &.{"sane"},
        &.{"cooked"},
        &.{ "rows", "40" },
        &.{ "cols", "100" },
        &.{ "columns", "132" },
        &.{ "intr", "^A" },
        &.{ "erase", "^H" },
        &.{ "eof", "undef" },
        &.{ "kill", "^X" },
        &.{ "min", "5" },
        &.{ "time", "9" },
        &.{"9600"},
        &.{"19200"},
        &.{ "ispeed", "4800" },
        &.{ "ospeed", "2400" },
        &.{ "-icrnl", "ixoff" },
        &.{ "intr", "^C", "kill", "^U" },
        &.{ "cs8", "-parenb", "-cstopb" },
    };

    for (cases) |case| {
        var zc: u8 = 0;
        var gc: u8 = 0;
        const zg = try applyThenSaveG(allocator, zstty, gstty, case, &zc);
        defer allocator.free(zg);
        const gg = try applyThenSaveG(allocator, gstty, gstty, case, &gc);
        defer allocator.free(gg);

        std.testing.expectEqual(gc, zc) catch {
            std.debug.print("apply exit-code mismatch for '{s}': zstty={d} gstty={d}\n", .{ case[0], zc, gc });
            return error.TestFailed;
        };
        std.testing.expectEqualStrings(gg, zg) catch {
            std.debug.print("termios mismatch after applying '{s}':\n  zstty: {s}  gstty: {s}", .{ case[0], zg, gg });
            return error.TestFailed;
        };
    }
}

test "invalid argument is rejected with exit code 1" {
    const allocator = std.testing.allocator;
    const zstty = try zsttyBin();

    var pty = try Pty.open_pty();
    defer pty.deinit();

    const z = try runTool(allocator, zstty, pty.slaveName(), &.{"bogusflag"});
    defer allocator.free(z.stdout);
    try std.testing.expectEqual(@as(u8, 1), z.code);
}

test "output style may not be combined with modes (GNU parity)" {
    const allocator = std.testing.allocator;
    const zstty = try zsttyBin();

    var pty = try Pty.open_pty();
    defer pty.deinit();

    // `-g echo` must error, matching GNU: "when specifying an output style,
    // modes may not be set".
    const z = try runTool(allocator, zstty, pty.slaveName(), &.{ "-g", "echo" });
    defer allocator.free(z.stdout);
    try std.testing.expectEqual(@as(u8, 1), z.code);
}

test "documented sane bytes (macOS ABI, no GNU binary required)" {
    if (!builtin.os.tag.isDarwin()) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const zstty = try zsttyBin();

    var pty = try Pty.open_pty();
    defer pty.deinit();

    // Apply `sane`, then read `-g`. On the macOS termios ABI GNU coreutils'
    // canonical sane flag words are iflag=0x2302 (BRKINT|ICRNL|IXON|IMAXBEL),
    // oflag=0x3 (OPOST|ONLCR), cflag=0x4b00 (CS8|CREAD|HUPCL),
    // lflag=0x5cf (ECHOKE|ECHOE|ECHOK|ECHO|ECHOCTL|ISIG|ICANON|IEXTEN), with the
    // stock macOS control-character defaults and NCCS=20. This exact string was
    // produced by `gstty -F <pts> sane; gstty -F <pts> -g` (coreutils 9.10).
    const apply = try runTool(allocator, zstty, pty.slaveName(), &.{"sane"});
    allocator.free(apply.stdout);
    try std.testing.expectEqual(@as(u8, 0), apply.code);

    const save = try runTool(allocator, zstty, pty.slaveName(), &.{"-g"});
    defer allocator.free(save.stdout);

    const expected = "2302:3:4b00:5cf:4:ff:ff:7f:17:15:12:ff:3:1c:1a:19:11:13:16:f:1:0:14:ff\n";
    try std.testing.expectEqualStrings(expected, save.stdout);
}
