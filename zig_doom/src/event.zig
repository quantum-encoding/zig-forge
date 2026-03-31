//! zig_doom/src/event.zig
//!
//! Input event types shared by menu, game, automap responders.
//! Translated from: linuxdoom-1.10/d_event.h, doomkeys.h
//! Original: Copyright (C) 1993-1996 id Software, Inc. GPL-2.0

const std = @import("std");

pub const Event = struct {
    event_type: EventType,
    data1: i32, // Key code / button
    data2: i32, // Mouse x / joystick x
    data3: i32, // Mouse y / joystick y
};

pub const EventType = enum {
    key_down,
    key_up,
    mouse,
    joystick,
};

// DOOM key codes (mapped to platform-specific keys in Phase 6)
pub const KEY_RIGHTARROW = 0xae;
pub const KEY_LEFTARROW = 0xac;
pub const KEY_UPARROW = 0xad;
pub const KEY_DOWNARROW = 0xaf;
pub const KEY_ESCAPE = 27;
pub const KEY_ENTER = 13;
pub const KEY_TAB = 9;
pub const KEY_F1 = 0x80 + 0x3b;
pub const KEY_F2 = 0x80 + 0x3c;
pub const KEY_F3 = 0x80 + 0x3d;
pub const KEY_F4 = 0x80 + 0x3e;
pub const KEY_F5 = 0x80 + 0x3f;
pub const KEY_F6 = 0x80 + 0x40;
pub const KEY_F7 = 0x80 + 0x41;
pub const KEY_F8 = 0x80 + 0x42;
pub const KEY_F9 = 0x80 + 0x43;
pub const KEY_F10 = 0x80 + 0x44;
pub const KEY_F11 = 0x80 + 0x45;
pub const KEY_F12 = 0x80 + 0x46;
pub const KEY_BACKSPACE = 127;
pub const KEY_PAUSE = 0xff;
pub const KEY_RSHIFT = 0x80 + 0x36;
pub const KEY_RCTRL = 0x80 + 0x1d;
pub const KEY_RALT = 0x80 + 0x38;
pub const KEY_FIRE = KEY_RCTRL;
pub const KEY_USE = ' ';
pub const KEY_STRAFE = KEY_RALT;
pub const KEY_SPEED = KEY_RSHIFT;

test "key constants" {
    try std.testing.expect(KEY_ESCAPE == 27);
    try std.testing.expect(KEY_ENTER == 13);
    try std.testing.expect(KEY_F1 > 0x80);
    try std.testing.expect(KEY_USE == ' ');
}

test "event struct" {
    const ev = Event{
        .event_type = .key_down,
        .data1 = KEY_ENTER,
        .data2 = 0,
        .data3 = 0,
    };
    try std.testing.expectEqual(EventType.key_down, ev.event_type);
    try std.testing.expectEqual(@as(i32, KEY_ENTER), ev.data1);
}
