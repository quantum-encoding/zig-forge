//! Core module - fundamental types and primitives
//!
//! Re-exports all core types for convenient access.

pub const types = @import("types.zig");
pub const color = @import("color.zig");
pub const cell = @import("cell.zig");
pub const buffer = @import("buffer.zig");
pub const theme = @import("theme.zig");

// Type re-exports
pub const Size = types.Size;
pub const Position = types.Position;
pub const Rect = types.Rect;
pub const Align = types.Align;
pub const VAlign = types.VAlign;
pub const BorderStyle = types.BorderStyle;
pub const BorderChars = types.BorderChars;
pub const Constraint = types.Constraint;

pub const Color = color.Color;
pub const Style = color.Style;
pub const Attrs = color.Attrs;

pub const Cell = cell.Cell;
pub const charWidth = cell.charWidth;
pub const stringWidth = cell.stringWidth;

pub const Buffer = buffer.Buffer;
pub const DiffIterator = buffer.DiffIterator;

pub const Theme = theme.Theme;
pub const Palette = theme.Palette;
pub const ThemeManager = theme.ThemeManager;
pub const WidgetState = theme.WidgetState;
pub const TextVariant = theme.TextVariant;
pub const dark_theme = theme.dark_theme;
pub const light_theme = theme.light_theme;
pub const high_contrast_theme = theme.high_contrast_theme;
pub const global_theme = &theme.global_theme;

test {
    @import("std").testing.refAllDecls(@This());
}
