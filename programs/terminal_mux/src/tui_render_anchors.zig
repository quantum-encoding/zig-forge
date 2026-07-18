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

test "REAL composer replay: typed text must land unmangled in the grid" {
    // fixtures/claude_composer_typed.bin = a pty capture of claude 2.1.214
    // booting at 120x40 and receiving the keystrokes "hey claude hows it
    // going" (one per 30ms). The live app rendered this as
    // "claudelhows itdgoing" — stale cells from earlier per-key redraws
    // surviving later frames. The Metal renderer repaints the WHOLE grid
    // every frame, so any stale text must exist IN the emulator grid; this
    // replay pins which half owns the defect.
    const cap = @embedFile("composer_fixture");
    const rect = session.Rect{ .x = 0, .y = 0, .width = 120, .height = 40 };
    const sess = try session.Session.init(std.testing.allocator, "composer", rect, 200);
    defer sess.deinit();
    feedFixture(sess, cap);

    const grid = &sess.getActiveWindow().getActivePane().terminal.grid;
    // Find the row containing "hey" and reconstruct its text.
    var found: bool = false;
    var r: u16 = 0;
    while (r < grid.rows) : (r += 1) {
        var buf: [200]u8 = undefined;
        var len: usize = 0;
        var c: u16 = 0;
        while (c < grid.cols and len < buf.len - 4) : (c += 1) {
            const ch = grid.getCellConst(r, c).char;
            if (ch == 0) { buf[len] = ' '; len += 1; }
            else if (ch < 128) { buf[len] = @intCast(ch); len += 1; }
            else { buf[len] = '#'; len += 1; }
        }
        const line = std.mem.trimEnd(u8, buf[0..len], " ");
        if (std.mem.indexOf(u8, line, "hey") != null) {
            found = true;
            std.debug.print("\ncomposer row {d}: [{s}]\n", .{ r, line });
            // The typed words must appear IN ORDER with clean boundaries —
            // no stale-cell merges like "claudelhows".
            try std.testing.expect(std.mem.indexOf(u8, line, "hey claude hows it going") != null);
        }
    }
    try std.testing.expect(found);
}

test "REAL composer replay WITH mid-stream resizes: no stale-cell mangling" {
    // Same capture protocol, but with the app's real lifecycle: spawn at
    // 120 cols, resize to 104 at byte 5620, type, resize back to 120 at byte
    // 10717 (offsets logged by the pty driver). Claude re-renders after each
    // SIGWINCH assuming ITS reflow model; if our resize leaves stale cells,
    // the mangled-echo defect ("claudelhows") reproduces here.
    const cap = @embedFile("composer_resize_fixture");
    const rect = session.Rect{ .x = 0, .y = 0, .width = 120, .height = 40 };
    const sess = try session.Session.init(std.testing.allocator, "composer-rs", rect, 200);
    defer sess.deinit();

    feedFixture(sess, cap[0..5620]);
    try sess.resize(.{ .x = 0, .y = 0, .width = 104, .height = 40 });
    feedFixture(sess, cap[5620..10717]);
    try sess.resize(.{ .x = 0, .y = 0, .width = 120, .height = 40 });
    feedFixture(sess, cap[10717..]);

    const grid = &sess.getActiveWindow().getActivePane().terminal.grid;
    var found = false;
    var r: u16 = 0;
    while (r < grid.rows) : (r += 1) {
        var buf: [240]u8 = undefined;
        var len: usize = 0;
        var c: u16 = 0;
        while (c < grid.cols and len < buf.len - 4) : (c += 1) {
            const ch = grid.getCellConst(r, c).char;
            if (ch == 0) { buf[len] = ' '; len += 1; }
            else if (ch < 128) { buf[len] = @intCast(ch); len += 1; }
            else { buf[len] = '#'; len += 1; }
        }
        const line = std.mem.trimEnd(u8, buf[0..len], " ");
        if (std.mem.indexOf(u8, line, "hey") != null) {
            found = true;
            std.debug.print("\nresized composer row {d}: [{s}]\n", .{ r, line });
            try std.testing.expect(std.mem.indexOf(u8, line, "hey claude hows it going") != null);
            // WIDTH audit — the Swift renderer BLANKS the cell after any
            // width-2 cell (wide-glyph continuation collapse). A spurious
            // width-2 on an ASCII cell makes the renderer EAT the next letter
            // ("claudelhows"-style mangling) even though the chars are right.
            var c2: u16 = 0;
            while (c2 < grid.cols) : (c2 += 1) {
                const cell = grid.getCellConst(r, c2);
                if (cell.char >= 0x20 and cell.char < 0x7F and cell.width != 1) {
                    std.debug.print("ASCII cell width!=1 at col {d}: ch='{c}' width={d}\n",
                        .{ c2, @as(u8, @intCast(cell.char)), cell.width });
                    try std.testing.expect(false);
                }
            }
        }
    }
    try std.testing.expect(found);
}

test "REAL submit cycle: transcript echo renders unmangled (scroll-region path)" {
    // The mangled-echo screenshots show the TRANSCRIPT copy of the submitted
    // message — rendered through claude's scroll-region machinery (DECSTBM +
    // scroll ops) that the type-only fixtures never exercise. This capture
    // includes typing + Enter + the model's response ("Crunched for 3s").
    const cap = @embedFile("composer_submit_fixture");
    const rect = session.Rect{ .x = 0, .y = 0, .width = 120, .height = 40 };
    const sess = try session.Session.init(std.testing.allocator, "submit", rect, 200);
    defer sess.deinit();
    feedFixture(sess, cap);

    const grid = &sess.getActiveWindow().getActivePane().terminal.grid;
    var r: u16 = 0;
    var sawEcho = false;
    while (r < grid.rows) : (r += 1) {
        var buf: [240]u8 = undefined;
        var len: usize = 0;
        var c: u16 = 0;
        while (c < grid.cols and len < buf.len - 4) : (c += 1) {
            const ch = grid.getCellConst(r, c).char;
            if (ch == 0) { buf[len] = ' '; len += 1; }
            else if (ch < 128) { buf[len] = @intCast(ch); len += 1; }
            else { buf[len] = '#'; len += 1; }
        }
        const line = std.mem.trimEnd(u8, buf[0..len], " ");
        if (std.mem.indexOf(u8, line, "hey") != null) {
            std.debug.print("\nsubmit-cycle row {d}: [{s}]\n", .{ r, line });
            // Words must have clean boundaries — the live defect merged them.
            try std.testing.expect(std.mem.indexOf(u8, line, "hey claude hows it going") != null);
            sawEcho = true;
        }
    }
    try std.testing.expect(sawEcho);
}

test "chunked feed == single feed: split escape sequences must not change the grid" {
    // The live app drains the PTY in arbitrary-sized chunks, so escape
    // sequences split at read boundaries constantly — a replay that feeds one
    // big buffer can NEVER see a split-sequence bug. Feed the real composer
    // capture twice: whole, and in adversarial small chunks (1..7 bytes,
    // deterministic pattern); the final grids must be identical.
    const cap = @embedFile("composer_fixture");
    const rect = session.Rect{ .x = 0, .y = 0, .width = 120, .height = 40 };

    const a = try session.Session.init(std.testing.allocator, "whole", rect, 200);
    defer a.deinit();
    feedFixture(a, cap);

    const b = try session.Session.init(std.testing.allocator, "chunks", rect, 200);
    defer b.deinit();
    var i: usize = 0;
    var step: usize = 1;
    while (i < cap.len) {
        const n = @min(step, cap.len - i);
        feedFixture(b, cap[i .. i + n]);
        i += n;
        step = (step % 7) + 1;   // 1,2,3,4,5,6,7,1,2,…
    }

    const ga = &a.getActiveWindow().getActivePane().terminal.grid;
    const gb = &b.getActiveWindow().getActivePane().terminal.grid;
    var r: u16 = 0;
    var diffs: usize = 0;
    while (r < ga.rows) : (r += 1) {
        var c: u16 = 0;
        while (c < ga.cols) : (c += 1) {
            const ca = ga.getCellConst(r, c);
            const cb = gb.getCellConst(r, c);
            if (ca.char != cb.char or @as(u8, @bitCast(ca.attrs)) != @as(u8, @bitCast(cb.attrs))) {
                if (diffs < 8)
                    std.debug.print("chunk-split diff at {d},{d}: whole ch={d} vs chunked ch={d}\n",
                        .{ r, c, ca.char, cb.char });
                diffs += 1;
            }
        }
    }
    try std.testing.expectEqual(@as(usize, 0), diffs);
}

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

test "DEC 2026: sync flag tracks h/l and the REAL claude stream closes every block" {
    // claude Code wraps EVERY repaint in `?2026h … ?2026l` (25 pairs in the
    // committed typed capture). The emulator grid is identical with or without
    // the mode — only host PRESENTATION is gated — so the live-only mangling
    // (half-erased rows, duplicated composer blocks, echo overwriting the TUI)
    // came from painting between the pair. This anchors the flag transitions
    // and that a full real stream ends un-suppressed (no stuck-frozen view).
    const rect = session.Rect{ .x = 0, .y = 0, .width = 120, .height = 40 };
    const sess = try session.Session.init(std.testing.allocator, "sync", rect, 200);
    defer sess.deinit();
    const term = &sess.getActiveWindow().getActivePane().terminal;

    try std.testing.expect(!term.modes.synchronized);
    feedFixture(sess, "\x1b[?2026h");
    try std.testing.expect(term.modes.synchronized);
    try std.testing.expect(term.sync_began_ms > 0);
    // Grid keeps updating normally mid-sync — 2026 gates presentation, not parsing.
    feedFixture(sess, "\x1b[Hmid-sync");
    try std.testing.expectEqual(@as(u21, 'm'), term.grid.getCellConst(0, 0).char);
    feedFixture(sess, "\x1b[?2026l");
    try std.testing.expect(!term.modes.synchronized);

    // Full real capture: every opened block must be closed by stream end.
    feedFixture(sess, @embedFile("composer_fixture"));
    try std.testing.expect(!term.modes.synchronized);
}
