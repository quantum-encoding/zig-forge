//! Clipboard abstraction for Linux (X11/Wayland)
//!
//! Detects the display server and uses appropriate backend:
//! - Wayland: wl-copy / wl-paste
//! - X11: xclip or xsel
//!
//! Supports both CLIPBOARD and PRIMARY selections.

const std = @import("std");
const posix = std.posix;
const libc = std.c;

pub const Selection = enum {
    clipboard, // Standard clipboard (Ctrl+C/V)
    primary, // X11 primary selection (middle-click paste)
};

pub const Backend = enum {
    wayland,
    x11_xclip,
    x11_xsel,
    macos_pb,
    none,
};

pub const ClipboardError = error{
    NoBackendAvailable,
    BackendFailed,
    ReadError,
    WriteError,
    OutOfMemory,
};

/// Detect the display server and available clipboard tools
pub fn detectBackend(allocator: std.mem.Allocator) Backend {
    // Check for Wayland first
    if (std.c.getenv("WAYLAND_DISPLAY")) |_| {
        // Check if wl-copy is available
        if (commandExists(allocator, "wl-copy")) {
            return .wayland;
        }
    }

    // Check for X11
    if (std.c.getenv("DISPLAY")) |_| {
        // Prefer xclip over xsel
        if (commandExists(allocator, "xclip")) {
            return .x11_xclip;
        }
        if (commandExists(allocator, "xsel")) {
            return .x11_xsel;
        }
    }

    // macOS fallback: pbcopy/pbpaste ship with the OS. The PRIMARY selection is
    // X11-only, so on macOS every selection maps to the single system pasteboard.
    if (commandExists(allocator, "pbcopy")) {
        return .macos_pb;
    }

    return .none;
}

/// Check if a command exists in PATH by scanning $PATH for an executable file.
/// This is done directly (access(2)) rather than by spawning `which`, so it does
/// not depend on the child's inherited environment or PATH resolution.
fn commandExists(allocator: std.mem.Allocator, cmd: []const u8) bool {
    _ = allocator;
    const path_env = libc.getenv("PATH") orelse return false;
    const path = std.mem.span(path_env);
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    var it = std.mem.tokenizeScalar(u8, path, ':');
    while (it.next()) |dir| {
        const full = std.fmt.bufPrintZ(&buf, "{s}/{s}", .{ dir, cmd }) catch continue;
        if (libc.access(full.ptr, posix.X_OK) == 0) return true;
    }
    return false;
}

/// Get the command arguments for copying to clipboard
pub fn getCopyCommand(backend: Backend, selection: Selection) ?[]const []const u8 {
    const static = struct {
        var wayland_clip: [2][]const u8 = .{ "wl-copy", "--" };
        var wayland_primary: [3][]const u8 = .{ "wl-copy", "--primary", "--" };
        var xclip_clip: [4][]const u8 = .{ "xclip", "-selection", "clipboard", "-i" };
        var xclip_primary: [4][]const u8 = .{ "xclip", "-selection", "primary", "-i" };
        var xsel_clip: [3][]const u8 = .{ "xsel", "--clipboard", "--input" };
        var xsel_primary: [3][]const u8 = .{ "xsel", "--primary", "--input" };
        var pbcopy: [1][]const u8 = .{"pbcopy"};
    };

    return switch (backend) {
        .wayland => switch (selection) {
            .clipboard => &static.wayland_clip,
            .primary => &static.wayland_primary,
        },
        .x11_xclip => switch (selection) {
            .clipboard => &static.xclip_clip,
            .primary => &static.xclip_primary,
        },
        .x11_xsel => switch (selection) {
            .clipboard => &static.xsel_clip,
            .primary => &static.xsel_primary,
        },
        .macos_pb => &static.pbcopy,
        .none => null,
    };
}

/// Get the command arguments for pasting from clipboard
pub fn getPasteCommand(backend: Backend, selection: Selection) ?[]const []const u8 {
    const static = struct {
        var wayland_clip: [1][]const u8 = .{"wl-paste"};
        var wayland_primary: [2][]const u8 = .{ "wl-paste", "--primary" };
        var xclip_clip: [4][]const u8 = .{ "xclip", "-selection", "clipboard", "-o" };
        var xclip_primary: [4][]const u8 = .{ "xclip", "-selection", "primary", "-o" };
        var xsel_clip: [3][]const u8 = .{ "xsel", "--clipboard", "--output" };
        var xsel_primary: [3][]const u8 = .{ "xsel", "--primary", "--output" };
        var pbpaste: [1][]const u8 = .{"pbpaste"};
    };

    return switch (backend) {
        .wayland => switch (selection) {
            .clipboard => &static.wayland_clip,
            .primary => &static.wayland_primary,
        },
        .x11_xclip => switch (selection) {
            .clipboard => &static.xclip_clip,
            .primary => &static.xclip_primary,
        },
        .x11_xsel => switch (selection) {
            .clipboard => &static.xsel_clip,
            .primary => &static.xsel_primary,
        },
        .macos_pb => &static.pbpaste,
        .none => null,
    };
}

/// Write the whole buffer to `fd`, looping over partial writes and retrying on
/// EINTR. Any other error (including EPIPE when the backend died early) becomes
/// ClipboardError.WriteError so the caller reports a non-zero exit instead of
/// silently truncating the clipboard payload.
fn writeAll(fd: posix.fd_t, data: []const u8) ClipboardError!void {
    var off: usize = 0;
    while (off < data.len) {
        const rc = libc.write(fd, data.ptr + off, data.len - off);
        if (rc < 0) {
            switch (libc.errno(rc)) {
                .INTR => continue, // interrupted before any write; retry
                else => return ClipboardError.WriteError,
            }
        }
        if (rc == 0) return ClipboardError.WriteError; // no progress => failure
        off += @intCast(rc);
    }
}

/// Ignore SIGPIPE so that a backend which exits before draining our write
/// yields an EPIPE error we can handle, rather than killing this process.
fn ignoreSigpipe() void {
    const act = posix.Sigaction{
        .handler = .{ .handler = posix.SIG.IGN },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(posix.SIG.PIPE, &act, null);
}

/// Copy `data` by spawning `cmd` and feeding it on stdin. Exposed for tests
/// so the write path can be exercised against a fake backend.
pub fn copyToCommand(io: std.Io, data: []const u8, cmd: []const []const u8) ClipboardError!void {
    ignoreSigpipe();

    var child = std.process.spawn(io, .{
        .argv = cmd,
        .stdin = .pipe,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return ClipboardError.BackendFailed;

    // Write data to stdin. A write failure must not leak the child: still wait().
    var write_err: ?ClipboardError = null;
    if (child.stdin) |stdin_file| {
        writeAll(stdin_file.handle, data) catch |e| {
            write_err = e;
        };
        _ = libc.close(stdin_file.handle);
        child.stdin = null;
    }

    const term = child.wait(io) catch return ClipboardError.BackendFailed;
    if (write_err) |e| return e;
    if (term != .exited or term.exited != 0) {
        return ClipboardError.BackendFailed;
    }
}

/// Copy data to clipboard
pub fn copy(io: std.Io, allocator: std.mem.Allocator, data: []const u8, selection: Selection) ClipboardError!void {
    const backend = detectBackend(allocator);
    const cmd = getCopyCommand(backend, selection) orelse return ClipboardError.NoBackendAvailable;
    return copyToCommand(io, data, cmd);
}

/// Paste by spawning `cmd` and draining its stdout. Exposed for tests so the
/// read path and exit-status handling can be exercised against a fake backend.
pub fn pasteFromCommand(io: std.Io, allocator: std.mem.Allocator, cmd: []const []const u8) ClipboardError![]u8 {
    var child = std.process.spawn(io, .{
        .argv = cmd,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .ignore,
    }) catch return ClipboardError.BackendFailed;

    // Read all output. `posix.read` retries EINTR internally; a genuine read
    // error (n<0 mapped to an error) becomes ReadError instead of a silent
    // truncation-as-EOF.
    var output = std.ArrayListUnmanaged(u8).empty;
    errdefer output.deinit(allocator);

    var read_err: ?ClipboardError = null;
    if (child.stdout) |stdout_file| {
        var buf: [4096]u8 = undefined;
        while (true) {
            const n = posix.read(stdout_file.handle, &buf) catch {
                read_err = ClipboardError.ReadError;
                break;
            };
            if (n == 0) break; // genuine EOF
            output.appendSlice(allocator, buf[0..n]) catch {
                read_err = ClipboardError.OutOfMemory;
                break;
            };
        }
        _ = libc.close(stdout_file.handle);
        child.stdout = null;
    }

    const term = child.wait(io) catch return ClipboardError.BackendFailed;
    if (read_err) |e| return e;
    // A non-zero backend exit (e.g. xclip -o on an empty/unavailable selection)
    // must surface as a failure, not an empty successful paste.
    if (term != .exited or term.exited != 0) {
        return ClipboardError.BackendFailed;
    }

    return output.toOwnedSlice(allocator) catch return ClipboardError.OutOfMemory;
}

/// Paste data from clipboard
pub fn paste(io: std.Io, allocator: std.mem.Allocator, selection: Selection) ClipboardError![]u8 {
    const backend = detectBackend(allocator);
    const cmd = getPasteCommand(backend, selection) orelse return ClipboardError.NoBackendAvailable;
    return pasteFromCommand(io, allocator, cmd);
}

/// Get backend name for display
pub fn backendName(backend: Backend) []const u8 {
    return switch (backend) {
        .wayland => "Wayland (wl-copy/wl-paste)",
        .x11_xclip => "X11 (xclip)",
        .x11_xsel => "X11 (xsel)",
        .macos_pb => "macOS (pbcopy/pbpaste)",
        .none => "none",
    };
}

// ============================================================================
// Tests
// ============================================================================

test "detect backend" {
    const backend = detectBackend(std.testing.allocator);
    // Just verify it doesn't crash
    _ = backendName(backend);
}

test "get copy command" {
    const cmd = getCopyCommand(.x11_xclip, .clipboard);
    try std.testing.expect(cmd != null);
    try std.testing.expectEqualStrings("xclip", cmd.?[0]);
}

test "get paste command" {
    const cmd = getPasteCommand(.wayland, .clipboard);
    try std.testing.expect(cmd != null);
    try std.testing.expectEqualStrings("wl-paste", cmd.?[0]);
}
