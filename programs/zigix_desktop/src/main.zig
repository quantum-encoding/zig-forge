// Zigix Desktop — a TUI desktop environment / window manager.
//
// Dual-use: builds for Linux (with libc, PTY, /proc) or Zigix freestanding
// (pure syscalls, UART). Platform selection is compile-time via build.zig.
//
// On Linux: full terminal_mux PTY integration, /proc stats, termios raw mode.
// On Zigix: direct UART I/O, fork+execve processes, kernel stats.
//
// Architecture:
//   platform.zig → { linux.zig | zigix.zig }
//   main.zig → event loop (platform-aware)
//   compositor.zig → wallpaper → windows → panel → launcher (pure Zig)
//   theme.zig → PC-98 amber palette (pure Zig)

const std = @import("std");
const platform = @import("platform.zig");
const compositor = @import("compositor.zig");
const Desktop = @import("desktop.zig").Desktop;
const Panel = @import("panel.zig");
const Launcher = @import("launcher.zig");
const theme = @import("theme.zig");

// Conditionally import zig_tui only on Linux (it needs libc)
const tui = if (platform.is_linux) @import("zig_tui") else @import("tui_pure.zig");

const Buffer = tui.Buffer;
const Size = tui.Size;
const Event = tui.Event;
const Key = tui.Key;
const Style = tui.Style;

// ── Global state ─────────────────────────────────────────────────────────────

var desktop: Desktop = undefined;
var panel: Panel.Panel = .{};
var launcher: Launcher.Launcher = .{};
var tick_counter: u32 = 0;
var quit_requested: bool = false;
var prefix_active: bool = false;

// Freestanding entry point
comptime {
    if (platform.is_zigix) {
        @export(&_start, .{ .name = "_start" });
    }
}

fn _start() callconv(.naked) noreturn {
    if (comptime @import("builtin").cpu.arch == .riscv64) {
        asm volatile (
            \\mv a0, sp
            \\andi sp, sp, -16
            \\call main
            \\1: wfi
            \\j 1b
        );
    } else if (comptime @import("builtin").cpu.arch == .aarch64) {
        asm volatile (
            \\mov x0, sp
            \\mov x29, #0
            \\bl main
            \\1: wfi
            \\b 1b
        );
    } else {
        asm volatile (
            "mov %%rsp, %%rdi\n" ++
                "and $-16, %%rsp\n" ++
                "call main"
            ::: "memory"
        );
    }
}

pub const panic = if (platform.is_zigix) zigixPanic else @import("std").debug.FullPanic(defaultPanic);

fn zigixPanic(msg: []const u8, _: ?*@import("std").builtin.StackTrace, _: ?usize) noreturn {
    _ = msg;
    @import("sys").exit(99);
}

fn defaultPanic(msg: []const u8, _: ?usize) noreturn {
    _ = msg;
    while (true) {}
}

pub fn main() !void {
    return mainInner();
}

fn zigixMain() callconv(.c) noreturn {
    mainInner() catch {};
    @import("sys").exit(0);
}

comptime {
    if (platform.is_zigix) {
        @export(&zigixMain, .{ .name = "main" });
    }
}

fn mainInner() !void {
    const allocator = platform.getAllocator();

    desktop = Desktop.init(allocator);
    defer desktop.deinit();

    // Spawn the initial shell window
    desktop.createDefaultWindow() catch {
        // On Zigix, this may fail if no shell is on disk — run without windows
    };

    panel.updateStats();

    if (platform.is_linux) {
        // Full zig_tui Application loop (termios, poll, etc.)
        try runWithTuiApp(allocator);
    } else {
        // Pure event loop for Zigix freestanding
        try runPureLoop(allocator);
    }
}

// ── Linux: zig_tui Application event loop ────────────────────────────────────

fn runWithTuiApp(allocator: std.mem.Allocator) !void {
    if (!platform.is_linux) return;

    var app = try tui.Application.init(allocator, .{
        .mouse_enabled = true,
        .tick_rate_ms = 16,
    });
    defer app.deinit();

    const initial_size = app.getSize();
    updateContentArea(initial_size);

    app.setRenderCallback(renderFrame);
    app.setEventCallback(handleEvent);

    try app.run();
}

fn renderFrame(buf: *Buffer, size: Size) void {
    buf.clearStyle(Style{ .bg = theme.term_default_bg });
    compositor.render(buf, size, &desktop, &panel, &launcher);
}

fn handleEvent(event: Event) bool {
    if (quit_requested) return false;
    switch (event) {
        .tick => return onTick(),
        .resize => |r| {
            updateContentArea(Size{ .width = r.width, .height = r.height });
            return true;
        },
        .key => |k| return onKey(event, k),
        else => return true,
    }
}

// ── Zigix: pure freestanding event loop ──────────────────────────────────────

fn runPureLoop(allocator: std.mem.Allocator) !void {
    _ = allocator;
    platform.termInit();
    defer platform.termDeinit();

    const size = platform.termSize();
    updateContentArea(Size{ .width = size.w, .height = size.h });

    // Simple render loop: read input → process → render → sleep
    var buf = try Buffer.init(platform.getAllocator(), size.w, size.h);

    while (!quit_requested) {
        // Poll input
        var input_buf: [64]u8 = undefined;
        const n = platform.readInput(&input_buf);
        if (n > 0) {
            // Parse raw bytes into key events
            for (input_buf[0..n]) |byte| {
                if (byte == 0x1B) {
                    // ESC — could be alt-key or standalone escape
                    // Simplified: treat as escape key
                    quit_requested = true;
                    break;
                }
                if (byte == 0x03) { // Ctrl+C
                    quit_requested = true;
                    break;
                }
                // Forward to focused window
                if (desktop.getFocused()) |win| {
                    win.sendInput(input_buf[0..n]);
                }
                break; // Process whole chunk at once
            }
        }

        // Tick
        _ = onTick();

        // Render
        buf.clearStyle(Style{ .bg = theme.term_default_bg });
        compositor.render(&buf, Size{ .width = size.w, .height = size.h }, &desktop, &panel, &launcher);

        // Flush buffer to UART
        // TODO: differential rendering for Zigix
        renderBufferToUart(&buf, size.w, size.h);

        platform.sleepMs(16);
    }
}

fn renderBufferToUart(buf: *const Buffer, width: u16, height: u16) void {
    // Move cursor home
    platform.writeOutput("\x1b[H");

    var render_buf: [8192]u8 = undefined;
    var pos: usize = 0;

    var row: u16 = 0;
    while (row < height) : (row += 1) {
        var col: u16 = 0;
        while (col < width) : (col += 1) {
            if (buf.get(col, row)) |cell| {
                const ch = cell.char;
                if (ch > 0 and ch < 128) {
                    if (pos < render_buf.len) {
                        render_buf[pos] = @truncate(ch);
                        pos += 1;
                    }
                } else {
                    if (pos < render_buf.len) {
                        render_buf[pos] = ' ';
                        pos += 1;
                    }
                }
            }
        }
        // Newline between rows
        if (pos + 2 < render_buf.len) {
            render_buf[pos] = '\r';
            pos += 1;
            render_buf[pos] = '\n';
            pos += 1;
        }

        // Flush periodically to avoid buffer overflow
        if (pos > render_buf.len - 256) {
            platform.writeOutput(render_buf[0..pos]);
            pos = 0;
        }
    }

    if (pos > 0) {
        platform.writeOutput(render_buf[0..pos]);
    }
}

// ── Shared logic (both platforms) ────────────────────────────────────────────

fn onTick() bool {
    desktop.pollAllOutputs();
    tick_counter +%= 1;
    if (tick_counter % 120 == 0) panel.updateStats();
    if (tick_counter % 60 == 0) _ = desktop.reapDead();
    return true;
}

fn onKey(event: Event, k: tui.KeyEvent) bool {
    if (launcher.active) {
        if (launcher.handleKey(event)) |cmd| {
            desktop.createWindow(cmd) catch {};
        }
        return true;
    }

    if (k.modifiers.ctrl and k.modifiers.alt) {
        return handleWmKeybind(k);
    }

    if (prefix_active) {
        prefix_active = false;
        return true;
    }

    forwardKeyToFocused(event, k);
    return true;
}

fn handleWmKeybind(k: tui.KeyEvent) bool {
    switch (k.key) {
        .char => |c| switch (c) {
            'q', 'Q' => { quit_requested = true; return false; },
            'n', 'N' => { desktop.createDefaultWindow() catch {}; return true; },
            'w', 'W' => {
                desktop.closeFocused();
                if (desktop.window_count == 0) { quit_requested = true; return false; }
                return true;
            },
            'l', 'L' => { launcher.toggle(); return true; },
            'h', 'H' => { desktop.setLayout(.split_h); return true; },
            'v', 'V' => { desktop.setLayout(.split_v); return true; },
            't', 'T' => { desktop.setLayout(.tiled); return true; },
            'f', 'F' => { desktop.setLayout(.single); return true; },
            '1'...'9' => { desktop.focusByNumber(@intCast(c - '0')); return true; },
            else => return true,
        },
        .special => |s| switch (s) {
            .tab, .right => { desktop.focusNext(); return true; },
            .left => { desktop.focusPrev(); return true; },
            else => return true,
        },
    }
}

fn forwardKeyToFocused(event: Event, k: tui.KeyEvent) void {
    _ = event;
    const win = desktop.getFocused() orelse return;
    var buf: [16]u8 = undefined;
    const seq = keyToBytes(k, &buf);
    if (seq.len > 0) win.sendInput(seq);
}

fn keyToBytes(k: tui.KeyEvent, buf: *[16]u8) []const u8 {
    switch (k.key) {
        .char => |c| {
            if (k.modifiers.ctrl and c >= 'a' and c <= 'z') {
                buf[0] = @intCast(c - 'a' + 1);
                return buf[0..1];
            }
            if (k.modifiers.alt) {
                buf[0] = 0x1B;
                const len = std.unicode.utf8Encode(c, buf[1..]) catch return buf[0..0];
                return buf[0 .. 1 + len];
            }
            const len = std.unicode.utf8Encode(c, buf[0..]) catch return buf[0..0];
            return buf[0..len];
        },
        .special => |s| return specialKeySequence(s),
    }
}

fn specialKeySequence(key: Key) []const u8 {
    return switch (key) {
        .enter => "\r",
        .tab => "\t",
        .backspace => "\x7F",
        .escape => "\x1B",
        .up => "\x1B[A",
        .down => "\x1B[B",
        .right => "\x1B[C",
        .left => "\x1B[D",
        .home => "\x1B[H",
        .end => "\x1B[F",
        .page_up => "\x1B[5~",
        .page_down => "\x1B[6~",
        .delete => "\x1B[3~",
        .f1 => "\x1BOP",
        .f2 => "\x1BOQ",
        .f3 => "\x1BOR",
        .f4 => "\x1BOS",
        else => "",
    };
}

fn updateContentArea(size: Size) void {
    const panel_h = Panel.PANEL_HEIGHT;
    const content_h = if (size.height > panel_h) size.height - panel_h else 1;
    desktop.setContentArea(0, 0, size.width, content_h);
}
