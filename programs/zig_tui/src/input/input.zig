//! Input module - event parsing and keyboard/mouse handling
//!
//! Re-exports all input-related types.

pub const event = @import("event.zig");
pub const parser = @import("parser.zig");
pub const keybindings = @import("keybindings.zig");

// Event types
pub const Event = event.Event;
pub const KeyEvent = event.KeyEvent;
pub const MouseEvent = event.MouseEvent;
pub const ResizeEvent = event.ResizeEvent;
pub const FocusEvent = event.FocusEvent;
pub const Key = event.Key;
pub const Modifiers = event.Modifiers;
pub const MouseButton = event.MouseButton;
pub const MouseEventKind = event.MouseEventKind;

// Parser
pub const Parser = parser.Parser;

// Keybindings
pub const Keybindings = keybindings.Keybindings;
pub const KeyBinding = keybindings.KeyBinding;
pub const Mode = keybindings.Mode;
pub const formatKeyBinding = keybindings.formatKeyBinding;

test {
    @import("std").testing.refAllDecls(@This());
}
