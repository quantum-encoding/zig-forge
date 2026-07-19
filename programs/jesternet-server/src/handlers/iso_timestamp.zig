// ISO 8601 timestamp formatting (Z timezone).
//
// CONTRACT §5's EventRow surface and the TS reference's
// recent.ts:toItem both serialise event timestamps as
// `new Date(row.created_at).toISOString()` — RFC 3339 with
// millisecond precision and a literal 'Z' suffix:
//
//   2026-05-22T14:30:00.123Z
//
// This module produces the same byte-exact format from epoch-ms.
// Used by handlers that emit event rows over JSON (notifications,
// future PR endpoints).

const std = @import("std");

/// Exact length of the format `YYYY-MM-DDTHH:MM:SS.mmmZ`.
pub const ISO_LEN: usize = 24;

/// Format an epoch-ms value into an ISO 8601 Z timestamp. The buffer
/// MUST be at least ISO_LEN bytes; returns the slice that was filled.
pub fn fromEpochMs(epoch_ms: i64, out: []u8) []u8 {
    std.debug.assert(out.len >= ISO_LEN);

    const total_seconds: i64 = @divFloor(epoch_ms, 1000);
    var ms_component: i64 = @mod(epoch_ms, 1000);
    if (ms_component < 0) ms_component += 1000;

    // std.time.epoch.EpochSeconds works in u64 seconds since 1970.
    // Negative epoch values aren't meaningful here (we're recording
    // events at present-day timestamps), so clamp to 0 for safety.
    const secs_u64: u64 = if (total_seconds < 0) 0 else @intCast(total_seconds);
    const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = secs_u64 };

    const epoch_day = epoch_seconds.getEpochDay();
    const day_seconds = epoch_seconds.getDaySeconds();
    const year_day = epoch_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();

    const year: u16 = year_day.year;
    const month: u8 = month_day.month.numeric();
    const day: u8 = month_day.day_index + 1;
    const hour: u8 = day_seconds.getHoursIntoDay();
    const minute: u8 = day_seconds.getMinutesIntoHour();
    const second: u8 = day_seconds.getSecondsIntoMinute();
    const millis: u16 = @intCast(ms_component);

    // Fixed-width fields. std.fmt's `{d:0>4}` etc. would work but
    // bufPrint allocates a length per call; pencil-print is exact and
    // bounds-checked above by the assert. ISO format is positional so
    // direct char writes are cleanest.
    writeDigits(out[0..4], year);
    out[4] = '-';
    writeDigits(out[5..7], month);
    out[7] = '-';
    writeDigits(out[8..10], day);
    out[10] = 'T';
    writeDigits(out[11..13], hour);
    out[13] = ':';
    writeDigits(out[14..16], minute);
    out[16] = ':';
    writeDigits(out[17..19], second);
    out[19] = '.';
    writeDigits(out[20..23], millis);
    out[23] = 'Z';

    return out[0..ISO_LEN];
}

fn writeDigits(out: []u8, value: u64) void {
    var v = value;
    var i = out.len;
    while (i > 0) {
        i -= 1;
        out[i] = '0' + @as(u8, @intCast(v % 10));
        v /= 10;
    }
}

// ── Tests ──

const testing = std.testing;

test "fromEpochMs: known timestamps round-trip" {
    var buf: [ISO_LEN]u8 = undefined;

    // 2026-05-21T13:14:15.678 UTC. Hand-derived:
    //   56 years from 1970 = 56*365 + 14 leaps = 20454 days at 2026-01-01.
    //   Jan(31)+Feb(28)+Mar(31)+Apr(30)+20 = 140 days into 2026.
    //   Total 20594 days × 86400 sec = 1779321600 sec at 2026-05-21T00.
    //   + 13:14:15 = 47655 sec → 1779369255 sec → 1779369255000 ms.
    //   + 678 ms = 1779369255678 ms.
    const epoch_ms: i64 = 1779369255678;
    const result = fromEpochMs(epoch_ms, &buf);
    try testing.expectEqualStrings("2026-05-21T13:14:15.678Z", result);
}

test "fromEpochMs: zero is the unix epoch" {
    var buf: [ISO_LEN]u8 = undefined;
    const result = fromEpochMs(0, &buf);
    try testing.expectEqualStrings("1970-01-01T00:00:00.000Z", result);
}

test "fromEpochMs: midnight ms boundary" {
    var buf: [ISO_LEN]u8 = undefined;
    // Exactly midnight 2025-01-01 in ms.
    const result = fromEpochMs(1735689600000, &buf);
    try testing.expectEqualStrings("2025-01-01T00:00:00.000Z", result);
}

test "fromEpochMs: padding on small components" {
    var buf: [ISO_LEN]u8 = undefined;
    // 2024-01-02T03:04:05.006Z exercises zero-padding in every field.
    const result = fromEpochMs(1704164645006, &buf);
    try testing.expectEqualStrings("2024-01-02T03:04:05.006Z", result);
}

test "fromEpochMs: external anchor — Date.prototype.toISOString() goldens" {
    // EXTERNAL ANCHOR (zig-forge/CLAUDE.md golden rule §1). These
    // (epoch-ms → string) pairs are NOT hand-derived; each was produced
    // by `new Date(ms).toISOString()` under Node.js — the exact call the
    // TS reference's recent.ts `toItem()` uses. They cover the cases a
    // hand-rolled calendar most often gets wrong: the century-rule leap
    // day (2000-02-29 — divisible by 400, so a leap year), the ordinary
    // leap-to-March rollover (2024-03-01), sub-second precision, and the
    // end-of-year 23:59:59.999 boundary.
    const cases = [_]struct { ms: i64, want: []const u8 }{
        .{ .ms = 0, .want = "1970-01-01T00:00:00.000Z" },
        .{ .ms = 1000, .want = "1970-01-01T00:00:01.000Z" },
        .{ .ms = 951782400000, .want = "2000-02-29T00:00:00.000Z" },
        .{ .ms = 1709251200000, .want = "2024-03-01T00:00:00.000Z" },
        .{ .ms = 1234567890123, .want = "2009-02-13T23:31:30.123Z" },
        .{ .ms = 1580515200000, .want = "2020-02-01T00:00:00.000Z" },
        .{ .ms = 4102444799000, .want = "2099-12-31T23:59:59.000Z" },
        .{ .ms = 1798761599999, .want = "2026-12-31T23:59:59.999Z" },
    };
    var buf: [ISO_LEN]u8 = undefined;
    for (cases) |c| {
        try testing.expectEqualStrings(c.want, fromEpochMs(c.ms, &buf));
    }
}
