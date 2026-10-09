//! Solar letter: a one-page A4 personalised letter an installer sends to a
//! householder about putting solar panels on their roof.
//!
//! The installer's brand (name, logo, colours, accreditation marks) and every
//! figure arrive in the payload: the template holds layout and the wording the
//! law requires, nothing about any one installer. Figures are display strings,
//! formatted by the caller; this module checks they are present, not their
//! arithmetic.
//!
//! Layout, top to bottom: a gradient bar; logo with phone, website and date;
//! the address block (dark on white, where a window envelope shows it); the
//! headline with one phrase marked by a highlighter band; the intro; the roof
//! picture full width; up to three figure cards in a row; the package as ticked
//! columns; the offer block with its QR code; a phone strip; accreditation
//! marks; small print.
//!
//! Input shape (every field required unless marked optional):
//! ```json
//! {
//!   "installer": { "name", "phone", "website", "logo",
//!                  "theme": { "ink_hex", "dark_hex", "primary_hex",
//!                             "accent_hex", "label_hex", "link_hex" },
//!                  "accreditations": ["<image>", ...],              // optional, up to 10
//!                  "legal_line": "Registered in England ..." },     // optional
//!   "letter":    { "reference", "date", "recipient": ["The Occupier", "1 High St", ...],
//!                  "headline", "headline_highlight" (optional, a phrase of the headline),
//!                  "intro", "qr_url": "https://...", "qr_caption", "small_print" },
//!   "package":   [ { "label", "value" } ],                           // 1 to 4 ticked columns
//!   "stats":     [ { "label", "value", "note" (optional) } ],        // 1 to 3 cards
//!   "image":     { "src", "caption" (optional) },
//!   "offer":     { "kind": "price" | "finance" | "grant", ... }
//! }
//! ```
//! Theme: ink is the headline and the darkest card and strip; dark and primary
//! are the other cards, the offer gradient and the ticks; accent is the
//! highlighter, the price and the phone number on dark; label is small capitals
//! on dark; link is the website and date line and the end of the top bar.
//! Images (logo, accreditations, image.src) are PNG or JPEG as raw base64, a
//! `data:` URL, or (CLI only) a file path.
//!
//! Offers:
//!   - price:   headline, price, price_note (optional), includes (0 to 3).
//!   - finance: headline, monthly, apr, term_months, interest_rate, credit,
//!              deposit, cash_price, total_payable, lender, other_charges
//!              (optional). These are the parts of a representative example
//!              (FCA CONC 3.5.5R); the template writes the example itself, and
//!              shows the representative APR at the same size as the monthly
//!              payment (CONC 3.5.7R(2): no less prominence than its trigger).
//!   - grant:   scheme, headline, body, criteria (1 to 4). No price fields.
//!
//! Refusals (each is an error with a message, never a PDF): an unknown or
//! missing field, an empty string, a character the letter's fonts can't print,
//! a colour that isn't #RRGGBB, a QR address that isn't https, an image that
//! isn't a PNG or JPEG, a list outside its limits, or text that doesn't fit its
//! space on the page.

const std = @import("std");
const document = @import("document.zig");
const image = @import("image.zig");
const qrcode = @import("qrcode.zig");

const Allocator = std.mem.Allocator;
const Color = document.Color;
const Font = document.Font;
const ContentStream = document.ContentStream;

pub const Error = error{
    /// A field is missing, unknown, empty, the wrong type or out of range.
    InvalidInput,
    /// An image isn't a readable PNG or JPEG.
    ImageInvalid,
    /// Text doesn't fit the space the layout gives it.
    TooLong,
    /// The PDF couldn't be laid out or written.
    PdfFailed,
    OutOfMemory,
};

/// Human-readable reason for the last error, sized to fit the FFI error buffer.
pub const Diagnostic = struct {
    buf: [240]u8 = undefined,
    len: usize = 0,

    pub fn set(self: *Diagnostic, comptime fmt: []const u8, args: anytype) void {
        const s = std.fmt.bufPrint(&self.buf, fmt, args) catch blk: {
            const cut = "...";
            @memcpy(self.buf[self.buf.len - cut.len ..], cut);
            break :blk self.buf[0..];
        };
        self.len = s.len;
    }

    pub fn text(self: *const Diagnostic) []const u8 {
        return self.buf[0..self.len];
    }
};

// =============================================================================
// Input model
// =============================================================================

pub const Theme = struct {
    ink: Color,
    dark: Color,
    primary: Color,
    accent: Color,
    label: Color,
    link: Color,
};

pub const Installer = struct {
    name: []const u8,
    phone: []const u8,
    website: []const u8,
    logo: []const u8,
    theme: Theme,
    accreditations: []const []const u8,
    legal_line: ?[]const u8,
};

pub const Row = struct { label: []const u8, value: []const u8 };
pub const Stat = struct { label: []const u8, value: []const u8, note: ?[]const u8 };

pub const PriceOffer = struct {
    headline: []const u8,
    price: []const u8,
    price_note: ?[]const u8,
    includes: []const []const u8,
};

pub const FinanceOffer = struct {
    headline: []const u8,
    monthly: []const u8,
    apr: []const u8,
    term_months: []const u8,
    interest_rate: []const u8,
    credit: []const u8,
    deposit: []const u8,
    cash_price: []const u8,
    total_payable: []const u8,
    lender: []const u8,
    other_charges: ?[]const u8,
};

pub const GrantOffer = struct {
    scheme: []const u8,
    headline: []const u8,
    body: []const u8,
    criteria: []const []const u8,
};

pub const Offer = union(enum) {
    price: PriceOffer,
    finance: FinanceOffer,
    grant: GrantOffer,
};

pub const Letter = struct {
    installer: Installer,
    reference: []const u8,
    date: []const u8,
    recipient: []const []const u8,
    headline: []const u8,
    /// A phrase of the headline drawn over a highlighter band.
    headline_highlight: ?[]const u8,
    intro: []const u8,
    qr_url: []const u8,
    qr_caption: []const u8,
    small_print: []const u8,
    package: []const Row,
    stats: []const Stat,
    image_src: []const u8,
    image_caption: ?[]const u8,
    offer: Offer,
};

// =============================================================================
// Strict JSON reading
// =============================================================================

/// One JSON object being read, with the dotted path used in error messages.
const Obj = struct {
    map: std.json.ObjectMap,
    path: []const u8,
    arena: Allocator,
    diag: *Diagnostic,

    fn of(v: std.json.Value, path: []const u8, arena: Allocator, diag: *Diagnostic) Error!Obj {
        if (v != .object) {
            diag.set("{s} must be an object", .{path});
            return error.InvalidInput;
        }
        return .{ .map = v.object, .path = path, .arena = arena, .diag = diag };
    }

    /// Refuse any key not in `allowed`: a misspelt optional field would
    /// otherwise vanish silently from the printed letter.
    fn only(self: Obj, allowed: []const []const u8) Error!void {
        for (self.map.keys()) |k| {
            for (allowed) |a| {
                if (std.mem.eql(u8, a, k)) break;
            } else {
                self.diag.set("{s}: unknown field '{s}'", .{ self.path, k });
                return error.InvalidInput;
            }
        }
    }

    fn get(self: Obj, key: []const u8) Error!std.json.Value {
        return self.map.get(key) orelse {
            self.diag.set("{s}.{s} is required", .{ self.path, key });
            return error.InvalidInput;
        };
    }

    /// Required text that will be printed.
    fn str(self: Obj, key: []const u8) Error![]const u8 {
        return self.text(try self.get(key), key);
    }

    fn optStr(self: Obj, key: []const u8) Error!?[]const u8 {
        const v = self.map.get(key) orelse return null;
        if (v == .null) return null;
        return try self.text(v, key);
    }

    fn text(self: Obj, v: std.json.Value, key: []const u8) Error![]const u8 {
        if (v != .string or std.mem.trim(u8, v.string, " \t").len == 0) {
            self.diag.set("{s}.{s} must be a non-empty string", .{ self.path, key });
            return error.InvalidInput;
        }
        try printable(v.string, self.path, key, self.diag);
        return v.string;
    }

    /// An image reference (base64, data: URL or path): non-empty, not printed.
    fn imageRef(self: Obj, v: std.json.Value, key: []const u8) Error![]const u8 {
        if (v != .string or v.string.len == 0) {
            self.diag.set("{s}.{s} must be an image (base64, data: URL or path)", .{ self.path, key });
            return error.InvalidInput;
        }
        return v.string;
    }

    fn child(self: Obj, key: []const u8) Error!Obj {
        const v = try self.get(key);
        const p = try std.fmt.allocPrint(self.arena, "{s}.{s}", .{ self.path, key });
        return Obj.of(v, p, self.arena, self.diag);
    }

    fn array(self: Obj, key: []const u8, min: usize, max: usize, required: bool) Error![]const std.json.Value {
        const v = self.map.get(key) orelse {
            if (!required and min == 0) return &.{};
            self.diag.set("{s}.{s} is required", .{ self.path, key });
            return error.InvalidInput;
        };
        if (v != .array) {
            self.diag.set("{s}.{s} must be a list", .{ self.path, key });
            return error.InvalidInput;
        }
        const n = v.array.items.len;
        if (n < min or n > max) {
            self.diag.set("{s}.{s} has {d} entries; it takes {d} to {d}", .{ self.path, key, n, min, max });
            return error.InvalidInput;
        }
        return v.array.items;
    }

    fn strList(self: Obj, key: []const u8, min: usize, max: usize, required: bool) Error![]const []const u8 {
        const items = try self.array(key, min, max, required);
        const out = try self.arena.alloc([]const u8, items.len);
        for (items, 0..) |item, i| {
            const k = try std.fmt.allocPrint(self.arena, "{s}[{d}]", .{ key, i });
            out[i] = try self.text(item, k);
        }
        return out;
    }

    fn colour(self: Obj, key: []const u8, required: bool) Error!?Color {
        const v = self.map.get(key) orelse {
            if (!required) return null;
            self.diag.set("{s}.{s} is required", .{ self.path, key });
            return error.InvalidInput;
        };
        if (v != .string or !isHexColour(v.string)) {
            self.diag.set("{s}.{s} must be a colour like #2b6531", .{ self.path, key });
            return error.InvalidInput;
        }
        return Color.fromHex(v.string);
    }
};

fn isHexColour(s: []const u8) bool {
    if (s.len != 7 or s[0] != '#') return false;
    for (s[1..]) |c| if (!std.ascii.isHex(c)) return false;
    return true;
}

/// Every character must exist in the letter's fonts (WinAnsi): anything else
/// would print as '?'. Control characters are refused too.
fn printable(s: []const u8, path: []const u8, key: []const u8, diag: *Diagnostic) Error!void {
    var i: usize = 0;
    while (i < s.len) {
        const at = i;
        const c = document.utf8ToWinAnsi(s, &i);
        if ((c == '?' and s[at] != '?') or c < 0x20) {
            diag.set("{s}.{s} has a character the letter can't print (byte {d})", .{ path, key, at });
            return error.InvalidInput;
        }
    }
}

pub fn parse(arena: Allocator, json_str: []const u8, diag: *Diagnostic) Error!Letter {
    const root_v = std.json.parseFromSliceLeaky(std.json.Value, arena, json_str, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            diag.set("input is not valid JSON ({s})", .{@errorName(err)});
            return error.InvalidInput;
        },
    };
    const root = try Obj.of(root_v, "input", arena, diag);
    try root.only(&.{ "installer", "letter", "package", "stats", "image", "offer" });

    const ins = try root.child("installer");
    try ins.only(&.{ "name", "phone", "website", "logo", "theme", "accreditations", "legal_line" });
    const th = try ins.child("theme");
    try th.only(&.{ "ink_hex", "dark_hex", "primary_hex", "accent_hex", "label_hex", "link_hex" });
    const theme = Theme{
        .ink = (try th.colour("ink_hex", true)).?,
        .dark = (try th.colour("dark_hex", true)).?,
        .primary = (try th.colour("primary_hex", true)).?,
        .accent = (try th.colour("accent_hex", true)).?,
        .label = (try th.colour("label_hex", true)).?,
        .link = (try th.colour("link_hex", true)).?,
    };
    const accr_items = try ins.array("accreditations", 0, 10, false);
    const accreditations = try arena.alloc([]const u8, accr_items.len);
    for (accr_items, 0..) |item, i| accreditations[i] = try ins.imageRef(item, "accreditations[]");
    const installer = Installer{
        .name = try ins.str("name"),
        .phone = try ins.str("phone"),
        .website = try ins.str("website"),
        .logo = try ins.imageRef(try ins.get("logo"), "logo"),
        .theme = theme,
        .accreditations = accreditations,
        .legal_line = try ins.optStr("legal_line"),
    };

    const let = try root.child("letter");
    try let.only(&.{ "reference", "date", "recipient", "headline", "headline_highlight", "intro", "qr_url", "qr_caption", "small_print" });
    const headline = try let.str("headline");
    const highlight = try let.optStr("headline_highlight");
    if (highlight) |h| if (std.mem.indexOf(u8, headline, h) == null) {
        diag.set("input.letter.headline_highlight '{s}' is not part of the headline", .{h});
        return error.InvalidInput;
    };
    const qr_url = try let.str("qr_url");
    if (!std.mem.startsWith(u8, qr_url, "https://")) {
        diag.set("input.letter.qr_url must start with https://", .{});
        return error.InvalidInput;
    }

    const pkg_items = try root.array("package", 1, 4, true);
    const package = try arena.alloc(Row, pkg_items.len);
    for (pkg_items, 0..) |item, i| {
        const o = try Obj.of(item, try std.fmt.allocPrint(arena, "input.package[{d}]", .{i}), arena, diag);
        try o.only(&.{ "label", "value" });
        package[i] = .{ .label = try o.str("label"), .value = try o.str("value") };
    }

    const stat_items = try root.array("stats", 1, 3, true);
    const stats = try arena.alloc(Stat, stat_items.len);
    for (stat_items, 0..) |item, i| {
        const o = try Obj.of(item, try std.fmt.allocPrint(arena, "input.stats[{d}]", .{i}), arena, diag);
        try o.only(&.{ "label", "value", "note" });
        stats[i] = .{ .label = try o.str("label"), .value = try o.str("value"), .note = try o.optStr("note") };
    }

    const img = try root.child("image");
    try img.only(&.{ "src", "caption" });

    return .{
        .installer = installer,
        .reference = try let.str("reference"),
        .date = try let.str("date"),
        .recipient = try let.strList("recipient", 2, 7, true),
        .headline = headline,
        .headline_highlight = highlight,
        .intro = try let.str("intro"),
        .qr_url = qr_url,
        .qr_caption = try let.str("qr_caption"),
        .small_print = try let.str("small_print"),
        .package = package,
        .stats = stats,
        .image_src = try img.imageRef(try img.get("src"), "src"),
        .image_caption = try img.optStr("caption"),
        .offer = try parseOffer(try root.child("offer")),
    };
}

fn parseOffer(o: Obj) Error!Offer {
    const kind = try o.str("kind");
    if (std.mem.eql(u8, kind, "price")) {
        try o.only(&.{ "kind", "headline", "price", "price_note", "includes" });
        return .{ .price = .{
            .headline = try o.str("headline"),
            .price = try o.str("price"),
            .price_note = try o.optStr("price_note"),
            .includes = try o.strList("includes", 0, 3, false),
        } };
    }
    if (std.mem.eql(u8, kind, "finance")) {
        try o.only(&.{ "kind", "headline", "monthly", "apr", "term_months", "interest_rate", "credit", "deposit", "cash_price", "total_payable", "lender", "other_charges" });
        return .{ .finance = .{
            .headline = try o.str("headline"),
            .monthly = try o.str("monthly"),
            .apr = try o.str("apr"),
            .term_months = try o.str("term_months"),
            .interest_rate = try o.str("interest_rate"),
            .credit = try o.str("credit"),
            .deposit = try o.str("deposit"),
            .cash_price = try o.str("cash_price"),
            .total_payable = try o.str("total_payable"),
            .lender = try o.str("lender"),
            .other_charges = try o.optStr("other_charges"),
        } };
    }
    if (std.mem.eql(u8, kind, "grant")) {
        try o.only(&.{ "kind", "scheme", "headline", "body", "criteria" });
        return .{ .grant = .{
            .scheme = try o.str("scheme"),
            .headline = try o.str("headline"),
            .body = try o.str("body"),
            .criteria = try o.strList("criteria", 1, 4, true),
        } };
    }
    o.diag.set("{s}.kind must be price, finance or grant", .{o.path});
    return error.InvalidInput;
}

// =============================================================================
// Layout
// =============================================================================

const PAGE_W: f32 = document.A4_WIDTH;
const PAGE_H: f32 = document.A4_HEIGHT;
const MARGIN: f32 = 30;
const CONTENT_W: f32 = PAGE_W - 2 * MARGIN;
const BOTTOM: f32 = 18; // lowest point text may reach, from the page bottom

const BODY = Color{ .r = 0.17, .g = 0.21, .b = 0.17 };
const MUTED = Color{ .r = 0.29, .g = 0.33, .b = 0.29 };
const FINE = Color{ .r = 0.36, .g = 0.40, .b = 0.36 };
const WHITE = Color.white;

const REGULAR: Font = .montserrat_regular;
const BOLD: Font = .montserrat_bold;

/// `a` blended toward `b` by `t` (0 = a, 1 = b).
fn mix(a: Color, b: Color, t: f32) Color {
    return .{ .r = a.r + (b.r - a.r) * t, .g = a.g + (b.g - a.g) * t, .b = a.b + (b.b - a.b) * t };
}

const Renderer = struct {
    a: Allocator,
    l: *const Letter,
    diag: *Diagnostic,
    doc: document.PdfDocument,
    cs: ContentStream,
    f_reg: []const u8 = "",
    f_bold: []const u8 = "",
    /// Distance of the layout cursor from the top of the page.
    top: f32 = 0,

    fn th(self: *const Renderer) Theme {
        return self.l.installer.theme;
    }

    fn fontId(self: *const Renderer, f: Font) []const u8 {
        return if (f == BOLD) self.f_bold else self.f_reg;
    }

    /// PDF y (from the page bottom) of a text baseline whose line box starts
    /// `t` points below the top of the page, for a line `leading` tall.
    fn baseline(t: f32, size: f32, leading: f32) f32 {
        return PAGE_H - t - (leading - size) / 2 - size * 0.8;
    }

    /// PDF y of the bottom of a box `h` tall whose top is `t` below the page top.
    fn boxY(t: f32, h: f32) f32 {
        return PAGE_H - t - h;
    }

    fn text(self: *Renderer, s: []const u8, x: f32, y: f32, f: Font, size: f32, c: Color) !void {
        try self.cs.drawText(s, x, y, self.fontId(f), size, c);
    }

    fn textRight(self: *Renderer, s: []const u8, right: f32, y: f32, f: Font, size: f32, c: Color) !void {
        try self.cs.drawText(s, right - f.measureText(s, size), y, self.fontId(f), size, c);
    }

    fn caps(self: *Renderer, s: []const u8, x: f32, y: f32, size: f32, c: Color) !f32 {
        const upper = try std.ascii.allocUpperString(self.a, s);
        const tracking = size * 0.12;
        try self.cs.drawTrackedText(upper, x, y, self.f_bold, size, tracking, c);
        return BOLD.measureTracked(upper, size, tracking);
    }

    /// Wrap `s` to `width`; refuse it if it needs more than `max_lines`.
    fn lines(self: *Renderer, s: []const u8, f: Font, size: f32, width: f32, max_lines: usize, what: []const u8) ![]const []const u8 {
        const w = try document.wrapText(self.a, s, f, size, width);
        if (w.lines.len > max_lines) {
            self.diag.set("{s} wraps to {d} lines; its space holds {d}", .{ what, w.lines.len, max_lines });
            return error.TooLong;
        }
        return w.lines;
    }

    /// One line that must fit `width` as it is.
    fn oneLine(self: *Renderer, s: []const u8, f: Font, size: f32, width: f32, what: []const u8) !void {
        if (f.measureText(s, size) > width) {
            self.diag.set("{s} '{s}' is too long for its space", .{ what, s });
            return error.TooLong;
        }
    }

    /// Draw wrapped lines from `t`; returns the height used.
    fn paragraph(self: *Renderer, ls: []const []const u8, x: f32, t: f32, f: Font, size: f32, leading: f32, c: Color) !f32 {
        for (ls, 0..) |ln, i| {
            try self.text(ln, x, baseline(t + @as(f32, @floatFromInt(i)) * leading, size, leading), f, size, c);
        }
        return @as(f32, @floatFromInt(ls.len)) * leading;
    }

    /// The largest size, from `start` down to `min`, at which `s` fits `width`.
    fn fitSize(self: *Renderer, s: []const u8, f: Font, start: f32, min: f32, width: f32, what: []const u8) !f32 {
        var size = start;
        while (size >= min) : (size -= 0.5) {
            if (f.measureText(s, size) <= width) return size;
        }
        self.diag.set("{s} '{s}' is too long for its space", .{ what, s });
        return error.TooLong;
    }

    fn loadImage(self: *Renderer, src: []const u8, what: []const u8) !struct { id: []const u8, w: f32, h: f32 } {
        const loaded = image.loadImageFlexible(self.a, src) catch {
            self.diag.set("{s} is not a readable PNG or JPEG", .{what});
            return error.ImageInvalid;
        };
        if (loaded.image.width == 0 or loaded.image.height == 0) {
            self.diag.set("{s} has no pixels", .{what});
            return error.ImageInvalid;
        }
        const id = try self.doc.addImage(loaded.image);
        return .{ .id = id, .w = @floatFromInt(loaded.image.width), .h = @floatFromInt(loaded.image.height) };
    }

    /// A rounded box filled with a diagonal gradient from `c0` (top left) to `c1`.
    fn gradientBox(self: *Renderer, x: f32, y: f32, w: f32, h: f32, r: f32, c0: Color, c1: Color) !void {
        const id = self.doc.getAxialShadingId(c0, c1, x, y + h, x + w, y);
        try self.cs.saveState();
        try self.cs.clipRoundedRect(x, y, w, h, r);
        try self.cs.paintShading(id);
        try self.cs.restoreState();
    }

    /// A tick mark in a filled circle, drawn as lines (the fonts have no tick).
    fn tick(self: *Renderer, cx: f32, cy: f32, r: f32, bg: Color, fg: Color) !void {
        try self.cs.drawCircle(cx, cy, r, bg, null);
        try self.cs.saveState();
        try self.cs.buffer.appendSlice(self.a, "1 J 1 j\n");
        try self.cs.setStrokeColor(fg);
        try self.cs.setLineWidth(r * 0.2);
        try self.cs.moveTo(cx - r * 0.42, cy + r * 0.02);
        try self.cs.lineTo(cx - r * 0.12, cy - r * 0.3);
        try self.cs.lineTo(cx + r * 0.45, cy + r * 0.32);
        try self.cs.stroke();
        try self.cs.restoreState();
    }

    // ── Sections, top to bottom ──────────────────────────────────────────

    fn topBar(self: *Renderer) !void {
        const h: f32 = 6.75;
        const id = self.doc.getAxialShadingId(self.th().dark, self.th().link, 0, PAGE_H, PAGE_W, PAGE_H);
        try self.cs.saveState();
        try self.cs.clipRect(0, PAGE_H - h, PAGE_W, h);
        try self.cs.paintShading(id);
        try self.cs.restoreState();
        self.top = h + 16;
    }

    fn header(self: *Renderer) !void {
        const ins = self.l.installer;
        const logo = try self.loadImage(ins.logo, "installer.logo");
        const box_h: f32 = 39;
        const scale = @min(170 / logo.w, box_h / logo.h);
        const lw = logo.w * scale;
        const lh = logo.h * scale;
        try self.cs.drawImage(logo.id, MARGIN, boxY(self.top + (box_h - lh) / 2, lh), lw, lh);

        const right = PAGE_W - MARGIN;
        try self.oneLine(ins.phone, BOLD, 15, CONTENT_W - lw - 20, "installer.phone");
        try self.textRight(ins.phone, right, baseline(self.top + 4, 15, 18), BOLD, 15, self.th().dark);
        const line2 = try std.fmt.allocPrint(self.a, "{s}  \u{00B7}  {s}", .{ ins.website, self.l.date });
        try self.oneLine(line2, REGULAR, 8.6, CONTENT_W - lw - 20, "installer.website and letter.date");
        const y2 = baseline(self.top + 22, 8.6, 12);
        try self.textRight(line2, right, y2, REGULAR, 8.6, self.th().link);
        const site_w = REGULAR.measureText(ins.website, 8.6);
        const line_w = REGULAR.measureText(line2, 8.6);
        const href = if (std.mem.startsWith(u8, ins.website, "http")) ins.website else try std.fmt.allocPrint(self.a, "https://{s}", .{ins.website});
        try self.doc.addLinkAnnotation(right - line_w, y2 - 2, right - line_w + site_w, y2 + 8, href);
        self.top += box_h + 18;
    }

    fn recipient(self: *Renderer) !void {
        for (self.l.recipient) |ln| try self.oneLine(ln, REGULAR, 9.75, CONTENT_W * 0.6, "letter.recipient line");
        self.top += try self.paragraph(self.l.recipient, MARGIN, self.top, REGULAR, 9.75, 14.6, self.th().ink);
        self.top += 16;
    }

    fn headline(self: *Renderer) !void {
        const size: f32 = 25.5;
        const leading: f32 = 28.5;
        const ls = try self.lines(self.l.headline, BOLD, size, CONTENT_W, 2, "letter.headline");
        // The highlighter: a band across the lower part of the line, behind the
        // marked phrase only, wherever the wrap put it.
        if (self.l.headline_highlight) |hl| {
            const start = std.mem.indexOf(u8, self.l.headline, hl).?;
            const end = start + hl.len;
            for (ls, 0..) |ln, i| {
                const ln_start = @intFromPtr(ln.ptr) - @intFromPtr(self.l.headline.ptr);
                const ln_end = ln_start + ln.len;
                const a = @max(start, ln_start);
                const b = @min(end, ln_end);
                if (a >= b) continue;
                const x0 = MARGIN + BOLD.measureText(ln[0 .. a - ln_start], size) - 2.25;
                const x1 = MARGIN + BOLD.measureText(ln[0 .. b - ln_start], size) + 2.25;
                const t = self.top + @as(f32, @floatFromInt(i)) * leading;
                try self.cs.drawRect(x0, boxY(t + leading * 0.52, leading * 0.40), x1 - x0, leading * 0.40, self.th().accent, null);
            }
        }
        self.top += try self.paragraph(ls, MARGIN, self.top, BOLD, size, leading, self.th().ink);
        self.top += 5;
    }

    fn intro(self: *Renderer) !void {
        const ls = try self.lines(self.l.intro, REGULAR, 9.4, CONTENT_W, 4, "letter.intro");
        self.top += try self.paragraph(ls, MARGIN, self.top, REGULAR, 9.4, 14.5, BODY);
        self.top += 10;
    }

    fn picture(self: *Renderer) !void {
        const h: f32 = 171;
        const y = boxY(self.top, h);
        const pic = try self.loadImage(self.l.image_src, "image.src");
        const scale = @max(CONTENT_W / pic.w, h / pic.h);
        const dw = pic.w * scale;
        const dh = pic.h * scale;
        try self.cs.saveState();
        try self.cs.clipRoundedRect(MARGIN, y, CONTENT_W, h, 10.5);
        try self.cs.drawImage(pic.id, MARGIN + (CONTENT_W - dw) / 2, y + (h - dh) / 2, dw, dh);
        if (self.l.image_caption) |cap| {
            try self.oneLine(cap, REGULAR, 7, CONTENT_W - 20, "image.caption");
            try self.cs.saveState();
            try self.cs.setExtGState(self.doc.getOpacityExtGStateId(0.55));
            try self.cs.drawRect(MARGIN, y, CONTENT_W, 17, Color.black, null);
            try self.cs.restoreState();
            try self.text(cap, MARGIN + 10, y + 6, REGULAR, 7, WHITE);
        }
        try self.cs.restoreState();
        self.top += h + 7.5;
    }

    fn stats(self: *Renderer) !void {
        const n = self.l.stats.len;
        const gap: f32 = 7.5;
        const w = (CONTENT_W - gap * @as(f32, @floatFromInt(n - 1))) / @as(f32, @floatFromInt(n));
        const h: f32 = 54;
        const t = self.th();
        // Lightest to darkest, left to right; fewer cards use the darker end.
        const fills = [3]Color{ t.primary, t.dark, t.ink };
        for (self.l.stats, 0..) |st, i| {
            const x = MARGIN + @as(f32, @floatFromInt(i)) * (w + gap);
            const fill = fills[3 - n + i];
            try self.cs.drawRoundedRect(x, boxY(self.top, h), w, h, 9, fill);
            const inner = w - 21;
            try self.oneLine(st.label, BOLD, 6.4, inner, "stats label");
            _ = try self.caps(st.label, x + 10.5, baseline(self.top + 8, 6.4, 8), 6.4, t.label);
            const size = try self.fitSize(st.value, BOLD, 21, 13, inner, "stats value");
            try self.text(st.value, x + 10.5, baseline(self.top + 17, size, 22), BOLD, size, WHITE);
            if (st.note) |note| {
                try self.oneLine(note, REGULAR, 7.9, inner, "stats note");
                try self.text(note, x + 10.5, baseline(self.top + 39, 7.9, 9.5), REGULAR, 7.9, mix(fill, WHITE, 0.85));
            }
        }
        self.top += h + 9;
    }

    fn package(self: *Renderer) !void {
        const n = self.l.package.len;
        const gap: f32 = 21;
        const w = (CONTENT_W - gap * @as(f32, @floatFromInt(n - 1))) / @as(f32, @floatFromInt(n));
        for (self.l.package, 0..) |row, i| {
            const x = MARGIN + @as(f32, @floatFromInt(i)) * (w + gap);
            try self.oneLine(row.label, REGULAR, 9, w, "package label");
            try self.oneLine(row.value, BOLD, 9, w, "package value");
            try self.tick(x + 8.25, PAGE_H - self.top - 8.25, 8.25, self.th().primary, WHITE);
            try self.text(row.label, x, baseline(self.top + 20, 9, 11), REGULAR, 9, MUTED);
            try self.text(row.value, x, baseline(self.top + 31, 9, 11), BOLD, 9, self.th().ink);
        }
        self.top += 42 + 9;
    }

    fn offer(self: *Renderer) !void {
        const t = self.th();
        const pad_x: f32 = 13.5;
        const pad_y: f32 = 12;
        const qr_tile_w: f32 = 96;
        const qr_size: f32 = 75;
        const text_x = MARGIN + pad_x;
        const text_w = CONTENT_W - 2 * pad_x - qr_tile_w - 12;
        const soft = mix(t.label, WHITE, 0.55);

        // Lay out first, so the box can grow to fit its text.
        const Line = struct { s: []const u8, f: Font, size: f32, leading: f32, c: Color };
        var body: std.ArrayListUnmanaged(Line) = .empty;
        var figures: ?[2][2][]const u8 = null; // finance: monthly and APR, the same size
        var price: ?[2][]const u8 = null; // price: the figure and its note
        var tag: []const u8 = "";
        var after: std.ArrayListUnmanaged(Line) = .empty; // below the figures

        switch (self.l.offer) {
            .price => |p| {
                tag = "Your price";
                for (try self.lines(p.headline, BOLD, 11.25, text_w, 2, "offer.headline")) |ln| try body.append(self.a, .{ .s = ln, .f = BOLD, .size = 11.25, .leading = 15, .c = WHITE });
                price = .{ p.price, p.price_note orelse "" };
                if (p.includes.len > 0) {
                    const joined = try std.mem.join(self.a, "  \u{00B7}  ", p.includes);
                    for (try self.lines(joined, REGULAR, 8.25, text_w, 2, "offer.includes")) |ln| try after.append(self.a, .{ .s = ln, .f = REGULAR, .size = 8.25, .leading = 11.5, .c = soft });
                }
            },
            .finance => |fi| {
                tag = "Finance";
                for (try self.lines(fi.headline, BOLD, 11.25, text_w, 2, "offer.headline")) |ln| try body.append(self.a, .{ .s = ln, .f = BOLD, .size = 11.25, .leading = 15, .c = WHITE });
                figures = .{ .{ "Monthly payment", fi.monthly }, .{ "Representative APR", fi.apr } };
                const charges = if (fi.other_charges) |oc| try std.fmt.allocPrint(self.a, " Other charges: {s}.", .{oc}) else "";
                const example = try std.fmt.allocPrint(self.a, "Representative example: cash price {s}, deposit {s}, total amount of credit {s}, repayable by {s} monthly payments of {s}. Interest rate {s}. Representative APR {s}. Total amount payable {s}.{s} Credit is provided by {s}.", .{ fi.cash_price, fi.deposit, fi.credit, fi.term_months, fi.monthly, fi.interest_rate, fi.apr, fi.total_payable, charges, fi.lender });
                for (try self.lines(example, REGULAR, 7.6, text_w, 5, "offer representative example")) |ln| try after.append(self.a, .{ .s = ln, .f = REGULAR, .size = 7.6, .leading = 10, .c = WHITE });
            },
            .grant => |g| {
                tag = g.scheme;
                for (try self.lines(g.headline, BOLD, 11.25, text_w, 2, "offer.headline")) |ln| try body.append(self.a, .{ .s = ln, .f = BOLD, .size = 11.25, .leading = 15, .c = WHITE });
                for (try self.lines(g.body, REGULAR, 8.4, text_w, 2, "offer.body")) |ln| try body.append(self.a, .{ .s = ln, .f = REGULAR, .size = 8.4, .leading = 11.5, .c = soft });
                for (g.criteria) |cr| {
                    const bullet = try std.fmt.allocPrint(self.a, "\u{2022}  {s}", .{cr});
                    try self.oneLine(bullet, REGULAR, 8.4, text_w, "offer.criteria");
                    try after.append(self.a, .{ .s = bullet, .f = REGULAR, .size = 8.4, .leading = 11.5, .c = WHITE });
                }
            },
        }
        try self.oneLine(tag, BOLD, 7.5, text_w, "offer label");

        var text_h: f32 = 13; // the tag line
        for (body.items) |ln| text_h += ln.leading;
        if (figures != null) text_h += 47;
        if (price != null) text_h += 40;
        for (after.items) |ln| text_h += ln.leading;
        const cap_ls = try self.lines(self.l.qr_caption, REGULAR, 6.4, qr_tile_w - 12, 2, "letter.qr_caption");
        const tile_h = 7.5 + qr_size + 5 + @as(f32, @floatFromInt(cap_ls.len)) * 8 + 6;
        const box_h = @max(text_h, tile_h) + 2 * pad_y;
        const box_y = boxY(self.top, box_h);
        try self.gradientBox(MARGIN, box_y, CONTENT_W, box_h, 12, t.dark, t.primary);

        // Text column.
        var ty = self.top + pad_y + @max(0, (box_h - 2 * pad_y - text_h) / 2);
        _ = try self.caps(tag, text_x, baseline(ty, 7.5, 13), 7.5, t.label);
        ty += 13;
        for (body.items) |ln| {
            try self.text(ln.s, text_x, baseline(ty, ln.size, ln.leading), ln.f, ln.size, ln.c);
            ty += ln.leading;
        }
        if (price) |pr| {
            const size = try self.fitSize(pr[0], BOLD, 34.5, 20, text_w * 0.62, "offer.price");
            try self.text(pr[0], text_x, baseline(ty, size, 40), BOLD, size, t.accent);
            if (pr[1].len > 0) {
                const pw = BOLD.measureText(pr[0], size);
                try self.oneLine(pr[1], REGULAR, 9, text_w - pw - 8, "offer.price_note");
                try self.text(pr[1], text_x + pw + 6, baseline(ty, size, 40), REGULAR, 9, WHITE);
            }
            ty += 40;
        }
        if (figures) |fig| {
            ty += 5;
            // CONC 3.5.7R(2): the representative APR at the same size as the monthly figure.
            const col = text_w / 2;
            const size = @min(try self.fitSize(fig[0][1], BOLD, 26, 14, col - 8, "offer.monthly"), try self.fitSize(fig[1][1], BOLD, 26, 14, col - 8, "offer.apr"));
            for (fig, 0..) |pair, k| {
                const x = text_x + @as(f32, @floatFromInt(k)) * col;
                _ = try self.caps(pair[0], x, baseline(ty, 6.4, 10), 6.4, t.label);
                try self.text(pair[1], x, baseline(ty + 10, size, 30), BOLD, size, t.accent);
            }
            ty += 42;
        }
        for (after.items) |ln| {
            try self.text(ln.s, text_x, baseline(ty, ln.size, ln.leading), ln.f, ln.size, ln.c);
            ty += ln.leading;
        }

        // QR tile on the right, linked to the same address.
        const tile_x = PAGE_W - MARGIN - pad_x - qr_tile_w;
        const tile_y = box_y + (box_h - tile_h) / 2;
        try self.cs.drawRoundedRect(tile_x, tile_y, qr_tile_w, tile_h, 9, WHITE);
        const qr_x = tile_x + (qr_tile_w - qr_size) / 2;
        const qr_y = tile_y + tile_h - 7.5 - qr_size;
        try self.qr(self.l.qr_url, qr_x, qr_y, qr_size, t.ink);
        try self.doc.addLinkAnnotation(qr_x, qr_y, qr_x + qr_size, qr_y + qr_size, self.l.qr_url);
        for (cap_ls, 0..) |ln, i| {
            const w = REGULAR.measureText(ln, 6.4);
            try self.text(ln, tile_x + (qr_tile_w - w) / 2, qr_y - 9 - @as(f32, @floatFromInt(i)) * 8, REGULAR, 6.4, MUTED);
        }
        self.top += box_h + 9;
    }

    /// QR code as vector squares (one rectangle per run of dark modules), so
    /// it prints sharp at any size.
    fn qr(self: *Renderer, url: []const u8, x: f32, y: f32, size: f32, c: Color) !void {
        var code = qrcode.encode(self.a, url, .{ .ec_level = .M, .quiet_zone = 0 }) catch {
            self.diag.set("letter.qr_url can't be encoded as a QR code", .{});
            return error.InvalidInput;
        };
        defer code.deinit(self.a);
        const n: usize = code.size;
        const m = size / @as(f32, @floatFromInt(n));
        try self.cs.saveState();
        try self.cs.setFillColor(c);
        var row: usize = 0;
        while (row < n) : (row += 1) {
            var col: usize = 0;
            while (col < n) {
                if (!code.getModule(col, row)) {
                    col += 1;
                    continue;
                }
                const start = col;
                while (col < n and code.getModule(col, row)) col += 1;
                const run: f32 = @floatFromInt(col - start);
                // A hair of overlap so adjacent squares print without seams.
                try self.cs.rect(x + @as(f32, @floatFromInt(start)) * m, y + size - @as(f32, @floatFromInt(row + 1)) * m, run * m + 0.05, m + 0.05);
            }
        }
        try self.cs.fill();
        try self.cs.restoreState();
    }

    fn phoneStrip(self: *Renderer) !void {
        const h: f32 = 30;
        const y = boxY(self.top, h);
        const ins = self.l.installer;
        const t = self.th();
        try self.cs.drawRoundedRect(MARGIN, y, CONTENT_W, h, 9, t.ink);
        const lead = "Call us on ";
        const lead_w = BOLD.measureText(lead, 12);
        try self.oneLine(ins.phone, BOLD, 12, CONTENT_W * 0.6 - lead_w, "installer.phone");
        try self.text(lead, MARGIN + 13.5, y + 10.5, BOLD, 12, WHITE);
        try self.text(ins.phone, MARGIN + 13.5 + lead_w, y + 10.5, BOLD, 12, t.accent);
        try self.textRight(ins.website, PAGE_W - MARGIN - 13.5, y + 11, REGULAR, 9, WHITE);
        const tel = try std.mem.replaceOwned(u8, self.a, try std.fmt.allocPrint(self.a, "tel:{s}", .{ins.phone}), " ", "");
        try self.doc.addLinkAnnotation(MARGIN, y, MARGIN + CONTENT_W / 2, y + h, tel);
        self.top += h + 9;
    }

    fn accreditations(self: *Renderer) !void {
        const marks = self.l.installer.accreditations;
        if (marks.len == 0) return;
        const Mark = struct { id: []const u8, w: f32, h: f32 };
        const loaded = try self.a.alloc(Mark, marks.len);
        const row_h: f32 = 22.5;
        var h = row_h;
        const gap: f32 = 19.5;
        const gaps = gap * @as(f32, @floatFromInt(marks.len - 1));
        var total: f32 = 0;
        for (marks, 0..) |src, i| {
            const img = try self.loadImage(src, try std.fmt.allocPrint(self.a, "installer.accreditations[{d}]", .{i}));
            loaded[i] = .{ .id = img.id, .w = img.w, .h = img.h };
            total += h * img.w / img.h;
        }
        if (total + gaps > CONTENT_W) {
            h *= (CONTENT_W - gaps) / total;
            total = CONTENT_W - gaps;
        }
        var x = MARGIN + (CONTENT_W - total - gaps) / 2;
        const y = boxY(self.top, row_h) + (row_h - h) / 2;
        for (loaded) |mk| {
            const w = h * mk.w / mk.h;
            try self.cs.drawImage(mk.id, x, y, w, h);
            x += w + gap;
        }
        self.top += row_h + 7;
    }

    fn smallPrint(self: *Renderer) !void {
        const ins = self.l.installer;
        const all = if (ins.legal_line) |ll| try std.fmt.allocPrint(self.a, "{s} {s}", .{ self.l.small_print, ll }) else self.l.small_print;
        const room = PAGE_H - self.top - BOTTOM;
        const leading: f32 = 9.1;
        const max_lines: usize = @intFromFloat(@max(0, @floor(room / leading)));
        const w = try document.wrapText(self.a, all, REGULAR, 6.3, CONTENT_W);
        if (w.lines.len > max_lines) {
            const over = @as(f32, @floatFromInt(w.lines.len)) * leading - room;
            self.diag.set("the letter runs {d:.0}pt past the bottom of the page; shorten the intro, offer or small print", .{over});
            return error.TooLong;
        }
        _ = try self.paragraph(w.lines, MARGIN, self.top, REGULAR, 6.3, leading, FINE);
    }

    fn render(self: *Renderer) ![]const u8 {
        self.f_reg = self.doc.getFontId(REGULAR);
        self.f_bold = self.doc.getFontId(BOLD);
        self.doc.setInfo(.{ .title = self.l.headline, .author = self.l.installer.name, .creator = "zig_pdf_generator solar_letter" });
        try self.topBar();
        try self.header();
        try self.recipient();
        try self.headline();
        try self.intro();
        try self.picture();
        try self.stats();
        try self.package();
        try self.offer();
        try self.phoneStrip();
        try self.accreditations();
        try self.smallPrint();
        try self.doc.addPage(&self.cs);
        return self.doc.build();
    }
};

/// Render the letter. PDF bytes are owned by `allocator`; on error `diag`
/// says which field or which part of the page is at fault.
pub fn generate(allocator: Allocator, json_str: []const u8, diag: *Diagnostic) Error![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const letter = try parse(a, json_str, diag);
    var r = Renderer{ .a = a, .l = &letter, .diag = diag, .doc = document.PdfDocument.init(a), .cs = ContentStream.init(a) };
    const pdf = r.render() catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidInput => return error.InvalidInput,
        error.ImageInvalid => return error.ImageInvalid,
        error.TooLong => return error.TooLong,
        else => {
            diag.set("layout failed: {s}", .{@errorName(err)});
            return error.PdfFailed;
        },
    };
    return allocator.dupe(u8, pdf) catch error.OutOfMemory;
}
