//! The legend: a typed table of variables, their candidate values and named
//! scenarios, loaded from TOML.
//!
//! ```toml
//! [legend]
//! name = "Decision letter"          # optional
//! open = "{"                        # optional delimiters
//! close = "}"
//!
//! [[var]]
//! name = "OUTCOME"
//! type = "enum"                     # string | enum | int | money | date | bool
//! values = ["approved", "declined"] # enum members; for other types, the
//!                                   # candidate list used by sequence/matrix
//! required = true                   # must be bound by a scenario or --set
//!
//! [[var]]
//! name = "AMOUNT"
//! type = "money"
//! currency = "GBP"                  # renders 1234.5 as £1,234.50
//! value = "1234.50"                 # default binding
//!
//! [[var]]
//! name = "NEXT_STEP"
//! type = "string"
//! by = "OUTCOME"                    # value chosen by another variable
//! [var.map]
//! approved = "Your welcome pack follows."
//! declined = "You may re-apply in six months."
//!
//! [[scenario]]
//! name = "approved"
//! [scenario.set]
//! OUTCOME = "approved"
//! ```
//!
//! Every value is held as a string; the type decides validation and default
//! formatting. TOML integers, floats, booleans and dates are converted to
//! their canonical text on load.

const std = @import("std");
const toml = @import("zig_toml");
const Diag = @import("diag.zig").Diag;
const template = @import("template.zig");

pub const VarType = enum {
    string,
    enum_,
    int,
    money,
    date,
    bool,

    pub fn parse(s: []const u8) ?VarType {
        const names = [_]struct { []const u8, VarType }{
            .{ "string", .string }, .{ "enum", .enum_ },  .{ "int", .int },
            .{ "money", .money },   .{ "date", .date },   .{ "bool", .bool },
        };
        for (names) |n| if (std.mem.eql(u8, s, n[0])) return n[1];
        return null;
    }

    pub fn label(self: VarType) []const u8 {
        return switch (self) {
            .string => "string",
            .enum_ => "enum",
            .int => "int",
            .money => "money",
            .date => "date",
            .bool => "bool",
        };
    }
};

pub const KV = struct { key: []const u8, value: []const u8 };

pub const VarSpec = struct {
    name: []const u8,
    kind: VarType = .string,
    description: []const u8 = "",
    /// Enum members, or the candidate list for sequence/matrix plans.
    values: []const []const u8 = &.{},
    /// Default binding.
    default: ?[]const u8 = null,
    required: bool = false,
    /// money: ISO 4217 code. Known codes render as a symbol.
    currency: []const u8 = "",
    /// money: fractional digits.
    decimals: u8 = 2,
    /// int: bounds.
    min: ?i64 = null,
    max: ?i64 = null,
    /// Dependent variable: the value is `map[binding of by]`.
    by: ?[]const u8 = null,
    map: []const KV = &.{},

    pub fn mapLookup(self: *const VarSpec, key: []const u8) ?[]const u8 {
        for (self.map) |kv| if (std.mem.eql(u8, kv.key, key)) return kv.value;
        return null;
    }

    pub fn hasValue(self: *const VarSpec, v: []const u8) bool {
        for (self.values) |m| if (std.mem.eql(u8, m, v)) return true;
        return false;
    }
};

pub const Scenario = struct {
    name: []const u8,
    /// Sorted by key so output is stable regardless of TOML hash order.
    set: []const KV,
};

pub const LoadError = error{
    OutOfMemory,
    InvalidToml,
    BadLegend,
};

pub const Legend = struct {
    arena: std.heap.ArenaAllocator,
    name: []const u8 = "",
    delims: template.Delims = .{},
    /// Declaration order.
    vars: []const VarSpec = &.{},
    scenarios: []const Scenario = &.{},

    pub fn deinit(self: *Legend) void {
        self.arena.deinit();
    }

    pub fn find(self: *const Legend, name: []const u8) ?*const VarSpec {
        for (self.vars) |*v| if (std.mem.eql(u8, v.name, name)) return v;
        return null;
    }

    pub fn scenario(self: *const Legend, name: []const u8) ?*const Scenario {
        for (self.scenarios) |*s| if (std.mem.eql(u8, s.name, name)) return s;
        return null;
    }

    pub fn load(gpa: std.mem.Allocator, src: []const u8, diag: *Diag) LoadError!Legend {
        var root = toml.parseToml(gpa, src) catch |err| {
            diag.set(0, "legend is not valid TOML: {s}", .{@errorName(err)});
            return error.InvalidToml;
        };
        defer root.deinit(gpa);

        var arena = std.heap.ArenaAllocator.init(gpa);
        errdefer arena.deinit();
        const a = arena.allocator();
        // The arena is moved into the legend only at the end: a copy taken
        // now would not see the buffers allocated below.
        var legend = Legend{ .arena = undefined };

        if (root.get("legend")) |lv| {
            const lt = try expectTable(lv, "legend", diag);
            if (lt.get("name")) |v| legend.name = try dupeString(a, v, "legend.name", diag);
            if (lt.get("open")) |v| legend.delims.open = try dupeString(a, v, "legend.open", diag);
            if (lt.get("close")) |v| legend.delims.close = try dupeString(a, v, "legend.close", diag);
            try rejectUnknownKeys(lt, &.{ "name", "open", "close" }, "legend", diag);
        }

        var vars: std.ArrayList(VarSpec) = .empty;
        if (root.get("var")) |vv| {
            const arr = try expectArray(vv, "var", diag);
            for (arr.items.items, 0..) |item, idx| {
                const t = try expectTable(item, "var", diag);
                const spec = try parseVar(a, t, idx, diag);
                for (vars.items) |existing| {
                    if (std.mem.eql(u8, existing.name, spec.name)) {
                        diag.set(0, "variable '{s}' declared twice", .{spec.name});
                        return error.BadLegend;
                    }
                }
                try vars.append(a, spec);
            }
        }
        legend.vars = try vars.toOwnedSlice(a);

        // `by` must name a declared, non-dependent variable so resolution
        // needs a single pass.
        for (legend.vars) |v| {
            if (v.by) |by| {
                const dep = legend.find(by) orelse {
                    diag.set(0, "variable '{s}' depends on undeclared '{s}'", .{ v.name, by });
                    return error.BadLegend;
                };
                if (dep.by != null) {
                    diag.set(0, "variable '{s}' depends on '{s}', which is itself dependent; chains are not supported", .{ v.name, by });
                    return error.BadLegend;
                }
                if (dep.kind == .enum_) {
                    for (v.map) |kv| if (!dep.hasValue(kv.key)) {
                        diag.set(0, "variable '{s}' maps '{s}', which is not a value of enum '{s}'", .{ v.name, kv.key, by });
                        return error.BadLegend;
                    };
                }
            }
        }

        var scenarios: std.ArrayList(Scenario) = .empty;
        if (root.get("scenario")) |sv| {
            const arr = try expectArray(sv, "scenario", diag);
            for (arr.items.items, 0..) |item, idx| {
                const t = try expectTable(item, "scenario", diag);
                const name_v = t.get("name") orelse {
                    diag.set(0, "scenario #{d} has no name", .{idx + 1});
                    return error.BadLegend;
                };
                const name = try dupeString(a, name_v, "scenario.name", diag);
                if (!isSafeName(name)) {
                    diag.set(0, "scenario name '{s}' must be letters, digits, '_' or '-'", .{name});
                    return error.BadLegend;
                }
                for (scenarios.items) |existing| if (std.mem.eql(u8, existing.name, name)) {
                    diag.set(0, "scenario '{s}' declared twice", .{name});
                    return error.BadLegend;
                };
                try rejectUnknownKeys(t, &.{ "name", "set" }, "scenario", diag);
                var set: []const KV = &.{};
                if (t.get("set")) |setv| {
                    const st = try expectTable(setv, "scenario.set", diag);
                    set = try tableToKVs(a, st, "scenario.set", diag);
                    for (set) |kv| {
                        const spec = legend.find(kv.key) orelse {
                            diag.set(0, "scenario '{s}' sets undeclared variable '{s}'", .{ name, kv.key });
                            return error.BadLegend;
                        };
                        checkValue(spec, kv.value, diag) catch return error.BadLegend;
                    }
                }
                try scenarios.append(a, .{ .name = name, .set = set });
            }
        }
        legend.scenarios = try scenarios.toOwnedSlice(a);

        try rejectUnknownKeys(&root, &.{ "legend", "var", "scenario" }, "top level", diag);
        legend.arena = arena;
        return legend;
    }
};

/// Scenario and file names: no path separators, nothing hidden.
pub fn isSafeName(s: []const u8) bool {
    if (s.len == 0 or s.len > 64) return false;
    for (s) |c| if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '-')) return false;
    return true;
}

fn parseVar(a: std.mem.Allocator, t: *const toml.Table, idx: usize, diag: *Diag) LoadError!VarSpec {
    const name_v = t.get("name") orelse {
        diag.set(0, "var #{d} has no name", .{idx + 1});
        return error.BadLegend;
    };
    var spec = VarSpec{ .name = try dupeString(a, name_v, "var.name", diag) };
    if (!template.isValidName(spec.name)) {
        diag.set(0, "variable name '{s}' is not a valid placeholder name", .{spec.name});
        return error.BadLegend;
    }
    try rejectUnknownKeys(t, &.{ "name", "type", "description", "values", "value", "required", "currency", "decimals", "min", "max", "by", "map" }, spec.name, diag);

    if (t.get("type")) |v| {
        const s = try dupeString(a, v, "type", diag);
        spec.kind = VarType.parse(s) orelse {
            diag.set(0, "variable '{s}': unknown type '{s}' (string, enum, int, money, date, bool)", .{ spec.name, s });
            return error.BadLegend;
        };
    }
    if (t.get("description")) |v| spec.description = try dupeString(a, v, "description", diag);
    if (t.get("currency")) |v| spec.currency = try dupeString(a, v, "currency", diag);
    if (t.get("required")) |v| spec.required = try expectBool(v, "required", diag);
    if (t.get("decimals")) |v| {
        const d = try expectInt(v, "decimals", diag);
        if (d < 0 or d > 6) {
            diag.set(0, "variable '{s}': decimals must be 0..6", .{spec.name});
            return error.BadLegend;
        }
        spec.decimals = @intCast(d);
    }
    if (t.get("min")) |v| spec.min = try expectInt(v, "min", diag);
    if (t.get("max")) |v| spec.max = try expectInt(v, "max", diag);
    if (t.get("by")) |v| spec.by = try dupeString(a, v, "by", diag);
    if (t.get("map")) |v| {
        const mt = try expectTable(v, "map", diag);
        spec.map = try tableToKVs(a, mt, "map", diag);
    }
    if ((spec.by == null) != (spec.map.len == 0)) {
        diag.set(0, "variable '{s}': 'by' and 'map' go together", .{spec.name});
        return error.BadLegend;
    }
    if (t.get("values")) |v| {
        const arr = try expectArray(v, "values", diag);
        var list: std.ArrayList([]const u8) = .empty;
        for (arr.items.items) |item| {
            const s = try valueToString(a, item, "values", diag);
            for (list.items) |existing| if (std.mem.eql(u8, existing, s)) {
                diag.set(0, "variable '{s}': duplicate value '{s}'", .{ spec.name, s });
                return error.BadLegend;
            };
            try list.append(a, s);
        }
        spec.values = try list.toOwnedSlice(a);
    }
    if (spec.kind == .enum_ and spec.values.len == 0) {
        diag.set(0, "enum variable '{s}' has no values", .{spec.name});
        return error.BadLegend;
    }
    if (spec.kind == .money and spec.currency.len == 0) {
        diag.set(0, "money variable '{s}' has no currency", .{spec.name});
        return error.BadLegend;
    }
    // Validate candidates, the default and the dependent map against the type.
    for (spec.values) |val| checkValue(&spec, val, diag) catch return error.BadLegend;
    if (t.get("value")) |v| {
        const s = try valueToString(a, v, "value", diag);
        checkValue(&spec, s, diag) catch return error.BadLegend;
        spec.default = s;
    }
    for (spec.map) |kv| checkValue(&spec, kv.value, diag) catch return error.BadLegend;
    return spec;
}

// ---------------------------------------------------------------------------
// Value validation and canonicalisation
// ---------------------------------------------------------------------------

pub const ValueError = error{BadValue};

/// Validate `v` against the spec's type. Errors fill `diag`.
pub fn checkValue(spec: *const VarSpec, v: []const u8, diag: *Diag) ValueError!void {
    switch (spec.kind) {
        .string => {},
        .enum_ => if (!spec.hasValue(v)) {
            diag.set(0, "'{s}' is not a value of enum '{s}'", .{ v, spec.name });
            return error.BadValue;
        },
        .int => {
            const n = std.fmt.parseInt(i64, v, 10) catch {
                diag.set(0, "'{s}' is not an integer for '{s}'", .{ v, spec.name });
                return error.BadValue;
            };
            if (spec.min) |m| if (n < m) {
                diag.set(0, "{d} is below the minimum {d} for '{s}'", .{ n, m, spec.name });
                return error.BadValue;
            };
            if (spec.max) |m| if (n > m) {
                diag.set(0, "{d} is above the maximum {d} for '{s}'", .{ n, m, spec.name });
                return error.BadValue;
            };
        },
        .money => if (!isDecimal(v, spec.decimals)) {
            diag.set(0, "'{s}' is not an amount with at most {d} decimals for '{s}'", .{ v, spec.decimals, spec.name });
            return error.BadValue;
        },
        .date => if (parseDate(v) == null) {
            diag.set(0, "'{s}' is not a calendar date (YYYY-MM-DD) for '{s}'", .{ v, spec.name });
            return error.BadValue;
        },
        .bool => if (parseBool(v) == null) {
            diag.set(0, "'{s}' is not a boolean for '{s}'", .{ v, spec.name });
            return error.BadValue;
        },
    }
}

/// `-?digits(.digits)?` with at most `decimals` fractional digits.
pub fn isDecimal(v: []const u8, decimals: u8) bool {
    var s = v;
    if (s.len > 0 and s[0] == '-') s = s[1..];
    if (s.len == 0) return false;
    const dot = std.mem.indexOfScalar(u8, s, '.');
    const int_part = if (dot) |d| s[0..d] else s;
    const frac_part = if (dot) |d| s[d + 1 ..] else "";
    if (int_part.len == 0 or int_part.len > 18) return false;
    for (int_part) |c| if (!std.ascii.isDigit(c)) return false;
    if (dot != null and (frac_part.len == 0 or frac_part.len > decimals)) return false;
    for (frac_part) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}

pub const Date = struct { year: u16, month: u8, day: u8 };

pub fn parseDate(v: []const u8) ?Date {
    if (v.len != 10 or v[4] != '-' or v[7] != '-') return null;
    const y = std.fmt.parseInt(u16, v[0..4], 10) catch return null;
    const m = std.fmt.parseInt(u8, v[5..7], 10) catch return null;
    const d = std.fmt.parseInt(u8, v[8..10], 10) catch return null;
    if (m < 1 or m > 12 or d < 1) return null;
    if (d > daysInMonth(y, m)) return null;
    return .{ .year = y, .month = m, .day = d };
}

pub fn daysInMonth(year: u16, month: u8) u8 {
    return switch (month) {
        1, 3, 5, 7, 8, 10, 12 => 31,
        4, 6, 9, 11 => 30,
        2 => if ((year % 4 == 0 and year % 100 != 0) or year % 400 == 0) @as(u8, 29) else 28,
        else => 0,
    };
}

pub fn parseBool(v: []const u8) ?bool {
    const yes = [_][]const u8{ "true", "yes", "1", "on" };
    const no = [_][]const u8{ "false", "no", "0", "off" };
    for (yes) |s| if (std.ascii.eqlIgnoreCase(v, s)) return true;
    for (no) |s| if (std.ascii.eqlIgnoreCase(v, s)) return false;
    return null;
}

// ---------------------------------------------------------------------------
// TOML helpers
// ---------------------------------------------------------------------------

fn expectTable(v: toml.Value, what: []const u8, diag: *Diag) LoadError!*const toml.Table {
    return switch (v) {
        .table => |t| t,
        else => {
            diag.set(0, "'{s}' must be a table", .{what});
            return error.BadLegend;
        },
    };
}

fn expectArray(v: toml.Value, what: []const u8, diag: *Diag) LoadError!*const toml.Array {
    return switch (v) {
        .array => |*arr| arr,
        else => {
            diag.set(0, "'{s}' must be an array", .{what});
            return error.BadLegend;
        },
    };
}

fn expectBool(v: toml.Value, what: []const u8, diag: *Diag) LoadError!bool {
    return switch (v) {
        .boolean => |b| b,
        else => {
            diag.set(0, "'{s}' must be true or false", .{what});
            return error.BadLegend;
        },
    };
}

fn expectInt(v: toml.Value, what: []const u8, diag: *Diag) LoadError!i64 {
    return switch (v) {
        .integer => |i| i,
        else => {
            diag.set(0, "'{s}' must be an integer", .{what});
            return error.BadLegend;
        },
    };
}

fn dupeString(a: std.mem.Allocator, v: toml.Value, what: []const u8, diag: *Diag) LoadError![]const u8 {
    return switch (v) {
        .string => |s| try a.dupe(u8, s),
        else => {
            diag.set(0, "'{s}' must be a string", .{what});
            return error.BadLegend;
        },
    };
}

/// Scalars become their canonical text. Floats are printed with `{d}`, so
/// `1234.5` becomes "1234.5"; money values are better written as strings.
fn valueToString(a: std.mem.Allocator, v: toml.Value, what: []const u8, diag: *Diag) LoadError![]const u8 {
    return switch (v) {
        .string => |s| try a.dupe(u8, s),
        .integer => |i| try std.fmt.allocPrint(a, "{d}", .{i}),
        .float => |f| try std.fmt.allocPrint(a, "{d}", .{f}),
        .boolean => |b| if (b) "true" else "false",
        .datetime => |s| try a.dupe(u8, s),
        .array, .table => {
            diag.set(0, "'{s}' must be a scalar", .{what});
            return error.BadLegend;
        },
    };
}

fn tableToKVs(a: std.mem.Allocator, t: *const toml.Table, what: []const u8, diag: *Diag) LoadError![]const KV {
    var out = try a.alloc(KV, t.count());
    var it = @constCast(t).iterator();
    var i: usize = 0;
    while (it.next()) |e| : (i += 1) {
        out[i] = .{
            .key = try a.dupe(u8, e.key_ptr.*),
            .value = try valueToString(a, e.value_ptr.*, what, diag),
        };
    }
    std.mem.sort(KV, out, {}, struct {
        fn lt(_: void, x: KV, y: KV) bool {
            return std.mem.lessThan(u8, x.key, y.key);
        }
    }.lt);
    return out;
}

fn rejectUnknownKeys(t: *const toml.Table, allowed: []const []const u8, where: []const u8, diag: *Diag) LoadError!void {
    var it = @constCast(t).iterator();
    while (it.next()) |e| {
        const k = e.key_ptr.*;
        var ok = false;
        for (allowed) |al| if (std.mem.eql(u8, al, k)) {
            ok = true;
        };
        if (!ok) {
            diag.set(0, "unknown key '{s}' in {s}", .{ k, where });
            return error.BadLegend;
        }
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

const sample =
    \\[legend]
    \\name = "t"
    \\[[var]]
    \\name = "OUTCOME"
    \\type = "enum"
    \\values = ["approved", "declined"]
    \\required = true
    \\[[var]]
    \\name = "AMOUNT"
    \\type = "money"
    \\currency = "GBP"
    \\value = "1234.50"
    \\[[var]]
    \\name = "N"
    \\type = "int"
    \\min = 1
    \\max = 10
    \\values = [1, 5, 10]
    \\[[var]]
    \\name = "STEP"
    \\by = "OUTCOME"
    \\[var.map]
    \\approved = "welcome"
    \\declined = "sorry"
    \\[[scenario]]
    \\name = "ok"
    \\[scenario.set]
    \\OUTCOME = "approved"
    \\AMOUNT = "50"
;

test "load sample legend" {
    var d = Diag{};
    var l = try Legend.load(testing.allocator, sample, &d);
    defer l.deinit();
    try testing.expectEqualStrings("t", l.name);
    try testing.expectEqual(@as(usize, 4), l.vars.len);
    try testing.expectEqualStrings("OUTCOME", l.vars[0].name);
    try testing.expectEqual(VarType.enum_, l.vars[0].kind);
    try testing.expect(l.vars[0].required);
    try testing.expectEqualStrings("1234.50", l.vars[1].default.?);
    try testing.expectEqualStrings("5", l.vars[2].values[1]);
    try testing.expectEqualStrings("sorry", l.vars[3].mapLookup("declined").?);
    const s = l.scenario("ok").?;
    try testing.expectEqualStrings("50", s.set[0].value); // sorted: AMOUNT, OUTCOME
    try testing.expectEqualStrings("approved", s.set[1].value);
}

fn expectBad(src: []const u8, needle: []const u8) !void {
    var d = Diag{};
    try testing.expectError(error.BadLegend, Legend.load(testing.allocator, src, &d));
    if (std.mem.indexOf(u8, d.text(), needle) == null) {
        std.debug.print("diag was: {s}\n", .{d.text()});
        return error.TestUnexpectedResult;
    }
}

test "legend rejects bad shapes" {
    try expectBad("[[var]]\ntype = \"int\"\n", "has no name");
    try expectBad("[[var]]\nname = \"A\"\ntype = \"list\"\n", "unknown type");
    try expectBad("[[var]]\nname = \"A\"\ntype = \"enum\"\n", "no values");
    try expectBad("[[var]]\nname = \"A\"\ntype = \"money\"\n", "no currency");
    try expectBad("[[var]]\nname = \"A\"\ntype = \"int\"\nvalue = \"x\"\n", "not an integer");
    try expectBad("[[var]]\nname = \"A\"\ntype = \"date\"\nvalue = \"2026-02-30\"\n", "calendar date");
    try expectBad("[[var]]\nname = \"A\"\ntype = \"enum\"\nvalues = [\"x\", \"x\"]\n", "duplicate value");
    try expectBad("[[var]]\nname = \"A\"\n[[var]]\nname = \"A\"\n", "declared twice");
    try expectBad("[[var]]\nname = \"A\"\nby = \"B\"\n[var.map]\nx = \"1\"\n", "undeclared 'B'");
    try expectBad("[[var]]\nname = \"A\"\ncolour = 1\n", "unknown key 'colour'");
    try expectBad("[[scenario]]\nname = \"s\"\n[scenario.set]\nZ = \"1\"\n", "undeclared variable 'Z'");
    try expectBad("[[scenario]]\nname = \"../x\"\n", "scenario name");
    try expectBad("[[var]]\nname = \"O\"\ntype = \"enum\"\nvalues = [\"a\"]\n[[var]]\nname = \"S\"\nby = \"O\"\n[var.map]\nzz = \"1\"\n", "not a value of enum");
}

test "invalid toml" {
    var d = Diag{};
    try testing.expectError(error.InvalidToml, Legend.load(testing.allocator, "[[var]\n", &d));
}

test "value validators" {
    try testing.expect(isDecimal("0", 2));
    try testing.expect(isDecimal("-12.5", 2));
    try testing.expect(!isDecimal("12.", 2));
    try testing.expect(!isDecimal("12.345", 2));
    try testing.expect(!isDecimal("1,000", 2));
    try testing.expect(isDecimal("7", 0));
    try testing.expect(!isDecimal("7.0", 0));
    try testing.expect(parseDate("2024-02-29") != null);
    try testing.expect(parseDate("2023-02-29") == null);
    try testing.expect(parseDate("2026-13-01") == null);
    try testing.expect(parseDate("26-01-01") == null);
    try testing.expectEqual(@as(?bool, true), parseBool("Yes"));
    try testing.expectEqual(@as(?bool, false), parseBool("0"));
    try testing.expectEqual(@as(?bool, null), parseBool("maybe"));
}
