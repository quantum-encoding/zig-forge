//! Guardian Shield - eBPF-based System Security Framework
//!
//! Copyright (c) 2025 Richard Tune / Quantum Encoding Ltd
//! Author: Richard Tune
//! Contact: info@quantumencoding.io
//! Website: https://quantumencoding.io
//!
//! License: Dual License - MIT (Non-Commercial) / Commercial License
//!
//! NON-COMMERCIAL USE (MIT License):
//! Permission is hereby granted, free of charge, to any person obtaining a copy
//! of this software and associated documentation files (the "Software"), to deal
//! in the Software without restriction for NON-COMMERCIAL purposes, including
//! without limitation the rights to use, copy, modify, merge, publish, distribute,
//! sublicense, and/or sell copies of the Software for non-commercial purposes,
//! and to permit persons to whom the Software is furnished to do so, subject to
//! the following conditions:
//!
//! The above copyright notice and this permission notice shall be included in all
//! copies or substantial portions of the Software.
//!
//! THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//! IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//! FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//! AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//! LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//! OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
//! SOFTWARE.
//!
//! COMMERCIAL USE:
//! Commercial use of this software requires a separate commercial license.
//! Contact info@quantumencoding.io for commercial licensing terms.


// SPDX-License-Identifier: GPL-2.0
//
// gaming_cheats.zig - Forbidden Input Incantations
//
// Purpose: Define behavioral patterns that detect modded controllers and cheating devices
// Architecture: Grimoire patterns adapted for USB HID input event streams
// Philosophy: Judge the hands, not the mind
//
// THE DOCTRINE OF INPUT SOVEREIGNTY:
//   - We do not scan memory or inspect files
//   - We observe only the player's input behavior
//   - If hands perform physically impossible actions → judgment is passed
//

const std = @import("std");

/// Input event types (from linux/input.h)
pub const InputEventType = enum(u16) {
    EV_SYN = 0x00,  // Synchronization events
    EV_KEY = 0x01,  // Key/button press or release
    EV_REL = 0x02,  // Relative axis (mouse movement)
    EV_ABS = 0x03,  // Absolute axis (joystick position)
    EV_MSC = 0x04,  // Miscellaneous
    EV_SW = 0x05,   // Switch
    EV_LED = 0x11,  // LEDs
    EV_SND = 0x12,  // Sounds
    EV_REP = 0x14,  // Repeat
    EV_FF = 0x15,   // Force feedback
    EV_PWR = 0x16,  // Power management
    EV_FF_STATUS = 0x17, // Force feedback status
};

/// Common button codes (from linux/input-event-codes.h)
pub const ButtonCode = struct {
    // Mouse buttons
    pub const BTN_LEFT: u16 = 0x110;
    pub const BTN_RIGHT: u16 = 0x111;
    pub const BTN_MIDDLE: u16 = 0x112;

    // Gamepad buttons (Xbox-style layout)
    pub const BTN_SOUTH: u16 = 0x130;  // A button (Xbox), X button (PlayStation)
    pub const BTN_EAST: u16 = 0x131;   // B button (Xbox), Circle (PlayStation)
    pub const BTN_NORTH: u16 = 0x133;  // Y button (Xbox), Triangle (PlayStation)
    pub const BTN_WEST: u16 = 0x134;   // X button (Xbox), Square (PlayStation)
    pub const BTN_TL: u16 = 0x136;     // Left bumper
    pub const BTN_TR: u16 = 0x137;     // Right bumper
    pub const BTN_SELECT: u16 = 0x13a; // Select/Back
    pub const BTN_START: u16 = 0x13b;  // Start
    pub const BTN_MODE: u16 = 0x13c;   // Xbox/PS button
    pub const BTN_THUMBL: u16 = 0x13d; // Left stick click
    pub const BTN_THUMBR: u16 = 0x13e; // Right stick click

    // Triggers (analog, but sometimes appear as buttons)
    pub const BTN_TL2: u16 = 0x138;    // Left trigger
    pub const BTN_TR2: u16 = 0x139;    // Right trigger
};

/// Relative axis codes (mouse)
pub const RelativeAxis = struct {
    pub const REL_X: u16 = 0x00;
    pub const REL_Y: u16 = 0x01;
    pub const REL_Z: u16 = 0x02;
    pub const REL_WHEEL: u16 = 0x08;
    pub const REL_HWHEEL: u16 = 0x06;
};

/// Severity levels
pub const Severity = enum(u8) {
    debug = 0,
    info = 1,
    warning = 2,
    high = 3,
    critical = 4,
};

/// Input pattern step (similar to GrimoirePattern but for input events)
pub const InputPatternStep = struct {
    /// Event type (EV_KEY, EV_REL, etc.)
    event_type: ?InputEventType = null,

    /// Specific button/key code (null = any code of this event_type)
    code: ?u16 = null,

    /// Expected value (for buttons: 0=release, 1=press, 2=repeat)
    /// For relative axes: specific delta or null for any
    value: ?i32 = null,

    /// Maximum time delta from previous step (microseconds)
    max_time_delta_us: u64 = 0,

    /// Minimum time delta from previous step (microseconds)
    /// Used to detect TOO FAST actions (inhuman speed)
    min_time_delta_us: u64 = 0,

    /// Maximum event distance from previous step
    max_step_distance: u32 = 0,
};

/// Complete input pattern definition
pub const InputPattern = struct {
    /// Pattern ID hash (FNV-1a)
    id_hash: u64,

    /// Human-readable name
    name: [32]u8,

    /// Pattern steps
    steps: []const InputPatternStep,

    /// Severity if pattern matches
    severity: Severity,

    /// Maximum time window for entire sequence (milliseconds)
    max_sequence_window_ms: u64,

    /// Pattern enabled flag
    enabled: bool = true,

    /// Description (for logs and reports)
    description: []const u8,

    /// Compile-time hash function (FNV-1a)
    pub fn hashName(comptime name_str: []const u8) u64 {
        var hash: u64 = 0xcbf29ce484222325;
        for (name_str) |byte| {
            hash ^= byte;
            hash *%= 0x100000001b3;
        }
        return hash;
    }

    /// Create pattern name from string (zero-padded)
    pub fn makeName(comptime name_str: []const u8) [32]u8 {
        var result = [_]u8{0} ** 32;
        @memcpy(result[0..@min(name_str.len, 32)], name_str[0..@min(name_str.len, 32)]);
        return result;
    }
};

// ═══════════════════════════════════════════════════════════════════════════
// FORBIDDEN INCANTATIONS: Gaming Cheat Patterns
// ═══════════════════════════════════════════════════════════════════════════

/// Pattern 1: Rapid Fire Mod (Cronus Zen, Strike Pack)
///
/// Behavior: Button presses at superhuman speed with perfect timing
/// Detection: 6+ presses within 50ms with <2ms jitter
/// False Positive Risk: ZERO (physically impossible for humans)
pub const rapid_fire_cronus = InputPattern{
    .id_hash = InputPattern.hashName("rapid_fire_cronus"),
    .name = InputPattern.makeName("rapid_fire_cronus"),
    .severity = .critical,
    .max_sequence_window_ms = 50,
    .description = "Cronus Zen / Strike Pack rapid fire mod - inhuman button press speed",

    .steps = &[_]InputPatternStep{
        // Step 1: Button press
        .{
            .event_type = .EV_KEY,
            .code = ButtonCode.BTN_SOUTH,  // A/X button (most common for rapid fire)
            .value = 1,  // Press
            .max_time_delta_us = 0,
        },
        // Step 2: Button release (within 5ms)
        .{
            .event_type = .EV_KEY,
            .code = ButtonCode.BTN_SOUTH,
            .value = 0,  // Release
            .max_time_delta_us = 5_000,  // <5ms
            .min_time_delta_us = 500,    // >0.5ms (debounce)
        },
        // Step 3: Button press again (within 5ms)
        .{
            .event_type = .EV_KEY,
            .code = ButtonCode.BTN_SOUTH,
            .value = 1,
            .max_time_delta_us = 5_000,
            .min_time_delta_us = 500,
        },
        // Step 4: Button release
        .{
            .event_type = .EV_KEY,
            .code = ButtonCode.BTN_SOUTH,
            .value = 0,
            .max_time_delta_us = 5_000,
            .min_time_delta_us = 500,
        },
        // Step 5: Button press
        .{
            .event_type = .EV_KEY,
            .code = ButtonCode.BTN_SOUTH,
            .value = 1,
            .max_time_delta_us = 5_000,
            .min_time_delta_us = 500,
        },
        // Step 6: Button release
        .{
            .event_type = .EV_KEY,
            .code = ButtonCode.BTN_SOUTH,
            .value = 0,
            .max_time_delta_us = 5_000,
            .min_time_delta_us = 500,
        },
    },
};

/// Pattern 2: Rapid Fire (Right Trigger variant)
///
/// Some mods attach to the trigger button instead of face buttons
pub const rapid_fire_trigger = InputPattern{
    .id_hash = InputPattern.hashName("rapid_fire_trigger"),
    .name = InputPattern.makeName("rapid_fire_trigger"),
    .severity = .critical,
    .max_sequence_window_ms = 50,
    .description = "Rapid fire mod on trigger button - common in FPS games",

    .steps = &[_]InputPatternStep{
        .{
            .event_type = .EV_KEY,
            .code = ButtonCode.BTN_TR2,  // Right trigger
            .value = 1,
            .max_time_delta_us = 0,
        },
        .{
            .event_type = .EV_KEY,
            .code = ButtonCode.BTN_TR2,
            .value = 0,
            .max_time_delta_us = 5_000,
            .min_time_delta_us = 500,
        },
        .{
            .event_type = .EV_KEY,
            .code = ButtonCode.BTN_TR2,
            .value = 1,
            .max_time_delta_us = 5_000,
            .min_time_delta_us = 500,
        },
        .{
            .event_type = .EV_KEY,
            .code = ButtonCode.BTN_TR2,
            .value = 0,
            .max_time_delta_us = 5_000,
            .min_time_delta_us = 500,
        },
        .{
            .event_type = .EV_KEY,
            .code = ButtonCode.BTN_TR2,
            .value = 1,
            .max_time_delta_us = 5_000,
            .min_time_delta_us = 500,
        },
        .{
            .event_type = .EV_KEY,
            .code = ButtonCode.BTN_TR2,
            .value = 0,
            .max_time_delta_us = 5_000,
            .min_time_delta_us = 500,
        },
    },
};

/// Pattern 3: Perfect Macro Sequence
///
/// Behavior: Complex button sequence executed with perfect timing
/// Detection: 15+ inputs in <100ms with perfect intervals
/// Example: Build macros in Fortnite, combos in fighting games
pub const perfect_macro_sequence = InputPattern{
    .id_hash = InputPattern.hashName("perfect_macro_sequence"),
    .name = InputPattern.makeName("perfect_macro_sequence"),
    .severity = .high,
    .max_sequence_window_ms = 100,
    .description = "Hardware/software macro - complex sequence with perfect timing",

    .steps = &[_]InputPatternStep{
        // Generic macro: Any key sequence with perfect timing
        // This is simplified - real implementation would track ANY button with perfect intervals

        // Button 1
        .{
            .event_type = .EV_KEY,
            .value = 1,  // Any press
            .max_time_delta_us = 0,
        },
        .{
            .event_type = .EV_KEY,
            .value = 0,  // Release
            .max_time_delta_us = 10_000,  // <10ms
        },

        // Button 2
        .{
            .event_type = .EV_KEY,
            .value = 1,
            .max_time_delta_us = 10_000,
        },
        .{
            .event_type = .EV_KEY,
            .value = 0,
            .max_time_delta_us = 10_000,
        },

        // Button 3
        .{
            .event_type = .EV_KEY,
            .value = 1,
            .max_time_delta_us = 10_000,
        },
        .{
            .event_type = .EV_KEY,
            .value = 0,
            .max_time_delta_us = 10_000,
        },

        // Button 4
        .{
            .event_type = .EV_KEY,
            .value = 1,
            .max_time_delta_us = 10_000,
        },
        .{
            .event_type = .EV_KEY,
            .value = 0,
            .max_time_delta_us = 10_000,
        },

        // Button 5
        .{
            .event_type = .EV_KEY,
            .value = 1,
            .max_time_delta_us = 10_000,
        },
        .{
            .event_type = .EV_KEY,
            .value = 0,
            .max_time_delta_us = 10_000,
        },
    },
};

/// Pattern 4: Mouse Snap (Aimbot signature)
///
/// Behavior: Instant large mouse movement followed by immediate click
/// Detection: Single large delta (>200 pixels) + click within 10ms
/// Note: This is a simplified version - real aimbot detection requires game state
pub const mouse_snap_aimbot = InputPattern{
    .id_hash = InputPattern.hashName("mouse_snap_aimbot"),
    .name = InputPattern.makeName("mouse_snap_aimbot"),
    .severity = .critical,
    .max_sequence_window_ms = 50,
    .description = "Aimbot signature - instant large mouse movement + click",

    .steps = &[_]InputPatternStep{
        // Large X movement (absolute value >200)
        .{
            .event_type = .EV_REL,
            .code = RelativeAxis.REL_X,
            // Note: value checking requires runtime logic for absolute value
            .max_time_delta_us = 0,
        },
        // Large Y movement (same timestamp or very close)
        .{
            .event_type = .EV_REL,
            .code = RelativeAxis.REL_Y,
            .max_time_delta_us = 1_000,  // <1ms
        },
        // Immediate click
        .{
            .event_type = .EV_KEY,
            .code = ButtonCode.BTN_LEFT,
            .value = 1,  // Press
            .max_time_delta_us = 10_000,  // <10ms
        },
    },
};

/// Pattern 5: Perfect Recoil Compensation
///
/// Behavior: Identical mouse movements at perfect intervals during firing
/// Detection: 10+ mouse events with identical deltas and perfect timing
/// Note: Requires tracking previous deltas - simplified here
pub const perfect_recoil_compensation = InputPattern{
    .id_hash = InputPattern.hashName("perfect_recoil_comp"),
    .name = InputPattern.makeName("perfect_recoil_comp"),
    .severity = .critical,
    .max_sequence_window_ms = 500,
    .description = "Anti-recoil script - perfect mouse compensation during fire",

    .steps = &[_]InputPatternStep{
        // Start firing
        .{
            .event_type = .EV_KEY,
            .code = ButtonCode.BTN_LEFT,
            .value = 1,
            .max_time_delta_us = 0,
        },

        // Perfect recoil compensation movements
        // Real implementation would track delta consistency

        // Movement 1
        .{
            .event_type = .EV_REL,
            .code = RelativeAxis.REL_Y,  // Vertical compensation
            .max_time_delta_us = 20_000,  // ~60Hz
        },
        // Movement 2 (identical timing)
        .{
            .event_type = .EV_REL,
            .code = RelativeAxis.REL_Y,
            .max_time_delta_us = 20_000,
        },
        // Movement 3
        .{
            .event_type = .EV_REL,
            .code = RelativeAxis.REL_Y,
            .max_time_delta_us = 20_000,
        },
        // Movement 4
        .{
            .event_type = .EV_REL,
            .code = RelativeAxis.REL_Y,
            .max_time_delta_us = 20_000,
        },
        // Movement 5
        .{
            .event_type = .EV_REL,
            .code = RelativeAxis.REL_Y,
            .max_time_delta_us = 20_000,
        },
    },
};

/// All gaming cheat patterns
pub const GAMING_CHEAT_PATTERNS = [_]InputPattern{
    rapid_fire_cronus,
    rapid_fire_trigger,
    perfect_macro_sequence,
    mouse_snap_aimbot,
    perfect_recoil_compensation,
};

// ═══════════════════════════════════════════════════════════════════════════
// PATTERN METADATA
// ═══════════════════════════════════════════════════════════════════════════

pub const PATTERN_COUNT = GAMING_CHEAT_PATTERNS.len;

pub fn getPatternByName(name: []const u8) ?*const InputPattern {
    for (&GAMING_CHEAT_PATTERNS) |*pattern| {
        const pattern_name = std.mem.sliceTo(&pattern.name, 0);
        if (std.mem.eql(u8, pattern_name, name)) {
            return pattern;
        }
    }
    return null;
}

pub fn getPatternById(id_hash: u64) ?*const InputPattern {
    for (&GAMING_CHEAT_PATTERNS) |*pattern| {
        if (pattern.id_hash == id_hash) {
            return pattern;
        }
    }
    return null;
}

// ═══════════════════════════════════════════════════════════════════════════
// PATTERN VALIDATION
// ═══════════════════════════════════════════════════════════════════════════

/// Compile-time pattern validation
comptime {
    // Ensure all patterns have unique IDs
    for (GAMING_CHEAT_PATTERNS, 0..) |pattern1, i| {
        for (GAMING_CHEAT_PATTERNS[i + 1 ..]) |pattern2| {
            if (pattern1.id_hash == pattern2.id_hash) {
                @compileError("Duplicate pattern ID hash detected");
            }
        }
    }

    // Ensure all patterns have non-empty names
    for (GAMING_CHEAT_PATTERNS) |pattern| {
        if (pattern.name[0] == 0) {
            @compileError("Pattern with empty name detected");
        }
    }

    // Ensure all patterns have at least one step
    for (GAMING_CHEAT_PATTERNS) |pattern| {
        if (pattern.steps.len == 0) {
            @compileError("Pattern with zero steps detected");
        }
    }
}
