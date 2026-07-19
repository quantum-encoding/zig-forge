//! Tier-1 anchors for `zig-trash`.
//!
//! Every expected value in this file comes from a source this program did not
//! write:
//!
//!   * **freedesktop.org Trash specification v1.0** — the `[Trash Info]` file
//!     format, and the requirement that the `Path` value be percent-encoded
//!     ("the value ... is the original location of the file/directory ...
//!     stored in URI form", RFC 2396/3986 escaping, path separators literal).
//!   * **Golden `.trashinfo` bytes as emitted by `gio trash` / `trash-cli`** —
//!     the two spec-compliant implementations this tool must interoperate with
//!     on Linux. These are byte-for-byte file bodies, not roundtrips.
//!   * **Published Unix epoch values** — 0, 1000000000, 1234567890, 2147483647
//!     and the standard leap-day timestamps. These are calendar facts, not
//!     values computed by this program.
//!
//! The date anchors are the ones that matter most: `empty --older` permanently
//! deletes files based on this arithmetic, and the previous implementation
//! wrote local time while parsing it as UTC (skew up to the UTC offset) on top
//! of a month table that ignored leap years (an extra day of drift inside any
//! leap year after February).

const std = @import("std");
const testing = std.testing;
const trash = @import("main.zig");

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn tzset() void;
extern "c" fn time(tloc: ?*std.c.time_t) std.c.time_t;
const cTime = time;

/// Pin the process to UTC so the local-time conversion below has a known
/// offset. The production path deliberately uses the machine's zone.
fn useUtc() void {
    _ = setenv("TZ", "UTC", 1);
    tzset();
}

// ═══════════════════════════════════════════════════════════════════════════
// Calendar / epoch anchors
// ═══════════════════════════════════════════════════════════════════════════

test "daysFromCivil matches published day counts" {
    // Days since 1970-01-01. Cross-checkable against any calendar library:
    // each value is (published epoch seconds) / 86400.
    try testing.expectEqual(@as(i64, 0), trash.daysFromCivil(1970, 1, 1));
    try testing.expectEqual(@as(i64, 11017), trash.daysFromCivil(2000, 3, 1)); // 951868800
    try testing.expectEqual(@as(i64, 19782), trash.daysFromCivil(2024, 2, 29)); // 1709164800
    try testing.expectEqual(@as(i64, 24855), trash.daysFromCivil(2038, 1, 19)); // 2147483647
    try testing.expectEqual(@as(i64, 10957), trash.daysFromCivil(2000, 1, 1)); // 946684800
    // 1900 is NOT a leap year, 2000 IS — the century rule the old month table
    // had no concept of.
    try testing.expectEqual(@as(i64, 1), trash.daysFromCivil(1970, 1, 2) - trash.daysFromCivil(1970, 1, 1));
    try testing.expectEqual(@as(i64, 366), trash.daysFromCivil(2001, 1, 1) - trash.daysFromCivil(2000, 1, 1));
    try testing.expectEqual(@as(i64, 365), trash.daysFromCivil(2002, 1, 1) - trash.daysFromCivil(2001, 1, 1));
}

test "parseIso8601 matches published Unix timestamps (TZ=UTC)" {
    useUtc();
    const cases = [_]struct { s: []const u8, epoch: i64 }{
        .{ .s = "1970-01-01T00:00:00", .epoch = 0 },
        .{ .s = "2001-09-09T01:46:40", .epoch = 1000000000 },
        .{ .s = "2009-02-13T23:31:30", .epoch = 1234567890 },
        .{ .s = "2038-01-19T03:14:07", .epoch = 2147483647 },
        // Leap day: the old fixed month table was short by a day here.
        .{ .s = "2024-02-29T12:00:00", .epoch = 1709208000 },
        .{ .s = "2024-03-01T00:00:00", .epoch = 1709251200 },
        .{ .s = "2000-02-29T00:00:00", .epoch = 951782400 },
    };
    for (cases) |tc| {
        const got = trash.parseIso8601(tc.s) orelse return error.ParseFailed;
        testing.expectEqual(tc.epoch, got) catch |e| {
            std.debug.print("parseIso8601(\"{s}\") = {d}, want {d}\n", .{ tc.s, got, tc.epoch });
            return e;
        };
    }
}

test "parseIso8601 rejects malformed and out-of-range dates" {
    useUtc();
    // A `.trashinfo` is attacker-writable in the sense that any process running
    // as the user can drop one; a bogus date must not become a plausible age
    // that `empty --older` acts on.
    try testing.expect(trash.parseIso8601("") == null);
    try testing.expect(trash.parseIso8601("2024-01-01") == null); // too short
    try testing.expect(trash.parseIso8601("2024/01/01T00:00:00") == null); // wrong separators
    try testing.expect(trash.parseIso8601("2024-13-01T00:00:00") == null); // month 13
    try testing.expect(trash.parseIso8601("2024-00-01T00:00:00") == null); // month 0
    try testing.expect(trash.parseIso8601("2024-01-32T00:00:00") == null); // day 32
    try testing.expect(trash.parseIso8601("2023-02-29T00:00:00") == null); // 2023 is not leap
    try testing.expect(trash.parseIso8601("2024-01-01T24:00:00") == null); // hour 24
    try testing.expect(trash.parseIso8601("2024-01-01T00:60:00") == null); // minute 60
    try testing.expect(trash.parseIso8601("20xx-01-01T00:00:00") == null); // non-numeric
    // 2024 IS a leap year — this one must parse.
    try testing.expect(trash.parseIso8601("2024-02-29T00:00:00") != null);
}

test "written DeletionDate reads back as the same instant (DST zone)" {
    // The write/parse pair must agree on the timezone. Writing local time and
    // parsing it as UTC — the previous behaviour — shows up here as an offset
    // equal to the zone's, in a zone that also exercises DST.
    _ = setenv("TZ", "America/New_York", 1);
    tzset();
    defer useUtc();

    var tnow: std.c.time_t = undefined;
    const now: i64 = @intCast(cTime(&tnow));
    const iso = trash.timestampToIso8601();
    const parsed = trash.parseIso8601(&iso) orelse return error.ParseFailed;
    // Allow 2s for the clock ticking between the two calls.
    const skew = @abs(parsed - now);
    testing.expect(skew <= 2) catch |e| {
        std.debug.print("DeletionDate roundtrip skew {d}s for \"{s}\"\n", .{ skew, iso });
        return e;
    };
}

// ═══════════════════════════════════════════════════════════════════════════
// .trashinfo encoding anchors (freedesktop spec + gio/trash-cli goldens)
// ═══════════════════════════════════════════════════════════════════════════

test "Path is percent-encoded the way gio/trash-cli encode it" {
    const a = testing.allocator;
    const cases = [_]struct { raw: []const u8, encoded: []const u8 }{
        // Plain path — unreserved chars and '/' stay literal.
        .{ .raw = "/home/user/notes.txt", .encoded = "/home/user/notes.txt" },
        // Space → %20 (the canonical gio output, and the case that made this
        // tool restore to a literal "%20" path before decoding existed).
        .{ .raw = "/home/user/My Documents/a b.txt", .encoded = "/home/user/My%20Documents/a%20b.txt" },
        // Reserved / delimiter characters.
        .{ .raw = "/tmp/a#b?c", .encoded = "/tmp/a%23b%3Fc" },
        .{ .raw = "/tmp/100%", .encoded = "/tmp/100%25" },
        // A newline in a filename is legal on POSIX; unencoded it would forge
        // extra `Path=` / `DeletionDate=` lines inside the metadata file. The
        // newline (and the `=`) are escaped; `/` stays literal per the spec.
        .{ .raw = "/tmp/evil\nPath=/etc/passwd", .encoded = "/tmp/evil%0APath%3D/etc/passwd" },
        // Non-ASCII is UTF-8 percent-encoded byte by byte.
        .{ .raw = "/tmp/café", .encoded = "/tmp/caf%C3%A9" },
    };
    for (cases) |tc| {
        const got = try trash.encodeTrashPath(a, tc.raw);
        defer a.free(got);
        try testing.expectEqualStrings(tc.encoded, got);

        const back = trash.decodeTrashPath(a, got) orelse return error.DecodeFailed;
        defer a.free(back);
        try testing.expectEqualStrings(tc.raw, back);
    }
}

test "decode accepts a gio-written Path value" {
    const a = testing.allocator;
    // Byte-for-byte the `Path=` value gio writes for /home/user/Hello World.txt
    const decoded = trash.decodeTrashPath(a, "/home/user/Hello%20World.txt") orelse return error.DecodeFailed;
    defer a.free(decoded);
    try testing.expectEqualStrings("/home/user/Hello World.txt", decoded);
}

/// A `.trashinfo` body exactly as `gio trash` emits it (spec §"Trash info
/// files": the `[Trash Info]` group, a percent-encoded `Path`, and a local-time
/// `DeletionDate` with no zone suffix).
const gio_golden =
    "[Trash Info]\n" ++
    "Path=/home/user/Documents/My%20Report%20%232.txt\n" ++
    "DeletionDate=2024-02-29T12:00:00\n";

test "readTrashInfo parses a gio-written .trashinfo byte-for-byte" {
    useUtc();
    const a = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "golden.trashinfo", .data = gio_golden });

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(io, &path_buf);
    const full = try std.fmt.allocPrint(a, "{s}/golden.trashinfo", .{path_buf[0..dir_len]});
    defer a.free(full);

    var entry = trash.readTrashInfo(a, full) orelse return error.ReadFailed;
    defer entry.deinit(a);

    try testing.expectEqualStrings("/home/user/Documents/My Report #2.txt", entry.original_path);
    try testing.expectEqualStrings("2024-02-29T12:00:00", entry.date_str);
    try testing.expectEqual(@as(?i64, 1709208000), entry.timestamp);
}

test "readTrashInfo rejects a body with no Path or no DeletionDate" {
    const a = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(io, &path_buf);
    const dir_path = path_buf[0..dir_len];

    const bad = [_][]const u8{
        "[Trash Info]\nDeletionDate=2024-02-29T12:00:00\n", // no Path
        "[Trash Info]\nPath=/tmp/x\n", // no DeletionDate
        "", // empty
    };
    for (bad, 0..) |body, i| {
        var name_buf: [32]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "bad{d}.trashinfo", .{i});
        try tmp.dir.writeFile(io, .{ .sub_path = name, .data = body });
        const full = try std.fmt.allocPrint(a, "{s}/{s}", .{ dir_path, name });
        defer a.free(full);
        if (trash.readTrashInfo(a, full)) |*e| {
            @constCast(e).deinit(a);
            return error.ShouldHaveRejected;
        }
    }
}

// ═══════════════════════════════════════════════════════════════════════════
// CLI argument parsing
// ═══════════════════════════════════════════════════════════════════════════

test "parseAge units" {
    try testing.expectEqual(@as(?i64, 7 * 86400), trash.parseAge("7d"));
    try testing.expectEqual(@as(?i64, 24 * 3600), trash.parseAge("24h"));
    try testing.expectEqual(@as(?i64, 30 * 60), trash.parseAge("30m"));
    try testing.expectEqual(@as(?i64, 0), trash.parseAge("0d"));
    try testing.expect(trash.parseAge("") == null);
    try testing.expect(trash.parseAge("7") == null);
    try testing.expect(trash.parseAge("7y") == null);
    try testing.expect(trash.parseAge("xd") == null);
    // A negative age would make `now - deleted_at >= threshold` true for every
    // entry, silently turning `empty --older -1d` into `empty` (delete all).
    try testing.expect(trash.parseAge("-1d") == null);
    try testing.expect(trash.parseAge("-9999h") == null);
}

test "humanSize boundaries" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("0 B", trash.humanSize(0, &buf));
    try testing.expectEqualStrings("1023 B", trash.humanSize(1023, &buf));
    try testing.expectEqualStrings("1.0 KiB", trash.humanSize(1024, &buf));
    try testing.expectEqualStrings("1.0 MiB", trash.humanSize(1024 * 1024, &buf));
    try testing.expectEqualStrings("1.00 GiB", trash.humanSize(1024 * 1024 * 1024, &buf));
}
