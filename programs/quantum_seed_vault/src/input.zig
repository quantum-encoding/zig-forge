//! Input module for Quantum Seed Vault
//!
//! Provides hardware abstraction for GPIO joystick/buttons and keyboard input.

const input_impl = @import("input/input.zig");

// Re-export types
pub const InputEvent = input_impl.InputEvent;
pub const InputState = input_impl.InputState;
pub const InputHandler = input_impl.InputHandler;
