// PC-98 amber-on-black retro theme for the Zigix system monitor.
// Matches the Theme struct defined in zig_tui/src/core/theme.zig.

const tui = @import("zig_tui");
const Color = tui.Color;
const Style = tui.Style;

// Amber color palette
pub const amber = Color.fromRgb(255, 176, 0);
pub const amber_bright = Color.fromRgb(255, 210, 64);
pub const amber_medium = Color.fromRgb(204, 140, 0);
pub const amber_dim = Color.fromRgb(128, 88, 0);
pub const amber_dark = Color.fromRgb(48, 32, 0);
pub const amber_surface = Color.fromRgb(24, 16, 0);
pub const red_amber = Color.fromRgb(255, 80, 0);

// Convenience styles used across all views
pub const title_style = Style{ .fg = amber_bright, .attrs = .{ .bold = true } };
pub const text_style = Style{ .fg = amber };
pub const dim_style = Style{ .fg = amber_dim };
pub const highlight_style = Style{ .fg = Color.black, .bg = amber };
pub const border_style = Style{ .fg = amber_medium };
pub const header_bg_style = Style{ .fg = amber_bright, .bg = amber_dark, .attrs = .{ .bold = true } };
pub const statusbar_style = Style{ .fg = Color.black, .bg = amber_medium };
pub const statusbar_sep_style = Style{ .fg = amber_dark, .bg = amber_medium };

pub const pc98_amber = tui.Theme{
    .name = "PC-98 Amber",
    .palette = .{
        .primary = amber,
        .secondary = amber_medium,
        .accent = amber_bright,
        .background = Color.black,
        .surface = amber_surface,
        .overlay = amber_dark,
        .text = amber,
        .text_secondary = amber_medium,
        .text_disabled = amber_dim,
        .success = amber_bright,
        .warning = Color.fromRgb(255, 140, 0),
        .error_color = red_amber,
        .info = Color.fromRgb(204, 176, 64),
        .border = amber_medium,
        .border_focus = amber,
        .hover = amber_dark,
        .selected = amber_medium,
        .pressed = amber_bright,
    },
    .button = .{
        .normal = Style{ .fg = amber },
        .focused = Style{ .fg = Color.black, .bg = amber, .attrs = .{ .bold = true } },
        .pressed = Style{ .fg = Color.black, .bg = amber_bright },
        .disabled = Style{ .fg = amber_dim },
        .hovered = Style{ .fg = amber_bright },
    },
    .input = .{
        .normal = Style{ .fg = amber },
        .focused = Style{ .fg = amber_bright, .attrs = .{ .underline = true } },
        .disabled = Style{ .fg = amber_dim },
        .placeholder = Style{ .fg = amber_dim },
        .cursor = Style{ .fg = Color.black, .bg = amber },
    },
    .list = .{
        .normal = Style{ .fg = amber },
        .selected = Style{ .fg = Color.black, .bg = amber, .attrs = .{ .bold = true } },
        .focused = Style{ .fg = amber_bright },
        .header = Style{ .fg = amber_bright, .attrs = .{ .bold = true } },
    },
    .table = .{
        .header = Style{ .fg = Color.black, .bg = amber_medium, .attrs = .{ .bold = true } },
        .row = Style{ .fg = amber },
        .row_alt = Style{ .fg = amber, .bg = amber_surface },
        .selected = Style{ .fg = Color.black, .bg = amber },
        .border = Style{ .fg = amber_dim },
    },
    .modal = .{
        .background = Style{ .bg = amber_dark },
        .border = Style{ .fg = amber },
        .title = Style{ .fg = amber_bright, .attrs = .{ .bold = true } },
        .message = Style{ .fg = amber },
        .button = Style{ .fg = amber },
        .button_selected = Style{ .fg = Color.black, .bg = amber, .attrs = .{ .bold = true } },
        .shadow = Style{ .fg = Color.black, .bg = Color.black },
    },
    .tabs = .{
        .active = Style{ .fg = Color.black, .bg = amber, .attrs = .{ .bold = true } },
        .inactive = Style{ .fg = amber_medium },
        .border = Style{ .fg = amber_dim },
        .disabled = Style{ .fg = amber_dim },
    },
};
