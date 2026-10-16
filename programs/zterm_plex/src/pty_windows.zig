//! The Windows PTY: a ConPTY pseudoconsole per pane.
//!
//! Shape, and why:
//!
//!   * `CreatePseudoConsole` over two anonymous pipes; the program starts with
//!     `CreateProcessW` carrying the pseudoconsole in its attribute list.
//!     Its stdio handles are set INVALID explicitly (STARTF_USESTDHANDLES):
//!     without that, a server whose own stdout is redirected to a log hands
//!     that log to every pane's program instead of the pseudoconsole.
//!   * Every pane's program runs in its own job object with
//!     KILL_ON_JOB_CLOSE, assigned while the process is still suspended, so
//!     everything it starts is in the job from its first instruction. The job
//!     is the process group: closing a pane ends the whole tree, and a server
//!     that dies takes its panes with it, as a closed PTY master hangs up a
//!     POSIX session.
//!   * Anonymous pipes cannot be polled, and the server's loop is one poll set
//!     (sys.zig). So `master_fd` is one end of an AF_UNIX socket pair, and two
//!     relay threads join the other end to the pipes: pseudoconsole output →
//!     socket, socket → pseudoconsole input. The server reads, writes and
//!     polls `master_fd` exactly as it does a PTY master.
//!   * A pseudoconsole outlives its program: conhost keeps the output pipe open
//!     until `ClosePseudoConsole`. So a waiter thread watches the process and,
//!     when it exits, lets its last output reach the pipe, then closes the
//!     pseudoconsole; the output relay then reaches end-of-file and shuts the
//!     socket's write side, which the server sees as the hang-up a POSIX
//!     master reports. The same thread carries out `close`: hang up (closing
//!     the pseudoconsole sends CTRL_CLOSE_EVENT to everything attached), give
//!     the tree `REAP_GRACE_MS`, then terminate the job. Nothing a caller does
//!     waits on any of it.

const std = @import("std");
const sys = @import("sys.zig");
const win = @import("win32.zig");
const cmdline = @import("win_cmdline.zig");

const HANDLE = win.HANDLE;
const DWORD = win.DWORD;
const alloc = std.heap.c_allocator;

/// How long a closed pane's tree has after the hang-up before its job is
/// terminated (the POSIX reaper's grace, same value).
pub const REAP_GRACE_MS: isize = 2000;

/// After the program exits, the pseudoconsole is closed once its output has
/// been quiet this long — conhost may still be rendering the last bytes the
/// program wrote — or after `EXIT_FLUSH_MAX_MS` regardless.
const EXIT_QUIET_MS: i64 = 100;
const EXIT_FLUSH_MAX_MS: i64 = 1500;

/// SRWLOCK-backed mutex with the POSIX Mutex's interface.
pub const Mutex = struct {
    inner: win.SRWLOCK = .{},

    pub fn lock(self: *Mutex) void {
        win.AcquireSRWLockExclusive(&self.inner);
    }

    pub fn unlock(self: *Mutex) void {
        win.ReleaseSRWLockExclusive(&self.inner);
    }
};

/// The POSIX reaper's diagnostic surface: panes whose teardown has not
/// finished (their waiter thread is still running).
pub const reaper = struct {
    var live = std.atomic.Value(usize).init(0);

    pub fn pendingCount() usize {
        return live.load(.acquire);
    }
};

pub const Winsize = @import("pty.zig").Winsize;

/// State shared between a Pty and its three threads. Freed by whichever of
/// them lets go of it last.
const Shared = struct {
    refs: std.atomic.Value(u32) = .init(1),
    lock: Mutex = .{},
    /// Null once closed (only the waiter closes it).
    hpc: ?win.HPCON,
    in_write: HANDLE,
    out_read: HANDLE,
    /// The relays' end of the socket pair.
    peer: win.SOCKET,
    /// Both relays use `peer`; the second to finish closes it.
    peer_users: std.atomic.Value(u32) = .init(2),
    /// Set by `Pty.close`.
    close_event: HANDLE,
    /// Set by `spawnIn` once `process` and `job` are filled in.
    spawned_event: HANDLE,
    process: ?HANDLE = null,
    job: ?HANDLE = null,
    /// GetLastError of a failed AssignProcessToJobObject (0: assigned).
    job_error: DWORD = 0,
    /// Monotonic ms of the last pseudoconsole output.
    last_output_ms: std.atomic.Value(i64) = .init(0),

    fn retain(self: *Shared) void {
        _ = self.refs.fetchAdd(1, .monotonic);
    }

    fn release(self: *Shared) void {
        if (self.refs.fetchSub(1, .acq_rel) != 1) return;
        _ = win.CloseHandle(self.close_event);
        _ = win.CloseHandle(self.spawned_event);
        alloc.destroy(self);
    }

    fn dropPeer(self: *Shared) void {
        if (self.peer_users.fetchSub(1, .acq_rel) == 1) _ = win.closesocket(self.peer);
    }

    /// Close the pseudoconsole once. Holding the lock keeps a concurrent
    /// `setSize` from resizing a handle that is being closed.
    fn closeHpc(self: *Shared) void {
        self.lock.lock();
        const h = self.hpc;
        self.hpc = null;
        self.lock.unlock();
        if (h) |hpc| win.ClosePseudoConsole(hpc);
    }
};

pub const Pty = struct {
    /// The server's end of the relay socket pair: read output, write input,
    /// poll it. Non-blocking, as the POSIX master is.
    master_fd: sys.fd_t,
    /// A pseudoconsole has no slave descriptor to hand out.
    slave_fd: sys.fd_t = -1,
    slave_path: [32]u8 = @splat(0),
    slave_path_len: usize = 0,
    child_pid: ?sys.pid_t = null,
    /// Set when `isAlive` (or `wait`) sees the program has exited.
    exit_status: ?ExitStatus = null,
    rows: u16,
    cols: u16,
    shared: ?*Shared = null,

    const Self = @This();

    /// How the program ended. Windows has exit codes only: `code` is the
    /// exit code when it fits a byte, 255 when it does not (an NTSTATUS such
    /// as an access violation), and `signal` is 2 for STATUS_CONTROL_C_EXIT.
    pub const ExitStatus = cmdline.ExitStatus;

    pub const WRITE_STALL_BUDGET_MS: i32 = 250;
    const WRITE_POLL_SLICE_MS: i32 = 25;

    /// A pseudoconsole (80x24) with its relays running, and no program yet.
    pub fn create() !Self {
        // Set once `Shared` owns everything; the errdefers below release only
        // what has not been handed to it.
        var handed_off = false;
        var in_read: HANDLE = undefined;
        var in_write: HANDLE = undefined;
        if (win.CreatePipe(&in_read, &in_write, null, 0) == 0) return error.OpenptyFailed;
        var in_read_open = true;
        defer if (in_read_open) {
            _ = win.CloseHandle(in_read);
        };
        errdefer if (!handed_off) {
            _ = win.CloseHandle(in_write);
        };

        var out_read: HANDLE = undefined;
        var out_write: HANDLE = undefined;
        if (win.CreatePipe(&out_read, &out_write, null, 0) == 0) return error.OpenptyFailed;
        var out_write_open = true;
        defer if (out_write_open) {
            _ = win.CloseHandle(out_write);
        };
        errdefer if (!handed_off) {
            _ = win.CloseHandle(out_read);
        };

        var hpc: win.HPCON = undefined;
        if (win.CreatePseudoConsole(.{ .X = 80, .Y = 24 }, in_read, out_write, 0, &hpc) < 0) return error.OpenptyFailed;
        errdefer if (!handed_off) win.ClosePseudoConsole(hpc);
        // conhost holds its own duplicates of the pseudoconsole's ends.
        _ = win.CloseHandle(in_read);
        in_read_open = false;
        _ = win.CloseHandle(out_write);
        out_write_open = false;

        const pair = try socketPair();
        errdefer if (!handed_off) {
            _ = win.closesocket(pair[0]);
            _ = win.closesocket(pair[1]);
        };
        var on: c_ulong = 1;
        _ = win.ioctlsocket(pair[0], win.FIONBIO, &on);

        const close_event = win.CreateEventW(null, win.TRUE, win.FALSE, null) orelse return error.SystemResources;
        errdefer if (!handed_off) {
            _ = win.CloseHandle(close_event);
        };
        const spawned_event = win.CreateEventW(null, win.TRUE, win.FALSE, null) orelse return error.SystemResources;
        errdefer if (!handed_off) {
            _ = win.CloseHandle(spawned_event);
        };

        const sh = try alloc.create(Shared);
        sh.* = .{
            .hpc = hpc,
            .in_write = in_write,
            .out_read = out_read,
            .peer = pair[1],
            .close_event = close_event,
            .spawned_event = spawned_event,
            .last_output_ms = .init(sys.monotonicMs()),
        };
        // From here every resource belongs to `sh` and its threads.
        handed_off = true;
        sh.refs.store(4, .monotonic); // this Pty, two relays, the waiter
        _ = reaper.live.fetchAdd(1, .acq_rel);
        const out_th = std.Thread.spawn(.{}, relayOut, .{sh}) catch null;
        if (out_th) |t| t.detach() else unstartedRelayOut(sh);
        const in_th = std.Thread.spawn(.{}, relayIn, .{sh}) catch null;
        if (in_th) |t| t.detach() else unstartedRelayIn(sh);
        const wait_th = std.Thread.spawn(.{}, waiter, .{sh}) catch null;
        if (wait_th) |t| t.detach() else unstartedWaiter(sh);
        if (out_th == null or in_th == null or wait_th == null) {
            // Out of threads: undo what started, so nothing is left blocked.
            _ = win.closesocket(pair[0]);
            _ = win.SetEvent(close_event);
            sh.release();
            return error.SystemResources;
        }
        return Self{ .master_fd = @bitCast(pair[0]), .rows = 24, .cols = 80, .shared = sh };
    }

    pub fn getSlavePath(self: *const Self) []const u8 {
        return self.slave_path[0..self.slave_path_len];
    }

    pub fn spawn(self: *Self, path: [*:0]const u8, argv: [*:null]const ?[*:0]const u8, envp: [*:null]const ?[*:0]const u8) !void {
        return self.spawnIn(path, argv, envp, null);
    }

    /// Start `path` in the pseudoconsole. `argv[0]` is the name the program
    /// sees; the command line is built from `argv` with the quoting the
    /// Microsoft C runtime's parser undoes. `path` must be an executable
    /// image: a .cmd/.bat would be run by cmd.exe, which re-parses the whole
    /// command line by its own rules, so an argument (an agent's brief) could
    /// carry `&`/`|` and become a command. Run one through the shell instead.
    pub fn spawnIn(
        self: *Self,
        path: [*:0]const u8,
        argv: [*:null]const ?[*:0]const u8,
        envp: [*:null]const ?[*:0]const u8,
        cwd: ?[*:0]const u8,
    ) !void {
        const sh = self.shared orelse return error.ForkFailed;
        const path_s = std.mem.sliceTo(path, 0);
        if (cmdline.isBatchFile(path_s)) return error.BatchFileRefused;

        const app_w = try std.unicode.utf8ToUtf16LeAllocZ(alloc, path_s);
        defer alloc.free(app_w);
        const line = try cmdline.commandLine(alloc, argv);
        defer alloc.free(line);
        const cmd_w = try std.unicode.utf8ToUtf16LeAllocZ(alloc, line);
        defer alloc.free(cmd_w);
        const env_w = try cmdline.environmentBlock(alloc, envp);
        defer alloc.free(env_w);
        const cwd_w: ?[:0]u16 = if (cwd) |d| try std.unicode.utf8ToUtf16LeAllocZ(alloc, std.mem.sliceTo(d, 0)) else null;
        defer if (cwd_w) |w| alloc.free(w);

        var attr_size: usize = 0;
        _ = win.InitializeProcThreadAttributeList(null, 1, 0, &attr_size);
        const attr_buf = try alloc.alignedAlloc(u8, .of(usize), attr_size);
        defer alloc.free(attr_buf);
        const attrs: *anyopaque = @ptrCast(attr_buf.ptr);
        if (win.InitializeProcThreadAttributeList(attrs, 1, 0, &attr_size) == 0) return error.ForkFailed;
        defer win.DeleteProcThreadAttributeList(attrs);

        sh.lock.lock();
        const hpc = sh.hpc;
        sh.lock.unlock();
        if (hpc == null) return error.ForkFailed;
        // The attribute's value is the HPCON itself, not a pointer to it.
        if (win.UpdateProcThreadAttribute(attrs, 0, win.PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE, hpc, @sizeOf(win.HPCON), null, null) == 0)
            return error.ForkFailed;

        const invalid: HANDLE = @ptrFromInt(win.INVALID_HANDLE_VALUE);
        var si = win.STARTUPINFOEXW{
            .StartupInfo = std.mem.zeroInit(win.STARTUPINFOW, .{
                .cb = @sizeOf(win.STARTUPINFOEXW),
                .dwFlags = win.STARTF_USESTDHANDLES,
                .hStdInput = invalid,
                .hStdOutput = invalid,
                .hStdError = invalid,
            }),
            .lpAttributeList = attrs,
        };
        var pi: win.PROCESS_INFORMATION = undefined;
        const ok = win.CreateProcessW(
            app_w.ptr,
            cmd_w.ptr,
            null,
            null,
            .FALSE,
            .{ .create_suspended = true, .create_unicode_environment = true, .extended_startupinfo_present = true },
            env_w.ptr,
            if (cwd_w) |w| w.ptr else null,
            &si.StartupInfo,
            &pi,
        );
        if (!ok.toBool()) return error.ForkFailed;

        // The job before the first instruction runs, so nothing the program
        // starts can escape it.
        const job = win.CreateJobObjectW(null, null);
        if (job) |j| {
            var limits = win.JOBOBJECT_EXTENDED_LIMIT_INFORMATION{};
            limits.BasicLimitInformation.LimitFlags = win.JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
            if (win.SetInformationJobObject(j, win.JobObjectExtendedLimitInformation, &limits, @sizeOf(win.JOBOBJECT_EXTENDED_LIMIT_INFORMATION)) == 0)
                sh.job_error = win.GetLastError();
            if (win.AssignProcessToJobObject(j, pi.hProcess) == 0) {
                sh.job_error = win.GetLastError();
                _ = win.CloseHandle(j);
                sh.job = null;
            } else sh.job = j;
        }
        sh.process = pi.hProcess;
        _ = win.ResumeThread(pi.hThread);
        _ = win.CloseHandle(pi.hThread);
        self.child_pid = pi.dwProcessId;
        _ = win.SetEvent(sh.spawned_event);
    }

    /// Resize the pseudoconsole (it tells the program, as SIGWINCH does).
    pub fn setSize(self: *Self, rows: u16, cols: u16) !void {
        if (rows == 0 or cols == 0) return error.IoctlFailed;
        const sh = self.shared orelse return error.IoctlFailed;
        sh.lock.lock();
        defer sh.lock.unlock();
        if (sh.hpc) |hpc| {
            if (win.ResizePseudoConsole(hpc, .{ .X = @intCast(@min(cols, 0x7fff)), .Y = @intCast(@min(rows, 0x7fff)) }) < 0)
                return error.IoctlFailed;
        }
        self.rows = rows;
        self.cols = cols;
    }

    pub fn getSize(self: *const Self) !Winsize {
        return .{ .ws_row = self.rows, .ws_col = self.cols, .ws_xpixel = 0, .ws_ypixel = 0 };
    }

    pub fn read(self: *Self, buf: []u8) !usize {
        return sys.read(self.master_fd, buf);
    }

    /// Write input, bounded like the POSIX master: a program that stops
    /// reading fills conhost's input, then the relay's pipe, then the socket,
    /// and after `WRITE_STALL_BUDGET_MS` without progress this returns the
    /// count that got through.
    pub fn write(self: *Self, data: []const u8) !usize {
        var off: usize = 0;
        var budget_ms = WRITE_STALL_BUDGET_MS;
        while (off < data.len) {
            const ret = sys.write(self.master_fd, data.ptr + off, data.len - off);
            if (ret > 0) {
                off += @intCast(ret);
                budget_ms = WRITE_STALL_BUDGET_MS;
                continue;
            }
            if (ret == 0) break;
            switch (sys.errno(ret)) {
                .INTR => continue,
                .AGAIN => {
                    if (budget_ms <= 0) break;
                    const slice = @min(budget_ms, WRITE_POLL_SLICE_MS);
                    budget_ms -= slice;
                    var pfd = [_]sys.pollfd{.{ .fd = self.master_fd, .events = sys.POLL.OUT, .revents = 0 }};
                    _ = sys.poll(&pfd, slice) catch break;
                    continue;
                },
                else => return error.WriteFailed,
            }
        }
        return off;
    }

    /// Whether the program is still running. Records `exit_status` and clears
    /// `child_pid` once it has exited.
    pub fn isAlive(self: *Self) bool {
        _ = self.child_pid orelse return false;
        const sh = self.shared orelse return false;
        const proc = sh.process orelse return false;
        if (win.WaitForSingleObject(proc, 0) == win.WAIT_TIMEOUT) return true;
        self.exit_status = exitStatusOf(proc);
        self.child_pid = null;
        return false;
    }

    /// Block until the program exits. Returns its exit code.
    pub fn wait(self: *Self) !u32 {
        _ = self.child_pid orelse return 0;
        const sh = self.shared orelse return 0;
        const proc = sh.process orelse return 0;
        _ = win.WaitForSingleObject(proc, win.INFINITE);
        var code: DWORD = 0;
        _ = win.GetExitCodeProcess(proc, &code);
        self.exit_status = exitStatusOf(proc);
        self.child_pid = null;
        return code;
    }

    /// Close the pane. Never waits: the waiter thread hangs the program up,
    /// gives its tree the grace, then terminates the job.
    pub fn close(self: *Self) void {
        self.child_pid = null;
        // The relays see the server's end go: the input relay's receive ends,
        // and the output relay keeps draining conhost without forwarding, so
        // conhost never blocks on a full pipe while it shuts down.
        if (self.master_fd >= 0) _ = sys.close(self.master_fd);
        self.master_fd = -1;
        if (self.shared) |sh| {
            _ = win.SetEvent(sh.close_event);
            sh.release();
        }
        self.shared = null;
    }
};

fn exitStatusOf(proc: HANDLE) Pty.ExitStatus {
    var code: DWORD = 0;
    if (win.GetExitCodeProcess(proc, &code) == 0) return .{ .code = 255 };
    return cmdline.decodeExitCode(code);
}

// ── threads ──────────────────────────────────────────────────────────────────

fn sendAll(s: win.SOCKET, bytes: []const u8) bool {
    var off: usize = 0;
    while (off < bytes.len) {
        const n = win.send(s, bytes.ptr + off, @intCast(@min(bytes.len - off, std.math.maxInt(c_int))), 0);
        if (n <= 0) return false;
        off += @intCast(n);
    }
    return true;
}

fn writeAll(h: HANDLE, bytes: []const u8) bool {
    var off: usize = 0;
    while (off < bytes.len) {
        var n: DWORD = 0;
        if (win.WriteFile(h, bytes.ptr + off, @intCast(@min(bytes.len - off, std.math.maxInt(DWORD))), &n, null) == 0) return false;
        if (n == 0) return false;
        off += n;
    }
    return true;
}

/// What each thread would have released, for one that could not start.
fn unstartedRelayOut(sh: *Shared) void {
    sh.closeHpc();
    _ = win.CloseHandle(sh.out_read);
    sh.dropPeer();
    sh.release();
}

fn unstartedRelayIn(sh: *Shared) void {
    _ = win.CloseHandle(sh.in_write);
    sh.dropPeer();
    sh.release();
}

fn unstartedWaiter(sh: *Shared) void {
    sh.closeHpc();
    _ = reaper.live.fetchSub(1, .acq_rel);
    sh.release();
}

/// Pseudoconsole output → the socket, until conhost closes the pipe. Once the
/// server's end is gone it keeps reading and discards, so conhost can always
/// finish writing and exit.
fn relayOut(sh: *Shared) void {
    var buf: [16384]u8 = undefined;
    var forwarding = true;
    while (true) {
        var n: DWORD = 0;
        if (win.ReadFile(sh.out_read, &buf, buf.len, &n, null) == 0 or n == 0) break;
        sh.last_output_ms.store(sys.monotonicMs(), .release);
        if (forwarding and !sendAll(sh.peer, buf[0..n])) forwarding = false;
    }
    // End of output: the server reads EOF after the last byte, as a POSIX
    // master reports once the terminal's last writer is gone.
    _ = win.shutdown(sh.peer, win.SD_SEND);
    _ = win.CloseHandle(sh.out_read);
    sh.dropPeer();
    sh.release();
}

/// The socket → pseudoconsole input, until the server closes its end.
fn relayIn(sh: *Shared) void {
    var buf: [16384]u8 = undefined;
    while (true) {
        const n = win.recv(sh.peer, &buf, buf.len, 0);
        if (n <= 0) break;
        if (!writeAll(sh.in_write, buf[0..@intCast(n)])) break;
    }
    _ = win.CloseHandle(sh.in_write);
    sh.dropPeer();
    sh.release();
}

/// Exit, hang-up and teardown for one pane. See the module docs.
fn waiter(sh: *Shared) void {
    defer {
        _ = reaper.live.fetchSub(1, .acq_rel);
        sh.release();
    }
    const first = [_]HANDLE{ sh.spawned_event, sh.close_event };
    if (win.WaitForMultipleObjects(2, &first, win.FALSE, win.INFINITE) != win.WAIT_OBJECT_0) {
        // Closed before any program ran.
        sh.closeHpc();
        return;
    }
    const proc = sh.process.?;
    defer _ = win.CloseHandle(proc);
    defer if (sh.job) |j| {
        // KILL_ON_JOB_CLOSE: whatever the program left running ends here.
        _ = win.CloseHandle(j);
    };

    const both = [_]HANDLE{ proc, sh.close_event };
    if (win.WaitForMultipleObjects(2, &both, win.FALSE, win.INFINITE) == win.WAIT_OBJECT_0) {
        // The program exited on its own. Close the pseudoconsole once its
        // output has gone quiet, so the server reads everything it wrote and
        // then the hang-up.
        const exited_at = sys.monotonicMs();
        while (true) {
            const now = sys.monotonicMs();
            if (now - sh.last_output_ms.load(.acquire) >= EXIT_QUIET_MS) break;
            if (now - exited_at >= EXIT_FLUSH_MAX_MS) break;
            if (win.WaitForSingleObject(sh.close_event, 20) == win.WAIT_OBJECT_0) break;
        }
        sh.closeHpc();
        // What the program started keeps the pane's job until the pane is
        // closed, as background jobs keep a POSIX terminal session alive.
        _ = win.WaitForSingleObject(sh.close_event, win.INFINITE);
        return;
    }

    // `close` while the program runs: hang up, give it the grace, then end
    // the whole tree.
    sh.closeHpc();
    if (win.WaitForSingleObject(proc, @intCast(REAP_GRACE_MS)) == win.WAIT_TIMEOUT) {
        if (sh.job) |j| {
            _ = win.TerminateJobObject(j, 1);
        } else {
            _ = win.TerminateProcess(proc, 1);
        }
    }
}

// ── socket pair ──────────────────────────────────────────────────────────────

var pair_seq = std.atomic.Value(u32).init(0);

/// A connected AF_UNIX socket pair (Windows has no socketpair): listen on a
/// fresh path in %TEMP%, connect, accept, remove the path. %TEMP% is the
/// user's own directory, so no other account can bind the name first.
pub fn socketPair() ![2]win.SOCKET {
    sys.netInit();
    const tmp = sys.getenv("TEMP") orelse sys.getenv("TMP") orelse return error.NoTempDir;
    var pb: [108]u8 = undefined;
    const seq = pair_seq.fetchAdd(1, .monotonic);
    const path = std.fmt.bufPrint(&pb, "{s}\\zt-{d}-{d}-{d}.sock", .{ tmp, win.GetCurrentProcessId(), seq, win.GetTickCount64() % 100000 }) catch return error.SocketPathTooLong;
    const addr = try sys.unixAddr(path);
    _ = sys.deletePath(path);

    const l = win.socket(win.AF_UNIX, win.SOCK_STREAM, 0);
    if (l == win.INVALID_SOCKET) return error.SocketCreateFailed;
    defer _ = win.closesocket(l);
    defer _ = sys.deletePath(path);
    if (win.bind(l, &addr, @sizeOf(win.sockaddr_un)) != 0) return error.BindFailed;
    if (win.listen(l, 1) != 0) return error.ListenFailed;

    const a = win.socket(win.AF_UNIX, win.SOCK_STREAM, 0);
    if (a == win.INVALID_SOCKET) return error.SocketCreateFailed;
    errdefer _ = win.closesocket(a);
    if (win.connect(a, &addr, @sizeOf(win.sockaddr_un)) != 0) return error.ConnectFailed;
    const b = win.accept(l, null, null);
    if (b == win.INVALID_SOCKET) return error.AcceptFailed;
    return .{ a, b };
}

/// The calling process's environment as POSIX-shaped UTF-8 "NAME=value"
/// entries, null-terminated, allocated for the process lifetime.
pub fn environ() ![*:null]const ?[*:0]const u8 {
    const block = win.GetEnvironmentStringsW() orelse return error.SystemResources;
    defer _ = win.FreeEnvironmentStringsW(block);
    var list: std.ArrayList(?[*:0]const u8) = .empty;
    var p: usize = 0;
    while (block[p] != 0) {
        var end = p;
        while (block[end] != 0) end += 1;
        const s = try std.unicode.utf16LeToUtf8AllocZ(alloc, block[p..end]);
        try list.append(alloc, s.ptr);
        p = end + 1;
    }
    const out = try list.toOwnedSliceSentinel(alloc, null);
    return out.ptr;
}

// ── the process tree (the "foreground" a POSIX terminal reports) ─────────────

pub const ProcEntry = struct {
    pid: sys.pid_t,
    /// Image file name, UTF-8 ("claude.exe").
    name_buf: [256]u8 = undefined,
    name_len: usize = 0,

    pub fn name(self: *const ProcEntry) []const u8 {
        return self.name_buf[0..self.name_len];
    }
};

fn creationTime(pid: DWORD) ?u64 {
    const h = win.OpenProcess(win.PROCESS_QUERY_LIMITED_INFORMATION, win.FALSE, pid) orelse return null;
    defer _ = win.CloseHandle(h);
    var cr: win.FILETIME = .{};
    var ex: win.FILETIME = .{};
    var k: win.FILETIME = .{};
    var u: win.FILETIME = .{};
    if (win.GetProcessTimes(h, &cr, &ex, &k, &u) == 0) return null;
    return (@as(u64, cr.dwHighDateTime) << 32) | cr.dwLowDateTime;
}

/// The chain a terminal's foreground would be on: the pane's root process,
/// then at each step its most recently started child, down to a leaf. Written
/// into `out`; returns the filled prefix. A child is only accepted if it
/// started after its parent, so a recycled parent pid is not followed.
pub fn processChain(root: sys.pid_t, out: []ProcEntry) []ProcEntry {
    if (out.len == 0 or root == 0) return out[0..0];
    const snap = win.CreateToolhelp32Snapshot(win.TH32CS_SNAPPROCESS, 0);
    if (@intFromPtr(snap) == win.INVALID_HANDLE_VALUE) return out[0..0];
    defer _ = win.CloseHandle(snap);

    const Row = struct { pid: DWORD, ppid: DWORD, name: [260]u16 };
    var rows: std.ArrayList(Row) = .empty;
    defer rows.deinit(alloc);
    var pe = win.PROCESSENTRY32W{ .dwSize = @sizeOf(win.PROCESSENTRY32W) };
    if (win.Process32FirstW(snap, &pe) == 0) return out[0..0];
    while (true) {
        rows.append(alloc, .{ .pid = pe.th32ProcessID, .ppid = pe.th32ParentProcessID, .name = pe.szExeFile }) catch break;
        if (win.Process32NextW(snap, &pe) == 0) break;
    }

    var n: usize = 0;
    var cur: DWORD = root;
    var cur_name: ?[260]u16 = null;
    for (rows.items) |r| {
        if (r.pid == root) cur_name = r.name;
    }
    if (cur_name == null) return out[0..0];
    var cur_time = creationTime(cur) orelse 0;
    while (n < out.len) {
        out[n] = .{ .pid = cur };
        const wname = std.mem.sliceTo(&cur_name.?, 0);
        out[n].name_len = std.unicode.utf16LeToUtf8(&out[n].name_buf, wname[0..@min(wname.len, 80)]) catch 0;
        n += 1;
        var best: ?Row = null;
        var best_time: u64 = 0;
        for (rows.items) |r| {
            if (r.ppid != cur or r.pid == cur) continue;
            const t = creationTime(r.pid) orelse continue;
            if (t < cur_time) continue;
            if (best == null or t > best_time) {
                best = r;
                best_time = t;
            }
        }
        const next = best orelse break;
        cur = next.pid;
        cur_name = next.name;
        cur_time = best_time;
    }
    return out[0..n];
}

/// A process's full image path (UTF-8) into `buf`.
pub fn processImagePath(pid: sys.pid_t, buf: []u8) ?[]const u8 {
    const h = win.OpenProcess(win.PROCESS_QUERY_LIMITED_INFORMATION, win.FALSE, pid) orelse return null;
    defer _ = win.CloseHandle(h);
    var wbuf: [1024]u16 = undefined;
    var size: DWORD = wbuf.len;
    if (win.QueryFullProcessImageNameW(h, 0, &wbuf, &size) == 0) return null;
    const n = std.unicode.utf16LeToUtf8(buf, wbuf[0..size]) catch return null;
    return buf[0..n];
}

// ── the console a client runs in (zterm attach) ──────────────────────────────

/// Console modes for a raw, VT-speaking client: input arrives as the bytes a
/// terminal would send (no line editing, no echo, Ctrl-C as a byte), output
/// is interpreted as VT, both in UTF-8. `exit` restores everything.
pub const RawMode = struct {
    in_h: ?HANDLE,
    out_h: ?HANDLE,
    in_mode: DWORD = 0,
    out_mode: DWORD = 0,
    in_cp: win.UINT = 0,
    out_cp: win.UINT = 0,

    pub fn enter(_: anytype) !RawMode {
        var self = RawMode{
            .in_h = win.GetStdHandle(win.STD_INPUT_HANDLE),
            .out_h = win.GetStdHandle(win.STD_OUTPUT_HANDLE),
        };
        const in_h = self.in_h orelse return error.NotATerminal;
        if (win.GetConsoleMode(in_h, &self.in_mode) == 0) return error.NotATerminal;
        self.in_cp = win.GetConsoleCP();
        self.out_cp = win.GetConsoleOutputCP();
        const raw_in = (self.in_mode & ~(win.ENABLE_LINE_INPUT | win.ENABLE_ECHO_INPUT | win.ENABLE_PROCESSED_INPUT)) | win.ENABLE_VIRTUAL_TERMINAL_INPUT;
        if (win.SetConsoleMode(in_h, raw_in) == 0) return error.NotATerminal;
        if (self.out_h) |oh| {
            if (win.GetConsoleMode(oh, &self.out_mode) != 0) {
                _ = win.SetConsoleMode(oh, self.out_mode | win.ENABLE_PROCESSED_OUTPUT | win.ENABLE_VIRTUAL_TERMINAL_PROCESSING | win.DISABLE_NEWLINE_AUTO_RETURN);
            }
        }
        _ = win.SetConsoleCP(win.CP_UTF8);
        _ = win.SetConsoleOutputCP(win.CP_UTF8);
        return self;
    }

    pub fn exit(self: *RawMode) void {
        if (self.in_h) |h| _ = win.SetConsoleMode(h, self.in_mode);
        if (self.out_h) |h| if (self.out_mode != 0) {
            _ = win.SetConsoleMode(h, self.out_mode);
        };
        if (self.in_cp != 0) _ = win.SetConsoleCP(self.in_cp);
        if (self.out_cp != 0) _ = win.SetConsoleOutputCP(self.out_cp);
    }
};

/// The console window's visible size.
pub fn getTerminalSize(_: anytype) !Winsize {
    const h = win.GetStdHandle(win.STD_OUTPUT_HANDLE) orelse return error.IoctlFailed;
    var info: win.CONSOLE_SCREEN_BUFFER_INFO = undefined;
    if (win.GetConsoleScreenBufferInfo(h, &info) == 0) return error.IoctlFailed;
    const cols: i32 = @as(i32, info.srWindow.Right) - info.srWindow.Left + 1;
    const rows: i32 = @as(i32, info.srWindow.Bottom) - info.srWindow.Top + 1;
    if (cols <= 0 or rows <= 0) return error.IoctlFailed;
    return .{ .ws_row = @intCast(rows), .ws_col = @intCast(cols), .ws_xpixel = 0, .ws_ypixel = 0 };
}

/// Write everything to stdout (a console or a redirect).
pub fn writeStdout(bytes: []const u8) void {
    const h = win.GetStdHandle(win.STD_OUTPUT_HANDLE) orelse return;
    _ = writeAll(h, bytes);
}

var stdin_sock: std.atomic.Value(isize) = .init(-1);

/// Standard input as a pollable socket: a thread reads the console (or a
/// redirected stdin) and forwards what it reads, so a client's loop polls
/// stdin and its server connection in one set. Console input is read as
/// UTF-16 and forwarded as UTF-8 (a surrogate pair split across two reads is
/// held until its second half arrives). Created once; later calls return the
/// same socket.
pub fn stdinSocket() !sys.fd_t {
    const have = stdin_sock.load(.acquire);
    if (have >= 0) return have;
    const pair = try socketPair();
    const in_h = win.GetStdHandle(win.STD_INPUT_HANDLE) orelse return error.NoStdin;
    const th = try std.Thread.spawn(.{}, stdinPump, .{ in_h, pair[1] });
    th.detach();
    const fd: isize = @bitCast(pair[0]);
    stdin_sock.store(fd, .release);
    return fd;
}

fn stdinPump(in_h: HANDLE, peer: win.SOCKET) void {
    defer _ = win.closesocket(peer);
    var mode: DWORD = 0;
    const console = win.GetConsoleMode(in_h, &mode) != 0;
    var bytes: [8192]u8 = undefined;
    if (!console) {
        while (true) {
            var n: DWORD = 0;
            if (win.ReadFile(in_h, &bytes, bytes.len, &n, null) == 0 or n == 0) return;
            if (!sendAll(peer, bytes[0..n])) return;
        }
    }
    var wide: [2048]u16 = undefined;
    var held: ?u16 = null;
    while (true) {
        var start: usize = 0;
        if (held) |h| {
            wide[0] = h;
            start = 1;
            held = null;
        }
        var n: DWORD = 0;
        if (win.ReadConsoleW(in_h, wide[start..].ptr, @intCast(wide.len - start), &n, null) == 0) return;
        var len = start + n;
        if (len == 0) continue;
        if (std.unicode.utf16IsHighSurrogate(wide[len - 1])) {
            held = wide[len - 1];
            len -= 1;
        }
        const m = std.unicode.utf16LeToUtf8(&bytes, wide[0..len]) catch continue;
        if (m > 0 and !sendAll(peer, bytes[0..m])) return;
    }
}

// ── tests (Windows only: pty.zig pulls this file in on Windows) ──────────────

const testing = std.testing;
const CMD: [*:0]const u8 = "C:\\Windows\\System32\\cmd.exe";

fn testEnv() ![*:null]const ?[*:0]const u8 {
    return environ();
}

/// Read the master into `out` until `needle` appears, end-of-file, or `ms`.
/// Returns whether `needle` was seen; `eof` reports a hang-up.
fn readUntil(p: *Pty, out: *std.ArrayList(u8), needle: ?[]const u8, ms: i64, eof: *bool) !bool {
    const deadline = sys.monotonicMs() + ms;
    var buf: [4096]u8 = undefined;
    while (sys.monotonicMs() < deadline) {
        if (needle) |n| if (std.mem.indexOf(u8, out.items, n) != null) return true;
        var pfd = [_]sys.pollfd{.{ .fd = p.master_fd, .events = sys.POLL.IN, .revents = 0 }};
        _ = try sys.poll(&pfd, 50);
        if (pfd[0].revents == 0) continue;
        const r = p.read(&buf) catch |e| switch (e) {
            error.WouldBlock => continue,
            else => {
                eof.* = true;
                break;
            },
        };
        if (r == 0) {
            eof.* = true;
            break;
        }
        try out.appendSlice(testing.allocator, buf[0..r]);
    }
    if (needle) |n| return std.mem.indexOf(u8, out.items, n) != null;
    return false;
}

fn spawnCmd(p: *Pty, args: []const [*:0]const u8) !void {
    var argv: [16:null]?[*:0]const u8 = @splat(null);
    argv[0] = CMD;
    for (args, 1..) |a, i| argv[i] = a;
    try p.spawnIn(CMD, &argv, try testEnv(), null);
}

/// A handle that keeps `pid`'s process object (so its id cannot be reused)
/// and can be waited on.
fn holdProcess(pid: DWORD) ?HANDLE {
    return win.OpenProcess(win.SYNCHRONIZE | win.PROCESS_QUERY_LIMITED_INFORMATION, win.FALSE, pid);
}

fn childrenOf(parent: DWORD, out: []DWORD) []DWORD {
    const snap = win.CreateToolhelp32Snapshot(win.TH32CS_SNAPPROCESS, 0);
    if (@intFromPtr(snap) == win.INVALID_HANDLE_VALUE) return out[0..0];
    defer _ = win.CloseHandle(snap);
    var pe = win.PROCESSENTRY32W{ .dwSize = @sizeOf(win.PROCESSENTRY32W) };
    var n: usize = 0;
    if (win.Process32FirstW(snap, &pe) == 0) return out[0..0];
    while (true) {
        if (pe.th32ParentProcessID == parent and n < out.len) {
            out[n] = pe.th32ProcessID;
            n += 1;
        }
        if (win.Process32NextW(snap, &pe) == 0) break;
    }
    return out[0..n];
}

test "conpty: a program's output reaches the master, then the hang-up, then its exit code" {
    var p = try Pty.create();
    defer p.close();
    try spawnCmd(&p, &.{ "/d", "/c", "echo zterm-conpty-out& exit 7" });
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    var eof = false;
    try testing.expect(try readUntil(&p, &out, "zterm-conpty-out", 10_000, &eof));
    // The pseudoconsole outlives its program; the waiter closes it once the
    // output is quiet, and only then does the master read end-of-file.
    _ = try readUntil(&p, &out, null, 10_000, &eof);
    try testing.expect(eof);
    try testing.expect(!p.isAlive());
    try testing.expectEqual(@as(u8, 7), p.exit_status.?.code);
    try testing.expectEqual(@as(u8, 0), p.exit_status.?.signal);
}

test "conpty: input written to the master reaches the program" {
    var p = try Pty.create();
    defer p.close();
    try spawnCmd(&p, &.{ "/d", "/q", "/k" });
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    var eof = false;
    const cmd = "set /a 6*7+100\r";
    try testing.expectEqual(cmd.len, try p.write(cmd));
    try testing.expect(try readUntil(&p, &out, "142", 10_000, &eof));
    _ = try p.write("exit 3\r");
    _ = try readUntil(&p, &out, null, 10_000, &eof);
    try testing.expect(eof);
    try testing.expect(!p.isAlive());
    try testing.expectEqual(@as(u8, 3), p.exit_status.?.code);
}

test "conpty: a resize reaches the program" {
    var p = try Pty.create();
    defer p.close();
    try spawnCmd(&p, &.{ "/d", "/q", "/k" });
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    var eof = false;
    // Let cmd.exe come up (its banner), then resize and ask.
    _ = try readUntil(&p, &out, "Microsoft", 10_000, &eof);
    try p.setSize(31, 97);
    out.clearRetainingCapacity();
    _ = try p.write("mode con\r");
    // mode reports the console's size as its program sees it.
    const seen = try readUntil(&p, &out, "97", 10_000, &eof);
    if (!seen) std.debug.print("mode con said: {f}\n", .{std.ascii.hexEscape(out.items, .lower)});
    try testing.expect(seen);
    try testing.expect(std.mem.indexOf(u8, out.items, "31") != null);
    const got = try p.getSize();
    try testing.expectEqual(@as(u16, 31), got.ws_row);
    try testing.expectEqual(@as(u16, 97), got.ws_col);
}

test "conpty: closing a pane never waits and ends the whole tree" {
    var p = try Pty.create();
    try spawnCmd(&p, &.{ "/d", "/c", "ping -n 60 127.0.0.1 >nul" });
    const root = p.child_pid.?;
    // cmd.exe starts ping.exe: wait until the tree has both.
    var chain_buf: [8]ProcEntry = undefined;
    var chain: []ProcEntry = chain_buf[0..0];
    const t0 = sys.monotonicMs();
    while (sys.monotonicMs() - t0 < 10_000) : (win.Sleep(50)) {
        chain = processChain(root, &chain_buf);
        if (chain.len >= 2) break;
    }
    try testing.expect(chain.len >= 2);
    const h_root = holdProcess(root) orelse return error.OpenProcessFailed;
    defer _ = win.CloseHandle(h_root);
    const h_ping = holdProcess(chain[1].pid) orelse return error.OpenProcessFailed;
    defer _ = win.CloseHandle(h_ping);

    const before = sys.monotonicMs();
    p.close();
    try testing.expect(sys.monotonicMs() - before < REAP_GRACE_MS);
    try testing.expect(p.child_pid == null);
    try testing.expectEqual(win.WAIT_OBJECT_0, win.WaitForSingleObject(h_root, @intCast(REAP_GRACE_MS + 5000)));
    try testing.expectEqual(win.WAIT_OBJECT_0, win.WaitForSingleObject(h_ping, @intCast(REAP_GRACE_MS + 5000)));
}

test "conpty: a program that left the console still ends with the pane, and not before" {
    // `start` gives ping a console of its own, so the pseudoconsole's hang-up
    // never reaches it: only the job can end it. cmd.exe exits at once.
    var p = try Pty.create();
    // (No quotes in the command: cmd.exe parses its /c line by its own rules,
    // not the C runtime's, so an escaped quote would not survive.)
    try spawnCmd(&p, &.{ "/d", "/c", "start /min ping -n 60 127.0.0.1" });
    const root = p.child_pid.?;
    try testing.expectEqual(@as(DWORD, 0), p.shared.?.job_error);
    const job = p.shared.?.job orelse return error.NoJob;
    const h_root = holdProcess(root) orelse return error.OpenProcessFailed;
    defer _ = win.CloseHandle(h_root);
    try testing.expectEqual(win.WAIT_OBJECT_0, win.WaitForSingleObject(h_root, 10_000));
    var kids_buf: [8]DWORD = undefined;
    var kids: []DWORD = kids_buf[0..0];
    const t0 = sys.monotonicMs();
    while (sys.monotonicMs() - t0 < 10_000) : (win.Sleep(50)) {
        kids = childrenOf(root, &kids_buf);
        if (kids.len > 0) break;
    }
    if (kids.len == 0) return error.NoChildFound;
    const h_ping = holdProcess(kids[0]) orelse return error.OpenProcessFailed;
    defer _ = win.CloseHandle(h_ping);
    var in_job: win.BOOL = win.FALSE;
    if (win.IsProcessInJob(h_ping, job, &in_job) == 0) return error.IsProcessInJobFailed;
    if (in_job == 0) {
        var nb: [64]u8 = undefined;
        std.debug.print("child {d} ({s}) is not in the pane's job\n", .{ kids[0], processImagePath(kids[0], &nb) orelse "?" });
        return error.ChildNotInJob;
    }
    // The pane's program has exited; what it started runs on, as a
    // background job keeps a POSIX session, until the pane is closed.
    try testing.expectEqual(win.WAIT_TIMEOUT, win.WaitForSingleObject(h_ping, 1000));
    const pending_before = reaper.pendingCount();
    p.close();
    var waited: u32 = 0;
    while (reaper.pendingCount() >= pending_before and waited < 8000) : (waited += 50) win.Sleep(50);
    const r = win.WaitForSingleObject(h_ping, 10_000);
    if (r != win.WAIT_OBJECT_0) std.debug.print("pending before={d} after={d} waited={d}ms\n", .{ pending_before, reaper.pendingCount(), waited });
    try testing.expectEqual(win.WAIT_OBJECT_0, r);
}

test "conpty: processChain follows the newest child down from the pane's program" {
    var p = try Pty.create();
    defer p.close();
    try spawnCmd(&p, &.{ "/d", "/c", "ping -n 30 127.0.0.1 >nul" });
    var chain_buf: [8]ProcEntry = undefined;
    var chain: []ProcEntry = chain_buf[0..0];
    const t0 = sys.monotonicMs();
    while (sys.monotonicMs() - t0 < 10_000) : (win.Sleep(50)) {
        chain = processChain(p.child_pid.?, &chain_buf);
        if (chain.len >= 2) break;
    }
    try testing.expect(chain.len >= 2);
    try testing.expectEqual(p.child_pid.?, chain[0].pid);
    try testing.expect(std.ascii.eqlIgnoreCase(chain[0].name(), "cmd.exe"));
    try testing.expect(std.ascii.eqlIgnoreCase(chain[chain.len - 1].name(), "PING.EXE"));
    var pb: [1024]u8 = undefined;
    const img = processImagePath(chain[0].pid, &pb) orelse return error.NoImagePath;
    try testing.expect(std.ascii.endsWithIgnoreCase(img, "\\System32\\cmd.exe"));
}

test "conpty: a batch file is refused as a pane's program" {
    var p = try Pty.create();
    defer p.close();
    const argv = [_:null]?[*:0]const u8{"C:\\x\\agent.cmd"};
    try testing.expectError(error.BatchFileRefused, p.spawnIn("C:\\x\\agent.cmd", &argv, try testEnv(), null));
    try testing.expectError(error.BatchFileRefused, p.spawnIn("C:\\x\\AGENT.BAT", &argv, try testEnv(), null));
}

test "conpty: the environment block's last entry for a name wins, names matched as Windows does" {
    var p = try Pty.create();
    defer p.close();
    const base = try testEnv();
    var list: std.ArrayList(?[*:0]const u8) = .empty;
    defer list.deinit(testing.allocator);
    var i: usize = 0;
    while (base[i]) |e| : (i += 1) try list.append(testing.allocator, e);
    try list.append(testing.allocator, "ZT_A=first");
    try list.append(testing.allocator, "ZT_A=second");
    try list.append(testing.allocator, "zt_b=lower");
    try list.append(testing.allocator, null);
    const envp: [*:null]const ?[*:0]const u8 = @ptrCast(list.items.ptr);
    const argv = [_:null]?[*:0]const u8{ CMD, "/d", "/c", "echo [%ZT_A%][%ZT_B%]" };
    try p.spawnIn(CMD, &argv, envp, null);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    var eof = false;
    // cmd.exe reads the block: one ZT_A (the later), and zt_b found as ZT_B.
    try testing.expect(try readUntil(&p, &out, "[second][lower]", 10_000, &eof));
}

test "commandLine: Microsoft's own parser (CommandLineToArgvW) recovers every argument" {
    // The documented C runtime examples ("Parsing C command-line arguments"),
    // plus empty, trailing-backslash and shell-metacharacter arguments.
    const cases = [_][]const [:0]const u8{
        &.{ "a b c", "d", "e" },
        &.{ "ab\"c", "\\", "d" },
        &.{ "a\\\\\\b", "de fg", "h" },
        &.{ "a\\\"b", "c", "d" },
        &.{ "a\\\\b c", "d", "e" },
        &.{"ab\" c d"},
        &.{ "", "x" },
        &.{ "trailing\\", "with space\\" },
        &.{ "\"quoted\"", "&|<>^%!" },
        &.{"tab\there"},
    };
    for (cases) |args| {
        var argv: [8:null]?[*:0]const u8 = @splat(null);
        argv[0] = "C:\\Program Files\\x\\prog.exe";
        for (args, 1..) |a, k| argv[k] = a.ptr;
        const line = try cmdline.commandLine(testing.allocator, &argv);
        defer testing.allocator.free(line);
        const wline = try std.unicode.utf8ToUtf16LeAllocZ(testing.allocator, line);
        defer testing.allocator.free(wline);
        var n: c_int = 0;
        const parsed = win.CommandLineToArgvW(wline.ptr, &n) orelse return error.ParseFailed;
        defer _ = win.LocalFree(@ptrCast(parsed));
        try testing.expectEqual(@as(c_int, @intCast(args.len + 1)), n);
        const prog = try std.unicode.utf16LeToUtf8Alloc(testing.allocator, std.mem.sliceTo(parsed[0], 0));
        defer testing.allocator.free(prog);
        try testing.expectEqualStrings("C:\\Program Files\\x\\prog.exe", prog);
        for (args, 1..) |want, k| {
            const got = try std.unicode.utf16LeToUtf8Alloc(testing.allocator, std.mem.sliceTo(parsed[k], 0));
            defer testing.allocator.free(got);
            try testing.expectEqualStrings(want, got);
        }
    }
}

test "socketPair carries bytes both ways" {
    const pair = try socketPair();
    defer _ = win.closesocket(pair[0]);
    defer _ = win.closesocket(pair[1]);
    try testing.expect(sendAll(pair[0], "ping"));
    var buf: [8]u8 = undefined;
    try testing.expectEqual(@as(c_int, 4), win.recv(pair[1], &buf, buf.len, 0));
    try testing.expectEqualStrings("ping", buf[0..4]);
    try testing.expect(sendAll(pair[1], "pong"));
    try testing.expectEqual(@as(c_int, 4), win.recv(pair[0], &buf, buf.len, 0));
    try testing.expectEqualStrings("pong", buf[0..4]);
}

test {
    _ = cmdline;
}
