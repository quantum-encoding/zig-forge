//! Render module - terminal output and rendering
//!
//! Re-exports all rendering-related types.

pub const renderer = @import("renderer.zig");

pub const Renderer = renderer.Renderer;
pub const TerminalMode = renderer.TerminalMode;

test {
    @import("std").testing.refAllDecls(@This());
}
