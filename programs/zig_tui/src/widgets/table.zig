//! Table widget - data table with columns and selection
//!
//! Displays tabular data with headers, scrolling, and row selection.

const std = @import("std");
const core = @import("../core/core.zig");
const widget_mod = @import("../widget/mod.zig");
const input_mod = @import("../input/input.zig");

pub const Buffer = core.Buffer;
pub const Rect = core.Rect;
pub const Size = core.Size;
pub const Style = core.Style;
pub const Color = core.Color;
pub const Cell = core.Cell;
pub const BorderStyle = core.BorderStyle;
pub const Widget = widget_mod.Widget;
pub const makeWidget = widget_mod.makeWidget;
pub const Event = input_mod.Event;
pub const Key = input_mod.Key;

/// Column width specification
pub const ColumnWidth = union(enum) {
    fixed: u16,
    min: u16, // Minimum width, expands to fill
    percent: u8, // Percentage of available width
    auto, // Size to content
};

/// Column definition
pub const Column = struct {
    header: []const u8,
    width: ColumnWidth = .auto,
    alignment: Alignment = .left,
};

/// Text alignment
pub const Alignment = enum {
    left,
    center,
    right,
};

/// Table row data
pub const Row = struct {
    cells: []const []const u8,
    enabled: bool = true,
    data: ?*anyopaque = null,
};

/// Callback when selection changes
pub const SelectCallback = *const fn (*Table, usize) void;

/// Callback when row is activated
pub const ActivateCallback = *const fn (*Table, usize) void;

/// Table widget
pub const Table = struct {
    columns: []const Column,
    rows: []const Row,
    selected: usize,
    scroll_offset: usize,

    // Styles
    header_style: Style,
    row_style: Style,
    selected_style: Style,
    disabled_style: Style,
    border_style: Style,

    // Options
    show_header: bool,
    show_borders: bool,
    show_row_numbers: bool,
    highlight_full_row: bool,

    // Callbacks
    on_select: ?SelectCallback,
    on_activate: ?ActivateCallback,

    // State
    focused: bool,
    visible_height: u16,
    column_widths: [16]u16, // Computed column widths

    const Self = @This();

    /// Get Widget interface
    pub fn widget(self: *Self) Widget {
        return makeWidget(Self, self);
    }

    /// Create a new table
    pub fn init(columns: []const Column, rows: []const Row) Self {
        return .{
            .columns = columns,
            .rows = rows,
            .selected = 0,
            .scroll_offset = 0,
            .header_style = Style{ .fg = Color.black, .bg = Color.white, .attrs = .{ .bold = true } },
            .row_style = Style{ .fg = Color.white },
            .selected_style = Style.init(Color.black, Color.cyan),
            .disabled_style = Style{ .fg = Color.gray },
            .border_style = Style{ .fg = Color.gray },
            .show_header = true,
            .show_borders = true,
            .show_row_numbers = false,
            .highlight_full_row = true,
            .on_select = null,
            .on_activate = null,
            .focused = false,
            .visible_height = 10,
            .column_widths = [_]u16{0} ** 16,
        };
    }

    /// Set rows data
    pub fn setRows(self: *Self, rows: []const Row) *Self {
        self.rows = rows;
        if (self.selected >= rows.len and rows.len > 0) {
            self.selected = rows.len - 1;
        }
        self.scroll_offset = 0;
        return self;
    }

    /// Set header style
    pub fn setHeaderStyle(self: *Self, style: Style) *Self {
        self.header_style = style;
        return self;
    }

    /// Set selected style
    pub fn setSelectedStyle(self: *Self, style: Style) *Self {
        self.selected_style = style;
        return self;
    }

    /// Show/hide header
    pub fn setShowHeader(self: *Self, show: bool) *Self {
        self.show_header = show;
        return self;
    }

    /// Show/hide borders
    pub fn setShowBorders(self: *Self, show: bool) *Self {
        self.show_borders = show;
        return self;
    }

    /// Set selection callback
    pub fn onSelect(self: *Self, callback: SelectCallback) *Self {
        self.on_select = callback;
        return self;
    }

    /// Set activation callback
    pub fn onActivate(self: *Self, callback: ActivateCallback) *Self {
        self.on_activate = callback;
        return self;
    }

    /// Get selected row index
    pub fn getSelected(self: *const Self) usize {
        return self.selected;
    }

    /// Get selected row
    pub fn getSelectedRow(self: *const Self) ?Row {
        if (self.selected < self.rows.len) {
            return self.rows[self.selected];
        }
        return null;
    }

    /// Set selected row
    pub fn select(self: *Self, index: usize) void {
        if (index < self.rows.len) {
            self.selected = index;
            self.ensureVisible();
            if (self.on_select) |cb| cb(self, index);
        }
    }

    /// Move selection up
    pub fn selectPrev(self: *Self) void {
        if (self.rows.len == 0) return;
        if (self.selected > 0) {
            self.selected -= 1;
            self.ensureVisible();
            if (self.on_select) |cb| cb(self, self.selected);
        }
    }

    /// Move selection down
    pub fn selectNext(self: *Self) void {
        if (self.rows.len == 0) return;
        if (self.selected < self.rows.len - 1) {
            self.selected += 1;
            self.ensureVisible();
            if (self.on_select) |cb| cb(self, self.selected);
        }
    }

    /// Page up
    pub fn pageUp(self: *Self) void {
        if (self.rows.len == 0) return;
        if (self.selected > self.visible_height) {
            self.selected -= self.visible_height;
        } else {
            self.selected = 0;
        }
        self.ensureVisible();
        if (self.on_select) |cb| cb(self, self.selected);
    }

    /// Page down
    pub fn pageDown(self: *Self) void {
        if (self.rows.len == 0) return;
        self.selected += self.visible_height;
        if (self.selected >= self.rows.len) {
            self.selected = self.rows.len - 1;
        }
        self.ensureVisible();
        if (self.on_select) |cb| cb(self, self.selected);
    }

    /// Move to first row
    pub fn selectFirst(self: *Self) void {
        if (self.rows.len == 0) return;
        self.selected = 0;
        self.ensureVisible();
        if (self.on_select) |cb| cb(self, self.selected);
    }

    /// Move to last row
    pub fn selectLast(self: *Self) void {
        if (self.rows.len == 0) return;
        self.selected = self.rows.len - 1;
        self.ensureVisible();
        if (self.on_select) |cb| cb(self, self.selected);
    }

    fn ensureVisible(self: *Self) void {
        if (self.selected < self.scroll_offset) {
            self.scroll_offset = self.selected;
        } else if (self.selected >= self.scroll_offset + self.visible_height) {
            self.scroll_offset = self.selected - self.visible_height + 1;
        }
    }

    /// Compute column widths based on available space
    fn computeColumnWidths(self: *Self, available_width: u16) void {
        if (self.columns.len == 0) return;

        const col_count: u16 = @intCast(@min(self.columns.len, 16));
        const separator_width: u16 = if (self.show_borders) col_count + 1 else col_count - 1;
        const content_width = if (available_width > separator_width) available_width - separator_width else 0;

        var fixed_width: u16 = 0;
        var flex_count: u16 = 0;

        // First pass: calculate fixed widths and count flex columns
        for (self.columns[0..col_count], 0..) |col, i| {
            switch (col.width) {
                .fixed => |w| {
                    self.column_widths[i] = w;
                    fixed_width += w;
                },
                .min => |w| {
                    self.column_widths[i] = w;
                    fixed_width += w;
                    flex_count += 1;
                },
                .percent => |p| {
                    const w: u16 = @intCast((content_width * @as(u32, p)) / 100);
                    self.column_widths[i] = w;
                    fixed_width += w;
                },
                .auto => {
                    // Calculate based on header and content
                    var max_width: u16 = @intCast(col.header.len);
                    for (self.rows) |row| {
                        if (i < row.cells.len) {
                            max_width = @max(max_width, @as(u16, @intCast(row.cells[i].len)));
                        }
                    }
                    self.column_widths[i] = @min(max_width, 30); // Cap at 30
                    fixed_width += self.column_widths[i];
                    flex_count += 1;
                },
            }
        }

        // Second pass: distribute remaining space to flex columns
        if (flex_count > 0 and content_width > fixed_width) {
            const extra = (content_width - fixed_width) / flex_count;
            for (self.columns[0..col_count], 0..) |col, i| {
                switch (col.width) {
                    .min, .auto => {
                        self.column_widths[i] += extra;
                    },
                    else => {},
                }
            }
        }
    }

    // Widget interface

    pub fn render(self: *Self, area: Rect, buf: *Buffer, state: Widget.RenderState) void {
        if (area.isEmpty()) return;

        self.focused = state.focused;
        self.computeColumnWidths(area.width);

        var y: u16 = area.y;

        // Render header
        if (self.show_header) {
            self.renderHeader(buf, area.x, y, area.width);
            y += 1;

            // Header separator
            if (self.show_borders) {
                self.renderSeparator(buf, area.x, y, area.width, '─');
                y += 1;
            }
        }

        // Calculate visible height for rows
        self.visible_height = if (area.height > (y - area.y)) area.height - (y - area.y) else 0;

        // Render rows
        var row_y: u16 = 0;
        while (row_y < self.visible_height) : (row_y += 1) {
            const row_idx = self.scroll_offset + row_y;
            if (row_idx >= self.rows.len) break;

            self.renderRow(buf, area.x, y + row_y, area.width, row_idx, state.focused);
        }
    }

    fn renderHeader(self: *Self, buf: *Buffer, x: u16, y: u16, width: u16) void {
        var cx = x;

        if (self.show_borders) {
            buf.setChar(cx, y, '│', self.border_style);
            cx += 1;
        }

        const col_count = @min(self.columns.len, 16);
        for (self.columns[0..col_count], 0..) |col, i| {
            const col_width = self.column_widths[i];

            // Fill background
            buf.fill(
                Rect{ .x = cx, .y = y, .width = col_width, .height = 1 },
                Cell.styled(' ', self.header_style),
            );

            // Write header text
            _ = buf.writeTruncated(cx, y, col_width, col.header, self.header_style);
            cx += col_width;

            // Column separator
            if (self.show_borders or i < col_count - 1) {
                buf.setChar(cx, y, '│', self.border_style);
                cx += 1;
            }

            if (cx >= x + width) break;
        }
    }

    fn renderSeparator(self: *Self, buf: *Buffer, x: u16, y: u16, width: u16, char: u21) void {
        var cx = x;

        if (self.show_borders) {
            buf.setChar(cx, y, '├', self.border_style);
            cx += 1;
        }

        const col_count = @min(self.columns.len, 16);
        for (0..col_count) |i| {
            const col_width = self.column_widths[i];
            buf.hLine(cx, y, col_width, char, self.border_style);
            cx += col_width;

            if (self.show_borders or i < col_count - 1) {
                const sep_char: u21 = if (self.show_borders) '┼' else '┬';
                buf.setChar(cx, y, sep_char, self.border_style);
                cx += 1;
            }

            if (cx >= x + width) break;
        }

        if (self.show_borders) {
            buf.setChar(cx - 1, y, '┤', self.border_style);
        }
    }

    fn renderRow(self: *Self, buf: *Buffer, x: u16, y: u16, width: u16, row_idx: usize, focused: bool) void {
        const row = self.rows[row_idx];
        const is_selected = row_idx == self.selected;

        const row_style = if (!row.enabled)
            self.disabled_style
        else if (is_selected and focused)
            self.selected_style
        else
            self.row_style;

        var cx = x;

        if (self.show_borders) {
            buf.setChar(cx, y, '│', self.border_style);
            cx += 1;
        }

        const col_count = @min(self.columns.len, 16);
        for (0..col_count) |i| {
            const col_width = self.column_widths[i];

            // Fill background for selected row
            if (self.highlight_full_row and is_selected and focused) {
                buf.fill(
                    Rect{ .x = cx, .y = y, .width = col_width, .height = 1 },
                    Cell.styled(' ', row_style),
                );
            }

            // Get cell content
            const cell_text = if (i < row.cells.len) row.cells[i] else "";

            // Write cell with alignment
            const text_len: u16 = @intCast(@min(cell_text.len, col_width));
            const align_offset: u16 = switch (self.columns[i].alignment) {
                .left => 0,
                .center => (col_width - text_len) / 2,
                .right => col_width - text_len,
            };

            _ = buf.writeTruncated(cx + align_offset, y, col_width - align_offset, cell_text, row_style);
            cx += col_width;

            // Column separator
            if (self.show_borders or i < col_count - 1) {
                buf.setChar(cx, y, '│', self.border_style);
                cx += 1;
            }

            if (cx >= x + width) break;
        }
    }

    pub fn handleEvent(self: *Self, event: Event) bool {
        switch (event) {
            .key => |k| {
                switch (k.key) {
                    .special => |s| switch (s) {
                        .up => {
                            self.selectPrev();
                            return true;
                        },
                        .down => {
                            self.selectNext();
                            return true;
                        },
                        .page_up => {
                            self.pageUp();
                            return true;
                        },
                        .page_down => {
                            self.pageDown();
                            return true;
                        },
                        .home => {
                            self.selectFirst();
                            return true;
                        },
                        .end => {
                            self.selectLast();
                            return true;
                        },
                        .enter => {
                            if (self.on_activate) |cb| cb(self, self.selected);
                            return true;
                        },
                        else => {},
                    },
                    .char => {},
                }
            },
            .mouse => |m| {
                if (m.kind == .press and m.button == .left) {
                    // Calculate which row was clicked
                    const header_offset: u16 = if (self.show_header)
                        (if (self.show_borders) @as(u16, 2) else @as(u16, 1))
                    else
                        0;
                    if (m.y >= header_offset) {
                        const clicked_idx = self.scroll_offset + (m.y - header_offset);
                        if (clicked_idx < self.rows.len) {
                            self.select(clicked_idx);
                            return true;
                        }
                    }
                } else if (m.kind == .scroll_up) {
                    if (self.scroll_offset > 0) {
                        self.scroll_offset -= 1;
                    }
                    return true;
                } else if (m.kind == .scroll_down) {
                    if (self.scroll_offset + self.visible_height < self.rows.len) {
                        self.scroll_offset += 1;
                    }
                    return true;
                }
            },
            else => {},
        }
        return false;
    }

    pub fn minSize(self: *Self) Size {
        var total_width: u16 = 0;
        for (self.columns) |col| {
            total_width += switch (col.width) {
                .fixed => |w| w,
                .min => |w| w,
                else => 10,
            };
        }
        return .{
            .width = total_width + @as(u16, @intCast(self.columns.len)) + 1,
            .height = if (self.show_header) 4 else 2,
        };
    }

    pub fn canFocus(self: *Self) bool {
        return self.rows.len > 0;
    }
};

test "Table basic" {
    const columns = [_]Column{
        .{ .header = "Name" },
        .{ .header = "Value" },
    };
    const rows = [_]Row{
        .{ .cells = &[_][]const u8{ "Foo", "123" } },
        .{ .cells = &[_][]const u8{ "Bar", "456" } },
    };
    var table = Table.init(&columns, &rows);
    try std.testing.expectEqual(@as(usize, 0), table.getSelected());

    table.selectNext();
    try std.testing.expectEqual(@as(usize, 1), table.getSelected());
}
