// Panel — bottom taskbar for the Zigix desktop.
// Shows window list, mini system stats, and clock.
// Uses platform abstraction for system stats and time.

const std = @import("std");
const tui = if (platform.is_linux) @import("zig_tui") else @import("tui_pure.zig");
const theme = @import("theme.zig");
const Window = @import("window.zig").Window;
const platform = @import("platform.zig");

const Buffer = tui.Buffer;
const Rect = tui.Rect;
const Cell = tui.Cell;
const Style = tui.Style;

pub const PANEL_HEIGHT: u16 = 2; // separator line + status row

pub const Panel = struct {
    stats: platform.SystemStats = .{},

    const Self = @This();

    /// Update system statistics via platform layer.
    pub fn updateStats(self: *Self) void {
        self.stats = platform.getSystemStats();
    }

    /// Render the panel into the buffer at the given rect.
    pub fn render(self: *const Self, buf: *Buffer, area: Rect, windows: []const Window, focused_idx: u8) void {
        if (area.height < 2) return;

        // Row 0: separator line ─────
        const sep_y = area.y;
        var sx: u16 = area.x;
        while (sx < area.x +| area.width) : (sx += 1) {
            buf.setChar(sx, sep_y, 0x2500, theme.panel_separator);
        }

        // Row 1: status bar
        const bar_y = area.y +| 1;

        // Fill background
        buf.fill(
            Rect{ .x = area.x, .y = bar_y, .width = area.width, .height = 1 },
            Cell.styled(' ', theme.panel_bg),
        );

        // Left: window list
        var x: u16 = area.x +| 1;
        for (windows, 0..) |win, i| {
            const is_focused = (i == focused_idx);
            const style = if (is_focused) theme.panel_active_window else theme.panel_inactive_window;

            var tag_buf: [32]u8 = undefined;
            const tag = std.fmt.bufPrint(&tag_buf, " {d}:{s} ", .{ i + 1, win.getTitle() }) catch " ? ";
            const written = buf.writeStr(x, bar_y, tag, style);
            x +|= written +| 1;
        }

        // Right: stats + clock
        const clock = platform.getWallClock();
        var right_buf: [48]u8 = undefined;
        const right_text = std.fmt.bufPrint(&right_buf, "CPU:{d}% MEM:{d}%  {d:0>2}:{d:0>2}:{d:0>2}", .{
            self.stats.cpu_pct,
            self.stats.mem_pct,
            clock.hour,
            clock.min,
            clock.sec,
        }) catch "??:??:??";

        const right_len: u16 = @intCast(right_text.len);
        const right_x = if (area.width > right_len + 2) area.x +| area.width -| right_len -| 1 else area.x;
        _ = buf.writeStr(right_x, bar_y, right_text, theme.panel_clock);
    }
};
