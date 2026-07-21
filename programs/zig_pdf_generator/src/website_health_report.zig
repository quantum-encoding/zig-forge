//! Website Health & Compliance Audit report — a data-driven, **paginating** PDF
//! generator for baton-audit's `SiteHealthReport` contract (see baton-audit
//! src/types.ts). Takes the report JSON and produces a QE-branded PDF:
//! cover → executive summary → scorecard → critical issues → per-category
//! detail → prioritised fix list → methodology.
//!
//! Unlike the fixed 20-page CRG solar report, this one FLOWS: content is laid
//! out top-to-bottom and breaks to a new page automatically, so the page count
//! scales with the number of findings. A running header + "Page N of M" footer
//! are stamped on every content page.
//!
//! Entry points:
//!   generateWebsiteHealthReport(alloc, report) ![]u8
//!   generateWebsiteHealthReportFromJson(alloc, json) ![]u8
//! CLI:  pdf-gen --health-report <report.json> <out.pdf>
//! WASM: zigpdf_generate_health_report

const std = @import("std");
const presentation = @import("presentation.zig");
const P = presentation;
const Align = P.TextAlign;

// ---- A4 canvas -------------------------------------------------------------
const PW: f64 = 595.28;
const PH: f64 = 841.89;
const ML: f64 = 50.0;
const MR: f64 = 50.0;
const CW: f64 = PW - ML - MR;
const CONTENT_TOP: f64 = 74.0;
const CONTENT_BOTTOM: f64 = 792.0;

// ---- palette (QE brand) ----------------------------------------------------
const NAVY = "#111827"; // headings / dark band
const INK = "#1f2937"; // body
const GREY = "#6b7280"; // secondary
const LGREY = "#9ca3af";
const CYAN = "#0891b2"; // brand accent
const CYAN_BRIGHT = "#23d8f4";
const CREAM = "#e8eef0";
const CARD_BG = "#f9fafb";
const TRACK = "#e5e7eb";
const RULE = "#d1d5db";
const WHITE = "#ffffff";

const RED = "#dc2626";
const AMBER = "#f59e0b";
const BLUE = "#2563eb";
const GREEN = "#16a34a";
const LIME = "#65a30d";
const ORANGE = "#ea580c";

fn gradeColor(g: []const u8) []const u8 {
    if (g.len == 0) return RED;
    return switch (g[0]) {
        'A' => GREEN,
        'B' => LIME,
        'C' => AMBER,
        'D' => ORANGE,
        else => RED,
    };
}
fn gradeWord(g: []const u8) []const u8 {
    if (g.len == 0) return "Critical";
    return switch (g[0]) {
        'A' => "Excellent",
        'B' => "Good",
        'C' => "Needs work",
        'D' => "Poor",
        else => "Critical",
    };
}
fn scoreColor(s: f64) []const u8 {
    if (s >= 90) return GREEN;
    if (s >= 80) return LIME;
    if (s >= 70) return AMBER;
    if (s >= 55) return ORANGE;
    return RED;
}
fn sevColor(sev: []const u8) []const u8 {
    if (std.mem.eql(u8, sev, "critical")) return RED;
    if (std.mem.eql(u8, sev, "warning")) return AMBER;
    if (std.mem.eql(u8, sev, "pass")) return GREEN;
    return BLUE; // info
}
fn sevRank(sev: []const u8) u8 {
    if (std.mem.eql(u8, sev, "critical")) return 0;
    if (std.mem.eql(u8, sev, "warning")) return 1;
    if (std.mem.eql(u8, sev, "info")) return 2;
    return 3; // pass
}
// Core Web Vitals rating → colour (null / unknown = grey, used for "—" cells).
fn ratingColor(r: ?[]const u8) []const u8 {
    if (r) |rr| {
        if (std.mem.eql(u8, rr, "good")) return GREEN;
        if (std.mem.eql(u8, rr, "needs-improvement")) return AMBER;
        if (std.mem.eql(u8, rr, "poor")) return RED;
    }
    return LGREY;
}
fn srcLabel(s: ?[]const u8) []const u8 {
    if (s) |v| {
        if (std.mem.eql(u8, v, "psi")) return "PageSpeed Insights";
        if (std.mem.eql(u8, v, "local")) return "Lighthouse (local)";
    }
    return "Lighthouse";
}
fn stratLabel(s: ?[]const u8) []const u8 {
    if (s) |v| if (std.mem.eql(u8, v, "desktop")) return "desktop";
    return "mobile";
}
fn scopeLabel(s: ?[]const u8) []const u8 {
    if (s) |v| if (std.mem.eql(u8, v, "origin")) return "origin";
    return "url";
}
fn ffLabel(s: []const u8) []const u8 {
    if (std.mem.eql(u8, s, "desktop")) return "Desktop";
    return "Mobile";
}

// ---- Helvetica AFM widths (ASCII 32..126) ----------------------------------
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
        0x00A3 => 556, 0x2013 => 556, 0x2014 => 1000,
        0x2018, 0x2019 => if (bold) @as(u16, 238) else 191,
        0x201C, 0x201D => if (bold) @as(u16, 474) else 333,
        0x00B0 => 400, 0x2022 => 350, 0x2192 => 1000,
        else => 556,
    };
}
fn textWidth(s: []const u8, size: f64, bold: bool) f64 {
    var total: u64 = 0;
    var it = std.unicode.Utf8View.initUnchecked(s).iterator();
    while (it.nextCodepoint()) |cp| total += glyphW(cp, bold);
    return @as(f64, @floatFromInt(total)) * size / 1000.0;
}
fn wrap(a: std.mem.Allocator, s: []const u8, size: f64, maxw: f64, bold: bool) ![]const []const u8 {
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    var seg_it = std.mem.splitScalar(u8, s, '\n');
    while (seg_it.next()) |seg| {
        if (seg.len == 0) {
            try out.append(a, "");
            continue;
        }
        var line_start: usize = 0;
        var line_end: usize = 0;
        var have = false;
        var ws: usize = 0;
        while (ws <= seg.len) {
            var we = ws;
            while (we < seg.len and seg[we] != ' ') we += 1;
            if (!have) {
                line_start = ws;
                line_end = we;
                have = true;
            } else if (textWidth(seg[line_start..we], size, bold) <= maxw) {
                line_end = we;
            } else {
                try out.append(a, seg[line_start..line_end]);
                line_start = ws;
                line_end = we;
            }
            if (we >= seg.len) break;
            ws = we + 1;
        }
        if (have) try out.append(a, seg[line_start..line_end]);
    }
    return out.items;
}
fn nLines(a: std.mem.Allocator, s: []const u8, size: f64, maxw: f64, bold: bool) !usize {
    const lines = try wrap(a, s, size, maxw, bold);
    return @max(1, lines.len);
}

// ---- SiteHealthReport contract (baton-audit src/types.ts) ------------------
const Finding = struct {
    id: []const u8 = "",
    severity: []const u8 = "info",
    title: []const u8 = "",
    detail: []const u8 = "",
    impact: []const u8 = "",
    recommendation: []const u8 = "",
    evidence: ?[]const u8 = null,
};
const Category = struct {
    key: []const u8 = "",
    label: []const u8 = "",
    score: f64 = 0,
    weight: f64 = 0,
    findings: []const Finding = &.{},
};
const Overall = struct {
    score: f64 = 0,
    grade: []const u8 = "F",
    cappedBy: ?[]const u8 = null,
};
// Lab-vs-field performance table (baton-audit PerformanceBlock / PerfMetricRow).
const PerfMetric = struct {
    key: []const u8 = "",
    label: []const u8 = "",
    lab: ?[]const u8 = null,
    labRating: ?[]const u8 = null,
    labDesktop: ?[]const u8 = null,
    labDesktopRating: ?[]const u8 = null,
    field: ?[]const u8 = null,
    fieldRating: ?[]const u8 = null,
};
const Lighthouse = struct {
    performance: ?f64 = null,
    accessibility: ?f64 = null,
    bestPractices: ?f64 = null,
    seo: ?f64 = null,
};
const LighthouseRun = struct {
    strategy: []const u8 = "",
    categories: Lighthouse = .{},
};
const Performance = struct {
    labScore: ?f64 = null,
    labSource: ?[]const u8 = null,
    labStrategy: ?[]const u8 = null,
    hasDesktopLab: bool = false,
    labDesktopStrategy: ?[]const u8 = null,
    lighthouse: ?Lighthouse = null,
    runs: []const LighthouseRun = &.{},
    fieldScore: ?f64 = null,
    fieldScope: ?[]const u8 = null,
    fieldOverall: ?[]const u8 = null,
    hasField: bool = false,
    rows: []const PerfMetric = &.{},
};
// One prior/current scan (baton-audit LedgerRow) — the Scan History trend.
const HistoryRow = struct {
    ts: []const u8 = "",
    host: []const u8 = "",
    overall: f64 = 0,
    grade: []const u8 = "",
    perf: f64 = 0,
    seo: f64 = 0,
    a11y: f64 = 0,
    sec: f64 = 0,
    comp: f64 = 0,
    @"struct": f64 = 0, // JSON key "struct" is a Zig keyword
    geo: f64 = 0,
    sust: f64 = 0,
    fieldScore: ?f64 = null,
    labPerf: ?f64 = null,
    lcp: ?[]const u8 = null,
    cls: ?[]const u8 = null,
    inp: ?[]const u8 = null,
    fcp: ?[]const u8 = null,
    crit: u32 = 0,
    warn: u32 = 0,
};
// A captured page screenshot for the Pages Loaded gallery (baton-audit GalleryShot).
const GalleryShot = struct {
    url: []const u8 = "",
    label: []const u8 = "",
    dataUri: []const u8 = "",
};
pub const Report = struct {
    url: []const u8 = "",
    domain: []const u8 = "",
    client: ?[]const u8 = null,
    auditedAt: []const u8 = "",
    screenshotDataUri: ?[]const u8 = null,
    overall: Overall = .{},
    categories: []const Category = &.{},
    criticalCount: u32 = 0,
    warningCount: u32 = 0,
    performance: ?Performance = null,
    history: []const HistoryRow = &.{},
    gallery: []const GalleryShot = &.{},
};

// ---- embedded QE assets ----------------------------------------------------
const LOGO_DARK = @embedFile("health_assets/qe_logo_dark.png"); // cyan Q on navy
const LOGO_WHITE = @embedFile("health_assets/qe_logo_white.png"); // cyan Q on white

/// Read a PNG data-URI's pixel dimensions from its IHDR header (decode just the
/// prefix). Returns null if not a base64 PNG. Used to preserve the cover
/// screenshot's aspect ratio instead of squashing it into a fixed box.
fn pngDims(data_uri: []const u8) ?struct { w: f64, h: f64 } {
    const marker = "base64,";
    const idx = std.mem.indexOf(u8, data_uri, marker) orelse return null;
    const b64 = data_uri[idx + marker.len ..];
    if (b64.len < 44) return null;
    var buf: [33]u8 = undefined;
    std.base64.standard.Decoder.decode(&buf, b64[0..44]) catch return null;
    const sig = [_]u8{ 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A };
    if (!std.mem.eql(u8, buf[0..8], &sig)) return null;
    const w = (@as(u32, buf[16]) << 24) | (@as(u32, buf[17]) << 16) | (@as(u32, buf[18]) << 8) | buf[19];
    const h = (@as(u32, buf[20]) << 24) | (@as(u32, buf[21]) << 16) | (@as(u32, buf[22]) << 8) | buf[23];
    if (w == 0 or h == 0) return null;
    return .{ .w = @floatFromInt(w), .h = @floatFromInt(h) };
}

fn dataUrl(a: std.mem.Allocator, bytes: []const u8) ![]const u8 {
    const Enc = std.base64.standard.Encoder;
    const prefix = "data:image/png;base64,";
    const buf = try a.alloc(u8, prefix.len + Enc.calcSize(bytes.len));
    @memcpy(buf[0..prefix.len], prefix);
    _ = Enc.encode(buf[prefix.len..], bytes);
    return buf;
}

// ---- paginating document builder -------------------------------------------
const PageBuf = struct {
    els: std.ArrayListUnmanaged(P.Element) = .empty,
    content: bool = false, // gets running header + footer
};

const Doc = struct {
    a: std.mem.Allocator,
    rep: *const Report,
    logo_dark: []const u8,
    logo_white: []const u8,
    pages: std.ArrayListUnmanaged(PageBuf) = .empty,
    cur: std.ArrayListUnmanaged(P.Element) = .empty,
    cur_content: bool = false,
    y: f64 = 0,

    fn el(self: *Doc, e: P.Element) !void {
        try self.cur.append(self.a, e);
    }
    fn f(self: *Doc, comptime fmt: []const u8, args: anytype) []const u8 {
        return std.fmt.allocPrint(self.a, fmt, args) catch unreachable;
    }

    fn text(self: *Doc, x: f64, y: f64, s: []const u8, size: f64, color: []const u8, bold: bool, al: Align) !void {
        var xx = x;
        if (al == .center) xx = x - textWidth(s, size, bold) / 2.0 else if (al == .right) xx = x - textWidth(s, size, bold);
        try self.el(.{ .text = .{
            .content = s,
            .x = @floatCast(xx),
            .y = @floatCast(y),
            .font_size = @floatCast(size),
            .color = color,
            .font_weight = if (bold) .bold else .normal,
        } });
    }
    fn rect(self: *Doc, x: f64, y: f64, w: f64, h: f64, fill: ?[]const u8, stroke: ?[]const u8, sw: f64) !void {
        try self.el(.{ .shape = .{
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
    fn image(self: *Doc, b64: []const u8, x: f64, y: f64, w: f64, h: f64) !void {
        try self.el(.{ .image = .{ .base64 = b64, .x = @floatCast(x), .y = @floatCast(y), .width = @floatCast(w), .height = @floatCast(h) } });
    }

    fn flushPage(self: *Doc) !void {
        if (self.cur.items.len == 0) return; // don't emit a blank page
        try self.pages.append(self.a, .{ .els = self.cur, .content = self.cur_content });
        self.cur = .empty;
    }

    fn drawHeader(self: *Doc) !void {
        try self.image(self.logo_white, ML, 34, 16, 16);
        try self.text(ML + 22, 46, "Quantum Encoding", 9, NAVY, true, .left);
        try self.text(PW - MR, 46, self.f("{s} · Website Health Audit", .{self.rep.domain}), 8.5, GREY, false, .right);
        try self.rect(ML, 56, CW, 0.8, CYAN, null, 0);
    }

    fn newContentPage(self: *Doc) !void {
        try self.flushPage();
        self.cur_content = true;
        try self.drawHeader();
        self.y = CONTENT_TOP;
    }
    fn ensure(self: *Doc, h: f64) !void {
        if (self.y + h > CONTENT_BOTTOM) try self.newContentPage();
    }
    fn gap(self: *Doc, dy: f64) void {
        self.y += dy;
    }

    // section heading (cyan rule + navy caps) — keeps itself with the next block
    fn section(self: *Doc, title: []const u8) !void {
        try self.ensure(60);
        self.y += 6;
        try self.rect(ML, self.y, 4, 15, CYAN, null, 0);
        try self.text(ML + 12, self.y + 12.5, title, 14, NAVY, true, .left);
        self.y += 24;
    }
    fn para(self: *Doc, s: []const u8, size: f64, color: []const u8, gap_after: f64) !void {
        const lines = try wrap(self.a, s, size, CW, false);
        const step = size * 1.33;
        for (lines) |ln| {
            try self.ensure(step);
            self.y += step;
            try self.text(ML, self.y, ln, size, color, false, .left);
        }
        self.y += gap_after;
    }
    fn bullet(self: *Doc, s: []const u8, size: f64, color: []const u8) !void {
        const lines = try wrap(self.a, s, size, CW - 16, false);
        const step = size * 1.32;
        var first = true;
        for (lines) |ln| {
            try self.ensure(step);
            self.y += step;
            if (first) {
                try self.text(ML + 3, self.y, "\u{2022}", size, CYAN, true, .left);
                first = false;
            }
            try self.text(ML + 16, self.y, ln, size, color, false, .left);
        }
        self.y += 3;
    }

    // horizontal score bar: label ......... [====   ] 82
    fn scoreBar(self: *Doc, label: []const u8, score: f64, weight: f64) !void {
        const row_h: f64 = 24;
        try self.ensure(row_h);
        const y = self.y;
        const col = scoreColor(score);
        try self.text(ML, y + 11, label, 10, INK, true, .left);
        if (weight > 0) try self.text(ML + 170, y + 11, self.f("weight {d:.0}%", .{weight}), 8, LGREY, false, .left);
        const bar_x = ML + 250;
        const bar_w = CW - 250 - 40;
        try self.rect(bar_x, y + 4, bar_w, 12, TRACK, null, 0);
        const fill = bar_w * @max(0.0, @min(100.0, score)) / 100.0;
        try self.rect(bar_x, y + 4, fill, 12, col, null, 0);
        try self.text(PW - MR, y + 11, self.f("{d:.0}", .{score}), 11, col, true, .right);
        self.y += row_h;
    }

    // "2026-07-21T17:43:.." → "07-21 17:43"
    fn dISO(self: *Doc, ts: []const u8) []const u8 {
        if (ts.len >= 16) return self.f("{s} {s}", .{ ts[5..10], ts[11..16] });
        if (ts.len >= 10) return ts[5..10];
        return ts;
    }

    // Scan History — the trend across scans (overall + Δ, grade, perf, field CWV).
    // Renders only with ≥2 rows; the latest row is highlighted.
    fn historyTable(self: *Doc, rows: []const HistoryRow) !void {
        if (rows.len < 2) return;
        try self.section("Scan History");
        try self.para("How the site has moved across scans \u{2014} the effect of each release. Overall " ++
            "score with its change since the previous scan, plus the real-user field Core Web " ++
            "Vitals (Chrome UX Report p75) that Google ranks on.", 10, INK, 10);

        const c_date = ML + 2;
        const c_over = ML + 150;
        const c_delta = ML + 168;
        const c_grade = ML + 220;
        const c_perf = ML + 270;
        const c_field = ML + 324;
        const c_lcp = ML + 382;
        const c_cls = ML + 434;
        const c_warn = ML + 478;

        try self.ensure(22);
        const hy = self.y + 10;
        try self.text(c_date, hy, "DATE", 8, GREY, true, .left);
        try self.text(c_over, hy, "OVERALL", 8, GREY, true, .center);
        try self.text(c_grade, hy, "GRADE", 8, GREY, true, .center);
        try self.text(c_perf, hy, "PERF", 8, GREY, true, .center);
        try self.text(c_field, hy, "FIELD", 8, GREY, true, .center);
        try self.text(c_lcp, hy, "LCP", 8, GREY, true, .center);
        try self.text(c_cls, hy, "CLS", 8, GREY, true, .center);
        try self.text(c_warn, hy, "WARN", 8, GREY, true, .center);
        self.y += 15;
        try self.rect(ML, self.y, CW, 0.8, RULE, null, 0);
        self.y += 1;

        const rh: f64 = 20;
        var prev: ?f64 = null;
        for (rows, 0..) |r, i| {
            try self.ensure(rh);
            const y = self.y;
            const last = i == rows.len - 1;
            if (last) {
                try self.rect(ML, y, CW, rh, "#ecfeff", null, 0); // faint cyan for the current scan
            } else if (i % 2 == 1) {
                try self.rect(ML, y, CW, rh, CARD_BG, null, 0);
            }
            const bold = last;
            try self.text(c_date, y + 13, self.dISO(r.ts), 9, INK, bold, .left);
            try self.text(c_over, y + 13, self.f("{d:.0}", .{r.overall}), 10, scoreColor(r.overall), bold, .center);
            if (prev) |p| {
                const d = r.overall - p;
                if (d > 0) {
                    try self.text(c_delta, y + 13, self.f("+{d:.0}", .{d}), 8.5, GREEN, true, .left);
                } else if (d < 0) {
                    try self.text(c_delta, y + 13, self.f("{d:.0}", .{d}), 8.5, RED, true, .left);
                } else {
                    try self.text(c_delta, y + 13, "0", 8.5, LGREY, false, .left);
                }
            }
            try self.text(c_grade, y + 13, r.grade, 10, gradeColor(r.grade), bold, .center);
            try self.text(c_perf, y + 13, self.f("{d:.0}", .{r.perf}), 9.5, scoreColor(r.perf), bold, .center);
            if (r.fieldScore) |fs| {
                try self.text(c_field, y + 13, self.f("{d:.0}", .{fs}), 9.5, scoreColor(fs), bold, .center);
            } else {
                try self.text(c_field, y + 13, "\u{2014}", 9.5, LGREY, false, .center);
            }
            try self.text(c_lcp, y + 13, r.lcp orelse "\u{2014}", 9, INK, bold, .center);
            try self.text(c_cls, y + 13, r.cls orelse "\u{2014}", 9, INK, bold, .center);
            try self.text(c_warn, y + 13, self.f("{d}", .{r.warn}), 9.5, if (r.warn == 0) GREEN else AMBER, bold, .center);
            prev = r.overall;
            self.y += rh;
        }
        self.y += 3;
        try self.rect(ML, self.y, CW, 0.8, RULE, null, 0);
        self.y += 8;
    }

    // one half of the lab/field score band
    fn perfScoreCell(self: *Doc, x: f64, w: f64, y: f64, h: f64, tag: []const u8, sub: []const u8, score: ?f64, foot: []const u8) !void {
        try self.rect(x, y, w, h, CARD_BG, RULE, 0.8);
        try self.rect(x, y, 4, h, CYAN, null, 0);
        try self.text(x + 12, y + 16, tag, 8.5, GREY, true, .left);
        try self.text(x + w - 12, y + 16, sub, 8, LGREY, false, .right);
        if (score) |sc| {
            const col = scoreColor(sc);
            const num = self.f("{d:.0}", .{sc});
            try self.text(x + 12, y + 41, num, 25, col, true, .left);
            try self.text(x + 14 + textWidth(num, 25, true), y + 41, "/ 100", 10, LGREY, false, .left);
        } else {
            try self.text(x + 12, y + 41, "n/a", 18, LGREY, true, .left);
        }
        try self.text(x + 12, y + h - 8, foot, 8, GREY, false, .left);
    }

    fn perfLegend(self: *Doc) !void {
        try self.ensure(14);
        self.y += 10;
        const items = [_]struct { c: []const u8, t: []const u8 }{
            .{ .c = GREEN, .t = "Good" },
            .{ .c = AMBER, .t = "Needs improvement" },
            .{ .c = RED, .t = "Poor" },
            .{ .c = LGREY, .t = "not reported by this source" },
        };
        var x = ML + 4;
        for (items) |it| {
            try self.text(x, self.y, "\u{2022}", 11, it.c, true, .left);
            try self.text(x + 11, self.y, it.t, 8.5, GREY, false, .left);
            x += 11 + textWidth(it.t, 8.5, false) + 16;
        }
    }

    // one Lighthouse gauge: a coloured ring (DevTools style) with the score
    // inside and a category label beneath.
    fn lhGauge(self: *Doc, cx: f64, cy: f64, label: []const u8, v: ?f64) !void {
        const R: f64 = 23; // radius; renderer takes width as diameter (radius = width/2)
        const col = if (v) |vv| scoreColor(vv) else LGREY;
        // white-filled disc with a coloured ring border (DevTools gauge look)
        try self.el(.{ .shape = .{ .shape = .circle, .x = @floatCast(cx), .y = @floatCast(cy), .width = @floatCast(R * 2), .height = @floatCast(R * 2), .fill_color = WHITE, .stroke_color = col, .stroke_width = 3 } });
        const num = if (v) |vv| self.f("{d:.0}", .{vv}) else "\u{2014}";
        const fs: f64 = if (num.len >= 3) 14 else 16; // shrink "100" so it fits the ring
        try self.text(cx, cy + fs * 0.35, num, fs, col, true, .center);
        try self.text(cx, cy + R + 14, label, 8.5, GREY, false, .center);
    }

    // The four Lighthouse category gauges (Performance / Accessibility / Best
    // Practices / SEO) — the DevTools/PSI lab report, shown in full.
    fn lhCard(self: *Doc, lh: Lighthouse, heading: []const u8) !void {
        try self.ensure(108);
        self.y += 2;
        try self.text(ML, self.y + 9, heading, 9.5, NAVY, true, .left);
        self.y += 20;
        const gy = self.y + 26;
        const items = [_]struct { l: []const u8, v: ?f64 }{
            .{ .l = "Performance", .v = lh.performance },
            .{ .l = "Accessibility", .v = lh.accessibility },
            .{ .l = "Best Practices", .v = lh.bestPractices },
            .{ .l = "SEO", .v = lh.seo },
        };
        for (items, 0..) |it, i| {
            const cx = ML + CW * (@as(f64, @floatFromInt(i)) + 0.5) / 4.0;
            try self.lhGauge(cx, gy, it.l, it.v);
        }
        self.y = gy + 23 + 22;
    }

    // Performance: lab (synthetic) vs field (real-user CrUX) — the actual stats,
    // side by side, so the report shows numbers rather than a single vibe score.
    fn perfTable(self: *Doc, p: Performance) !void {
        try self.section("Performance — Lab vs Field");
        try self.para("Two ways to measure speed, and they routinely disagree. \u{201C}Lab\u{201D} is a single " ++
            "synthetic page load (Lighthouse / PageSpeed Insights): repeatable, but pessimistic and " ++
            "sensitive to the test machine. \u{201C}Field\u{201D} is the 75th-percentile experience of real " ++
            "Chrome users over the last 28 days (Chrome UX Report) \u{2014} the numbers Google actually " ++
            "ranks on. Where the two disagree, the field column is the ground truth.", 10, INK, 12);

        // score band: lab | field
        const band_h: f64 = 60;
        try self.ensure(band_h + 46);
        const hw = (CW - 12) / 2;
        const yb = self.y;
        const labsub = self.f("{s} \u{00B7} {s}", .{ srcLabel(p.labSource), stratLabel(p.labStrategy) });
        try self.perfScoreCell(ML, hw, yb, band_h, "LAB (synthetic)", labsub, p.labScore, "one load in Google\u{2019}s remote lab");
        if (p.hasField) {
            const fsub = self.f("CrUX \u{00B7} {s} p75", .{scopeLabel(p.fieldScope)});
            try self.perfScoreCell(ML + hw + 12, hw, yb, band_h, "FIELD (real-user)", fsub, p.fieldScore, "real visitors, rolling 28 days");
        } else {
            try self.perfScoreCell(ML + hw + 12, hw, yb, band_h, "FIELD (real-user)", "no CrUX data", null, "too little traffic for field data");
        }
        self.y = yb + band_h + 16;

        // Lighthouse category gauges — one card per run (mobile + desktop when --both).
        if (p.runs.len > 0) {
            for (p.runs) |run| {
                try self.lhCard(run.categories, self.f("Lighthouse \u{2014} {s} lab ({s})", .{ ffLabel(run.strategy), srcLabel(p.labSource) }));
            }
        } else if (p.lighthouse) |lh| {
            try self.lhCard(lh, self.f("Lighthouse report \u{2014} lab ({s} \u{00B7} {s})", .{ srcLabel(p.labSource), stratLabel(p.labStrategy) }));
        }

        // metric table — 2 columns (Lab | Field) or 3 (Lab mobile | Lab desktop | Field)
        const three = p.hasDesktopLab;
        const cx_lab = if (three) ML + 268 else ML + 312;
        const cx_lab2 = ML + 360; // desktop lab (only when three)
        const cx_field = if (three) ML + 456 else ML + 430;
        try self.ensure(20);
        try self.text(ML + 4, self.y + 10, "Core Web Vital / lab metric", 8.5, GREY, true, .left);
        if (three) {
            try self.text(cx_lab, self.y + 10, self.f("Lab \u{00B7} {s}", .{ffLabel(p.labStrategy orelse "mobile")}), 8, GREY, true, .center);
            try self.text(cx_lab2, self.y + 10, self.f("Lab \u{00B7} {s}", .{ffLabel(p.labDesktopStrategy orelse "desktop")}), 8, GREY, true, .center);
        } else {
            try self.text(cx_lab, self.y + 10, "Lab", 8.5, GREY, true, .center);
        }
        try self.text(cx_field, self.y + 10, "Field (p75)", 8, GREY, true, .center);
        self.y += 15;
        try self.rect(ML, self.y, CW, 0.8, RULE, null, 0);
        self.y += 1;

        const rh: f64 = 19;
        for (p.rows, 0..) |row, i| {
            try self.ensure(rh);
            const y = self.y;
            if (i % 2 == 1) try self.rect(ML, y, CW, rh, CARD_BG, null, 0);
            try self.text(ML + 4, y + 13, row.label, 9.5, INK, false, .left);
            const lab = row.lab orelse "\u{2014}";
            const fld = row.field orelse "\u{2014}";
            try self.text(cx_lab, y + 13, lab, 10, ratingColor(row.labRating), row.lab != null, .center);
            if (three) {
                const labd = row.labDesktop orelse "\u{2014}";
                try self.text(cx_lab2, y + 13, labd, 10, ratingColor(row.labDesktopRating), row.labDesktop != null, .center);
            }
            try self.text(cx_field, y + 13, fld, 10, ratingColor(row.fieldRating), row.field != null, .center);
            self.y += rh;
        }
        self.y += 3;
        try self.rect(ML, self.y, CW, 0.8, RULE, null, 0);
        self.y += 8;
        try self.perfLegend();
        self.gap(10);
    }

    // severity pill: small filled tag with white caps label; returns its width
    fn pill(self: *Doc, x: f64, y: f64, sev: []const u8) !f64 {
        // Uppercase into ARENA memory — a stack buffer would dangle by render time.
        const up = try self.a.alloc(u8, sev.len);
        _ = std.ascii.upperString(up, sev);
        const w = textWidth(up, 7, true) + 12;
        try self.rect(x, y - 8.5, w, 12, sevColor(sev), null, 0);
        try self.text(x + 6, y, up, 7, WHITE, true, .left);
        return w;
    }

    // A finding card — kept whole on one page.
    fn findingCard(self: *Doc, fnd: Finding) !void {
        const tw = CW - 28; // text width inside card
        const title_lines = try nLines(self.a, fnd.title, 10.5, tw - 70, true);
        const detail_lines = if (fnd.detail.len > 0) try nLines(self.a, fnd.detail, 9.5, tw, false) else 0;
        const why = if (fnd.impact.len > 0) self.f("Why it matters: {s}", .{fnd.impact}) else "";
        const why_lines = if (why.len > 0) try nLines(self.a, why, 9, tw, false) else 0;
        const fix = if (fnd.recommendation.len > 0) self.f("Recommended fix: {s}", .{fnd.recommendation}) else "";
        const fix_lines = if (fix.len > 0) try nLines(self.a, fix, 9.5, tw, false) else 0;
        const ev_lines: usize = if (fnd.evidence) |_| 1 else 0;

        const lh: f64 = 1.32;
        var h: f64 = 10; // top pad
        h += @max(12.0, @as(f64, @floatFromInt(title_lines)) * 10.5 * lh);
        if (detail_lines > 0) h += 3 + @as(f64, @floatFromInt(detail_lines)) * 9.5 * lh;
        if (why_lines > 0) h += 3 + @as(f64, @floatFromInt(why_lines)) * 9 * lh;
        if (fix_lines > 0) h += 3 + @as(f64, @floatFromInt(fix_lines)) * 9.5 * lh;
        if (ev_lines > 0) h += 3 + 11;
        h += 10; // bottom pad

        try self.ensure(h + 6);
        const y0 = self.y;
        try self.rect(ML, y0, CW, h, CARD_BG, null, 0);
        try self.rect(ML, y0, 4, h, sevColor(fnd.severity), null, 0);

        const cx = ML + 14;
        var yy = y0 + 10;
        // severity pill + title on the first line
        yy += 10;
        const pw = try self.pill(cx, yy, fnd.severity);
        const tlines = try wrap(self.a, fnd.title, 10.5, tw - pw - 8, true);
        for (tlines, 0..) |ln, i| {
            if (i == 0) {
                try self.text(cx + pw + 8, yy, ln, 10.5, NAVY, true, .left);
            } else {
                yy += 10.5 * lh;
                try self.text(cx, yy, ln, 10.5, NAVY, true, .left);
            }
        }
        if (detail_lines > 0) {
            for (try wrap(self.a, fnd.detail, 9.5, tw, false)) |ln| {
                yy += 9.5 * lh;
                try self.text(cx, yy, ln, 9.5, INK, false, .left);
            }
            yy += 3;
        }
        if (why_lines > 0) {
            for (try wrap(self.a, why, 9, tw, false)) |ln| {
                yy += 9 * lh;
                try self.text(cx, yy, ln, 9, GREY, false, .left);
            }
            yy += 3;
        }
        if (fix_lines > 0) {
            for (try wrap(self.a, fix, 9.5, tw, false)) |ln| {
                yy += 9.5 * lh;
                try self.text(cx, yy, ln, 9.5, CYAN, false, .left);
            }
            yy += 3;
        }
        if (fnd.evidence) |ev| {
            yy += 11;
            const shown = if (ev.len > 96) ev[0..96] else ev;
            try self.text(cx, yy, self.f("{s}", .{shown}), 8, LGREY, false, .left);
        }
        self.y = y0 + h + 8;
    }

    fn finish(self: *Doc) !P.PresentationData {
        try self.flushPage();
        const total = self.pages.items.len;
        // stamp footer with "Page N of M" on content pages
        for (self.pages.items, 0..) |*pb, i| {
            if (!pb.content) continue;
            try pb.els.append(self.a, .{ .shape = .{ .shape = .rectangle, .x = @floatCast(ML), .y = @floatCast(CONTENT_BOTTOM + 12), .width = @floatCast(CW), .height = 0.6, .fill_color = RULE, .stroke_color = null, .stroke_width = 0 } });
            try pb.els.append(self.a, .{ .text = .{ .content = "Quantum Encoding · quantumencoding.io", .x = @floatCast(ML), .y = @floatCast(CONTENT_BOTTOM + 24), .font_size = 8, .color = LGREY } });
            const pn = self.f("Page {d} of {d}", .{ i + 1, total });
            try pb.els.append(self.a, .{ .text = .{ .content = pn, .x = @floatCast(PW - MR - textWidth(pn, 8, false)), .y = @floatCast(CONTENT_BOTTOM + 24), .font_size = 8, .color = LGREY } });
        }
        const out = try self.a.alloc(P.Page, self.pages.items.len);
        for (self.pages.items, 0..) |pb, i| out[i] = .{ .background_color = WHITE, .elements = pb.els.items };
        return .{ .page_size = .{ .width = @floatCast(PW), .height = @floatCast(PH) }, .pages = out };
    }
};

// ---- cover page ------------------------------------------------------------
fn buildCover(d: *Doc) !void {
    const r = d.rep;
    // dark brand band
    try d.rect(0, 0, PW, 150, NAVY, null, 0);
    try d.image(d.logo_dark, ML, 42, 50, 50);
    try d.text(ML + 64, 66, "QUANTUM ENCODING", 16, CYAN_BRIGHT, true, .left);
    try d.text(ML + 64, 86, "Website Health & Compliance Audit", 10, CREAM, false, .left);

    // title + domain
    try d.text(ML, 214, "Website Health Audit", 27, NAVY, true, .left);
    try d.text(ML, 244, r.domain, 20, CYAN, true, .left);
    var yy: f64 = 268;
    if (r.client) |c| {
        try d.text(ML, yy, d.f("Prepared for {s}", .{c}), 11, GREY, false, .left);
        yy += 18;
    }
    try d.text(ML, yy, d.f("Audited {s}", .{r.auditedAt}), 9.5, LGREY, false, .left);

    // grade badge (right)
    const bx = PW - MR - 150;
    const by: f64 = 190;
    try d.rect(bx, by, 150, 150, gradeColor(r.overall.grade), null, 0);
    try d.text(bx + 75, by + 98, r.overall.grade, 82, WHITE, true, .center);
    try d.text(bx + 75, by + 128, d.f("{s}", .{gradeWord(r.overall.grade)}), 12, WHITE, true, .center);

    // score line under title
    try d.text(ML, 330, d.f("Overall score {d:.0} / 100", .{r.overall.score}), 15, NAVY, true, .left);
    try d.rect(ML, 340, 250, 10, TRACK, null, 0);
    try d.rect(ML, 340, 250 * @max(0.0, @min(100.0, r.overall.score)) / 100.0, 10, scoreColor(r.overall.score), null, 0);
    try d.text(ML, 372, d.f("{d} critical · {d} warnings across {d} categories", .{ r.criticalCount, r.warningCount, r.categories.len }), 10, GREY, false, .left);
    if (r.overall.cappedBy) |cap| {
        try d.text(ML, 390, d.f("Grade capped by: {s}", .{cap}), 9.5, RED, true, .left);
    }

    // screenshot frame (optional) — fit within a box, preserving aspect ratio
    if (r.screenshotDataUri) |shot| {
        const box_w: f64 = 440;
        const box_h: f64 = 320;
        var iw: f64 = box_w;
        var ih: f64 = box_h * (10.0 / 16.0); // fallback aspect if dims unreadable
        if (pngDims(shot)) |dim| {
            const scale = @min(box_w / dim.w, box_h / dim.h);
            iw = dim.w * scale;
            ih = dim.h * scale;
        }
        const ix = (PW - iw) / 2;
        const iyv: f64 = 428;
        try d.rect(ix - 6, iyv - 6, iw + 12, ih + 12, "#f3f4f6", RULE, 1);
        try d.image(shot, ix, iyv, iw, ih);
        try d.text(PW / 2, iyv + ih + 22, d.f("{s}", .{r.url}), 9, LGREY, false, .center);
    }

    // cover footer
    try d.rect(ML, PH - 54, CW, 0.8, RULE, null, 0);
    try d.text(ML, PH - 38, "Confidential — prepared by Quantum Encoding", 9, GREY, false, .left);
    try d.text(PW - MR, PH - 38, "quantumencoding.io", 9, CYAN, false, .right);

    d.cur_content = false;
    try d.flushPage();
}

// ---- report body -----------------------------------------------------------
fn allFindingsSorted(a: std.mem.Allocator, r: *const Report, want_pass: bool) ![]const Finding {
    var list: std.ArrayListUnmanaged(Finding) = .empty;
    for (r.categories) |c| {
        for (c.findings) |fnd| {
            if (!want_pass and std.mem.eql(u8, fnd.severity, "pass")) continue;
            try list.append(a, fnd);
        }
    }
    std.mem.sort(Finding, list.items, {}, struct {
        fn lt(_: void, x: Finding, yv: Finding) bool {
            return sevRank(x.severity) < sevRank(yv.severity);
        }
    }.lt);
    return list.items;
}

// Pages Loaded — a 2-column grid of page screenshots (proof of real page loads).
fn buildGallery(d: *Doc) !void {
    const shots = d.rep.gallery;
    if (shots.len == 0) return;
    try d.section("Pages Loaded");
    try d.para("Screenshots captured during the audit \u{2014} evidence each page was loaded and " ++
        "rendered in a real browser (Chrome DevTools Protocol), not just fetched as HTML.", 10, INK, 10);

    const gap: f64 = 14;
    const cw = (CW - gap) / 2.0; // two columns
    var i: usize = 0;
    while (i < shots.len) : (i += 2) {
        // row image height = tallest image in the row at column width (capped)
        var row_ih: f64 = cw * 9.0 / 16.0;
        var j: usize = 0;
        while (j < 2 and i + j < shots.len) : (j += 1) {
            if (pngDims(shots[i + j].dataUri)) |dim| {
                const h = cw * dim.h / dim.w;
                if (h > row_ih) row_ih = h;
            }
        }
        if (row_ih > 190) row_ih = 190;
        const cell_h = row_ih + 22;
        try d.ensure(cell_h + 6);
        const y0 = d.y;
        j = 0;
        while (j < 2 and i + j < shots.len) : (j += 1) {
            const shot = shots[i + j];
            const x = ML + @as(f64, @floatFromInt(j)) * (cw + gap);
            var iw = cw;
            var ih = row_ih;
            if (pngDims(shot.dataUri)) |dim| {
                const scale = @min(cw / dim.w, row_ih / dim.h);
                iw = dim.w * scale;
                ih = dim.h * scale;
            }
            try d.rect(x, y0, cw, row_ih, "#f3f4f6", RULE, 0.8);
            try d.image(shot.dataUri, x + (cw - iw) / 2.0, y0 + (row_ih - ih) / 2.0, iw, ih);
            try d.text(x + 2, y0 + row_ih + 13, shot.label, 8.5, GREY, false, .left);
        }
        d.y = y0 + cell_h + 6;
    }
    d.gap(6);
}

fn buildBody(d: *Doc) !void {
    const r = d.rep;
    try d.newContentPage();

    // 1. Executive summary
    try d.section("Executive Summary");
    try d.para(d.f("This report assesses {s} across {d} areas of website health — performance, " ++
        "SEO, accessibility, security, compliance, structured data, AI-search readiness and " ++
        "sustainability. It scored {d:.0} out of 100, an overall grade of {s} ({s}).", .{ r.domain, r.categories.len, r.overall.score, r.overall.grade, gradeWord(r.overall.grade) }), 10.5, INK, 8);
    if (r.criticalCount > 0 or r.warningCount > 0) {
        try d.para(d.f("We identified {d} critical issue(s) and {d} warning(s). The most important are listed below; " ++
            "full detail follows by category.", .{ r.criticalCount, r.warningCount }), 10.5, INK, 6);
    } else {
        try d.para("No critical issues were found. This site is in good health across the audited areas.", 10.5, INK, 6);
    }
    // headline problems: top criticals then warnings, up to 5
    {
        const sorted = try allFindingsSorted(d.a, r, false);
        var shown: usize = 0;
        for (sorted) |fnd| {
            if (shown >= 5) break;
            if (std.mem.eql(u8, fnd.severity, "info")) continue;
            try d.bullet(d.f("{s} — {s}", .{ fnd.title, fnd.detail }), 10, INK);
            shown += 1;
        }
    }
    d.gap(8);

    // 2. Scorecard
    try d.section("Scorecard");
    try d.scoreBar("Overall", r.overall.score, 0);
    d.gap(2);
    for (r.categories) |c| try d.scoreBar(c.label, c.score, c.weight);
    d.gap(10);

    // 2a. Scan History — the trend across scans (renders only with ≥2 ledger rows)
    if (r.history.len >= 2) try d.historyTable(r.history);

    // 2b. Performance — lab vs field stats table (when Lighthouse and/or CrUX ran)
    if (r.performance) |p| {
        if (p.rows.len > 0 or p.labScore != null or p.fieldScore != null) try d.perfTable(p);
    }

    // 3. Critical issues
    {
        const sorted = try allFindingsSorted(d.a, r, false);
        var any = false;
        for (sorted) |fnd| {
            if (std.mem.eql(u8, fnd.severity, "critical")) any = true;
        }
        if (any) {
            try d.section("Critical Issues");
            try d.para("These must be fixed first — each carries real risk (lost traffic, legal exposure, or security).", 10, GREY, 8);
            for (sorted) |fnd| {
                if (std.mem.eql(u8, fnd.severity, "critical")) try d.findingCard(fnd);
            }
            d.gap(6);
        }
    }

    // 4. Per-category detail
    try d.section("Detailed Findings by Category");
    for (r.categories) |c| {
        try d.ensure(48);
        d.gap(4);
        // category header row
        const col = scoreColor(c.score);
        try d.text(ML, d.y + 12, c.label, 12, NAVY, true, .left);
        try d.text(PW - MR, d.y + 12, d.f("{d:.0}/100", .{c.score}), 12, col, true, .right);
        d.y += 18;
        try d.rect(ML, d.y, CW, 8, TRACK, null, 0);
        try d.rect(ML, d.y, CW * @max(0.0, @min(100.0, c.score)) / 100.0, 8, col, null, 0);
        d.y += 16;
        var shown = false;
        for (c.findings) |fnd| {
            if (std.mem.eql(u8, fnd.severity, "pass")) continue;
            try d.findingCard(fnd);
            shown = true;
        }
        if (!shown) {
            try d.para("No issues found in this category.", 9.5, GREEN, 4);
        }
        d.gap(8);
    }

    // 5. Prioritised fix list
    try d.section("Prioritised Fix List");
    try d.para("Everything to address, ordered by severity.", 10, GREY, 8);
    {
        const sorted = try allFindingsSorted(d.a, r, false);
        var n: usize = 1;
        for (sorted) |fnd| {
            if (std.mem.eql(u8, fnd.severity, "info")) continue;
            const line = d.f("{d}. [{s}] {s} — {s}", .{ n, fnd.severity, fnd.title, fnd.recommendation });
            const lines = try wrap(d.a, line, 9.5, CW - 6, false);
            const step: f64 = 9.5 * 1.32;
            for (lines, 0..) |ln, i| {
                try d.ensure(step);
                d.y += step;
                try d.text(if (i == 0) ML else ML + 14, d.y, ln, 9.5, INK, false, .left);
            }
            d.y += 3;
            n += 1;
        }
    }
    d.gap(10);

    // 5b. Pages Loaded — screenshot gallery (renders only when --shots captured any)
    try buildGallery(d);

    // 6. Methodology & next steps
    try d.section("Methodology & Next Steps");
    try d.para("This audit was produced by baton-audit: a real browser (Brave over the Chrome DevTools " ++
        "Protocol) loads the page, and each category is scored by deterministic checks reading the live " ++
        "DOM, response headers, cookies and navigation timing — the same signals a search engine, " ++
        "screen reader or regulator would see.", 10, INK, 8);
    try d.para("Scores start at 100 and deduct per issue by severity; the overall is a weighted average, " ++
        "and a critical security or compliance failure caps the grade at C. Weightings reflect commercial " ++
        "impact and can be tuned per engagement.", 10, INK, 8);
    try d.para("Want these issues fixed? Quantum Encoding rebuilds sites to score in the 90s across every " ++
        "category — fast, accessible, compliant and search-ready. Get in touch at quantumencoding.io.", 10.5, CYAN, 4);
}

// ---- entry points ----------------------------------------------------------
pub fn generateWebsiteHealthReport(alloc: std.mem.Allocator, report: Report) ![]const u8 {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    var d = Doc{
        .a = a,
        .rep = &report,
        .logo_dark = try dataUrl(a, LOGO_DARK),
        .logo_white = try dataUrl(a, LOGO_WHITE),
    };
    try buildCover(&d);
    try buildBody(&d);
    const data = try d.finish();
    var renderer = P.PresentationRenderer.init(a, data);
    const pdf = try renderer.render();
    return alloc.dupe(u8, pdf);
}

pub fn generateWebsiteHealthReportFromJson(alloc: std.mem.Allocator, json_str: []const u8) ![]const u8 {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const report = try std.json.parseFromSliceLeaky(Report, arena.allocator(), json_str, .{ .ignore_unknown_fields = true });
    return generateWebsiteHealthReport(alloc, report);
}
