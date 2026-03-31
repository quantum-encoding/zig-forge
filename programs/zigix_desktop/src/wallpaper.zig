// Wallpaper background for the Zigix desktop.
// Draws a subtle repeating dot/grid pattern in very dim amber on black.

const platform = @import("platform.zig");
const tui = if (platform.is_linux) @import("zig_tui") else @import("tui_pure.zig");
const theme = @import("theme.zig");

const Buffer = tui.Buffer;
const Rect = tui.Rect;
const Cell = tui.Cell;
const Style = tui.Style;

// Pattern characters for the repeating grid motif.
// Using light box-drawing dots and middle-dots for a subtle CRT feel.
const pattern_chars = [4]u21{ '\u{00B7}', ' ', ' ', ' ' }; // · then spaces
const pattern_width: u16 = 4;
const pattern_height: u16 = 2;

/// Fill the given rectangle with the wallpaper pattern.
pub fn render(buf: *Buffer, area: Rect) void {
    const style = theme.wallpaper;
    const bg_cell = Cell.styled(' ', Style{ .bg = theme.term_default_bg });

    var y: u16 = area.y;
    while (y < area.y +| area.height) : (y += 1) {
        var x: u16 = area.x;
        while (x < area.x +| area.width) : (x += 1) {
            // Compute pattern coordinates relative to screen origin for stability
            const px = x % pattern_width;
            const py = y % pattern_height;

            if (py == 0 and px == 0) {
                // Dot at grid intersection
                buf.setChar(x, y, pattern_chars[0], style);
            } else {
                // Empty background
                buf.set(x, y, bg_cell);
            }
        }
    }
}
