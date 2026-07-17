/// Zigix freestanding platform backend — no libc, direct syscalls + UART.
///
/// On Zigix, the desktop runs as a regular userspace process communicating
/// via syscalls. Terminal output goes to fd 1 (UART/console), input from fd 0.
/// Child processes are spawned with fork+execve, no PTY needed — the desktop
/// acts as a simple multiplexer routing UART I/O to the focused window.
///
/// For the pure freestanding build: compiled with -Dtarget=riscv64-freestanding-none
/// or x86_64-freestanding-none and linked against the Zigix userspace syscall lib.

const std = @import("std");
const sys = @import("sys");

// ── Terminal I/O ─────────────────────────────────────────────────────────────
// Zigix UART is already in raw mode — no termios needed.

pub fn termInit() void {
    // Hide cursor, alt screen (if VT100 terminal supports it)
    writeOutput("\x1b[?1049h\x1b[?25l");
}

pub fn termDeinit() void {
    writeOutput("\x1b[?25h\x1b[?1049l");
}

pub fn termSize() struct { w: u16, h: u16 } {
    // Zigix: fixed console size or query via ioctl if supported
    // Default to 80x25 VGA text mode dimensions
    return .{ .w = 80, .h = 25 };
}

pub fn writeOutput(data: []const u8) void {
    _ = sys.write(1, data.ptr, data.len);
}

/// Read input from UART (fd 0). Non-blocking — returns 0 if no data.
pub fn readInput(buf: []u8) usize {
    const n = sys.read(0, buf.ptr, buf.len);
    if (n <= 0) return 0;
    return @intCast(n);
}

// ── Process management ───────────────────────────────────────────────────────

pub const ProcessHandle = struct {
    pid: u64,
    // On Zigix, child processes share the console — we track PIDs
    // and use pipes for separate I/O when pipe syscall is available.
    read_fd: u64 = 0,
    write_fd: u64 = 0,
};

/// Spawn a child process via fork+execve.
pub fn spawnProcess(path: []const u8, _: anytype) !ProcessHandle {
    // Validate the path length in the PARENT (F-05) so the caller gets an error
    // instead of a child that silently exit(127)s after the fork has succeeded.
    if (path.len >= 256) return error.PathTooLong;

    const pid_raw = sys.fork();
    if (@as(i64, @bitCast(@as(u64, @intCast(pid_raw)))) < 0) return error.ForkFailed;

    if (pid_raw == 0) {
        // ── Child ──────────────────────────────────────────────────────────────
        // fd hygiene: close every inherited descriptor above stderr before exec
        // so the child cannot observe/inject on sibling windows' I/O fds (a
        // cross-pane keystroke observe/inject primitive). 0/1/2 stay open for the
        // shared console. close() on a non-open fd is a harmless no-op.
        var fd: u64 = 3;
        while (fd < 1024) : (fd += 1) {
            _ = sys.close(fd);
        }

        // Null-terminate the path (length already validated above).
        var path_buf: [256]u8 = undefined;
        @memcpy(path_buf[0..path.len], path);
        path_buf[path.len] = 0;

        // POSIX requires a non-NULL, NULL-terminated argv (with argv[0] set) and
        // a non-NULL envp. The old `execve(path, 0, 0)` made conformant programs
        // SIGSEGV on the first argv[0] deref. argv/envp are arrays of pointer-
        // sized addresses terminated by a null (0) entry; execve takes their
        // addresses as raw u64s.
        var argv = [_]u64{ @intFromPtr(&path_buf), 0 };
        var envp = [_]u64{0};
        _ = sys.execve(@ptrCast(&path_buf), @intFromPtr(&argv), @intFromPtr(&envp));
        sys.exit(127); // exec failed
    }

    return ProcessHandle{ .pid = @bitCast(@as(i64, pid_raw)) };
}

/// Read output from a child process pipe.
pub fn readProcessOutput(handle: ProcessHandle, buf: []u8) usize {
    if (handle.read_fd == 0) return 0;
    const n = sys.read(handle.read_fd, buf.ptr, buf.len);
    if (n <= 0) return 0;
    return @intCast(n);
}

/// Send input to a child process pipe.
pub fn writeProcessInput(handle: ProcessHandle, data: []const u8) void {
    if (handle.write_fd == 0) return;
    _ = sys.write(handle.write_fd, data.ptr, data.len);
}

/// Check if child is alive (non-blocking wait).
pub fn isProcessAlive(handle: ProcessHandle) bool {
    const result = sys.wait4(handle.pid, 0, 1); // WNOHANG=1
    return @as(i64, @bitCast(result)) != @as(i64, @bitCast(handle.pid));
}

// ── System stats ─────────────────────────────────────────────────────────────

pub const SystemStats = struct {
    cpu_pct: u8 = 0,
    mem_pct: u8 = 0,
    mem_total_mb: u32 = 0,
    mem_used_mb: u32 = 0,
    uptime_secs: u64 = 0,
};

pub fn getSystemStats() SystemStats {
    // Zigix: read from kernel info struct or /proc equivalent
    // For now, return placeholder — will be filled via Zigix-specific syscalls
    var uname_buf: [65 * 5]u8 = undefined;
    _ = sys.uname(&uname_buf);

    return SystemStats{
        .cpu_pct = 0,
        .mem_pct = 0,
        .mem_total_mb = 256, // QEMU default
        .mem_used_mb = 0,
        .uptime_secs = 0,
    };
}

// ── Time ─────────────────────────────────────────────────────────────────────

pub fn getWallClock() struct { hour: u8, min: u8, sec: u8 } {
    // Zigix clock_gettime is stubbed, use ticks as proxy
    return .{ .hour = 0, .min = 0, .sec = 0 };
}

/// Busy-wait delay (no nanosleep on Zigix yet).
pub fn sleepMs(ms: u32) void {
    // Use sched_yield in a loop — crude but works
    var i: u32 = 0;
    while (i < ms) : (i += 1) {
        _ = @as(isize, @bitCast(sys.syscall0(124))); // sched_yield
    }
}

// ── Memory allocation ────────────────────────────────────────────────────────

/// Zigix freestanding uses a bump allocator on top of brk()/mmap().
/// For the initial version, use a fixed-size static arena.
const ARENA_SIZE = 256 * 1024; // 256 KiB
var arena_buf: [ARENA_SIZE]u8 = undefined;
var arena_pos: usize = 0;

fn arenaAlloc(_: *anyopaque, n: usize, _: std.mem.Alignment, _: usize) ?[*]u8 {
    const aligned = (arena_pos + 15) & ~@as(usize, 15);
    if (aligned + n > ARENA_SIZE) return null;
    arena_pos = aligned + n;
    return arena_buf[aligned..].ptr;
}

fn arenaResize(_: *anyopaque, buf: []u8, _: std.mem.Alignment, new_len: usize, _: usize) bool {
    _ = buf;
    _ = new_len;
    return false;
}

fn arenaRemap(_: *anyopaque, buf: []u8, _: std.mem.Alignment, _: usize, _: usize) ?[*]u8 {
    _ = buf;
    return null;
}

fn arenaFree(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize) void {}

const arena_vtable = std.mem.Allocator.VTable{
    .alloc = arenaAlloc,
    .resize = arenaResize,
    .remap = arenaRemap,
    .free = arenaFree,
};

pub fn getAllocator() std.mem.Allocator {
    return .{
        .ptr = undefined,
        .vtable = &arena_vtable,
    };
}
