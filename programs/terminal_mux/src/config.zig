//! Terminal Multiplexer Configuration
//!
//! Zig-native configuration - no parsing of external config files.
//! All configuration is compile-time constants that can be overridden
//! via environment variables or command-line flags at runtime.

const std = @import("std");

/// RGB color
pub const Color = struct {
    r: u8,
    g: u8,
    b: u8,

    pub fn fromRgb(r: u8, g: u8, b: u8) Color {
        return .{ .r = r, .g = g, .b = b };
    }

    pub fn from256(idx: u8) Color {
        // Standard 256-color palette
        if (idx < 16) {
            // System colors
            return system_colors[idx];
        } else if (idx < 232) {
            // 6x6x6 color cube
            const cube_idx = idx - 16;
            const r: u8 = @intCast((cube_idx / 36) % 6);
            const g: u8 = @intCast((cube_idx / 6) % 6);
            const b: u8 = @intCast(cube_idx % 6);
            return .{
                .r = if (r == 0) 0 else @as(u8, 55) + r * 40,
                .g = if (g == 0) 0 else @as(u8, 55) + g * 40,
                .b = if (b == 0) 0 else @as(u8, 55) + b * 40,
            };
        } else {
            // Grayscale
            const gray: u8 = @intCast((idx - 232) * 10 + 8);
            return .{ .r = gray, .g = gray, .b = gray };
        }
    }

    const system_colors = [16]Color{
        .{ .r = 0, .g = 0, .b = 0 }, // Black
        .{ .r = 205, .g = 0, .b = 0 }, // Red
        .{ .r = 0, .g = 205, .b = 0 }, // Green
        .{ .r = 205, .g = 205, .b = 0 }, // Yellow
        .{ .r = 0, .g = 0, .b = 238 }, // Blue
        .{ .r = 205, .g = 0, .b = 205 }, // Magenta
        .{ .r = 0, .g = 205, .b = 205 }, // Cyan
        .{ .r = 229, .g = 229, .b = 229 }, // White
        .{ .r = 127, .g = 127, .b = 127 }, // Bright Black
        .{ .r = 255, .g = 0, .b = 0 }, // Bright Red
        .{ .r = 0, .g = 255, .b = 0 }, // Bright Green
        .{ .r = 255, .g = 255, .b = 0 }, // Bright Yellow
        .{ .r = 92, .g = 92, .b = 255 }, // Bright Blue
        .{ .r = 255, .g = 0, .b = 255 }, // Bright Magenta
        .{ .r = 0, .g = 255, .b = 255 }, // Bright Cyan
        .{ .r = 255, .g = 255, .b = 255 }, // Bright White
    };
};

/// Key modifier flags
pub const Modifiers = packed struct {
    ctrl: bool = false,
    alt: bool = false,
    shift: bool = false,
    _pad: u5 = 0,
};

/// Key representation
pub const Key = struct {
    char: u8 = 0,
    special: SpecialKey = .none,
    mods: Modifiers = .{},

    pub const SpecialKey = enum(u8) {
        none = 0,
        up,
        down,
        left,
        right,
        home,
        end,
        page_up,
        page_down,
        insert,
        delete,
        f1,
        f2,
        f3,
        f4,
        f5,
        f6,
        f7,
        f8,
        f9,
        f10,
        f11,
        f12,
        escape,
        backspace,
        tab,
        enter,
    };

    pub fn ctrl(char: u8) Key {
        return .{ .char = char, .mods = .{ .ctrl = true } };
    }

    pub fn plain(char: u8) Key {
        return .{ .char = char };
    }

    pub fn specialKey(k: SpecialKey) Key {
        return .{ .special = k };
    }
};

/// Actions that can be bound to keys
pub const Action = enum {
    // Session management
    new_session,
    rename_session,
    kill_session,
    detach,
    list_sessions,

    // Window management
    new_window,
    rename_window,
    kill_window,
    next_window,
    prev_window,
    select_window_0,
    select_window_1,
    select_window_2,
    select_window_3,
    select_window_4,
    select_window_5,
    select_window_6,
    select_window_7,
    select_window_8,
    select_window_9,
    last_window,

    // Pane management
    split_horizontal,
    split_vertical,
    kill_pane,
    select_pane_up,
    select_pane_down,
    select_pane_left,
    select_pane_right,
    resize_pane_up,
    resize_pane_down,
    resize_pane_left,
    resize_pane_right,
    zoom_pane,
    next_pane,
    prev_pane,

    // Copy mode
    enter_copy_mode,
    paste_buffer,

    // Misc
    reload_config,
    show_clock,
    command_prompt,
};

/// Key binding
pub const Binding = struct {
    key: Key,
    action: Action,
};

/// Main configuration structure
pub const Config = struct {
    /// Prefix key (default: Ctrl-b like tmux)
    prefix_key: Key = Key.ctrl('b'),

    /// Shell to spawn in new panes
    shell: []const u8 = "/bin/bash",

    /// TERM environment variable value
    default_term: []const u8 = "xterm-256color",

    /// Number of scrollback lines per pane
    scrollback_lines: u32 = 10000,

    /// Status bar configuration
    status_bar: StatusBarConfig = .{},

    /// Key bindings (after prefix)
    bindings: []const Binding = &default_bindings,

    /// Mouse support
    mouse_enabled: bool = true,

    /// Base index for windows (0 or 1)
    base_index: u8 = 0,

    /// Escape time in milliseconds
    escape_time_ms: u16 = 500,

    /// Activity monitoring
    monitor_activity: bool = false,
    monitor_bell: bool = true,

    /// Aggressive resize (resize to smallest attached client)
    aggressive_resize: bool = false,

    /// Focus events (pass through focus in/out)
    focus_events: bool = true,
};

pub const StatusBarConfig = struct {
    enabled: bool = true,
    position: Position = .bottom,
    bg: Color = Color.fromRgb(0, 128, 0),
    fg: Color = Color.fromRgb(255, 255, 255),

    left_format: []const u8 = "[#S] ",
    right_format: []const u8 = " %H:%M %d-%b-%y",

    window_format: []const u8 = "#I:#W#F",
    window_current_format: []const u8 = "#I:#W#F",
    window_current_bg: Color = Color.fromRgb(255, 255, 0),
    window_current_fg: Color = Color.fromRgb(0, 0, 0),

    pub const Position = enum { top, bottom };
};

/// Default key bindings (modeled after tmux defaults)
pub const default_bindings = [_]Binding{
    // Session
    .{ .key = Key.plain('d'), .action = .detach },
    .{ .key = Key.plain('s'), .action = .list_sessions },
    .{ .key = Key.plain('$'), .action = .rename_session },

    // Window
    .{ .key = Key.plain('c'), .action = .new_window },
    .{ .key = Key.plain(','), .action = .rename_window },
    .{ .key = Key.plain('&'), .action = .kill_window },
    .{ .key = Key.plain('n'), .action = .next_window },
    .{ .key = Key.plain('p'), .action = .prev_window },
    .{ .key = Key.plain('l'), .action = .last_window },
    .{ .key = Key.plain('0'), .action = .select_window_0 },
    .{ .key = Key.plain('1'), .action = .select_window_1 },
    .{ .key = Key.plain('2'), .action = .select_window_2 },
    .{ .key = Key.plain('3'), .action = .select_window_3 },
    .{ .key = Key.plain('4'), .action = .select_window_4 },
    .{ .key = Key.plain('5'), .action = .select_window_5 },
    .{ .key = Key.plain('6'), .action = .select_window_6 },
    .{ .key = Key.plain('7'), .action = .select_window_7 },
    .{ .key = Key.plain('8'), .action = .select_window_8 },
    .{ .key = Key.plain('9'), .action = .select_window_9 },

    // Pane - splitting
    .{ .key = Key.plain('%'), .action = .split_horizontal },
    .{ .key = Key.plain('"'), .action = .split_vertical },
    .{ .key = Key.plain('x'), .action = .kill_pane },

    // Pane - navigation
    .{ .key = Key.specialKey(.up), .action = .select_pane_up },
    .{ .key = Key.specialKey(.down), .action = .select_pane_down },
    .{ .key = Key.specialKey(.left), .action = .select_pane_left },
    .{ .key = Key.specialKey(.right), .action = .select_pane_right },
    .{ .key = Key.plain('o'), .action = .next_pane },
    .{ .key = Key.plain(';'), .action = .prev_pane },

    // Pane - resize (Ctrl+arrow)
    .{ .key = .{ .special = .up, .mods = .{ .ctrl = true } }, .action = .resize_pane_up },
    .{ .key = .{ .special = .down, .mods = .{ .ctrl = true } }, .action = .resize_pane_down },
    .{ .key = .{ .special = .left, .mods = .{ .ctrl = true } }, .action = .resize_pane_left },
    .{ .key = .{ .special = .right, .mods = .{ .ctrl = true } }, .action = .resize_pane_right },

    // Pane - zoom
    .{ .key = Key.plain('z'), .action = .zoom_pane },

    // Copy mode
    .{ .key = Key.plain('['), .action = .enter_copy_mode },
    .{ .key = Key.plain(']'), .action = .paste_buffer },

    // Misc
    .{ .key = Key.plain('t'), .action = .show_clock },
    .{ .key = Key.plain(':'), .action = .command_prompt },
    .{ .key = Key.plain('r'), .action = .reload_config },
};

/// Runtime configuration (can be modified after startup)
pub const RuntimeConfig = struct {
    allocator: std.mem.Allocator,
    static: Config,

    // Dynamic overrides
    shell_override: ?[]const u8,
    scrollback_override: ?u32,

    pub fn init(allocator: std.mem.Allocator) RuntimeConfig {
        return .{
            .allocator = allocator,
            .static = .{},
            .shell_override = null,
            .scrollback_override = null,
        };
    }

    pub fn deinit(self: *RuntimeConfig) void {
        if (self.shell_override) |s| {
            self.allocator.free(s);
        }
    }

    pub fn getShell(self: *const RuntimeConfig) []const u8 {
        return self.shell_override orelse self.static.shell;
    }

    pub fn getScrollbackLines(self: *const RuntimeConfig) u32 {
        return self.scrollback_override orelse self.static.scrollback_lines;
    }

    /// Load overrides from environment variables
    pub fn loadFromEnv(self: *RuntimeConfig) void {
        if (std.posix.getenv("TMUX_SHELL")) |shell| {
            self.shell_override = self.allocator.dupe(u8, shell) catch null;
        }

        if (std.posix.getenv("TMUX_SCROLLBACK")) |val| {
            self.scrollback_override = std.fmt.parseInt(u32, val, 10) catch null;
        }
    }
};

// =============================================================================
// Tests
// =============================================================================

test "color from 256" {
    // Test system color
    const black = Color.from256(0);
    try std.testing.expectEqual(@as(u8, 0), black.r);

    // Test cube color
    const red = Color.from256(196); // Pure red in cube
    try std.testing.expect(red.r > red.g);
    try std.testing.expect(red.r > red.b);

    // Test grayscale
    const gray = Color.from256(244);
    try std.testing.expectEqual(gray.r, gray.g);
    try std.testing.expectEqual(gray.g, gray.b);
}

test "key creation" {
    const ctrl_b = Key.ctrl('b');
    try std.testing.expect(ctrl_b.mods.ctrl);
    try std.testing.expectEqual(@as(u8, 'b'), ctrl_b.char);

    const up = Key.specialKey(.up);
    try std.testing.expectEqual(Key.SpecialKey.up, up.special);
}
