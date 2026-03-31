/// Minimal TUI types for Zigix freestanding builds.
/// Mirrors the subset of zig_tui types used by the desktop, without libc deps.
/// On Linux builds, the real zig_tui is used instead — this file is never compiled.

pub const Size = struct { width: u16, height: u16 };
pub const Rect = struct { x: u16, y: u16, width: u16, height: u16 };
pub const Position = struct { x: u16, y: u16 };

pub const Color = struct {
    r: u8 = 0,
    g: u8 = 0,
    b: u8 = 0,
    kind: enum { default, rgb, indexed } = .default,

    pub fn fromRgb(r: u8, g: u8, b: u8) Color {
        return .{ .r = r, .g = g, .b = b, .kind = .rgb };
    }
    pub fn from256(idx: u8) Color {
        _ = idx;
        return .{ .kind = .indexed };
    }
    pub const black = Color{ .kind = .default };
};

pub const Attrs = struct {
    bold: bool = false,
    dim: bool = false,
    italic: bool = false,
    underline: bool = false,
    blink: bool = false,
    reverse: bool = false,
    hidden: bool = false,
    strikethrough: bool = false,
};

pub const Style = struct {
    fg: Color = .{},
    bg: Color = .{},
    attrs: Attrs = .{},
    pub const default = Style{};
};

pub const Cell = struct {
    char: u21 = ' ',
    style: Style = .{},

    pub fn styled(ch: u21, style: Style) Cell {
        return .{ .char = ch, .style = style };
    }
};

pub const Buffer = struct {
    cells: []Cell,
    width: u16,
    height: u16,
    allocator: @import("std").mem.Allocator,

    pub fn init(allocator: @import("std").mem.Allocator, w: u16, h: u16) !Buffer {
        const cells = try allocator.alloc(Cell, @as(usize, w) * h);
        for (cells) |*c| c.* = .{};
        return .{ .cells = cells, .width = w, .height = h, .allocator = allocator };
    }

    pub fn deinit(self: *Buffer) void {
        self.allocator.free(self.cells);
    }

    pub fn get(self: *const Buffer, x: u16, y: u16) ?Cell {
        if (x >= self.width or y >= self.height) return null;
        return self.cells[@as(usize, y) * self.width + x];
    }

    pub fn getMut(self: *Buffer, x: u16, y: u16) ?*Cell {
        if (x >= self.width or y >= self.height) return null;
        return &self.cells[@as(usize, y) * self.width + x];
    }

    pub fn set(self: *Buffer, x: u16, y: u16, cell: Cell) void {
        if (x >= self.width or y >= self.height) return;
        self.cells[@as(usize, y) * self.width + x] = cell;
    }

    pub fn setChar(self: *Buffer, x: u16, y: u16, ch: u21, style: Style) void {
        self.set(x, y, Cell.styled(ch, style));
    }

    pub fn clearStyle(self: *Buffer, style: Style) void {
        for (self.cells) |*c| {
            c.* = Cell.styled(' ', style);
        }
    }

    pub fn fill(self: *Buffer, rect: Rect, cell: Cell) void {
        var y: u16 = rect.y;
        while (y < rect.y +| rect.height) : (y += 1) {
            var x: u16 = rect.x;
            while (x < rect.x +| rect.width) : (x += 1) {
                self.set(x, y, cell);
            }
        }
    }

    pub fn writeStr(self: *Buffer, x: u16, y: u16, str: []const u8, style: Style) u16 {
        var cx = x;
        for (str) |ch| {
            if (cx >= self.width) break;
            self.setChar(cx, y, ch, style);
            cx += 1;
        }
        return cx - x;
    }

    pub fn drawBorder(self: *Buffer, rect: Rect, _: anytype, style: Style) void {
        // Simple box drawing
        self.setChar(rect.x, rect.y, 0x256D, style); // ╭
        self.setChar(rect.x +| rect.width -| 1, rect.y, 0x256E, style); // ╮
        self.setChar(rect.x, rect.y +| rect.height -| 1, 0x2570, style); // ╰
        self.setChar(rect.x +| rect.width -| 1, rect.y +| rect.height -| 1, 0x256F, style); // ╯

        var i: u16 = 1;
        while (i < rect.width -| 1) : (i += 1) {
            self.setChar(rect.x +| i, rect.y, 0x2500, style);
            self.setChar(rect.x +| i, rect.y +| rect.height -| 1, 0x2500, style);
        }
        var j: u16 = 1;
        while (j < rect.height -| 1) : (j += 1) {
            self.setChar(rect.x, rect.y +| j, 0x2502, style);
            self.setChar(rect.x +| rect.width -| 1, rect.y +| j, 0x2502, style);
        }
    }
};

// Event types (simplified for pure mode)
pub const Modifiers = struct { ctrl: bool = false, alt: bool = false, shift: bool = false };
pub const Key = enum { enter, tab, backspace, escape, up, down, left, right, home, end, page_up, page_down, insert, delete, f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12, char };
pub const KeyEvent = struct { key: union(enum) { char: u21, special: Key }, modifiers: Modifiers = .{} };
pub const MouseEvent = struct {};
pub const ResizeEvent = struct { width: u16, height: u16 };
pub const Event = union(enum) { key: KeyEvent, mouse: MouseEvent, resize: ResizeEvent, tick: void };

pub const BorderStyle = enum { rounded, single, double, heavy };

// No Application type in pure mode — main.zig has its own loop
