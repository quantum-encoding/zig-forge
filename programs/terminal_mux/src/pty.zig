//! PTY (Pseudo-Terminal) Management
//!
//! Handles creation and management of pseudo-terminals.
//! Both platforms allocate from /dev/ptmx with each end opened O_CLOEXEC
//! (Linux via TIOCSPTLCK/TIOCGPTN, Darwin via grantpt/unlockpt/ptsname_r).
//! The rest of the lifecycle (fork/exec, raw mode, winsize ioctls, reaping)
//! is shared via libc.

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const c = std.c;

const is_darwin = builtin.os.tag.isDarwin();

/// libc ioctl — used for the portable winsize / controlling-terminal requests.
extern "c" fn ioctl(fd: c_int, request: c_ulong, ...) c_int;
extern "c" fn grantpt(fd: c_int) c_int;
extern "c" fn unlockpt(fd: c_int) c_int;
extern "c" fn ptsname_r(fd: c_int, buf: [*]u8, len: usize) c_int;

/// pthread-backed mutex (this toolchain's std has no std.Thread.Mutex).
pub const Mutex = struct {
    inner: std.c.pthread_mutex_t = std.c.PTHREAD_MUTEX_INITIALIZER,

    pub fn lock(self: *Mutex) void {
        _ = std.c.pthread_mutex_lock(&self.inner);
    }

    pub fn unlock(self: *Mutex) void {
        _ = std.c.pthread_mutex_unlock(&self.inner);
    }
};

/// Serializes fork against fd creation that cannot be atomically CLOEXEC.
/// Every terminal_mux site that creates an fd and then sets FD_CLOEXEC with a
/// separate fcntl (Darwin has no SOCK_CLOEXEC / accept4) holds it across both
/// calls, and every fork holds it across the fork, so a child never inherits
/// such an fd in the gap. PTY ends are opened O_CLOEXEC and need no lock.
pub var fd_lock: Mutex = .{};

/// Create-then-CLOEXEC under `fd_lock`. `make` returns the new fd or < 0.
pub fn cloexecUnderLock(make: anytype, args: anytype) c_int {
    fd_lock.lock();
    defer fd_lock.unlock();
    const fd: c_int = @call(.auto, make, args);
    if (fd >= 0) _ = c.fcntl(fd, c.F.SETFD, @as(c_int, c.FD_CLOEXEC));
    return fd;
}

/// How long a closed pane's process group has to exit after the hangup
/// before the reaper sends SIGKILL to the group.
pub const REAP_GRACE_MS: isize = 2000;

/// Process-wide reaper for children of closed PTYs.
///
/// Darwin: one thread blocked in kevent on EVFILT_PROC/NOTE_EXIT per adopted
/// pid, plus a one-shot EVFILT_TIMER (same ident) for the SIGKILL escalation.
/// Nothing polls and no caller blocks. Linux: a detached thread per pid
/// waiting on its pidfd with the same grace.
pub const reaper = struct {
    var mutex: Mutex = .{};
    var kq: c_int = -1;
    var started = false;
    /// Pids adopted and not yet reaped. Guards the escalation against a
    /// timer that outlives its pid (a recycled pid must never be killed).
    /// Value: the monotonic ms after which the group is SIGKILLed.
    var pending: std.AutoHashMapUnmanaged(posix.pid_t, i64) = .empty;
    const gpa = std.heap.c_allocator;

    /// Number of adopted children not yet reaped (tests, diagnostics).
    pub fn pendingCount() usize {
        mutex.lock();
        defer mutex.unlock();
        return pending.count();
    }

    fn monotonicMs() i64 {
        var ts: std.c.timespec = undefined;
        _ = std.c.clock_gettime(.MONOTONIC, &ts);
        return @intCast(@as(i128, ts.sec) * 1000 + @divTrunc(ts.nsec, 1_000_000));
    }

    pub fn adopt(pid: posix.pid_t) void {
        if (is_darwin) adoptDarwin(pid) else adoptLinux(pid);
    }

    fn adoptDarwin(pid: posix.pid_t) void {
        mutex.lock();
        defer mutex.unlock();
        if (!started) {
            kq = c.kqueue();
            if (kq >= 0) {
                _ = c.fcntl(kq, c.F.SETFD, @as(c_int, c.FD_CLOEXEC));
                if (std.Thread.spawn(.{}, runDarwin, .{})) |th| {
                    th.detach();
                    started = true;
                } else |_| {
                    _ = std.c.close(kq);
                    kq = -1;
                }
            }
        }
        if (!started) {
            // No reaper available: a non-blocking attempt is all that is
            // safe here; the kernel keeps a zombie at worst.
            _ = c.waitpid(pid, null, c.W.NOHANG);
            return;
        }
        pending.put(gpa, pid, monotonicMs() + REAP_GRACE_MS) catch {};
        const ident: usize = @intCast(pid);
        const changes = [_]c.Kevent{
            .{ .ident = ident, .filter = c.EVFILT.PROC, .flags = c.EV.ADD | c.EV.ONESHOT, .fflags = c.NOTE.EXIT, .data = 0, .udata = 0 },
            .{ .ident = ident, .filter = c.EVFILT.TIMER, .flags = c.EV.ADD | c.EV.ONESHOT, .fflags = 0, .data = REAP_GRACE_MS, .udata = 0 },
        };
        var none: [0]c.Kevent = undefined;
        const proc_ok = c.kevent(kq, changes[0..1].ptr, 1, &none, 0, null) == 0;
        if (c.waitpid(pid, null, c.W.NOHANG) != 0) {
            forgetLocked(pid, proc_ok);
            return;
        }
        if (proc_ok) {
            _ = c.kevent(kq, changes[1..2].ptr, 1, &none, 0, null);
        } else {
            // The kernel refuses an exit knote on a process already inside
            // exit(); it becomes collectable within moments. Check back
            // shortly instead of after the full grace.
            armRetryLocked(ident);
        }
    }

    /// Drop `pid` and its knotes. Caller holds `mutex`.
    fn forgetLocked(pid: posix.pid_t, delete_proc: bool) void {
        _ = pending.remove(pid);
        const ident: usize = @intCast(pid);
        var none: [0]c.Kevent = undefined;
        const del_timer = [_]c.Kevent{.{ .ident = ident, .filter = c.EVFILT.TIMER, .flags = c.EV.DELETE, .fflags = 0, .data = 0, .udata = 0 }};
        _ = c.kevent(kq, &del_timer, 1, &none, 0, null);
        if (delete_proc) {
            const del_proc = [_]c.Kevent{.{ .ident = ident, .filter = c.EVFILT.PROC, .flags = c.EV.DELETE, .fflags = 0, .data = 0, .udata = 0 }};
            _ = c.kevent(kq, &del_proc, 1, &none, 0, null);
        }
    }

    /// One-shot 20 ms timer on `ident`, for a child whose exit knote could
    /// not attach (the kernel refuses one on a process inside exit()). Its
    /// handler reaps, re-arming only while the process is still mid-exit,
    /// and SIGKILLs the group only once the grace has passed.
    fn armRetryLocked(ident: usize) void {
        var none: [0]c.Kevent = undefined;
        const rearm = [_]c.Kevent{.{ .ident = ident, .filter = c.EVFILT.TIMER, .flags = c.EV.ADD | c.EV.ONESHOT, .fflags = 0, .data = 20, .udata = 0 }};
        _ = c.kevent(kq, &rearm, 1, &none, 0, null);
    }

    fn runDarwin() void {
        var events: [16]c.Kevent = undefined;
        var none: [0]c.Kevent = undefined;
        while (true) {
            const n = c.kevent(kq, &none, 0, &events, events.len, null);
            if (n <= 0) continue; // EINTR
            for (events[0..@intCast(n)]) |ev| {
                const pid: posix.pid_t = @intCast(ev.ident);
                mutex.lock();
                defer mutex.unlock();
                const deadline = pending.get(pid) orelse continue; // already collected
                if (ev.filter == c.EVFILT.PROC) {
                    // Exited: the zombie is collectable without waiting.
                    _ = c.waitpid(pid, null, c.W.NOHANG);
                    forgetLocked(pid, false);
                } else {
                    // Timer: once the grace is over, end the whole group. A
                    // child with an exit knote is then collected on
                    // NOTE_EXIT; one without (it was already mid-exit at
                    // adopt) is re-checked until it is collectable.
                    if (monotonicMs() >= deadline) {
                        _ = c.kill(-pid, posix.SIG.KILL);
                        _ = c.kill(pid, posix.SIG.KILL);
                    }
                    if (c.waitpid(pid, null, c.W.NOHANG) != 0) {
                        forgetLocked(pid, true);
                    } else {
                        armRetryLocked(ev.ident);
                    }
                }
            }
        }
    }

    fn adoptLinux(pid: posix.pid_t) void {
        mutex.lock();
        pending.put(gpa, pid, 0) catch {};
        mutex.unlock();
        if (std.Thread.spawn(.{}, runLinux, .{pid})) |th| {
            th.detach();
        } else |_| {
            _ = c.waitpid(pid, null, c.W.NOHANG);
        }
    }

    fn runLinux(pid: posix.pid_t) void {
        if (!is_darwin) {
            const linux = std.os.linux;
            const r = linux.pidfd_open(pid, 0);
            if (linux.errno(r) == .SUCCESS) {
                const pfd: c_int = @intCast(r);
                var fds = [_]posix.pollfd{.{ .fd = pfd, .events = posix.POLL.IN, .revents = 0 }};
                const ready = posix.poll(&fds, @intCast(REAP_GRACE_MS)) catch 0;
                if (ready == 0) {
                    _ = c.kill(-pid, posix.SIG.KILL);
                    _ = c.kill(pid, posix.SIG.KILL);
                }
                _ = std.c.close(pfd);
            } else {
                _ = c.kill(-pid, posix.SIG.KILL);
                _ = c.kill(pid, posix.SIG.KILL);
            }
            // The child has exited or been SIGKILLed: this returns promptly.
            _ = c.waitpid(pid, null, 0);
        }
        mutex.lock();
        _ = pending.remove(pid);
        mutex.unlock();
    }
};

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

    /// Darwin: allocate the pair from /dev/ptmx, both ends opened O_CLOEXEC.
    ///
    /// openpty(3) cannot take O_CLOEXEC, and setting it afterwards with fcntl
    /// leaves a window in which a fork on another thread of the host (the
    /// Swift app spawns processes from many threads) inherits the master; that
    /// child then holds the terminal open and the pane's shell never hangs up.
    /// Opening each end with the flag closes the window for every forker in
    /// the process, not only those that take `fd_lock`.
    fn createDarwin() !Self {
        const master_fd = c.open("/dev/ptmx", .{ .ACCMODE = .RDWR, .NOCTTY = true, .CLOEXEC = true });
        if (master_fd < 0) return error.OpenptyFailed;
        errdefer _ = std.c.close(master_fd);
        if (grantpt(master_fd) != 0) return error.OpenptyFailed;
        if (unlockpt(master_fd) != 0) return error.OpenptyFailed;

        var slave_path: [128]u8 = undefined;
        if (ptsname_r(master_fd, &slave_path, slave_path.len) != 0) return error.OpenptyFailed;
        const slave_fd = c.open(@ptrCast(&slave_path), .{ .ACCMODE = .RDWR, .NOCTTY = true, .CLOEXEC = true });
        if (slave_fd < 0) return error.OpenptyFailed;
        errdefer _ = std.c.close(slave_fd);

        var ws = Winsize{ .ws_row = 24, .ws_col = 80, .ws_xpixel = 0, .ws_ypixel = 0 };
        try doIoctl(master_fd, tioc.SWINSZ, &ws);
        setMasterNonblock(master_fd);

        // The slave is held by fd; no path is tracked on Darwin.
        var no_path: [32]u8 = undefined;
        @memset(&no_path, 0);

        return Self{
            .master_fd = master_fd,
            .slave_fd = slave_fd,
            .slave_path = no_path,
            .slave_path_len = 0,
            .child_pid = null,
            .rows = 24,
            .cols = 80,
        };
    }

    /// Linux: allocate the pair via the Unix98 /dev/ptmx interface.
    fn createLinux() !Self {
        // Open the PTY master device
        // Both ends O_CLOEXEC, as on Darwin: no fork elsewhere in the host
        // may inherit either end. The child gets the slave through dup2,
        // which clears the flag on 0/1/2.
        const master_fd = try posix.openatZ(c.AT.FDCWD, "/dev/ptmx", .{
            .ACCMODE = .RDWR,
            .NOCTTY = true,
            .CLOEXEC = true,
        }, 0);
        errdefer _ = std.c.close(master_fd);
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
            .CLOEXEC = true,
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

    /// Close the PTY and hand the child to the process-wide reaper. Never
    /// waits: the caller is often the host's main thread or a view deinit.
    pub fn close(self: *Self) void {
        // Watch for the exit BEFORE anything can end the child, so the exit
        // knote attaches to a live process rather than racing its teardown.
        const pid = self.child_pid;
        if (pid) |p| reaper.adopt(p);
        self.child_pid = null;

        // The descriptors go next. A child exiting with output still queued
        // on its terminal waits in the kernel for that output to drain (ps
        // state `E`), and only a reader on the master or the master's close
        // releases it, even after SIGKILL. Closing the master also hangs up
        // the terminal, which ends an ordinary shell.
        if (self.slave_fd >= 0) _ = std.c.close(self.slave_fd);
        self.slave_fd = -1;
        if (self.master_fd >= 0) _ = std.c.close(self.master_fd);
        self.master_fd = -1;

        if (pid) |p| {
            // The child is a setsid leader, so its pid is also its process
            // group: HUP reaches the shell and anything it started in its
            // own group. The reaper escalates to SIGKILL on the group after
            // `REAP_GRACE_MS` and collects the exit status, so no closed pane
            // leaves a zombie in a host that runs for days.
            _ = c.kill(-p, posix.SIG.HUP);
            _ = c.kill(p, posix.SIG.HUP);
        }
    }

    /// Get slave path as a slice
    pub fn getSlavePath(self: *const Self) []const u8 {
        return self.slave_path[0..self.slave_path_len];
    }

    /// Spawn `path` in the PTY with `argv`. `argv[0]` is the name the child
    /// sees, which may differ from `path`: a leading `-` makes a shell a login
    /// shell. `argv` must be NUL-terminated (the terminator is mandatory —
    /// execve reads it to find the end of the vector; passing a non-terminated
    /// array makes execve dereference stack garbage as argv[1], which fails
    /// with EFAULT on Darwin).
    pub fn spawn(self: *Self, path: [*:0]const u8, argv: [*:null]const ?[*:0]const u8, envp: [*:null]const ?[*:0]const u8) !void {
        return self.spawnIn(path, argv, envp, null);
    }

    /// `spawn`, with the child starting in `cwd` (null = inherit the caller's).
    /// The chdir happens in the child, after fork, so the caller's own working
    /// directory is never touched — a multi-pane server must not change its
    /// cwd per spawn. A chdir failure exits the child with 126 (the shell
    /// convention for "found but could not run"); callers that need a clean
    /// error should validate the directory before spawning.
    pub fn spawnIn(
        self: *Self,
        path: [*:0]const u8,
        argv: [*:null]const ?[*:0]const u8,
        envp: [*:null]const ?[*:0]const u8,
        cwd: ?[*:0]const u8,
    ) !void {
        // Held across fork so no terminal_mux fd that is still between
        // creation and its FD_CLOEXEC fcntl can be inherited.
        fd_lock.lock();
        const pid = c.fork();
        fd_lock.unlock();

        if (pid < 0) {
            return error.ForkFailed;
        } else if (pid == 0) {
            // Child process
            self.setupChild() catch {
                std.c._exit(1);
            };
            if (cwd) |dir| {
                if (c.chdir(dir) != 0) std.c._exit(126);
            }

            // `path` is absolute; execve does no PATH search.
            _ = c.execve(path, argv, envp);
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
        // Linux exposes the slave node as /dev/pts/N; Darwin keeps only
        // the fd, so no path is tracked there.
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

test "close reaps a child whose output nobody read" {
    // The child floods its terminal and the master is never read, so its
    // exit waits on the tty draining. Reaping before closing the master hung
    // forever: six such threads were found parked in waitpid inside the app.
    var p = Pty.create() catch |err| {
        if (isUnavailableError(err)) return error.SkipZigTest;
        return err;
    };
    const argv = [_:null]?[*:0]const u8{ "sh", "-c", "yes x | head -c 2000000; sleep 100" };
    try p.spawn("/bin/sh", &argv, std.c.environ);
    var no_fds = [_]posix.pollfd{};
    _ = posix.poll(&no_fds, 500) catch {}; // let the output queue fill

    const Closer = struct {
        pty: *Pty,
        done: std.atomic.Value(bool) = .init(false),
        fn run(self: *@This()) void {
            self.pty.close();
            self.done.store(true, .release);
        }
    };
    var closer = Closer{ .pty = &p };
    const th = try std.Thread.spawn(.{}, Closer.run, .{&closer});
    const started = monotonicMsForTest();
    while (!closer.done.load(.acquire) and monotonicMsForTest() - started < 5000) {
        _ = posix.poll(&no_fds, 10) catch {};
    }
    // A hung close cannot be joined; leave its thread behind and fail.
    if (!closer.done.load(.acquire)) {
        th.detach();
        return error.CloseHung;
    }
    th.join();
}

test "both pty ends are close-on-exec from creation" {
    var p = Pty.create() catch |err| {
        if (isUnavailableError(err)) return error.SkipZigTest;
        return err;
    };
    defer p.close();
    try std.testing.expect(c.fcntl(p.master_fd, c.F.GETFD, @as(c_int, 0)) & c.FD_CLOEXEC != 0);
    try std.testing.expect(c.fcntl(p.slave_fd, c.F.GETFD, @as(c_int, 0)) & c.FD_CLOEXEC != 0);
}

/// Whether `pid` still exists (a zombie counts). Test helper.
fn pidExists(pid: posix.pid_t) bool {
    return c.kill(pid, @enumFromInt(0)) == 0;
}

test "close returns at once and the reaper ends and reaps the whole group" {
    // The shell ignores HUP and TERM and leaves a background job in its own
    // process group: closing must not wait for it, the reaper must SIGKILL
    // the GROUP after the grace (the job dies too, not only the leader), and
    // the leader must be reaped (no zombie: kill(pid, 0) fails with ESRCH).
    var p = Pty.create() catch |err| {
        if (isUnavailableError(err)) return error.SkipZigTest;
        return err;
    };
    const argv = [_:null]?[*:0]const u8{ "sh", "-c", "trap '' HUP TERM; sleep 100 & echo JOB=$!; wait" };
    try p.spawn("/bin/sh", &argv, std.c.environ);
    const leader = p.child_pid.?;

    var buf: [256]u8 = undefined;
    var got: usize = 0;
    var job: posix.pid_t = 0;
    const started_read = monotonicMsForTest();
    while (job == 0 and monotonicMsForTest() - started_read < 5000) {
        var pfd = [_]posix.pollfd{.{ .fd = p.master_fd, .events = posix.POLL.IN, .revents = 0 }};
        if ((posix.poll(&pfd, 100) catch 0) == 0) continue;
        const r = posix.read(p.master_fd, buf[got..]) catch break;
        got += r;
        if (std.mem.indexOf(u8, buf[0..got], "JOB=")) |i| {
            var end = i + 4;
            while (end < got and std.ascii.isDigit(buf[end])) end += 1;
            if (end < got) job = std.fmt.parseInt(posix.pid_t, buf[i + 4 .. end], 10) catch 0;
        }
    }
    try std.testing.expect(job > 0);

    const t0 = monotonicMsForTest();
    p.close();
    try std.testing.expect(monotonicMsForTest() - t0 < 50);
    try std.testing.expect(p.child_pid == null);

    const deadline = monotonicMsForTest() + REAP_GRACE_MS + 3000;
    var no_fds = [_]posix.pollfd{};
    while ((pidExists(leader) or pidExists(job)) and monotonicMsForTest() < deadline) {
        _ = posix.poll(&no_fds, 20) catch {};
    }
    try std.testing.expect(!pidExists(leader));
    try std.testing.expect(!pidExists(job));
}

test "close of an ordinary shell reaps it on the hangup, before the grace" {
    var p = Pty.create() catch |err| {
        if (isUnavailableError(err)) return error.SkipZigTest;
        return err;
    };
    const argv = [_:null]?[*:0]const u8{ "sh", "-c", "sleep 100" };
    try p.spawn("/bin/sh", &argv, std.c.environ);
    const pid = p.child_pid.?;
    var no_fds = [_]posix.pollfd{};
    _ = posix.poll(&no_fds, 100) catch {};
    const t0 = monotonicMsForTest();
    p.close();
    while (pidExists(pid) and monotonicMsForTest() - t0 < 5000) {
        _ = posix.poll(&no_fds, 10) catch {};
    }
    try std.testing.expect(!pidExists(pid));
    try std.testing.expect(monotonicMsForTest() - t0 < REAP_GRACE_MS);
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
