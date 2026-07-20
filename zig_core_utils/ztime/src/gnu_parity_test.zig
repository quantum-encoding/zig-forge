//! Externally-anchored parity tests for ztime.
//!
//! These are NOT roundtrip tests. Each test drives the *built* `ztime` binary and
//! compares its bytes / exit status against behavior that is externally specified —
//! either GNU `time`'s documented semantics (info time / man 1 time) or an
//! independently-computed system value (the exit status of a shell command, the
//! system page size from getpagesize(2)). No GNU `time` / `gtime` binary is installed
//! on this host (Homebrew coreutils ships `gtimeout` but not `time`; GNU time is the
//! separate `gnu-time` formula), so the anchors are the documented spec with the
//! expected bytes written literally below, each with its source cited inline.
//!
//! Anchoring sources:
//!   * GNU time manual, "Setting the Format" — format specifiers %e %E %U %S %P %M
//!     %c %w %x %C %%, and the "Command terminated by signal N" message.
//!     https://www.gnu.org/software/time/  (info '(time)')
//!   * getrusage(2) on Darwin: ru_maxrss is reported in BYTES; on Linux in KILOBYTES.
//!     Apple man page: "ru_maxrss  the maximum resident set size utilized (in bytes)."
//!   * POSIX: a wrapper command exits with the exit status of the command it ran.

const std = @import("std");
const build_options = @import("build_options");

const ZTIME = build_options.ztime_path;

// libc primitives (std.posix no longer exposes fork/execvp/waitpid in 0.16).
extern "c" fn fork() c_int;
extern "c" fn execvp(file: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;
extern "c" fn waitpid(pid: c_int, status: *c_int, options: c_int) c_int;
extern "c" fn getpagesize() c_int;

fn WIFEXITED(status: c_int) bool {
    return (status & 0x7f) == 0;
}
fn WEXITSTATUS(status: c_int) u8 {
    return @intCast((status >> 8) & 0xff);
}

const RunResult = struct {
    exit_code: ?u8, // set when the process exited normally
    stderr: []u8, // captured timing stream (caller owns)

    fn deinit(self: RunResult, a: std.mem.Allocator) void {
        a.free(self.stderr);
    }
};

/// Run `ztime` with the given trailing args (argv[0] is filled in as ZTIME).
/// stdout of the child command is sent to /dev/null; ztime's timing output (stderr)
/// is redirected to a temp file and returned.
fn runZtime(a: std.mem.Allocator, extra_args: []const []const u8) !RunResult {
    const c = std.c;

    // Unique temp file for this run's stderr capture.
    var name_buf: [128]u8 = undefined;
    counter += 1;
    const err_path = try std.fmt.bufPrintZ(&name_buf, "/tmp/ztime_parity_{d}_{d}.err", .{
        std.c.getpid(), counter,
    });

    // Build argv: ZTIME + extra_args + null.
    var argv = std.ArrayListUnmanaged(?[*:0]const u8).empty;
    defer argv.deinit(a);
    const ztime_z = try a.dupeZ(u8, ZTIME);
    defer a.free(ztime_z);
    try argv.append(a, ztime_z.ptr);
    var dups = std.ArrayListUnmanaged([:0]u8).empty;
    defer {
        for (dups.items) |d| a.free(d);
        dups.deinit(a);
    }
    for (extra_args) |arg| {
        const z = try a.dupeZ(u8, arg);
        try dups.append(a, z);
        try argv.append(a, z.ptr);
    }
    try argv.append(a, null);
    const argv_ptr: [*:null]const ?[*:0]const u8 = @ptrCast(argv.items.ptr);

    const pid = fork();
    if (pid < 0) return error.ForkFailed;
    if (pid == 0) {
        // Child: stdout -> /dev/null, stderr -> temp file.
        const devnull = c.open("/dev/null", c.O{ .ACCMODE = .WRONLY }, @as(c.mode_t, 0));
        if (devnull >= 0) {
            _ = c.dup2(devnull, c.STDOUT_FILENO);
            _ = c.close(devnull);
        }
        const errfd = c.open(err_path.ptr, c.O{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(c.mode_t, 0o644));
        if (errfd >= 0) {
            _ = c.dup2(errfd, c.STDERR_FILENO);
            _ = c.close(errfd);
        }
        _ = execvp(ztime_z.ptr, argv_ptr);
        std.process.exit(127);
    }

    var status: c_int = 0;
    _ = waitpid(pid, &status, 0);

    const stderr_bytes = try readAllFile(a, err_path);
    _ = std.c.unlink(err_path);

    return .{
        .exit_code = if (WIFEXITED(status)) WEXITSTATUS(status) else null,
        .stderr = stderr_bytes,
    };
}

/// Read an entire file into a freshly-allocated slice using libc (the 0.16 std.fs /
/// std.Io reader stack is heavier than needed for a small capture file).
fn readAllFile(a: std.mem.Allocator, path: [*:0]const u8) ![]u8 {
    const c = std.c;
    const fd = c.open(path, c.O{ .ACCMODE = .RDONLY }, @as(c.mode_t, 0));
    if (fd < 0) return error.OpenFailed;
    defer _ = c.close(fd);

    var list = std.ArrayListUnmanaged(u8).empty;
    errdefer list.deinit(a);
    var chunk: [4096]u8 = undefined;
    while (true) {
        const n = c.read(fd, &chunk, chunk.len);
        if (n < 0) return error.ReadFailed;
        if (n == 0) break;
        try list.appendSlice(a, chunk[0..@intCast(n)]);
    }
    return list.toOwnedSlice(a);
}

var counter: u64 = 0;

// ---------------------------------------------------------------------------

test "exit status is passed through (POSIX: wrapper returns command's status)" {
    const a = std.testing.allocator;
    const r = try runZtime(a, &.{ "sh", "-c", "exit 42" });
    defer r.deinit(a);
    // Anchor: `time COMMAND` returns COMMAND's exit status. 42 is independent of ztime.
    try std.testing.expectEqual(@as(?u8, 42), r.exit_code);
}

test "%x prints the command's exit status (GNU: %x = exit status)" {
    const a = std.testing.allocator;
    const r = try runZtime(a, &.{ "-f", "%x", "sh", "-c", "exit 7" });
    defer r.deinit(a);
    try std.testing.expectEqualStrings("7", r.stderr);
}

test "%C prints command name and arguments (GNU: %C)" {
    const a = std.testing.allocator;
    const r = try runZtime(a, &.{ "-f", "%C", "echo", "hello", "world" });
    defer r.deinit(a);
    try std.testing.expectEqualStrings("echo hello world", r.stderr);
}

test "%% expands to a single literal percent (GNU: %%)" {
    const a = std.testing.allocator;
    const r = try runZtime(a, &.{ "-f", "%%", "true" });
    defer r.deinit(a);
    try std.testing.expectEqualStrings("%", r.stderr);
}

test "%e and %E are distinct shapes (GNU: %e=seconds, %E=[h:]mm:ss.ss)" {
    const a = std.testing.allocator;
    const r = try runZtime(a, &.{ "-f", "%e|%E", "true" });
    defer r.deinit(a);
    // Split on '|'.
    const bar = std.mem.indexOfScalar(u8, r.stderr, '|') orelse return error.NoSeparator;
    const e = r.stderr[0..bar];
    const E = r.stderr[bar + 1 ..];

    // %e: plain seconds "D.DD" — must NOT contain a colon.
    try std.testing.expect(std.mem.indexOfScalar(u8, e, ':') == null);
    try std.testing.expect(std.mem.indexOfScalar(u8, e, '.') != null);

    // %E: clock format "M:SS.ss" — MUST contain a colon (this is the whole point of
    // the fix; before it, %E was aliased to %e and had no colon).
    try std.testing.expect(std.mem.indexOfScalar(u8, E, ':') != null);
    // Shape check: <int>:<2 digits>.<2 digits> for a sub-hour duration.
    const colon = std.mem.indexOfScalar(u8, E, ':').?;
    const dot = std.mem.indexOfScalar(u8, E, '.') orelse return error.NoDot;
    try std.testing.expectEqual(@as(usize, 2), dot - (colon + 1)); // exactly 2 second digits
    try std.testing.expectEqual(@as(usize, 2), E.len - (dot + 1)); // exactly 2 fractional digits
}

test "%M is normalized to KB (Darwin ru_maxrss is bytes; must not be 1024x inflated)" {
    const a = std.testing.allocator;
    const r = try runZtime(a, &.{ "-f", "%M", "true" });
    defer r.deinit(a);
    const kb = try std.fmt.parseInt(i64, std.mem.trim(u8, r.stderr, " \n"), 10);
    // A freshly-forked `true` cannot occupy hundreds of megabytes. If ru_maxrss (bytes
    // on Darwin) were reported as if it were KB, this value would be ~1_000_000+ (i.e.
    // ~1 GB expressed in KB). The normalization to KB keeps it a small multiple of a MB.
    // This bound is the mutation anchor for the maxRssKb() /1024 Darwin fix.
    try std.testing.expect(kb > 0);
    try std.testing.expect(kb < 100_000);
}

test "%Z equals the real system page size (getpagesize(2))" {
    const a = std.testing.allocator;
    const r = try runZtime(a, &.{ "-f", "%Z", "true" });
    defer r.deinit(a);
    const reported = try std.fmt.parseInt(i64, std.mem.trim(u8, r.stderr, " \n"), 10);
    const expected: i64 = getpagesize(); // independent of ztime
    try std.testing.expectEqual(expected, reported);
}

test "signal death prints 'Command terminated by signal N' and exits 128+N (GNU)" {
    const a = std.testing.allocator;
    const r = try runZtime(a, &.{ "sh", "-c", "kill -TERM $$" });
    defer r.deinit(a);
    // GNU time emits exactly this line to the timing stream on signal death.
    try std.testing.expect(std.mem.indexOf(u8, r.stderr, "Command terminated by signal 15") != null);
    // ztime folds the signal into 128+SIGTERM = 143.
    try std.testing.expectEqual(@as(?u8, 143), r.exit_code);
}
