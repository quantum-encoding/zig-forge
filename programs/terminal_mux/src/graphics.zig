//! Inline graphics — Kitty graphics protocol (Phase 1 subset).
//!
//! The emulator is a byte-pipe + geometry tracker: it captures transmitted
//! image bytes (RGB / RGBA / PNG) verbatim and tracks where each image is
//! placed on the grid. It does NOT decode — the host renderer decodes (see
//! docs/SPEC_GraphicsProtocol.md, "Decoding — host-side"). PNG bytes are stored
//! opaque; RGB/RGBA are stored as-is after base64 decoding.
//!
//! Placements are anchored to an ABSOLUTE line index (`anchor_line`), the same
//! monotonic numbering the scrollback ring implies — so scrolling is O(1) (the
//! viewport-top line number moves; placements are untouched) and the renderer
//! resolves each placement's on-screen row at read time as
//! `anchor_line - viewport_top_abs`.
//!
//! Whitelist (anything outside this is silently accepted-and-ignored):
//!   a = t (transmit) / T (transmit+place at cursor) / p (place by id) /
//!         d (delete: d=i by id, d=a all)
//!   f = 24 (RGB) / 32 (RGBA) / 100 (PNG, host-decoded)
//!   t = d (direct base64) ONLY — t=f/t=t/t=s rejected
//!   m = 1 continuation chunks until m=0
//!   c=/r= placement size in cells, i= image id
//!   unknown keys ignored-but-consumed.

const std = @import("std");

/// Per-pane image store cap. Past this a new image is refused (DoS guard, same
/// spirit as the OSC length bound). Chosen per SPEC "Risks": ~64 MiB/pane.
pub const STORE_CAP_BYTES: usize = 64 * 1024 * 1024;

/// Hard cap on the streaming APC payload accumulator (base64 text across
/// continuation chunks). Base64 inflates ~4/3, so allow a little over the store
/// cap; past this the transmission is dropped.
pub const APC_ACCUM_CAP: usize = 96 * 1024 * 1024;

pub const ImageFormat = enum(u8) {
    rgba = 0,
    rgb = 1,
    png = 2,
    iterm = 3,

    /// The wire format code (Kitty `f=`) → internal tag, or null if unsupported.
    pub fn fromKitty(f: u32) ?ImageFormat {
        return switch (f) {
            32 => .rgba,
            24 => .rgb,
            100 => .png,
            else => null,
        };
    }
};

pub const Image = struct {
    id: u32,
    width: u32,
    height: u32,
    format: ImageFormat,
    bytes: []u8,
};

/// A placement of an image on the grid, anchored to an absolute line index.
pub const Placement = struct {
    image_id: u32,
    /// Absolute line index of the image's TOP row (scrollback-absolute).
    anchor_line: i64,
    /// Left column (grid-local at place time).
    col: u16,
    /// Size in cells (Kitty c= / r=).
    cell_w: u16,
    cell_h: u16,
    z: i32 = 0,
};

/// The clipped, on-screen rect the host should draw, plus the source pixel crop
/// to sample. Cell coords are grid-local; src coords are image-pixel space.
pub const VisibleRect = struct {
    cell_x: u16,
    cell_y: u16,
    cell_w: u16,
    cell_h: u16,
    src_x: u32,
    src_y: u32,
    src_w: u32,
    src_h: u32,
};

/// Graphics state for ONE screen (primary or alt). Rides the alt-screen swap:
/// entering alt swaps in a fresh empty state; exiting frees the alt state
/// (signalling every image freed) and restores the primary byte-for-byte.
pub const GraphicsState = struct {
    images: std.ArrayListUnmanaged(Image) = .empty,
    placements: std.ArrayListUnmanaged(Placement) = .empty,
    total_bytes: usize = 0,
    /// Absolute line index of grid logical row 0 for THIS screen. Advanced on
    /// scroll-up, retreated on scroll-down. Placements anchor to `epoch + row`.
    epoch: i64 = 0,

    pub const empty: GraphicsState = .{};

    /// Free every image's bytes, pushing each freed id into `freed` (so the host
    /// can release the matching GPU texture), then free the containers.
    pub fn deinit(self: *GraphicsState, allocator: std.mem.Allocator, freed: ?*std.ArrayListUnmanaged(u32)) void {
        for (self.images.items) |img| {
            if (freed) |q| q.append(allocator, img.id) catch {};
            allocator.free(img.bytes);
        }
        self.images.deinit(allocator);
        self.placements.deinit(allocator);
        self.total_bytes = 0;
    }

    pub fn findImage(self: *const GraphicsState, id: u32) ?*const Image {
        for (self.images.items) |*img| {
            if (img.id == id) return img;
        }
        return null;
    }

    fn imageIndex(self: *const GraphicsState, id: u32) ?usize {
        for (self.images.items, 0..) |img, i| {
            if (img.id == id) return i;
        }
        return null;
    }

    /// Whether any placement still references `id`.
    fn referenced(self: *const GraphicsState, id: u32) bool {
        for (self.placements.items) |p| {
            if (p.image_id == id) return true;
        }
        return false;
    }

    /// Store (or replace) an image. Enforces the byte cap: an image that would
    /// push total over the cap is refused (bytes freed by the caller path).
    /// Returns true on success. `freed` collects the id of a replaced image.
    pub fn putImage(
        self: *GraphicsState,
        allocator: std.mem.Allocator,
        img: Image,
        freed: *std.ArrayListUnmanaged(u32),
    ) bool {
        // Replace an existing image with the same id.
        if (self.imageIndex(img.id)) |idx| {
            const old = self.images.items[idx];
            self.total_bytes -= old.bytes.len;
            allocator.free(old.bytes);
            freed.append(allocator, img.id) catch {};
            self.images.items[idx] = img;
            self.total_bytes += img.bytes.len;
            return true;
        }
        if (self.total_bytes + img.bytes.len > STORE_CAP_BYTES) {
            return false; // caller frees img.bytes and drops
        }
        self.images.append(allocator, img) catch return false;
        self.total_bytes += img.bytes.len;
        return true;
    }

    /// Free image `id` and drop every placement referencing it. Signals the id.
    pub fn freeImage(
        self: *GraphicsState,
        allocator: std.mem.Allocator,
        id: u32,
        freed: *std.ArrayListUnmanaged(u32),
    ) void {
        // Drop placements first.
        var i: usize = 0;
        while (i < self.placements.items.len) {
            if (self.placements.items[i].image_id == id) {
                _ = self.placements.orderedRemove(i);
            } else i += 1;
        }
        if (self.imageIndex(id)) |idx| {
            const img = self.images.items[idx];
            self.total_bytes -= img.bytes.len;
            allocator.free(img.bytes);
            _ = self.images.orderedRemove(idx);
            freed.append(allocator, id) catch {};
        }
    }

    /// Delete everything: all placements and all images (each id signalled).
    pub fn clearAll(self: *GraphicsState, allocator: std.mem.Allocator, freed: *std.ArrayListUnmanaged(u32)) void {
        self.placements.clearRetainingCapacity();
        for (self.images.items) |img| {
            freed.append(allocator, img.id) catch {};
            allocator.free(img.bytes);
        }
        self.images.clearRetainingCapacity();
        self.total_bytes = 0;
    }

    /// Evict placements whose ENTIRE rect has scrolled above `min_retained_abs`
    /// (their content is gone from history). Frees an image once no placement
    /// references it. Returns true if anything was evicted.
    pub fn prune(
        self: *GraphicsState,
        allocator: std.mem.Allocator,
        min_retained_abs: i64,
        freed: *std.ArrayListUnmanaged(u32),
    ) bool {
        var changed = false;
        var i: usize = 0;
        while (i < self.placements.items.len) {
            const p = self.placements.items[i];
            if (p.anchor_line + @as(i64, p.cell_h) <= min_retained_abs) {
                _ = self.placements.orderedRemove(i);
                changed = true;
                // If no other placement references the image, free it.
                if (!self.referenced(p.image_id)) {
                    if (self.imageIndex(p.image_id)) |idx| {
                        const img = self.images.items[idx];
                        self.total_bytes -= img.bytes.len;
                        allocator.free(img.bytes);
                        _ = self.images.orderedRemove(idx);
                        freed.append(allocator, p.image_id) catch {};
                    }
                }
            } else i += 1;
        }
        return changed;
    }
};

/// Clip a placement to the viewport `[0,rows) x [0,cols)` and compute the source
/// pixel crop. Returns null if the placement is not visible.
pub fn clip(p: Placement, img: *const Image, viewport_top_abs: i64, rows: u16, cols: u16) ?VisibleRect {
    if (p.cell_w == 0 or p.cell_h == 0) return null;
    if (p.col >= cols) return null;

    const on_top: i64 = p.anchor_line - viewport_top_abs;
    const on_bot: i64 = on_top + @as(i64, p.cell_h);

    const vis_y0: i64 = @max(@as(i64, 0), on_top);
    const vis_y1: i64 = @min(@as(i64, rows), on_bot);
    if (vis_y1 <= vis_y0) return null;

    const cell_w_clip: u16 = @min(p.cell_w, cols - p.col);

    // Rows clipped from the top / bottom of the placement.
    const dtop: u64 = @intCast(vis_y0 - on_top);
    const rows_shown: u64 = @intCast(vis_y1 - vis_y0);

    const H: u64 = img.height;
    const W: u64 = img.width;
    const ch: u64 = p.cell_h;
    const cw: u64 = p.cell_w;

    // Source vertical crop, scaled by the fraction of cells shown.
    const src_y: u64 = if (ch == 0) 0 else dtop * H / ch;
    const src_y_end: u64 = if (ch == 0) H else (dtop + rows_shown) * H / ch;
    const src_h: u64 = if (src_y_end > src_y) src_y_end - src_y else 0;

    // Source horizontal crop (only right-clipped; col is always >= 0).
    const src_w: u64 = if (cw == 0) W else @as(u64, cell_w_clip) * W / cw;

    return VisibleRect{
        .cell_x = p.col,
        .cell_y = @intCast(vis_y0),
        .cell_w = cell_w_clip,
        .cell_h = @intCast(rows_shown),
        .src_x = 0,
        .src_y = @intCast(src_y),
        .src_w = @intCast(src_w),
        .src_h = @intCast(src_h),
    };
}

// =============================================================================
// Kitty APC control parse
// =============================================================================

pub const Action = enum { transmit, transmit_place, place, delete, unknown };

/// Parsed Kitty control block (the `key=value,...` before the `;`).
pub const Control = struct {
    a: Action = .transmit, // default action is transmit
    f: u32 = 32, // default RGBA
    t: u8 = 'd', // default direct
    i: u32 = 0, // image id
    s: u32 = 0, // width (pixels)
    v: u32 = 0, // height (pixels)
    c: u32 = 0, // columns (cells)
    r: u32 = 0, // rows (cells)
    m: u32 = 0, // more-chunks flag
    d: u8 = 'a', // delete target (default all)
    has_m: bool = false,

    /// Parse `key=value` pairs separated by ','. Unknown keys are consumed and
    /// ignored. `ctrl` is the slice AFTER the leading 'G' and BEFORE the ';'.
    pub fn parse(ctrl: []const u8) Control {
        var out: Control = .{};
        var it = std.mem.splitScalar(u8, ctrl, ',');
        while (it.next()) |pair| {
            if (pair.len == 0) continue;
            const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
            const key = pair[0..eq];
            const val = pair[eq + 1 ..];
            if (key.len == 0 or val.len == 0) continue;
            if (key.len == 1) {
                switch (key[0]) {
                    'a' => out.a = switch (val[0]) {
                        't' => .transmit,
                        'T' => .transmit_place,
                        'p' => .place,
                        'd' => .delete,
                        else => .unknown,
                    },
                    'f' => out.f = parseU32(val) orelse out.f,
                    't' => out.t = val[0],
                    'i' => out.i = parseU32(val) orelse 0,
                    's' => out.s = parseU32(val) orelse 0,
                    'v' => out.v = parseU32(val) orelse 0,
                    'c' => out.c = parseU32(val) orelse 0,
                    'r' => out.r = parseU32(val) orelse 0,
                    'm' => {
                        out.m = parseU32(val) orelse 0;
                        out.has_m = true;
                    },
                    'd' => out.d = val[0],
                    else => {}, // unknown single-char key: ignored-but-consumed
                }
            }
            // multi-char keys (none in scope) are ignored-but-consumed
        }
        return out;
    }
};

fn parseU32(s: []const u8) ?u32 {
    return std.fmt.parseInt(u32, s, 10) catch null;
}

// =============================================================================
// Tests (pure logic — no terminal)
// =============================================================================

test "Control.parse basic transmit+place" {
    const c = Control.parse("a=T,f=32,i=7,s=4,v=4,c=2,r=2");
    try std.testing.expectEqual(Action.transmit_place, c.a);
    try std.testing.expectEqual(@as(u32, 32), c.f);
    try std.testing.expectEqual(@as(u32, 7), c.i);
    try std.testing.expectEqual(@as(u32, 2), c.c);
    try std.testing.expectEqual(@as(u32, 2), c.r);
}

test "Control.parse ignores unknown keys, consumes payload boundary" {
    const c = Control.parse("q=1,X=99,a=p,i=3,z=5,Y=2");
    try std.testing.expectEqual(Action.place, c.a);
    try std.testing.expectEqual(@as(u32, 3), c.i);
}

test "Control.parse chunk continuation (m only)" {
    const c = Control.parse("m=1");
    try std.testing.expect(c.has_m);
    try std.testing.expectEqual(@as(u32, 1), c.m);
}

test "ImageFormat.fromKitty whitelist" {
    try std.testing.expectEqual(ImageFormat.rgba, ImageFormat.fromKitty(32).?);
    try std.testing.expectEqual(ImageFormat.rgb, ImageFormat.fromKitty(24).?);
    try std.testing.expectEqual(ImageFormat.png, ImageFormat.fromKitty(100).?);
    try std.testing.expectEqual(@as(?ImageFormat, null), ImageFormat.fromKitty(8));
}

test "clip: fully visible" {
    var img = Image{ .id = 1, .width = 40, .height = 40, .format = .rgba, .bytes = &.{} };
    const p = Placement{ .image_id = 1, .anchor_line = 5, .col = 3, .cell_w = 4, .cell_h = 4 };
    // viewport top = 0, so on-screen top row = 5
    const v = clip(p, &img, 0, 24, 80).?;
    try std.testing.expectEqual(@as(u16, 3), v.cell_x);
    try std.testing.expectEqual(@as(u16, 5), v.cell_y);
    try std.testing.expectEqual(@as(u16, 4), v.cell_w);
    try std.testing.expectEqual(@as(u16, 4), v.cell_h);
    try std.testing.expectEqual(@as(u32, 0), v.src_y);
    try std.testing.expectEqual(@as(u32, 40), v.src_h);
}

test "clip: partial top clip adjusts src crop" {
    var img = Image{ .id = 1, .width = 40, .height = 40, .format = .rgba, .bytes = &.{} };
    // anchor 0, viewport top 2 => on-screen top = -2 (2 rows above the top row)
    const p = Placement{ .image_id = 1, .anchor_line = 0, .col = 0, .cell_w = 4, .cell_h = 4 };
    const v = clip(p, &img, 2, 24, 80).?;
    try std.testing.expectEqual(@as(u16, 0), v.cell_y); // clamped on screen
    try std.testing.expectEqual(@as(u16, 2), v.cell_h); // 2 rows remain
    try std.testing.expectEqual(@as(u32, 20), v.src_y); // 2/4 of 40px cropped off top
    try std.testing.expectEqual(@as(u32, 20), v.src_h);
}

test "clip: entirely above viewport => null" {
    var img = Image{ .id = 1, .width = 8, .height = 8, .format = .rgba, .bytes = &.{} };
    const p = Placement{ .image_id = 1, .anchor_line = 0, .col = 0, .cell_w = 2, .cell_h = 2 };
    try std.testing.expectEqual(@as(?VisibleRect, null), clip(p, &img, 10, 24, 80));
}
