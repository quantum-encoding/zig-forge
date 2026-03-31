//! Terminal control layer — raw mode, ANSI escapes, terminal size, input.
//! Platform-aware: works on macOS (Darwin) and Linux.

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;

// ============================================================================
// Color palette for avionics display
// ============================================================================

pub const Color = enum(u8) {
    black = 0,
    red = 1,
    green = 2,
    yellow = 3,
    blue = 4,
    cyan = 6,
    white = 7,
    dim = 8, // Bright black = dim gray
    bright_red = 9,
    bright_green = 10,
    bright_yellow = 11,
    bright_cyan = 14,
    bright_white = 15,
};

// ============================================================================
// Terminal size
// ============================================================================

pub const TermSize = struct {
    rows: u16,
    cols: u16,
};

const Winsize = extern struct {
    ws_row: u16,
    ws_col: u16,
    ws_xpixel: u16,
    ws_ypixel: u16,
};

// Platform-specific TIOCGWINSZ
const TIOCGWINSZ: c_ulong = if (builtin.os.tag == .macos) 0x40087468 else 0x5413;

extern "c" fn ioctl(fd: c_int, request: c_ulong, ...) c_int;

pub fn getTermSize() TermSize {
    var ws: Winsize = undefined;
    const result = ioctl(posix.STDOUT_FILENO, TIOCGWINSZ, &ws);
    if (result == 0 and ws.ws_row > 0 and ws.ws_col > 0) {
        return .{ .rows = ws.ws_row, .cols = ws.ws_col };
    }
    return .{ .rows = 24, .cols = 80 };
}

// ============================================================================
// Raw terminal mode
// ============================================================================

pub const RawMode = struct {
    original: posix.termios,
    fd: posix.fd_t,

    pub fn enter(fd: posix.fd_t) !RawMode {
        const original = try posix.tcgetattr(fd);
        var raw = original;

        // Input: no break, no CR→NL, no parity, no strip, no flow control
        raw.iflag.BRKINT = false;
        raw.iflag.ICRNL = false;
        raw.iflag.INPCK = false;
        raw.iflag.ISTRIP = false;
        raw.iflag.IXON = false;

        // Output: disable post-processing
        raw.oflag.OPOST = false;

        // Control: 8-bit chars
        raw.cflag.CSIZE = .CS8;

        // Local: echo off, canonical off, no extended, no signal chars
        raw.lflag.ECHO = false;
        raw.lflag.ICANON = false;
        raw.lflag.IEXTEN = false;
        raw.lflag.ISIG = false;

        // Non-blocking read: VMIN=0, VTIME=1 (100ms timeout)
        raw.cc[@intFromEnum(posix.V.MIN)] = 0;
        raw.cc[@intFromEnum(posix.V.TIME)] = 1;

        try posix.tcsetattr(fd, .FLUSH, raw);
        return .{ .original = original, .fd = fd };
    }

    pub fn exit(self: *RawMode) void {
        posix.tcsetattr(self.fd, .FLUSH, self.original) catch {};
    }
};

// ============================================================================
// ANSI escape sequence helpers (write directly to stdout fd)
// ============================================================================

fn writeStdout(data: []const u8) void {
    _ = std.c.write(posix.STDOUT_FILENO, data.ptr, data.len);
}

pub fn enterAltScreen() void {
    writeStdout("\x1b[?1049h");
}

pub fn exitAltScreen() void {
    writeStdout("\x1b[?1049l");
}

pub fn hideCursor() void {
    writeStdout("\x1b[?25l");
}

pub fn showCursor() void {
    writeStdout("\x1b[?25h");
}

pub fn clearScreen() void {
    writeStdout("\x1b[2J\x1b[H");
}

// ============================================================================
// Non-blocking input
// ============================================================================

/// Read a single key, non-blocking.
/// Returns 0 if no input available within VTIME timeout.
pub fn readKey() u8 {
    var buf: [1]u8 = undefined;
    const n = std.c.read(posix.STDIN_FILENO, &buf, 1);
    if (n == 1) return buf[0];
    return 0;
}
