// Copyright (c) 2025 QUANTUM ENCODING LTD
// Licensed under the MIT License.

//! DOCX numbering parser: which lists are numbered and which are bulleted.
//!
//! A list paragraph's `w:numPr` names a `w:numId` and a level (`w:ilvl`).
//! In word/numbering.xml the `w:num` with that id points at a
//! `w:abstractNum`, whose `w:lvl` for that level gives the marker format
//! (`w:numFmt`: "bullet", "decimal", "lowerLetter", "none", …) and the first
//! number (`w:start`). A `w:lvlOverride` inside the `w:num` may replace a
//! level's definition (`w:lvl`) or only its first number
//! (`w:startOverride`); either wins over the abstract definition.
//! numId 0 means "no numbering" (ECMA-376 Part 1, 17.9.18).

const std = @import("std");
const xml = @import("xml.zig");
const test_alloc = @import("test_alloc.zig");

pub const LevelFormat = enum {
    /// A visible bullet character.
    bullet,
    /// Any counted format: decimal, letters, roman numerals, ordinals.
    ordered,
    /// No visible marker (`numFmt="none"`).
    none,
};

pub const Level = struct {
    format: LevelFormat = .ordered,
    start: u32 = 1,
};

const AbstractLevel = struct {
    abstract_id: u32,
    ilvl: u8,
    level: Level,
};

const NumRef = struct {
    num_id: u32,
    abstract_id: u32,
};

const Override = struct {
    num_id: u32,
    ilvl: u8,
    /// The level redefined by the override; null when only the start changes.
    level: ?Level,
    start: ?u32,
};

pub const Numbering = struct {
    abstract_levels: []AbstractLevel = &.{},
    nums: []NumRef = &.{},
    overrides: []Override = &.{},

    pub fn deinit(self: *Numbering, allocator: std.mem.Allocator) void {
        allocator.free(self.abstract_levels);
        allocator.free(self.nums);
        allocator.free(self.overrides);
        self.* = .{};
    }

    /// The level a list paragraph uses, or null when the numbering part does
    /// not define it (the paragraph is then a list item of unknown kind).
    pub fn level(self: *const Numbering, num_id: u32, ilvl: u8) ?Level {
        var start_override: ?u32 = null;
        for (self.overrides) |o| {
            if (o.num_id != num_id or o.ilvl != ilvl) continue;
            if (o.level) |l| return if (o.start) |s| .{ .format = l.format, .start = s } else l;
            start_override = o.start;
        }
        const abstract_id = for (self.nums) |n| {
            if (n.num_id == num_id) break n.abstract_id;
        } else return null;
        for (self.abstract_levels) |a| {
            if (a.abstract_id == abstract_id and a.ilvl == ilvl) {
                return .{ .format = a.level.format, .start = start_override orelse a.level.start };
            }
        }
        return null;
    }
};

fn formatOf(num_fmt: []const u8) LevelFormat {
    if (std.mem.eql(u8, num_fmt, "bullet")) return .bullet;
    if (std.mem.eql(u8, num_fmt, "none")) return .none;
    return .ordered;
}

fn parseU32(attrs: []const xml.Attr, name: []const u8) ?u32 {
    const v = xml.getAttr(attrs, name) orelse return null;
    return std.fmt.parseInt(u32, v, 10) catch null;
}

fn parseU8(attrs: []const xml.Attr, name: []const u8) ?u8 {
    const v = xml.getAttr(attrs, name) orelse return null;
    return std.fmt.parseInt(u8, v, 10) catch null;
}

/// Reads word/numbering.xml. Malformed ids or levels are skipped, never fatal:
/// the paragraphs that name them read as list items of unknown kind.
pub fn parseNumbering(allocator: std.mem.Allocator, xml_data: []const u8) !Numbering {
    var abstract_levels: std.ArrayListUnmanaged(AbstractLevel) = .empty;
    errdefer abstract_levels.deinit(allocator);
    var nums: std.ArrayListUnmanaged(NumRef) = .empty;
    errdefer nums.deinit(allocator);
    var overrides: std.ArrayListUnmanaged(Override) = .empty;
    errdefer overrides.deinit(allocator);

    // Where the parser is: inside an abstractNum (its id), a num (its id),
    // a lvlOverride (its level), and the lvl being read.
    var abstract_id: ?u32 = null;
    var num_id: ?u32 = null;
    var override_ilvl: ?u8 = null;
    var override_start: ?u32 = null;
    var override_level: ?Level = null;
    var lvl_ilvl: ?u8 = null;
    var lvl: Level = .{};

    var parser = xml.XmlParser.init(xml_data);
    while (parser.next()) |event| {
        switch (event) {
            .element_start => |es| {
                const name = es.name;
                if (std.mem.eql(u8, name, "abstractNum")) {
                    abstract_id = parseU32(es.attrs, "abstractNumId");
                } else if (std.mem.eql(u8, name, "num")) {
                    num_id = parseU32(es.attrs, "numId");
                } else if (std.mem.eql(u8, name, "abstractNumId") and num_id != null) {
                    if (parseU32(es.attrs, "val")) |a| {
                        try nums.append(allocator, .{ .num_id = num_id.?, .abstract_id = a });
                    }
                } else if (std.mem.eql(u8, name, "lvlOverride") and num_id != null) {
                    override_ilvl = parseU8(es.attrs, "ilvl");
                    override_start = null;
                    override_level = null;
                    if (es.self_closing) override_ilvl = null;
                } else if (std.mem.eql(u8, name, "startOverride") and override_ilvl != null) {
                    override_start = parseU32(es.attrs, "val");
                } else if (std.mem.eql(u8, name, "lvl")) {
                    lvl_ilvl = parseU8(es.attrs, "ilvl");
                    lvl = .{};
                } else if (std.mem.eql(u8, name, "numFmt") and lvl_ilvl != null) {
                    if (xml.getAttr(es.attrs, "val")) |v| lvl.format = formatOf(v);
                } else if (std.mem.eql(u8, name, "start") and lvl_ilvl != null) {
                    if (parseU32(es.attrs, "val")) |s| lvl.start = s;
                }
            },
            .element_end => |name| {
                if (std.mem.eql(u8, name, "lvl")) {
                    if (lvl_ilvl) |ilvl| {
                        if (override_ilvl != null) {
                            override_level = lvl;
                        } else if (abstract_id) |a| {
                            try abstract_levels.append(allocator, .{ .abstract_id = a, .ilvl = ilvl, .level = lvl });
                        }
                    }
                    lvl_ilvl = null;
                } else if (std.mem.eql(u8, name, "lvlOverride")) {
                    if (override_ilvl) |ilvl| {
                        if (override_level != null or override_start != null) {
                            try overrides.append(allocator, .{
                                .num_id = num_id.?,
                                .ilvl = ilvl,
                                .level = override_level,
                                .start = override_start,
                            });
                        }
                    }
                    override_ilvl = null;
                } else if (std.mem.eql(u8, name, "abstractNum")) {
                    abstract_id = null;
                } else if (std.mem.eql(u8, name, "num")) {
                    num_id = null;
                }
            },
            .text => {},
        }
    }

    const al = try abstract_levels.toOwnedSlice(allocator);
    errdefer allocator.free(al);
    const ns = try nums.toOwnedSlice(allocator);
    errdefer allocator.free(ns);
    return .{ .abstract_levels = al, .nums = ns, .overrides = try overrides.toOwnedSlice(allocator) };
}

test "decimal, bullet and none levels, a start, and both kinds of override" {
    const data =
        \\<w:numbering xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
        \\  <w:abstractNum w:abstractNumId="0">
        \\    <w:lvl w:ilvl="0"><w:start w:val="1"/><w:numFmt w:val="decimal"/></w:lvl>
        \\    <w:lvl w:ilvl="1"><w:start w:val="1"/><w:numFmt w:val="bullet"/></w:lvl>
        \\  </w:abstractNum>
        \\  <w:abstractNum w:abstractNumId="1">
        \\    <w:lvl w:ilvl="0"><w:start w:val="4"/><w:numFmt w:val="lowerLetter"/></w:lvl>
        \\    <w:lvl w:ilvl="1"><w:numFmt w:val="none"/></w:lvl>
        \\  </w:abstractNum>
        \\  <w:num w:numId="1"><w:abstractNumId w:val="0"/></w:num>
        \\  <w:num w:numId="2"><w:abstractNumId w:val="1"/></w:num>
        \\  <w:num w:numId="3"><w:abstractNumId w:val="0"/>
        \\    <w:lvlOverride w:ilvl="0"><w:startOverride w:val="7"/></w:lvlOverride>
        \\  </w:num>
        \\  <w:num w:numId="4"><w:abstractNumId w:val="0"/>
        \\    <w:lvlOverride w:ilvl="0"><w:lvl w:ilvl="0"><w:numFmt w:val="bullet"/></w:lvl></w:lvlOverride>
        \\  </w:num>
        \\</w:numbering>
    ;
    var n = try parseNumbering(std.testing.allocator, data);
    defer n.deinit(std.testing.allocator);
    try std.testing.expectEqual(Level{ .format = .ordered, .start = 1 }, n.level(1, 0).?);
    try std.testing.expectEqual(LevelFormat.bullet, n.level(1, 1).?.format);
    try std.testing.expectEqual(Level{ .format = .ordered, .start = 4 }, n.level(2, 0).?);
    try std.testing.expectEqual(LevelFormat.none, n.level(2, 1).?.format);
    try std.testing.expectEqual(Level{ .format = .ordered, .start = 7 }, n.level(3, 0).?);
    try std.testing.expectEqual(LevelFormat.bullet, n.level(4, 0).?.format);
    // Levels and lists the part does not define are unknown, not guessed.
    try std.testing.expectEqual(@as(?Level, null), n.level(1, 5));
    try std.testing.expectEqual(@as(?Level, null), n.level(99, 0));
}

test "an empty or junk numbering part reads as no lists" {
    var n = try parseNumbering(std.testing.allocator, "<w:numbering><w:num w:numId=\"x\"/></w:numbering>");
    defer n.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(?Level, null), n.level(1, 0));
}

test "no leak when an allocation fails part-way" {
    const data =
        \\<w:numbering><w:abstractNum w:abstractNumId="0"><w:lvl w:ilvl="0"><w:numFmt w:val="decimal"/></w:lvl></w:abstractNum>
        \\<w:num w:numId="1"><w:abstractNumId w:val="0"/><w:lvlOverride w:ilvl="0"><w:startOverride w:val="2"/></w:lvlOverride></w:num></w:numbering>
    ;
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn run(a: std.mem.Allocator, d: []const u8) !void {
            // Every growth a fresh allocation, so each run counts the same.
            var no_in_place: test_alloc.NoInPlace = .{ .child = a };
            const na = no_in_place.allocator();
            var n = try parseNumbering(na, d);
            n.deinit(na);
        }
    }.run, .{data});
}
