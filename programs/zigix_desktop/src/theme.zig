// PC-98 amber desktop theme for the Zigix TUI desktop environment.
// Extends the amber palette from zigix_monitor with window-manager-specific styles.

const platform = @import("platform.zig");
const tui = if (platform.is_linux) @import("zig_tui") else @import("tui_pure.zig");
const Color = tui.Color;
const Style = tui.Style;

// ── Amber color palette ─────────────────────────────────────────────────────
pub const amber = Color.fromRgb(255, 176, 0);
pub const amber_bright = Color.fromRgb(255, 210, 64);
pub const amber_medium = Color.fromRgb(204, 140, 0);
pub const amber_dim = Color.fromRgb(128, 88, 0);
pub const amber_dark = Color.fromRgb(48, 32, 0);
pub const amber_surface = Color.fromRgb(24, 16, 0);
pub const amber_very_dim = Color.fromRgb(64, 44, 0);
pub const red_amber = Color.fromRgb(255, 80, 0);

// ── Window chrome ───────────────────────────────────────────────────────────

// Active (focused) window
pub const active_border = Style{ .fg = amber_bright };
pub const active_title = Style{
    .fg = Color.black,
    .bg = amber,
    .attrs = .{ .bold = true },
};
pub const active_title_close = Style{
    .fg = red_amber,
    .bg = amber,
    .attrs = .{ .bold = true },
};

// Inactive (unfocused) window
pub const inactive_border = Style{ .fg = amber_dim };
pub const inactive_title = Style{
    .fg = amber_medium,
    .bg = amber_dark,
};
pub const inactive_title_close = Style{
    .fg = amber_dim,
    .bg = amber_dark,
};

// ── Panel (taskbar) ─────────────────────────────────────────────────────────
pub const panel_bg = Style{ .fg = amber, .bg = amber_dark };
pub const panel_separator = Style{ .fg = amber_dim, .bg = amber_dark };
pub const panel_active_window = Style{
    .fg = Color.black,
    .bg = amber,
    .attrs = .{ .bold = true },
};
pub const panel_inactive_window = Style{ .fg = amber_medium, .bg = amber_dark };
pub const panel_clock = Style{
    .fg = amber_bright,
    .bg = amber_dark,
    .attrs = .{ .bold = true },
};
pub const panel_stats = Style{ .fg = amber_medium, .bg = amber_dark };

// ── Launcher overlay ────────────────────────────────────────────────────────
pub const launcher_border = Style{ .fg = amber_bright };
pub const launcher_title = Style{
    .fg = amber_bright,
    .attrs = .{ .bold = true },
};
pub const launcher_bg = Style{ .bg = Color.fromRgb(16, 10, 0) };
pub const launcher_input = Style{
    .fg = amber_bright,
    .attrs = .{ .underline = true },
};
pub const launcher_item = Style{ .fg = amber };
pub const launcher_item_selected = Style{
    .fg = Color.black,
    .bg = amber,
    .attrs = .{ .bold = true },
};
pub const launcher_item_desc = Style{ .fg = amber_dim };

// ── Wallpaper ───────────────────────────────────────────────────────────────
pub const wallpaper = Style{ .fg = amber_very_dim, .bg = Color.black };

// ── General text ────────────────────────────────────────────────────────────
pub const text = Style{ .fg = amber };
pub const text_bright = Style{ .fg = amber_bright };
pub const text_dim = Style{ .fg = amber_dim };
pub const text_error = Style{ .fg = red_amber, .attrs = .{ .bold = true } };

// ── Default terminal colors ─────────────────────────────────────────────────
// When terminal_mux cells use CellColor.default, map to amber-on-black.
pub const term_default_fg = amber;
pub const term_default_bg = Color.black;
