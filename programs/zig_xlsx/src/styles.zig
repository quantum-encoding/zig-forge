// Copyright (c) 2025 QUANTUM ENCODING LTD
// Licensed under the MIT License.

//! Which cell styles show a number as a date or time.
//!
//! A cell's `s` attribute indexes <cellXfs> in xl/styles.xml; that <xf>'s
//! numFmtId names a number format, either a custom one from <numFmts> or a
//! built-in one. Excel stores dates as serial day numbers, so the format is
//! the only thing that says a number is a date:
//!
//!   <numFmts><numFmt numFmtId="165" formatCode="dd\ mmm\ yyyy"/></numFmts>
//!   <cellXfs><xf numFmtId="0"/><xf numFmtId="165"/><xf numFmtId="14"/></cellXfs>
//!
//! Here styles 1 and 2 are dates. `formatSerial` turns such a serial into
//! ISO 8601 text.

const std = @import("std");
const xml = @import("xml.zig");

pub const DateKind = enum {
    /// A plain number format.
    none,
    date,
    time,
    datetime,
    /// Elapsed time (`[h]:mm:ss`): a span, not a point in time.
    duration,
};

pub const Styles = struct {
    /// The date kind of each <cellXfs> entry, by index.
    xf_kinds: []DateKind,
    allocator: std.mem.Allocator,

    pub const empty: Styles = .{ .xf_kinds = &.{}, .allocator = undefined };

    pub fn parse(allocator: std.mem.Allocator, xml_data: []const u8) !Styles {
        const Custom = struct { id: u32, kind: DateKind };
        var customs: std.ArrayListUnmanaged(Custom) = .empty;
        defer customs.deinit(allocator);
        var xf_ids: std.ArrayListUnmanaged(u32) = .empty;
        defer xf_ids.deinit(allocator);

        var parser = xml.XmlParser.init(xml_data);
        var in_cell_xfs = false;
        while (parser.next()) |event| {
            switch (event) {
                .element_start => |e| {
                    if (std.mem.eql(u8, e.name, "numFmt")) {
                        const id_text = xml.getAttr(e.attrs, "numFmtId") orelse continue;
                        const id = std.fmt.parseInt(u32, id_text, 10) catch continue;
                        const raw = xml.getAttr(e.attrs, "formatCode") orelse continue;
                        const code = try xml.decodeAlloc(allocator, raw);
                        defer allocator.free(code);
                        try customs.append(allocator, .{ .id = id, .kind = classifyFormat(code) });
                    } else if (std.mem.eql(u8, e.name, "cellXfs")) {
                        in_cell_xfs = true;
                    } else if (in_cell_xfs and std.mem.eql(u8, e.name, "xf")) {
                        const id_text = xml.getAttr(e.attrs, "numFmtId") orelse "0";
                        try xf_ids.append(allocator, std.fmt.parseInt(u32, id_text, 10) catch 0);
                    }
                },
                .element_end => |name| {
                    if (std.mem.eql(u8, name, "cellXfs")) in_cell_xfs = false;
                },
                .text => {},
            }
        }

        const kinds = try allocator.alloc(DateKind, xf_ids.items.len);
        for (xf_ids.items, kinds) |id, *k| {
            // A custom format with a built-in id replaces the built-in.
            k.* = for (customs.items) |c| {
                if (c.id == id) break c.kind;
            } else builtinKind(id);
        }
        return .{ .xf_kinds = kinds, .allocator = allocator };
    }

    /// The date kind of the cell style `xf_index` (a cell's `s` attribute).
    pub fn kind(self: *const Styles, xf_index: usize) DateKind {
        return if (xf_index < self.xf_kinds.len) self.xf_kinds[xf_index] else .none;
    }

    pub fn deinit(self: *Styles) void {
        if (self.xf_kinds.len > 0) self.allocator.free(self.xf_kinds);
        self.xf_kinds = &.{};
    }
};

/// The built-in number formats that show dates and times (ECMA-376 Part 1,
/// 18.8.30): 14 `mm-dd-yy`, 15 `d-mmm-yy`, 16 `d-mmm`, 17 `mmm-yy`,
/// 18 `h:mm AM/PM`, 19 `h:mm:ss AM/PM`, 20 `h:mm`, 21 `h:mm:ss`,
/// 22 `m/d/yy h:mm`, 45 `mm:ss`, 46 `[h]:mm:ss`, 47 `mmss.0`.
pub fn builtinKind(id: u32) DateKind {
    return switch (id) {
        14...17 => .date,
        18...21, 45, 47 => .time,
        22 => .datetime,
        46 => .duration,
        else => .none,
    };
}

/// Whether a format code shows a number as a date or time, judged on its
/// first section (the one for positive numbers). Quoted literals, escaped
/// (`\x`), padding (`_x`) and fill (`*x`) characters and bracketed colours,
/// conditions and locales are not tokens; `[h]`, `[mm]` and `[ss]` are
/// elapsed-time tokens. `d` and `y` are date tokens, `h` and `s` time
/// tokens, and `m` alone (as in `mmm`) a month.
pub fn classifyFormat(code: []const u8) DateKind {
    var has_date = false;
    var has_time = false;
    var has_m = false;
    var elapsed = false;
    var i: usize = 0;
    while (i < code.len) : (i += 1) {
        const c = code[i];
        switch (c) {
            ';' => break,
            '"' => {
                i += 1;
                while (i < code.len and code[i] != '"') i += 1;
            },
            '\\', '_', '*' => i += 1,
            '[' => {
                const close = std.mem.indexOfScalarPos(u8, code, i + 1, ']') orelse break;
                const inner = code[i + 1 .. close];
                if (isElapsedToken(inner)) {
                    elapsed = true;
                }
                i = close;
            },
            else => switch (std.ascii.toLower(c)) {
                'd', 'y' => has_date = true,
                'h', 's' => has_time = true,
                'm' => has_m = true,
                else => {},
            },
        }
    }
    if (elapsed) return .duration;
    if (has_date and has_time) return .datetime;
    if (has_date) return .date;
    if (has_time) return .time;
    if (has_m) return .date;
    return .none;
}

/// `[h]`, `[hh]`, `[m]`, `[mm]`, `[s]`, `[ss]` (any case) without the brackets.
fn isElapsedToken(inner: []const u8) bool {
    if (inner.len == 0) return false;
    const first = std.ascii.toLower(inner[0]);
    if (first != 'h' and first != 'm' and first != 's') return false;
    for (inner) |ch| if (std.ascii.toLower(ch) != first) return false;
    return true;
}

const ms_per_day: i64 = 86_400_000;
/// Serial 2958466 is 10000-01-01, past the last date Excel shows.
const max_serial: f64 = 2958466.0;
/// Days from 1970-01-01 back to each serial-zero epoch: 1899-12-30 for the
/// 1900 date system, 1904-01-01 for the 1904 one.
const epoch_1900_days: i64 = -25569;
const epoch_1904_days: i64 = -24107;

/// `serial` (Excel's day count in the workbook's date system) as ISO 8601
/// text in `buf`, or null when it is not a showable date (negative, past
/// 9999-12-31, not finite) and the number should be left as it is.
///
///   date      2026-08-25           datetime  2026-08-25T17:26:00
///   time      17:26:00             duration  26:30:00 (hours may pass 24)
///
/// The time of day is rounded to the millisecond; `.mmm` is added only when
/// it is not zero. A serial below 1 has no date part and reads as a time;
/// a date-only format whose serial has a time of day keeps it, so nothing
/// stored is dropped. In the 1900 system, serials below 60 are shifted a
/// day to undo Excel's fictitious 1900-02-29.
pub fn formatSerial(buf: *[32]u8, serial: f64, kind: DateKind, date1904: bool) ?[]const u8 {
    if (kind == .none or !std.math.isFinite(serial)) return null;
    if (kind == .duration) {
        if (@abs(serial) >= max_serial) return null;
        const total: i64 = @intFromFloat(@round(serial * @as(f64, @floatFromInt(ms_per_day))));
        const sign: []const u8 = if (total < 0) "-" else "";
        const t: u64 = @abs(total);
        const ms = t % 1000;
        const s = (t / 1000) % 60;
        const m = (t / 60_000) % 60;
        const h = t / 3_600_000;
        return if (ms != 0)
            std.fmt.bufPrint(buf, "{s}{d}:{d:0>2}:{d:0>2}.{d:0>3}", .{ sign, h, m, s, ms }) catch null
        else
            std.fmt.bufPrint(buf, "{s}{d}:{d:0>2}:{d:0>2}", .{ sign, h, m, s }) catch null;
    }
    if (serial < 0 or serial >= max_serial) return null;

    var day: i64 = @intFromFloat(@floor(serial));
    var ms: i64 = @intFromFloat(@round((serial - @floor(serial)) * @as(f64, @floatFromInt(ms_per_day))));
    if (ms >= ms_per_day) {
        day += 1;
        ms -= ms_per_day;
    }
    var time_buf: [16]u8 = undefined;
    const time = formatTimeOfDay(&time_buf, ms) orelse return null;
    if (day == 0 and serial < 1) return std.fmt.bufPrint(buf, "{s}", .{time}) catch null;

    if (!date1904 and serial > 0 and serial < 60) day += 1;
    const civil = civilFromDays(day + if (date1904) epoch_1904_days else epoch_1900_days);
    const y: u32 = @intCast(civil.year);
    if (ms == 0 and kind == .date)
        return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}", .{ y, civil.month, civil.day }) catch null;
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}T{s}", .{ y, civil.month, civil.day, time }) catch null;
}

fn formatTimeOfDay(buf: *[16]u8, ms_of_day: i64) ?[]const u8 {
    const t: u64 = @intCast(ms_of_day);
    const ms = t % 1000;
    const s = (t / 1000) % 60;
    const m = (t / 60_000) % 60;
    const h = t / 3_600_000;
    return if (ms != 0)
        std.fmt.bufPrint(buf, "{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}", .{ h, m, s, ms }) catch null
    else
        std.fmt.bufPrint(buf, "{d:0>2}:{d:0>2}:{d:0>2}", .{ h, m, s }) catch null;
}

const Civil = struct { year: i64, month: u32, day: u32 };

/// The proleptic Gregorian date `days` after 1970-01-01 (Howard Hinnant's
/// days_from_civil inverse).
fn civilFromDays(days: i64) Civil {
    const z = days + 719468;
    const era = @divFloor(z, 146097);
    const doe = z - era * 146097; // [0, 146096]
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const d = doy - @divFloor(153 * mp + 2, 5) + 1;
    const m = if (mp < 10) mp + 3 else mp - 9;
    return .{
        .year = yoe + era * 400 + @as(i64, if (m <= 2) 1 else 0),
        .month = @intCast(m),
        .day = @intCast(d),
    };
}

test "classifyFormat: date, time and plain formats" {
    const t = std.testing;
    try t.expectEqual(DateKind.date, classifyFormat("dd\\ mmm\\ yyyy"));
    try t.expectEqual(DateKind.date, classifyFormat("[$-409]d\\-mmm\\-yyyy;@"));
    try t.expectEqual(DateKind.date, classifyFormat("mmm"));
    try t.expectEqual(DateKind.datetime, classifyFormat("yyyy-mm-dd hh:mm"));
    try t.expectEqual(DateKind.time, classifyFormat("h:mm AM/PM"));
    try t.expectEqual(DateKind.duration, classifyFormat("[h]:mm:ss"));
    try t.expectEqual(DateKind.duration, classifyFormat("[MM]:SS"));
    try t.expectEqual(DateKind.none, classifyFormat("General"));
    try t.expectEqual(DateKind.none, classifyFormat("0.0"));
    try t.expectEqual(DateKind.none, classifyFormat("\"£\"#,##0.00;[Red]\\-\"£\"#,##0.00"));
    try t.expectEqual(DateKind.none, classifyFormat("#,##0.00_ ;[Red]\\-#,##0.00\\ "));
    try t.expectEqual(DateKind.none, classifyFormat("_-\"£\"* #,##0.00_-;\\-\"£\"* #,##0.00_-;_-\"£\"* \"-\"??_-;_-@_-"));
    try t.expectEqual(DateKind.none, classifyFormat("0.00 \"days\""));
    try t.expectEqual(DateKind.none, classifyFormat("[Red][>=100]0.00"));
    // Only the first section counts.
    try t.expectEqual(DateKind.none, classifyFormat("0;\"d\"0;yyyy"));
}

test "builtinKind" {
    const t = std.testing;
    try t.expectEqual(DateKind.none, builtinKind(0));
    try t.expectEqual(DateKind.none, builtinKind(13));
    try t.expectEqual(DateKind.date, builtinKind(14));
    try t.expectEqual(DateKind.date, builtinKind(17));
    try t.expectEqual(DateKind.time, builtinKind(18));
    try t.expectEqual(DateKind.datetime, builtinKind(22));
    try t.expectEqual(DateKind.none, builtinKind(44));
    try t.expectEqual(DateKind.time, builtinKind(45));
    try t.expectEqual(DateKind.duration, builtinKind(46));
    try t.expectEqual(DateKind.none, builtinKind(49));
}

test "formatSerial: 1900 and 1904 systems" {
    const t = std.testing;
    var buf: [32]u8 = undefined;
    try t.expectEqualStrings("2026-08-25T17:26:00", formatSerial(&buf, 46259.7263888889, .datetime, false).?);
    try t.expectEqualStrings("2026-08-25T17:26:00", formatSerial(&buf, 46259.7263888889, .date, false).?);
    try t.expectEqualStrings("2026-08-25", formatSerial(&buf, 46259, .date, false).?);
    try t.expectEqualStrings("2026-08-25T00:00:00", formatSerial(&buf, 46259, .datetime, false).?);
    try t.expectEqualStrings("1900-01-01", formatSerial(&buf, 1, .date, false).?);
    try t.expectEqualStrings("1900-02-28", formatSerial(&buf, 59, .date, false).?);
    try t.expectEqualStrings("1900-03-01", formatSerial(&buf, 61, .date, false).?);
    try t.expectEqualStrings("1904-01-02", formatSerial(&buf, 1, .date, true).?);
    try t.expectEqualStrings("2026-08-25", formatSerial(&buf, 46259 - 1462, .date, true).?);
}

test "formatSerial: times, durations and numbers that are not dates" {
    const t = std.testing;
    var buf: [32]u8 = undefined;
    try t.expectEqualStrings("12:00:00", formatSerial(&buf, 0.5, .time, false).?);
    try t.expectEqualStrings("00:00:00", formatSerial(&buf, 0, .date, false).?);
    try t.expectEqualStrings("06:00:00.500", formatSerial(&buf, 0.25 + 0.5 / 86400.0, .time, false).?);
    // A time of day that rounds up to midnight rolls over to the next day.
    try t.expectEqualStrings("1900-01-01T00:00:00", formatSerial(&buf, 0.9999999999, .time, false).?);
    try t.expectEqualStrings("26:30:00", formatSerial(&buf, 1.1041666666666667, .duration, false).?);
    try t.expectEqualStrings("-12:00:00", formatSerial(&buf, -0.5, .duration, false).?);
    try t.expectEqualStrings("9999-12-31", formatSerial(&buf, 2958465, .date, false).?);
    try t.expect(formatSerial(&buf, 2958466, .date, false) == null);
    try t.expect(formatSerial(&buf, -1, .date, false) == null);
    try t.expect(formatSerial(&buf, std.math.nan(f64), .date, false) == null);
    try t.expect(formatSerial(&buf, 46259, .none, false) == null);
}

test "Styles.parse maps cellXfs through custom and built-in formats" {
    const styles_xml =
        \\<styleSheet>
        \\<numFmts count="3">
        \\  <numFmt numFmtId="164" formatCode="&quot;£&quot;#,##0.00"/>
        \\  <numFmt numFmtId="165" formatCode="dd\ mmm\ yyyy"/>
        \\  <numFmt numFmtId="14" formatCode="0.00"/>
        \\</numFmts>
        \\<cellStyleXfs count="1"><xf numFmtId="22"/></cellStyleXfs>
        \\<cellXfs count="5">
        \\  <xf numFmtId="0"/><xf numFmtId="164"/><xf numFmtId="165"/><xf numFmtId="22"/><xf numFmtId="14"/>
        \\</cellXfs>
        \\</styleSheet>
    ;
    var st = try Styles.parse(std.testing.allocator, styles_xml);
    defer st.deinit();
    try std.testing.expectEqual(@as(usize, 5), st.xf_kinds.len);
    try std.testing.expectEqual(DateKind.none, st.kind(0));
    try std.testing.expectEqual(DateKind.none, st.kind(1));
    try std.testing.expectEqual(DateKind.date, st.kind(2));
    try std.testing.expectEqual(DateKind.datetime, st.kind(3));
    // numFmt 14 redefined as a plain number format.
    try std.testing.expectEqual(DateKind.none, st.kind(4));
    try std.testing.expectEqual(DateKind.none, st.kind(99));
}
