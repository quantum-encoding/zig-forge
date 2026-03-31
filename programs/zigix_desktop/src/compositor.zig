// Compositor — assembles the final frame for the Zigix desktop.
// Render pipeline: wallpaper → windows → panel → launcher overlay.

const platform = @import("platform.zig");
const tui = if (platform.is_linux) @import("zig_tui") else @import("tui_pure.zig");
const theme = @import("theme.zig");
const wallpaper = @import("wallpaper.zig");
const Window = @import("window.zig").Window;
const Panel = @import("panel.zig");
const Launcher = @import("launcher.zig");
const Desktop = @import("desktop.zig").Desktop;

const Buffer = tui.Buffer;
const Size = tui.Size;
const Rect = tui.Rect;
const Style = tui.Style;
const Cell = tui.Cell;

/// Render the entire desktop frame into the buffer.
pub fn render(
    buf: *Buffer,
    screen: Size,
    desktop: *Desktop,
    panel: *const Panel.Panel,
    launcher: *const Launcher.Launcher,
) void {
    if (screen.height < 4 or screen.width < 20) {
        buf.clearStyle(Style{ .bg = theme.term_default_bg });
        _ = buf.writeStr(0, 0, "Terminal too small", theme.text_error);
        return;
    }

    // Calculate regions
    const panel_height = Panel.PANEL_HEIGHT;
    const content_h = if (screen.height > panel_height) screen.height - panel_height else 1;

    const content_rect = Rect{
        .x = 0,
        .y = 0,
        .width = screen.width,
        .height = content_h,
    };

    const panel_rect = Rect{
        .x = 0,
        .y = content_h,
        .width = screen.width,
        .height = panel_height,
    };

    // 1. Wallpaper — fill entire content area with background pattern
    wallpaper.render(buf, content_rect);

    // 2. Windows — render each window's chrome and terminal content
    const windows = desktop.getWindows();
    for (windows) |*win| {
        win.renderTo(buf);
    }

    // 3. Panel — taskbar at bottom
    panel.render(buf, panel_rect, windows, desktop.focused_idx);

    // 4. Launcher overlay — on top of everything if active
    if (launcher.active) {
        launcher.render(buf, screen);
    }
}
