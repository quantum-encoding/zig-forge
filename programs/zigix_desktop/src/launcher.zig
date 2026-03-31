// Launcher — application launcher overlay for the Zigix desktop.
// Displays a centered command palette for launching programs in new windows.

const std = @import("std");
const platform = @import("platform.zig");
const tui = if (platform.is_linux) @import("zig_tui") else @import("tui_pure.zig");
const theme = @import("theme.zig");

const Buffer = tui.Buffer;
const Rect = tui.Rect;
const Size = tui.Size;
const Cell = tui.Cell;
const Style = tui.Style;
const Event = tui.Event;
const Key = tui.Key;

pub const AppDef = struct {
    name: []const u8,
    cmd: []const u8,
    desc: []const u8,
};

pub const apps = [_]AppDef{
    .{ .name = "bash", .cmd = "/bin/bash", .desc = "Shell" },
    .{ .name = "zsh", .cmd = "/bin/zsh", .desc = "Z Shell" },
    .{ .name = "zigix-monitor", .cmd = "zigix-monitor", .desc = "System Monitor" },
    .{ .name = "vim", .cmd = "/usr/bin/vim", .desc = "Text Editor" },
    .{ .name = "htop", .cmd = "/usr/bin/htop", .desc = "Process Viewer" },
    .{ .name = "top", .cmd = "/usr/bin/top", .desc = "Task Manager" },
    .{ .name = "nano", .cmd = "/usr/bin/nano", .desc = "Simple Editor" },
    .{ .name = "less", .cmd = "/usr/bin/less", .desc = "Pager" },
};

const MAX_INPUT_LEN = 64;
const OVERLAY_WIDTH: u16 = 50;

pub const Launcher = struct {
    active: bool = false,
    input_buf: [MAX_INPUT_LEN]u8 = undefined,
    input_len: usize = 0,
    selected_idx: usize = 0,

    // Filtered list indices (into the apps array)
    filtered: [apps.len]usize = undefined,
    filtered_count: usize = 0,

    const Self = @This();

    pub fn toggle(self: *Self) void {
        self.active = !self.active;
        if (self.active) {
            self.reset();
        }
    }

    pub fn open(self: *Self) void {
        self.active = true;
        self.reset();
    }

    pub fn close(self: *Self) void {
        self.active = false;
    }

    fn reset(self: *Self) void {
        self.input_len = 0;
        self.selected_idx = 0;
        self.updateFilter();
    }

    /// Handle a key event while the launcher is active.
    /// Returns the command to launch (if Enter was pressed), or null.
    pub fn handleKey(self: *Self, event: Event) ?[]const u8 {
        switch (event) {
            .key => |k| {
                switch (k.key) {
                    .char => |c| {
                        if (k.modifiers.ctrl) return null;

                        // Printable ASCII input
                        if (c >= 0x20 and c < 0x7F and self.input_len < MAX_INPUT_LEN) {
                            self.input_buf[self.input_len] = @intCast(c);
                            self.input_len += 1;
                            self.selected_idx = 0;
                            self.updateFilter();
                        }
                        return null;
                    },
                    .special => |s| {
                        switch (s) {
                            .escape => {
                                self.close();
                                return null;
                            },
                            .enter => {
                                if (self.filtered_count > 0) {
                                    const idx = self.filtered[self.selected_idx];
                                    self.close();
                                    return apps[idx].cmd;
                                }
                                return null;
                            },
                            .backspace => {
                                if (self.input_len > 0) {
                                    self.input_len -= 1;
                                    self.selected_idx = 0;
                                    self.updateFilter();
                                }
                                return null;
                            },
                            .up => {
                                if (self.selected_idx > 0) {
                                    self.selected_idx -= 1;
                                }
                                return null;
                            },
                            .down => {
                                if (self.selected_idx + 1 < self.filtered_count) {
                                    self.selected_idx += 1;
                                }
                                return null;
                            },
                            .tab => {
                                if (self.selected_idx + 1 < self.filtered_count) {
                                    self.selected_idx += 1;
                                } else {
                                    self.selected_idx = 0;
                                }
                                return null;
                            },
                            else => return null,
                        }
                    },
                }
            },
            else => return null,
        }
    }

    fn updateFilter(self: *Self) void {
        self.filtered_count = 0;
        const query = self.input_buf[0..self.input_len];

        for (apps, 0..) |app, i| {
            if (query.len == 0 or containsInsensitive(app.name, query) or containsInsensitive(app.desc, query)) {
                self.filtered[self.filtered_count] = i;
                self.filtered_count += 1;
            }
        }

        if (self.selected_idx >= self.filtered_count and self.filtered_count > 0) {
            self.selected_idx = self.filtered_count - 1;
        }
    }

    /// Render the launcher overlay centered on screen.
    pub fn render(self: *const Self, buf: *Buffer, screen: Size) void {
        if (!self.active) return;

        const visible_items: u16 = @intCast(self.filtered_count);
        const height: u16 = visible_items +| 4; // border(1) + title(1) + input(1) + items + border(1)
        const width: u16 = if (screen.width > OVERLAY_WIDTH + 4) OVERLAY_WIDTH else screen.width -| 4;

        // Center on screen
        const ox = if (screen.width > width) (screen.width - width) / 2 else 0;
        const oy = if (screen.height > height + 2) (screen.height - height) / 3 else 0;

        const overlay_rect = Rect{ .x = ox, .y = oy, .width = width, .height = height };

        // Fill background
        buf.fill(overlay_rect, Cell.styled(' ', theme.launcher_bg));

        // Draw border
        buf.drawBorder(overlay_rect, .rounded, theme.launcher_border);

        // Title in top border
        const title = " Launch Application ";
        const title_x = ox +| (width -| @as(u16, @intCast(title.len))) / 2;
        _ = buf.writeStr(title_x, oy, title, theme.launcher_title);

        // Input line: "> query_"
        const input_y = oy +| 1;
        _ = buf.writeStr(ox +| 2, input_y, "> ", theme.launcher_input);

        if (self.input_len > 0) {
            _ = buf.writeStr(ox +| 4, input_y, self.input_buf[0..self.input_len], theme.launcher_input);
        }

        // Cursor indicator
        const cursor_x = ox +| 4 +| @as(u16, @intCast(self.input_len));
        buf.setChar(cursor_x, input_y, '_', theme.launcher_input);

        // Separator line
        const sep_y = oy +| 2;
        var sx: u16 = ox +| 1;
        while (sx < ox +| width -| 1) : (sx += 1) {
            buf.setChar(sx, sep_y, 0x2500, theme.launcher_border); // ─
        }

        // Item list
        var item_y = oy +| 3;
        for (0..self.filtered_count) |fi| {
            if (item_y >= oy +| height -| 1) break;

            const app_idx = self.filtered[fi];
            const app = apps[app_idx];
            const is_selected = (fi == self.selected_idx);

            const name_style = if (is_selected) theme.launcher_item_selected else theme.launcher_item;
            const desc_style = if (is_selected) theme.launcher_item_selected else theme.launcher_item_desc;

            // Fill row background if selected
            if (is_selected) {
                buf.fill(
                    Rect{ .x = ox +| 1, .y = item_y, .width = width -| 2, .height = 1 },
                    Cell.styled(' ', theme.launcher_item_selected),
                );
            }

            // Name (left) and description (right)
            _ = buf.writeStr(ox +| 3, item_y, app.name, name_style);

            const desc_x = ox +| width -| @as(u16, @intCast(app.desc.len)) -| 3;
            _ = buf.writeStr(desc_x, item_y, app.desc, desc_style);

            item_y += 1;
        }
    }
};

// ── String helpers ───────────────────────────────────────────────────────────

fn containsInsensitive(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    if (needle.len == 0) return true;

    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        var match = true;
        for (0..needle.len) |j| {
            if (toLower(haystack[i + j]) != toLower(needle[j])) {
                match = false;
                break;
            }
        }
        if (match) return true;
    }
    return false;
}

fn toLower(c: u8) u8 {
    return if (c >= 'A' and c <= 'Z') c + 32 else c;
}
