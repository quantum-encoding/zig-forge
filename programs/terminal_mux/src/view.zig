//! view — encode a pane's terminal state as view-protocol messages
//! (docs/VIEW-PROTOCOL.md). Pure functions over a `Terminal`: no sockets, no
//! PTYs, so every encoding rule is unit-tested here and zterm.zig only
//! decides WHEN to send.
//!
//! zterm is the only emulator. What leaves this file is already-decided
//! state: each cell's character, width, colours and attributes, the cursor,
//! the modes an application asked for. A client never parses VT.

const std = @import("std");
const terminal = @import("terminal.zig");
const config = @import("config.zig");

const Terminal = terminal.Terminal;
const Cell = terminal.Cell;
const CellColor = terminal.CellColor;
const Stringify = std.json.Stringify;

pub const VERSION = 1;

/// What the next frame for one client must include.
pub const FrameArgs = struct {
    pane: u64,
    seq: u64,
    /// Every row, and the client clears first.
    full: bool,
    /// Rows changed since the client's last frame (ignored when `full`).
    dirty: ?*const std.DynamicBitSetUnmanaged,
};

fn attrBits(a: terminal.CellAttrs) u8 {
    return @bitCast(a);
}

fn sameStyle(a: *const Cell, b: *const Cell) bool {
    return a.fg.eql(b.fg) and a.bg.eql(b.bg) and a.attrs.eql(b.attrs);
}

fn isDefaultStyle(c: *const Cell) bool {
    return c.fg == .default and c.bg == .default and c.attrs.eql(terminal.CellAttrs.default);
}

fn charOf(c: *const Cell) u21 {
    return if (c.char == 0) ' ' else c.char;
}

fn writeColor(s: *Stringify, key: []const u8, col: CellColor) !void {
    switch (col) {
        .default => {},
        .indexed => |i| {
            try s.objectField(key);
            try s.write(i);
        },
        .rgb => |rgb| {
            // "#rrggbb", encoded directly: no formatter, so no error path.
            const digits = "0123456789abcdef";
            var buf: [7]u8 = undefined;
            buf[0] = '#';
            for ([_]u8{ rgb.r, rgb.g, rgb.b }, 0..) |byte, i| {
                buf[1 + 2 * i] = digits[byte >> 4];
                buf[2 + 2 * i] = digits[byte & 0xf];
            }
            try s.objectField(key);
            try s.write(@as([]const u8, &buf));
        },
    }
}

fn writeSpan(s: *Stringify, x: usize, text: []const u8, wide: bool, style: *const Cell) !void {
    try s.beginObject();
    try s.objectField("x");
    try s.write(x);
    try s.objectField("text");
    try s.write(text);
    if (wide) {
        try s.objectField("w");
        try s.write(2);
    }
    try writeColor(s, "fg", style.fg);
    try writeColor(s, "bg", style.bg);
    const a = attrBits(style.attrs);
    if (a != 0) {
        try s.objectField("a");
        try s.write(a);
    }
    try s.endObject();
}

/// A row as spans: maximal runs of one style over width-1 cells, each wide
/// cell its own span, continuation cells (width 0) skipped. A run in the
/// default style that is only blanks is omitted (the client clears the row),
/// and trailing blanks of a default-style run are trimmed. Every span carries
/// its own `x`, so a client never accumulates position.
pub fn writeSpans(s: *Stringify, cells: []const Cell, scratch: *std.ArrayList(u8), alloc: std.mem.Allocator) !void {
    try s.beginArray();
    var c: usize = 0;
    while (c < cells.len) {
        const cell = &cells[c];
        if (cell.width == 0) {
            c += 1;
            continue;
        }
        if (cell.width == 2) {
            // A run of double-width characters in one style is ONE span
            // (`w: 2` means every code point in it spans two columns), so a
            // line of CJK costs one span, not one per character. The
            // continuation cells between them (width 0) are stepped over.
            const start = c;
            scratch.clearRetainingCapacity();
            while (c < cells.len) {
                if (cells[c].width == 0) {
                    c += 1;
                    continue;
                }
                if (cells[c].width != 2 or !sameStyle(&cells[c], cell)) break;
                var ub: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(charOf(&cells[c]), &ub) catch 0;
                try scratch.appendSlice(alloc, ub[0..n]);
                c += 1;
            }
            try writeSpan(s, start, scratch.items, true, cell);
            continue;
        }
        // A run: consecutive width-1 cells in this cell's style.
        const start = c;
        scratch.clearRetainingCapacity();
        var last_nonblank: usize = 0; // byte length up to the last non-space
        var any_nonblank = false;
        while (c < cells.len and cells[c].width == 1 and sameStyle(&cells[c], cell)) : (c += 1) {
            var ub: [4]u8 = undefined;
            const ch = charOf(&cells[c]);
            const n = std.unicode.utf8Encode(ch, &ub) catch blk: {
                ub[0] = '?';
                break :blk 1;
            };
            try scratch.appendSlice(alloc, ub[0..n]);
            if (ch != ' ') {
                last_nonblank = scratch.items.len;
                any_nonblank = true;
            }
        }
        if (isDefaultStyle(cell)) {
            // Default blanks are what a cleared row already shows.
            if (!any_nonblank) continue;
            scratch.items.len = last_nonblank;
        }
        // Leading default blanks: start the span at the first visible cell.
        var x = start;
        var text = scratch.items;
        if (isDefaultStyle(cell)) {
            while (text.len > 0 and text[0] == ' ') {
                text = text[1..];
                x += 1;
            }
        }
        try writeSpan(s, x, text, false, cell);
    }
    try s.endArray();
}

fn mouseName(m: terminal.Modes.MouseMode) []const u8 {
    return switch (m) {
        .none => "none",
        .x10 => "x10",
        .normal => "normal",
        .button => "button",
        .any => "any",
    };
}

fn shapeName(shape: u8) []const u8 {
    return switch (shape) {
        1 => "underline",
        2 => "bar",
        else => "block",
    };
}

/// The absolute line number of grid row 0, and of the oldest history line
/// still held — the numbering `zterm_pane_lines` uses, so a selection held
/// against content survives output streaming past it.
pub fn lineRange(term: *const Terminal) struct { live_top: i64, oldest: i64 } {
    const live_top: i64 = @intCast(term.graphics.epoch);
    const held: i64 = if (term.modes.alt_screen) 0 else @intCast(term.scrollback.len);
    return .{ .live_top = live_top, .oldest = live_top - held };
}

fn hex(buf: *[7]u8, col: config.Color) []const u8 {
    const digits = "0123456789abcdef";
    buf[0] = '#';
    for ([_]u8{ col.r, col.g, col.b }, 0..) |byte, i| {
        buf[1 + 2 * i] = digits[byte >> 4];
        buf[2 + 2 * i] = digits[byte & 0xf];
    }
    return buf;
}

/// The colours every index and "default" on the wire resolve to — the theme
/// zterm itself answers OSC 10/11 from, so a client draws exactly what the
/// application was told. `palette` is all 256 entries resolved (0-15 themed,
/// 16-255 the xterm cube/grey ramp); with `bold_is_bright`, a bold cell in
/// colours 0-7 is drawn with 8-15.
pub fn writeTheme(s: *Stringify, theme: *const config.Theme) !void {
    var b: [7]u8 = undefined;
    try s.beginObject();
    inline for (.{ .{ "fg", theme.fg }, .{ "bg", theme.bg }, .{ "cursor", theme.cursor }, .{ "cursor_text", theme.cursor_text } }) |kv| {
        try s.objectField(kv[0]);
        try s.write(hex(&b, kv[1]));
    }
    try s.objectField("bold_is_bright");
    try s.write(theme.bold_is_bright);
    try s.objectField("palette");
    try s.beginArray();
    var i: usize = 0;
    while (i < 256) : (i += 1) {
        const idx: u8 = @intCast(i);
        const col = if (idx < 16) theme.palette[idx] else config.Color.from256(idx);
        try s.write(hex(&b, col));
    }
    try s.endArray();
    try s.endObject();
}

/// The first message on a view connection.
pub fn writeHello(s: *Stringify, pane: u64, theme: *const config.Theme) !void {
    try s.beginObject();
    try s.objectField("t");
    try s.write("hello");
    try s.objectField("v");
    try s.write(VERSION);
    try s.objectField("pane");
    try s.write(pane);
    try s.objectField("theme");
    try writeTheme(s, theme);
    try s.endObject();
}

/// One `frame` message (without the trailing newline).
pub fn writeFrame(s: *Stringify, term: *Terminal, args: FrameArgs, alloc: std.mem.Allocator) !void {
    const grid = term.getCurrentGrid();
    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(alloc);

    try s.beginObject();
    try s.objectField("t");
    try s.write("frame");
    try s.objectField("pane");
    try s.write(args.pane);
    try s.objectField("seq");
    try s.write(args.seq);
    try s.objectField("full");
    try s.write(args.full);
    try s.objectField("rows");
    try s.write(grid.rows);
    try s.objectField("cols");
    try s.write(grid.cols);
    const range = lineRange(term);
    try s.objectField("live_top");
    try s.write(range.live_top);
    try s.objectField("oldest");
    try s.write(range.oldest);

    try s.objectField("lines");
    try s.beginArray();
    var r: u16 = 0;
    while (r < grid.rows) : (r += 1) {
        if (!args.full) {
            const d = args.dirty orelse continue;
            if (r >= d.capacity() or !d.isSet(r)) continue;
        }
        try s.beginObject();
        try s.objectField("y");
        try s.write(r);
        try s.objectField("spans");
        try writeSpans(s, grid.rowSlice(r), &scratch, alloc);
        try s.endObject();
    }
    try s.endArray();

    try s.objectField("cursor");
    try s.beginObject();
    try s.objectField("x");
    try s.write(term.cursor.col);
    try s.objectField("y");
    try s.write(term.cursor.row);
    try s.objectField("visible");
    try s.write(term.modes.cursor_visible);
    try s.objectField("shape");
    try s.write(shapeName(term.cursor_shape));
    try s.objectField("blink");
    try s.write(term.cursor_blink);
    try s.endObject();

    try s.objectField("modes");
    try s.beginObject();
    try s.objectField("app_cursor");
    try s.write(term.modes.app_cursor);
    try s.objectField("bracketed_paste");
    try s.write(term.modes.bracketed_paste);
    try s.objectField("alt_screen");
    try s.write(term.modes.alt_screen);
    try s.objectField("mouse");
    try s.write(mouseName(term.modes.mouse_tracking));
    try s.objectField("mouse_sgr");
    try s.write(term.modes.mouse_sgr);
    try s.objectField("focus");
    try s.write(term.modes.focus_events);
    try s.endObject();

    try s.objectField("title");
    try s.write(term.title[0..term.title_len]);
    try s.endObject();
}

/// A list of OSC 133 marks: `[{"n":line,"k":"A"},{"n":line,"k":"D","exit":0}]`.
fn writeMarkList(s: *Stringify, marks: []const terminal.Mark) !void {
    try s.beginArray();
    for (marks) |m| {
        try s.beginObject();
        try s.objectField("n");
        try s.write(m.line);
        try s.objectField("k");
        const letter = [1]u8{m.kind.letter()};
        try s.write(letter[0..]);
        if (m.exit) |code| {
            try s.objectField("exit");
            try s.write(code);
        }
        try s.endObject();
    }
    try s.endArray();
}

/// One `marks` message: every mark the pane holds on lines `>= from`. The
/// client replaces its own marks from `from` down with these — so one shape
/// carries a new mark (from = its line), a rewrite that dropped marks below
/// it, and the whole set (from = the oldest line held).
pub fn writeMarks(s: *Stringify, term: *const Terminal, pane: u64, from: i64) !void {
    try s.beginObject();
    try s.objectField("t");
    try s.write("marks");
    try s.objectField("pane");
    try s.write(pane);
    try s.objectField("from");
    try s.write(from);
    try s.objectField("marks");
    try writeMarkList(s, term.marksIn(from, std.math.maxInt(i64)));
    try s.endObject();
}

/// One `history` reply: `count` lines from absolute line `from`, as spans.
/// Lines no longer held (or not yet written) are omitted.
pub fn writeHistory(s: *Stringify, term: *Terminal, pane: u64, from: i64, count: usize, alloc: std.mem.Allocator) !void {
    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(alloc);
    const range = lineRange(term);
    const grid = term.getCurrentGrid();

    try s.beginObject();
    try s.objectField("t");
    try s.write("history");
    try s.objectField("pane");
    try s.write(pane);
    try s.objectField("from");
    try s.write(from);
    try s.objectField("count");
    try s.write(count);
    try s.objectField("lines");
    try s.beginArray();
    var i: usize = 0;
    while (i < count) : (i += 1) {
        // `from` is the client's; a line number past the end of i64 is none.
        const n = std.math.add(i64, from, @intCast(i)) catch break;
        const cells: []const Cell = blk: {
            if (n >= range.live_top) {
                const row = n - range.live_top;
                if (row >= grid.rows) break :blk &.{};
                break :blk grid.rowSlice(@intCast(row));
            }
            if (n < range.oldest) break :blk &.{};
            const behind: usize = @intCast(range.live_top - n); // 1 = newest history line
            break :blk term.scrollback.line(term.scrollback.len - behind);
        };
        if (cells.len == 0) continue;
        try s.beginObject();
        try s.objectField("n");
        try s.write(n);
        try s.objectField("spans");
        try writeSpans(s, cells, &scratch, alloc);
        try s.endObject();
    }
    try s.endArray();
    // The OSC 133 marks on the requested lines, so a view that refills its
    // scrollback gets that history's command blocks back with it.
    try s.objectField("marks");
    const until = std.math.add(i64, from, @intCast(count)) catch std.math.maxInt(i64);
    try writeMarkList(s, term.marksIn(from, until));
    try s.endObject();
}

/// Remove every bracketed-paste terminator from `text`, so pasted content can
/// never end the bracket early and have the rest arrive as keystrokes. The
/// server re-brackets. Returns a slice of `buf`.
pub fn stripPasteEnd(text: []const u8, buf: *std.ArrayList(u8), alloc: std.mem.Allocator) ![]const u8 {
    const end = "\x1b[201~";
    buf.clearRetainingCapacity();
    var rest = text;
    while (std.mem.indexOf(u8, rest, end)) |i| {
        try buf.appendSlice(alloc, rest[0..i]);
        rest = rest[i + end.len ..];
    }
    try buf.appendSlice(alloc, rest);
    return buf.items;
}

// ══ tests ══════════════════════════════════════════════════════════════════════════════════════════════

const testing = std.testing;

fn frameOf(term: *Terminal, full: bool, dirty: ?*const std.DynamicBitSetUnmanaged) !std.json.Parsed(std.json.Value) {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    var s: Stringify = .{ .writer = &aw.writer };
    try writeFrame(&s, term, .{ .pane = 3, .seq = 9, .full = full, .dirty = dirty }, testing.allocator);
    return std.json.parseFromSlice(std.json.Value, testing.allocator, aw.written(), .{});
}

/// A terminal driven through the REAL parser (Pane.processOutput), as the
/// vt_tier1 anchors do — no PTY.
const Harness = struct {
    sess: *session.Session,

    fn init(rows: u16, cols: u16) !Harness {
        const rect = session.Rect{ .x = 0, .y = 0, .width = cols, .height = rows };
        return .{ .sess = try session.Session.init(testing.allocator, "view", rect, 100) };
    }
    fn deinit(self: *Harness) void {
        self.sess.deinit();
    }
    fn feed(self: *Harness, bytes: []const u8) void {
        self.sess.getActiveWindow().getActivePane().processOutput(bytes);
    }
    fn term(self: *Harness) *Terminal {
        return &self.sess.getActiveWindow().getActivePane().terminal;
    }
};
const session = @import("session.zig");

fn spansOfRow(frame: std.json.Value, y: i64) ?std.json.Array {
    for (frame.object.get("lines").?.array.items) |line| {
        if (line.object.get("y").?.integer == y) return line.object.get("spans").?.array;
    }
    return null;
}

test "a full frame carries every row, dims, cursor, modes and title" {
    var h = try Harness.init(4, 20);
    defer h.deinit();
    const term = h.term();
    h.feed("hi\r\n\x1b]0;my-title\x07\x1b[?2004h");
    const p = try frameOf(term, true, null);
    defer p.deinit();
    const f = p.value.object;
    try testing.expectEqualStrings("frame", f.get("t").?.string);
    try testing.expectEqual(@as(i64, 3), f.get("pane").?.integer);
    try testing.expectEqual(@as(i64, 9), f.get("seq").?.integer);
    try testing.expectEqual(@as(i64, 4), f.get("rows").?.integer);
    try testing.expectEqual(@as(i64, 20), f.get("cols").?.integer);
    try testing.expectEqual(@as(usize, 4), f.get("lines").?.array.items.len);
    try testing.expectEqualStrings("my-title", f.get("title").?.string);
    try testing.expect(f.get("modes").?.object.get("bracketed_paste").?.bool);
    const cur = f.get("cursor").?.object;
    try testing.expectEqual(@as(i64, 0), cur.get("x").?.integer);
    try testing.expectEqual(@as(i64, 1), cur.get("y").?.integer);
    const row0 = spansOfRow(p.value, 0).?;
    try testing.expectEqual(@as(usize, 1), row0.items.len);
    try testing.expectEqualStrings("hi", row0.items[0].object.get("text").?.string);
    // An empty row is present in a full frame, with no spans.
    try testing.expectEqual(@as(usize, 0), spansOfRow(p.value, 3).?.items.len);
}

test "an incremental frame carries only the dirty rows" {
    var h = try Harness.init(4, 20);
    defer h.deinit();
    const term = h.term();
    var dirty = try std.DynamicBitSetUnmanaged.initEmpty(testing.allocator, 4);
    defer dirty.deinit(testing.allocator);
    dirty.set(2);
    const p = try frameOf(term, false, &dirty);
    defer p.deinit();
    const lines = p.value.object.get("lines").?.array.items;
    try testing.expectEqual(@as(usize, 1), lines.len);
    try testing.expectEqual(@as(i64, 2), lines[0].object.get("y").?.integer);
}

test "colours, attributes and styled spaces become styled spans at their own x" {
    var h = try Harness.init(2, 30);
    defer h.deinit();
    const term = h.term();
    // "ab" default, then bold red "cd", then a green-background space run, then 256-colour and truecolour.
    h.feed("ab\x1b[1;31mcd\x1b[0m\x1b[42m  \x1b[0m\x1b[38;5;200mE\x1b[38;2;1;2;3mF\x1b[0m");
    const p = try frameOf(term, true, null);
    defer p.deinit();
    const spans = spansOfRow(p.value, 0).?.items;
    try testing.expectEqual(@as(usize, 5), spans.len);
    try testing.expectEqualStrings("ab", spans[0].object.get("text").?.string);
    try testing.expect(spans[0].object.get("fg") == null);
    const cd = spans[1].object;
    try testing.expectEqual(@as(i64, 2), cd.get("x").?.integer);
    try testing.expectEqualStrings("cd", cd.get("text").?.string);
    try testing.expectEqual(@as(i64, 1), cd.get("fg").?.integer);
    try testing.expectEqual(@as(i64, 1), cd.get("a").?.integer); // bold
    // A space with a background colour is visible, so it is a span.
    const bg = spans[2].object;
    try testing.expectEqual(@as(i64, 4), bg.get("x").?.integer);
    try testing.expectEqualStrings("  ", bg.get("text").?.string);
    try testing.expectEqual(@as(i64, 2), bg.get("bg").?.integer);
    try testing.expectEqual(@as(i64, 200), spans[3].object.get("fg").?.integer);
    try testing.expectEqualStrings("#010203", spans[4].object.get("fg").?.string);
    try testing.expectEqual(@as(i64, 7), spans[4].object.get("x").?.integer);
}

test "a CJK run is one w:2 span; a style change or a narrow char ends it" {
    var h = try Harness.init(2, 30);
    defer h.deinit();
    const term = h.term();
    h.feed("日本語\x1b[31m中\x1b[0mx文");
    const p = try frameOf(term, true, null);
    defer p.deinit();
    const spans = spansOfRow(p.value, 0).?.items;
    try testing.expectEqual(@as(usize, 4), spans.len);
    try testing.expectEqualStrings("日本語", spans[0].object.get("text").?.string);
    try testing.expectEqual(@as(i64, 2), spans[0].object.get("w").?.integer);
    try testing.expectEqual(@as(i64, 0), spans[0].object.get("x").?.integer);
    // Red 中 starts at column 6 — three wide chars took six columns.
    try testing.expectEqualStrings("中", spans[1].object.get("text").?.string);
    try testing.expectEqual(@as(i64, 6), spans[1].object.get("x").?.integer);
    try testing.expectEqual(@as(i64, 1), spans[1].object.get("fg").?.integer);
    try testing.expectEqualStrings("x", spans[2].object.get("text").?.string);
    try testing.expect(spans[2].object.get("w") == null);
    try testing.expectEqual(@as(i64, 9), spans[3].object.get("x").?.integer);
}

test "combining marks are dropped: every code point in a span is a column" {
    var h = try Harness.init(2, 20);
    defer h.deinit();
    const term = h.term();
    h.feed("e\u{0301}x"); // e + COMBINING ACUTE, then x
    const p = try frameOf(term, true, null);
    defer p.deinit();
    const spans = spansOfRow(p.value, 0).?.items;
    try testing.expectEqualStrings("ex", spans[0].object.get("text").?.string);
}

test "hello carries the theme: defaults, cursor and all 256 colours resolved" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    var s: Stringify = .{ .writer = &aw.writer };
    var theme: config.Theme = .{};
    theme.fg = config.Color.fromRgb(1, 2, 3);
    theme.palette[1] = config.Color.fromRgb(0xab, 0, 0);
    try writeHello(&s, 7, &theme);
    const p = try std.json.parseFromSlice(std.json.Value, testing.allocator, aw.written(), .{});
    defer p.deinit();
    const t = p.value.object.get("theme").?.object;
    try testing.expectEqualStrings("#010203", t.get("fg").?.string);
    const pal = t.get("palette").?.array.items;
    try testing.expectEqual(@as(usize, 256), pal.len);
    try testing.expectEqualStrings("#ab0000", pal[1].string);
    // 16-255 are the fixed cube/grey ramp: 196 is pure red, 231 white, 232 near-black.
    try testing.expectEqualStrings("#ff0000", pal[196].string);
    try testing.expectEqualStrings("#ffffff", pal[231].string);
    try testing.expectEqualStrings("#080808", pal[232].string);
    try testing.expect(t.get("bold_is_bright").?.bool);
}

test "wide characters keep every following column where it belongs" {
    var h = try Harness.init(2, 20);
    defer h.deinit();
    const term = h.term();
    h.feed("a日本b");
    const p = try frameOf(term, true, null);
    defer p.deinit();
    const spans = spansOfRow(p.value, 0).?.items;
    try testing.expectEqual(@as(usize, 3), spans.len);
    try testing.expectEqualStrings("a", spans[0].object.get("text").?.string);
    try testing.expectEqualStrings("日本", spans[1].object.get("text").?.string);
    try testing.expectEqual(@as(i64, 2), spans[1].object.get("w").?.integer);
    try testing.expectEqual(@as(i64, 1), spans[1].object.get("x").?.integer);
    // 'b' lands at column 5: two wide characters took four columns.
    try testing.expectEqualStrings("b", spans[2].object.get("text").?.string);
    try testing.expectEqual(@as(i64, 5), spans[2].object.get("x").?.integer);
}

test "leading and trailing default blanks are not sent; inner ones are" {
    var h = try Harness.init(2, 20);
    defer h.deinit();
    const term = h.term();
    h.feed("   x y   ");
    const p = try frameOf(term, true, null);
    defer p.deinit();
    const spans = spansOfRow(p.value, 0).?.items;
    try testing.expectEqual(@as(usize, 1), spans.len);
    try testing.expectEqual(@as(i64, 3), spans[0].object.get("x").?.integer);
    try testing.expectEqualStrings("x y", spans[0].object.get("text").?.string);
}

test "modes report mouse, app cursor, alt screen and cursor style" {
    var h = try Harness.init(3, 10);
    defer h.deinit();
    const term = h.term();
    h.feed("\x1b[?1h\x1b[?1002h\x1b[?1006h\x1b[?1049h\x1b[5 q\x1b[?25l");
    const p = try frameOf(term, true, null);
    defer p.deinit();
    const m = p.value.object.get("modes").?.object;
    try testing.expect(m.get("app_cursor").?.bool);
    try testing.expectEqualStrings("button", m.get("mouse").?.string);
    try testing.expect(m.get("mouse_sgr").?.bool);
    try testing.expect(m.get("alt_screen").?.bool);
    const cur = p.value.object.get("cursor").?.object;
    try testing.expectEqualStrings("bar", cur.get("shape").?.string);
    try testing.expect(cur.get("blink").?.bool);
    try testing.expect(!cur.get("visible").?.bool);
    // On the alternate screen there is no history.
    try testing.expectEqual(p.value.object.get("live_top").?.integer, p.value.object.get("oldest").?.integer);
}

test "history returns lines by absolute number, omitting what is not held" {
    var h = try Harness.init(2, 10);
    defer h.deinit();
    const term = h.term();
    h.feed("one\r\ntwo\r\nthree\r\nfour");
    const range = lineRange(term);
    try testing.expect(range.oldest < range.live_top);
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    var s: Stringify = .{ .writer = &aw.writer };
    try writeHistory(&s, term, 3, range.oldest - 5, 20, testing.allocator);
    const p = try std.json.parseFromSlice(std.json.Value, testing.allocator, aw.written(), .{});
    defer p.deinit();
    const lines = p.value.object.get("lines").?.array.items;
    // Exactly the held history plus the two live rows; nothing before `oldest`.
    try testing.expectEqual(@as(i64, range.oldest), lines[0].object.get("n").?.integer);
    try testing.expectEqualStrings("one", lines[0].object.get("spans").?.array.items[0].object.get("text").?.string);
    const last = lines[lines.len - 1].object;
    try testing.expectEqual(range.live_top + 1, last.get("n").?.integer);
    try testing.expectEqualStrings("four", last.get("spans").?.array.items[0].object.get("text").?.string);
}

test "a paste can never close its own bracket" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    try testing.expectEqualStrings("ab", try stripPasteEnd("a\x1b[201~b", &buf, testing.allocator));
    try testing.expectEqualStrings("plain", try stripPasteEnd("plain", &buf, testing.allocator));
    try testing.expectEqualStrings("", try stripPasteEnd("\x1b[201~\x1b[201~", &buf, testing.allocator));
}

// ── OSC 133 marks ─────────────────────────────────────────────────────────────

fn marksOf(term: *Terminal, from: i64) !std.json.Parsed(std.json.Value) {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    var s: Stringify = .{ .writer = &aw.writer };
    try writeMarks(&s, term, 3, from);
    return std.json.parseFromSlice(std.json.Value, testing.allocator, aw.written(), .{});
}

fn expectMark(m: std.json.Value, n: i64, k: []const u8, exit: ?i64) !void {
    try testing.expectEqual(n, m.object.get("n").?.integer);
    try testing.expectEqualStrings(k, m.object.get("k").?.string);
    if (exit) |e| {
        try testing.expectEqual(e, m.object.get("exit").?.integer);
    } else try testing.expect(m.object.get("exit") == null);
}

test "OSC 133 marks land on the absolute line of the cursor, BEL or ST terminated" {
    var h = try Harness.init(3, 20);
    defer h.deinit();
    const term = h.term();
    // Prompt on line 0, command, output on line 1..3 (scrolls one line off),
    // then D;7 + the next prompt on line 4.
    h.feed("\x1b]133;A\x07$ \x1b]133;B\x07ls\r\n\x1b]133;C\x1b\\a\r\nb\r\nc\r\n\x1b]133;D;7\x07\x1b]133;A;aid=9\x07$ ");
    const range = lineRange(term);
    try testing.expectEqual(@as(i64, 2), range.live_top);
    const p = try marksOf(term, range.oldest);
    defer p.deinit();
    try testing.expectEqualStrings("marks", p.value.object.get("t").?.string);
    try testing.expectEqual(@as(i64, 3), p.value.object.get("pane").?.integer);
    try testing.expectEqual(@as(i64, 0), p.value.object.get("from").?.integer);
    const ms = p.value.object.get("marks").?.array.items;
    try testing.expectEqual(@as(usize, 5), ms.len);
    try expectMark(ms[0], 0, "A", null);
    try expectMark(ms[1], 0, "B", null);
    try expectMark(ms[2], 1, "C", null);
    try expectMark(ms[3], 4, "D", 7);
    try expectMark(ms[4], 4, "A", null);
    // A tail from line 4 carries only that line's marks.
    const tail = try marksOf(term, 4);
    defer tail.deinit();
    try testing.expectEqual(@as(usize, 2), tail.value.object.get("marks").?.array.items.len);
    // No trailing backslash from the ST form reached the grid.
    try testing.expectEqual(@as(u21, 'a'), term.scrollback.line(1)[0].char);
}

test "a D with no status, an unknown letter and the alternate screen record nothing extra" {
    var h = try Harness.init(4, 20);
    defer h.deinit();
    const term = h.term();
    h.feed("\x1b]133;D\x07\x1b]133;Z\x07\x1b]133;AB\x07\x1b[?1049h\x1b]133;A\x07\x1b[?1049l");
    try testing.expectEqual(@as(usize, 1), term.marks.items.len);
    try testing.expectEqual(terminal.Mark.Kind.done, term.marks.items[0].kind);
    try testing.expectEqual(@as(?i32, null), term.marks.items[0].exit);
}

test "a mark written above held ones drops the stale ones below it" {
    var h = try Harness.init(6, 20);
    defer h.deinit();
    const term = h.term();
    h.feed("\x1b]133;A\x07$ ls\r\n\x1b]133;C\x07out\r\n\x1b]133;D;0\x07\x1b]133;A\x07$ ");
    try testing.expectEqual(@as(usize, 4), term.marks.items.len);
    _ = term.takeMarksTouched();
    // `clear`: home and erase, then the shell's D + A on row 0 again.
    h.feed("\x1b[H\x1b[2J\x1b]133;D;0\x07\x1b]133;A\x07$ ");
    try testing.expectEqual(@as(usize, 1), term.marks.items.len);
    try testing.expectEqual(@as(i64, 0), term.marks.items[0].line);
    try testing.expectEqual(terminal.Mark.Kind.prompt, term.marks.items[0].kind);
    try testing.expectEqual(@as(?i64, 0), term.takeMarksTouched());
}

test "marks are pruned with the scrollback they point into" {
    var h = try Harness.init(2, 10);
    defer h.deinit();
    const term = h.term();
    h.feed("\x1b]133;A\x07first\r\n");
    try testing.expectEqual(@as(usize, 1), term.marks.items.len);
    // Harness scrollback holds 100 lines: push line 0 out of it.
    var i: usize = 0;
    while (i < 101) : (i += 1) h.feed("x\r\n");
    try testing.expect(lineRange(term).oldest > 0);
    try testing.expectEqual(@as(usize, 0), term.marks.items.len);
    // ED 3 clears the scrollback, and the marks in it.
    h.feed("\x1b]133;A\x07p\r\n\r\n\r\n\x1b[3J");
    try testing.expectEqual(@as(usize, 0), term.marks.items.len);
}

test "a history reply carries the marks of the lines it covers" {
    var h = try Harness.init(2, 10);
    defer h.deinit();
    const term = h.term();
    h.feed("\x1b]133;A\x07one\r\n\x1b]133;C\x07two\r\nthree\r\n\x1b]133;D;1\x07");
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    var s: Stringify = .{ .writer = &aw.writer };
    try writeHistory(&s, term, 3, 1, 2, testing.allocator);
    const p = try std.json.parseFromSlice(std.json.Value, testing.allocator, aw.written(), .{});
    defer p.deinit();
    try testing.expectEqual(@as(i64, 2), p.value.object.get("count").?.integer);
    const ms = p.value.object.get("marks").?.array.items;
    try testing.expectEqual(@as(usize, 1), ms.len);
    try expectMark(ms[0], 1, "C", null);
    // A range past the end of i64 is empty, not a crash.
    aw.clearRetainingCapacity();
    s = .{ .writer = &aw.writer };
    try writeHistory(&s, term, 3, std.math.maxInt(i64) - 1, 50, testing.allocator);
}

test "the mark list is bounded, keeping the newest" {
    var h = try Harness.init(4, 10);
    defer h.deinit();
    const term = h.term();
    var i: usize = 0;
    while (i < terminal.MAX_MARKS + 10) : (i += 1) {
        term.recordMark(if (i % 2 == 0) .prompt else .done, @intCast(i));
        term.cursor.row = @intCast((i + 1) % 2); // alternate lines so none replaces another
        if (i % 2 == 1) term.graphics.epoch += 1;
    }
    try testing.expectEqual(terminal.MAX_MARKS, term.marks.items.len);
    try testing.expectEqual(@as(?i32, @intCast(terminal.MAX_MARKS + 9)), term.marks.items[terminal.MAX_MARKS - 1].exit);
}
