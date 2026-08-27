//! PTY (Pseudo-Terminal) Management
//!
//! Handles creation and management of pseudo-terminals.
//! Linux uses the Unix98 PTY interface (/dev/ptmx); Darwin (macOS) uses
//! openpty(3) from libSystem. The rest of the lifecycle (fork/exec, raw mode,
//! winsize ioctls) is shared across both platforms via libc.

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const c = std.c;

const is_darwin = builtin.os.tag.isDarwin();

/// libc ioctl — used for the portable winsize / controlling-terminal requests.
extern "c" fn ioctl(fd: c_int, request: c_ulong, ...) c_int;
/// openpty(3) — Darwin (libSystem) and the BSDs. On Linux we use /dev/ptmx
/// instead to avoid the -lutil link dependency.
extern "c" fn openpty(
    amaster: *c_int,
    aslave: *c_int,
    name: ?[*]u8,
    termp: ?*const anyopaque,
    winp: ?*const Winsize,
) c_int;

/// Platform-dependent ioctl request numbers. The winsize + controlling-terminal
/// requests have different encodings on Linux vs Darwin.
const tioc = struct {
    pub const GWINSZ: c_ulong = if (is_darwin) 0x40087468 else 0x5413;
    pub const SWINSZ: c_ulong = if (is_darwin) 0x80087467 else 0x5414;
    pub const SCTTY: c_ulong = if (is_darwin) 0x20007461 else 0x540E;
};

/// Linux-only /dev/ptmx ioctl constants (Unix98 PTY allocation).
const linux_pty_ioctl = struct {
    /// Get the PTY slave number — _IOR('T', 0x30, unsigned int)
    pub const TIOCGPTN: c_ulong = 0x80045430;
    /// Unlock the PTY slave — _IOW('T', 0x31, int)
    pub const TIOCSPTLCK: c_ulong = 0x40045431;
};

/// Window size structure
pub const Winsize = extern struct {
    ws_row: u16,
    ws_col: u16,
    ws_xpixel: u16,
    ws_ypixel: u16,
};

/// PTY pair (master + slave)
pub const Pty = struct {
    master_fd: posix.fd_t,
    slave_fd: posix.fd_t,
    slave_path: [32]u8,
    slave_path_len: usize,
    child_pid: ?posix.pid_t,
    /// Set when `isAlive` (or `wait`) reaps the child. Null while it runs.
    exit_status: ?ExitStatus = null,

    rows: u16,
    cols: u16,

    const Self = @This();

    /// Put the master in non-blocking mode.
    ///
    /// Load-bearing for `write`: on a BLOCKING master, a child that has stopped
    /// reading parks write() inside the kernel and no userspace budget can
    /// reach it — the EAGAIN path below would simply never run. Reads are
    /// unaffected because every read site is poll(POLLIN)-gated and treats an
    /// error as "nothing ready".
    fn setMasterNonblock(master_fd: c_int) void {
        const fl = c.fcntl(master_fd, c.F.GETFL, @as(c_int, 0));
        if (fl < 0) return;
        _ = c.fcntl(master_fd, c.F.SETFL, fl | @as(c_int, @bitCast(c.O{ .NONBLOCK = true })));
    }

    /// Create a new PTY pair (master + slave), dispatching to the platform path.
    pub fn create() !Self {
        return if (is_darwin) createDarwin() else createLinux();
    }

    /// Darwin: allocate the pair with openpty(3) from libSystem.
    fn createDarwin() !Self {
        var master_fd: c_int = -1;
        var slave_fd: c_int = -1;
        var ws = Winsize{ .ws_row = 24, .ws_col = 80, .ws_xpixel = 0, .ws_ypixel = 0 };
        if (openpty(&master_fd, &slave_fd, null, null, &ws) != 0) {
            return error.OpenptyFailed;
        }
        // Masters must not leak into spawned shells: a later pane's child
        // inheriting an earlier pane's master keeps that PTY alive forever
        // (and the same class of leak made ctl connections never EOF).
        _ = c.fcntl(master_fd, c.F.SETFD, @as(c_int, c.FD_CLOEXEC));
        setMasterNonblock(master_fd);

        // openpty hands back the slave fd directly; we don't track a path.
        var slave_path: [32]u8 = undefined;
        @memset(&slave_path, 0);

        return Self{
            .master_fd = master_fd,
            .slave_fd = slave_fd,
            .slave_path = slave_path,
            .slave_path_len = 0,
            .child_pid = null,
            .rows = 24,
            .cols = 80,
        };
    }

    /// Linux: allocate the pair via the Unix98 /dev/ptmx interface.
    fn createLinux() !Self {
        // Open the PTY master device
        const master_fd = try posix.openatZ(c.AT.FDCWD, "/dev/ptmx", .{
            .ACCMODE = .RDWR,
            .NOCTTY = true,
        }, 0);
        errdefer _ = std.c.close(master_fd);
        // Same CLOEXEC rationale as the Darwin path: masters never reach children.
        _ = c.fcntl(master_fd, c.F.SETFD, @as(c_int, c.FD_CLOEXEC));
        setMasterNonblock(master_fd);

        // Unlock the slave
        var unlock: c_int = 0;
        doIoctl(master_fd, linux_pty_ioctl.TIOCSPTLCK, &unlock) catch {
            return error.PtyUnlockFailed;
        };

        // Get the slave number
        var pts_num: c_uint = 0;
        doIoctl(master_fd, linux_pty_ioctl.TIOCGPTN, &pts_num) catch {
            return error.PtyGetSlaveNumFailed;
        };

        // Construct slave path with null terminator
        var slave_path: [32]u8 = undefined;
        @memset(&slave_path, 0);
        const path_slice = std.fmt.bufPrint(&slave_path, "/dev/pts/{d}", .{pts_num}) catch {
            return error.PathTooLong;
        };
        const path_len = path_slice.len;
        slave_path[path_len] = 0; // Ensure null termination

        // Open the slave device
        const slave_fd = try posix.openatZ(c.AT.FDCWD, slave_path[0..path_len :0], .{
            .ACCMODE = .RDWR,
            .NOCTTY = true,
        }, 0);
        errdefer _ = std.c.close(slave_fd);

        return Self{
            .master_fd = master_fd,
            .slave_fd = slave_fd,
            .slave_path = slave_path,
            .slave_path_len = path_len,
            .child_pid = null,
            .rows = 24,
            .cols = 80,
        };
    }

    /// Close the PTY
    pub fn close(self: *Self) void {
        if (self.child_pid) |pid| {
            // TERM, then reap. Without the waitpid every closed pane left a
            // zombie for the life of the host process — the GUI embeddings
            // (CosmicDuck/aiconductor) run for days and accumulate one per
            // closed tab/split. If TERM hasn't landed yet, escalate to KILL
            // and reap synchronously (KILL cannot be caught; the reap is
            // immediate, no unbounded block).
            _ = posix.kill(pid, posix.SIG.TERM) catch {};
            var i: u8 = 0;
            var reaped = false;
            while (i < 20) : (i += 1) { // ~100ms grace for a clean TERM exit
                if (c.waitpid(pid, null, c.W.NOHANG) != 0) {
                    reaped = true;
                    break;
                }
                var no_fds = [_]posix.pollfd{};
                _ = posix.poll(&no_fds, 5) catch {}; // 5ms portable sleep
            }
            if (!reaped) {
                _ = posix.kill(pid, posix.SIG.KILL) catch {};
                _ = c.waitpid(pid, null, 0);
            }
            self.child_pid = null;
        }

        if (self.slave_fd >= 0) _ = std.c.close(self.slave_fd);
        _ = std.c.close(self.master_fd);
    }

    /// Get slave path as a slice
    pub fn getSlavePath(self: *const Self) []const u8 {
        return self.slave_path[0..self.slave_path_len];
    }

    /// Spawn a child process in the PTY. `argv` must be NUL-terminated (the
    /// terminator is mandatory — execve reads it to find the end of the vector;
    /// passing a non-terminated array makes execve dereference stack garbage as
    /// argv[1], which fails with EFAULT on Darwin).
    pub fn spawn(self: *Self, argv: [*:null]const ?[*:0]const u8, envp: [*:null]const ?[*:0]const u8) !void {
        const pid = c.fork();

        if (pid < 0) {
            return error.ForkFailed;
        } else if (pid == 0) {
            // Child process
            self.setupChild() catch {
                std.c._exit(1);
            };

            // Execute the command - shell path (argv[0]) is already absolute.
            _ = c.execve(argv[0].?, argv, envp);
            // If we reach here, exec failed
            std.c._exit(127);
        } else {
            // Parent process
            self.child_pid = pid;

            // Close slave fd in parent - we only use master
            _ = std.c.close(self.slave_fd);
            self.slave_fd = -1;
        }
    }

    /// Setup child process (called after fork in child)
    fn setupChild(self: *Self) !void {
        // Close master fd in child
        _ = std.c.close(self.master_fd);

        // Create a new session
        if (c.setsid() < 0) return error.SetsidFailed;

        // Set the slave as the controlling terminal
        const zero: c_int = 0;
        doIoctl(self.slave_fd, tioc.SCTTY, &zero) catch {
            return error.SetControllingTerminalFailed;
        };

        // Duplicate slave to stdin/stdout/stderr
        if (c.dup2(self.slave_fd, 0) < 0) return error.Dup2Failed;
        if (c.dup2(self.slave_fd, 1) < 0) return error.Dup2Failed;
        if (c.dup2(self.slave_fd, 2) < 0) return error.Dup2Failed;

        // Close original slave fd if it's not 0, 1, or 2
        if (self.slave_fd > 2) {
            _ = std.c.close(self.slave_fd);
        }
    }

    /// Set the window size of the PTY
    pub fn setSize(self: *Self, rows: u16, cols: u16) !void {
        const ws = Winsize{
            .ws_row = rows,
            .ws_col = cols,
            .ws_xpixel = 0,
            .ws_ypixel = 0,
        };

        try doIoctl(self.master_fd, tioc.SWINSZ, &ws);

        self.rows = rows;
        self.cols = cols;

        // Send SIGWINCH to the child process group
        if (self.child_pid) |pid| {
            _ = posix.kill(-pid, posix.SIG.WINCH) catch {};
        }
    }

    /// Get the current window size
    pub fn getSize(self: *const Self) !Winsize {
        var ws: Winsize = undefined;
        try doIoctl(self.master_fd, tioc.GWINSZ, &ws);
        return ws;
    }

    /// Read data from the PTY master
    pub fn read(self: *Self, buf: []u8) !usize {
        return posix.read(self.master_fd, buf);
    }

    /// How long `write` will wait on a full kernel buffer WITHOUT the child
    /// consuming a single byte before it gives up and returns short. Any
    /// progress resets the allowance, so a slow-but-reading child still gets
    /// the whole payload; only a child that has stopped reading (Ctrl-Z'd,
    /// wedged, dead-but-unreaped) hits the bound.
    ///
    /// This is a hard requirement, not a tuning knob: `tmux_paste` runs on the
    /// host's MAIN thread, so an unbounded wait here freezes the UI.
    pub const WRITE_STALL_BUDGET_MS: i32 = 250;
    /// One EAGAIN wait. The budget is charged this much per wait regardless of
    /// how early poll returns, which caps the loop at BUDGET/SLICE iterations
    /// even when the fd flaps writable-then-EAGAIN and no wait actually elapses.
    const WRITE_POLL_SLICE_MS: i32 = 25;

    /// Write `data` to the PTY master (sends to shell), looping over partial
    /// writes so a big paste isn't truncated by a kernel buffer that only
    /// accepted part of it.
    ///
    /// Returns the number of bytes ACTUALLY written, which may be short of
    /// `data.len`: a child that is not reading stalls the write, and after
    /// `WRITE_STALL_BUDGET_MS` of no progress we return what got through
    /// rather than block the caller forever. Callers that care must check the
    /// count — `tmux_paste` reports it to the host.
    pub fn write(self: *Self, data: []const u8) !usize {
        var off: usize = 0;
        var budget_ms = WRITE_STALL_BUDGET_MS;
        while (off < data.len) {
            const ret = c.write(self.master_fd, data.ptr + off, data.len - off);
            if (ret > 0) {
                off += @intCast(ret);
                budget_ms = WRITE_STALL_BUDGET_MS; // progress: the child is reading
                continue;
            }
            if (ret == 0) break;
            switch (posix.errno(ret)) {
                .INTR => continue, // interrupted — retry, not a stall
                .AGAIN => {
                    if (budget_ms <= 0) break; // stalled: return the partial count
                    const slice = @min(budget_ms, WRITE_POLL_SLICE_MS);
                    budget_ms -= slice;
                    var pfd = [_]posix.pollfd{.{ .fd = self.master_fd, .events = posix.POLL.OUT, .revents = 0 }};
                    _ = posix.poll(&pfd, slice) catch break;
                    continue;
                },
                else => return error.WriteFailed,
            }
        }
        return off;
    }

    /// How the child ended, once reaped. `signal` is 0 for a normal exit;
    /// `code` is 0 when a signal killed it (POSIX wait status has one or the
    /// other, never both).
    pub const ExitStatus = struct {
        code: u8 = 0,
        signal: u8 = 0,
    };

    /// Whether the child process is still running.
    ///
    /// Reaps it (WNOHANG) when it has exited, recording `exit_status` and
    /// CLEARING `child_pid`. Clearing matters: the old version reaped but left
    /// the pid set, so a later `close()` sent SIGTERM/SIGKILL to a pid the
    /// kernel had already recycled onto some unrelated process.
    pub fn isAlive(self: *Self) bool {
        const pid = self.child_pid orelse return false;
        var status: c_int = 0;
        const r = c.waitpid(pid, &status, c.W.NOHANG);
        if (r == 0) return true; // still running
        if (r > 0) self.exit_status = decodeWaitStatus(status);
        // r < 0 means already reaped or never ours — not alive either way.
        self.child_pid = null;
        return false;
    }

    /// Wait for child process to exit
    pub fn wait(self: *Self) !u32 {
        if (self.child_pid) |pid| {
            var status: c_int = 0;
            _ = c.waitpid(pid, &status, 0);
            self.child_pid = null;
            self.exit_status = decodeWaitStatus(status);
            // Extract signal from status (WTERMSIG)
            return @intCast(status & 0x7f);
        }
        return 0;
    }
};

/// Split a POSIX wait(2) status into exit code / terminating signal. The low 7
/// bits hold the signal (0 for a normal exit) and bits 8-15 the exit code —
/// the same layout on Linux and Darwin.
fn decodeWaitStatus(status: c_int) Pty.ExitStatus {
    const sig: u8 = @intCast(status & 0x7f);
    if (sig != 0) return .{ .code = 0, .signal = sig };
    return .{ .code = @intCast((status >> 8) & 0xff), .signal = 0 };
}

/// True when `err` means "this environment refuses PTY allocation" rather than
/// "the code under test is wrong". A sandbox that denies /dev/ptmx surfaces
/// `OpenptyFailed` on Darwin and `AccessDenied`/`FileNotFound` on Linux; a
/// container out of PTY slots surfaces the quota errors.
pub fn isUnavailableError(err: anyerror) bool {
    return switch (err) {
        error.OpenptyFailed,
        error.FileNotFound,
        error.AccessDenied,
        error.PermissionDenied,
        error.DeviceBusy,
        error.NoDevice,
        error.PtyUnlockFailed,
        error.PtyGetSlaveNumFailed,
        error.SystemResources,
        error.ProcessFdQuotaExceeded,
        error.SystemFdQuotaExceeded,
        => true,
        else => false,
    };
}

/// Probe result for `available()`. Single-threaded test use; the probe is a
/// pure open/close of a PTY pair, so caching it costs nothing and avoids
/// burning an fd per test.
var availability_probe: ?bool = null;

/// Whether this environment can allocate a PTY at all.
pub fn available() bool {
    if (availability_probe) |a| return a;
    const probe = Pty.create() catch |err| {
        if (isUnavailableError(err)) {
            availability_probe = false;
            return false;
        }
        // An unexpected error is not an availability answer — report available
        // so the caller's own error surfaces instead of being masked as a skip.
        availability_probe = true;
        return true;
    };
    var p = probe;
    p.close();
    availability_probe = true;
    return true;
}

/// `try pty.skipIfUnavailable();` at the top of a test that needs a real PTY,
/// so `zig build test` is green in a sandbox that denies PTY allocation.
pub fn skipIfUnavailable() error{SkipZigTest}!void {
    if (!available()) return error.SkipZigTest;
}

/// Generic libc ioctl wrapper. `arg` must be a pointer to the request payload.
fn doIoctl(fd: posix.fd_t, request: c_ulong, arg: anytype) !void {
    switch (@typeInfo(@TypeOf(arg))) {
        .pointer => {},
        else => @compileError("ioctl arg must be a pointer"),
    }
    if (ioctl(@intCast(fd), request, arg) == -1) return error.IoctlFailed;
}

/// Raw terminal mode utilities
pub const RawMode = struct {
    original: posix.termios,
    fd: posix.fd_t,

    const Self = @This();

    /// Enter raw mode on a terminal
    pub fn enter(fd: posix.fd_t) !Self {
        const original = try posix.tcgetattr(fd);

        var raw = original;

        // Input modes: no break, no CR to NL, no parity check, no strip char,
        // no start/stop output control
        raw.iflag.BRKINT = false;
        raw.iflag.ICRNL = false;
        raw.iflag.INPCK = false;
        raw.iflag.ISTRIP = false;
        raw.iflag.IXON = false;

        // Output modes: disable post processing
        raw.oflag.OPOST = false;

        // Control modes: set 8 bit chars
        raw.cflag.CSIZE = .CS8;

        // Local modes: echo off, canonical off, no extended functions,
        // no signal chars
        raw.lflag.ECHO = false;
        raw.lflag.ICANON = false;
        raw.lflag.IEXTEN = false;
        raw.lflag.ISIG = false;

        // Control chars: set read timeout
        raw.cc[@intFromEnum(posix.V.MIN)] = 0;
        raw.cc[@intFromEnum(posix.V.TIME)] = 1; // 100ms timeout

        try posix.tcsetattr(fd, .FLUSH, raw);

        return Self{
            .original = original,
            .fd = fd,
        };
    }

    /// Exit raw mode, restoring original terminal settings
    pub fn exit(self: *Self) void {
        posix.tcsetattr(self.fd, .FLUSH, self.original) catch {};
    }
};

/// Get the current terminal size
pub fn getTerminalSize(fd: posix.fd_t) !Winsize {
    var ws: Winsize = undefined;
    try doIoctl(fd, tioc.GWINSZ, &ws);
    return ws;
}

// =============================================================================
// Tests
// =============================================================================

test "pty create and close" {
    // Needs a real PTY: skipped wherever the environment denies allocation.
    const pty = Pty.create() catch |err| {
        if (isUnavailableError(err)) return error.SkipZigTest;
        return err;
    };

    var pty_var = pty;
    defer pty_var.close();

    try std.testing.expect(pty_var.master_fd >= 0);
    try std.testing.expect(pty_var.slave_fd >= 0);
    if (!is_darwin) {
        // Linux exposes the slave node as /dev/pts/N. openpty(3) on Darwin
        // hands back the fd directly, so we don't track a path there.
        try std.testing.expect(std.mem.startsWith(u8, pty_var.getSlavePath(), "/dev/pts/"));
    }
}

/// Put the slave in the raw-ish mode a real shell's line editor sets (zle,
/// readline: ICANON off, no echo). It matters for backpressure: in CANONICAL
/// mode macOS's line discipline silently DISCARDS master writes once the
/// canonical buffer overflows with no newline (measured: 2.6 MB written, 0
/// bytes readable), so a canonical slave never produces the stall under test.
fn makeSlaveRaw(p: *Pty) !void {
    var t = try posix.tcgetattr(p.slave_fd);
    t.lflag.ICANON = false;
    t.lflag.ECHO = false;
    t.lflag.ISIG = false;
    t.iflag.IXON = false;
    try posix.tcsetattr(p.slave_fd, .NOW, t);
}

test "write is bounded when the child stops reading" {
    // A PTY nobody drains: the tty input queue fills (~1 KiB) and every
    // further write returns EAGAIN forever — the exact shape of a Ctrl-Z'd or
    // wedged shell, which used to park the host's main thread inside write().
    var p = Pty.create() catch |err| {
        if (isUnavailableError(err)) return error.SkipZigTest;
        return err;
    };
    defer p.close();
    try makeSlaveRaw(&p);

    const big = try std.testing.allocator.alloc(u8, 1 << 20);
    defer std.testing.allocator.free(big);
    @memset(big, 'x');

    const started = monotonicMsForTest();
    const n = try p.write(big);
    const elapsed = monotonicMsForTest() - started;

    // Returns SHORT rather than hanging or claiming a delivery that did not
    // happen. (Some bytes DO land — the queue had room for about 1 KiB.)
    try std.testing.expect(n < big.len);
    try std.testing.expect(n > 0);
    // And it comes back on the stall budget. The pre-fix loop waited 1000ms
    // per EAGAIN without bound; generous ceiling so a loaded box can't flake.
    try std.testing.expect(elapsed < Pty.WRITE_STALL_BUDGET_MS * 4);
}

test "write delivers everything when the child IS reading" {
    // The bound must not cost correctness on the normal path: the payload goes
    // through in full when someone drains the other end, even though it is
    // 250x larger than the tty queue that triggers the stall above.
    var p = Pty.create() catch |err| {
        if (isUnavailableError(err)) return error.SkipZigTest;
        return err;
    };
    defer p.close();
    try makeSlaveRaw(&p);

    const payload_len: usize = 256 * 1024;
    const big = try std.testing.allocator.alloc(u8, payload_len);
    defer std.testing.allocator.free(big);
    @memset(big, 'y');

    const Drainer = struct {
        fd: posix.fd_t,
        want: usize,
        got: usize = 0,
        fn run(self: *@This()) void {
            var buf: [4096]u8 = undefined;
            while (self.got < self.want) {
                var pfd = [_]posix.pollfd{.{ .fd = self.fd, .events = posix.POLL.IN, .revents = 0 }};
                const ready = posix.poll(&pfd, 2000) catch break;
                if (ready == 0) break;
                const r = posix.read(self.fd, &buf) catch break;
                if (r == 0) break;
                self.got += r;
            }
        }
    };
    var drainer = Drainer{ .fd = p.slave_fd, .want = payload_len };
    const th = try std.Thread.spawn(.{}, Drainer.run, .{&drainer});

    const n = try p.write(big);
    th.join();
    try std.testing.expectEqual(payload_len, n);
}

/// Local monotonic clock for the write-budget test. `std.time.Instant` and
/// `std.time.Timer` do not exist in Zig 0.16 (see repo CLAUDE.md); this is the
/// clock_gettime pattern the rest of the tree uses.
fn monotonicMsForTest() i64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    return @intCast(@as(i128, ts.sec) * 1000 + @divTrunc(ts.nsec, 1_000_000));
}

test "winsize struct size" {
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(Winsize));
}
