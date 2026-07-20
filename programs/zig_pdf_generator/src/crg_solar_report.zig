//! CRG Solar Proposal — a Zig-native, data-driven generator for the genuine
//! 20-page CRG Direct solar proposal (reproduced from
//! crgdirect.co.uk/example-solar-proposal.pdf).
//!
//! This is a port of `templates/crg_solar_report/build_report.py`: the same
//! A4-canvas layout, the same Adobe AFM Helvetica metrics, the same word-wrap,
//! now taking a small `CrgQuote` (the ~28 per-lead fields) as JSON and emitting
//! the PDF directly — no 2.66 MB template JSON, no Python at deploy. The 12
//! brand assets are @embedFile'd, so the module is self-contained (works in the
//! freestanding browser WASM build too).
//!
//! Layout is built as `presentation.PresentationData` structs in an arena and
//! rendered by the existing canvas renderer, so the drawing path is unchanged.
//!
//! Entry points:
//!   generateCrgSolarReport(alloc, quote) ![]u8
//!   generateCrgSolarReportFromJson(alloc, json) ![]u8   // parses CrgQuote
//! CLI: pdf-gen --crg-report <quote.json> <out.pdf>   (--crg-report-demo for sample)

const std = @import("std");
const presentation = @import("presentation.zig");
const P = presentation;
const Align = P.TextAlign;

// ---- A4 canvas (points, top-left origin) -----------------------------------
const PW: f64 = 595.28;
const PH: f64 = 841.89;
const ML: f64 = 45.0;
const MR: f64 = 45.0;
const CW: f64 = PW - ML - MR;

// ---- palette (sampled from the reference) ----------------------------------
const GREEN = "#38761D";
const BODY = "#000000";
const GREY = "#3a3a3a";
const LINK = "#1155cc";
const BAND_LT = "#ededed";
const BAND_MD = "#bfbfbf";
const BLUE_LT = "#dce6f1";
const HAIR = "#000000";

// ---- Helvetica / Helvetica-Bold AFM widths (units per 1000 em), ASCII 32..126
const HELV = [95]u16{
    278, 278, 355, 556, 556, 889, 667, 191, 333, 333, 389, 584, 278, 333, 278, 278,
    556, 556, 556, 556, 556, 556, 556, 556, 556, 556, 278, 278, 584, 584, 584, 556,
    1015, 667, 667, 722, 722, 667, 611, 778, 722, 278, 500, 667, 556, 833, 722, 778,
    667, 778, 722, 667, 611, 722, 667, 944, 667, 667, 611, 278, 278, 278, 469, 556,
    333, 556, 556, 500, 556, 556, 278, 556, 556, 222, 222, 500, 222, 833, 556, 556,
    556, 556, 333, 500, 278, 556, 500, 722, 500, 500, 500, 334, 260, 334, 584,
};
const HELVB = [95]u16{
    278, 333, 474, 556, 556, 889, 722, 238, 333, 333, 389, 584, 278, 333, 278, 278,
    556, 556, 556, 556, 556, 556, 556, 556, 556, 556, 333, 333, 584, 584, 584, 611,
    975, 722, 722, 722, 722, 667, 611, 778, 722, 278, 556, 722, 611, 833, 722, 778,
    667, 778, 722, 667, 611, 722, 667, 944, 667, 667, 611, 333, 278, 333, 584, 556,
    333, 556, 611, 556, 611, 556, 333, 611, 611, 278, 278, 556, 278, 889, 611, 611,
    611, 611, 389, 556, 333, 611, 556, 778, 556, 556, 500, 389, 280, 389, 584,
};

fn glyphW(cp: u21, bold: bool) u16 {
    if (cp >= 32 and cp <= 126) return if (bold) HELVB[cp - 32] else HELV[cp - 32];
    return switch (cp) {
        0x00A3 => 556, // £
        0x2013 => 556, // – en dash
        0x2014 => 1000, // — em dash
        0x2018, 0x2019 => if (bold) @as(u16, 238) else 191, // ' '
        0x201C, 0x201D => if (bold) @as(u16, 474) else 333, // " "
        0x00B0 => 400, // °
        0x2022 => 350, // •
        else => 556,
    };
}

fn textWidth(s: []const u8, size: f64, bold: bool) f64 {
    var total: u64 = 0;
    var it = std.unicode.Utf8View.initUnchecked(s).iterator();
    while (it.nextCodepoint()) |cp| total += glyphW(cp, bold);
    return @as(f64, @floatFromInt(total)) * size / 1000.0;
}

// Greedy word-wrap into lines fitting maxw, honouring explicit '\n'. Because the
// prose uses single spaces, each wrapped line is a contiguous slice of `s`.
fn wrap(a: std.mem.Allocator, s: []const u8, size: f64, maxw: f64, bold: bool) ![]const []const u8 {
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    var seg_it = std.mem.splitScalar(u8, s, '\n');
    while (seg_it.next()) |seg| {
        if (seg.len == 0) {
            try out.append(a, "");
            continue;
        }
        var line_start: usize = 0; // byte offset in seg of current line
        var line_end: usize = 0; // byte offset (exclusive) of current line content
        var have_line = false;
        var word_start: usize = 0;
        while (word_start <= seg.len) {
            // find end of the current word (next space or end)
            var word_end = word_start;
            while (word_end < seg.len and seg[word_end] != ' ') word_end += 1;
            const word = seg[word_start..word_end];
            if (!have_line) {
                line_start = word_start;
                line_end = word_end;
                have_line = true;
            } else {
                const cand = seg[line_start..word_end]; // includes the spaces between
                if (textWidth(cand, size, bold) <= maxw) {
                    line_end = word_end;
                } else {
                    try out.append(a, seg[line_start..line_end]);
                    line_start = word_start;
                    line_end = word_end;
                }
            }
            _ = word; // (word span captured via offsets)
            if (word_end >= seg.len) break;
            word_start = word_end + 1; // skip the single space
        }
        if (have_line) try out.append(a, seg[line_start..line_end]);
    }
    return out.items;
}

// ---- embedded brand assets (base64 data URLs, built once per generate) -----
const AssetsRaw = struct {
    cover: []const u8 = @embedFile("crg_assets/cover_house.jpg"),
    quote_photo: []const u8 = @embedFile("crg_assets/quote_photo.jpg"),
    medal: []const u8 = @embedFile("crg_assets/medal.png"),
    reviews: []const u8 = @embedFile("crg_assets/reviews.jpg"),
    logo: []const u8 = @embedFile("crg_assets/logo.png"),
    accreditation: []const u8 = @embedFile("crg_assets/accreditation.png"),
    canadian1: []const u8 = @embedFile("crg_assets/canadian1.jpg"),
    canadian2: []const u8 = @embedFile("crg_assets/canadian2.jpg"),
    sunsynk_inverter: []const u8 = @embedFile("crg_assets/sunsynk_inverter.jpg"),
    signature: []const u8 = @embedFile("crg_assets/signature.png"),
    sunpath: []const u8 = @embedFile("crg_assets/sunpath.png"),
    battery: []const u8 = @embedFile("crg_assets/battery.jpg"),
};

const Assets = struct {
    cover: []const u8,
    quote_photo: []const u8,
    medal: []const u8,
    reviews: []const u8,
    logo: []const u8,
    accreditation: []const u8,
    canadian1: []const u8,
    canadian2: []const u8,
    sunsynk_inverter: []const u8,
    signature: []const u8,
    sunpath: []const u8,
    battery: []const u8,
};

fn dataUrl(a: std.mem.Allocator, mime: []const u8, bytes: []const u8) ![]const u8 {
    const Enc = std.base64.standard.Encoder;
    const prefix = try std.fmt.allocPrint(a, "data:image/{s};base64,", .{mime});
    const b64_len = Enc.calcSize(bytes.len);
    const buf = try a.alloc(u8, prefix.len + b64_len);
    @memcpy(buf[0..prefix.len], prefix);
    _ = Enc.encode(buf[prefix.len..], bytes);
    return buf;
}

fn buildAssets(a: std.mem.Allocator) !Assets {
    const r = AssetsRaw{};
    return .{
        .cover = try dataUrl(a, "jpeg", r.cover),
        .quote_photo = try dataUrl(a, "jpeg", r.quote_photo),
        .medal = try dataUrl(a, "png", r.medal),
        .reviews = try dataUrl(a, "jpeg", r.reviews),
        .logo = try dataUrl(a, "png", r.logo),
        .accreditation = try dataUrl(a, "png", r.accreditation),
        .canadian1 = try dataUrl(a, "jpeg", r.canadian1),
        .canadian2 = try dataUrl(a, "jpeg", r.canadian2),
        .sunsynk_inverter = try dataUrl(a, "jpeg", r.sunsynk_inverter),
        .signature = try dataUrl(a, "png", r.signature),
        .sunpath = try dataUrl(a, "png", r.sunpath),
        .battery = try dataUrl(a, "jpeg", r.battery),
    };
}

// ---- the per-lead data (all strings, mirrors the Python QUOTE dict) --------
pub const CrgQuote = struct {
    ref: []const u8 = "PO4 Joe",
    client: []const u8 = "Joe Bloggs",
    address: []const u8 = "N/A",
    postcode: []const u8 = "PO4 9nx",
    date: []const u8 = "2026-03-05",
    kw: []const u8 = "4.92",
    annual_saving: []const u8 = "0",
    total_price: []const u8 = "7,430",
    net_price: []const u8 = "7,430",
    total_price_dec: []const u8 = "7430.00",
    lifetime_saving: []const u8 = "0",
    panel_count: []const u8 = "12",
    panel_model: []const u8 = "Cs3l-355ms-ab",
    panel_model_raw: []const u8 = "cs3l-355ms-ab",
    panel_watt: []const u8 = "410",
    battery: []const u8 = "5.3 Sunsynk Battery",
    battery_kwh: []const u8 = "5.3Kw",
    inverter: []const u8 = "Sun-3.6-ecco Inverter",
    inverter_raw: []const u8 = "sunsynk sun-3.6-ecco",
    annual_usage_kwh: []const u8 = "7450",
    tariff_p: []const u8 = "0.34",
    annual_gen_kwh: []const u8 = "0",
    deposit: []const u8 = "1,115",
    stage: []const u8 = "2,972",
    balance: []const u8 = "3,344",
    payback_years: []const u8 = "0",
    array_sqm: []const u8 = "22.44",
};

// ---- table cell / row types (mirror the Python grid dicts) -----------------
const Cell = struct {
    t: []const u8 = "",
    al: Align = .left,
    bg: ?[]const u8 = null,
    bold: bool = false,
    color: []const u8 = BODY,
    size: ?f64 = null,
};
const Row = struct {
    cells: []const Cell,
    widths: ?[]const f64 = null,
    h: ?f64 = null,
};

// ---- builder ---------------------------------------------------------------
const TextOpts = struct {
    size: f64 = 10.5,
    color: []const u8 = BODY,
    bold: bool = false,
    italic: bool = false,
    al: Align = .left,
};
const ParaOpts = struct {
    size: f64 = 10.5,
    color: []const u8 = BODY,
    bold: bool = false,
    italic: bool = false,
    x: f64 = ML,
    maxw: f64 = CW,
    lh: f64 = 1.32,
    gap_after: f64 = 8,
    al: Align = .left,
};
const HeadOpts = struct {
    size: f64 = 21,
    color: []const u8 = GREEN,
    gap_before: f64 = 0,
    gap_after: f64 = 14,
};
const BulletsOpts = struct {
    size: f64 = 10.5,
    color: []const u8 = BODY,
    x: f64 = ML,
    maxw: f64 = CW,
    lh: f64 = 1.3,
    gap_after: f64 = 8,
    indent: f64 = 16,
};
const GridOpts = struct {
    y: ?f64 = null,
    border: ?[]const u8 = "#000000",
    sw: f64 = 0.7,
    size: f64 = 9.5,
    pad: f64 = 5,
    lh: f64 = 1.12,
    min_h: f64 = 0,
};

const B = struct {
    a: std.mem.Allocator,
    els: std.ArrayListUnmanaged(P.Element) = .empty,
    y: f64 = 50,
    bg: []const u8 = "#ffffff",

    fn page(self: *B) P.Page {
        return .{ .background_color = self.bg, .elements = self.els.items };
    }
    fn f(self: *B, comptime fmt: []const u8, args: anytype) []const u8 {
        return std.fmt.allocPrint(self.a, fmt, args) catch unreachable;
    }
    fn gap(self: *B, dy: f64) void {
        self.y += dy;
    }

    fn text(self: *B, x: f64, y: f64, s: []const u8, o: TextOpts) !void {
        var xx = x;
        if (o.al == .center) {
            xx = x - textWidth(s, o.size, o.bold) / 2.0;
        } else if (o.al == .right) {
            xx = x - textWidth(s, o.size, o.bold);
        }
        try self.els.append(self.a, .{ .text = .{
            .content = s,
            .x = @floatCast(xx),
            .y = @floatCast(y),
            .font_size = @floatCast(o.size),
            .color = o.color,
            .font_weight = if (o.bold) .bold else .normal,
            .font_style = if (o.italic) .italic else .normal,
        } });
    }

    fn image(self: *B, b64: []const u8, x: f64, y: f64, w: f64, h: f64) !void {
        try self.els.append(self.a, .{ .image = .{
            .base64 = b64,
            .x = @floatCast(x),
            .y = @floatCast(y),
            .width = @floatCast(w),
            .height = @floatCast(h),
        } });
    }

    fn rect(self: *B, x: f64, y: f64, w: f64, h: f64, fill: ?[]const u8, stroke: ?[]const u8, sw: f64) !void {
        try self.els.append(self.a, .{ .shape = .{
            .shape = .rectangle,
            .x = @floatCast(x),
            .y = @floatCast(y),
            .width = @floatCast(w),
            .height = @floatCast(h),
            .fill_color = fill,
            .stroke_color = stroke,
            .stroke_width = @floatCast(sw),
        } });
    }

    fn hline(self: *B, x1: f64, x2: f64, y: f64, color: []const u8, w: f64) !void {
        try self.els.append(self.a, .{ .shape = .{
            .shape = .line,
            .x = @floatCast(x1),
            .y = @floatCast(y),
            .width = @floatCast(x2 - x1),
            .height = 0,
            .fill_color = null,
            .stroke_color = color,
            .stroke_width = @floatCast(w),
        } });
    }

    fn heading(self: *B, s: []const u8, o: HeadOpts) !void {
        self.y += o.gap_before + o.size;
        try self.text(ML, self.y, s, .{ .size = o.size, .color = o.color });
        self.y += o.gap_after;
    }

    fn para(self: *B, s: []const u8, o: ParaOpts) !void {
        const lines = try wrap(self.a, s, o.size, o.maxw, o.bold);
        const step = o.size * o.lh;
        const anchor: f64 = if (o.al == .left) o.x else if (o.al == .center) o.x + o.maxw / 2.0 else o.x + o.maxw;
        for (lines) |ln| {
            self.y += step;
            try self.text(anchor, self.y, ln, .{ .size = o.size, .color = o.color, .bold = o.bold, .italic = o.italic, .al = o.al });
        }
        self.y += o.gap_after;
    }

    fn bullets(self: *B, items: []const []const u8, o: BulletsOpts) !void {
        const step = o.size * o.lh;
        for (items) |it| {
            const lines = try wrap(self.a, it, o.size, o.maxw - o.indent, false);
            var first = true;
            for (lines) |ln| {
                self.y += step;
                if (first) {
                    try self.text(o.x + 3, self.y, "\u{2022}", .{ .size = o.size, .color = o.color });
                    first = false;
                }
                try self.text(o.x + o.indent, self.y, ln, .{ .size = o.size, .color = o.color });
            }
            self.y += 2;
        }
        self.y += o.gap_after;
    }

    fn link(self: *B, url: []const u8, size: f64, gap_after: f64) !void {
        self.y += size * 1.3;
        try self.text(ML, self.y, url, .{ .size = size, .color = LINK });
        self.y += gap_after;
    }

    fn grid(self: *B, x: f64, col_w: []const f64, rows: []const Row, o: GridOpts) !void {
        var yc = o.y orelse self.y;
        for (rows) |row| {
            const widths = row.widths orelse col_w;
            const h = row.h orelse blk: {
                var maxln: usize = 1;
                for (row.cells, 0..) |c, i| {
                    if (c.t.len != 0) {
                        const csz = c.size orelse o.size;
                        const lines = try wrap(self.a, c.t, csz, widths[i] - 2 * o.pad, c.bold);
                        if (lines.len > maxln) maxln = lines.len;
                    }
                }
                break :blk @max(o.min_h, @as(f64, @floatFromInt(maxln)) * o.size * o.lh + 2 * o.pad + 4);
            };
            var cx = x;
            for (row.cells, 0..) |c, i| {
                const w = widths[i];
                if (c.bg) |bg| try self.rect(cx, yc, w, h, bg, null, o.sw);
                if (o.border) |b| try self.rect(cx, yc, w, h, null, b, o.sw);
                if (c.t.len != 0) {
                    const csize = c.size orelse o.size;
                    const lines = try wrap(self.a, c.t, csize, w - 2 * o.pad, c.bold);
                    const step = csize * o.lh;
                    const block = step * @as(f64, @floatFromInt(lines.len));
                    const base = yc + (h - block) / 2.0 + csize * 0.80;
                    for (lines, 0..) |ln, k| {
                        const ly = base + @as(f64, @floatFromInt(k)) * step;
                        const tx: f64 = if (c.al == .left) cx + o.pad else if (c.al == .center) cx + w / 2.0 else cx + w - o.pad;
                        try self.text(tx, ly, ln, .{ .size = csize, .color = c.color, .bold = c.bold, .al = c.al });
                    }
                }
                cx += w;
            }
            yc += h;
        }
        self.y = yc;
    }
};

// ---- helpers to arena-copy runtime cell/width slices (avoid dangling temps) --
fn cs(a: std.mem.Allocator, cells: []const Cell) []const Cell {
    return a.dupe(Cell, cells) catch unreachable;
}
fn ws(a: std.mem.Allocator, widths: []const f64) []const f64 {
    return a.dupe(f64, widths) catch unreachable;
}
fn perfBand(a: std.mem.Allocator, title: []const u8, sz: f64) Row {
    return .{ .cells = cs(a, &.{.{ .t = title, .al = .center, .bg = BAND_LT, .size = sz }}), .widths = ws(a, &.{CW}), .h = 18 };
}
fn perfRow(a: std.mem.Allocator, label: []const u8, val: []const u8, shade: bool, sz: f64) Row {
    const bg: ?[]const u8 = if (shade) BLUE_LT else null;
    return .{ .cells = cs(a, &.{ .{ .t = label, .bg = bg, .size = sz }, .{ .t = val, .bg = bg, .size = sz } }) };
}

// ============================================================================
// PAGE 1 — COVER (fully-designed cover JPEG, full-bleed)
// ============================================================================
fn p01(a: std.mem.Allocator, q: CrgQuote, A: Assets) !P.Page {
    _ = q;
    var b = B{ .a = a };
    try b.image(A.cover, 0, 0, PW, PH);
    return b.page();
}

// ============================================================================
// PAGE 2 — INTRODUCTION
// ============================================================================
fn p02(a: std.mem.Allocator, q: CrgQuote, A: Assets) !P.Page {
    _ = q;
    _ = A;
    var b = B{ .a = a };
    try b.heading("Introduction", .{ .gap_after = 6 });
    b.y = 430;
    try b.para("Welcome to CRG Direct. Here’s your bespoke solar quote. In this " ++
        "quote, you’ll find the cost of your system, your estimated savings " ++
        "using MCS calculations, and more information about your recommended " ++
        "solar system.", .{ .size = 16, .lh = 1.28, .gap_after = 26 });
    const top = b.y;
    const colw = (CW - 30) / 2;
    b.y = top;
    try b.para("At CRG Direct, we believe in delivering quality service that goes " ++
        "above and beyond for our customers. Our dedicated team works " ++
        "tirelessly to ensure that every installation is done efficiently and " ++
        "with the utmost care. We understand the importance of clear " ++
        "communication and transparency, which is why we make sure our " ++
        "pricing is always straightforward and competitive.", .{ .size = 9.5, .maxw = colw, .gap_after = 8 });
    try b.para("Customer satisfaction is our top priority, and we are proud of our " ++
        "5-star reviews on Google. These reviews are a testament to our " ++
        "commitment to excellence and our unwavering dedication to providing " ++
        "the best service possible.", .{ .size = 9.5, .maxw = colw });
    b.y = top;
    const rx = ML + colw + 30;
    try b.para("If you are considering CRG Direct for your next project, we encourage " ++
        "you to visit our website at www.crgdirect.co.uk for more information. " ++
        "And remember, if you have any questions at all, our friendly team is " ++
        "always here to help. Thank you for considering CRG Direct for your " ++
        "solar and home improvement needs.", .{ .size = 9.5, .x = rx, .maxw = colw });
    return b.page();
}

// ============================================================================
// PAGE 3 — YOUR QUOTE
// ============================================================================
fn p03(a: std.mem.Allocator, q: CrgQuote, A: Assets) !P.Page {
    var b = B{ .a = a };
    try b.heading("Your quote", .{ .gap_after = 10 });
    try b.hline(ML, PW - MR, b.y, HAIR, 1.0);
    b.gap(24);
    try b.text(PW / 2, b.y, "Recommended System Option", .{ .size = 15, .al = .center });
    b.gap(30);
    const Metric = struct { val: []const u8, lab: []const u8 };
    const labels = [_]Metric{
        .{ .val = b.f("{s} kW", .{q.kw}), .lab = "System Size" },
        .{ .val = b.f("£ {s}", .{q.annual_saving}), .lab = "Estimated Annual\nElectricity Bill Savings" },
        .{ .val = b.f("£ {s}", .{q.total_price}), .lab = "Total System Price" },
        .{ .val = b.f("£ {s}", .{q.net_price}), .lab = "Net System Price" },
    };
    const n: f64 = 4;
    const vy = b.y;
    for (labels, 0..) |m, i| {
        const cx = ML + CW * (@as(f64, @floatFromInt(i)) + 0.5) / n;
        try b.text(cx, vy, m.val, .{ .size = 15, .al = .center });
        const ly = vy + 26;
        var jt = std.mem.splitScalar(u8, m.lab, '\n');
        var j: f64 = 0;
        while (jt.next()) |part| : (j += 1) {
            try b.text(cx, ly + j * 11, part, .{ .size = 8, .color = GREY, .al = .center });
        }
    }
    b.y = vy + 52;
    const sum = [_][]const u8{
        b.f("System Size: {s} KWp", .{q.kw}),
        b.f("Total System Price:  £ {s}", .{q.total_price}),
        b.f("Estimated Annual Electricity Bill Savings:  £ {s}", .{q.annual_saving}),
        b.f("Estimated Lifetime Savings:  £ {s}", .{q.lifetime_saving}),
    };
    for (sum) |line| {
        b.gap(20);
        try b.text(ML, b.y, line, .{ .size = 12.5 });
    }
    b.gap(16);
    try b.hline(ML, PW - MR, b.y, HAIR, 1.0);
    b.gap(22);
    try b.text(ML, b.y, "Your system is made up of:", .{});
    const made = [_][]const u8{ b.f("{s} {s} Panels", .{ q.panel_count, q.panel_model }), q.battery, q.inverter };
    for (made) |line| {
        b.gap(18);
        try b.text(ML, b.y, line, .{});
    }
    b.gap(16);
    try b.para(b.f("We’ve estimated you’ll save £ {s} over the lifetime of your " ++
        "system using regulated MCS calculations. You’ll see a breakdown of " ++
        "this on page 7.", .{q.lifetime_saving}), .{ .gap_after = 6 });
    try b.para("Your total cost includes installation fees and more. We’ll also " ++
        "handle your DNO application. All equipment is MCS certified.", .{ .gap_after = 6 });
    try b.para("These modules comply with the following international standards:", .{ .gap_after = 6 });
    try b.para("Carry CE mark", .{ .gap_after = 6 });
    try b.para(b.f("You are using {s} of electricity per year at {s}p. We estimate your new " ++
        "system will produce {s} KWH of electricity per annum, giving approx’ " ++
        "£ {s} worth of savings per annum.", .{ q.annual_usage_kwh, q.tariff_p, q.annual_gen_kwh, q.annual_saving }), .{ .gap_after = 6 });
    try b.para(b.f("The total cost of the system is £ {s} MCS calculations predict you " ++
        "will use 95% of the energy produced.", .{q.total_price_dec}), .{ .gap_after = 6 });
    const ph_h: f64 = 150;
    try b.image(A.quote_photo, 0, PH - ph_h, PW, ph_h);
    return b.page();
}

// ============================================================================
// PAGE 4 — REVIEWS (screenshot)
// ============================================================================
fn p04(a: std.mem.Allocator, q: CrgQuote, A: Assets) !P.Page {
    _ = q;
    var b = B{ .a = a };
    try b.heading("You're in good hands", .{ .gap_after = 6 });
    try b.image(A.medal, ML + 250, 34, 40, 41);
    try b.para("Before we get to your quote, we’d love to show you our amazing " ++
        "reviews for our brilliant customer service.", .{ .size = 9.5, .maxw = 360, .gap_after = 12 });
    const iw = CW;
    const ih = iw * (2769.0 / 1953.0);
    try b.image(A.reviews, ML, b.y, iw, @min(ih, PH - b.y - 30));
    return b.page();
}

// ============================================================================
// PAGE 5 — DETAILS & INFO
// ============================================================================
fn p05(a: std.mem.Allocator, q: CrgQuote, A: Assets) !P.Page {
    var b = B{ .a = a };
    try b.heading("Details & Info", .{ .gap_after = 10 });
    try b.image(A.logo, PW - MR - 150, 34, 150, 65);
    b.gap(4);
    try b.text(ML, b.y, "CRG Direct Ltd", .{ .size = 10.5, .color = GREEN });
    b.gap(22);
    try b.text(ML, b.y, "Integrated Management System", .{ .size = 10.5, .color = GREEN });
    b.gap(24);
    const KV = struct { k: []const u8, v: []const u8 };
    const rows = [_]KV{
        .{ .k = "Document Title :", .v = "Customer Quote" },
        .{ .k = "Ref. No. :", .v = q.ref },
        .{ .k = "Next Review Date :", .v = "One Year" },
        .{ .k = "MCS Accredited Company:", .v = "CRG DIRECT LTD" },
        .{ .k = "MCS Accredited Number", .v = "NIC600310(Company Registration Number: 10546909)" },
        .{ .k = "Registered Office Address:", .v = "Wey Court West Union Road, Farnham, GU9 7PT" },
        .{ .k = "Principal Trading Address:", .v = "172 Sea Front Hayling Island PO11 9HP" },
        .{ .k = "Contact Details:", .v = "Tel: 0330 133 2497/07955568287\nadmin@crgdirect.co.uk" },
        .{ .k = "Website:", .v = "www.crgdirect.co.uk" },
        .{ .k = "HIES Membership Number:", .v = "CRG/A/088" },
        .{ .k = "MCS Accredited Company:", .v = "CRG DIRECT LTD" },
        .{ .k = "Trustmark", .v = "2855428" },
        .{ .k = "MCS Certification Number:", .v = "NIC600310" },
        .{ .k = "Project Reference:", .v = q.ref },
        .{ .k = "Client:", .v = q.client },
        .{ .k = "Address:", .v = q.address },
        .{ .k = "Postcode:", .v = q.postcode },
        .{ .k = "Date:", .v = q.date },
    };
    const vx = ML + 175;
    for (rows) |kv| {
        try b.text(ML, b.y, kv.k, .{ .size = 9.5, .color = GREEN });
        var vt = std.mem.splitScalar(u8, kv.v, '\n');
        var j: f64 = 0;
        var nlines: f64 = 0;
        while (vt.next()) |vl| : (j += 1) {
            try b.text(vx, b.y + j * 12, vl, .{ .size = 9.5, .color = BODY });
            nlines += 1;
        }
        b.gap(19 + (nlines - 1) * 12);
    }
    b.gap(6);
    try b.para("Really nice to meet you and thanks for allowing me the opportunity to " ++
        "provide a quotation for your proposed Solar PV installation.", .{ .size = 9.5, .gap_after = 8 });
    try b.para("We endeavour to deliver the equipment as specified but due to global " ++
        "pressure these may have to be amended.We are obligated to provide you " ++
        "with certain Pre-Sale Information as part of our compliance with the " ++
        "Microgeneration Certification Scheme and in particular the Solar PV " ++
        "Standard MIS-3002 and MIS-3012 The Battery Standard including " ++
        "performance estimates and potential shade effects (if any).", .{ .size = 9.5, .gap_after = 8 });
    try b.text(ML, b.y + 6, b.f("Quote Reference: {s}", .{q.ref}), .{});
    b.gap(6);
    const aw = CW;
    const ah = aw * (106.0 / 902.0);
    try b.image(A.accreditation, ML, PH - 55, aw, ah);
    return b.page();
}

// ============================================================================
// PAGE 6 — OVERVIEW / SYSTEM DETAIL
// ============================================================================
fn p06(a: std.mem.Allocator, q: CrgQuote, A: Assets) !P.Page {
    var b = B{ .a = a };
    b.y = 46;
    try b.para("All our work is backed by HIES, the Home Insulation and Energy " ++
        "Systems insurance backed guarantee and we are fully MCS accredited.", .{ .size = 10.5, .gap_after = 8 });
    try b.heading("OVERVIEW:", .{ .size = 17, .gap_before = 2, .gap_after = 8 });
    try b.bullets(&.{
        b.f("{s} canadian_solar {s} {s},output per panel is {s}", .{ q.panel_count, q.panel_model_raw, q.panel_watt, q.panel_watt }),
        b.f("watts Inverter is a {s}", .{q.inverter_raw}),
        b.f("Total system generation of{s} KWp", .{q.kw}),
        b.f("System cost is £{s}", .{q.total_price_dec}),
        b.f("Predicted annual electricity produce is {s} Kwh", .{q.annual_gen_kwh}),
        "If you also have opted for a battery it is",
        b.f("Battery Storage System {s}", .{q.battery_kwh}),
    }, .{ .size = 10.5, .gap_after = 6 });
    try b.heading("SYSTEM DETAIL:", .{ .size = 17, .gap_before = 2, .gap_after = 8 });
    try b.para(b.f("Having visited your property we are able to fit {s} panels on your " ++
        "South facing roof by using {s} panels creating a {s} KWH system.We are " ++
        "proposing to supply MCS approved canadian_solar {s} {s} panels. These " ++
        "panels achieve a higher cell efficiency which means more energy per " ++
        "square meter. Use of first-class materials result in an increased " ++
        "durability so they reach a higher reliability, assured by a 25 year " ++
        "performance guarantee.", .{ q.panel_count, q.panel_watt, q.kw, q.panel_model_raw, q.panel_watt }), .{ .size = 10.5, .gap_after = 8 });
    try b.para("These modules comply with the following international standards:", .{ .size = 10.5, .gap_after = 4 });
    try b.bullets(&.{ "IEC 61730 – Safety Qualification", "IEC 61215", "Carry CE mark" }, .{ .size = 10.5, .gap_after = 8 });
    try b.para(b.f("You are using {s} of electricity per year at {s}p. We estimate your new " ++
        "system will produce {s} KWH of electricity per annum, giving approx’ " ++
        "£{s} worth of savings per annum.", .{ q.annual_usage_kwh, q.tariff_p, q.annual_gen_kwh, q.annual_saving }), .{ .size = 10.5, .gap_after = 8 });
    try b.para(b.f("The total cost of the system is £{s} MCS calculations predict you " ++
        "will use 95% of the energy produced.", .{q.total_price_dec}), .{ .size = 10.5, .gap_after = 10 });
    const img_y = b.y;
    var dw: f64 = 250;
    var dh = dw * (1754.0 / 1240.0);
    if (img_y + dh > PH - 30) {
        dh = PH - 30 - img_y;
        dw = dh * (1240.0 / 1754.0);
    }
    try b.image(A.canadian1, ML, img_y, dw, dh);
    const tx = ML + dw + 18;
    b.y = img_y - 4;
    try b.para("The panels would be mounted on your roof using an aluminium mounting " ++
        "frame system certified by MCS complete with the required hooks, " ++
        "connectors and clamps to ensure a quality finish to your system.", .{ .size = 10.5, .x = tx, .maxw = PW - MR - tx, .gap_after = 10 });
    try b.para("A generation meter will also be installed in the property so you can " ++
        "see what energy you are producing.", .{ .size = 10.5, .x = tx, .maxw = PW - MR - tx, .gap_after = 12 });
    var dw2 = PW - MR - tx;
    var dh2 = dw2 * (1754.0 / 1240.0);
    if (b.y + dh2 > PH - 30) {
        dh2 = PH - 30 - b.y;
        dw2 = dh2 * (1240.0 / 1754.0);
    }
    try b.image(A.canadian2, tx, b.y, dw2, dh2);
    return b.page();
}

// ============================================================================
// PAGE 7 — INVERTER
// ============================================================================
fn p07(a: std.mem.Allocator, q: CrgQuote, A: Assets) !P.Page {
    var b = B{ .a = a };
    try b.heading("INVERTER", .{ .size = 17, .gap_after = 8 });
    try b.para(b.f("The inverter we are proposing is a {s} panels on your inverter. The " ++
        "data sheet below shows the capabilities and limitations of your " ++
        "inverter, be advised if you have an inverter that does not support " ++
        "battery storage and at some point in the future you require battery " ++
        "storage you will need to upgrade your inverter..", .{q.inverter_raw}), .{ .size = 10.5, .gap_after = 16 });
    var iw: f64 = 430;
    var ih = iw * (1600.0 / 1131.0);
    if (b.y + ih > PH - 30) {
        ih = PH - 30 - b.y;
        iw = ih * (1131.0 / 1600.0);
    }
    try b.image(A.sunsynk_inverter, (PW - iw) / 2, b.y, iw, ih);
    return b.page();
}

// ============================================================================
// PAGE 8 — PRICE
// ============================================================================
fn p08(a: std.mem.Allocator, q: CrgQuote, A: Assets) !P.Page {
    _ = A;
    var b = B{ .a = a };
    b.y = 170;
    try b.heading("PRICE", .{ .size = 17, .gap_after = 10 });
    try b.para(b.f("The price for this {s} Kwh system fully fitted including VAT (where " ++
        "applicable) is  £{s}", .{ q.kw, q.total_price }), .{ .size = 10.5, .gap_after = 10 });
    try b.para("This price includes the following:", .{ .size = 10.5, .gap_after = 4 });
    try b.bullets(&.{
        b.f("Battery Storage System {s}", .{q.battery_kwh}),
        "Panels, inverter, mounting frame",
        "Additional electrical work, cabling etc",
        "Delivery", "Fitting Cost", "Scaffolding", "Roof Survey",
        "Generation Meter – a means of recording and displaying the total AC generation",
        "Handover Pack and MCS Certificate (if a valid Mpan is submitted)",
        "Guarantees and Warranties", "Registration with DNO", "iBoost",
        "BirdGuard no", "Number of optimisers to be installed 0", "EPS no", "UPS no",
    }, .{ .size = 10.5, .gap_after = 12 });
    try b.heading("SCHEDULE FOR PAYMENT", .{ .size = 17, .gap_after = 10 });
    try b.para("This price includes the following:", .{ .size = 10.5, .gap_after = 4 });
    try b.bullets(&.{
        "Deposit of 15% upon placing of order.",
        "Stage payment of 40% on agreed install date",
        "Final payment of balance on completion of install and commissioning",
    }, .{ .size = 10.5, .gap_after = 10 });
    try b.para("Our estimated costs include the supply, delivery, installation, " ++
        "testing and commissioning of the solar array, including any works to " ++
        "the existing electrical consumer unit to enable the installation of " ++
        "the solar system. Our costs also include scaffolding as required while " ++
        "carrying out works on the roof.", .{ .size = 10.5, .gap_after = 8 });
    try b.para("All systems we supply are installed by professional fitters. An MCS " ++
        "Certificate will be provided.", .{ .size = 10.5, .gap_after = 10 });
    try b.text(ML, b.y, "Account Details:", .{ .size = 10.5 });
    b.gap(20);
    try b.text(ML, b.y, "Bank", .{ .size = 9.5 });
    try b.text(ML + 70, b.y, "Natwest", .{ .size = 9.5 });
    try b.text(ML + 300, b.y, "Sort Code", .{ .size = 9.5 });
    try b.text(ML + 375, b.y, "52-41-20", .{ .size = 9.5 });
    b.gap(24);
    try b.text(ML, b.y, "Account", .{ .size = 9.5 });
    try b.text(ML, b.y + 11, "Name", .{ .size = 9.5 });
    try b.text(ML + 70, b.y, "CRG Direct Ltd", .{ .size = 9.5 });
    try b.text(ML + 300, b.y, "Account", .{ .size = 9.5 });
    try b.text(ML + 300, b.y + 11, "No.", .{ .size = 9.5 });
    try b.text(ML + 375, b.y, "43634435", .{ .size = 9.5 });
    b.gap(24);
    try b.rect(ML, b.y - 12, CW, 20, BAND_LT, "#999999", 0.6);
    try b.text(PW / 2, b.y + 2, "Payment Terms", .{ .size = 10.5, .al = .center });
    return b.page();
}

// ============================================================================
// PAGE 9 — PAYMENT TERMS TABLE + CANCELLATION + SIGNATURE
// ============================================================================
fn p09(a: std.mem.Allocator, q: CrgQuote, A: Assets) !P.Page {
    var b = B{ .a = a };
    b.y = 40;
    const cw3 = [_]f64{ 78, 350, CW - 428 };
    const rows = [_]Row{
        .{ .cells = cs(a, &.{ .{ .t = "Deposit:" }, .{ .t = "Deposit (Maximum 15% of the total sum inc VAT) payable on confirmation of order" }, .{ .t = b.f("£{s}", .{q.deposit}), .al = .right } }) },
        .{ .cells = cs(a, &.{ .{ .t = "Advance\nPayment:" }, .{ .t = "Further advance payment payable when an install date agreed 40% of the total sum inc VAT" }, .{ .t = b.f("£{s}", .{q.stage}), .al = .right } }) },
        .{ .cells = cs(a, &.{ .{ .t = "Balance:" }, .{ .t = "Balance payable following final commissioning" }, .{ .t = b.f("£{s}", .{q.balance}), .al = .right } }) },
    };
    try b.grid(ML, &cw3, &rows, .{ .border = "#888888", .sw = 0.7, .size = 9.0, .pad = 6 });
    b.gap(8);
    try b.para("It is important that this quotation is read in conjunction with the " ++
        "full performance estimate that forms part of it in the following " ++
        "pages. If you require clarification on any point please do not " ++
        "hesitate to contact us", .{ .size = 9.5, .gap_after = 16 });
    b.gap(6);
    try b.para("All quotes valid for 14 days and subject to our terms and conditions", .{ .size = 13, .color = GREEN, .al = .center, .gap_after = 34 });
    const paras = [_][]const u8{
        "This quotation has been based on us being able to install your system as " ++
            "described without interruption. Should there be circumstances beyond our " ++
            "control which cause an interruption to the installation process we will " ++
            "discuss with you the implications of such a delay.",
        "Should you decide to make any changes to the agreed installation within " ++
            "your cancellation period, we will produce another full quotation which " ++
            "takes into account these changes. You will be given a further cancellation " ++
            "period to consider this quotation.",
        "Should you wish to make any changes to the agreed installation after your " ++
            "cancellation period has expired, again we will prepare a new quotation for " ++
            "you, but we reserve the right to charge for any reasonable costs we have " ++
            "incurred in working towards the original installation details.",
        "If, during the installation process, we come across any situation that we " ++
            "could not reasonably be expected to foresee, for example, remedial " ++
            "electrical or building work, we will discuss with you the implications and " ++
            "costs involved in rectifying the problem.",
        "Should you request any changes after the installation process has begun " ++
            "that involve additional cost we will provide you with a quotation based on " ++
            "the daily or hourly rate of our installers.",
    };
    for (paras) |pp| try b.para(pp, .{ .size = 10.5, .gap_after = 8 });
    b.gap(6);
    try b.text(ML, b.y, "Yours sincerely,", .{ .size = 10.5 });
    b.gap(6);
    try b.image(A.signature, ML, b.y, 120, 32);
    b.gap(40);
    try b.text(ML, b.y, "Lance Pearson – Managing Director", .{ .size = 10.5 });
    return b.page();
}

// ============================================================================
// PAGE 10 — PERFORMANCE ESTIMATION (big table)
// ============================================================================
fn p10(a: std.mem.Allocator, q: CrgQuote, A: Assets) !P.Page {
    _ = A;
    var b = B{ .a = a };
    try b.heading("PERFORMANCE ESTIMATION", .{ .size = 17, .gap_after = 10 });
    try b.para("Please see the following section which shows an estimate of the annual " ++
        "total generation of the proposed system calculated using the " ++
        "methodology recommended in the MIS-3002 specification and MGD 003 " ++
        "“Determining the Electrical Self-Consumption of Domestic Solar " ++
        "Photovoltaic (PV) Installations with and without Electrical Energy " ++
        "Storage”.", .{ .size = 10, .gap_after = 8 });
    try b.para(b.f("Electricity Per Year – {s} Kwh solar PV array.", .{q.kw}), .{ .size = 10, .gap_after = 10 });
    try b.para("PV PERFORMANCE ESTIMATION", .{ .size = 13, .gap_after = 8 });
    const lc = CW * 0.62;
    const rc = CW * 0.38;
    const SZ: f64 = 9.0;
    var rows: std.ArrayListUnmanaged(Row) = .empty;
    try rows.append(a, perfBand(a, "A. Installation Cost", SZ));
    try rows.append(a, perfRow(a, "Installed capacity of PV system - kWP (stc)", b.f("{s} Kwh", .{q.kw}), true, SZ));
    try rows.append(a, perfRow(a, "Orientation of the PV system - degrees from South", "", false, SZ));
    try rows.append(a, perfRow(a, "Inclination of system - degrees from horizontal", "35°", true, SZ));
    try rows.append(a, perfRow(a, "Postcode region", "SOUTHERN ENGLAND", false, SZ));
    try rows.append(a, perfBand(a, "B. Performance Calculations", SZ));
    try rows.append(a, perfRow(a, "kWh/kWp (Kk) from table", "0", true, SZ));
    try rows.append(a, perfRow(a, "Shade factor (SF)", "0 %", false, SZ));
    try rows.append(a, perfRow(a, "Estimated annual output (kWp x Kk x SF)", "0", true, SZ));
    try rows.append(a, perfBand(a, "C. Estimated PV self-consumption-PV Only", SZ));
    try rows.append(a, perfRow(a, "Assumed occupancy archetype", "Out all day", true, SZ));
    try rows.append(a, perfRow(a, "Assumed annual electricity consumption, kWh", q.annual_usage_kwh, false, SZ));
    try rows.append(a, perfRow(a, "Assumed annual electricity generation from solar PV system, kWh", "0", true, SZ));
    try rows.append(a, perfRow(a, "Expected solar PV self-consumption (PV Only)", "0", false, SZ));
    try rows.append(a, perfRow(a, "Grid electricity independence /Self-sufficiency (PV Only)", "0%", true, SZ));
    try rows.append(a, perfBand(a, "D. Estimated PV self-consumption-with EESS", SZ));
    try rows.append(a, perfRow(a, "Assumed usable capacity of electrical energy storage device, which is used for self-consumption, kWh", b.f("Battery Storage System {s}", .{q.battery_kwh}), true, SZ));
    try rows.append(a, perfRow(a, "Expected solar PV self-consumption (with EESS) Kwh", "0", false, SZ));
    try rows.append(a, perfRow(a, "Grid electricity independence /Self-sufficiency (with EESS)", "0%", true, SZ));
    try rows.append(a, perfBand(a, "E. Additional benefits from PV and EESS", SZ));
    try rows.append(a, perfRow(a, "EESS capacity NOT used for self-consumption", "0", true, SZ));
    try rows.append(a, perfRow(a, "Total energy discharged per annum approx (will degrade annually)", "1855", false, SZ));
    try rows.append(a, perfRow(a, "Additional self-consumption from EV, heat pumps, diverters (only when presnt)", "0", true, SZ));
    try b.grid(ML, &[_]f64{ lc, rc }, rows.items, .{ .border = "#c8c8c8", .sw = 0.6, .size = SZ, .pad = 5, .min_h = 26 });
    return b.page();
}

// ============================================================================
// PAGE 11 — performance notes + THE FIGURES
// ============================================================================
fn p11(a: std.mem.Allocator, q: CrgQuote, A: Assets) !P.Page {
    _ = q;
    _ = A;
    var b = B{ .a = a };
    b.y = 40;
    const notes = [_][]const u8{
        "“Important Note: The performance of solar PV systems is impossible to " ++
            "predict with certainty due to the variability in the amount of solar " ++
            "radiation (sunlight) from location to location and from year to year. " ++
            "This estimate is based upon the standard MCS procedure is given as " ++
            "guidance only for the first year of generation. It should not be " ++
            "considered as a guarantee of performance.",
        "The solar PV self-consumption has been calculated in accordance with the " ++
            "most relevant methodology for your system. There are a number of external " ++
            "factors that can have a significant effect on the amount of energy that is " ++
            "self-consumed so this figure should not be considered as a guarantee of " ++
            "the amount of energy that will be self-consumed. It does not account for " ++
            "the impact of power diverters, electric space heating, electric water " ++
            "heating or electric vehicle charging.”",
        "Where the shade factor (SF) is less than 1 Shading will be present on your " ++
            "system that will reduce its output to the factor stated. This factor was " ++
            "calculated using the MCS shading methodology and we believe that this will " ++
            "yield results within 10% of the actual energy estimate stated for most " ++
            "systems.",
        "Important Note: The energy performance and benefits of EESS is impossible " ++
            "to predict with certainty due to the numerous functions a system can be " ++
            "programmed to perform. This estimate is based upon the standard MCS " ++
            "procedure and is given as guidance only. It should not be considered as a " ++
            "guarantee of performance.",
        "Where occupancy archetype is not known (e.g. new build) then both sections " ++
            "C & D in the above table can be omitted (or marked as N/A).",
    };
    for (notes) |pp| try b.para(pp, .{ .size = 9.5, .gap_after = 8 });
    try b.heading("THE FIGURES", .{ .size = 15, .gap_before = 2, .gap_after = 8 });
    try b.para("If the system performs in line with our predictions the following " ++
        "would apply, remember, we have assumed that you are Out all day We have " ++
        "assumed you will self-consume 0% of the energy produced by your PV " ++
        "system, as determined by the method set out in MGD 003, therefore " ++
        "exporting 100%", .{ .size = 9.5, .gap_after = 10 });
    const w3 = [_]f64{ CW - 90, 45, 45 };
    const rows = [_]Row{
        .{ .cells = cs(a, &.{.{ .t = "ANNUAL BENEFITS", .al = .center, .bg = BAND_MD, .size = 9.5 }}), .widths = ws(a, &.{CW}), .h = 20 },
        .{ .cells = cs(a, &.{
            .{ .t = "Grid independence: Estimated annual electricity savings % grid independence of PV output = total x electricity tariff (p/kWh) / 100 (e.g. 22% (grid independence) of 2491 (PV output) = 548.02 x 15p (electricity tariff) /100 = £82.20", .bg = "#d9d9d9", .size = 8.3 },
            .{ .t = "0", .al = .center, .bg = "#d9d9d9" },
            .{ .t = "per\nyear", .al = .center, .bg = "#d9d9d9" },
        }) },
        .{ .cells = cs(a, &.{
            .{ .t = "\"Annual income generated from Smart Export Guarantee % export of PV output x SEG rate from Energy Provider / 100 e.g. 69% (to be exported) of 2491 (PV output)) = 1,718.79 x 5.5p (SEG rate) / 100 = £94.53\"", .bg = "#d9d9d9", .size = 8.3 },
            .{ .t = "0", .al = .center, .bg = "#d9d9d9" },
            .{ .t = "per\nyear", .al = .center, .bg = "#d9d9d9" },
        }) },
        .{ .cells = cs(a, &.{
            .{ .t = "SMART EXPORT GUARANTEE RATE", .bg = "#d9d9d9", .size = 8.3 },
            .{ .t = "£0.32", .al = .center, .bg = "#d9d9d9" },
            .{ .t = "per\nkwh", .al = .center, .bg = "#d9d9d9" },
        }), .h = 40 },
    };
    try b.grid(ML, &w3, &rows, .{ .border = "#7f7f7f", .sw = 0.7, .size = 8.3, .pad = 5 });
    return b.page();
}

// ============================================================================
// PAGE 12 — PAYBACK PERIOD + wind/snow tables
// ============================================================================
fn p12(a: std.mem.Allocator, q: CrgQuote, A: Assets) !P.Page {
    _ = A;
    var b = B{ .a = a };
    b.y = 40;
    try b.para("Note: Smart Export Guarantee rates differ between energy providers and " ++
        "can change at their discretion. Please also be aware there is no current " ++
        "set minimum number of years of eligibility for the Smart Export " ++
        "Guarantee. The amount above is per annum based on your energy provider's " ++
        "current SEG rates.", .{ .size = 9.5, .gap_after = 10 });
    try b.heading("PAYBACK PERIOD", .{ .size = 15, .gap_after = 6 });
    try b.para("HOW LONG WILL IT TAKE FOR THE SYSTEM TO PAY FOR ITSELF?", .{ .size = 10.5, .gap_after = 10 });
    const box = [_]Row{
        .{ .cells = cs(a, &.{.{ .t = "None of us can predict accurately what will happen in the future when it comes to inflation and electricity prices, so for the payback time we have assumed no increases in electricity prices. This is only a rough guide, as there may be maintenance costs to be considered.", .bg = "#d9d9d9", .size = 9.0 }}) },
        .{ .cells = cs(a, &.{.{ .t = "To calculate how long the system will take to pay for itself, we can divide the total cost you have paid for the system and divide it by the estimated benefit you will receive each year.", .bg = "#d9d9d9", .size = 9.0 }}) },
    };
    try b.grid(ML, &[_]f64{CW}, &box, .{ .border = "#bfbfbf", .sw = 0.7, .size = 9.0, .pad = 7 });
    b.gap(2);
    const half = [_]f64{ CW * 0.5, CW * 0.5 };
    const rows = [_]Row{
        .{ .cells = cs(a, &.{ .{ .t = "Total Installation cost :", .bg = "#d9d9d9" }, .{ .t = b.f("£{s}", .{q.total_price}) } }), .h = 30 },
        .{ .cells = cs(a, &.{ .{ .t = "Estimated Annual Benefit :", .bg = "#d9d9d9" }, .{ .t = b.f("£{s}", .{q.annual_saving}) } }), .h = 30 },
        .{ .cells = cs(a, &.{ .{ .t = "Payback Period (installation cost divided by estimated annual benefit) :", .bg = "#d9d9d9" }, .{ .t = b.f("{s} Years", .{q.payback_years}) } }), .h = 36 },
    };
    try b.grid(ML, &half, &rows, .{ .border = "#bfbfbf", .sw = 0.7, .size = 9.5, .pad = 7 });
    b.gap(6);
    try b.text(ML, b.y, b.f("Array Surface Area ={s} Sqm", .{q.array_sqm}), .{ .size = 10 });
    b.gap(16);
    const WV = struct { k: []const u8, v: []const u8 };
    var wind: std.ArrayListUnmanaged(Row) = .empty;
    try wind.append(a, .{ .cells = cs(a, &.{.{ .t = "MCS Wind Loading Calculation", .al = .center, .bg = BLUE_LT, .size = 10 }}), .widths = ws(a, &.{CW}), .h = 22 });
    const wind_rows = [_]WV{
        .{ .k = "Wind Zone:", .v = "1-SU" }, .{ .k = "Peak Pressure:", .v = "1,009Pa" },
        .{ .k = "Altitude Correction Factor:", .v = "NONE" }, .{ .k = "Typography Correction Factor:", .v = "NONE" },
        .{ .k = "Peak Velocity Pressure:", .v = "1009Pa" }, .{ .k = "Pressure Coefficient:", .v = "-0.5" },
        .{ .k = "Wind Pressure:", .v = "-681Pa" },
    };
    for (wind_rows) |r| try wind.append(a, .{ .cells = cs(a, &.{ .{ .t = r.k }, .{ .t = r.v } }), .h = 24 });
    try b.grid(ML, &half, wind.items, .{ .border = "#a6a6a6", .sw = 0.7, .size = 9.5, .pad = 7 });
    b.gap(4);
    var snow: std.ArrayListUnmanaged(Row) = .empty;
    try snow.append(a, .{ .cells = cs(a, &.{.{ .t = "Snow Landing Calculation", .al = .center, .bg = BLUE_LT, .size = 10 }}), .widths = ws(a, &.{CW}), .h = 22 });
    const snow_rows = [_]WV{
        .{ .k = "Snow Load:", .v = "500Pa" }, .{ .k = "Altitude Correction:", .v = "NONE" },
        .{ .k = "Pitch Adjustment:", .v = "1000" }, .{ .k = "Adjust Snow Load:", .v = "500Pa" },
    };
    for (snow_rows) |r| try snow.append(a, .{ .cells = cs(a, &.{ .{ .t = r.k }, .{ .t = r.v } }), .h = 24 });
    try b.grid(ML, &half, snow.items, .{ .border = "#a6a6a6", .sw = 0.7, .size = 9.5, .pad = 7 });
    return b.page();
}

// ============================================================================
// PAGE 13 — SUN PATH + SEG TARIFF
// ============================================================================
fn p13(a: std.mem.Allocator, q: CrgQuote, A: Assets) !P.Page {
    _ = q;
    var b = B{ .a = a };
    b.y = 30;
    const iw: f64 = 430;
    const ih = iw * (226.0 / 577.0);
    try b.image(A.sunpath, (PW - iw) / 2, b.y, iw, ih);
    b.y += ih + 20;
    try b.text(ML, b.y, "Sun Path Chart - 0%", .{ .size = 11 });
    b.gap(14);
    try b.para("This shade assessment has been undertaken using the standard MCS " ++
        "procedure – it is estimated that this method will yield results within " ++
        "10% of the actual annual yield or most systems. Where there is an " ++
        "obvious clear horizon and no near or far shading, the assessment of SF " ++
        "has been omitted and an SF value of 1 used.", .{ .size = 10, .gap_after = 12 });
    try b.heading("SMART EXPORT GUARANTEE (SEG) TARIFF", .{ .size = 14, .gap_after = 10 });
    const paras = [_][]const u8{
        "The Smart Export Guarantee is a support mechanism designed to ensure " ++
            "small-scale generators are paid for the renewable electricity they export " ++
            "to the grid. It has been in place since 1st January 2020.",
        "Under the scheme, all licensed energy companies with 150,000 or more " ++
            "customers must provide at least one SEG tariff. Smaller suppliers can offer " ++
            "a tariff if they want to on a voluntary basis. All suppliers can also " ++
            "choose to offer other means of making payments for exported electricity, " ++
            "separate to the SEG arrangements.",
        "The technology and installer used by householders must be certified under " ++
            "the Microgeneration Certification Scheme (MCS) or equivalent and the solar " ++
            "PV system must be grid connected. Energy suppliers may ask for the MCS " ++
            "certificate to prove the installation meets the standard which we will " ++
            "provide for you.",
        "You also need a registered Smart Meter that records your exported " ++
            "electricity, even if you’re not signing up to a smart tariff.",
        "SEG payments are not linked to other financial support around renewable " ++
            "energy installations. This means that, if eligible, you could combine SEG " ++
            "payments with other financial support. In Scotland, for example you could " ++
            "combine SEG payments with the Home Energy Scotland loan.",
        "You will not be able to receive SEG from more than one supplier.",
        "Octopus Energy offer Outgoing Octopus which is described as a smart export " ++
            "tariff and their successor to the feed-in tariff (FIT). Perfect for homes " ++
            "with solar panels, battery storage, or any other way of sharing energy back " ++
            "to the grid. Outgoing Octopus comes in two flavours – Fixed or Agile. " ++
            "Outgoing Fixed guarantees 5.5p per kWh for every unit you export. Outgoing " ++
            "Agile matches your half-hourly prices with day-ahead wholesale rates, " ++
            "helping you make the most of the energy you generate.",
    };
    for (paras) |pp| try b.para(pp, .{ .size = 9.5, .gap_after = 7 });
    try b.link("https://octopus.energy/outgoing/", 10.5, 6);
    try b.para("Here is a list of energy suppliers who provide SEG. Some are mandated " ++
        "and some have chosen to offer this.", .{ .size = 9.5, .gap_after = 2 });
    try b.link("https://www.ofgem.gov.uk/publications/seg-supplier-list", 10.5, 6);
    try b.para("The Energy Saving Trust provide a Solar Energy Calculator to provide " ++
        "estimates for fuel bill saving and financial payments you may receive by " ++
        "installing a solar PV system.", .{ .size = 9.5, .gap_after = 2 });
    return b.page();
}

// ============================================================================
// PAGE 14
// ============================================================================
fn p14(a: std.mem.Allocator, q: CrgQuote, A: Assets) !P.Page {
    _ = q;
    _ = A;
    var b = B{ .a = a };
    b.y = 30;
    try b.link("https://www.pvfitcalculator.energysavingtrust.org.uk/", 10.5, 6);
    try b.heading("SEG and ELECTRICAL ENERGY STORAGE (Battery Storage)", .{ .size = 13, .gap_after = 10 });
    const seg = [_][]const u8{
        "If you’ve included an energy storage system in your renewables " ++
            "installation, you can still apply for SEG, but there might be a few rules, " ++
            "depending on your SEG contract. Your battery could store electricity from " ++
            "the grid (known as brown electricity) before exporting it later on.",
        "Energy suppliers do not have to pay you for brown electricity exported to " ++
            "the grid but they may choose to do so.",
        "Some suppliers may only pay the SEG for green electricity, ie the " ++
            "electricity your low-carbon system generates itself. If this is the case, " ++
            "the supplier may ask you to show how you separate the green electricity you " ++
            "generate from any imported brown electricity.",
    };
    for (seg) |pp| try b.para(pp, .{ .size = 10, .gap_after = 8 });
    try b.heading("PITCHED ROOF WORK", .{ .size = 13, .gap_after = 10 });
    try b.para("On all roof types there should not be a need to drill tiles.\n" ++
        "On slate roofs it is sometimes necessary to cut a portion of the slate " ++
        "out or remove a slate so that the surrounding slates sit back down, the " ++
        "area that would be removed would maintain its waterproof integrity " ++
        "through the use of lead flashing kits.\n" ++
        "In the case of tiles a small channel is cut out on the underside to " ++
        "allow the tile to sit flush with the roof again, the integrity of the " ++
        "tile is maintained.\n" ++
        "The mounting anchors are fixed to the roof joists using appropriate " ++
        "fixings and the tile or slate sits back in place or where necessary " ++
        "flashing kit used.\n" ++
        "Whenever any roof covering is modified the water proof integrity is " ++
        "always maintained in the most appropriate way possible, with little or " ++
        "no visual impact.\n" ++
        "Decra roofing installation, Metasole+ brackets or Solar limpet fixings " ++
        "will be used drilled direct into roofing material through the tiling " ++
        "these are an MCS accredited fixing", .{ .size = 10, .gap_after = 6 });
    try b.para("The link has more information on the product", .{ .size = 10, .gap_after = 2 });
    try b.link("https://www.renusol.com/en/solar-panel-mounting/metal-roof/ms-msp/", 10.5, 6);
    try b.para("It is part of MCS (Micro Generation Certification Scheme) rules and " ++
        "regulations that the roof offers the same or better waterproofing once " ++
        "the contractor has left site.", .{ .size = 10, .gap_after = 8 });
    try b.para("We should be able to demonstrate that the installation of the modules " ++
        "has not affected the fire performance of the roof. This can be " ++
        "demonstrated by mounting the panels above an existing non-combustible " ++
        "roof covering (pitched roofs).", .{ .size = 10, .gap_after = 10 });
    try b.heading("PLANNING CONSENT, PERMISSIONS AND APPROVAL", .{ .size = 13, .gap_after = 10 });
    const plan = [_][]const u8{
        "We shall ensure your building is assessed by a competent professional " ++
            "experienced in solar photovoltaic systems to ensure that it is suitable for " ++
            "the installation and, by undertaking the proposed works, the building’s " ++
            "compliance with the Building Regulations (in particular those relating to " ++
            "energy efficiency) is not compromised. Where work is undertaken that is " ++
            "notifiable under the Building Regulations we shall make this clear to you " ++
            "and who shall be responsible for this notification.",
        "We are registered with a Competent Persons Scheme (CPS) and able to " ++
            "self-certify our work.",
        "It is not a requirement to contact your local planning authority and advise " ++
            "them of your intention to install a solar electrical system. Legislation " ++
            "changed in April of 2008 so that now, in most cases the installation will " ++
            "be considered a ‘permitted development’; however in some cases planning " ++
            "permission may be required, usually in a conservation area or on a listed " ++
            "building. It is advisable if you are in any doubt for you to just check and " ++
            "clear this before your installation.",
    };
    for (plan) |pp| try b.para(pp, .{ .size = 10, .gap_after = 8 });
    return b.page();
}

// ============================================================================
// PAGE 15
// ============================================================================
fn p15(a: std.mem.Allocator, q: CrgQuote, A: Assets) !P.Page {
    _ = q;
    _ = A;
    var b = B{ .a = a };
    b.y = 30;
    const top = [_][]const u8{
        "On a pitched roof the solar PV array must not protrude more than 200 mm " ++
            "above the roof line.",
        "On a flat roof the highest part of the solar PV array must be less than 1 " ++
            "meter higher than the highest part of the roof (excluding any chimney).",
        "The PV array must be sited more than 200mm away from the external edges of " ++
            "the roof and as far as practicable the PV array should be sited to minimise " ++
            "the effect on the external appearance of the building.",
    };
    for (top) |pp| try b.para(pp, .{ .size = 10, .gap_after = 8 });
    try b.heading("STRUCTURAL STABILITY", .{ .size = 13, .gap_after = 10 });
    const ss = [_][]const u8{
        "Most roofs are more than adequate to cope with a solar array being mounted " ++
            "as the weight of the load is spread across the large surface area. A wind " ++
            "and snow loading calculation has been provided within this quotation.",
        "PV Systems should not adversely affect the weather tightness or structural " ++
            "integrity of the building to which they are fitted. The system should be " ++
            "designed and installed to ensure this is maintained for the life of the " ++
            "system.",
        "IMPORTANT: Where the existing roof covering is under warranty, then the roof " ++
            "warranty provider should be consulted to establish if warranties will be " ++
            "invalidated by the installation.",
        "Where an existing warranty may be invalidated by the proposed installation, " ++
            "we shall notify the customer in writing and obtain explicit written " ++
            "agreement from the customer if the installation is to proceed.",
    };
    for (ss) |pp| try b.para(pp, .{ .size = 10, .gap_after = 8 });
    try b.heading("NOTIFICATION TO THE DISTRIBUTION NETWORK OPERATOR (DNO)", .{ .size = 12.5, .gap_after = 10 });
    try b.para("We will carry out the necessary liaison regarding connection to the " ++
        "local grid, and completion of the G98 or G99 paperwork.", .{ .size = 10, .gap_after = 10 });
    try b.heading("SAFETY AND DURABILITY", .{ .size = 13, .gap_after = 10 });
    const sd = [_][]const u8{
        "Suitable and sufficient risk assessments shall be conducted before any work " ++
            "on site commences and an installation method statement will be carried out " ++
            "and issued prior to the commencement of any work and our installers will " ++
            "have carried out relevant health and safety training courses in line with " ++
            "the type of work.",
        "As an MCS contractor we shall be able to demonstrate that the installation " ++
            "of the modules has not affected the fire performance of the roof such as " ++
            "mounting above an existing non-combustible roof covering (pitched roofs).",
    };
    for (sd) |pp| try b.para(pp, .{ .size = 10, .gap_after = 8 });
    try b.heading("INSURANCE", .{ .size = 13, .gap_after = 10 });
    try b.para("Our advice with reference to your building insurance is that you do need " ++
        "to inform your insurers, however most insurers will add solar panels to " ++
        "your policy at no additional cost (It will be down to the insurance " ++
        "company as to how they view this).", .{ .size = 10, .gap_after = 10 });
    try b.heading("MAINS POWER FAILURE", .{ .size = 13, .gap_after = 10 });
    try b.para("If there is a power cut or the mains power is switched off deliberately " ++
        "the solar electric system will automatically disconnect from the main " ++
        "supply. This means that an engineer working on the electrical system " ++
        "will be in no danger. When the power is switched back on the system will " ++
        "automatically connect.", .{ .size = 10, .gap_after = 8 });
    return b.page();
}

// ============================================================================
// PAGE 16
// ============================================================================
fn p16(a: std.mem.Allocator, q: CrgQuote, A: Assets) !P.Page {
    _ = q;
    _ = A;
    var b = B{ .a = a };
    try b.heading("INSTALLATION", .{ .size = 13, .gap_before = 0, .gap_after = 10 });
    b.y = @max(b.y, 46);
    const inst = [_][]const u8{
        "The Installation will be carried out to comply with all applicable " ++
            "legislation and directives and the necessary standards including MCS " ++
            "installation requirements, Electrical Safety, Quality and continuity " ++
            "Regulations 2002 and the Consumer Code.",
        "Once the installation is complete you will be issued with a handover file " ++
            "consisting of all test documentation, user instructions, circuit diagrams, " ++
            "Energy Performance Certificate, warranties and contact details.",
        "Where work is undertaken that is notifiable under the Building Regulations " ++
            "it shall be made clear to the customer who shall be responsible for the " ++
            "notification.",
        "Where responsible for notification under the Building Regulations, the MCS " ++
            "Contractor shall ensure notification has been completed prior to handing " ++
            "over the installation.",
        "Note: Where notification under the Building Regulations is to be undertaken " ++
            "by others (e.g. the developer of a new-build project) then it is " ++
            "permissible for the MCS Contractor to handover the installation immediately " ++
            "following commissioning.",
        "Self-certification, in lieu of building control approval, is only permitted " ++
            "where installation and commissioning is undertaken by an entity registered " ++
            "with a Competent Persons Scheme (CPS) approved by the relevant government " ++
            "department for the scope of work being undertaken.",
    };
    for (inst) |pp| try b.para(pp, .{ .size = 10, .gap_after = 8 });
    try b.heading("ADDITIONAL MEASURES THAT MAY BE BENEFICIAL TO THE PERFORMANCE AND " ++
        "DURABILITY OF THE SYSTEM", .{ .size = 12.5, .gap_after = 10 });
    const meas = [_][]const u8{
        "Cleaning of your Solar Panels. The first thing you want to do is to check " ++
            "with your solar panel manufacturer. They might have specific " ++
            "recommendations for cleaning. There are solar panel cleaning companies " ++
            "available and so check your local area for details.",
        "Solar panels can become incredibly hot in sunshine. Either clean your solar " ++
            "panels in the morning/afternoon, or pick a relatively cool day. Warm water " ++
            "and soap – no other special equipment is needed. Clean the surface of the " ++
            "solar panel with a soft cloth or sponge. You do not have to clean the wiring " ++
            "underneath.",
        "The installation of solar panels can provide shelter for nesting birds with " ++
            "pigeons nesting under solar panels and so you may want to consider specific " ++
            "bird-proofing measures designed to solve this problem which are available.",
        "Take care to keep clean, as airborne dust particles, sticky tree and plant " ++
            "sap, lichen, soot and bird droppings are just a few of the things that can " ++
            "contribute to a build-up of dirt on your panels. Accumulation creates " ++
            "shading and will prevent daylight reaching the cells of the panels.",
        "The solar panels we install for you will be positioned to gain the maximum " ++
            "amount of sunlight. However, you should be aware that the future growth of " ++
            "trees, large shrubs and their spreading foliage could cause the panels to " ++
            "be shaded, thereby reducing the performance of the system.",
        "You should also consider how any future building work that takes place on " ++
            "your property would affect the shading of the solar panels.",
    };
    for (meas) |pp| try b.para(pp, .{ .size = 10, .gap_after = 8 });
    try b.heading("ENVIRONMENT", .{ .size = 13, .color = "#000000", .gap_after = 10 });
    try b.para("We recycle most of the waste materials from your installation. We also " ++
        "endeavour to keep our travelling to a minimum by carrying out the works " ++
        "over as few journeys as possible.", .{ .size = 10, .gap_after = 8 });
    return b.page();
}

// ============================================================================
// PAGE 17
// ============================================================================
fn p17(a: std.mem.Allocator, q: CrgQuote, A: Assets) !P.Page {
    _ = q;
    _ = A;
    var b = B{ .a = a };
    try b.heading("WARRANTIES", .{ .size = 13, .gap_before = 0, .gap_after = 10 });
    b.y = @max(b.y, 46);
    const warr = [_][]const u8{
        "Your equipment will be guaranteed by its manufacturer, but you should " ++
            "contact us in the first instance if anything appears to be operating " ++
            "incorrectly.",
        "In addition to the product guarantees, our work will be covered by a " ++
            "workmanship warranty. This workmanship warranty will be transferable to the " ++
            "new legal owner of the property if it is sold during the warranty period.",
        "As signatories to a Consumer Code we are required to ensure that should we " ++
            "cease trading, due to receivership, administration or bankruptcy, that the " ++
            "workmanship warranty that we have in place for your installation will still " ++
            "be honoured.",
        "When you confirm the order and we have received any requested deposit, we " ++
            "will register your name, address and the total value of the contract, " ++
            "within two working days on the Job Registration System.",
        "A leaflet explaining the scheme is enclosed. If you are not content for us " ++
            "to register your details in this way, please let us know. The insurance " ++
            "provider will send the policy documents direct to you. This policy will be " ++
            "at no additional cost to you.",
        "Should we cause any damage, either to installed equipment or to your " ++
            "property we will rectify such damage without charge to you.",
    };
    for (warr) |pp| try b.para(pp, .{ .size = 10, .gap_after = 8 });
    try b.heading("HIES CONSUMER CODE", .{ .size = 13, .gap_after = 10 });
    try b.para("We are signatories to the HIES Consumer Code, membership number and the " ++
        "membership number is displayed on the bottom of our letterhead. This " ++
        "document is prepared in accordance with the HIES Consumer Code.", .{ .size = 10, .gap_after = 6 });
    try b.para("A leaflet describing the HIES Consumer Code is at the link below.", .{ .size = 10, .gap_after = 2 });
    try b.link("https://www.hiesscheme.org.uk/regulation/hies-scheme-rules-code-of-practice/", 10.5, 6);
    try b.heading("COMPLAINTS", .{ .size = 13, .gap_after = 10 });
    try b.para("We hope you won't have any reason to complain about any aspect of our " ++
        "service. But if you do, please contact us.", .{ .size = 10, .gap_after = 6 });
    try b.para("You may contact us by telephone, letter or e mail, and you will find our " ++
        "contact details on this quotation. We will acknowledge and attempt to " ++
        "resolve your complaint promptly. Where we need to investigate the " ++
        "complaint, we will report to you our progress on any investigation " ++
        "within seven working days.", .{ .size = 10, .gap_after = 6 });
    try b.para("If we are unable resolve your complaint, you may be able to complain to " ++
        "HIES. You can read about this here:", .{ .size = 10, .gap_after = 2 });
    try b.link("https://www.hiesscheme.org.uk/what-we-do/alternative-dispute-resolution/=how-to-complain-and-who-to-complain-to", 10.5, 6);
    try b.para("VAT - This is charged at the reduced rate of 0% on the installation of " ++
        "solar panels in, or in the curtilage of residential accommodation.", .{ .size = 10, .gap_after = 6 });
    try b.para("DELIVERY - Approximately 2 to 3 weeks from order, subject to " ++
        "availability of components. To be confirmed at the time of order.", .{ .size = 10, .gap_after = 6 });
    try b.para("PRIVACY - Using Your Personal Information", .{ .size = 10, .gap_after = 4 });
    try b.bullets(&.{"We will use the personal information you provide to us in accordance " ++
        "with the Data Protection Act 2018 ,General Data Protection " ++
        "Regulations and more specifically to:"}, .{ .size = 10, .gap_after = 2 });
    try b.bullets(&.{
        "Supply the Goods and Services to you",
        "Process any payments that you make for the Goods and Services, " ++
            "including if necessary conducting credit reference check;",
    }, .{ .size = 10, .x = ML + 24, .gap_after = 6 });
    return b.page();
}

// ============================================================================
// PAGE 18
// ============================================================================
fn p18(a: std.mem.Allocator, q: CrgQuote, A: Assets) !P.Page {
    _ = q;
    var b = B{ .a = a };
    b.y = 30;
    try b.bullets(&.{
        "Register your installation with any relevant bodies, including your " ++
            "deposit protection and insurance backed guarantee and any competent " ++
            "persons scheme;",
        "Address any concerns or complaints that you have about the Goods and " ++
            "Services, including liaison with HIES and QA Scheme Support Services " ++
            "Limited or The Dispute Resolution Ombudsman where the law requires us " ++
            "to share.",
    }, .{ .size = 10, .x = ML + 24, .gap_after = 8 });
    try b.para("Where you have indicated that you would like to receive further " ++
        "information on offers, products and services, you can change this at any " ++
        "point by contacting us.", .{ .size = 10, .gap_after = 10 });
    try b.heading("CANCELLATION RIGHTS", .{ .size = 13, .gap_after = 10 });
    try b.para("Your cancellation rights will vary depending on whether the contract you " ++
        "agree with us is considered to have been agreed on or away from trade " ++
        "premises.", .{ .size = 10, .gap_after = 6 });
    try b.para("For contracts considered to have been agreed on trade premises you will " ++
        "be given a fourteen day cancellation period from the day that the " ++
        "contract was signed.\n" ++
        "For contracts considered to have been agreed away from trade premises, " ++
        "your cancellation rights are as set out in the Consumer Contracts " ++
        "(Information, Cancellation and Additional Charges) Regulations. These " ++
        "regulations give you the right to cancel from the time that the contract " ++
        "is signed until fourteen days after the delivery of the last of the " ++
        "goods.", .{ .size = 10, .gap_after = 10 });
    try b.heading("BATTERY STORAGE (EESS)", .{ .size = 13, .gap_after = 10 });
    try b.para("The system is a off-the-shelf Packaged EESS. The battery is capable of " ++
        "charging from, storing and subsequently discharging electrical energy " ++
        "from a domestic solar PV system. and is to be installed within the same " ++
        "domestic electrical system as the solar PV system and loads i.e. on the " ++
        "domestic side of the utility meter. The electrical energy storage is " ++
        "operated for provision of increasing self-consumption. This will be " ++
        "installed as new and not been previously used.", .{ .size = 10, .gap_after = 10 });
    const iw: f64 = 200;
    const ih = iw * (380.0 / 276.0);
    try b.image(A.battery, (PW - iw) / 2, b.y, iw, ih);
    b.y += ih + 12;
    try b.para("The battery type is Lithium Iron Phosphate cells resulting in safe and " ++
        "reliable battery and special precautions should be taken such as " ++
        "ventilation and fire safety.", .{ .size = 10, .gap_after = 6 });
    return b.page();
}

// ============================================================================
// PAGE 19
// ============================================================================
fn p19(a: std.mem.Allocator, q: CrgQuote, A: Assets) !P.Page {
    _ = A;
    var b = B{ .a = a };
    b.y = 30;
    try b.bullets(&.{ "The system size is", b.f("Battery Storage System {s}", .{q.battery_kwh}) }, .{ .size = 10, .gap_after = 2 });
    try b.para("Kwh and if the battery developes a problem you must inform the " ++
        "manufacturer immediately see data sheet for all specifications.", .{ .size = 10, .gap_after = 8 });
    try b.para("The battery will be situated in the {%loc_battery%}", .{ .size = 10, .gap_after = 8 });
    try b.para("The useable storage capacity in kilowatt-hours (kWh) accounting for the " ++
        "maximum allowable depth of discharge.", .{ .size = 10, .gap_after = 8 });
    try b.para("Battery Modules can be stacked up to three high and a Power Module that " ++
        "controls them is placed on top. When connected to a compatible inverter " ++
        "this gives the following energy storage capacity and continuous power " ++
        "output:", .{ .size = 10, .gap_after = 6 });
    try b.bullets(&.{
        "Battery Module = 5 kilowatt-hour of energy storage and 2.5 kilowatts of power output.",
        "Battery Modules = 10 kilowatt-hours of energy storage and 5 kilowatts of power output.",
        "Battery Modules = 15 kilowatt-hours of energy storage and 5 kilowatts of power output.",
    }, .{ .size = 10, .gap_after = 10 });
    const paras = [_][]const u8{
        "Note: if the inverter is under 5 kilowatts the power output will be limited " ++
            "by the inverter’s capacity.",
        "If you want more than 15 kilowatt-hours of storage, two Luna2000s can be " ++
            "installed in parallel to provide up to 30 kilowatt-hours of storage. More " ++
            "modules won’t improve the power output beyond 5 kilowatts:",
        "Each 5 kilowatt-hour Battery Module operates separately from the others. " ++
            "This means if a fault develops in one module the others can still be used " ++
            "until the defective unit is repaired or replaced.",
        "The independent operation makes it easy to add an extra module to expand " ++
            "storage capacity or compensate for capacity deteriorating over time. As each " ++
            "battery module is covered by its own warranty, adding a new one to an " ++
            "existing system won’t create a warranty issue.",
        "The Battery is water-resistant and can be installed outdoors. Its IP rating " ++
            "— or Ingress Protection rating — is IP66. This means it’s dust-tight and " ++
            "able to resist jets of water from all directions. This means if your idiot " ++
            "cousin decides to hose down your home battery, it should be fine.",
        "Note: It would be helpful for consumers if the useable storage capacity " ++
            "could be expressed in terms of the time that particular devices could be " ++
            "run. Use the formula (10 x battery capacity in amp hours) divided by " ++
            "(appliance load in watts)",
        "If capable (or not) of running in Island mode (during loss of grid power) " ++
            "and limitations in terms of maximum load in kW. Battery fault on module auto " ++
            "isolates to keep system safe.",
        "Warranties applying to the system and its storage capacity (degradation, " ++
            "number of cycles, energy throughput etc.)",
        "How the EESS indicates its current usable capacity or state of health (thus " ++
            "indicating if it is ending its life or the storage capacity is below the " ++
            "warranted capacity).",
        "End of life, recycling, arrangements should be carried out in accordance " ++
            "with the Waste Electrical Electronic Equipment (WEE, 2012/19/EU) and the " ++
            "Battery Directive (2006/66/EC).",
        "Where the EES is to be remotely controlled by third parties, the terms of " ++
            "that arrangement including the terms applying should the consumer wish to " ++
            "terminate the arrangement and assume full control of their system. Penalties " ++
            "for early termination shall be clearly stated.",
        "If the EESS can be controlled to respond to time of use electricity tariffs " ++
            "and, if so, how it shall be highlighted whether this is a manual process " ++
            "(manually setting charge and discharge times) or can be automated (such that " ++
            "charge and discharge times change automatically when tariffs change).",
        "The EESS is intended to increase the self-consumption of Solar PV and " ++
            "therefore is within the scope of MGD 003.",
    };
    for (paras) |pp| try b.para(pp, .{ .size = 9.5, .gap_after = 6 });
    try b.bullets(&.{
        "The EESS is serving a domestic building",
        "The annual electricity consumption is between 1500 kWh and 6000 kWh " ++
            "(excluding consumption attributable to electric vehicles and " ++
            "electrified space heating).",
    }, .{ .size = 9.5, .gap_after = 4 });
    return b.page();
}

// ============================================================================
// PAGE 20
// ============================================================================
fn p20(a: std.mem.Allocator, q: CrgQuote, A: Assets) !P.Page {
    _ = A;
    var b = B{ .a = a };
    b.y = 30;
    try b.bullets(&.{
        "The estimated annual generation of the solar PV system (calculated " ++
            "in accordance with MIS 3002) is between 1500 kWh and 6000 kWh",
        "There are no other forms of local electricity generation serving the " ++
            "building (other than the solar PV)",
    }, .{ .size = 10, .gap_after = 10 });
    try b.para("Following the procedure outlined in MGD 003 Sections C and D have been " ++
        "completed.", .{ .size = 10, .gap_after = 10 });
    try b.para("If you wish us to begin work within the cancellation period you must give " ++
        "us express permission, in writing, to do so.", .{ .size = 10, .gap_after = 8 });
    try b.para("You can find full details of your cancellation rights within the contract " ++
        "we will ask you to sign and also on the Cancellation Form we will issue " ++
        "to you.", .{ .size = 10, .gap_after = 10 });
    try b.heading("CONTRACT TERMS", .{ .size = 13, .gap_after = 10 });
    try b.para("We have enclosed a copy of our contract with this quotation. Please read " ++
        "this carefully, and as always, please contact us if you require further " ++
        "clarification.", .{ .size = 10, .gap_after = 10 });
    try b.text(ML, b.y, "Customer Declaration:", .{ .size = 11 });
    b.gap(16);
    try b.para("I confirm that I wish to continue with the installation process with " ++
        "this quotation, and to the costs set out in this quote. I confirm that I " ++
        "have obtained any planning permission for the proposed works (if " ++
        "applicable) and that there are no restrictions in relation to my property " ++
        "being in an area of outstanding natural beauty or conservation area. I " ++
        "would like to proceed with the installation at my property.", .{ .size = 10, .gap_after = 12 });
    const decl = [_]Row{
        .{ .cells = cs(a, &.{ .{ .t = "Name:", .al = .center, .bg = "#d9d9d9" }, .{ .t = q.client } }), .h = 30 },
        .{ .cells = cs(a, &.{ .{ .t = "Signature:", .al = .center, .bg = "#d9d9d9" }, .{ .t = "" } }), .h = 30 },
        .{ .cells = cs(a, &.{ .{ .t = "Date:", .al = .center, .bg = "#d9d9d9" }, .{ .t = "" } }), .h = 30 },
    };
    try b.grid(ML, &[_]f64{ CW * 0.4, CW * 0.6 }, &decl, .{ .border = "#7f7f7f", .sw = 0.7, .size = 10, .pad = 7 });
    b.gap(6);
    try b.text(ML, b.y, "The next steps", .{ .size = 10.5 });
    b.gap(13);
    try b.para("Below are the steps both of us will take to give you a complete solar " ++
        "system under your control.", .{ .size = 10, .gap_after = 8 });
    try b.para("Check the quotation ensure everything suits your needs and you are happy " ++
        "with the costings", .{ .size = 10, .gap_after = 12 });
    try b.text(ML, b.y, "Sign the attached agreement and return to us with your deposit of 15%", .{ .size = 10 });
    try b.text(PW - MR, b.y, b.f("£{s}", .{q.deposit}), .{ .size = 10, .al = .right });
    b.gap(20);
    try b.text(ML, b.y, "Once we have an install date we will contact you and take the second payment of 40%", .{ .size = 10 });
    try b.text(PW - MR, b.y, b.f("£{s}", .{q.stage}), .{ .size = 10, .al = .right });
    b.gap(18);
    try b.para("Day of installation; Teams arrive and brief you on the plan then install " ++
        "and commission your system, install team will then demonstrate and answer " ++
        "any questions you may have on your system. Final payment of the " ++
        "outstanding balance is due at this point.", .{ .size = 10, .gap_after = 8 });
    try b.para("Within 14 days of install post installation pack warranties, product " ++
        "information and post install support certification delivered to you.", .{ .size = 10, .gap_after = 8 });
    try b.text(ML, b.y, "Your Surveyor was: -", .{ .size = 10 });
    b.gap(24);
    try b.text(PW / 2, b.y, "Many thanks for your time and for your interest in our " ++
        "products.", .{ .size = 13, .color = GREEN, .al = .center });
    return b.page();
}

// ---- assembly + entry points -----------------------------------------------
pub fn generateCrgSolarReport(alloc: std.mem.Allocator, q: CrgQuote) ![]const u8 {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    const A = try buildAssets(a);
    var pages: [20]P.Page = undefined;
    pages[0] = try p01(a, q, A);
    pages[1] = try p02(a, q, A);
    pages[2] = try p03(a, q, A);
    pages[3] = try p04(a, q, A);
    pages[4] = try p05(a, q, A);
    pages[5] = try p06(a, q, A);
    pages[6] = try p07(a, q, A);
    pages[7] = try p08(a, q, A);
    pages[8] = try p09(a, q, A);
    pages[9] = try p10(a, q, A);
    pages[10] = try p11(a, q, A);
    pages[11] = try p12(a, q, A);
    pages[12] = try p13(a, q, A);
    pages[13] = try p14(a, q, A);
    pages[14] = try p15(a, q, A);
    pages[15] = try p16(a, q, A);
    pages[16] = try p17(a, q, A);
    pages[17] = try p18(a, q, A);
    pages[18] = try p19(a, q, A);
    pages[19] = try p20(a, q, A);

    const data = P.PresentationData{
        .page_size = .{ .width = @floatCast(PW), .height = @floatCast(PH) },
        .pages = &pages,
    };
    // Render with the arena allocator; the PDF bytes land in the arena, so copy
    // them to the caller's allocator before the arena is freed. We deliberately
    // do NOT call renderer.deinit() (it frees data assuming JSON-parser
    // ownership); the arena owns everything and frees it wholesale.
    var renderer = P.PresentationRenderer.init(a, data);
    const pdf = try renderer.render();
    return alloc.dupe(u8, pdf);
}

pub fn generateCrgSolarReportFromJson(alloc: std.mem.Allocator, json_str: []const u8) ![]const u8 {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const q = try std.json.parseFromSliceLeaky(CrgQuote, arena.allocator(), json_str, .{ .ignore_unknown_fields = true });
    return generateCrgSolarReport(alloc, q);
}
