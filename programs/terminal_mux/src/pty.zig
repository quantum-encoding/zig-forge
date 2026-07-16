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

    rows: u16,
    cols: u16,

    const Self = @This();

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
            // Try to kill the child process
            _ = posix.kill(pid, posix.SIG.TERM) catch {};
        }

        _ = std.c.close(self.slave_fd);
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

    /// Write ALL of `data` to the PTY master (sends to shell). Loops over partial
    /// writes and waits out a full kernel buffer (EAGAIN) so big pastes aren't
    /// truncated — the old single-write() dropped the tail of anything the kernel
    /// only partially accepted.
    pub fn write(self: *Self, data: []const u8) !usize {
        var off: usize = 0;
        while (off < data.len) {
            const ret = c.write(self.master_fd, data.ptr + off, data.len - off);
            if (ret > 0) {
                off += @intCast(ret);
                continue;
            }
            if (ret == 0) break;
            switch (posix.errno(ret)) {
                .INTR => continue, // interrupted — retry
                .AGAIN => {
                    // buffer full: wait until the master is writable again, then retry
                    var pfd = [_]posix.pollfd{.{ .fd = self.master_fd, .events = posix.POLL.OUT, .revents = 0 }};
                    _ = posix.poll(&pfd, 1000) catch {};
                    continue;
                },
                else => return error.WriteFailed,
            }
        }
        return off;
    }

    /// Check if child process is still alive
    pub fn isAlive(self: *const Self) bool {
        if (self.child_pid) |pid| {
            const result = c.waitpid(pid, null, c.W.NOHANG);
            return result == 0; // Returns 0 if still running
        }
        return false;
    }

    /// Wait for child process to exit
    pub fn wait(self: *Self) !u32 {
        if (self.child_pid) |pid| {
            var status: c_int = 0;
            _ = c.waitpid(pid, &status, 0);
            self.child_pid = null;
            // Extract signal from status (WTERMSIG)
            return @intCast(status & 0x7f);
        }
        return 0;
    }
};

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
    // This test requires /dev/ptmx to be available
    const pty = Pty.create() catch |err| {
        if (err == error.FileNotFound or err == error.AccessDenied) {
            // Skip test if /dev/ptmx not available (e.g., in container)
            return;
        }
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

test "winsize struct size" {
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(Winsize));
}
