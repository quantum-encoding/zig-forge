/// Linux platform backend — uses libc, termios, PTY, /proc.
/// This is the host-development version for testing on real Linux/macOS.

const std = @import("std");
const posix = std.posix;

// ── Terminal I/O ─────────────────────────────────────────────────────────────

var orig_termios: ?posix.termios = null;

pub fn termInit() void {
    orig_termios = posix.tcgetattr(posix.STDIN_FILENO) catch null;
    if (orig_termios) |orig| {
        var raw = orig;
        // Disable echo, canonical mode, signals, flow control
        raw.lflag = raw.lflag.fromInt(raw.lflag.toInt() & ~@as(u32, 0o10 | 0o2 | 0o1 | 0o100000)); // ~(ECHO|ICANON|ISIG|IEXTEN)
        raw.iflag = raw.iflag.fromInt(raw.iflag.toInt() & ~@as(u32, 0o20 | 0o400 | 0o4000 | 0o10000)); // ~(INLCR|ICRNL|IXON|IXOFF)
        raw.cc[@intFromEnum(posix.V.MIN)] = 0;
        raw.cc[@intFromEnum(posix.V.TIME)] = 1;
        posix.tcsetattr(posix.STDIN_FILENO, .NOW, raw) catch {};
    }
    // Alt screen + hide cursor + mouse enable
    writeOutput("\x1b[?1049h\x1b[?25l\x1b[?1006h\x1b[?1003h");
}

pub fn termDeinit() void {
    // Disable mouse + show cursor + normal screen
    writeOutput("\x1b[?1003l\x1b[?1006l\x1b[?25h\x1b[?1049l");
    if (orig_termios) |orig| {
        posix.tcsetattr(posix.STDIN_FILENO, .NOW, orig) catch {};
    }
}

pub fn termSize() struct { w: u16, h: u16 } {
    const TIOCGWINSZ: u32 = if (@import("builtin").os.tag == .macos) 0x40087468 else 0x5413;
    const Winsize = extern struct { ws_row: u16, ws_col: u16, ws_xpixel: u16, ws_ypixel: u16 };
    var ws: Winsize = undefined;
    const result = std.os.linux.ioctl(posix.STDOUT_FILENO, TIOCGWINSZ, @intFromPtr(&ws));
    if (result == 0) return .{ .w = ws.ws_col, .h = ws.ws_row };
    return .{ .w = 80, .h = 24 };
}

pub fn writeOutput(data: []const u8) void {
    _ = std.c.write(posix.STDOUT_FILENO, data.ptr, data.len);
}

/// Poll stdin for input. Returns bytes read, or 0 if no data.
pub fn readInput(buf: []u8) usize {
    var fds = [_]posix.pollfd{.{
        .fd = posix.STDIN_FILENO,
        .events = .{ .IN = true },
        .revents = .{ .IN = false, .PRI = false, .OUT = false, .ERR = false, .HUP = false, .NVAL = false },
    }};
    const ready = posix.poll(&fds, 0) catch return 0;
    if (ready == 0) return 0;
    return posix.read(posix.STDIN_FILENO, buf) catch 0;
}

// ── Process management ───────────────────────────────────────────────────────

pub const ProcessHandle = struct {
    master_fd: posix.fd_t,
    pid: std.posix.pid_t,
};

/// Spawn a shell process with a PTY. Returns a handle for I/O.
pub fn spawnProcess(shell: []const u8, _: std.mem.Allocator) !ProcessHandle {
    // Use terminal_mux Pane or raw PTY — for now, simplified fork/exec
    _ = shell;
    return error.NotImplemented; // Delegates to terminal_mux in the real build
}

/// Read output from a spawned process. Non-blocking.
pub fn readProcessOutput(handle: ProcessHandle, buf: []u8) usize {
    return posix.read(handle.master_fd, buf) catch 0;
}

/// Send input to a spawned process.
pub fn writeProcessInput(handle: ProcessHandle, data: []const u8) void {
    _ = posix.write(handle.master_fd, data) catch {};
}

/// Check if process is still alive.
pub fn isProcessAlive(handle: ProcessHandle) bool {
    _ = handle;
    return true; // TODO: waitpid(WNOHANG)
}

// ── System stats ─────────────────────────────────────────────────────────────

pub const SystemStats = struct {
    cpu_pct: u8 = 0,
    mem_pct: u8 = 0,
    mem_total_mb: u32 = 0,
    mem_used_mb: u32 = 0,
    uptime_secs: u64 = 0,
};

var prev_cpu_total: u64 = 0;
var prev_cpu_idle: u64 = 0;

pub fn getSystemStats() SystemStats {
    var stats = SystemStats{};

    // CPU from /proc/stat
    var cpu_buf: [256]u8 = undefined;
    if (readProcFile("/proc/stat", &cpu_buf)) |n| {
        const line = cpu_buf[0..n];
        if (std.mem.startsWith(u8, line, "cpu ")) {
            var iter = std.mem.tokenizeScalar(u8, line["cpu ".len..], ' ');
            var fields: [10]u64 = .{0} ** 10;
            var fi: usize = 0;
            while (iter.next()) |tok| {
                if (fi >= 10) break;
                fields[fi] = std.fmt.parseInt(u64, tok, 10) catch 0;
                fi += 1;
            }
            var total: u64 = 0;
            for (fields[0..@min(fi, 10)]) |f| total += f;
            const idle = fields[3];
            const dt = total -| prev_cpu_total;
            const di = idle -| prev_cpu_idle;
            if (dt > 0) stats.cpu_pct = @intCast(((dt - di) * 100) / dt);
            prev_cpu_total = total;
            prev_cpu_idle = idle;
        }
    }

    // Memory from /proc/meminfo
    var mem_buf: [512]u8 = undefined;
    if (readProcFile("/proc/meminfo", &mem_buf)) |n| {
        var total: u64 = 0;
        var available: u64 = 0;
        var lines = std.mem.splitScalar(u8, mem_buf[0..n], '\n');
        while (lines.next()) |line| {
            if (std.mem.startsWith(u8, line, "MemTotal:")) total = parseKB(line);
            if (std.mem.startsWith(u8, line, "MemAvailable:")) available = parseKB(line);
        }
        if (total > 0) {
            stats.mem_total_mb = @intCast(total / 1024);
            stats.mem_used_mb = @intCast((total - available) / 1024);
            stats.mem_pct = @intCast(((total - available) * 100) / total);
        }
    }

    // Uptime
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    stats.uptime_secs = @intCast(ts.sec);

    return stats;
}

// ── Time ─────────────────────────────────────────────────────────────────────

pub fn getWallClock() struct { hour: u8, min: u8, sec: u8 } {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.REALTIME, &ts);
    const epoch: u64 = @intCast(ts.sec);
    const day_secs = epoch % 86400;
    return .{
        .hour = @intCast(day_secs / 3600),
        .min = @intCast((day_secs % 3600) / 60),
        .sec = @intCast(day_secs % 60),
    };
}

/// Sleep for the given number of milliseconds.
pub fn sleepMs(ms: u32) void {
    std.time.sleep(@as(u64, ms) * 1_000_000);
}

// ── Memory allocation ────────────────────────────────────────────────────────

pub fn getAllocator() std.mem.Allocator {
    return std.heap.c_allocator;
}

// ── Helpers ──────────────────────────────────────────────────────────────────

fn readProcFile(path: [*:0]const u8, buf: []u8) ?usize {
    const c = @cImport({ @cInclude("fcntl.h"); @cInclude("unistd.h"); });
    const fd = c.open(path, c.O_RDONLY);
    if (fd < 0) return null;
    defer _ = c.close(fd);
    const n = c.read(fd, buf.ptr, buf.len);
    if (n <= 0) return null;
    return @intCast(n);
}

fn parseKB(line: []const u8) u64 {
    var iter = std.mem.tokenizeAny(u8, line, " \t");
    _ = iter.next();
    const val = iter.next() orelse return 0;
    return std.fmt.parseInt(u64, val, 10) catch 0;
}
