//! ANSI escape sequence parser for terminal input
//!
//! Parses keyboard, mouse, and other terminal events from raw byte input.

const std = @import("std");
const event = @import("event.zig");

pub const Event = event.Event;
pub const KeyEvent = event.KeyEvent;
pub const MouseEvent = event.MouseEvent;
pub const Key = event.Key;
pub const Modifiers = event.Modifiers;
pub const MouseButton = event.MouseButton;
pub const MouseEventKind = event.MouseEventKind;

/// Input parser state machine
pub const Parser = struct {
    state: State = .ground,
    params: [16]u16 = [_]u16{0} ** 16,
    param_count: u8 = 0,
    intermediate: u8 = 0,

    const Self = @This();

    const State = enum {
        ground,
        escape,
        csi_entry,
        csi_param,
        csi_intermediate,
        ss3,
        utf8_2,
        utf8_3,
        utf8_4,
    };

    /// Parse a single byte, potentially returning an event
    pub fn feed(self: *Self, byte: u8) ?Event {
        return switch (self.state) {
            .ground => self.handleGround(byte),
            .escape => self.handleEscape(byte),
            .csi_entry => self.handleCsiEntry(byte),
            .csi_param => self.handleCsiParam(byte),
            .csi_intermediate => self.handleCsiIntermediate(byte),
            .ss3 => self.handleSs3(byte),
            .utf8_2 => self.handleUtf8Continuation(byte, 2),
            .utf8_3 => self.handleUtf8Continuation(byte, 3),
            .utf8_4 => self.handleUtf8Continuation(byte, 4),
        };
    }

    /// Reset parser state
    pub fn reset(self: *Self) void {
        self.state = .ground;
        self.param_count = 0;
        self.intermediate = 0;
        @memset(&self.params, 0);
    }

    fn handleGround(self: *Self, byte: u8) ?Event {
        // ESC
        if (byte == 0x1B) {
            self.state = .escape;
            return null;
        }

        // Control characters
        if (byte < 0x20) {
            return self.handleControlChar(byte);
        }

        // DEL (backspace on many terminals)
        if (byte == 0x7F) {
            return Event{ .key = KeyEvent.special(.backspace) };
        }

        // ASCII printable
        if (byte < 0x80) {
            return Event{ .key = KeyEvent.char(byte) };
        }

        // UTF-8 multi-byte start
        if (byte >= 0xC0 and byte < 0xE0) {
            self.params[0] = byte & 0x1F;
            self.state = .utf8_2;
            return null;
        } else if (byte >= 0xE0 and byte < 0xF0) {
            self.params[0] = byte & 0x0F;
            self.state = .utf8_3;
            return null;
        } else if (byte >= 0xF0 and byte < 0xF8) {
            self.params[0] = byte & 0x07;
            self.state = .utf8_4;
            return null;
        }

        // Invalid byte, ignore
        return null;
    }

    fn handleControlChar(self: *Self, byte: u8) ?Event {
        _ = self;
        return switch (byte) {
            0x00 => Event{ .key = KeyEvent.special(.null) },
            0x09 => Event{ .key = KeyEvent.special(.tab) },
            0x0A, 0x0D => Event{ .key = KeyEvent.special(.enter) },
            // Ctrl+letter (0x01-0x08, 0x0B-0x0C, 0x0E-0x1A maps to Ctrl+A through Ctrl+Z)
            // Skip 0x09 (tab), 0x0A (newline), 0x0D (return)
            0x01...0x08 => |c| Event{
                .key = .{
                    .key = .{ .char = 'a' + c - 1 },
                    .modifiers = .{ .ctrl = true },
                },
            },
            0x0B, 0x0C, 0x0E...0x1A => |c| Event{
                .key = .{
                    .key = .{ .char = 'a' + c - 1 },
                    .modifiers = .{ .ctrl = true },
                },
            },
            else => null,
        };
    }

    fn handleEscape(self: *Self, byte: u8) ?Event {
        switch (byte) {
            '[' => {
                self.state = .csi_entry;
                self.param_count = 0;
                self.intermediate = 0; // Reset intermediate for new CSI sequence
                @memset(&self.params, 0);
                return null;
            },
            'O' => {
                self.state = .ss3;
                return null;
            },
            0x1B => {
                // Double ESC - return single ESC and stay in escape state
                return Event{ .key = KeyEvent.special(.escape) };
            },
            else => {
                // Alt+key
                self.state = .ground;
                if (byte >= 0x20 and byte < 0x7F) {
                    return Event{
                        .key = .{
                            .key = .{ .char = byte },
                            .modifiers = .{ .alt = true },
                        },
                    };
                }
                // Bare escape
                return Event{ .key = KeyEvent.special(.escape) };
            },
        }
    }

    fn handleCsiEntry(self: *Self, byte: u8) ?Event {
        // Check for parameter or intermediate
        if (byte >= '0' and byte <= '9') {
            self.params[0] = byte - '0';
            self.param_count = 1;
            self.state = .csi_param;
            return null;
        } else if (byte == ';') {
            self.param_count = 1;
            self.state = .csi_param;
            return null;
        } else if (byte == '<' or byte == '>' or byte == '?' or byte == '=') {
            self.intermediate = byte;
            self.state = .csi_param;
            return null;
        }

        // Final byte
        return self.handleCsiFinal(byte);
    }

    fn handleCsiParam(self: *Self, byte: u8) ?Event {
        if (byte >= '0' and byte <= '9') {
            if (self.param_count == 0) self.param_count = 1;
            const idx = self.param_count - 1;
            if (idx < self.params.len) {
                self.params[idx] = self.params[idx] * 10 + (byte - '0');
            }
            return null;
        } else if (byte == ';') {
            if (self.param_count < self.params.len) {
                self.param_count += 1;
            }
            return null;
        } else if (byte == ':') {
            // Subparameter separator - skip for now
            return null;
        }

        // Final byte or intermediate
        if (byte >= 0x20 and byte < 0x30) {
            self.state = .csi_intermediate;
            return null;
        }

        return self.handleCsiFinal(byte);
    }

    fn handleCsiIntermediate(self: *Self, byte: u8) ?Event {
        if (byte >= 0x20 and byte < 0x30) {
            return null;
        }
        return self.handleCsiFinal(byte);
    }

    fn handleCsiFinal(self: *Self, byte: u8) ?Event {
        self.state = .ground;

        // SGR mouse mode
        if (self.intermediate == '<') {
            return self.parseSgrMouse(byte);
        }

        // Standard CSI sequences
        return switch (byte) {
            'A' => Event{ .key = KeyEvent.special(.up) },
            'B' => Event{ .key = KeyEvent.special(.down) },
            'C' => Event{ .key = KeyEvent.special(.right) },
            'D' => Event{ .key = KeyEvent.special(.left) },
            'H' => Event{ .key = KeyEvent.special(.home) },
            'F' => Event{ .key = KeyEvent.special(.end) },
            'Z' => Event{ .key = KeyEvent.special(.backtab) },
            '~' => self.parseTildeKey(),
            'I' => Event{ .focus = .gained },
            'O' => Event{ .focus = .lost },
            else => null,
        };
    }

    fn parseTildeKey(self: *Self) ?Event {
        const param = if (self.param_count > 0) self.params[0] else 0;
        const modifiers = self.parseModifiers();

        const key: Key = switch (param) {
            1 => .home,
            2 => .insert,
            3 => .delete,
            4 => .end,
            5 => .page_up,
            6 => .page_down,
            11 => .f1,
            12 => .f2,
            13 => .f3,
            14 => .f4,
            15 => .f5,
            17 => .f6,
            18 => .f7,
            19 => .f8,
            20 => .f9,
            21 => .f10,
            23 => .f11,
            24 => .f12,
            else => return null,
        };

        return Event{
            .key = .{
                .key = .{ .special = key },
                .modifiers = modifiers,
            },
        };
    }

    fn parseSgrMouse(self: *Self, final: u8) ?Event {
        if (self.param_count < 3) return null;

        const button_code = self.params[0];
        const x = if (self.params[1] > 0) self.params[1] - 1 else 0;
        const y = if (self.params[2] > 0) self.params[2] - 1 else 0;

        const button: MouseButton = switch (button_code & 0x03) {
            0 => .left,
            1 => .middle,
            2 => .right,
            3 => .release,
            else => unreachable,
        };

        const is_scroll = (button_code & 64) != 0;
        const is_drag = (button_code & 32) != 0;

        const kind: MouseEventKind = if (is_scroll)
            (if (button_code & 1 == 0) .scroll_up else .scroll_down)
        else if (is_drag)
            .drag
        else if (final == 'M')
            .press
        else
            .release;

        return Event{
            .mouse = .{
                .x = x,
                .y = y,
                .button = button,
                .kind = kind,
                .modifiers = .{
                    .shift = (button_code & 4) != 0,
                    .alt = (button_code & 8) != 0,
                    .ctrl = (button_code & 16) != 0,
                },
            },
        };
    }

    fn parseModifiers(self: *Self) Modifiers {
        if (self.param_count < 2) return .{};
        const m = self.params[1];
        if (m == 0) return .{};
        // Modifier encoding: 1 + (shift) + (alt*2) + (ctrl*4) + (meta*8)
        const mod = m - 1;
        return .{
            .shift = (mod & 1) != 0,
            .alt = (mod & 2) != 0,
            .ctrl = (mod & 4) != 0,
            .super = (mod & 8) != 0,
        };
    }

    fn handleSs3(self: *Self, byte: u8) ?Event {
        self.state = .ground;
        return switch (byte) {
            'A' => Event{ .key = KeyEvent.special(.up) },
            'B' => Event{ .key = KeyEvent.special(.down) },
            'C' => Event{ .key = KeyEvent.special(.right) },
            'D' => Event{ .key = KeyEvent.special(.left) },
            'H' => Event{ .key = KeyEvent.special(.home) },
            'F' => Event{ .key = KeyEvent.special(.end) },
            'P' => Event{ .key = KeyEvent.special(.f1) },
            'Q' => Event{ .key = KeyEvent.special(.f2) },
            'R' => Event{ .key = KeyEvent.special(.f3) },
            'S' => Event{ .key = KeyEvent.special(.f4) },
            else => null,
        };
    }

    fn handleUtf8Continuation(self: *Self, byte: u8, expected_bytes: u8) ?Event {
        // Check for valid continuation byte
        if ((byte & 0xC0) != 0x80) {
            self.state = .ground;
            return null; // Invalid UTF-8
        }

        self.params[0] = (self.params[0] << 6) | (byte & 0x3F);

        if (expected_bytes == 2) {
            self.state = .ground;
            return Event{ .key = KeyEvent.char(@intCast(self.params[0])) };
        } else if (expected_bytes == 3) {
            self.state = .utf8_3;
            return null;
        } else {
            self.state = .utf8_4;
            return null;
        }
    }
};

test "Parser basic keys" {
    var p = Parser{};

    // Simple character
    const a = p.feed('a');
    try std.testing.expect(a != null);
    try std.testing.expectEqual(@as(u21, 'a'), a.?.key.key.char);

    // Enter
    const enter = p.feed(0x0D);
    try std.testing.expect(enter != null);
    try std.testing.expect(enter.?.key.key == .special);
}

test "Parser escape sequences" {
    var p = Parser{};

    // Up arrow: ESC [ A
    _ = p.feed(0x1B);
    _ = p.feed('[');
    const up = p.feed('A');
    try std.testing.expect(up != null);
    try std.testing.expect(up.?.key.key.special == .up);
}

test "Parser Ctrl+C" {
    var p = Parser{};
    const event_opt = p.feed(0x03); // Ctrl+C
    try std.testing.expect(event_opt != null);
    const e = event_opt.?;
    try std.testing.expect(e.isCtrlC());
}
