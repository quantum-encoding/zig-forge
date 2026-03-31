//! Input events for the TUI framework
//!
//! Unified event system for keyboard, mouse, resize, and other terminal events.

const std = @import("std");

/// Keyboard modifier flags
pub const Modifiers = packed struct {
    shift: bool = false,
    alt: bool = false,
    ctrl: bool = false,
    super: bool = false,

    pub const none = Modifiers{};

    pub fn eql(self: Modifiers, other: Modifiers) bool {
        return @as(u4, @bitCast(self)) == @as(u4, @bitCast(other));
    }
};

/// Special key codes
pub const Key = enum(u16) {
    // ASCII control codes
    null = 0,
    tab = 9,
    enter = 13,
    escape = 27,
    backspace = 127,

    // Navigation keys
    up = 0x1001,
    down = 0x1002,
    left = 0x1003,
    right = 0x1004,
    home = 0x1005,
    end = 0x1006,
    page_up = 0x1007,
    page_down = 0x1008,
    insert = 0x1009,
    delete = 0x100A,

    // Function keys
    f1 = 0x1101,
    f2 = 0x1102,
    f3 = 0x1103,
    f4 = 0x1104,
    f5 = 0x1105,
    f6 = 0x1106,
    f7 = 0x1107,
    f8 = 0x1108,
    f9 = 0x1109,
    f10 = 0x110A,
    f11 = 0x110B,
    f12 = 0x110C,

    // Other
    backtab = 0x1201, // Shift+Tab
};

/// Mouse button
pub const MouseButton = enum(u3) {
    left = 0,
    middle = 1,
    right = 2,
    release = 3,
    scroll_up = 4,
    scroll_down = 5,
    scroll_left = 6,
    scroll_right = 7,
};

/// Mouse event kind
pub const MouseEventKind = enum {
    press,
    release,
    drag,
    move,
    scroll_up,
    scroll_down,
};

/// Mouse event data
pub const MouseEvent = struct {
    x: u16,
    y: u16,
    button: MouseButton,
    kind: MouseEventKind,
    modifiers: Modifiers,
};

/// Keyboard event data
pub const KeyEvent = struct {
    /// Key code or Unicode codepoint for character keys
    key: union(enum) {
        char: u21,
        special: Key,
    },
    modifiers: Modifiers,

    /// Create event for printable character
    pub fn char(c: u21) KeyEvent {
        return .{ .key = .{ .char = c }, .modifiers = .{} };
    }

    /// Create event for special key
    pub fn special(k: Key) KeyEvent {
        return .{ .key = .{ .special = k }, .modifiers = .{} };
    }

    /// Create event with modifiers
    pub fn withMods(k: anytype, mods: Modifiers) KeyEvent {
        const T = @TypeOf(k);
        if (T == u21 or T == comptime_int) {
            return .{ .key = .{ .char = k }, .modifiers = mods };
        } else {
            return .{ .key = .{ .special = k }, .modifiers = mods };
        }
    }

    /// Check if this is a character event
    pub fn isChar(self: KeyEvent) bool {
        return self.key == .char;
    }

    /// Get character if this is a character event
    pub fn getChar(self: KeyEvent) ?u21 {
        return switch (self.key) {
            .char => |c| c,
            .special => null,
        };
    }

    /// Check if Ctrl is pressed
    pub fn isCtrl(self: KeyEvent) bool {
        return self.modifiers.ctrl;
    }

    /// Check for Ctrl+C
    pub fn isCtrlC(self: KeyEvent) bool {
        return self.modifiers.ctrl and
            self.key == .char and self.key.char == 'c';
    }
};

/// Terminal resize event
pub const ResizeEvent = struct {
    width: u16,
    height: u16,
};

/// Focus event
pub const FocusEvent = enum {
    gained,
    lost,
};

/// Unified event type
pub const Event = union(enum) {
    key: KeyEvent,
    mouse: MouseEvent,
    resize: ResizeEvent,
    focus: FocusEvent,
    paste: []const u8,
    tick, // Timer tick for animations

    /// Helper to check for specific key
    pub fn isKey(self: Event, key: Key) bool {
        return switch (self) {
            .key => |k| switch (k.key) {
                .special => |s| s == key,
                .char => false,
            },
            else => false,
        };
    }

    /// Helper to check for specific character
    pub fn isChar(self: Event, c: u21) bool {
        return switch (self) {
            .key => |k| switch (k.key) {
                .char => |ch| ch == c,
                .special => false,
            },
            else => false,
        };
    }

    /// Check if this is Ctrl+C
    pub fn isCtrlC(self: Event) bool {
        return switch (self) {
            .key => |k| k.isCtrlC(),
            else => false,
        };
    }

    /// Check if this is Escape
    pub fn isEscape(self: Event) bool {
        return self.isKey(.escape);
    }

    /// Check if this is Enter
    pub fn isEnter(self: Event) bool {
        return self.isKey(.enter);
    }

    /// Check if this is Tab
    pub fn isTab(self: Event) bool {
        return self.isKey(.tab);
    }

    /// Check if this is Shift+Tab (backtab)
    pub fn isBacktab(self: Event) bool {
        return self.isKey(.backtab);
    }
};

test "KeyEvent" {
    const e = KeyEvent.char('a');
    try std.testing.expect(e.isChar());
    try std.testing.expectEqual(@as(?u21, 'a'), e.getChar());
}

test "Event helpers" {
    const esc = Event{ .key = KeyEvent.special(.escape) };
    try std.testing.expect(esc.isEscape());
    try std.testing.expect(!esc.isEnter());

    const enter = Event{ .key = KeyEvent.special(.enter) };
    try std.testing.expect(enter.isEnter());
}
