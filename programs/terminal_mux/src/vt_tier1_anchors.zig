//! Tier-1 externally-anchored VT conformance tests.
//!
//! Golden-rule compliance (repo CLAUDE.md): inputs AND expected outputs come
//! from sources we didn't write —
//!   [esctest]  George Nachman's esctest suite (github.com/gnachman/esctest),
//!              the de-facto xterm-conformance harness (iTerm2/xterm CI).
//!              Test names cited per case.
//!   [ctlseqs]  xterm's ctlseqs.txt (Thomas Dickey), the normative description
//!              of DECAWM deferred wrap, DECSC/DECRC state, and 1049 alt
//!              screen semantics.
//!   [ECMA-48]  §8.3.64/8.3.26/8.3.41 for ICH/DCH/ECH cell arithmetic.
//!
//! Every case drives bytes through the REAL parser (Pane.processOutput) —
//! no direct Terminal method calls — so the parser dispatch is under test too.

const std = @import("std");
const session = @import("session.zig");

const Harness = struct {
    sess: *session.Session,

    fn init(rows: u16, cols: u16) !Harness {
        const rect = session.Rect{ .x = 0, .y = 0, .width = cols, .height = rows };
        return .{ .sess = try session.Session.init(std.testing.allocator, "vt", rect, 100) };
    }
    fn deinit(self: *Harness) void {
        self.sess.deinit();
    }
    fn feed(self: *Harness, bytes: []const u8) void {
        self.sess.getActiveWindow().getActivePane().processOutput(bytes);
    }
    fn term(self: *Harness) *session.Pane {
        return self.sess.getActiveWindow().getActivePane();
    }
    fn charAt(self: *Harness, row: u16, col: u16) u21 {
        return self.term().terminal.grid.getCellConst(row, col).char;
    }
    fn cursor(self: *Harness) struct { row: u16, col: u16 } {
        const c = self.term().terminal.cursor;
        return .{ .row = c.row, .col = c.col };
    }
    /// A row's text with trailing blanks trimmed (esctest's screen comparison).
    fn rowText(self: *Harness, row: u16, buf: []u8) []const u8 {
        const grid = &self.term().terminal.grid;
        var len: usize = 0;
        var col: u16 = 0;
        while (col < grid.cols) : (col += 1) {
            const ch = grid.getCellConst(row, col).char;
            if (ch == 0) continue;
            buf[len] = if (ch < 0x80) @intCast(ch) else '?';
            len += 1;
        }
        while (len > 0 and buf[len - 1] == ' ') len -= 1;
        return buf[0..len];
    }
};

// ── DECAWM deferred wrap ────────────────────────────────────────────────────

test "esctest DECAWM: printing the last column leaves the cursor ON it (deferred wrap)" {
    // esctest: test_DECAWM_OnRespectsLeftRightMargin / wrap tests — after
    // filling the line, CPR reports the LAST column, not column 1 of the next
    // row; the wrap is pending, not taken.
    var h = try Harness.init(5, 10);
    defer h.deinit();
    h.feed("abcdefghij"); // exactly 10 = full row
    try std.testing.expectEqual(@as(u16, 0), h.cursor().row);
    try std.testing.expectEqual(@as(u16, 9), h.cursor().col);
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("abcdefghij", h.rowText(0, &buf));
}

test "esctest DECAWM: the NEXT printable takes the deferred wrap" {
    var h = try Harness.init(5, 10);
    defer h.deinit();
    h.feed("abcdefghijK");
    try std.testing.expectEqual(@as(u16, 1), h.cursor().row);
    try std.testing.expectEqual(@as(u16, 1), h.cursor().col);
    try std.testing.expectEqual(@as(u21, 'K'), h.charAt(1, 0));
    try std.testing.expectEqual(@as(u21, 'j'), h.charAt(0, 9)); // row 0 intact
}

test "esctest DECAWM: CR after filling the line stays on the SAME row" {
    // esctest test_DECAWM_NoLineWrapOnTabWithLeftRightMargin family: control
    // characters cancel the pending wrap instead of taking it.
    var h = try Harness.init(5, 10);
    defer h.deinit();
    h.feed("abcdefghij\rX");
    try std.testing.expectEqual(@as(u21, 'X'), h.charAt(0, 0)); // overwrote 'a'
    try std.testing.expectEqual(@as(u16, 0), h.cursor().row);
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("Xbcdefghij", h.rowText(0, &buf));
}

test "esctest DECAWM: CUP cancels the pending wrap" {
    var h = try Harness.init(5, 10);
    defer h.deinit();
    h.feed("abcdefghij"); // pending
    h.feed("\x1b[1;10H"); // CUP to the same last column
    h.feed("Z"); // must OVERWRITE column 10, not wrap
    try std.testing.expectEqual(@as(u21, 'Z'), h.charAt(0, 9));
    try std.testing.expectEqual(@as(u16, 0), h.cursor().row);
}

test "ctlseqs DECAWM off: printables overwrite the last column in place" {
    var h = try Harness.init(5, 10);
    defer h.deinit();
    h.feed("\x1b[?7l"); // DECAWM off
    h.feed("abcdefghijKLM"); // K,L,M all land on the last cell
    try std.testing.expectEqual(@as(u21, 'M'), h.charAt(0, 9));
    try std.testing.expectEqual(@as(u16, 0), h.cursor().row);
    h.feed("\x1b[?7h");
}

test "esctest DECSC/DECRC: restore brings back the pending-wrap state" {
    // esctest test_DECRC_ResetsPendingWrap-adjacent: xterm's saved cursor
    // includes the wrap flag.
    var h = try Harness.init(5, 10);
    defer h.deinit();
    h.feed("abcdefghij"); // pending wrap armed
    h.feed("\x1b7"); // DECSC
    h.feed("\x1b[3;1Hxyz"); // move away, print
    h.feed("\x1b8"); // DECRC → last column, wrap pending again
    h.feed("Q"); // takes the wrap
    try std.testing.expectEqual(@as(u21, 'Q'), h.charAt(1, 0));
}

// ── wide characters ─────────────────────────────────────────────────────────

test "esctest wide char at the last column wraps whole (never split)" {
    // esctest: DoubleWidth tests — a CJK glyph with one column left moves to
    // the next line; the abandoned last cell is blanked.
    var h = try Harness.init(5, 10);
    defer h.deinit();
    h.feed("abcdefghi"); // cursor on col 9 (last), 9 cells used
    h.feed("\u{4E2D}"); // 中 needs 2 columns
    try std.testing.expectEqual(@as(u21, ' '), h.charAt(0, 9)); // spacer
    try std.testing.expectEqual(@as(u21, 0x4E2D), h.charAt(1, 0));
    try std.testing.expectEqual(@as(u2, 2), h.term().terminal.grid.getCellConst(1, 0).width);
    try std.testing.expectEqual(@as(u2, 0), h.term().terminal.grid.getCellConst(1, 1).width);
}

test "combining characters do not advance the cursor" {
    // esctest: combining-mark tests — U+0301 after 'e' must not move the
    // cursor (we drop the mark; composing is out of scope, mis-advancing is a bug).
    var h = try Harness.init(5, 10);
    defer h.deinit();
    h.feed("e\u{0301}x");
    try std.testing.expectEqual(@as(u21, 'e'), h.charAt(0, 0));
    try std.testing.expectEqual(@as(u21, 'x'), h.charAt(0, 1));
    try std.testing.expectEqual(@as(u16, 2), h.cursor().col);
}

// ── alternate screen (DECSET 1049) ──────────────────────────────────────────

test "ctlseqs 1049: primary content is restored byte-exact on exit" {
    var h = try Harness.init(5, 20);
    defer h.deinit();
    h.feed("primary line\r\nsecond");
    h.feed("\x1b[?1049h"); // save cursor + alt screen
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("", h.rowText(0, &buf)); // alt starts blank
    // 1049 does NOT home the cursor (it stays where the primary left it);
    // real fullscreen apps CUP themselves — do the same before writing.
    h.feed("\x1b[H");
    h.feed("ALT CONTENT");
    try std.testing.expectEqualStrings("ALT CONTENT", h.rowText(0, &buf));
    h.feed("\x1b[?1049l"); // back to primary + restore cursor
    try std.testing.expectEqualStrings("primary line", h.rowText(0, &buf));
    try std.testing.expectEqualStrings("second", h.rowText(1, &buf));
}

test "ctlseqs 1049: cursor position is saved on enter and restored on exit" {
    var h = try Harness.init(5, 20);
    defer h.deinit();
    h.feed("\x1b[2;7H"); // row 1, col 6 (0-based)
    h.feed("\x1b[?1049h");
    h.feed("\x1b[5;1Hxxxxx"); // move around in alt
    h.feed("\x1b[?1049l");
    try std.testing.expectEqual(@as(u16, 1), h.cursor().row);
    try std.testing.expectEqual(@as(u16, 6), h.cursor().col);
}

test "alt screen writes never leak into primary scrollback" {
    var h = try Harness.init(3, 10);
    defer h.deinit();
    const before = h.term().terminal.scrollback.len;
    h.feed("\x1b[?1049h");
    h.feed("l1\r\nl2\r\nl3\r\nl4\r\nl5\r\n"); // scrolls the ALT screen
    h.feed("\x1b[?1049l");
    try std.testing.expectEqual(before, h.term().terminal.scrollback.len);
}

// ── ECMA-48 editing functions ───────────────────────────────────────────────

test "ECMA-48 ICH: inserted blanks shift the tail right, last cells fall off" {
    var h = try Harness.init(5, 10);
    defer h.deinit();
    h.feed("abcdefghij\x1b[1;3H\x1b[2@"); // ICH 2 at col 3
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("ab  cdefgh", h.rowText(0, &buf));
}

test "ECMA-48 DCH: deleted cells pull the tail left, blanks fill the end" {
    var h = try Harness.init(5, 10);
    defer h.deinit();
    h.feed("abcdefghij\x1b[1;3H\x1b[2P"); // DCH 2 at col 3
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("abefghij", h.rowText(0, &buf));
}

test "ECMA-48 ECH: erases N cells in place without moving the tail" {
    var h = try Harness.init(5, 10);
    defer h.deinit();
    h.feed("abcdefghij\x1b[1;3H\x1b[2X"); // ECH 2 at col 3
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("ab  efghij", h.rowText(0, &buf));
}

// ── erase display / scrollback ──────────────────────────────────────────────

test "ctlseqs ED 3 clears scrollback, ED 2 does not" {
    var h = try Harness.init(3, 10);
    defer h.deinit();
    h.feed("a\r\nb\r\nc\r\nd\r\ne\r\n"); // force scrollback
    try std.testing.expect(h.term().terminal.scrollback.len > 0);
    h.feed("\x1b[2J");
    try std.testing.expect(h.term().terminal.scrollback.len > 0);
    h.feed("\x1b[3J");
    try std.testing.expectEqual(@as(usize, 0), h.term().terminal.scrollback.len);
}

// ── scroll region ───────────────────────────────────────────────────────────

test "ctlseqs DECSTBM: LF at region bottom scrolls only the region" {
    var h = try Harness.init(5, 10);
    defer h.deinit();
    h.feed("top\x1b[5;1Hbottom"); // rows 0 and 4 as sentinels
    h.feed("\x1b[2;4r"); // region rows 2-4 (1-based) = 1..3
    h.feed("\x1b[4;1Hline3\n"); // LF at region bottom → region scrolls
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("top", h.rowText(0, &buf)); // untouched
    try std.testing.expectEqualStrings("bottom", h.rowText(4, &buf)); // untouched
    try std.testing.expectEqualStrings("line3", h.rowText(2, &buf)); // moved up
    h.feed("\x1b[r");
}
