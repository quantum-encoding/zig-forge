//! Display module for Quantum Seed Vault
//!
//! Provides hardware abstraction for the ST7789 LCD and terminal mock display.

pub const types = @import("display/types.zig");
pub const framebuffer = @import("display/framebuffer.zig");
pub const fonts = @import("display/fonts.zig");
pub const terminal = @import("display/terminal.zig");
pub const st7789 = @import("display/st7789.zig");

// Re-export commonly used types
pub const Color = types.Color;
pub const Colors = types.Colors;
pub const Theme = types.Theme;
pub const Point = types.Point;
pub const Rect = types.Rect;
pub const Align = types.Align;
pub const FontSize = types.FontSize;
pub const WIDTH = types.WIDTH;
pub const HEIGHT = types.HEIGHT;

pub const Framebuffer = framebuffer.Framebuffer;
pub const TerminalDisplay = terminal.TerminalDisplay;
pub const AsciiDisplay = terminal.AsciiDisplay;
pub const ST7789 = st7789.ST7789;

/// Display backend abstraction
pub const Display = union(enum) {
    hardware: *ST7789,
    terminal: *TerminalDisplay,
    ascii: *terminal.AsciiDisplay,

    const Self = @This();

    /// Render framebuffer to display
    pub fn render(self: Self, fb: *const Framebuffer) void {
        switch (self) {
            .hardware => |hw| hw.update(fb) catch {},
            .terminal => |term| term.render(fb),
            .ascii => |ascii| ascii.render(fb),
        }
    }

    /// Clear display
    pub fn clear(self: Self) void {
        switch (self) {
            .hardware => {},
            .terminal => |term| term.clear(),
            .ascii => {},
        }
    }

    /// Get display name
    pub fn getName(self: Self) []const u8 {
        return switch (self) {
            .hardware => "ST7789 LCD (Hardware)",
            .terminal => "Terminal (ANSI 256-color)",
            .ascii => "ASCII Art",
        };
    }
};

/// Check if running on hardware with display available
pub fn isHardwareAvailable() bool {
    return st7789.isHardwareAvailable();
}
