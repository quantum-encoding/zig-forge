//! Bindings, resolution against a legend, and rendering of a parsed template.

const std = @import("std");
const Diag = @import("diag.zig").Diag;
const template = @import("template.zig");
const legend_mod = @import("legend.zig");
const Legend = legend_mod.Legend;
const VarSpec = legend_mod.VarSpec;
const KV = legend_mod.KV;

/// name → value, in insertion order. Values are borrowed; the caller keeps
/// the legend / argv / plan storage alive for as long as the bindings are used.
pub const Bindings = struct {
    map: std.StringArrayHashMapUnmanaged([]const u8) = .empty,

    pub fn deinit(self: *Bindings, gpa: std.mem.Allocator) void {
        self.map.deinit(gpa);
    }

    pub fn put(self: *Bindings, gpa: std.mem.Allocator, name: []const u8, value: []const u8) !void {
        try self.map.put(gpa, name, value);
    }

    pub fn get(self: *const Bindings, name: []const u8) ?[]const u8 {
        return self.map.get(name);
    }

    pub fn count(self: *const Bindings) usize {
        return self.map.count();
    }

    /// Keys sorted for stable output.
    pub fn sortedKeys(self: *const Bindings, gpa: std.mem.Allocator) ![]const []const u8 {
        const keys = try gpa.dupe([]const u8, self.map.keys());
        std.mem.sort([]const u8, keys, {}, struct {
            fn lt(_: void, x: []const u8, y: []const u8) bool {
                return std.mem.lessThan(u8, x, y);
            }
        }.lt);
        return keys;
    }
};

pub const ResolveError = error{
    OutOfMemory,
    UnknownScenario,
    UnknownVariable,
    BadValue,
    MissingRequired,
    NoMapping,
};

/// Build the bindings for one variant. Precedence, highest first:
/// `overrides` (CLI `--set`), `picks` (a plan's choice per variable), the
/// scenario, the variable's default. Dependent (`by`) variables are then
/// filled from their map unless already bound.
pub fn resolve(
    gpa: std.mem.Allocator,
    legend: *const Legend,
    scenario_name: ?[]const u8,
    picks: []const KV,
    overrides: []const KV,
    diag: *Diag,
) ResolveError!Bindings {
    var b = Bindings{};
    errdefer b.deinit(gpa);

    for (legend.vars) |*v| {
        if (v.default) |d| try b.put(gpa, v.name, d);
    }
    if (scenario_name) |sn| {
        const s = legend.scenario(sn) orelse {
            diag.set(0, "unknown scenario '{s}'", .{sn});
            return error.UnknownScenario;
        };
        for (s.set) |kv| try b.put(gpa, kv.key, kv.value);
    }
    for (picks) |kv| try b.put(gpa, kv.key, kv.value);
    for (overrides) |kv| {
        const spec = legend.find(kv.key) orelse {
            diag.set(0, "'{s}' is not in the legend", .{kv.key});
            return error.UnknownVariable;
        };
        try legend_mod.checkValue(spec, kv.value, diag);
        try b.put(gpa, kv.key, kv.value);
    }
    for (legend.vars) |*v| {
        if (v.by) |by| {
            if (b.get(v.name) != null) continue;
            const key = b.get(by) orelse continue;
            const mapped = v.mapLookup(key) orelse {
                diag.set(0, "'{s}' has no mapping for {s}={s}", .{ v.name, by, key });
                return error.NoMapping;
            };
            try b.put(gpa, v.name, mapped);
        }
    }
    for (legend.vars) |*v| {
        if (v.required and b.get(v.name) == null) {
            diag.set(0, "required variable '{s}' is not bound", .{v.name});
            return error.MissingRequired;
        }
    }
    return b;
}

pub const RenderError = error{
    OutOfMemory,
    WriteFailed,
    MissingVariable,
    UnknownFilter,
    BadValue,
};

/// Render `t` with `b` to `w`. `legend` may be null (untyped bindings).
pub fn render(
    gpa: std.mem.Allocator,
    t: *const template.Template,
    legend: ?*const Legend,
    b: *const Bindings,
    w: *std.Io.Writer,
    diag: *Diag,
) RenderError!void {
    try renderNodes(gpa, t.nodes, legend, b, w, diag);
}

pub fn renderAlloc(
    gpa: std.mem.Allocator,
    t: *const template.Template,
    legend: ?*const Legend,
    b: *const Bindings,
    diag: *Diag,
) RenderError![]u8 {
    var out = std.Io.Writer.Allocating.init(gpa);
    errdefer out.deinit();
    try render(gpa, t, legend, b, &out.writer, diag);
    return out.toOwnedSlice();
}

fn renderNodes(
    gpa: std.mem.Allocator,
    nodes: []const template.Node,
    legend: ?*const Legend,
    b: *const Bindings,
    w: *std.Io.Writer,
    diag: *Diag,
) RenderError!void {
    for (nodes) |n| switch (n) {
        .text => |s| w.writeAll(s) catch return error.WriteFailed,
        .variable => |v| {
            const raw = b.get(v.name) orelse {
                diag.set(v.line, "'{s}' is not bound", .{v.name});
                return error.MissingVariable;
            };
            const spec: ?*const VarSpec = if (legend) |l| l.find(v.name) else null;
            try writeValue(gpa, raw, spec, v.filters, w, v.line, diag);
        },
        .cond => |c| {
            const raw = b.get(c.name) orelse {
                diag.set(c.line, "'{s}' is not bound", .{c.name});
                return error.MissingVariable;
            };
            const spec: ?*const VarSpec = if (legend) |l| l.find(c.name) else null;
            const hit = switch (c.op) {
                .truthy => truthy(raw, spec),
                .eq => std.mem.eql(u8, canonical(raw, spec), canonical(c.value, spec)),
                .ne => !std.mem.eql(u8, canonical(raw, spec), canonical(c.value, spec)),
            };
            try renderNodes(gpa, if (hit) c.then_nodes else c.else_nodes, legend, b, w, diag);
        },
    };
}

fn truthy(raw: []const u8, spec: ?*const VarSpec) bool {
    if (spec != null and spec.?.kind == .bool) return legend_mod.parseBool(raw) orelse false;
    if (legend_mod.parseBool(raw)) |bv| return bv;
    return std.mem.trim(u8, raw, " \t\r\n").len != 0;
}

/// Booleans compare by meaning ("yes" == "true"); everything else by text.
fn canonical(raw: []const u8, spec: ?*const VarSpec) []const u8 {
    if (spec != null and spec.?.kind == .bool) {
        if (legend_mod.parseBool(raw)) |bv| return if (bv) "true" else "false";
    }
    return raw;
}

/// Filters, applied left to right after the type's default formatting:
///   raw    skip the type formatting (money digits, ISO date)
///   upper / lower / title / trim
///   long   date → "16 September 2026"
///   us     date → "September 16, 2026"
///   uk     date → "16/09/2026"
///   plain  money → "1,234.50" (no currency)
pub const filter_names = [_][]const u8{ "raw", "upper", "lower", "title", "trim", "long", "us", "uk", "plain" };

fn writeValue(
    gpa: std.mem.Allocator,
    raw: []const u8,
    spec: ?*const VarSpec,
    filters: []const []const u8,
    w: *std.Io.Writer,
    line: u32,
    diag: *Diag,
) RenderError!void {
    var buf = std.Io.Writer.Allocating.init(gpa);
    defer buf.deinit();
    const bw = &buf.writer;

    const want_raw = filters.len > 0 and std.mem.eql(u8, filters[0], "raw");
    var date_style: enum { iso, long, us, uk } = .iso;
    var money_symbol = true;
    for (filters) |f| {
        if (std.mem.eql(u8, f, "long")) date_style = .long;
        if (std.mem.eql(u8, f, "us")) date_style = .us;
        if (std.mem.eql(u8, f, "uk")) date_style = .uk;
        if (std.mem.eql(u8, f, "plain")) money_symbol = false;
    }

    // Type formatting.
    if (spec != null and !want_raw) switch (spec.?.kind) {
        .money => formatMoney(raw, spec.?, money_symbol, bw) catch |e| switch (e) {
            error.BadValue => {
                diag.set(line, "'{s}' holds '{s}', which is not an amount", .{ spec.?.name, raw });
                return error.BadValue;
            },
            else => return error.OutOfMemory,
        },
        .date => {
            const d = legend_mod.parseDate(raw) orelse {
                diag.set(line, "'{s}' holds '{s}', which is not a date", .{ spec.?.name, raw });
                return error.BadValue;
            };
            formatDate(d, date_style, bw) catch return error.OutOfMemory;
        },
        .bool => bw.writeAll(if (legend_mod.parseBool(raw) orelse false) "true" else "false") catch return error.OutOfMemory,
        else => bw.writeAll(raw) catch return error.OutOfMemory,
    } else bw.writeAll(raw) catch return error.OutOfMemory;

    // Text filters.
    for (filters) |f| {
        const s = buf.written();
        if (std.mem.eql(u8, f, "upper")) {
            for (s) |*c| c.* = std.ascii.toUpper(c.*);
        } else if (std.mem.eql(u8, f, "lower")) {
            for (s) |*c| c.* = std.ascii.toLower(c.*);
        } else if (std.mem.eql(u8, f, "title")) {
            var at_word_start = true;
            for (s) |*c| {
                if (std.ascii.isAlphanumeric(c.*)) {
                    c.* = if (at_word_start) std.ascii.toUpper(c.*) else std.ascii.toLower(c.*);
                    at_word_start = false;
                } else at_word_start = true;
            }
        } else if (std.mem.eql(u8, f, "trim")) {
            const t = std.mem.trim(u8, s, " \t\r\n");
            std.mem.copyForwards(u8, s[0..t.len], t);
            buf.shrinkRetainingCapacity(t.len);
        } else if (std.mem.eql(u8, f, "raw") or std.mem.eql(u8, f, "long") or std.mem.eql(u8, f, "us") or
            std.mem.eql(u8, f, "uk") or std.mem.eql(u8, f, "plain"))
        {
            // Consumed above.
        } else {
            diag.set(line, "unknown filter '{s}'", .{f});
            return error.UnknownFilter;
        }
    }
    w.writeAll(buf.written()) catch return error.WriteFailed;
}

pub fn currencySymbol(code: []const u8) ?[]const u8 {
    const table = [_]struct { []const u8, []const u8 }{
        .{ "GBP", "£" }, .{ "EUR", "€" }, .{ "USD", "$" }, .{ "JPY", "¥" },
        .{ "INR", "₹" }, .{ "KRW", "₩" }, .{ "CNY", "¥" }, .{ "AUD", "A$" },
        .{ "CAD", "C$" }, .{ "NZD", "NZ$" }, .{ "HKD", "HK$" }, .{ "SGD", "S$" },
    };
    for (table) |e| if (std.mem.eql(u8, e[0], code)) return e[1];
    return null;
}

/// "-1234.5" with GBP/2 → "-£1,234.50". Unknown codes render as "CHF 1,234.50".
pub fn formatMoney(raw: []const u8, spec: *const VarSpec, with_symbol: bool, w: *std.Io.Writer) !void {
    if (!legend_mod.isDecimal(raw, spec.decimals)) return error.BadValue;
    var s = raw;
    if (s[0] == '-') {
        try w.writeByte('-');
        s = s[1..];
    }
    if (with_symbol) {
        if (currencySymbol(spec.currency)) |sym| {
            try w.writeAll(sym);
        } else {
            try w.writeAll(spec.currency);
            try w.writeByte(' ');
        }
    }
    const dot = std.mem.indexOfScalar(u8, s, '.');
    const int_part = if (dot) |d| s[0..d] else s;
    const frac_part = if (dot) |d| s[d + 1 ..] else "";
    for (int_part, 0..) |c, i| {
        const remaining = int_part.len - i;
        if (i != 0 and remaining % 3 == 0) try w.writeByte(',');
        try w.writeByte(c);
    }
    if (spec.decimals > 0) {
        try w.writeByte('.');
        try w.writeAll(frac_part);
        var pad: usize = spec.decimals - frac_part.len;
        while (pad > 0) : (pad -= 1) try w.writeByte('0');
    }
}

const month_names = [_][]const u8{
    "January", "February", "March",     "April",   "May",      "June",
    "July",    "August",   "September", "October", "November", "December",
};

pub fn formatDate(d: legend_mod.Date, style: anytype, w: *std.Io.Writer) !void {
    const name = month_names[d.month - 1];
    switch (style) {
        .iso => try w.print("{d:0>4}-{d:0>2}-{d:0>2}", .{ d.year, d.month, d.day }),
        .long => try w.print("{d} {s} {d}", .{ d.day, name, d.year }),
        .us => try w.print("{s} {d}, {d}", .{ name, d.day, d.year }),
        .uk => try w.print("{d:0>2}/{d:0>2}/{d:0>4}", .{ d.day, d.month, d.year }),
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

const lg =
    \\[[var]]
    \\name = "OUTCOME"
    \\type = "enum"
    \\values = ["approved", "declined"]
    \\required = true
    \\[[var]]
    \\name = "AMOUNT"
    \\type = "money"
    \\currency = "GBP"
    \\value = "1234.5"
    \\[[var]]
    \\name = "WHEN"
    \\type = "date"
    \\value = "2026-09-16"
    \\[[var]]
    \\name = "URGENT"
    \\type = "bool"
    \\value = "no"
    \\[[var]]
    \\name = "NAME"
    \\value = "ada LOVELACE"
    \\[[var]]
    \\name = "STEP"
    \\by = "OUTCOME"
    \\[var.map]
    \\approved = "welcome"
    \\declined = "sorry"
    \\[[scenario]]
    \\name = "yes"
    \\[scenario.set]
    \\OUTCOME = "approved"
    \\[[scenario]]
    \\name = "no"
    \\[scenario.set]
    \\OUTCOME = "declined"
    \\URGENT = "true"
;

fn renderWith(src: []const u8, scenario: ?[]const u8, overrides: []const KV) ![]u8 {
    var d = Diag{};
    var l = try Legend.load(testing.allocator, lg, &d);
    defer l.deinit();
    var t = try template.parse(testing.allocator, src, .{}, &d);
    defer t.deinit();
    var b = try resolve(testing.allocator, &l, scenario, &.{}, overrides, &d);
    defer b.deinit(testing.allocator);
    return renderAlloc(testing.allocator, &t, &l, &b, &d);
}

test "types format by default" {
    const out = try renderWith("{AMOUNT} {AMOUNT|plain} {AMOUNT|raw} {WHEN} {WHEN|long} {WHEN|us} {WHEN|uk} {URGENT}", "yes", &.{});
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("£1,234.50 1,234.50 1234.5 2026-09-16 16 September 2026 September 16, 2026 16/09/2026 false", out);
}

test "text filters chain" {
    const out = try renderWith("{NAME|title}|{NAME|upper}|{NAME|lower}|{WHEN|long|upper}", "yes", &.{});
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("Ada Lovelace|ADA LOVELACE|ada lovelace|16 SEPTEMBER 2026", out);
}

test "scenario drives dependent var and blocks" {
    const a = try renderWith("{STEP}{?OUTCOME=approved} A{:} D{/}{?URGENT} !{/}", "yes", &.{});
    defer testing.allocator.free(a);
    try testing.expectEqualStrings("welcome A", a);
    const b = try renderWith("{STEP}{?OUTCOME=approved} A{:} D{/}{?URGENT} !{/}", "no", &.{});
    defer testing.allocator.free(b);
    try testing.expectEqualStrings("sorry D !", b);
}

test "overrides beat scenario and are type-checked" {
    const a = try renderWith("{OUTCOME}/{STEP}", "yes", &.{.{ .key = "OUTCOME", .value = "declined" }});
    defer testing.allocator.free(a);
    try testing.expectEqualStrings("declined/sorry", a);
    try testing.expectError(error.BadValue, renderWith("{OUTCOME}", "yes", &.{.{ .key = "OUTCOME", .value = "maybe" }}));
    try testing.expectError(error.UnknownVariable, renderWith("{OUTCOME}", "yes", &.{.{ .key = "NOPE", .value = "1" }}));
    try testing.expectError(error.BadValue, renderWith("{AMOUNT}", "yes", &.{.{ .key = "AMOUNT", .value = "12.345" }}));
}

test "missing required, unknown scenario, unbound placeholder, unknown filter" {
    try testing.expectError(error.MissingRequired, renderWith("x", null, &.{}));
    try testing.expectError(error.UnknownScenario, renderWith("x", "nope", &.{}));
    try testing.expectError(error.MissingVariable, renderWith("{GHOST}", "yes", &.{}));
    try testing.expectError(error.UnknownFilter, renderWith("{NAME|shout}", "yes", &.{}));
}

test "money formatting edge cases" {
    var d = Diag{};
    var l = try Legend.load(testing.allocator, lg, &d);
    defer l.deinit();
    const spec = l.find("AMOUNT").?;
    var buf = std.Io.Writer.Allocating.init(testing.allocator);
    defer buf.deinit();
    try formatMoney("0", spec, true, &buf.writer);
    try buf.writer.writeByte(' ');
    try formatMoney("-999", spec, true, &buf.writer);
    try buf.writer.writeByte(' ');
    try formatMoney("1000000.05", spec, false, &buf.writer);
    try testing.expectEqualStrings("£0.00 -£999.00 1,000,000.05", buf.written());
}

test "untyped render without a legend" {
    var d = Diag{};
    var t = try template.parse(testing.allocator, "hi {WHO|upper}{?FLAG} yes{/}", .{}, &d);
    defer t.deinit();
    var b = Bindings{};
    defer b.deinit(testing.allocator);
    try b.put(testing.allocator, "WHO", "bob");
    try b.put(testing.allocator, "FLAG", "");
    const out = try renderAlloc(testing.allocator, &t, null, &b, &d);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("hi BOB", out);
}
