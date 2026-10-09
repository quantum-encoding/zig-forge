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
    /// The reply queue the emulator owes the app, read-and-clear (what the
    /// host drains via zterm_take_responses).
    fn takeResp(self: *Harness) []const u8 {
        const t = &self.term().terminal;
        const out = t.resp_pending[0..t.resp_len];
        t.resp_len = 0;
        return out;
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

test "UAX-11: emoji are width 2 (renderers and the shell's wcwidth must agree)" {
    // Unicode 15 EastAsianWidth.txt lists U+1F680 (rocket) and U+231A (watch)
    // as `W`. Width-1 emoji made the Metal consumers overlap the glyph with
    // the next cell and drift the cursor vs the shell.
    var h = try Harness.init(5, 10);
    defer h.deinit();
    h.feed("\u{1F680}\u{231A}x");
    try std.testing.expectEqual(@as(u2, 2), h.term().terminal.grid.getCellConst(0, 0).width);
    try std.testing.expectEqual(@as(u2, 0), h.term().terminal.grid.getCellConst(0, 1).width);
    try std.testing.expectEqual(@as(u2, 2), h.term().terminal.grid.getCellConst(0, 2).width);
    try std.testing.expectEqual(@as(u21, 'x'), h.charAt(0, 4));
    try std.testing.expectEqual(@as(u16, 5), h.cursor().col);
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

// ctlseqs DECSET/DECRST: "47 → Use Alternate Screen Buffer" / "Use Normal
// Screen Buffer"; "1047 → Use Alternate Screen Buffer" / "Use Normal Screen
// Buffer ... Clear the screen first if in the Alternate Screen Buffer";
// "1049 → Save cursor as in DECSC ... switch to the Alternate Screen Buffer,
// clearing it first". xterm has ONE alternate buffer: 47 never clears it.

test "ctlseqs 47: a plain switch — primary restored, no cursor save, alt buffer kept" {
    var h = try Harness.init(5, 20);
    defer h.deinit();
    var buf: [32]u8 = undefined;
    h.feed("primary\x1b[3;5H"); // cursor row 2, col 4
    h.feed("\x1b[?47h");
    try std.testing.expect(h.term().terminal.modes.alt_screen);
    try std.testing.expectEqualStrings("", h.rowText(0, &buf)); // nothing drawn here yet
    h.feed("\x1b[1;1HALT47"); // cursor ends row 0, col 5
    h.feed("\x1b[?47l");
    try std.testing.expect(!h.term().terminal.modes.alt_screen);
    try std.testing.expectEqualStrings("primary", h.rowText(0, &buf));
    // No DECRC: the cursor is where the alternate screen left it.
    try std.testing.expectEqual(@as(u16, 0), h.cursor().row);
    try std.testing.expectEqual(@as(u16, 5), h.cursor().col);
    // The alternate buffer still holds what was drawn on it.
    h.feed("\x1b[?47h");
    try std.testing.expectEqualStrings("ALT47", h.rowText(0, &buf));
    h.feed("\x1b[?47l");
    try std.testing.expectEqualStrings("primary", h.rowText(0, &buf));
}

test "ctlseqs 1047: the alternate buffer is cleared on the way out, not the way in" {
    var h = try Harness.init(5, 20);
    defer h.deinit();
    var buf: [32]u8 = undefined;
    h.feed("primary");
    h.feed("\x1b[?47h\x1b[HKEPT\x1b[?47l"); // leave content in the alt buffer
    h.feed("\x1b[?1047h");
    try std.testing.expectEqualStrings("KEPT", h.rowText(0, &buf)); // 1047h does not clear
    h.feed("\x1b[HDRAWN");
    h.feed("\x1b[?1047l");
    try std.testing.expectEqualStrings("primary", h.rowText(0, &buf));
    h.feed("\x1b[?47h"); // what 1047l left behind: nothing
    try std.testing.expectEqualStrings("", h.rowText(0, &buf));
    h.feed("\x1b[?47l");
}

test "ctlseqs 1049 clears the alternate buffer a 47 exit kept" {
    var h = try Harness.init(5, 20);
    defer h.deinit();
    var buf: [32]u8 = undefined;
    h.feed("\x1b[?47h\x1b[HKEPT\x1b[?47l");
    h.feed("\x1b[?1049h");
    try std.testing.expectEqualStrings("", h.rowText(0, &buf));
    h.feed("\x1b[?1049l");
}

test "RIS inside the alternate screen returns to the primary and frees the alternate" {
    // std.testing.allocator fails this test on a leak: an RIS that reset only
    // the mode flag would leave the alternate grid on screen as "primary",
    // and the next 1049h would stash it over the real primary, leaking it.
    var h = try Harness.init(5, 20);
    defer h.deinit();
    var buf: [32]u8 = undefined;
    h.feed("\x1b[?47h\x1b[HKEPT\x1b[?47l"); // a kept alternate buffer too
    h.feed("\x1b[?1049h\x1b[HALT");
    h.feed("\x1bc"); // RIS
    try std.testing.expect(!h.term().terminal.modes.alt_screen);
    try std.testing.expect(h.term().terminal.alt_grid == null);
    try std.testing.expect(h.term().terminal.kept_alt == null);
    try std.testing.expectEqualStrings("", h.rowText(0, &buf));
    h.feed("main\x1b[?1049h\x1b[?1049l");
    try std.testing.expectEqualStrings("main", h.rowText(0, &buf));
}

test "a kept alternate buffer follows a resize" {
    var h = try Harness.init(5, 20);
    defer h.deinit();
    var buf: [32]u8 = undefined;
    h.feed("\x1b[?47h\x1b[HKEPT\x1b[?47l");
    try h.term().resize(.{ .x = 0, .y = 0, .width = 30, .height = 8 });
    h.feed("\x1b[?47h");
    try std.testing.expectEqual(@as(u16, 8), h.term().terminal.grid.rows);
    try std.testing.expectEqual(@as(u16, 30), h.term().terminal.grid.cols);
    try std.testing.expectEqualStrings("KEPT", h.rowText(0, &buf));
    h.feed("\x1b[8;30HZ"); // the last cell exists
    try std.testing.expectEqual(@as(u21, 'Z'), h.charAt(7, 29));
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

// ── OSC / string terminators ────────────────────────────────────────────────

test "ctlseqs OSC terminated by ST (ESC backslash) sets the title and prints NOTHING" {
    // xterm ctlseqs: OSC strings end with BEL or ST (ESC \). The old parser
    // returned to ground on the ESC, so the trailing '\' printed into the
    // grid after every tmux/iTerm2-style title write.
    var h = try Harness.init(5, 20);
    defer h.deinit();
    h.feed("\x1b]0;mytitle\x1b\\X");
    const t = &h.term().terminal;
    try std.testing.expectEqualStrings("mytitle", t.title[0..t.title_len]);
    try std.testing.expectEqual(@as(u21, 'X'), h.charAt(0, 0)); // no stray backslash
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("X", h.rowText(0, &buf));
}

test "ctlseqs OSC terminated by BEL behaves identically" {
    var h = try Harness.init(5, 20);
    defer h.deinit();
    h.feed("\x1b]0;beltitle\x07Y");
    const t = &h.term().terminal;
    try std.testing.expectEqualStrings("beltitle", t.title[0..t.title_len]);
    try std.testing.expectEqual(@as(u21, 'Y'), h.charAt(0, 0));
}

// ── CSI parameter grammar ───────────────────────────────────────────────────

test "ECMA-48 CUP with a leading empty parameter: ESC[;5H is row-default col-5" {
    // esctest CUP default-parameter cases: an empty first param means default
    // (row 1), and the 5 belongs to the SECOND parameter (column).
    var h = try Harness.init(5, 20);
    defer h.deinit();
    h.feed("\x1b[3;3H"); // park somewhere first
    h.feed("\x1b[;5H");
    try std.testing.expectEqual(@as(u16, 0), h.cursor().row); // default row 1
    try std.testing.expectEqual(@as(u16, 4), h.cursor().col); // column 5
}

test "ECMA-48 colon sub-parameters do not corrupt following params" {
    // SGR 4:3 (curly underline) and 38:2::r:g:b use ':' SUB-parameters
    // (ECMA-48 §5.4.2). Promoting them to top-level params made everything
    // after them mis-parse: sub-params belong to their parameter, and the
    // params AFTER the colon-carrying one must still land correctly.
    var h = try Harness.init(5, 20);
    defer h.deinit();
    h.feed("\x1b[4:3;1mZ"); // underline(with subparam) ; bold
    const cell = h.term().terminal.grid.getCellConst(0, 0);
    try std.testing.expectEqual(@as(u21, 'Z'), cell.char);
    try std.testing.expect(cell.attrs.bold); // the ;1 survived the 4:3
}

// ── SGR extended colour (xterm ctlseqs "SGR", ITU T.416) ────────────────────

const terminal = @import("terminal.zig");

/// The cell `text` lands in after `sgr` is applied on a fresh 3x30 screen.
fn sgrCell(sgr: []const u8) !terminal.Cell {
    var h = try Harness.init(3, 30);
    defer h.deinit();
    h.feed(sgr);
    h.feed("Z");
    return h.term().terminal.grid.getCellConst(0, 0).*;
}

fn expectRgb(c: terminal.CellColor, r: u8, g: u8, b: u8) !void {
    switch (c) {
        .rgb => |v| {
            try std.testing.expectEqual(r, v.r);
            try std.testing.expectEqual(g, v.g);
            try std.testing.expectEqual(b, v.b);
        },
        else => return error.NotRgb,
    }
}

fn expectIndexed(c: terminal.CellColor, n: u8) !void {
    switch (c) {
        .indexed => |v| try std.testing.expectEqual(n, v),
        else => return error.NotIndexed,
    }
}

test "ctlseqs SGR 38/48: colon form, with and without the colour-space id" {
    // ctlseqs: "38:2:Pi:Pr:Pg:Pb Set foreground color using RGB values ...
    // The color space identifier Pi is ignored"; "38:5:Ps ... indexed color".
    // `38:2::r:g:b` (empty Pi) is what kitty/foot-style apps emit; `38:2:r:g:b`
    // (no Pi) is the other spelling in the wild.
    try expectRgb((try sgrCell("\x1b[38:2::10:20:30m")).fg, 10, 20, 30);
    try expectRgb((try sgrCell("\x1b[38:2:0:10:20:30m")).fg, 10, 20, 30);
    try expectRgb((try sgrCell("\x1b[38:2:10:20:30m")).fg, 10, 20, 30);
    try expectRgb((try sgrCell("\x1b[48:2::1:2:3m")).bg, 1, 2, 3);
    try expectIndexed((try sgrCell("\x1b[38:5:123m")).fg, 123);
    try expectIndexed((try sgrCell("\x1b[48:5:7m")).bg, 7);
    // The konsole-compatible semicolon form still works.
    try expectRgb((try sgrCell("\x1b[38;2;10;20;30m")).fg, 10, 20, 30);
    try expectIndexed((try sgrCell("\x1b[48;5;200m")).bg, 200);
}

test "ctlseqs SGR: a colon-form colour leaves the parameters after it alone" {
    // The sub-parameters are the colour's own; the `;1` / `;4` that follow
    // are ordinary SGR parameters (the semicolon form, by contrast, eats the
    // parameters after it, so a `;1` there would be read as a component).
    const a = try sgrCell("\x1b[38:2::1:2:3;1m");
    try expectRgb(a.fg, 1, 2, 3);
    try std.testing.expect(a.attrs.bold);
    const b = try sgrCell("\x1b[38:5:9;48:2::4:5:6;4m");
    try expectIndexed(b.fg, 9);
    try expectRgb(b.bg, 4, 5, 6);
    try std.testing.expect(b.attrs.underline);
}

test "kitty underline styles: 4:n is an underline, 4:0 turns it off" {
    // kitty's "Colored and styled underlines": 4:0 none, 4:1 straight,
    // 4:2 double, 4:3 curly, 4:4 dotted, 4:5 dashed.
    try std.testing.expect((try sgrCell("\x1b[4:3m")).attrs.underline);
    try std.testing.expect((try sgrCell("\x1b[4:1m")).attrs.underline);
    try std.testing.expect((try sgrCell("\x1b[4m")).attrs.underline);
    try std.testing.expect(!(try sgrCell("\x1b[4m\x1b[4:0m")).attrs.underline);
}

test "SGR 58 (underline colour) consumes its arguments in either form" {
    // `58;2;255;0;0` read as separate SGR codes would be dim (2) and then a
    // full reset (0), dropping the bold before it.
    try std.testing.expect((try sgrCell("\x1b[1;58;2;255;0;0m")).attrs.bold);
    try std.testing.expect(!(try sgrCell("\x1b[1;58;2;255;0;0m")).attrs.dim);
    try std.testing.expect((try sgrCell("\x1b[1;58:2::255:0:0m")).attrs.bold);
}

test "out-of-range SGR colours and ED/EL modes are ignored, never a crash" {
    // A component past 255 names no colour (xterm ignores it). Narrowing the
    // u16 param to u8 with @intCast is a safety panic in Debug/ReleaseSafe:
    // any program in a pane could take the whole server down with one printf.
    try std.testing.expect((try sgrCell("\x1b[38;5;300m")).fg == .default);
    try std.testing.expect((try sgrCell("\x1b[38;2;300;0;0m")).fg == .default);
    try std.testing.expect((try sgrCell("\x1b[48:2::0:999:0m")).bg == .default);
    try std.testing.expect((try sgrCell("\x1b[38:5:65535m")).fg == .default);
    // The semicolon form still consumes its arguments: the 1 after is bold.
    try std.testing.expect((try sgrCell("\x1b[38;5;300;1m")).attrs.bold);
    var h = try Harness.init(3, 10);
    defer h.deinit();
    h.feed("abc\x1b[256J\x1b[300K\x1b[65535J");
    try std.testing.expectEqual(@as(u21, 'a'), h.charAt(0, 0)); // nothing erased
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

test "esctest DECOM: CUP is relative to the scroll region and clamps to it" {
    // esctest DECSETTests.test_DECSET_DECOM: with DECOM (DECSET 6) set, CUP
    // row 1 addresses the TOP of the DECSTBM region (not the screen top), and
    // a row beyond the region bottom clamps to the region bottom. Resetting
    // DECOM makes CUP absolute again. Anchors the origin-mode offset in
    // setCursorPos (terminal.zig) that the already-anchored DECSTBM case does
    // not exercise.
    var h = try Harness.init(8, 10);
    defer h.deinit();
    h.feed("\x1b[3;6r"); // DECSTBM region 1-based rows 3..6 → 0-based 2..5
    h.feed("\x1b[?6h"); // DECOM on

    // CUP 1;1 lands at the region top (0-based row 2), NOT the screen top.
    h.feed("\x1b[1;1HA");
    try std.testing.expectEqual(@as(u21, 'A'), h.charAt(2, 0));
    try std.testing.expect(h.charAt(0, 0) != 'A'); // screen top is NOT the origin

    // CUP to a row past the region bottom clamps to the region bottom (row 5).
    h.feed("\x1b[10;1HB");
    try std.testing.expectEqual(@as(u21, 'B'), h.charAt(5, 0));

    // DECOM off → CUP is absolute again: row 1 is the screen top.
    h.feed("\x1b[?6l");
    h.feed("\x1b[1;1HC");
    try std.testing.expectEqual(@as(u21, 'C'), h.charAt(0, 0));
    h.feed("\x1b[r");
}


// ── device reports: DA / DSR / CPR ──────────────────────────────────────────
//
// [ctlseqs] "CSI Ps n — Device Status Report (DSR). Ps = 6 → Report Cursor
// Position (CPR) [row;column] as CSI r ; c R" — rows and columns are 1-based.
// [ctlseqs] DECOM: "the cursor position is relative to the scrolling region",
// which is what makes the origin-mode case below a different answer, not just
// a different clamp. esctest covers these as test_DSR_CPR* / test_DECOM*.
//
// NOTE ON ANCHORING: the CPR/DSR *format and values* are spec-derived above.
// The DA identity strings are this terminal's own declaration of capability —
// no external source can say what WE are — so those cases are DRIFT LOCKS on
// the emitted bytes, not external anchors. Labelled here so the distinction
// does not get lost (repo CLAUDE.md, golden rule §1).

test "ctlseqs DSR-CPR: ESC[6n answers CSI row;col R, 1-based" {
    var h = try Harness.init(10, 40);
    defer h.deinit();
    h.feed("\x1b[3;7H"); // row 3, col 7 (1-based on the wire)
    h.feed("\x1b[6n");
    try std.testing.expectEqualStrings("\x1b[3;7R", h.takeResp());
}

test "ctlseqs DSR-CPR under DECOM: the row is RELATIVE to the scroll region" {
    var h = try Harness.init(10, 40);
    defer h.deinit();
    h.feed("\x1b[3;8r"); // DECSTBM: region = absolute rows 3..8
    h.feed("\x1b[?6h"); // DECOM on — CUP and CPR both become region-relative
    h.feed("\x1b[2;5H"); // 2nd row OF THE REGION = absolute row 4
    try std.testing.expectEqual(@as(u16, 3), h.cursor().row); // 0-based absolute
    h.feed("\x1b[6n");
    // Must report 2, not 4: the app's next CUP uses the same origin.
    try std.testing.expectEqualStrings("\x1b[2;5R", h.takeResp());
}

test "DSR-CPR clamps a cursor parked outside the origin-mode region" {
    // Region set AFTER the cursor was parked below it: DECOM must not report a
    // row that underflows past the region top (row 1 is the region's first).
    var h = try Harness.init(10, 40);
    defer h.deinit();
    h.feed("\x1b[1;1H"); // absolute row 0
    h.feed("\x1b[5;8r\x1b[?6h"); // region rows 5..8, then origin mode on
    h.term().terminal.cursor.row = 0; // force the out-of-region parking
    h.feed("\x1b[6n");
    try std.testing.expectEqualStrings("\x1b[1;1R", h.takeResp());
}

test "ctlseqs DSR 5 answers CSI 0 n (no malfunction)" {
    var h = try Harness.init(5, 20);
    defer h.deinit();
    h.feed("\x1b[5n");
    try std.testing.expectEqualStrings("\x1b[0n", h.takeResp());
}

test "ctlseqs DECXCPR: ESC[?6n answers CSI ? row ; col ; page R" {
    var h = try Harness.init(10, 40);
    defer h.deinit();
    h.feed("\x1b[4;2H\x1b[?6n");
    try std.testing.expectEqualStrings("\x1b[?4;2;1R", h.takeResp());
}

test "drift lock — DA1 (ESC[c) and DA2 (ESC[>c) answer with our identity" {
    var h = try Harness.init(5, 20);
    defer h.deinit();
    h.feed("\x1b[c");
    try std.testing.expectEqualStrings("\x1b[?62;22c", h.takeResp());
    h.feed("\x1b[0c"); // explicit Ps=0 is the same request
    try std.testing.expectEqualStrings("\x1b[?62;22c", h.takeResp());
    h.feed("\x1b[>c");
    try std.testing.expectEqualStrings("\x1b[>0;277;0c", h.takeResp());
}

test "ctlseqs DA: a non-zero Ps and DA3 are not requests — stay silent" {
    var h = try Harness.init(5, 20);
    defer h.deinit();
    h.feed("\x1b[1c"); // not a DA request per ctlseqs
    h.feed("\x1b[=c"); // DA3 reports a unit id we do not have
    h.feed("\x1b[7n"); // undefined DSR
    try std.testing.expectEqual(@as(usize, 0), h.takeResp().len);
}

test "OSC 10/11 '?' answer the themed fg/bg as 16-bit rgb:" {
    const config = @import("config.zig");
    const saved = config.active_theme;
    defer config.active_theme = saved;
    config.active_theme.fg = .{ .r = 0xD9, .g = 0xDB, .b = 0xE0 };
    config.active_theme.bg = .{ .r = 0x12, .g = 0x12, .b = 0x17 };

    var h = try Harness.init(5, 20);
    defer h.deinit();
    // xterm answers colour queries with 16-bit-per-channel components; the
    // 8-bit value is widened by repetition (0xD9 -> 0xD9D9).
    h.feed("\x1b]10;?\x1b\\");
    try std.testing.expectEqualStrings("\x1b]10;rgb:d9d9/dbdb/e0e0\x1b\\", h.takeResp());
    h.feed("\x1b]11;?\x1b\\");
    try std.testing.expectEqualStrings("\x1b]11;rgb:1212/1212/1717\x1b\\", h.takeResp());
    // A SET (non-"?") must not answer.
    h.feed("\x1b]11;#000000\x1b\\");
    try std.testing.expectEqual(@as(usize, 0), h.takeResp().len);
}

test "the reply queue is bounded: a query burst drops whole replies, never partial ones" {
    var h = try Harness.init(10, 40);
    defer h.deinit();
    // Each DA1 reply is 9 bytes; 64 bytes of capacity holds 7 with 1 left over,
    // so the 8th must be dropped ENTIRELY rather than truncated to 1 byte.
    var i: usize = 0;
    while (i < 20) : (i += 1) h.feed("\x1b[c");
    const queued = h.takeResp();
    try std.testing.expect(queued.len <= terminal.RESP_CAPACITY);
    try std.testing.expectEqual(@as(usize, 0), queued.len % 9); // no partial reply
    try std.testing.expectEqual(@as(usize, 63), queued.len);
}

test "RIS voids replies owed to the pre-reset app" {
    var h = try Harness.init(5, 20);
    defer h.deinit();
    h.feed("\x1b[6n");
    try std.testing.expect(h.term().terminal.resp_len > 0);
    h.feed("\x1bc"); // RIS
    try std.testing.expectEqual(@as(usize, 0), h.takeResp().len);
}

// ── OSC strings: command numbers, OSC 52 clipboard ──────────────────────────

test "ctlseqs OSC: the command number ends at the first ';' — digits after it are data" {
    // "OSC Ps ; Pt ST": Pt is text. Digits after the ';' read into Ps would
    // make a title that starts with a number set nothing at all.
    var h = try Harness.init(3, 20);
    defer h.deinit();
    const t = &h.term().terminal;
    h.feed("\x1b]0;2024 report\x07");
    try std.testing.expectEqualStrings("2024 report", t.title[0..t.title_len]);
    h.feed("\x1b]2;;x\x1b\\"); // an empty first field is still text
    try std.testing.expectEqualStrings(";x", t.title[0..t.title_len]);
    h.feed("\x1b]52;0;aGk=\x07"); // Pc is cut buffer 0, not part of Ps
    try std.testing.expectEqualStrings("0;aGk=", t.pendingClipboard());
}

/// "\x1b]52;c;" ++ `n` base64 characters ++ BEL.
fn osc52(alloc: std.mem.Allocator, n: usize) ![]u8 {
    const out = try alloc.alloc(u8, 7 + n + 1);
    @memcpy(out[0..7], "\x1b]52;c;");
    const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    for (out[7 .. 7 + n], 0..) |*ch, i| ch.* = alphabet[(i * 7) % alphabet.len];
    out[out.len - 1] = 0x07;
    return out;
}

test "OSC 52: a ~100 KB payload arrives whole, BEL- or ST-terminated" {
    // A real copy is far larger than the parser's 2 KiB OSC buffer. Cut
    // mid-base64, the host's decode fails and the copy is silently lost.
    const alloc = std.testing.allocator;
    var h = try Harness.init(3, 20);
    defer h.deinit();
    const t = &h.term().terminal;
    const seq = try osc52(alloc, 100_000);
    defer alloc.free(seq);
    h.feed(seq);
    try std.testing.expectEqualStrings(seq[5 .. seq.len - 1], t.pendingClipboard());
    t.clearClipboard();
    // ST instead of BEL, delivered in the small pieces a PTY read gives.
    var off: usize = 0;
    while (off < seq.len - 1) : (off += 4093) h.feed(seq[off..@min(off + 4093, seq.len - 1)]);
    h.feed("\x1b\\after");
    try std.testing.expectEqualStrings(seq[5 .. seq.len - 1], t.pendingClipboard());
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("after", h.rowText(0, &buf)); // ST's '\' not printed
}

test "OSC 52: a payload over the cap is dropped whole, never truncated" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(3, 20);
    defer h.deinit();
    const t = &h.term().terminal;
    h.feed("\x1b]52;c;aGk=\x07");
    const big = try osc52(alloc, terminal.CLIPBOARD_CAP); // "c;" + this > cap
    defer alloc.free(big);
    h.feed(big);
    try std.testing.expectEqualStrings("c;aGk=", t.pendingClipboard()); // the earlier one stands
    // Exactly at the cap is still whole.
    const fits = try osc52(alloc, terminal.CLIPBOARD_CAP - 2);
    defer alloc.free(fits);
    h.feed(fits);
    try std.testing.expectEqual(terminal.CLIPBOARD_CAP, t.pendingClipboard().len);
}

test "OSC 52 '?' (read the clipboard) is refused with an empty reply, never the contents" {
    var h = try Harness.init(3, 20);
    defer h.deinit();
    const t = &h.term().terminal;
    h.feed("\x1b]52;c;c2VjcmV0\x07"); // something the host has pending
    h.feed("\x1b]52;c;?\x07");
    try std.testing.expectEqualStrings("\x1b]52;c;\x1b\\", h.takeResp());
    try std.testing.expectEqualStrings("c;c2VjcmV0", t.pendingClipboard()); // the query replaced nothing
    h.feed("\x1b]52;x\x7f;?\x1b\\"); // a selection xterm does not define is not echoed
    try std.testing.expectEqualStrings("\x1b]52;c;\x1b\\", h.takeResp());
}
