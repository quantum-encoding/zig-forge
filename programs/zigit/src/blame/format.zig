// blame formatters.
//
// Two output flavours:
//
//   * `writePorcelain` — designed to byte-match `git blame --porcelain`.
//     Each "group" (a run of consecutive target lines that came from
//     the same commit at consecutive blob-line numbers) gets one
//     header line; the first appearance of a commit gets the full
//     author/committer/summary/boundary|previous/filename block.
//
//   * `writeHuman` — best-effort match of `git blame`'s default
//     output. Not parity-checked.

const std = @import("std");
const Oid = @import("../object/oid.zig").Oid;
const BlameResult = @import("blame.zig").BlameResult;
const BlameLine = @import("blame.zig").BlameLine;

// ── Porcelain ────────────────────────────────────────────────────────

/// Write `result` in porcelain format. `path` is the file path the
/// blame was run against — appears in the `filename` and `previous`
/// header lines.
pub fn writePorcelain(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    result: BlameResult,
    path: []const u8,
) !void {
    if (result.lines.len == 0) return;

    // First pass: compute group sizes. A group is a maximal run of
    // consecutive target lines where both
    //   * commit_oid is the same as the previous line's, and
    //   * orig_line_no is exactly one greater than the previous line's.
    //
    // group_size[i] holds the group's length when i is the first line
    // of a group, else 0.
    var group_size = try allocator.alloc(u32, result.lines.len);
    defer allocator.free(group_size);
    @memset(group_size, 0);

    {
        var run_start: usize = 0;
        var i: usize = 1;
        while (i <= result.lines.len) : (i += 1) {
            const at_end = i == result.lines.len;
            const breaks_run = at_end or blk: {
                const prev = result.lines[i - 1];
                const cur = result.lines[i];
                if (!prev.commit_oid.eql(cur.commit_oid)) break :blk true;
                if (prev.orig_line_no + 1 != cur.orig_line_no) break :blk true;
                break :blk false;
            };
            if (breaks_run) {
                group_size[run_start] = @intCast(i - run_start);
                run_start = i;
            }
        }
    }

    // Track which commits we've already written the header block for.
    var seen_commits: std.AutoHashMapUnmanaged([20]u8, void) = .empty;
    defer seen_commits.deinit(allocator);

    for (result.lines, 0..) |line, idx| {
        var oid_hex: [40]u8 = undefined;
        line.commit_oid.toHex(&oid_hex);

        if (group_size[idx] > 0) {
            // First line of a group → emit "<oid> <orig> <final> <size>".
            try writer.print("{s} {d} {d} {d}\n", .{
                oid_hex,
                line.orig_line_no,
                line.line_no,
                group_size[idx],
            });

            // First appearance of this commit → emit the header block.
            const gop = try seen_commits.getOrPut(allocator, line.commit_oid.bytes);
            if (!gop.found_existing) {
                try writeCommitHeader(writer, line, path);
            }
        } else {
            // Continuation line in a group → emit "<oid> <orig> <final>".
            try writer.print("{s} {d} {d}\n", .{
                oid_hex,
                line.orig_line_no,
                line.line_no,
            });
        }

        // The content line. `line.content` already carries its trailing
        // '\n' if the original line had one. Real git emits an
        // explicit '\n' after the content when the source line lacked
        // one (otherwise the porcelain stream would lose its line
        // discipline). Mirror that behaviour.
        try writer.writeByte('\t');
        try writer.writeAll(line.content);
        if (line.content.len == 0 or line.content[line.content.len - 1] != '\n') {
            try writer.writeByte('\n');
        }
    }
}

fn writeCommitHeader(writer: *std.Io.Writer, line: BlameLine, path: []const u8) !void {
    var tz_buf: [8]u8 = undefined;

    try writer.print("author {s}\n", .{line.author_name});
    try writer.print("author-mail <{s}>\n", .{line.author_email});
    try writer.print("author-time {d}\n", .{line.author_time});
    try writer.print("author-tz {s}\n", .{formatTz(line.author_tz_offset_minutes, &tz_buf)});

    try writer.print("committer {s}\n", .{line.committer_name});
    try writer.print("committer-mail <{s}>\n", .{line.committer_email});
    try writer.print("committer-time {d}\n", .{line.committer_time});
    try writer.print("committer-tz {s}\n", .{formatTz(line.committer_tz_offset_minutes, &tz_buf)});

    try writer.print("summary {s}\n", .{line.summary});

    if (line.is_boundary) {
        try writer.writeAll("boundary\n");
    } else if (line.previous_oid) |prev| {
        var prev_hex: [40]u8 = undefined;
        prev.toHex(&prev_hex);
        try writer.print("previous {s} {s}\n", .{ prev_hex, path });
    }

    try writer.print("filename {s}\n", .{path});
}

fn formatTz(tz_offset_minutes: i16, buf: *[8]u8) []const u8 {
    const sign: u8 = if (tz_offset_minutes >= 0) '+' else '-';
    const abs: u16 = @intCast(@abs(tz_offset_minutes));
    const hh: u16 = abs / 60;
    const mm: u16 = abs % 60;
    return std.fmt.bufPrint(buf, "{c}{d:0>2}{d:0>2}", .{ sign, hh, mm }) catch unreachable;
}

// ── Human (default git blame output) ─────────────────────────────────

/// Write `result` in human format. Not byte-parity-checked, but mirrors
/// git's default `<short_oid> (<author> <date> <time> <tz> <line_no>) <content>`.
pub fn writeHuman(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    result: BlameResult,
) !void {
    if (result.lines.len == 0) return;

    // Author-name padding: widest name in the result.
    var max_author_w: usize = 0;
    for (result.lines) |line| max_author_w = @max(max_author_w, line.author_name.len);

    // Line-number padding: digits in the largest line_no.
    var max_line_no: u32 = 0;
    for (result.lines) |line| max_line_no = @max(max_line_no, line.line_no);
    var line_w: usize = 1;
    {
        var n = max_line_no;
        while (n >= 10) : (n = n / 10) line_w += 1;
    }

    var oid_hex_buf: [40]u8 = undefined;
    var date_buf: [32]u8 = undefined;
    var tz_buf: [8]u8 = undefined;
    var name_buf: std.ArrayListUnmanaged(u8) = .empty;
    defer name_buf.deinit(allocator);

    for (result.lines) |line| {
        line.commit_oid.toHex(&oid_hex_buf);
        const short_oid = oid_hex_buf[0..8];

        const date_str = try formatDateTime(line.author_time, line.author_tz_offset_minutes, &date_buf);
        const tz_str = formatTz(line.author_tz_offset_minutes, &tz_buf);

        name_buf.clearRetainingCapacity();
        try name_buf.appendSlice(allocator, line.author_name);
        while (name_buf.items.len < max_author_w) try name_buf.append(allocator, ' ');

        // Format the line number into a small buffer right-aligned to
        // line_w. Zig's std.fmt doesn't have runtime-width %*d, so we
        // pad ourselves.
        var lineno_raw_buf: [16]u8 = undefined;
        const lineno_raw = try std.fmt.bufPrint(&lineno_raw_buf, "{d}", .{line.line_no});
        var lineno_padded_buf: [16]u8 = undefined;
        var pad_idx: usize = 0;
        while (pad_idx + lineno_raw.len < line_w) : (pad_idx += 1) {
            lineno_padded_buf[pad_idx] = ' ';
        }
        @memcpy(lineno_padded_buf[pad_idx..][0..lineno_raw.len], lineno_raw);
        const lineno_padded = lineno_padded_buf[0 .. pad_idx + lineno_raw.len];

        try writer.print("{s} ({s} {s} {s} {s}) ", .{
            short_oid,
            name_buf.items,
            date_str,
            tz_str,
            lineno_padded,
        });
        try writer.writeAll(line.content);
        if (line.content.len == 0 or line.content[line.content.len - 1] != '\n') {
            try writer.writeByte('\n');
        }
    }
}

/// Format a unix timestamp + minutes-east-of-UTC into "YYYY-MM-DD HH:MM:SS"
/// in the supplied buffer. Returns a slice into `buf` that lives as
/// long as the buffer does.
fn formatDateTime(unix_time: i64, tz_offset_minutes: i16, buf: *[32]u8) ![]const u8 {
    const local = unix_time + @as(i64, tz_offset_minutes) * 60;
    const days = @divFloor(local, 86400);
    const time_of_day: i64 = @mod(local, 86400);
    const civil = civilFromDays(days);
    const hour: u8 = @intCast(@divTrunc(time_of_day, 3600));
    const minute: u8 = @intCast(@divTrunc(@mod(time_of_day, 3600), 60));
    const second: u8 = @intCast(@mod(time_of_day, 60));

    // Cast year to u32 to avoid the implicit '+' that std.fmt prints
    // for signed types. Pre-epoch dates aren't in scope for blame.
    const year_u: u32 = @intCast(civil.year);
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}", .{
        year_u, civil.month, civil.day, hour, minute, second,
    });
}

const Civil = struct { year: i32, month: u8, day: u8 };

/// Convert days-since-1970-01-01 to a proleptic Gregorian (year, month, day).
/// Howard Hinnant's algorithm.
fn civilFromDays(days: i64) Civil {
    const z = days + 719468;
    const era = @divFloor(z, 146097);
    const doe: u32 = @intCast(z - era * 146097);
    const yoe: u32 = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    const y: i64 = @as(i64, yoe) + era * 400;
    const doy: u32 = doe - (365 * yoe + yoe / 4 - yoe / 100);
    const mp: u32 = (5 * doy + 2) / 153;
    const d: u32 = doy - (153 * mp + 2) / 5 + 1;
    const m: u32 = if (mp < 10) mp + 3 else mp - 9;
    const year_adj: i64 = if (m <= 2) y + 1 else y;
    return .{
        .year = @intCast(year_adj),
        .month = @intCast(m),
        .day = @intCast(d),
    };
}

// ── Tests ───────────────────────────────────────────────────────────

const testing = std.testing;

test "civilFromDays — Unix epoch is 1970-01-01" {
    const c = civilFromDays(0);
    try testing.expectEqual(@as(i32, 1970), c.year);
    try testing.expectEqual(@as(u8, 1), c.month);
    try testing.expectEqual(@as(u8, 1), c.day);
}

test "civilFromDays — 2024-02-29 leap day" {
    // 2024-02-29 == days since epoch = 19782
    const c = civilFromDays(19782);
    try testing.expectEqual(@as(i32, 2024), c.year);
    try testing.expectEqual(@as(u8, 2), c.month);
    try testing.expectEqual(@as(u8, 29), c.day);
}

test "formatTz — round-trip a few offsets" {
    var buf: [8]u8 = undefined;
    try testing.expectEqualStrings("+0000", formatTz(0, &buf));
    try testing.expectEqualStrings("+0100", formatTz(60, &buf));
    try testing.expectEqualStrings("-0500", formatTz(-300, &buf));
    try testing.expectEqualStrings("+0530", formatTz(330, &buf));
    try testing.expectEqualStrings("-0930", formatTz(-570, &buf));
}

test "formatDateTime — 1700000000 +0000" {
    var buf: [32]u8 = undefined;
    const s = try formatDateTime(1700000000, 0, &buf);
    // 1700000000 → 2023-11-14 22:13:20 UTC
    try testing.expectEqualStrings("2023-11-14 22:13:20", s);
}

test "formatDateTime — apply +0100 offset" {
    var buf: [32]u8 = undefined;
    const s = try formatDateTime(1700000000, 60, &buf);
    // Same epoch + 1 hour → 23:13:20.
    try testing.expectEqualStrings("2023-11-14 23:13:20", s);
}

test "porcelain: tiny single-commit fixture round-trips against hand-written reference" {
    // A 3-line file at a single commit. We can pin every byte of the
    // expected porcelain output because the only variable is the
    // commit OID.
    const blame_mod = @import("blame.zig");
    const LooseStore = @import("../object/loose_store.zig").LooseStore;
    const compute_oid = @import("../object/mod.zig").computeOid;
    const tree_mod = @import("../object/tree.zig");
    const commit_mod = @import("../object/commit.zig");

    const allocator = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = LooseStore.init(tmp.dir, io);

    const file = "one\ntwo\nthree\n";
    const blob_oid = compute_oid(.blob, file);
    try store.write(allocator, .blob, file, blob_oid);

    const entries = [_]tree_mod.Entry{
        .{ .mode = tree_mod.blob_mode_regular, .name = "f.txt", .oid = blob_oid },
    };
    const tree_payload = try tree_mod.serialize(allocator, &entries);
    defer allocator.free(tree_payload);
    const tree_oid = compute_oid(.tree, tree_payload);
    try store.write(allocator, .tree, tree_payload, tree_oid);

    const author: commit_mod.Author = .{
        .name = "Alice",
        .email = "a@example.com",
        .when_unix = 1700000000,
        .timezone = "+0000",
    };
    const commit_payload = try commit_mod.serialize(allocator, .{
        .tree_oid = tree_oid,
        .parent_oids = &.{},
        .author = author,
        .committer = author,
        .message = "init\n",
    });
    defer allocator.free(commit_payload);
    const commit_oid = compute_oid(.commit, commit_payload);
    try store.write(allocator, .commit, commit_payload, commit_oid);

    var result = try blame_mod.blameFile(allocator, &store, commit_oid, "f.txt", .{});
    defer result.deinit();

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try writePorcelain(allocator, &out.writer, result, "f.txt");

    var oid_hex: [40]u8 = undefined;
    commit_oid.toHex(&oid_hex);

    var expected: std.Io.Writer.Allocating = .init(allocator);
    defer expected.deinit();
    // All three lines come from the same commit at consecutive blob
    // lines, so they form ONE group of size 3. The first line carries
    // the group_size and the full header block; the remaining two
    // lines are continuations (OID + orig + final only) — this is
    // git blame's actual porcelain compression behaviour, verified
    // against real `git blame --porcelain` output.
    try expected.writer.print(
        "{s} 1 1 3\n" ++
            "author Alice\n" ++
            "author-mail <a@example.com>\n" ++
            "author-time 1700000000\n" ++
            "author-tz +0000\n" ++
            "committer Alice\n" ++
            "committer-mail <a@example.com>\n" ++
            "committer-time 1700000000\n" ++
            "committer-tz +0000\n" ++
            "summary init\n" ++
            "boundary\n" ++
            "filename f.txt\n" ++
            "\tone\n" ++
            "{s} 2 2\n" ++
            "\ttwo\n" ++
            "{s} 3 3\n" ++
            "\tthree\n",
        .{ &oid_hex, &oid_hex, &oid_hex },
    );

    try testing.expectEqualStrings(expected.written(), out.written());
}
