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

    pub const system_colors = [16]Color{
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
// Theme — palette + default colors, the SINGLE source of truth shared by every
// renderer (standalone TUI + the C-ABI consumers like CosmicDuck's Metal view).
// Loaded from a simple line-based `key = value` file: a named `preset` as the
// base, with per-key overrides on top. Parsing is string-based (file reading is
// the caller's job) so it's unit-testable and free of std.fs/json quirks.
// =============================================================================

pub const CursorStyle = enum(u8) { block = 0, bar = 1, underline = 2 };

pub const Theme = struct {
    bg: Color = Color.fromRgb(0x12, 0x12, 0x17),
    fg: Color = Color.fromRgb(0xD9, 0xDB, 0xE0),
    cursor: Color = Color.fromRgb(0xF5, 0xE0, 0xDC),
    cursor_text: Color = Color.fromRgb(0x12, 0x12, 0x17),
    selection_bg: Color = Color.fromRgb(0x45, 0x47, 0x5A),
    selection_fg: Color = Color.fromRgb(0xD9, 0xDB, 0xE0),
    url: Color = Color.fromRgb(0x89, 0xB4, 0xFA), // detected-URL highlight
    palette: [16]Color = Color.system_colors, // ANSI 0-15; 16-255 derived
    bold_is_bright: bool = true,
    cursor_style: CursorStyle = .block,

    /// Resolve an indexed color (0-255) to RGB via this theme: 0-15 from the
    /// themed palette (bold may promote 0-7 to the bright 8-15), 16-255 from the
    /// fixed xterm cube/grayscale.
    pub fn resolveIndexed(self: *const Theme, idx: u8, bold: bool) Color {
        if (idx < 8) {
            const i: u8 = if (bold and self.bold_is_bright) idx + 8 else idx;
            return self.palette[i];
        } else if (idx < 16) {
            return self.palette[idx];
        }
        return Color.from256(idx); // cube/grayscale are not themed
    }

    /// Parse a theme config (text). `preset = <name>` sets the base; later keys override.
    pub fn parse(text: []const u8) Theme {
        var theme: Theme = presets.default;
        // pass 1: a preset becomes the base (regardless of where it appears)
        var p1 = std.mem.tokenizeAny(u8, text, "\n\r");
        while (p1.next()) |raw| {
            const line = trimSpace(raw);
            if (line.len == 0 or line[0] == '#') continue;
            const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
            if (std.mem.eql(u8, trimSpace(line[0..eq]), "preset")) {
                if (presetByName(trimSpace(line[eq + 1 ..]))) |p| theme = p;
            }
        }
        // pass 2: per-key overrides on top of the base
        var p2 = std.mem.tokenizeAny(u8, text, "\n\r");
        while (p2.next()) |raw| {
            const line = trimSpace(raw);
            if (line.len == 0 or line[0] == '#') continue;
            const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
            applyOverride(&theme, trimSpace(line[0..eq]), trimSpace(line[eq + 1 ..]));
        }
        return theme;
    }
};

fn trimSpace(s: []const u8) []const u8 {
    var a: usize = 0;
    var b: usize = s.len;
    while (a < b and (s[a] == ' ' or s[a] == '\t')) a += 1;
    while (b > a and (s[b - 1] == ' ' or s[b - 1] == '\t')) b -= 1;
    return s[a..b];
}

/// Parse `#RRGGBB` (or `RRGGBB`) into a Color; null if malformed.
pub fn parseHexColor(s_in: []const u8) ?Color {
    var s = s_in;
    if (s.len > 0 and s[0] == '#') s = s[1..];
    if (s.len < 6) return null;
    const r = std.fmt.parseInt(u8, s[0..2], 16) catch return null;
    const g = std.fmt.parseInt(u8, s[2..4], 16) catch return null;
    const b = std.fmt.parseInt(u8, s[4..6], 16) catch return null;
    return Color.fromRgb(r, g, b);
}

fn applyOverride(t: *Theme, key: []const u8, val: []const u8) void {
    const eql = std.mem.eql;
    if (eql(u8, key, "preset")) return; // handled in pass 1
    if (eql(u8, key, "background")) {
        if (parseHexColor(val)) |c| t.bg = c;
    } else if (eql(u8, key, "foreground")) {
        if (parseHexColor(val)) |c| t.fg = c;
    } else if (eql(u8, key, "cursor")) {
        if (parseHexColor(val)) |c| t.cursor = c;
    } else if (eql(u8, key, "cursor_text")) {
        if (parseHexColor(val)) |c| t.cursor_text = c;
    } else if (eql(u8, key, "selection_bg")) {
        if (parseHexColor(val)) |c| t.selection_bg = c;
    } else if (eql(u8, key, "selection_fg")) {
        if (parseHexColor(val)) |c| t.selection_fg = c;
    } else if (eql(u8, key, "url")) {
        if (parseHexColor(val)) |c| t.url = c;
    } else if (eql(u8, key, "bold_is_bright")) {
        t.bold_is_bright = eql(u8, val, "true");
    } else if (eql(u8, key, "cursor_style")) {
        t.cursor_style = if (eql(u8, val, "bar")) .bar else if (eql(u8, val, "underline")) .underline else .block;
    } else if (std.mem.startsWith(u8, key, "color")) {
        const n = std.fmt.parseInt(u8, key[5..], 10) catch return;
        if (n < 16) {
            if (parseHexColor(val)) |c| t.palette[n] = c;
        }
    }
}

/// Built-in named themes. `preset = <name>` selects one; per-key lines override.
pub const presets = struct {
    pub const default: Theme = .{};

    /// Old-school monochrome green CRT — everything renders green.
    pub const matrix: Theme = .{
        .bg = Color.fromRgb(0x00, 0x05, 0x00),
        .fg = Color.fromRgb(0x00, 0xFF, 0x00),
        .cursor = Color.fromRgb(0x00, 0xFF, 0x00),
        .cursor_text = Color.fromRgb(0x00, 0x05, 0x00),
        .selection_bg = Color.fromRgb(0x00, 0x44, 0x00),
        .selection_fg = Color.fromRgb(0x00, 0xFF, 0x00),
        .url = Color.fromRgb(0x66, 0xFF, 0xAA),
        .palette = .{
            Color.fromRgb(0x00, 0x22, 0x00), Color.fromRgb(0x00, 0x88, 0x00),
            Color.fromRgb(0x00, 0xFF, 0x00), Color.fromRgb(0x00, 0xCC, 0x00),
            Color.fromRgb(0x00, 0x66, 0x00), Color.fromRgb(0x00, 0xAA, 0x55),
            Color.fromRgb(0x00, 0xDD, 0xAA), Color.fromRgb(0x00, 0xCC, 0x00),
            Color.fromRgb(0x00, 0x44, 0x00), Color.fromRgb(0x00, 0xAA, 0x00),
            Color.fromRgb(0x33, 0xFF, 0x33), Color.fromRgb(0x66, 0xFF, 0x66),
            Color.fromRgb(0x00, 0x88, 0x44), Color.fromRgb(0x33, 0xFF, 0xAA),
            Color.fromRgb(0x66, 0xFF, 0xCC), Color.fromRgb(0xCC, 0xFF, 0xCC),
        },
    };

    /// Old-school amber CRT.
    pub const amber: Theme = .{
        .bg = Color.fromRgb(0x0A, 0x05, 0x00),
        .fg = Color.fromRgb(0xFF, 0xB0, 0x00),
        .cursor = Color.fromRgb(0xFF, 0xB0, 0x00),
        .cursor_text = Color.fromRgb(0x0A, 0x05, 0x00),
        .selection_bg = Color.fromRgb(0x44, 0x2A, 0x00),
        .selection_fg = Color.fromRgb(0xFF, 0xC8, 0x44),
        .url = Color.fromRgb(0xFF, 0xD8, 0x88),
        .palette = .{
            Color.fromRgb(0x2A, 0x18, 0x00), Color.fromRgb(0xCC, 0x70, 0x00),
            Color.fromRgb(0xFF, 0xB0, 0x00), Color.fromRgb(0xFF, 0xC8, 0x44),
            Color.fromRgb(0x88, 0x55, 0x00), Color.fromRgb(0xDD, 0x88, 0x22),
            Color.fromRgb(0xFF, 0xD8, 0x88), Color.fromRgb(0xFF, 0xB0, 0x00),
            Color.fromRgb(0x55, 0x33, 0x00), Color.fromRgb(0xFF, 0x88, 0x00),
            Color.fromRgb(0xFF, 0xC8, 0x44), Color.fromRgb(0xFF, 0xE0, 0x99),
            Color.fromRgb(0xAA, 0x66, 0x00), Color.fromRgb(0xFF, 0xAA, 0x33),
            Color.fromRgb(0xFF, 0xE8, 0xAA), Color.fromRgb(0xFF, 0xF0, 0xCC),
        },
    };

    /// Solarized Dark (Ethan Schoonover).
    pub const solarized_dark: Theme = .{
        .bg = Color.fromRgb(0x00, 0x2B, 0x36),
        .fg = Color.fromRgb(0x83, 0x94, 0x96),
        .cursor = Color.fromRgb(0x93, 0xA1, 0xA1),
        .cursor_text = Color.fromRgb(0x00, 0x2B, 0x36),
        .selection_bg = Color.fromRgb(0x07, 0x36, 0x42),
        .selection_fg = Color.fromRgb(0x93, 0xA1, 0xA1),
        .url = Color.fromRgb(0x26, 0x8B, 0xD2),
        .palette = .{
            Color.fromRgb(0x07, 0x36, 0x42), Color.fromRgb(0xDC, 0x32, 0x2F),
            Color.fromRgb(0x85, 0x99, 0x00), Color.fromRgb(0xB5, 0x89, 0x00),
            Color.fromRgb(0x26, 0x8B, 0xD2), Color.fromRgb(0xD3, 0x36, 0x82),
            Color.fromRgb(0x2A, 0xA1, 0x98), Color.fromRgb(0xEE, 0xE8, 0xD5),
            Color.fromRgb(0x00, 0x2B, 0x36), Color.fromRgb(0xCB, 0x4B, 0x16),
            Color.fromRgb(0x58, 0x6E, 0x75), Color.fromRgb(0x65, 0x7B, 0x83),
            Color.fromRgb(0x83, 0x94, 0x96), Color.fromRgb(0x6C, 0x71, 0xC4),
            Color.fromRgb(0x93, 0xA1, 0xA1), Color.fromRgb(0xFD, 0xF6, 0xE3),
        },
    };

    pub fn byName(name: []const u8) ?Theme {
        const eq = std.mem.eql;
        if (eq(u8, name, "default")) return default;
        if (eq(u8, name, "matrix") or eq(u8, name, "green")) return matrix;
        if (eq(u8, name, "amber")) return amber;
        if (eq(u8, name, "solarized_dark") or eq(u8, name, "solarized")) return solarized_dark;
        return null;
    }
};

fn presetByName(name: []const u8) ?Theme {
    return presets.byName(name);
}

// =============================================================================
// Tests
// =============================================================================

test "theme: preset + overrides parse" {
    const txt =
        \\# my theme
        \\preset = matrix
        \\background = #010203
        \\color1 = #ABCDEF
        \\bold_is_bright = false
    ;
    const t = Theme.parse(txt);
    // preset base (matrix fg green)
    try std.testing.expectEqual(@as(u8, 0x00), t.fg.r);
    try std.testing.expectEqual(@as(u8, 0xFF), t.fg.g);
    // overrides applied on top
    try std.testing.expectEqual(@as(u8, 0x01), t.bg.r);
    try std.testing.expectEqual(@as(u8, 0xAB), t.palette[1].r);
    try std.testing.expectEqual(false, t.bold_is_bright);
}

test "theme: resolveIndexed bold promotes to bright" {
    const t = presets.default;
    const c3 = t.resolveIndexed(3, false);
    const c11 = t.resolveIndexed(3, true); // bold → bright (palette 11)
    try std.testing.expectEqual(t.palette[3].r, c3.r);
    try std.testing.expectEqual(t.palette[11].r, c11.r);
    // 16-255 unaffected by theme
    const cube = t.resolveIndexed(196, false);
    try std.testing.expect(cube.r > cube.g);
}

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
