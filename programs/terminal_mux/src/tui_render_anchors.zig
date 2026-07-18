//! Renderer-facing regression anchors: feed a claude-Code-style TUI byte stream
//! through the emulator and assert the grid the Swift/Metal renderer consumes is
//! exactly right. These lock down the *emulator* half of the aiconductor Metal
//! renderer bug (goal 556D61CB): the operator confirmed the raw mux is correct,
//! and the tui_diag harness proved it — so any future emulator regression that
//! would manifest as spurious underlines or mangled TUI text fails here.
//!
//! The renderer-side fixes (glyph-presence fallback for tofu, vector box-drawing
//! for crisp borders) live in the Swift consumer and can't be unit-tested from
//! Zig; these anchors guarantee the DATA those fixes consume stays correct.

const std = @import("std");
const session = @import("session.zig");
const url = @import("url.zig");

const ATTR_UNDERLINE: u8 = 8;

fn feedFixture(sess: *session.Session, bytes: []const u8) void {
    sess.getActiveWindow().getActivePane().processOutput(bytes);
}

/// A rounded box with a URL inside — the exact shape claude draws. Same content
/// as tests/fixtures/claude_tui_synth.bin, inline so the test is hermetic.
/// The leading `ESC[>1u` + `ESC[>4;2m` are claude's REAL boot handshake (Kitty
/// keyboard push + XTMODKEYS), captured via `script` from claude 2.1.214 —
/// the original synth fixture lacked them, which is why the grid dumped clean
/// while the live app underlined everything: an unguarded `m`-final dispatch
/// read XTMODKEYS' param 4 as SGR underline-on, and no reset ever follows.
const TUI =
    "\x1b[?1049h\x1b[H\x1b[2J" ++
    "\x1b[>1u\x1b[>4;2m" ++
    "\x1b[38;2;180;180;190m" ++
    "\u{256D}" ++ "\u{2500}" ** 20 ++ "\u{256E}\r\n" ++
    "\u{2502} \x1b[0m\x1b[1m\u{2733} Claude\x1b[0m\r\n" ++
    "\u{2502} \x1b[0mSee https://docs.anthropic.com/claude for more.\r\n" ++
    "\u{2570}" ++ "\u{2500}" ** 20 ++ "\u{2570}\r\n" ++
    "\x1b[0m\u{23F5} auto-accept on   \u{26A0} 3 files\r\n";

test "XTMODKEYS (CSI > 4;2 m) must NOT set SGR underline — claude's boot handshake" {
    const rect = session.Rect{ .x = 0, .y = 0, .width = 80, .height = 24 };
    const sess = try session.Session.init(std.testing.allocator, "xtmod", rect, 200);
    defer sess.deinit();
    // Handshake first, then plain text — pre-fix, EVERY cell after the
    // handshake carried ATTR_UNDERLINE for the rest of the session.
    feedFixture(sess, "\x1b[>4;2mplain text after handshake");

    const grid = &sess.getActiveWindow().getActivePane().terminal.grid;
    var c: u16 = 0;
    while (c < 10) : (c += 1) {
        const cell = grid.getCellConst(0, c);
        try std.testing.expect(@as(u8, @bitCast(cell.attrs)) & ATTR_UNDERLINE == 0);
    }
}

test "TUI stream: NO spurious ATTR_UNDERLINE anywhere except the real URL" {
    const rect = session.Rect{ .x = 0, .y = 0, .width = 80, .height = 24 };
    const sess = try session.Session.init(std.testing.allocator, "tui", rect, 200);
    defer sess.deinit();
    feedFixture(sess, TUI);

    const grid = &sess.getActiveWindow().getActivePane().terminal.grid;
    var underlined: usize = 0;
    var r: u16 = 0;
    while (r < grid.rows) : (r += 1) {
        var c: u16 = 0;
        while (c < grid.cols) : (c += 1) {
            const cell = grid.getCellConst(r, c);
            if (@as(u8, @bitCast(cell.attrs)) & ATTR_UNDERLINE != 0) underlined += 1;
        }
    }
    // The emulator itself sets NO underline attrs here (the box borders are
    // box-drawing chars, not underlines). The renderer's URL painter adds the
    // only legitimate underline, and that's driven by findUrls below — not by
    // the grid. So the grid must be underline-free.
    try std.testing.expectEqual(@as(usize, 0), underlined);
}

test "TUI stream: findUrls flags exactly the one URL, nothing else (no overreach)" {
    const rect = session.Rect{ .x = 0, .y = 0, .width = 80, .height = 24 };
    const sess = try session.Session.init(std.testing.allocator, "tui", rect, 200);
    defer sess.deinit();
    feedFixture(sess, TUI);

    const grid = &sess.getActiveWindow().getActivePane().terminal.grid;
    var ranges: [16]url.UrlRange = undefined;
    const n = url.findUrls(grid, &ranges);
    try std.testing.expectEqual(@as(usize, 1), n);

    // Reconstruct the flagged text; it must be exactly the URL — the "pervasive
    // underlines" defect would show up here as an overreaching range.
    const rg = ranges[0];
    try std.testing.expectEqual(rg.start_row, rg.end_row); // single row
    var buf: [128]u8 = undefined;
    var len: usize = 0;
    var c: u16 = rg.start_col;
    while (c < rg.end_col) : (c += 1) {
        const ch = grid.getCellConst(rg.start_row, c).char;
        if (ch != 0 and ch < 128) {
            buf[len] = @intCast(ch);
            len += 1;
        }
    }
    try std.testing.expectEqualStrings("https://docs.anthropic.com/claude", buf[0..len]);
}

test "TUI stream: box-drawing + symbol codepoints land in the grid intact" {
    // The renderer draws these; the emulator must preserve them exactly (no
    // width drift that would mangle following text — defect 4's suspected class).
    const rect = session.Rect{ .x = 0, .y = 0, .width = 80, .height = 24 };
    const sess = try session.Session.init(std.testing.allocator, "tui", rect, 200);
    defer sess.deinit();
    feedFixture(sess, TUI);

    const grid = &sess.getActiveWindow().getActivePane().terminal.grid;
    // Row 0 col 0 is the rounded top-left ╭; each of these is width-1 (narrow),
    // so the border row is exactly 22 cells (╭ + 20×─ + ╮) with no drift.
    try std.testing.expectEqual(@as(u21, 0x256D), grid.getCellConst(0, 0).char);
    try std.testing.expectEqual(@as(u2, 1), grid.getCellConst(0, 0).width);
    try std.testing.expectEqual(@as(u21, 0x2500), grid.getCellConst(0, 1).char);
    try std.testing.expectEqual(@as(u21, 0x256E), grid.getCellConst(0, 21).char);
    // The ✳ (U+2733) and ❯-class symbols are narrow (width 1) — a width-2
    // misclassification here is exactly what drifts the columns and merges text.
    try std.testing.expectEqual(@as(u2, 1), grid.getCellConst(1, 2).width); // ✳
}
