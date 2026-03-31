//! Theme system - centralized color and style management
//!
//! Provides theming support for consistent look and feel across widgets.

const std = @import("std");
const core = @import("core.zig");

pub const Color = core.Color;
pub const Style = core.Style;

/// Theme color palette
pub const Palette = struct {
    // Primary colors
    primary: Color,
    secondary: Color,
    accent: Color,

    // Background colors
    background: Color,
    surface: Color,
    overlay: Color,

    // Text colors
    text: Color,
    text_secondary: Color,
    text_disabled: Color,

    // Semantic colors
    success: Color,
    warning: Color,
    error_color: Color,
    info: Color,

    // Border colors
    border: Color,
    border_focus: Color,

    // Interactive states
    hover: Color,
    selected: Color,
    pressed: Color,
};

/// Theme definition
pub const Theme = struct {
    name: []const u8,
    palette: Palette,

    // Widget-specific styles
    button: ButtonTheme,
    input: InputTheme,
    list: ListTheme,
    table: TableTheme,
    modal: ModalTheme,
    tabs: TabsTheme,

    const Self = @This();

    /// Get style for button
    pub fn buttonStyle(self: *const Self, state: WidgetState) Style {
        return switch (state) {
            .normal => self.button.normal,
            .focused => self.button.focused,
            .pressed => self.button.pressed,
            .disabled => self.button.disabled,
            .hovered => self.button.hovered,
        };
    }

    /// Get style for input
    pub fn inputStyle(self: *const Self, state: WidgetState) Style {
        return switch (state) {
            .normal => self.input.normal,
            .focused => self.input.focused,
            .pressed => self.input.normal,
            .disabled => self.input.disabled,
            .hovered => self.input.normal,
        };
    }

    /// Get style for text
    pub fn textStyle(self: *const Self, variant: TextVariant) Style {
        return switch (variant) {
            .primary => Style{ .fg = self.palette.text },
            .secondary => Style{ .fg = self.palette.text_secondary },
            .disabled => Style{ .fg = self.palette.text_disabled },
            .success => Style{ .fg = self.palette.success },
            .warning => Style{ .fg = self.palette.warning },
            .err => Style{ .fg = self.palette.error_color },
            .info => Style{ .fg = self.palette.info },
        };
    }
};

/// Widget states
pub const WidgetState = enum {
    normal,
    focused,
    pressed,
    disabled,
    hovered,
};

/// Text variants
pub const TextVariant = enum {
    primary,
    secondary,
    disabled,
    success,
    warning,
    err,
    info,
};

/// Button theme styles
pub const ButtonTheme = struct {
    normal: Style,
    focused: Style,
    pressed: Style,
    disabled: Style,
    hovered: Style,
};

/// Input theme styles
pub const InputTheme = struct {
    normal: Style,
    focused: Style,
    disabled: Style,
    placeholder: Style,
    cursor: Style,
};

/// List theme styles
pub const ListTheme = struct {
    normal: Style,
    selected: Style,
    focused: Style,
    header: Style,
};

/// Table theme styles
pub const TableTheme = struct {
    header: Style,
    row: Style,
    row_alt: Style,
    selected: Style,
    border: Style,
};

/// Modal theme styles
pub const ModalTheme = struct {
    background: Style,
    border: Style,
    title: Style,
    message: Style,
    button: Style,
    button_selected: Style,
    shadow: Style,
};

/// Tabs theme styles
pub const TabsTheme = struct {
    active: Style,
    inactive: Style,
    border: Style,
    disabled: Style,
};

/// Built-in dark theme
pub const dark_theme = Theme{
    .name = "Dark",
    .palette = .{
        .primary = Color.cyan,
        .secondary = Color.blue,
        .accent = Color.magenta,
        .background = Color.black,
        .surface = Color.bright_black,
        .overlay = Color.gray,
        .text = Color.white,
        .text_secondary = Color.gray,
        .text_disabled = Color.bright_black,
        .success = Color.green,
        .warning = Color.yellow,
        .error_color = Color.red,
        .info = Color.cyan,
        .border = Color.gray,
        .border_focus = Color.cyan,
        .hover = Color.bright_black,
        .selected = Color.blue,
        .pressed = Color.bright_blue,
    },
    .button = .{
        .normal = Style{ .fg = Color.white },
        .focused = Style{ .fg = Color.black, .bg = Color.cyan, .attrs = .{ .bold = true } },
        .pressed = Style{ .fg = Color.black, .bg = Color.white },
        .disabled = Style{ .fg = Color.gray },
        .hovered = Style{ .fg = Color.cyan },
    },
    .input = .{
        .normal = Style{ .fg = Color.white },
        .focused = Style{ .fg = Color.white, .attrs = .{ .underline = true } },
        .disabled = Style{ .fg = Color.gray },
        .placeholder = Style{ .fg = Color.gray },
        .cursor = Style{ .fg = Color.black, .bg = Color.white },
    },
    .list = .{
        .normal = Style{ .fg = Color.white },
        .selected = Style{ .fg = Color.black, .bg = Color.cyan },
        .focused = Style{ .fg = Color.cyan },
        .header = Style{ .fg = Color.yellow, .attrs = .{ .bold = true } },
    },
    .table = .{
        .header = Style{ .fg = Color.black, .bg = Color.white, .attrs = .{ .bold = true } },
        .row = Style{ .fg = Color.white },
        .row_alt = Style{ .fg = Color.white, .bg = Color.bright_black },
        .selected = Style{ .fg = Color.black, .bg = Color.cyan },
        .border = Style{ .fg = Color.gray },
    },
    .modal = .{
        .background = Style{ .bg = Color.bright_black },
        .border = Style{ .fg = Color.cyan },
        .title = Style{ .fg = Color.bright_white, .attrs = .{ .bold = true } },
        .message = Style{ .fg = Color.white },
        .button = Style{ .fg = Color.white },
        .button_selected = Style{ .fg = Color.black, .bg = Color.white, .attrs = .{ .bold = true } },
        .shadow = Style{ .fg = Color.black, .bg = Color.black },
    },
    .tabs = .{
        .active = Style{ .fg = Color.black, .bg = Color.white, .attrs = .{ .bold = true } },
        .inactive = Style{ .fg = Color.white },
        .border = Style{ .fg = Color.gray },
        .disabled = Style{ .fg = Color.gray },
    },
};

/// Built-in light theme
pub const light_theme = Theme{
    .name = "Light",
    .palette = .{
        .primary = Color.blue,
        .secondary = Color.cyan,
        .accent = Color.magenta,
        .background = Color.white,
        .surface = Color.bright_white,
        .overlay = Color.gray,
        .text = Color.black,
        .text_secondary = Color.gray,
        .text_disabled = Color.bright_black,
        .success = Color.green,
        .warning = Color.yellow,
        .error_color = Color.red,
        .info = Color.blue,
        .border = Color.gray,
        .border_focus = Color.blue,
        .hover = Color.bright_white,
        .selected = Color.blue,
        .pressed = Color.bright_blue,
    },
    .button = .{
        .normal = Style{ .fg = Color.black },
        .focused = Style{ .fg = Color.white, .bg = Color.blue, .attrs = .{ .bold = true } },
        .pressed = Style{ .fg = Color.white, .bg = Color.black },
        .disabled = Style{ .fg = Color.gray },
        .hovered = Style{ .fg = Color.blue },
    },
    .input = .{
        .normal = Style{ .fg = Color.black },
        .focused = Style{ .fg = Color.black, .attrs = .{ .underline = true } },
        .disabled = Style{ .fg = Color.gray },
        .placeholder = Style{ .fg = Color.gray },
        .cursor = Style{ .fg = Color.white, .bg = Color.black },
    },
    .list = .{
        .normal = Style{ .fg = Color.black },
        .selected = Style{ .fg = Color.white, .bg = Color.blue },
        .focused = Style{ .fg = Color.blue },
        .header = Style{ .fg = Color.blue, .attrs = .{ .bold = true } },
    },
    .table = .{
        .header = Style{ .fg = Color.white, .bg = Color.blue, .attrs = .{ .bold = true } },
        .row = Style{ .fg = Color.black },
        .row_alt = Style{ .fg = Color.black, .bg = Color.bright_white },
        .selected = Style{ .fg = Color.white, .bg = Color.blue },
        .border = Style{ .fg = Color.gray },
    },
    .modal = .{
        .background = Style{ .bg = Color.white },
        .border = Style{ .fg = Color.blue },
        .title = Style{ .fg = Color.black, .attrs = .{ .bold = true } },
        .message = Style{ .fg = Color.black },
        .button = Style{ .fg = Color.black },
        .button_selected = Style{ .fg = Color.white, .bg = Color.blue, .attrs = .{ .bold = true } },
        .shadow = Style{ .fg = Color.gray, .bg = Color.gray },
    },
    .tabs = .{
        .active = Style{ .fg = Color.white, .bg = Color.blue, .attrs = .{ .bold = true } },
        .inactive = Style{ .fg = Color.black },
        .border = Style{ .fg = Color.gray },
        .disabled = Style{ .fg = Color.gray },
    },
};

/// High contrast theme for accessibility
pub const high_contrast_theme = Theme{
    .name = "High Contrast",
    .palette = .{
        .primary = Color.bright_white,
        .secondary = Color.bright_yellow,
        .accent = Color.bright_cyan,
        .background = Color.black,
        .surface = Color.black,
        .overlay = Color.black,
        .text = Color.bright_white,
        .text_secondary = Color.white,
        .text_disabled = Color.gray,
        .success = Color.bright_green,
        .warning = Color.bright_yellow,
        .error_color = Color.bright_red,
        .info = Color.bright_cyan,
        .border = Color.bright_white,
        .border_focus = Color.bright_yellow,
        .hover = Color.bright_white,
        .selected = Color.bright_yellow,
        .pressed = Color.bright_white,
    },
    .button = .{
        .normal = Style{ .fg = Color.bright_white },
        .focused = Style{ .fg = Color.black, .bg = Color.bright_yellow, .attrs = .{ .bold = true } },
        .pressed = Style{ .fg = Color.black, .bg = Color.bright_white },
        .disabled = Style{ .fg = Color.gray },
        .hovered = Style{ .fg = Color.bright_yellow },
    },
    .input = .{
        .normal = Style{ .fg = Color.bright_white },
        .focused = Style{ .fg = Color.bright_yellow, .attrs = .{ .underline = true } },
        .disabled = Style{ .fg = Color.gray },
        .placeholder = Style{ .fg = Color.white },
        .cursor = Style{ .fg = Color.black, .bg = Color.bright_yellow },
    },
    .list = .{
        .normal = Style{ .fg = Color.bright_white },
        .selected = Style{ .fg = Color.black, .bg = Color.bright_yellow },
        .focused = Style{ .fg = Color.bright_yellow },
        .header = Style{ .fg = Color.bright_cyan, .attrs = .{ .bold = true } },
    },
    .table = .{
        .header = Style{ .fg = Color.black, .bg = Color.bright_white, .attrs = .{ .bold = true } },
        .row = Style{ .fg = Color.bright_white },
        .row_alt = Style{ .fg = Color.bright_white },
        .selected = Style{ .fg = Color.black, .bg = Color.bright_yellow },
        .border = Style{ .fg = Color.bright_white },
    },
    .modal = .{
        .background = Style{ .bg = Color.black },
        .border = Style{ .fg = Color.bright_white },
        .title = Style{ .fg = Color.bright_yellow, .attrs = .{ .bold = true } },
        .message = Style{ .fg = Color.bright_white },
        .button = Style{ .fg = Color.bright_white },
        .button_selected = Style{ .fg = Color.black, .bg = Color.bright_yellow, .attrs = .{ .bold = true } },
        .shadow = Style{ .fg = Color.white, .bg = Color.white },
    },
    .tabs = .{
        .active = Style{ .fg = Color.black, .bg = Color.bright_yellow, .attrs = .{ .bold = true } },
        .inactive = Style{ .fg = Color.bright_white },
        .border = Style{ .fg = Color.bright_white },
        .disabled = Style{ .fg = Color.gray },
    },
};

/// Global theme manager
pub const ThemeManager = struct {
    current: *const Theme,

    const Self = @This();

    pub fn init() Self {
        return .{ .current = &dark_theme };
    }

    pub fn setTheme(self: *Self, theme: *const Theme) void {
        self.current = theme;
    }

    pub fn get(self: *const Self) *const Theme {
        return self.current;
    }
};

/// Global theme instance
pub var global_theme: ThemeManager = ThemeManager.init();

test "Theme styles" {
    const theme = dark_theme;
    const btn_style = theme.buttonStyle(.focused);
    try std.testing.expect(btn_style.attrs.bold);
}
