//! Inline-graphics lifecycle anchors — the four failure modes the SPEC names as
//! "the engineering; everything else is plumbing", plus an ABI-level recorded-
//! stream anchor.
//!
//! Every case drives bytes through the REAL parser (Pane.processOutput /
//! tmux_feed), so the APC capture + Kitty control parse are under test too — not
//! just the graphics bookkeeping.
//!
//!   1. Scroll off the top of scrollback  → placement evicted, image freed.
//!   2. Partial viewport clip             → clipped on-screen rect, never OOB.
//!   3. Resize/reflow under a placement    → no crash, sane clipped rect.
//!   4. Alt-screen switch (the DOOM case) → per-screen isolation, no leak.

const std = @import("std");
const session = @import("session.zig");
const terminal = @import("terminal.zig");
const gfx = @import("graphics.zig");
const capi = @import("capi.zig");
const pty = @import("pty.zig");

const talloc = std.testing.allocator;

// A 2x2 RGBA test image (red, green, blue, white).
const PIXELS = [_]u8{
    0xFF, 0x00, 0x00, 0xFF,
    0x00, 0xFF, 0x00, 0xFF,
    0x00, 0x00, 0xFF, 0xFF,
    0xFF, 0xFF, 0xFF, 0xFF,
};

fn base64Alloc(pixels: []const u8) ![]u8 {
    const enc = std.base64.standard.Encoder;
    const buf = try talloc.alloc(u8, enc.calcSize(pixels.len));
    _ = enc.encode(buf, pixels);
    return buf;
}

/// Build a Kitty a=T (transmit + place at cursor) escape for an RGBA image.
fn transmitPlace(id: u32, s: u32, v: u32, cols: u32, rows: u32, pixels: []const u8) ![]u8 {
    const b64 = try base64Alloc(pixels);
    defer talloc.free(b64);
    return std.fmt.allocPrint(talloc, "\x1b_Ga=T,f=32,i={d},s={d},v={d},c={d},r={d};{s}\x1b\\", .{ id, s, v, cols, rows, b64 });
}

fn deleteById(id: u32) ![]u8 {
    return std.fmt.allocPrint(talloc, "\x1b_Ga=d,d=i,i={d}\x1b\\", .{id});
}

const H = struct {
    sess: *session.Session,

    fn init(rows: u16, cols: u16, scrollback: u32) !H {
        const rect = session.Rect{ .x = 0, .y = 0, .width = cols, .height = rows };
        return .{ .sess = try session.Session.init(talloc, "gfx", rect, scrollback) };
    }
    fn deinit(self: *H) void {
        self.sess.deinit();
    }
    fn feed(self: *H, bytes: []const u8) void {
        self.sess.getActiveWindow().getActivePane().processOutput(bytes);
    }
    fn term(self: *H) *terminal.Terminal {
        return &self.sess.getActiveWindow().getActivePane().terminal;
    }
    /// Count placements whose clipped rect is currently on-screen (mirrors
    /// tmux_placement_count).
    fn visibleCount(self: *H) usize {
        const t = self.term();
        const top = t.graphicsViewportTopAbs();
        var n: usize = 0;
        for (t.graphics.placements.items) |p| {
            const img = t.graphics.findImage(p.image_id) orelse continue;
            if (gfx.clip(p, img, top, t.grid.rows, t.grid.cols) != null) n += 1;
        }
        return n;
    }
};

fn freedContains(t: *terminal.Terminal, id: u32) bool {
    for (t.graphics_freed.items) |x| {
        if (x == id) return true;
    }
    return false;
}

// ============================================================================
// 1. Scroll off the top of scrollback → evicted + freed.
// ============================================================================
test "lifecycle 1: scroll off top of scrollback evicts the placement and frees the image" {
    var h = try H.init(10, 20, 4); // tiny scrollback so eviction is quick
    defer h.deinit();

    const stream = try transmitPlace(1, 2, 2, 2, 2, &PIXELS);
    defer talloc.free(stream);
    h.feed(stream);

    try std.testing.expectEqual(@as(usize, 1), h.term().graphics.placements.items.len);
    try std.testing.expectEqual(@as(usize, 1), h.term().graphics.images.items.len);
    try std.testing.expectEqual(@as(usize, 1), h.visibleCount());

    // Scroll far past the scrollback depth. The placement (anchor 0) is gone
    // once its whole rect drops below the oldest retained line.
    var i: usize = 0;
    while (i < 60) : (i += 1) h.feed("\n");

    try std.testing.expectEqual(@as(usize, 0), h.term().graphics.placements.items.len);
    try std.testing.expectEqual(@as(usize, 0), h.term().graphics.images.items.len);
    try std.testing.expectEqual(@as(usize, 0), h.visibleCount());
    try std.testing.expect(freedContains(h.term(), 1)); // image freed → host releases texture
}

// ============================================================================
// 2. Partial viewport clip → clipped rect, source crop, never OOB.
// ============================================================================
test "lifecycle 2: a placement scrolled partly above the top reports a clipped, in-bounds rect" {
    var h = try H.init(10, 20, 100);
    defer h.deinit();

    // Place a 2x4-cell image (image 2x8 px) at row 1.
    h.feed("\x1b[2;1H"); // CUP row 2 (0-based row 1)
    const stream = try transmitPlace(1, 2, 8, 2, 4, &PIXELS);
    defer talloc.free(stream);
    h.feed(stream);
    try std.testing.expectEqual(@as(i64, 1), h.term().graphics.placements.items[0].anchor_line);

    // Scroll up 3: the image top (anchor 1) is now 2 rows above the top row.
    h.feed("\x1b[3S");

    const t = h.term();
    const top = t.graphicsViewportTopAbs();
    const p = t.graphics.placements.items[0];
    const img = t.graphics.findImage(p.image_id).?;
    const vr = gfx.clip(p, img, top, t.grid.rows, t.grid.cols).?;

    // On-screen rect is clamped to the viewport (top-left, 2 of 4 rows remain).
    try std.testing.expectEqual(@as(u16, 0), vr.cell_y);
    try std.testing.expectEqual(@as(u16, 2), vr.cell_h);
    // Never out of bounds.
    try std.testing.expect(vr.cell_y + vr.cell_h <= t.grid.rows);
    try std.testing.expect(vr.cell_x + vr.cell_w <= t.grid.cols);
    // Source crop skips the 2 clipped rows: 2/4 of 8px = 4px off the top.
    try std.testing.expectEqual(@as(u32, 4), vr.src_y);
    try std.testing.expectEqual(@as(u32, 4), vr.src_h);
}

// ============================================================================
// 3. Resize under a placement → no crash, cell size unchanged, sane clip.
// ============================================================================
test "lifecycle 3: resize under a placement keeps cell size, survives anchor, clips sanely" {
    var h = try H.init(10, 20, 100);
    defer h.deinit();

    h.feed("\x1b[4;1H"); // row 4 (0-based 3)
    const stream = try transmitPlace(1, 8, 8, 4, 4, &PIXELS);
    defer talloc.free(stream);
    h.feed(stream);
    try std.testing.expectEqual(@as(i64, 3), h.term().graphics.placements.items[0].anchor_line);

    // Shrink both dimensions under the placement.
    try h.term().resize(6, 6);

    const t = h.term();
    const p = t.graphics.placements.items[0];
    // Cell size is fixed at place-time (images are sized in cells, not reflowed).
    try std.testing.expectEqual(@as(u16, 4), p.cell_w);
    try std.testing.expectEqual(@as(u16, 4), p.cell_h);
    try std.testing.expectEqual(@as(i64, 3), p.anchor_line);

    const top = t.graphicsViewportTopAbs();
    const img = t.graphics.findImage(p.image_id).?;
    const vr = gfx.clip(p, img, top, t.grid.rows, t.grid.cols).?;
    // Clipped to the new 6x6 geometry, never OOB.
    try std.testing.expect(vr.cell_x + vr.cell_w <= 6);
    try std.testing.expect(vr.cell_y + vr.cell_h <= 6);
    try std.testing.expectEqual(@as(u16, 3), vr.cell_y);
    try std.testing.expectEqual(@as(u16, 3), vr.cell_h); // rows 3..6
}

// ============================================================================
// 4. Alt-screen switch → per-screen isolation, alt placements freed on exit.
// ============================================================================
test "lifecycle 4: alt-screen placements never leak into the primary; freed on exit" {
    var h = try H.init(10, 20, 100);
    defer h.deinit();

    // Place image 1 on the PRIMARY screen.
    const s1 = try transmitPlace(1, 2, 2, 2, 2, &PIXELS);
    defer talloc.free(s1);
    h.feed(s1);
    try std.testing.expectEqual(@as(usize, 1), h.term().graphics.placements.items.len);

    // Enter the alt screen: placements swap to a fresh, empty set.
    h.feed("\x1b[?1049h");
    try std.testing.expect(h.term().modes.alt_screen);
    try std.testing.expectEqual(@as(usize, 0), h.term().graphics.placements.items.len);

    // Place image 2 on the ALT screen (as DOOM would per frame).
    const s2 = try transmitPlace(2, 2, 2, 2, 2, &PIXELS);
    defer talloc.free(s2);
    h.feed(s2);
    try std.testing.expectEqual(@as(usize, 1), h.term().graphics.placements.items.len);
    try std.testing.expectEqual(@as(u32, 2), h.term().graphics.placements.items[0].image_id);

    // Exit the alt screen: alt placements are DISCARDED, alt image freed, and
    // the primary set is restored byte-for-byte.
    h.feed("\x1b[?1049l");
    try std.testing.expect(!h.term().modes.alt_screen);
    try std.testing.expectEqual(@as(usize, 1), h.term().graphics.placements.items.len);
    try std.testing.expectEqual(@as(u32, 1), h.term().graphics.placements.items[0].image_id); // primary's own
    try std.testing.expectEqual(@as(usize, 1), h.term().graphics.images.items.len);
    try std.testing.expectEqual(@as(u32, 1), h.term().graphics.images.items[0].id);
    // The alt image (2) was freed; the primary image (1) was NOT.
    try std.testing.expect(freedContains(h.term(), 2));
    try std.testing.expect(!freedContains(h.term(), 1));
}

// ============================================================================
// ABI integration — the C ABI surface a host renderer drives, staged so we see
// the placement appear, move with a scroll, expose its bytes, and free on delete.
// ============================================================================
test "graphics ABI: transmit, place, image_data, scroll-move, delete + freed" {
    try pty.skipIfUnavailable();
    var id: u64 = 0;
    const hh = capi.tmux_create(24, 80, "/bin/cat", &id) orelse return error.CreateFailed;
    defer capi.tmux_destroy(hh);

    const gen0 = capi.tmux_graphics_generation(hh);

    // Transmit + place a 2x2 image at row 3 (CUP row 4).
    capi.tmux_feed(hh, "\x1b[4;1H", 6);
    const stream = try transmitPlace(1, 2, 2, 2, 2, &PIXELS);
    defer talloc.free(stream);
    capi.tmux_feed(hh, stream.ptr, stream.len);

    try std.testing.expectEqual(@as(usize, 1), capi.tmux_placement_count(hh));
    try std.testing.expect(capi.tmux_graphics_generation(hh) > gen0);

    var pl: capi.CPlacement = undefined;
    try std.testing.expectEqual(@as(c_int, 0), capi.tmux_placement_at(hh, 0, &pl));
    try std.testing.expectEqual(@as(u32, 1), pl.image_id);
    try std.testing.expectEqual(@as(u16, 0), pl.cell_x);
    try std.testing.expectEqual(@as(u16, 3), pl.cell_y);
    try std.testing.expectEqual(@as(u16, 2), pl.cell_w);
    try std.testing.expectEqual(@as(u16, 2), pl.cell_h);
    try std.testing.expectEqual(@as(c_int, -1), capi.tmux_placement_at(hh, 1, &pl)); // only one

    // Image bytes + info come straight back (host decodes; core does not).
    var info: capi.CImageInfo = undefined;
    var buf: [64]u8 = undefined;
    const n = capi.tmux_image_data(hh, 1, &buf, buf.len, &info);
    try std.testing.expectEqual(@as(usize, 16), n);
    try std.testing.expectEqual(@as(u32, 2), info.width);
    try std.testing.expectEqual(@as(u32, 2), info.height);
    try std.testing.expectEqual(@as(u8, 0), info.format); // RGBA
    try std.testing.expectEqualSlices(u8, &PIXELS, buf[0..16]);

    // Scroll up 2 — the placement MOVES with the content (anchor line fixed).
    capi.tmux_feed(hh, "\x1b[2S", 4);
    try std.testing.expectEqual(@as(usize, 1), capi.tmux_placement_count(hh));
    try std.testing.expectEqual(@as(c_int, 0), capi.tmux_placement_at(hh, 0, &pl));
    try std.testing.expectEqual(@as(u16, 1), pl.cell_y); // 3 → 1

    // Drain freed, then delete by id → count 0, freed reports the id.
    _ = capi.tmux_take_freed_images(hh, null, 0);
    const del = try deleteById(1);
    defer talloc.free(del);
    capi.tmux_feed(hh, del.ptr, del.len);
    try std.testing.expectEqual(@as(usize, 0), capi.tmux_placement_count(hh));

    var freed: [8]u32 = undefined;
    const nfreed = capi.tmux_take_freed_images(hh, &freed, freed.len);
    try std.testing.expectEqual(@as(usize, 1), nfreed);
    try std.testing.expectEqual(@as(u32, 1), freed[0]);
    // Image is gone from the store.
    try std.testing.expectEqual(@as(usize, 0), capi.tmux_image_data(hh, 1, null, 0, null));
}

// ============================================================================
// Committed recorded-stream anchor: tests/fixtures/graphics_kitty_rgba.bin
// transmits a 2x2 RGBA image, places it at row 5, and scrolls up 3. The ABI
// must report the image present and the placement moved to row 2.
// ============================================================================
test "recorded-stream anchor: committed .bin replays to the expected ABI state" {
    const fixture = @embedFile("graphics_fixture");

    try pty.skipIfUnavailable();
    var id: u64 = 0;
    const hh = capi.tmux_create(24, 80, "/bin/cat", &id) orelse return error.CreateFailed;
    defer capi.tmux_destroy(hh);

    capi.tmux_feed(hh, fixture.ptr, fixture.len);

    try std.testing.expectEqual(@as(usize, 1), capi.tmux_placement_count(hh));
    var pl: capi.CPlacement = undefined;
    try std.testing.expectEqual(@as(c_int, 0), capi.tmux_placement_at(hh, 0, &pl));
    try std.testing.expectEqual(@as(u32, 1), pl.image_id);
    try std.testing.expectEqual(@as(u16, 2), pl.cell_y); // placed at row 5, scrolled up 3
    try std.testing.expectEqual(@as(u16, 2), pl.cell_w);
    try std.testing.expectEqual(@as(u16, 2), pl.cell_h);

    var info: capi.CImageInfo = undefined;
    var buf: [64]u8 = undefined;
    const n = capi.tmux_image_data(hh, 1, &buf, buf.len, &info);
    try std.testing.expectEqual(@as(usize, 16), n);
    try std.testing.expectEqual(@as(u32, 2), info.width);
    try std.testing.expectEqualSlices(u8, &PIXELS, buf[0..16]);

    // Delete frees it.
    const del = try deleteById(1);
    defer talloc.free(del);
    capi.tmux_feed(hh, del.ptr, del.len);
    try std.testing.expectEqual(@as(usize, 0), capi.tmux_placement_count(hh));
    var freed: [8]u32 = undefined;
    try std.testing.expectEqual(@as(usize, 1), capi.tmux_take_freed_images(hh, &freed, freed.len));
    try std.testing.expectEqual(@as(u32, 1), freed[0]);
}
