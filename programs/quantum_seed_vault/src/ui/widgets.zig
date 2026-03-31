//! UI Widgets for Quantum Seed Vault
//!
//! Reusable UI components for the LCD display.

const std = @import("std");
const display = @import("../display.zig");

const Framebuffer = display.Framebuffer;
const Color = display.Color;
const Colors = display.Colors;
const Theme = display.Theme;
const Align = display.Align;
const FontSize = display.FontSize;
const WIDTH = display.WIDTH;
const HEIGHT = display.HEIGHT;

/// Widget rendering context
pub const Context = struct {
    fb: *Framebuffer,
    theme: Theme,

    pub fn init(fb: *Framebuffer) Context {
        return .{
            .fb = fb,
            .theme = Theme{}, // Default theme
        };
    }
};

/// Button widget
pub const Button = struct {
    x: i16,
    y: i16,
    width: u16,
    height: u16,
    label: []const u8,
    selected: bool,
    enabled: bool,

    const Self = @This();

    pub fn init(x: i16, y: i16, width: u16, height: u16, label: []const u8) Self {
        return .{
            .x = x,
            .y = y,
            .width = width,
            .height = height,
            .label = label,
            .selected = false,
            .enabled = true,
        };
    }

    pub fn draw(self: *const Self, ctx: *Context) void {
        const bg = if (!self.enabled) Colors.DARK_GRAY else if (self.selected) ctx.theme.highlight else ctx.theme.secondary;
        const fg = if (!self.enabled) Colors.GRAY else ctx.theme.text;

        // Draw background
        ctx.fb.fillRect(self.x, self.y, self.width, self.height, bg);

        // Draw border
        if (self.selected) {
            ctx.fb.rect(self.x, self.y, self.width, self.height, ctx.theme.accent);
            ctx.fb.rect(self.x + 1, self.y + 1, self.width - 2, self.height - 2, ctx.theme.accent);
        } else {
            ctx.fb.rect(self.x, self.y, self.width, self.height, Colors.DARK_GRAY);
        }

        // Draw label centered
        const text_y = self.y + @as(i16, @intCast(self.height / 2)) - 4;
        ctx.fb.drawTextAligned(
            self.x,
            text_y,
            self.width,
            self.label,
            .small,
            .center,
            fg,
            null,
        );
    }
};

/// List item for menu/selection lists
pub const ListItem = struct {
    label: []const u8,
    value: usize,
    enabled: bool,

    pub fn init(label: []const u8, value: usize) ListItem {
        return .{
            .label = label,
            .value = value,
            .enabled = true,
        };
    }
};

/// Scrollable list widget
pub const List = struct {
    x: i16,
    y: i16,
    width: u16,
    height: u16,
    items: []const ListItem,
    selected_index: usize,
    scroll_offset: usize,
    visible_items: usize,
    item_height: u16,

    const Self = @This();

    pub fn init(x: i16, y: i16, width: u16, height: u16, items: []const ListItem) Self {
        const item_height: u16 = 20;
        const visible = height / item_height;
        return .{
            .x = x,
            .y = y,
            .width = width,
            .height = height,
            .items = items,
            .selected_index = 0,
            .scroll_offset = 0,
            .visible_items = visible,
            .item_height = item_height,
        };
    }

    pub fn draw(self: *const Self, ctx: *Context) void {
        // Background
        ctx.fb.fillRect(self.x, self.y, self.width, self.height, ctx.theme.background);

        // Draw visible items
        var visible_idx: usize = 0;
        var item_idx = self.scroll_offset;
        while (item_idx < self.items.len and visible_idx < self.visible_items) : ({
            item_idx += 1;
            visible_idx += 1;
        }) {
            const item = self.items[item_idx];
            const item_y = self.y + @as(i16, @intCast(visible_idx * self.item_height));
            const is_selected = item_idx == self.selected_index;

            // Item background
            const bg = if (is_selected) ctx.theme.highlight else ctx.theme.background;
            ctx.fb.fillRect(self.x, item_y, self.width, self.item_height, bg);

            // Item text
            const fg = if (!item.enabled) Colors.GRAY else ctx.theme.text;
            ctx.fb.drawText(
                self.x + 8,
                item_y + 5,
                item.label,
                .small,
                fg,
                null,
            );

            // Selection indicator
            if (is_selected) {
                ctx.fb.fillRect(self.x, item_y, 4, self.item_height, ctx.theme.accent);
            }
        }

        // Scroll indicator if needed
        if (self.items.len > self.visible_items) {
            self.drawScrollbar(ctx);
        }
    }

    fn drawScrollbar(self: *const Self, ctx: *Context) void {
        const bar_x = self.x + @as(i16, @intCast(self.width)) - 4;
        const bar_height = self.height;
        const thumb_height = @max(10, (self.visible_items * bar_height) / self.items.len);
        const thumb_offset = (self.scroll_offset * (bar_height - thumb_height)) /
            (self.items.len - self.visible_items + 1);

        // Track
        ctx.fb.fillRect(bar_x, self.y, 4, bar_height, Colors.DARK_GRAY);
        // Thumb
        ctx.fb.fillRect(bar_x, self.y + @as(i16, @intCast(thumb_offset)), 4, @intCast(thumb_height), ctx.theme.accent);
    }

    pub fn moveUp(self: *Self) void {
        if (self.selected_index > 0) {
            self.selected_index -= 1;
            if (self.selected_index < self.scroll_offset) {
                self.scroll_offset = self.selected_index;
            }
        }
    }

    pub fn moveDown(self: *Self) void {
        if (self.selected_index < self.items.len - 1) {
            self.selected_index += 1;
            if (self.selected_index >= self.scroll_offset + self.visible_items) {
                self.scroll_offset = self.selected_index - self.visible_items + 1;
            }
        }
    }

    pub fn getSelected(self: *const Self) ?*const ListItem {
        if (self.selected_index < self.items.len) {
            return &self.items[self.selected_index];
        }
        return null;
    }
};

/// Progress bar widget
pub const ProgressBar = struct {
    x: i16,
    y: i16,
    width: u16,
    height: u16,
    progress: f32, // 0.0 to 1.0
    label: ?[]const u8,

    const Self = @This();

    pub fn init(x: i16, y: i16, width: u16, height: u16) Self {
        return .{
            .x = x,
            .y = y,
            .width = width,
            .height = height,
            .progress = 0.0,
            .label = null,
        };
    }

    pub fn draw(self: *const Self, ctx: *Context) void {
        // Background
        ctx.fb.fillRect(self.x, self.y, self.width, self.height, Colors.DARK_GRAY);

        // Progress fill
        const fill_width = @as(u16, @intFromFloat(@as(f32, @floatFromInt(self.width)) * self.progress));
        if (fill_width > 0) {
            ctx.fb.fillRect(self.x, self.y, fill_width, self.height, ctx.theme.accent);
        }

        // Border
        ctx.fb.rect(self.x, self.y, self.width, self.height, Colors.GRAY);

        // Label
        if (self.label) |lbl| {
            ctx.fb.drawTextAligned(
                self.x,
                self.y + @as(i16, @intCast(self.height / 2)) - 4,
                self.width,
                lbl,
                .small,
                .center,
                ctx.theme.text,
                null,
            );
        }
    }

    pub fn setProgress(self: *Self, value: f32) void {
        self.progress = @max(0.0, @min(1.0, value));
    }
};

/// Text input widget (for seed entry)
pub const TextInput = struct {
    x: i16,
    y: i16,
    width: u16,
    height: u16,
    buffer: [256]u8,
    cursor: usize,
    max_length: usize,
    masked: bool, // Hide input (for passwords)
    focused: bool,

    const Self = @This();

    pub fn init(x: i16, y: i16, width: u16, height: u16, max_length: usize, masked: bool) Self {
        return .{
            .x = x,
            .y = y,
            .width = width,
            .height = height,
            .buffer = [_]u8{0} ** 256,
            .cursor = 0,
            .max_length = @min(max_length, 255),
            .masked = masked,
            .focused = false,
        };
    }

    pub fn draw(self: *const Self, ctx: *Context) void {
        // Background
        const bg = if (self.focused) ctx.theme.secondary else Colors.DARK_GRAY;
        ctx.fb.fillRect(self.x, self.y, self.width, self.height, bg);

        // Border
        const border_color = if (self.focused) ctx.theme.accent else Colors.GRAY;
        ctx.fb.rect(self.x, self.y, self.width, self.height, border_color);

        // Text content
        const text_y = self.y + @as(i16, @intCast(self.height / 2)) - 4;
        if (self.cursor > 0) {
            if (self.masked) {
                // Show asterisks
                var mask_buf: [256]u8 = undefined;
                @memset(mask_buf[0..self.cursor], '*');
                ctx.fb.drawText(
                    self.x + 4,
                    text_y,
                    mask_buf[0..self.cursor],
                    .small,
                    ctx.theme.text,
                    null,
                );
            } else {
                ctx.fb.drawText(
                    self.x + 4,
                    text_y,
                    self.buffer[0..self.cursor],
                    .small,
                    ctx.theme.text,
                    null,
                );
            }
        }

        // Cursor (blinking would require animation state)
        if (self.focused) {
            const cursor_x = self.x + 4 + @as(i16, @intCast(self.cursor * 6));
            ctx.fb.vLine(cursor_x, self.y + 4, self.height - 8, ctx.theme.text);
        }
    }

    pub fn addChar(self: *Self, char: u8) bool {
        if (self.cursor < self.max_length) {
            self.buffer[self.cursor] = char;
            self.cursor += 1;
            return true;
        }
        return false;
    }

    pub fn backspace(self: *Self) bool {
        if (self.cursor > 0) {
            self.cursor -= 1;
            self.buffer[self.cursor] = 0;
            return true;
        }
        return false;
    }

    pub fn clear(self: *Self) void {
        @memset(&self.buffer, 0);
        self.cursor = 0;
    }

    pub fn getText(self: *const Self) []const u8 {
        return self.buffer[0..self.cursor];
    }
};

/// Header bar widget
pub const Header = struct {
    title: []const u8,
    show_battery: bool,
    battery_level: u8, // 0-100

    const Self = @This();
    const HEADER_HEIGHT: u16 = 24;

    pub fn init(title: []const u8) Self {
        return .{
            .title = title,
            .show_battery = true,
            .battery_level = 100,
        };
    }

    pub fn draw(self: *const Self, ctx: *Context) void {
        // Background
        ctx.fb.fillRect(0, 0, WIDTH, HEADER_HEIGHT, ctx.theme.primary);

        // Title
        ctx.fb.drawTextAligned(
            0,
            6,
            WIDTH,
            self.title,
            .small,
            .center,
            ctx.theme.text,
            null,
        );

        // Battery indicator
        if (self.show_battery) {
            self.drawBattery(ctx);
        }
    }

    fn drawBattery(self: *const Self, ctx: *Context) void {
        const bat_x: i16 = WIDTH - 28;
        const bat_y: i16 = 6;
        const bat_w: u16 = 20;
        const bat_h: u16 = 10;

        // Outline
        ctx.fb.rect(bat_x, bat_y, bat_w, bat_h, ctx.theme.text);
        ctx.fb.fillRect(bat_x + @as(i16, @intCast(bat_w)), bat_y + 2, 2, 6, ctx.theme.text);

        // Fill based on level
        const fill_color: Color = if (self.battery_level > 50)
            Colors.GREEN
        else if (self.battery_level > 20)
            Colors.YELLOW
        else
            Colors.RED;

        const fill_width = (self.battery_level * (bat_w - 4)) / 100;
        if (fill_width > 0) {
            ctx.fb.fillRect(bat_x + 2, bat_y + 2, @intCast(fill_width), bat_h - 4, fill_color);
        }
    }
};

/// Footer with button hints
pub const Footer = struct {
    buttons: [3]?[]const u8,

    const Self = @This();
    const FOOTER_HEIGHT: u16 = 20;

    pub fn init() Self {
        return .{
            .buttons = .{ null, null, null },
        };
    }

    pub fn setButtons(self: *Self, btn1: ?[]const u8, btn2: ?[]const u8, btn3: ?[]const u8) void {
        self.buttons = .{ btn1, btn2, btn3 };
    }

    pub fn draw(self: *const Self, ctx: *Context) void {
        const y: i16 = HEIGHT - FOOTER_HEIGHT;

        // Background
        ctx.fb.fillRect(0, y, WIDTH, FOOTER_HEIGHT, ctx.theme.secondary);

        // Draw button labels
        const btn_width = WIDTH / 3;
        for (self.buttons, 0..) |maybe_label, i| {
            if (maybe_label) |label| {
                const btn_x: i16 = @intCast(i * btn_width);
                ctx.fb.drawTextAligned(
                    btn_x,
                    y + 5,
                    btn_width,
                    label,
                    .small,
                    .center,
                    ctx.theme.text,
                    null,
                );
            }
        }

        // Separators
        ctx.fb.vLine(@intCast(btn_width), y, FOOTER_HEIGHT, Colors.DARK_GRAY);
        ctx.fb.vLine(@intCast(btn_width * 2), y, FOOTER_HEIGHT, Colors.DARK_GRAY);
    }
};

/// Message box for alerts/confirmations
pub const MessageBox = struct {
    title: []const u8,
    message: []const u8,
    buttons: []const []const u8,
    selected_button: usize,

    const Self = @This();
    const BOX_WIDTH: u16 = 200;
    const BOX_HEIGHT: u16 = 100;

    pub fn init(title: []const u8, message: []const u8, buttons: []const []const u8) Self {
        return .{
            .title = title,
            .message = message,
            .buttons = buttons,
            .selected_button = 0,
        };
    }

    pub fn draw(self: *const Self, ctx: *Context) void {
        const x: i16 = @intCast((WIDTH - BOX_WIDTH) / 2);
        const y: i16 = @intCast((HEIGHT - BOX_HEIGHT) / 2);

        // Shadow
        ctx.fb.fillRect(x + 4, y + 4, BOX_WIDTH, BOX_HEIGHT, Colors.BLACK);

        // Background
        ctx.fb.fillRect(x, y, BOX_WIDTH, BOX_HEIGHT, ctx.theme.background);
        ctx.fb.rect(x, y, BOX_WIDTH, BOX_HEIGHT, ctx.theme.accent);

        // Title bar
        ctx.fb.fillRect(x, y, BOX_WIDTH, 20, ctx.theme.primary);
        ctx.fb.drawTextAligned(x, y + 5, BOX_WIDTH, self.title, .small, .center, ctx.theme.text, null);

        // Message
        ctx.fb.drawTextAligned(x, y + 30, BOX_WIDTH, self.message, .small, .center, ctx.theme.text, null);

        // Buttons
        if (self.buttons.len > 0) {
            const btn_total_width = self.buttons.len * 60 + (self.buttons.len - 1) * 10;
            var btn_x: i16 = x + @as(i16, @intCast((BOX_WIDTH - btn_total_width) / 2));
            const btn_y: i16 = y + @as(i16, @intCast(BOX_HEIGHT)) - 30;

            for (self.buttons, 0..) |label, i| {
                const is_selected = i == self.selected_button;
                const btn = Button.init(btn_x, btn_y, 60, 20, label);
                var btn_copy = btn;
                btn_copy.selected = is_selected;
                btn_copy.draw(ctx);
                btn_x += 70;
            }
        }
    }

    pub fn selectNext(self: *Self) void {
        if (self.buttons.len > 0) {
            self.selected_button = (self.selected_button + 1) % self.buttons.len;
        }
    }

    pub fn selectPrev(self: *Self) void {
        if (self.buttons.len > 0) {
            if (self.selected_button == 0) {
                self.selected_button = self.buttons.len - 1;
            } else {
                self.selected_button -= 1;
            }
        }
    }
};
