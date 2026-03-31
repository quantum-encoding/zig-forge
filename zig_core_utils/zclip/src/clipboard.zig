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

    return .none;
}

/// Check if a command exists in PATH
fn commandExists(allocator: std.mem.Allocator, cmd: []const u8) bool {
    _ = allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const argv = [_][]const u8{ "which", cmd };
    var child = std.process.spawn(io, .{
        .argv = &argv,
        .stdout = .ignore,
        .stderr = .ignore,
        .stdin = .ignore,
    }) catch return false;

    const term = child.wait(io) catch return false;
    return term == .exited and term.exited == 0;
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
        .none => null,
    };
}

/// Copy data to clipboard
pub fn copy(allocator: std.mem.Allocator, data: []const u8, selection: Selection) ClipboardError!void {
    const backend = detectBackend(allocator);
    const cmd = getCopyCommand(backend, selection) orelse return ClipboardError.NoBackendAvailable;

    const io = std.Io.Threaded.global_single_threaded.io();
    var child = std.process.spawn(io, .{
        .argv = cmd,
        .stdin = .pipe,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return ClipboardError.BackendFailed;

    // Write data to stdin
    if (child.stdin) |stdin_file| {
        _ = libc.write(stdin_file.handle, data.ptr, data.len);
        _ = libc.close(stdin_file.handle);
        child.stdin = null;
    }

    const term = child.wait(io) catch return ClipboardError.BackendFailed;
    if (term != .exited or term.exited != 0) {
        return ClipboardError.BackendFailed;
    }
}

/// Paste data from clipboard
pub fn paste(allocator: std.mem.Allocator, selection: Selection) ClipboardError![]u8 {
    const backend = detectBackend(allocator);
    const cmd = getPasteCommand(backend, selection) orelse return ClipboardError.NoBackendAvailable;

    const io = std.Io.Threaded.global_single_threaded.io();
    var child = std.process.spawn(io, .{
        .argv = cmd,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .ignore,
    }) catch return ClipboardError.BackendFailed;

    // Read all output
    var output = std.ArrayListUnmanaged(u8).empty;
    errdefer output.deinit(allocator);

    if (child.stdout) |stdout_file| {
        var buf: [4096]u8 = undefined;
        while (true) {
            const n_signed = libc.read(stdout_file.handle, &buf, buf.len);
            if (n_signed <= 0) break;
            const n: usize = @intCast(n_signed);
            output.appendSlice(allocator, buf[0..n]) catch return ClipboardError.OutOfMemory;
        }
        _ = libc.close(stdout_file.handle);
        child.stdout = null;
    }

    const term = child.wait(io) catch return ClipboardError.BackendFailed;
    _ = term;

    return output.toOwnedSlice(allocator) catch return ClipboardError.OutOfMemory;
}

/// Get backend name for display
pub fn backendName(backend: Backend) []const u8 {
    return switch (backend) {
        .wayland => "Wayland (wl-copy/wl-paste)",
        .x11_xclip => "X11 (xclip)",
        .x11_xsel => "X11 (xsel)",
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
