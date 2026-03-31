//! Display buffer with double-buffering support
//!
//! The buffer holds a grid of cells representing the terminal display.
//! Double-buffering allows efficient differential updates.

const std = @import("std");
const types = @import("types.zig");
const cell_mod = @import("cell.zig");
const color = @import("color.zig");

pub const Cell = cell_mod.Cell;
pub const Color = color.Color;
pub const Style = color.Style;
pub const Size = types.Size;
pub const Rect = types.Rect;
pub const Position = types.Position;
pub const Align = types.Align;
pub const BorderStyle = types.BorderStyle;

/// Display buffer - a 2D grid of cells
pub const Buffer = struct {
    cells: []Cell,
    width: u16,
    height: u16,
    allocator: std.mem.Allocator,

    const Self = @This();

    /// Create a new buffer
    pub fn init(allocator: std.mem.Allocator, width: u16, height: u16) !Self {
        const cell_count = @as(usize, width) * @as(usize, height);
        const cells = try allocator.alloc(Cell, cell_count);
        @memset(cells, Cell.empty);

        return Self{
            .cells = cells,
            .width = width,
            .height = height,
            .allocator = allocator,
        };
    }

    /// Free buffer memory
    pub fn deinit(self: *Self) void {
        self.allocator.free(self.cells);
        self.* = undefined;
    }

    /// Get buffer size
    pub fn size(self: *const Self) Size {
        return .{ .width = self.width, .height = self.height };
    }

    /// Get buffer area as rectangle
    pub fn area(self: *const Self) Rect {
        return .{ .x = 0, .y = 0, .width = self.width, .height = self.height };
    }

    /// Clear entire buffer
    pub fn clear(self: *Self) void {
        @memset(self.cells, Cell.empty);
    }

    /// Clear with specific style
    pub fn clearStyle(self: *Self, style: Style) void {
        const c = Cell{ .char = ' ', .style = style };
        @memset(self.cells, c);
    }

    /// Fill a region with a cell
    pub fn fill(self: *Self, rect: Rect, c: Cell) void {
        const clipped = rect.intersect(self.area());
        if (clipped.isEmpty()) return;

        var y = clipped.y;
        while (y < clipped.bottom()) : (y += 1) {
            const row_start = @as(usize, y) * self.width + clipped.x;
            const row_end = row_start + clipped.width;
            @memset(self.cells[row_start..row_end], c);
        }
    }

    /// Fill a region with style (keep existing characters)
    pub fn fillStyle(self: *Self, rect: Rect, style: Style) void {
        const clipped = rect.intersect(self.area());
        if (clipped.isEmpty()) return;

        var y = clipped.y;
        while (y < clipped.bottom()) : (y += 1) {
            var x = clipped.x;
            while (x < clipped.right()) : (x += 1) {
                const idx = @as(usize, y) * self.width + x;
                self.cells[idx].style = style;
            }
        }
    }

    /// Get cell at position (returns null if out of bounds)
    pub fn get(self: *const Self, x: u16, y: u16) ?Cell {
        if (x >= self.width or y >= self.height) return null;
        return self.cells[@as(usize, y) * self.width + x];
    }

    /// Get mutable cell reference
    pub fn getMut(self: *Self, x: u16, y: u16) ?*Cell {
        if (x >= self.width or y >= self.height) return null;
        return &self.cells[@as(usize, y) * self.width + x];
    }

    /// Set cell at position
    pub fn set(self: *Self, x: u16, y: u16, c: Cell) void {
        if (x >= self.width or y >= self.height) return;
        self.cells[@as(usize, y) * self.width + x] = c;
    }

    /// Set character at position with style
    pub fn setChar(self: *Self, x: u16, y: u16, char: u21, style: Style) void {
        self.set(x, y, Cell.styled(char, style));
    }

    /// Write string at position
    pub fn writeStr(self: *Self, x: u16, y: u16, str: []const u8, style: Style) u16 {
        if (y >= self.height) return 0;

        var cx = x;
        var iter = std.unicode.Utf8Iterator{ .bytes = str, .i = 0 };
        while (iter.nextCodepoint()) |cp| {
            if (cx >= self.width) break;

            const w = cell_mod.charWidth(cp);
            if (w == 0) continue; // Skip zero-width chars for now

            self.set(cx, y, Cell{
                .char = cp,
                .style = style,
                .wide = if (w == 2) .wide else .narrow,
            });
            cx += 1;

            // Handle wide characters
            if (w == 2 and cx < self.width) {
                self.set(cx, y, Cell{
                    .char = 0,
                    .style = style,
                    .wide = .wide_spacer,
                });
                cx += 1;
            }
        }

        return cx - x;
    }

    /// Write string with alignment
    pub fn writeAligned(self: *Self, rect: Rect, str: []const u8, style: Style, align_h: Align) void {
        const clipped = rect.intersect(self.area());
        if (clipped.isEmpty()) return;

        const text_width: u16 = @intCast(@min(cell_mod.stringWidth(str), clipped.width));
        const x_offset: u16 = switch (align_h) {
            .left => 0,
            .center => (clipped.width - text_width) / 2,
            .right => clipped.width - text_width,
        };

        _ = self.writeStr(clipped.x + x_offset, clipped.y, str, style);
    }

    /// Write string with word wrapping within a rectangle
    /// Returns number of lines used
    pub fn writeWrapped(self: *Self, rect: Rect, str: []const u8, style: Style) u16 {
        const clipped = rect.intersect(self.area());
        if (clipped.isEmpty() or clipped.width == 0) return 0;

        var lines_used: u16 = 0;
        var y = clipped.y;
        var remaining = str;

        while (remaining.len > 0 and y < clipped.bottom()) {
            // Find line break point
            var line_end: usize = 0;
            var last_space: ?usize = null;
            var display_width: u16 = 0;

            var iter = std.unicode.Utf8Iterator{ .bytes = remaining, .i = 0 };
            while (iter.nextCodepoint()) |cp| {
                const char_width = cell_mod.charWidth(cp);

                // Check if adding this char exceeds width
                if (display_width + char_width > clipped.width) {
                    // Wrap at last space if available
                    if (last_space) |space_idx| {
                        line_end = space_idx;
                    } else {
                        const cp_len: usize = std.unicode.utf8CodepointSequenceLength(cp) catch 1;
                        line_end = if (iter.i >= cp_len) iter.i - cp_len else 0;
                    }
                    break;
                }

                // Track word boundaries
                if (cp == ' ' or cp == '\t') {
                    last_space = iter.i;
                }

                // Handle explicit newlines
                if (cp == '\n') {
                    line_end = iter.i - 1;
                    break;
                }

                display_width += char_width;
                line_end = iter.i;
            }

            // Write the line
            if (line_end > 0) {
                _ = self.writeStr(clipped.x, y, remaining[0..line_end], style);
            }
            lines_used += 1;
            y += 1;

            // Advance past the line (skip trailing space/newline if present)
            if (line_end < remaining.len) {
                remaining = remaining[line_end..];
                if (remaining.len > 0 and (remaining[0] == ' ' or remaining[0] == '\n')) {
                    remaining = remaining[1..];
                }
            } else {
                break;
            }
        }

        return lines_used;
    }

    /// Write string truncated with ellipsis if too long
    pub fn writeTruncated(self: *Self, x: u16, y: u16, max_width: u16, str: []const u8, style: Style) u16 {
        if (y >= self.height or max_width == 0) return 0;

        const str_width = cell_mod.stringWidth(str);
        if (str_width <= max_width) {
            return self.writeStr(x, y, str, style);
        }

        // Need ellipsis - find truncation point
        const ellipsis = "...";
        const ellipsis_width: u16 = 3;
        if (max_width <= ellipsis_width) {
            return self.writeStr(x, y, ellipsis[0..max_width], style);
        }

        const target_width = max_width - ellipsis_width;
        var display_width: u16 = 0;
        var truncate_at: usize = 0;

        var iter = std.unicode.Utf8Iterator{ .bytes = str, .i = 0 };
        while (iter.nextCodepoint()) |cp| {
            const char_width = cell_mod.charWidth(cp);
            if (display_width + char_width > target_width) break;
            display_width += char_width;
            truncate_at = iter.i;
        }

        var written = self.writeStr(x, y, str[0..truncate_at], style);
        written += self.writeStr(x + written, y, ellipsis, style);
        return written;
    }

    /// Draw horizontal line
    pub fn hLine(self: *Self, x: u16, y: u16, length: u16, char: u21, style: Style) void {
        if (y >= self.height) return;
        const end = @min(x + length, self.width);
        var cx = x;
        while (cx < end) : (cx += 1) {
            self.set(cx, y, Cell.styled(char, style));
        }
    }

    /// Draw vertical line
    pub fn vLine(self: *Self, x: u16, y: u16, length: u16, char: u21, style: Style) void {
        if (x >= self.width) return;
        const end = @min(y + length, self.height);
        var cy = y;
        while (cy < end) : (cy += 1) {
            self.set(x, cy, Cell.styled(char, style));
        }
    }

    /// Draw rectangle border
    pub fn drawBorder(self: *Self, rect: Rect, border: BorderStyle, style: Style) void {
        if (border == .none) return;

        const clipped = rect.intersect(self.area());
        if (clipped.width < 2 or clipped.height < 2) return;

        const chars = border.chars();

        // Corners
        self.set(clipped.x, clipped.y, Cell.styled(chars.top_left, style));
        self.set(clipped.right() - 1, clipped.y, Cell.styled(chars.top_right, style));
        self.set(clipped.x, clipped.bottom() - 1, Cell.styled(chars.bottom_left, style));
        self.set(clipped.right() - 1, clipped.bottom() - 1, Cell.styled(chars.bottom_right, style));

        // Top and bottom edges
        if (clipped.width > 2) {
            self.hLine(clipped.x + 1, clipped.y, clipped.width - 2, chars.horizontal, style);
            self.hLine(clipped.x + 1, clipped.bottom() - 1, clipped.width - 2, chars.horizontal, style);
        }

        // Left and right edges
        if (clipped.height > 2) {
            self.vLine(clipped.x, clipped.y + 1, clipped.height - 2, chars.vertical, style);
            self.vLine(clipped.right() - 1, clipped.y + 1, clipped.height - 2, chars.vertical, style);
        }
    }

    /// Copy from another buffer (with offset)
    pub fn blit(self: *Self, src: *const Buffer, dest_x: u16, dest_y: u16) void {
        var sy: u16 = 0;
        while (sy < src.height and dest_y + sy < self.height) : (sy += 1) {
            var sx: u16 = 0;
            while (sx < src.width and dest_x + sx < self.width) : (sx += 1) {
                const src_cell = src.get(sx, sy) orelse continue;
                self.set(dest_x + sx, dest_y + sy, src_cell);
            }
        }
    }

    /// Resize buffer (allocates new memory)
    pub fn resize(self: *Self, new_width: u16, new_height: u16) !void {
        if (new_width == self.width and new_height == self.height) return;

        const new_size = @as(usize, new_width) * @as(usize, new_height);
        const new_cells = try self.allocator.alloc(Cell, new_size);
        @memset(new_cells, Cell.empty);

        // Copy existing content
        const copy_w = @min(self.width, new_width);
        const copy_h = @min(self.height, new_height);
        var y: u16 = 0;
        while (y < copy_h) : (y += 1) {
            const old_row = @as(usize, y) * self.width;
            const new_row = @as(usize, y) * new_width;
            @memcpy(new_cells[new_row..][0..copy_w], self.cells[old_row..][0..copy_w]);
        }

        self.allocator.free(self.cells);
        self.cells = new_cells;
        self.width = new_width;
        self.height = new_height;
    }

    /// Compare buffers, return iterator of differences
    pub fn diff(self: *const Self, other: *const Self) DiffIterator {
        return DiffIterator.init(self, other);
    }
};

/// Iterator over cell differences between two buffers
pub const DiffIterator = struct {
    current: *const Buffer,
    previous: *const Buffer,
    x: u16,
    y: u16,

    pub fn init(current: *const Buffer, previous: *const Buffer) DiffIterator {
        return .{
            .current = current,
            .previous = previous,
            .x = 0,
            .y = 0,
        };
    }

    pub const DiffCell = struct {
        x: u16,
        y: u16,
        cell: Cell,
    };

    pub fn next(self: *DiffIterator) ?DiffCell {
        while (self.y < self.current.height) {
            while (self.x < self.current.width) {
                const curr = self.current.get(self.x, self.y) orelse Cell.empty;
                const prev = self.previous.get(self.x, self.y) orelse Cell.empty;

                const x = self.x;
                const y = self.y;
                self.x += 1;

                if (!curr.eql(prev)) {
                    return .{ .x = x, .y = y, .cell = curr };
                }
            }
            self.x = 0;
            self.y += 1;
        }
        return null;
    }

    /// Reset iterator
    pub fn reset(self: *DiffIterator) void {
        self.x = 0;
        self.y = 0;
    }
};

test "Buffer basic operations" {
    var buf = try Buffer.init(std.testing.allocator, 10, 5);
    defer buf.deinit();

    try std.testing.expectEqual(@as(u16, 10), buf.width);
    try std.testing.expectEqual(@as(u16, 5), buf.height);

    buf.set(0, 0, Cell.init('A'));
    const c = buf.get(0, 0).?;
    try std.testing.expectEqual(@as(u21, 'A'), c.char);
}

test "Buffer.writeStr" {
    var buf = try Buffer.init(std.testing.allocator, 20, 5);
    defer buf.deinit();

    const written = buf.writeStr(0, 0, "Hello", Style.default);
    try std.testing.expectEqual(@as(u16, 5), written);
    try std.testing.expectEqual(@as(u21, 'H'), buf.get(0, 0).?.char);
    try std.testing.expectEqual(@as(u21, 'o'), buf.get(4, 0).?.char);
}

test "Buffer.diff" {
    var buf1 = try Buffer.init(std.testing.allocator, 5, 5);
    defer buf1.deinit();
    var buf2 = try Buffer.init(std.testing.allocator, 5, 5);
    defer buf2.deinit();

    buf1.set(2, 2, Cell.init('X'));

    var diff = buf1.diff(&buf2);
    const first = diff.next();
    try std.testing.expect(first != null);
    try std.testing.expectEqual(@as(u16, 2), first.?.x);
    try std.testing.expectEqual(@as(u16, 2), first.?.y);
    try std.testing.expectEqual(@as(u21, 'X'), first.?.cell.char);
}
