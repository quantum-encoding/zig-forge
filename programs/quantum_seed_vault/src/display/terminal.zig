//! Terminal mock display for testing without hardware
//!
//! Renders the 240x240 framebuffer to the terminal using block characters
//! and ANSI colors. Useful for development and testing.

const std = @import("std");
const types = @import("types.zig");
const Framebuffer = @import("framebuffer.zig").Framebuffer;

const Color = types.Color;
const WIDTH = types.WIDTH;
const HEIGHT = types.HEIGHT;

/// Write to stdout using libc
fn writeStdout(data: []const u8) void {
    _ = std.c.write(std.posix.STDOUT_FILENO, data.ptr, data.len);
}

/// Terminal display renderer
/// Downsamples 240x240 to fit in terminal (configurable)
pub const TerminalDisplay = struct {
    term_width: u16,
    term_height: u16,
    scale_x: u16,
    scale_y: u16,
    buffer: [8192]u8,

    const Self = @This();

    /// Initialize with default terminal size (80x24)
    pub fn init() Self {
        return initWithSize(80, 40);
    }

    /// Initialize with custom terminal size
    pub fn initWithSize(term_width: u16, term_height: u16) Self {
        // Calculate scale to fit display in terminal
        // Each terminal character represents multiple pixels
        const scale_x = (WIDTH + term_width - 1) / term_width;
        const scale_y = (HEIGHT + term_height - 1) / term_height;

        return Self{
            .term_width = term_width,
            .term_height = term_height,
            .scale_x = @max(1, scale_x),
            .scale_y = @max(1, scale_y * 2), // *2 because chars are ~2x tall
            .buffer = undefined,
        };
    }

    /// Clear terminal screen
    pub fn clear(self: *Self) void {
        _ = self;
        // ANSI escape: clear screen and move cursor home
        writeStdout("\x1b[2J\x1b[H");
    }

    /// Render framebuffer to terminal
    pub fn render(self: *Self, fb: *const Framebuffer) void {
        // Move cursor to top-left
        writeStdout("\x1b[H");

        // Draw border top
        writeStdout("\xe2\x94\x8c"); // ┌
        for (0..self.term_width) |_| {
            writeStdout("\xe2\x94\x80"); // ─
        }
        writeStdout("\xe2\x94\x90\n"); // ┐

        // Render each row (sampling from framebuffer)
        var y: u16 = 0;
        while (y < HEIGHT) : (y += self.scale_y) {
            writeStdout("\xe2\x94\x82"); // │

            var x: u16 = 0;
            while (x < WIDTH) : (x += self.scale_x) {
                // Sample pixel at this position
                const idx = @as(usize, y) * WIDTH + @as(usize, x);
                const color = fb.pixels[idx];

                // Convert RGB565 to ANSI 256-color
                const ansi = rgb565ToAnsi256(color);

                // Format ANSI color code manually (simpler approach)
                var color_buf: [16]u8 = undefined;
                // Build "\x1b[48;5;XXXm " where XXX is the color number
                color_buf[0] = 0x1b;
                color_buf[1] = '[';
                color_buf[2] = '4';
                color_buf[3] = '8';
                color_buf[4] = ';';
                color_buf[5] = '5';
                color_buf[6] = ';';
                // Convert ansi (0-255) to decimal string
                var pos: usize = 7;
                if (ansi >= 100) {
                    color_buf[pos] = '0' + ansi / 100;
                    pos += 1;
                }
                if (ansi >= 10) {
                    color_buf[pos] = '0' + (ansi / 10) % 10;
                    pos += 1;
                }
                color_buf[pos] = '0' + ansi % 10;
                pos += 1;
                color_buf[pos] = 'm';
                pos += 1;
                color_buf[pos] = ' ';
                pos += 1;
                writeStdout(color_buf[0..pos]);
            }

            // Reset color and draw right border
            writeStdout("\x1b[0m\xe2\x94\x82\n");
        }

        // Draw bottom border
        writeStdout("\xe2\x94\x94"); // └
        for (0..self.term_width) |_| {
            writeStdout("\xe2\x94\x80"); // ─
        }
        writeStdout("\xe2\x94\x98\n\x1b[0m"); // ┘
    }

    /// Render with status line
    pub fn renderWithStatus(self: *Self, fb: *const Framebuffer, status: []const u8) void {
        self.render(fb);
        writeStdout("\n");
        writeStdout(status);
        writeStdout("\nControls: Arrow keys=Navigate, Enter=Select, Q=Quit\n");
    }
};

/// Convert RGB565 to ANSI 256-color palette
fn rgb565ToAnsi256(color: Color) u8 {
    // Extract RGB components
    const r5: u8 = @truncate((color >> 11) & 0x1F);
    const g6: u8 = @truncate((color >> 5) & 0x3F);
    const b5: u8 = @truncate(color & 0x1F);

    // Scale to 0-5 for ANSI color cube
    const r = @as(u8, r5) * 6 / 32;
    const g = @as(u8, g6) * 6 / 64;
    const b = @as(u8, b5) * 6 / 32;

    // ANSI 256 color cube starts at 16
    // Format: 16 + 36*r + 6*g + b
    return 16 + 36 * r + 6 * g + b;
}

/// Simple ASCII art renderer (for very basic terminals)
pub const AsciiDisplay = struct {
    chars: []const u8 = " .:-=+*#%@",

    const Self = @This();

    pub fn init() Self {
        return Self{};
    }

    pub fn render(self: *Self, fb: *const Framebuffer) void {
        // Move cursor to top-left
        writeStdout("\x1b[H");

        // Scale: 4x8 pixels per character
        const scale_x: u16 = 4;
        const scale_y: u16 = 8;

        var y: u16 = 0;
        while (y < HEIGHT) : (y += scale_y) {
            var x: u16 = 0;
            while (x < WIDTH) : (x += scale_x) {
                // Average brightness in this block
                var total: u32 = 0;
                var count: u32 = 0;

                var dy: u16 = 0;
                while (dy < scale_y and y + dy < HEIGHT) : (dy += 1) {
                    var dx: u16 = 0;
                    while (dx < scale_x and x + dx < WIDTH) : (dx += 1) {
                        const idx = @as(usize, y + dy) * WIDTH + @as(usize, x + dx);
                        const color = fb.pixels[idx];
                        total += colorBrightness(color);
                        count += 1;
                    }
                }

                const avg = if (count > 0) total / count else 0;
                const char_idx = avg * @as(u32, @intCast(self.chars.len - 1)) / 255;
                const char_slice = self.chars[char_idx..][0..1];
                writeStdout(char_slice);
            }
            writeStdout("\n");
        }
    }
};

/// Calculate brightness from RGB565 color (0-255)
fn colorBrightness(color: Color) u32 {
    const r: u32 = (color >> 11) & 0x1F;
    const g: u32 = (color >> 5) & 0x3F;
    const b: u32 = color & 0x1F;

    // Weighted average (human perception)
    // Scale: R and B are 5-bit (0-31), G is 6-bit (0-63)
    return (r * 8 * 77 + g * 4 * 150 + b * 8 * 29) / 256;
}
