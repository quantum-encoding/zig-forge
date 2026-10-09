//! Solar letter: a one-page A4 personalised letter an installer sends to a
//! householder about putting solar panels on their roof.
//!
//! The installer's brand (name, logo, colours, accreditation marks) and every
//! figure arrive in the payload: the template holds layout and the wording the
//! law requires, nothing about any one installer. Figures are display strings,
//! formatted by the caller; this module checks they are present, not their
//! arithmetic.
//!
//! Input shape (every field required unless marked optional):
//! ```json
//! {
//!   "installer": { "name", "phone", "website", "logo",
//!                  "primary_hex": "#2b6531", "tint_hex": "#eef6ef",   // tint optional
//!                  "accreditations": ["<image>", ...],              // optional, up to 10
//!                  "legal_line": "Registered in England ..." },     // optional
//!   "letter":    { "reference", "date", "recipient": ["The Occupier", "1 High St", ...],
//!                  "headline", "intro", "qr_url": "https://...", "qr_caption",
//!                  "small_print", "package_title" (optional) },
//!   "package":   [ { "label", "value" } ],                           // 1 to 4 rows
//!   "stats":     [ { "label", "value", "note" (optional) } ],        // 1 to 3 cards
//!   "image":     { "src", "caption" (optional) },
//!   "offer":     { "kind": "price" | "finance" | "grant", ... }
//! }
//! ```
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

pub const Installer = struct {
    name: []const u8,
    phone: []const u8,
    website: []const u8,
    logo: []const u8,
    primary: Color,
    tint: Color,
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
    intro: []const u8,
    qr_url: []const u8,
    qr_caption: []const u8,
    small_print: []const u8,
    /// Heading over the package rows; "Your recommended system" when absent.
    package_title: ?[]const u8,
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
    try ins.only(&.{ "name", "phone", "website", "logo", "primary_hex", "tint_hex", "accreditations", "legal_line" });
    const accr_items = try ins.array("accreditations", 0, 10, false);
    const accreditations = try arena.alloc([]const u8, accr_items.len);
    for (accr_items, 0..) |item, i| accreditations[i] = try ins.imageRef(item, "accreditations[]");
    const installer = Installer{
        .name = try ins.str("name"),
        .phone = try ins.str("phone"),
        .website = try ins.str("website"),
        .logo = try ins.imageRef(try ins.get("logo"), "logo"),
        .primary = (try ins.colour("primary_hex", true)).?,
        .tint = (try ins.colour("tint_hex", false)) orelse Color{ .r = 0.93, .g = 0.96, .b = 0.93 },
        .accreditations = accreditations,
        .legal_line = try ins.optStr("legal_line"),
    };

    const let = try root.child("letter");
    try let.only(&.{ "reference", "date", "recipient", "headline", "intro", "qr_url", "qr_caption", "small_print", "package_title" });
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
        .headline = try let.str("headline"),
        .intro = try let.str("intro"),
        .qr_url = qr_url,
        .qr_caption = try let.str("qr_caption"),
        .small_print = try let.str("small_print"),
        .package_title = try let.optStr("package_title"),
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
const MARGIN: f32 = 40;
const CONTENT_W: f32 = PAGE_W - 2 * MARGIN;
const BOTTOM: f32 = 24; // lowest point text may reach, from the page bottom

const INK = Color{ .r = 0.12, .g = 0.16, .b = 0.12 };
const MUTED = Color{ .r = 0.36, .g = 0.40, .b = 0.36 };
const RULE = Color{ .r = 0.84, .g = 0.86, .b = 0.83 };
const WHITE = Color.white;

const REGULAR: Font = .montserrat_regular;
const BOLD: Font = .montserrat_bold;

const Renderer = struct {
    a: Allocator,
    l: *const Letter,
    diag: *Diagnostic,
    doc: document.PdfDocument,
    cs: ContentStream,
    f_reg: []const u8 = "",
    f_bold: []const u8 = "",
    /// Distance of the layout cursor from the top of the page.
    top: f32 = 36,

    fn fontId(self: *const Renderer, f: Font) []const u8 {
        return if (f == BOLD) self.f_bold else self.f_reg;
    }

    /// PDF y (from the page bottom) of a text baseline whose line starts `t`
    /// points below the top of the page.
    fn baseline(t: f32, size: f32) f32 {
        return PAGE_H - t - size * 0.78;
    }

    fn text(self: *Renderer, s: []const u8, x: f32, y: f32, f: Font, size: f32, c: Color) !void {
        try self.cs.drawText(s, x, y, self.fontId(f), size, c);
    }

    fn textRight(self: *Renderer, s: []const u8, right: f32, y: f32, f: Font, size: f32, c: Color) !void {
        try self.cs.drawText(s, right - f.measureText(s, size), y, self.fontId(f), size, c);
    }

    fn caps(self: *Renderer, s: []const u8, x: f32, y: f32, size: f32, c: Color) !void {
        const upper = try std.ascii.allocUpperString(self.a, s);
        try self.cs.drawTrackedText(upper, x, y, self.f_bold, size, size * 0.12, c);
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

    /// Draw wrapped lines from `t` (top of first line); returns the height used.
    fn paragraph(self: *Renderer, ls: []const []const u8, x: f32, t: f32, f: Font, size: f32, leading: f32, c: Color) !f32 {
        for (ls, 0..) |ln, i| {
            try self.text(ln, x, baseline(t + @as(f32, @floatFromInt(i)) * leading, size), f, size, c);
        }
        return @as(f32, @floatFromInt(ls.len)) * leading;
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

    // ── Sections, top to bottom ──────────────────────────────────────────

    fn header(self: *Renderer) !void {
        const ins = self.l.installer;
        const logo = try self.loadImage(ins.logo, "installer.logo");
        const box_w: f32 = 150;
        const box_h: f32 = 44;
        const scale = @min(box_w / logo.w, box_h / logo.h);
        const lw = logo.w * scale;
        const lh = logo.h * scale;
        try self.cs.drawImage(logo.id, MARGIN, PAGE_H - self.top - lh, lw, lh);

        const right = PAGE_W - MARGIN;
        try self.textRight(ins.phone, right, baseline(self.top, 13), BOLD, 13, ins.primary);
        try self.textRight(ins.website, right, baseline(self.top + 18, 8.5), REGULAR, 8.5, MUTED);
        const site_w = REGULAR.measureText(ins.website, 8.5);
        const href = if (std.mem.startsWith(u8, ins.website, "http")) ins.website else try std.fmt.allocPrint(self.a, "https://{s}", .{ins.website});
        try self.doc.addLinkAnnotation(right - site_w, baseline(self.top + 18, 8.5) - 2, right, baseline(self.top + 18, 8.5) + 8, href);
        const dated = try std.fmt.allocPrint(self.a, "{s}  \u{00B7}  Ref {s}", .{ self.l.date, self.l.reference });
        try self.textRight(dated, right, baseline(self.top + 31, 8), REGULAR, 8, MUTED);

        self.top += @max(lh, 42) + 12;
        try self.cs.drawLine(MARGIN, PAGE_H - self.top, PAGE_W - MARGIN, PAGE_H - self.top, RULE, 0.6);
        self.top += 16;
    }

    fn recipient(self: *Renderer) !void {
        for (self.l.recipient) |ln| {
            const w = REGULAR.measureText(ln, 9.5);
            if (w > CONTENT_W * 0.6) {
                self.diag.set("letter.recipient line '{s}' is too long for the address block", .{ln});
                return error.TooLong;
            }
        }
        self.top += try self.paragraph(self.l.recipient, MARGIN, self.top, REGULAR, 9.5, 13, INK);
        self.top += 14;
    }

    fn intro(self: *Renderer) !void {
        const head = try self.lines(self.l.headline, BOLD, 20, CONTENT_W, 2, "letter.headline");
        self.top += try self.paragraph(head, MARGIN, self.top, BOLD, 20, 24, self.l.installer.primary);
        self.top += 4;
        const body = try self.lines(self.l.intro, REGULAR, 9.5, CONTENT_W, 4, "letter.intro");
        self.top += try self.paragraph(body, MARGIN, self.top, REGULAR, 9.5, 14, INK);
        self.top += 12;
    }

    fn package(self: *Renderer) !void {
        try self.caps(self.l.package_title orelse "Your recommended system", MARGIN, baseline(self.top, 7.5), 7.5, self.l.installer.primary);
        self.top += 13;
        const row_h: f32 = 19;
        for (self.l.package) |row| {
            const label_w = REGULAR.measureText(row.label, 9.5);
            const value_w = BOLD.measureText(row.value, 10);
            if (label_w + value_w + 16 > CONTENT_W) {
                self.diag.set("package row '{s}' is too long for one line", .{row.label});
                return error.TooLong;
            }
            try self.text(row.label, MARGIN, baseline(self.top + 4, 9.5), REGULAR, 9.5, INK);
            try self.textRight(row.value, PAGE_W - MARGIN, baseline(self.top + 4, 10), BOLD, 10, INK);
            self.top += row_h;
            try self.cs.drawLine(MARGIN, PAGE_H - self.top + 2, PAGE_W - MARGIN, PAGE_H - self.top + 2, RULE, 0.5);
        }
        self.top += 12;
    }

    fn hero(self: *Renderer) !void {
        const h: f32 = 196;
        const gap: f32 = 10;
        const img_w = CONTENT_W * 0.6 - gap / 2;
        const y = PAGE_H - self.top - h;

        // The picture, cropped to fill its box.
        const pic = try self.loadImage(self.l.image_src, "image.src");
        const scale = @max(img_w / pic.w, h / pic.h);
        const dw = pic.w * scale;
        const dh = pic.h * scale;
        try self.cs.saveState();
        try self.cs.clipRoundedRect(MARGIN, y, img_w, h, 8);
        try self.cs.drawImage(pic.id, MARGIN + (img_w - dw) / 2, y + (h - dh) / 2, dw, dh);
        if (self.l.image_caption) |cap| {
            const cap_ls = try self.lines(cap, REGULAR, 7, img_w - 16, 1, "image.caption");
            try self.cs.saveState();
            try self.cs.setExtGState(self.doc.getOpacityExtGStateId(0.55));
            try self.cs.drawRect(MARGIN, y, img_w, 17, Color.black, null);
            try self.cs.restoreState();
            try self.text(cap_ls[0], MARGIN + 8, y + 6, REGULAR, 7, WHITE);
        }
        try self.cs.restoreState();

        // Figures beside it, the first in the brand colour.
        const col_x = MARGIN + img_w + gap;
        const col_w = CONTENT_W - img_w - gap;
        const n: f32 = @floatFromInt(self.l.stats.len);
        const card_gap: f32 = 8;
        const card_h = (h - card_gap * (n - 1)) / n;
        const primary = self.l.installer.primary;
        for (self.l.stats, 0..) |st, i| {
            const cy = y + h - (@as(f32, @floatFromInt(i)) + 1) * card_h - @as(f32, @floatFromInt(i)) * card_gap;
            const first = i == 0;
            const bg = if (first) primary else self.l.installer.tint;
            const fg = if (first) WHITE else primary;
            const sub = if (first) WHITE else MUTED;
            try self.cs.drawRoundedRect(col_x, cy, col_w, card_h, 8, bg);

            const label_ls = try self.lines(st.label, BOLD, 7, col_w - 24, 1, "stats label");
            const value_size = try self.fitSize(st.value, BOLD, if (card_h > 70) 26 else 20, 13, col_w - 24, "stats value");
            const note_h: f32 = if (st.note != null) 11 else 0;
            const block = 9 + 6 + value_size * 0.8 + note_h;
            const top_pad = (card_h - block) / 2;
            const t0 = PAGE_H - (cy + card_h) + top_pad;
            const upper = try std.ascii.allocUpperString(self.a, label_ls[0]);
            const lw = BOLD.measureTracked(upper, 7, 0.84);
            try self.cs.drawTrackedText(upper, col_x + (col_w - lw) / 2, baseline(t0, 7), self.f_bold, 7, 0.84, sub);
            const vw = BOLD.measureText(st.value, value_size);
            try self.text(st.value, col_x + (col_w - vw) / 2, baseline(t0 + 15, value_size), BOLD, value_size, fg);
            if (st.note) |note| {
                const note_ls = try self.lines(note, REGULAR, 8, col_w - 20, 1, "stats note");
                const nw = REGULAR.measureText(note_ls[0], 8);
                try self.text(note_ls[0], col_x + (col_w - nw) / 2, baseline(t0 + 15 + value_size * 0.8 + 5, 8), REGULAR, 8, sub);
            }
        }
        self.top += h + 12;
    }

    /// The largest size, from `start` down to `min`, at which `s` fits `width`.
    fn fitSize(self: *Renderer, s: []const u8, f: Font, start: f32, min: f32, width: f32, what: []const u8) !f32 {
        var size = start;
        while (size >= min) : (size -= 1) {
            if (f.measureText(s, size) <= width) return size;
        }
        self.diag.set("{s} '{s}' is too long for its card", .{ what, s });
        return error.TooLong;
    }

    fn offer(self: *Renderer) !void {
        const qr_size: f32 = 84;
        const pad: f32 = 14;
        const primary = self.l.installer.primary;
        const inner_x = MARGIN + pad;
        const qr_col_w: f32 = 104;
        const text_w = CONTENT_W - 2 * pad - qr_col_w - 10;

        // Lay the text out first so the box can grow to fit it.
        var t: f32 = 0;
        const Item = struct { ls: []const []const u8, f: Font, size: f32, leading: f32, c: Color, gap_after: f32 };
        var items: std.ArrayListUnmanaged(Item) = .empty;
        var figures: ?[2][2][]const u8 = null; // finance: equal-size monthly and APR
        var big_price: ?[2][]const u8 = null; // price: the figure and its note

        switch (self.l.offer) {
            .price => |p| {
                try items.append(self.a, .{ .ls = &.{"Your price"}, .f = BOLD, .size = 7.5, .leading = 13, .c = primary, .gap_after = 0 });
                try items.append(self.a, .{ .ls = try self.lines(p.headline, BOLD, 12, text_w, 1, "offer.headline"), .f = BOLD, .size = 12, .leading = 16, .c = INK, .gap_after = 4 });
                big_price = .{ p.price, p.price_note orelse "" };
                if (p.includes.len > 0) {
                    const joined = try std.mem.join(self.a, "  \u{00B7}  ", p.includes);
                    try items.append(self.a, .{ .ls = try self.lines(joined, REGULAR, 8.5, text_w, 2, "offer.includes"), .f = REGULAR, .size = 8.5, .leading = 12, .c = MUTED, .gap_after = 0 });
                }
            },
            .finance => |fi| {
                try items.append(self.a, .{ .ls = &.{"Finance"}, .f = BOLD, .size = 7.5, .leading = 13, .c = primary, .gap_after = 0 });
                try items.append(self.a, .{ .ls = try self.lines(fi.headline, BOLD, 12, text_w, 1, "offer.headline"), .f = BOLD, .size = 12, .leading = 16, .c = INK, .gap_after = 4 });
                figures = .{ .{ "Monthly payment", fi.monthly }, .{ "Representative APR", fi.apr } };
                const charges = if (fi.other_charges) |oc| try std.fmt.allocPrint(self.a, " Other charges: {s}.", .{oc}) else "";
                const example = try std.fmt.allocPrint(self.a, "Representative example: cash price {s}, deposit {s}, total amount of credit {s}, repayable by {s} monthly payments of {s}. Interest rate {s}. Representative APR {s}. Total amount payable {s}.{s} Credit is provided by {s}.", .{ fi.cash_price, fi.deposit, fi.credit, fi.term_months, fi.monthly, fi.interest_rate, fi.apr, fi.total_payable, charges, fi.lender });
                try items.append(self.a, .{ .ls = try self.lines(example, REGULAR, 8, text_w, 4, "offer representative example"), .f = REGULAR, .size = 8, .leading = 10.5, .c = INK, .gap_after = 0 });
            },
            .grant => |g| {
                try items.append(self.a, .{ .ls = &.{g.scheme}, .f = BOLD, .size = 7.5, .leading = 13, .c = primary, .gap_after = 0 });
                try items.append(self.a, .{ .ls = try self.lines(g.headline, BOLD, 12, text_w, 2, "offer.headline"), .f = BOLD, .size = 12, .leading = 15, .c = INK, .gap_after = 3 });
                try items.append(self.a, .{ .ls = try self.lines(g.body, REGULAR, 8.5, text_w, 2, "offer.body"), .f = REGULAR, .size = 8.5, .leading = 12, .c = INK, .gap_after = 3 });
                for (g.criteria) |cr| {
                    const bullet = try std.fmt.allocPrint(self.a, "\u{2022}  {s}", .{cr});
                    try items.append(self.a, .{ .ls = try self.lines(bullet, REGULAR, 8.5, text_w, 1, "offer.criteria"), .f = REGULAR, .size = 8.5, .leading = 11.5, .c = INK, .gap_after = 0 });
                }
            },
        }
        for (items.items, 0..) |it, i| {
            t += @as(f32, @floatFromInt(it.ls.len)) * it.leading + it.gap_after;
            if (i == 1) {
                if (figures != null) t += 40;
                if (big_price != null) t += 34;
            }
        }
        const box_h = @max(qr_size + 2 * pad + 14, t + 2 * pad);
        const box_y = PAGE_H - self.top - box_h;
        try self.cs.drawRoundedRectEx(MARGIN, box_y, CONTENT_W, box_h, 10, WHITE, primary, 1.2);

        // Text column.
        var ty = self.top + pad;
        for (items.items, 0..) |it, i| {
            if (i == 0) {
                const upper = try std.ascii.allocUpperString(self.a, it.ls[0]);
                try self.cs.drawTrackedText(upper, inner_x, baseline(ty, it.size), self.f_bold, it.size, it.size * 0.12, it.c);
                ty += it.leading;
            } else {
                ty += try self.paragraph(it.ls, inner_x, ty, it.f, it.size, it.leading, it.c);
                ty += it.gap_after;
            }
            if (i == 1) {
                if (figures) |fig| {
                    // CONC 3.5.7R(2): the representative APR at the same size as the monthly figure.
                    const col = text_w / 2;
                    for (fig, 0..) |pair, k| {
                        const x = inner_x + @as(f32, @floatFromInt(k)) * col;
                        const upper = try std.ascii.allocUpperString(self.a, pair[0]);
                        try self.cs.drawTrackedText(upper, x, baseline(ty, 6.5), self.f_bold, 6.5, 0.78, MUTED);
                    }
                    const size = @min(try self.fitSize(fig[0][1], BOLD, 22, 14, col - 8, "offer.monthly"), try self.fitSize(fig[1][1], BOLD, 22, 14, col - 8, "offer.apr"));
                    for (fig, 0..) |pair, k| {
                        const x = inner_x + @as(f32, @floatFromInt(k)) * col;
                        try self.text(pair[1], x, baseline(ty + 10, size), BOLD, size, primary);
                    }
                    ty += 40;
                }
                if (big_price) |bp| {
                    const size = try self.fitSize(bp[0], BOLD, 26, 16, text_w * 0.6, "offer.price");
                    try self.text(bp[0], inner_x, baseline(ty, size), BOLD, size, primary);
                    if (bp[1].len > 0) {
                        const pw = BOLD.measureText(bp[0], size);
                        const note_ls = try self.lines(bp[1], REGULAR, 9, text_w - pw - 10, 1, "offer.price_note");
                        try self.text(note_ls[0], inner_x + pw + 8, baseline(ty + size * 0.8 - 9, 9), REGULAR, 9, MUTED);
                    }
                    ty += 34;
                }
            }
        }

        // QR code and its caption on the right, linked to the same address.
        const qr_x = PAGE_W - MARGIN - pad - qr_col_w + (qr_col_w - qr_size) / 2;
        const qr_y = box_y + box_h - pad - qr_size;
        try self.qr(self.l.qr_url, qr_x, qr_y, qr_size);
        try self.doc.addLinkAnnotation(qr_x, qr_y, qr_x + qr_size, qr_y + qr_size, self.l.qr_url);
        const cap_ls = try self.lines(self.l.qr_caption, REGULAR, 7, qr_col_w, 2, "letter.qr_caption");
        for (cap_ls, 0..) |ln, i| {
            const w = REGULAR.measureText(ln, 7);
            try self.text(ln, PAGE_W - MARGIN - pad - qr_col_w + (qr_col_w - w) / 2, qr_y - 10 - @as(f32, @floatFromInt(i)) * 9, REGULAR, 7, MUTED);
        }

        self.top += box_h + 10;
    }

    /// QR code as vector squares (one rectangle per run of dark modules), so
    /// it prints sharp at any size.
    fn qr(self: *Renderer, url: []const u8, x: f32, y: f32, size: f32) !void {
        var code = qrcode.encode(self.a, url, .{ .ec_level = .M, .quiet_zone = 0 }) catch {
            self.diag.set("letter.qr_url can't be encoded as a QR code", .{});
            return error.InvalidInput;
        };
        defer code.deinit(self.a);
        const n: usize = code.size;
        const m = size / @as(f32, @floatFromInt(n));
        try self.cs.saveState();
        try self.cs.setFillColor(INK);
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
        const y = PAGE_H - self.top - h;
        const ins = self.l.installer;
        try self.cs.drawRoundedRect(MARGIN, y, CONTENT_W, h, 8, ins.primary);
        const call = try std.fmt.allocPrint(self.a, "Call us on {s}", .{ins.phone});
        try self.text(call, MARGIN + 14, y + 10.5, BOLD, 12, WHITE);
        try self.textRight(ins.website, PAGE_W - MARGIN - 14, y + 11, REGULAR, 9, WHITE);
        const tel = try std.fmt.allocPrint(self.a, "tel:{s}", .{ins.phone});
        const tel_clean = try std.mem.replaceOwned(u8, self.a, tel, " ", "");
        try self.doc.addLinkAnnotation(MARGIN, y, MARGIN + CONTENT_W / 2, y + h, tel_clean);
        self.top += h + 12;
    }

    fn accreditations(self: *Renderer) !void {
        const marks = self.l.installer.accreditations;
        if (marks.len == 0) return;
        const Mark = struct { id: []const u8, w: f32, h: f32 };
        const loaded = try self.a.alloc(Mark, marks.len);
        var h: f32 = 26;
        const gap: f32 = 16;
        var total: f32 = 0;
        for (marks, 0..) |src, i| {
            const what = try std.fmt.allocPrint(self.a, "installer.accreditations[{d}]", .{i});
            const img = try self.loadImage(src, what);
            loaded[i] = .{ .id = img.id, .w = img.w, .h = img.h };
            total += h * img.w / img.h;
        }
        total += gap * @as(f32, @floatFromInt(marks.len - 1));
        if (total > CONTENT_W) {
            const shrink = (CONTENT_W - gap * @as(f32, @floatFromInt(marks.len - 1))) / (total - gap * @as(f32, @floatFromInt(marks.len - 1)));
            h *= shrink;
            total = CONTENT_W;
        }
        var x = MARGIN + (CONTENT_W - total) / 2;
        const y = PAGE_H - self.top - 26 + (26 - h) / 2;
        for (loaded) |mk| {
            const w = h * mk.w / mk.h;
            try self.cs.drawImage(mk.id, x, y, w, h);
            x += w + gap;
        }
        self.top += 26 + 10;
    }

    fn smallPrint(self: *Renderer) !void {
        const ins = self.l.installer;
        const all = if (ins.legal_line) |ll| try std.fmt.allocPrint(self.a, "{s} {s}", .{ self.l.small_print, ll }) else self.l.small_print;
        const room = PAGE_H - self.top - BOTTOM;
        const leading: f32 = 8.6;
        const max_lines: usize = @intFromFloat(@max(0, @floor(room / leading)));
        const w = try document.wrapText(self.a, all, REGULAR, 6.6, CONTENT_W);
        if (w.lines.len > max_lines) {
            const over = @as(f32, @floatFromInt(w.lines.len)) * leading - room;
            self.diag.set("the letter runs {d:.0}pt past the bottom of the page; shorten the intro, offer or small print", .{over});
            return error.TooLong;
        }
        _ = try self.paragraph(w.lines, MARGIN, self.top, REGULAR, 6.6, leading, MUTED);
    }

    fn render(self: *Renderer) ![]const u8 {
        self.f_reg = self.doc.getFontId(REGULAR);
        self.f_bold = self.doc.getFontId(BOLD);
        self.doc.setInfo(.{ .title = self.l.headline, .author = self.l.installer.name, .creator = "zig_pdf_generator solar_letter" });
        try self.header();
        try self.recipient();
        try self.intro();
        try self.package();
        try self.hero();
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
