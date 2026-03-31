//! Keybindings system - customizable keyboard shortcuts
//!
//! Provides a flexible way to define and manage keyboard shortcuts.

const std = @import("std");
const input_mod = @import("input.zig");

pub const SpecialKey = input_mod.Key;
pub const Modifiers = input_mod.Modifiers;
pub const KeyEvent = input_mod.KeyEvent;

/// Key type (matches KeyEvent.key)
pub const Key = union(enum) {
    char: u21,
    special: SpecialKey,
};

/// Action identifier
pub const Action = []const u8;

/// Key binding definition
pub const KeyBinding = struct {
    key: Key,
    modifiers: Modifiers,
    action: Action,
    description: []const u8,
    enabled: bool,
};

/// Keybinding mode (like vim modes)
pub const Mode = enum {
    normal,
    insert,
    command,
    visual,
};

/// Keybindings manager
pub const Keybindings = struct {
    bindings: std.ArrayListUnmanaged(KeyBinding),
    allocator: std.mem.Allocator,
    current_mode: Mode,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .bindings = .{},
            .allocator = allocator,
            .current_mode = .normal,
        };
    }

    pub fn deinit(self: *Self) void {
        self.bindings.deinit(self.allocator);
    }

    /// Add a keybinding
    pub fn bind(
        self: *Self,
        key: Key,
        modifiers: Modifiers,
        action: Action,
        description: []const u8,
    ) !void {
        try self.bindings.append(self.allocator, .{
            .key = key,
            .modifiers = modifiers,
            .action = action,
            .description = description,
            .enabled = true,
        });
    }

    /// Bind a character key
    pub fn bindChar(self: *Self, char: u21, modifiers: Modifiers, action: Action, description: []const u8) !void {
        try self.bind(.{ .char = char }, modifiers, action, description);
    }

    /// Bind a special key
    pub fn bindSpecial(self: *Self, special: SpecialKey, modifiers: Modifiers, action: Action, description: []const u8) !void {
        try self.bind(.{ .special = special }, modifiers, action, description);
    }

    /// Find action for a key event
    pub fn getAction(self: *const Self, event: KeyEvent) ?Action {
        for (self.bindings.items) |binding| {
            if (!binding.enabled) continue;
            if (self.keyMatches(binding.key, event.key) and self.modifiersMatch(binding.modifiers, event.modifiers)) {
                return binding.action;
            }
        }
        return null;
    }

    fn keyMatches(_: *const Self, binding_key: Key, event_key: anytype) bool {
        return switch (binding_key) {
            .char => |bc| switch (event_key) {
                .char => |ec| bc == ec,
                .special => false,
            },
            .special => |bs| switch (event_key) {
                .char => false,
                .special => |es| bs == es,
            },
        };
    }

    fn modifiersMatch(_: *const Self, binding_mods: Modifiers, event_mods: Modifiers) bool {
        return binding_mods.ctrl == event_mods.ctrl and
            binding_mods.alt == event_mods.alt and
            binding_mods.shift == event_mods.shift;
    }

    /// Remove a keybinding by action
    pub fn unbind(self: *Self, action: Action) void {
        var i: usize = 0;
        while (i < self.bindings.items.len) {
            if (std.mem.eql(u8, self.bindings.items[i].action, action)) {
                _ = self.bindings.orderedRemove(i);
            } else {
                i += 1;
            }
        }
    }

    /// Enable/disable a binding
    pub fn setEnabled(self: *Self, action: Action, enabled: bool) void {
        for (self.bindings.items) |*binding| {
            if (std.mem.eql(u8, binding.action, action)) {
                binding.enabled = enabled;
            }
        }
    }

    /// Set current mode
    pub fn setMode(self: *Self, mode: Mode) void {
        self.current_mode = mode;
    }

    /// Get all bindings (for help display)
    pub fn getAllBindings(self: *const Self) []const KeyBinding {
        return self.bindings.items;
    }

    /// Load default keybindings
    pub fn loadDefaults(self: *Self) !void {
        // Navigation
        try self.bindSpecial(.up, .{}, "navigate.up", "Move up");
        try self.bindSpecial(.down, .{}, "navigate.down", "Move down");
        try self.bindSpecial(.left, .{}, "navigate.left", "Move left");
        try self.bindSpecial(.right, .{}, "navigate.right", "Move right");
        try self.bindSpecial(.home, .{}, "navigate.home", "Go to start");
        try self.bindSpecial(.end, .{}, "navigate.end", "Go to end");
        try self.bindSpecial(.page_up, .{}, "navigate.page_up", "Page up");
        try self.bindSpecial(.page_down, .{}, "navigate.page_down", "Page down");

        // Actions
        try self.bindSpecial(.enter, .{}, "action.confirm", "Confirm/Select");
        try self.bindSpecial(.escape, .{}, "action.cancel", "Cancel/Back");
        try self.bindSpecial(.tab, .{}, "action.next_focus", "Next focus");
        try self.bindSpecial(.backtab, .{}, "action.prev_focus", "Previous focus");

        // Edit
        try self.bindSpecial(.backspace, .{}, "edit.delete_back", "Delete backward");
        try self.bindSpecial(.delete, .{}, "edit.delete", "Delete forward");

        // Control shortcuts
        try self.bindChar('c', .{ .ctrl = true }, "action.quit", "Quit");
        try self.bindChar('q', .{}, "action.quit", "Quit");
        try self.bindChar('s', .{ .ctrl = true }, "file.save", "Save");
        try self.bindChar('o', .{ .ctrl = true }, "file.open", "Open");
        try self.bindChar('n', .{ .ctrl = true }, "file.new", "New");

        // Help
        try self.bindChar('?', .{}, "help.show", "Show help");
        try self.bindSpecial(.f1, .{}, "help.show", "Show help");
    }
};

/// Format key binding for display
pub fn formatKeyBinding(key: Key, modifiers: Modifiers, buf: []u8) []const u8 {
    var pos: usize = 0;

    if (modifiers.ctrl) {
        const ctrl_str = "Ctrl+";
        @memcpy(buf[pos..][0..ctrl_str.len], ctrl_str);
        pos += ctrl_str.len;
    }
    if (modifiers.alt) {
        const alt_str = "Alt+";
        @memcpy(buf[pos..][0..alt_str.len], alt_str);
        pos += alt_str.len;
    }
    if (modifiers.shift) {
        const shift_str = "Shift+";
        @memcpy(buf[pos..][0..shift_str.len], shift_str);
        pos += shift_str.len;
    }

    switch (key) {
        .char => |c| {
            if (c < 128) {
                buf[pos] = @intCast(c);
                pos += 1;
            }
        },
        .special => |s| {
            const name: []const u8 = switch (s) {
                .null => "Null",
                .up => "Up",
                .down => "Down",
                .left => "Left",
                .right => "Right",
                .home => "Home",
                .end => "End",
                .page_up => "PgUp",
                .page_down => "PgDn",
                .insert => "Ins",
                .delete => "Del",
                .backspace => "Bksp",
                .enter => "Enter",
                .tab => "Tab",
                .backtab => "S-Tab",
                .escape => "Esc",
                .f1 => "F1",
                .f2 => "F2",
                .f3 => "F3",
                .f4 => "F4",
                .f5 => "F5",
                .f6 => "F6",
                .f7 => "F7",
                .f8 => "F8",
                .f9 => "F9",
                .f10 => "F10",
                .f11 => "F11",
                .f12 => "F12",
            };
            @memcpy(buf[pos..][0..name.len], name);
            pos += name.len;
        },
    }

    return buf[0..pos];
}

test "Keybindings basic" {
    var kb = Keybindings.init(std.testing.allocator);
    defer kb.deinit();

    try kb.bindChar('q', .{}, "quit", "Quit application");

    const event = KeyEvent{ .key = .{ .char = 'q' }, .modifiers = .{} };
    const action = kb.getAction(event);
    try std.testing.expect(action != null);
    try std.testing.expectEqualStrings("quit", action.?);
}
