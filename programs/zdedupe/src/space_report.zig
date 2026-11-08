//! The disk-space report: one folder of a disk-space scan as plain text, for a
//! person to read, paste or save. It is rendered from the same answers a host
//! reads (overview, children, largest), so it states what the screens state,
//! with full paths where a screen shortens them.
//!
//! Sizes follow the host's own formatter so the figures match its screen:
//! `decimal` is Apple's ByteCountFormatter (.file), `binary` the Svelte app's
//! formatBytes. Both are reproduced with integer arithmetic, which is exact
//! where the originals round half up.

const std = @import("std");
const space = @import("space.zig");

const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const Category = space.Category;

pub const Units = enum { decimal, binary };

/// Most items a list in the report holds (the space calls clamp the same way).
pub const max_contents: usize = space.max_children;
pub const max_listed: usize = space.max_largest;

pub const Query = struct {
    /// The folder, as for every space call; neither = the whole scan.
    node: ?u32 = null,
    path: ?[]const u8 = null,
    /// Narrows the top files to one type, as the Top Files list's filter does.
    type: ?Category = null,
    /// Items directly inside the folder, largest first; clamped to `max_contents`.
    contents: usize = 50,
    /// Largest folders below it; clamped to `max_listed`.
    folders: usize = 50,
    /// Largest files below it; clamped to `max_listed`.
    files: usize = 100,
    units: Units = .binary,
    /// Seconds east of UTC, for the scan time in the reader's time zone.
    utc_offset: i32 = 0,
    /// What the host calls the disk ("Macintosh HD"); the mount point stands
    /// alone without one.
    volume_name: ?[]const u8 = null,
};

// The parts of the space answers the report reads. Field names are the wire
// names (schema/results-session.schema.json); everything else is ignored.

pub const Node = struct {
    kind: []const u8,
    name: []const u8,
    path: []const u8,
    bytes: u64,
    logical: u64 = 0,
    files: u64 = 0,
    dirs: u64 = 0,
};

pub const Rest = struct { count: u64 = 0, bytes: u64 = 0 };

pub const TypeTotal = struct { type: Category, bytes: u64 };

pub const Group = struct { items: []const Node, rest: Rest = .{} };

pub const Children = struct {
    node: Node,
    types: []const TypeTotal,
    groups: []const Group,
};

pub const Largest = struct { items: []const Node };

pub const Skipped = struct {
    recorded: bool = false,
    unreadable: u64 = 0,
    denied: u64 = 0,
    privacy: u64 = 0,
    partial: u64 = 0,
    other_volume: u64 = 0,
    app_library: u64 = 0,
    credentials: u64 = 0,
    excluded: u64 = 0,

    /// What the scan tried and could not read.
    fn unread(self: Skipped) u64 {
        return self.unreadable + self.denied + self.privacy + self.partial;
    }

    /// What the scan left out on purpose.
    fn leftOut(self: Skipped) u64 {
        return self.other_volume + self.app_library + self.credentials + self.excluded;
    }
};

pub const Volume = struct { mount: []const u8, total: u64, free: u64, available: u64 };

pub const Overview = struct {
    roots: []const []const u8,
    generated_at: i64,
    volume: Volume,
    files: u64,
    dirs: u64,
    bytes: u64,
    dataless_files: u64 = 0,
    dataless_logical: u64 = 0,
    hard_links: u64 = 0,
    incomplete_dirs: u64 = 0,
    removed_count: u64 = 0,
    removed_bytes: u64 = 0,
    skipped: Skipped = .{},
};

pub const Input = struct {
    query: Query,
    overview: Overview,
    children: Children,
    folders: []const Node,
    files: []const Node,
};

/// Longest size `formatSize` writes ("1023.99 KB", "9.22 EB").
pub const size_buf_len = 32;

/// `bytes` as the host's formatter writes it.
pub fn formatSize(bytes: u64, units: Units, buf: *[size_buf_len]u8) []const u8 {
    return switch (units) {
        .decimal => formatDecimal(bytes, buf),
        .binary => formatBinary(bytes, buf),
    };
}

/// ByteCountFormatter, .file count style, adaptive: powers of 1000, no
/// decimals for KB, one for MB, two from GB up, trailing zeros dropped, half
/// rounded up, and a value that rounds to 1000 moves up a unit.
fn formatDecimal(bytes: u64, buf: *[size_buf_len]u8) []const u8 {
    if (bytes == 0) return "Zero KB";
    if (bytes < 1000) {
        return std.fmt.bufPrint(buf, "{d} {s}", .{ bytes, if (bytes == 1) "byte" else "bytes" }) catch unreachable;
    }
    const units = [_][]const u8{ "KB", "MB", "GB", "TB", "PB", "EB" };
    const decimals = [_]u8{ 0, 1, 2, 2, 2, 2 };
    var unit: usize = 0;
    var divisor: u128 = 1000;
    while (unit + 1 < units.len and bytes >= divisor * 1000) {
        unit += 1;
        divisor *= 1000;
    }
    while (true) {
        const scale = std.math.pow(u128, 10, decimals[unit]);
        const scaled = roundHalfUp(@as(u128, bytes) * scale, divisor);
        if (scaled >= 1000 * scale and unit + 1 < units.len) {
            unit += 1;
            divisor *= 1000;
            continue;
        }
        return writeFixed(buf, scaled, decimals[unit], true, units[unit]);
    }
}

/// The Svelte app's formatBytes: powers of 1024, the largest unit not above
/// the value, two decimals (none for bytes), the exact quotient rounded half
/// up as JavaScript's toFixed does. No moving up a unit: 1048575 bytes is
/// "1024.00 KB".
fn formatBinary(bytes: u64, buf: *[size_buf_len]u8) []const u8 {
    if (bytes < 1024) return std.fmt.bufPrint(buf, "{d} B", .{bytes}) catch unreachable;
    const units = [_][]const u8{ "KB", "MB", "GB", "TB", "PB", "EB" };
    var unit: usize = 0;
    var divisor: u128 = 1024;
    while (unit + 1 < units.len and bytes >= divisor * 1024) {
        unit += 1;
        divisor *= 1024;
    }
    return writeFixed(buf, roundHalfUp(@as(u128, bytes) * 100, divisor), 2, false, units[unit]);
}

fn roundHalfUp(numerator: u128, divisor: u128) u128 {
    return (numerator * 2 + divisor) / (divisor * 2);
}

/// `scaled` / 10^decimals (at most 2) with that many decimals, trailing
/// zeros (and a bare point) dropped when `trim`.
fn writeFixed(buf: *[size_buf_len]u8, scaled: u128, decimals: u8, trim: bool, unit: []const u8) []const u8 {
    const scale = std.math.pow(u128, 10, decimals);
    const whole = scaled / scale;
    var frac = scaled % scale;
    var places = decimals;
    if (trim) {
        while (places > 0 and frac % 10 == 0) {
            frac /= 10;
            places -= 1;
        }
    }
    if (places == 0) return std.fmt.bufPrint(buf, "{d} {s}", .{ whole, unit }) catch unreachable;
    if (places == 1) return std.fmt.bufPrint(buf, "{d}.{d} {s}", .{ whole, frac, unit }) catch unreachable;
    return std.fmt.bufPrint(buf, "{d}.{d:0>2} {s}", .{ whole, frac, unit }) catch unreachable;
}

/// `n` with a comma between each group of three digits.
fn writeCount(w: *Writer, n: u64) Writer.Error!void {
    var digits: [24]u8 = undefined;
    const s = std.fmt.bufPrint(&digits, "{d}", .{n}) catch unreachable;
    for (s, 0..) |c, i| {
        if (i > 0 and (s.len - i) % 3 == 0) try w.writeByte(',');
        try w.writeByte(c);
    }
}

/// "1 file", "2,900,330 files".
fn writeCounted(w: *Writer, n: u64, one: []const u8, many: []const u8) Writer.Error!void {
    try writeCount(w, n);
    try w.writeByte(' ');
    try w.writeAll(if (n == 1) one else many);
}

fn typeLabel(c: Category) []const u8 {
    return switch (c) {
        .media => "Media",
        .documents => "Documents",
        .code => "Code",
        .archives => "Archives",
        .applications => "Applications",
        .system => "System",
        .other => "Other",
    };
}

const Clock = struct { year: u16, month: u8, day: u8, hour: u8, minute: u8 };

/// Epoch milliseconds in the zone `utc_offset` seconds east of UTC; times
/// before 1970 read as 1970.
fn clockOf(millis: i64, utc_offset: i32) Clock {
    const seconds = @divFloor(millis, 1000) + utc_offset;
    const es: std.time.epoch.EpochSeconds = .{ .secs = @intCast(@max(seconds, 0)) };
    const year_day = es.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_seconds = es.getDaySeconds();
    return .{
        .year = year_day.year,
        .month = month_day.month.numeric(),
        .day = @as(u8, month_day.day_index) + 1,
        .hour = day_seconds.getHoursIntoDay(),
        .minute = day_seconds.getMinutesIntoHour(),
    };
}

const label_width = 10;

fn writeLabel(w: *Writer, label: []const u8) Writer.Error!void {
    try w.writeAll(label);
    try w.splatByteAll(' ', label_width -| label.len);
}

/// A size right-aligned in `width` columns, two spaces, then `text`.
fn writeSizeRow(w: *Writer, units: Units, bytes: u64, width: usize, text: []const u8) Writer.Error!void {
    var buf: [size_buf_len]u8 = undefined;
    const size = formatSize(bytes, units, &buf);
    try w.writeAll("  ");
    try w.splatByteAll(' ', width -| size.len);
    try w.writeAll(size);
    try w.writeAll("  ");
    try w.writeAll(text);
}

fn sizeWidth(units: Units, sizes: []const u64) usize {
    var width: usize = 0;
    var buf: [size_buf_len]u8 = undefined;
    for (sizes) |b| width = @max(width, formatSize(b, units, &buf).len);
    return width;
}

/// The report, as UTF-8 text ending in a newline.
pub fn render(arena: Allocator, w: *Writer, in: Input) !void {
    const q = in.query;
    const o = in.overview;
    const node = in.children.node;
    var buf: [size_buf_len]u8 = undefined;
    var buf2: [size_buf_len]u8 = undefined;

    try w.writeAll("Disk Space Report\n\n");

    try writeLabel(w, "Folder:");
    if (std.mem.eql(u8, node.kind, "all")) {
        try w.writeAll("Whole scan");
    } else {
        try w.writeAll(node.path);
    }
    try w.writeByte('\n');

    try writeLabel(w, "Size:");
    try w.print("{s} on disk", .{formatSize(node.bytes, q.units, &buf)});
    if (node.logical != node.bytes) try w.print(", {s} apparent", .{formatSize(node.logical, q.units, &buf)});
    try w.writeAll(", ");
    try writeCounted(w, node.files, "file", "files");
    try w.writeAll(", ");
    try writeCounted(w, node.dirs, "folder", "folders");
    try w.writeByte('\n');

    const used = o.volume.total -| @min(o.volume.free, o.volume.total);
    try writeLabel(w, "Disk:");
    if (q.volume_name) |name| {
        try w.print("{s} ({s})", .{ name, o.volume.mount });
    } else {
        try w.writeAll(o.volume.mount);
    }
    try w.print(", {s} used of {s}, ", .{ formatSize(used, q.units, &buf), formatSize(o.volume.total, q.units, &buf2) });
    try w.print("{s} available\n", .{formatSize(o.volume.available, q.units, &buf)});

    const at = clockOf(o.generated_at, q.utc_offset);
    try writeLabel(w, "Scanned:");
    for (o.roots, 0..) |root, i| {
        if (i > 0) try w.writeAll(", ");
        try w.writeAll(root);
    }
    try w.print(" on {d:0>4}-{d:0>2}-{d:0>2} at {d:0>2}:{d:0>2}, {s} in ", .{
        at.year, at.month, at.day, at.hour, at.minute, formatSize(o.bytes, q.units, &buf),
    });
    try writeCounted(w, o.files, "file", "files");
    try w.writeAll(", ");
    try writeCounted(w, o.dirs, "folder", "folders");
    try w.writeByte('\n');

    // The notes under the scan figures, in the apps' words.
    const pad: [label_width]u8 = @splat(' ');
    const skipped = o.skipped;
    if (skipped.recorded and skipped.unread() + skipped.leftOut() > 0) {
        try w.writeAll(&pad);
        if (skipped.unread() > 0) {
            try writeCounted(w, skipped.unread(), "item", "items");
            try w.writeAll(" could not be read.");
            if (skipped.leftOut() > 0) try w.writeByte(' ');
        }
        if (skipped.leftOut() > 0) {
            try writeCounted(w, skipped.leftOut(), "item", "items");
            try w.writeAll(" excluded.");
        }
        try w.writeByte('\n');
    }
    if (!skipped.recorded and o.incomplete_dirs > 0) {
        try w.writeAll(&pad);
        try writeCounted(w, o.incomplete_dirs, "folder", "folders");
        try w.writeAll(" could not be read in full (permission, or only in iCloud).\n");
    }
    if (o.dataless_files > 0) {
        try w.writeAll(&pad);
        try writeCounted(w, o.dataless_files, "file", "files");
        try w.print(" {s} only in iCloud ({s} not on this disk).\n", .{
            if (o.dataless_files == 1) "is" else "are", formatSize(o.dataless_logical, q.units, &buf),
        });
    }
    if (o.hard_links > 0) {
        try w.writeAll(&pad);
        try writeCounted(w, o.hard_links, "extra hard link", "extra hard links");
        try w.writeAll(" counted once.\n");
    }
    if (o.removed_count > 0) {
        try w.writeAll(&pad);
        try writeCounted(w, o.removed_count, "item", "items");
        try w.print(" ({s}) moved to the Trash since the scan.\n", .{formatSize(o.removed_bytes, q.units, &buf)});
    }

    // By type, largest first; types with nothing are left out.
    try w.writeAll("\nBy Type\n");
    const types = try arena.dupe(TypeTotal, in.children.types);
    std.mem.sort(TypeTotal, types, {}, struct {
        fn lessThan(_: void, a: TypeTotal, b: TypeTotal) bool {
            return a.bytes > b.bytes;
        }
    }.lessThan);
    var type_total: u64 = 0;
    var label_len: usize = 0;
    var type_sizes: std.ArrayListUnmanaged(u64) = .empty;
    for (types) |t| {
        if (t.bytes == 0) continue;
        type_total += t.bytes;
        label_len = @max(label_len, typeLabel(t.type).len);
        try type_sizes.append(arena, t.bytes);
    }
    if (type_total == 0) try w.writeAll("  No files here.\n");
    const type_width = sizeWidth(q.units, type_sizes.items);
    for (types) |t| {
        if (t.bytes == 0) continue;
        const label = typeLabel(t.type);
        try w.writeAll("  ");
        try w.writeAll(label);
        try w.splatByteAll(' ', label_len - label.len);
        const size = formatSize(t.bytes, q.units, &buf);
        try w.writeAll("  ");
        try w.splatByteAll(' ', type_width - size.len);
        try w.writeAll(size);
        const percent = (@as(u128, t.bytes) * 200 + type_total) / (@as(u128, type_total) * 2);
        if (percent == 0) {
            try w.writeAll("   <1%\n");
        } else {
            try w.print("  {d: >3}%\n", .{percent});
        }
    }

    // What is directly inside, largest first, and what the list left out.
    try w.writeAll("\nContents\n");
    var listed: []const Node = &.{};
    var rest: Rest = .{};
    if (in.children.groups.len > 0) {
        listed = in.children.groups[0].items;
        rest = in.children.groups[0].rest;
    }
    {
        var sizes: std.ArrayListUnmanaged(u64) = .empty;
        for (listed) |item| try sizes.append(arena, item.bytes);
        if (rest.count > 0) try sizes.append(arena, rest.bytes);
        const width = sizeWidth(q.units, sizes.items);
        if (listed.len == 0) try w.writeAll("  Empty folder.\n");
        for (listed) |item| {
            const dir = !std.mem.eql(u8, item.kind, "file");
            const name = if (dir and !std.mem.endsWith(u8, item.name, "/"))
                try std.fmt.allocPrint(arena, "{s}/", .{item.name})
            else
                item.name;
            try writeSizeRow(w, q.units, item.bytes, width, name);
            try w.writeByte('\n');
        }
        if (rest.count > 0) {
            var more: Writer.Allocating = .init(arena);
            try writeCounted(&more.writer, rest.count, "more item", "more items");
            try writeSizeRow(w, q.units, rest.bytes, width, more.written());
            try w.writeByte('\n');
        }
    }

    try w.writeAll("\nLargest Folders\n");
    try writeList(arena, w, q.units, in.folders, "No folders below this one.");

    if (q.type) |t| {
        try w.print("\nTop {d} Files ({s})\n", .{ in.files.len, typeLabel(t) });
    } else {
        try w.print("\nTop {d} Files\n", .{in.files.len});
    }
    try writeList(arena, w, q.units, in.files, "No files here.");
}

/// Ranked items by full path, sizes aligned.
fn writeList(arena: Allocator, w: *Writer, units: Units, items: []const Node, empty: []const u8) !void {
    if (items.len == 0) {
        try w.print("  {s}\n", .{empty});
        return;
    }
    const sizes = try arena.alloc(u64, items.len);
    for (items, sizes) |item, *s| s.* = item.bytes;
    const width = sizeWidth(units, sizes);
    for (items) |item| {
        try writeSizeRow(w, units, item.bytes, width, item.path);
        try w.writeByte('\n');
    }
}

/// A file name for the saved report: "disk-space-<folder>-<scan date>.txt",
/// with the folder's name made safe for any file system, or
/// "disk-space-<scan date>.txt" for a folder with no name of its own ("/",
/// "C:\\") and for the whole of several roots.
pub fn fileName(arena: Allocator, in: Input) ![]u8 {
    const node = in.children.node;
    var name: []const u8 = "";
    if (!std.mem.eql(u8, node.kind, "all")) {
        const trimmed = std.mem.trimEnd(u8, node.path, "/\\");
        const cut = std.mem.lastIndexOfAny(u8, trimmed, "/\\");
        name = if (cut) |c| trimmed[c + 1 ..] else trimmed;
        if (name.len == 2 and name[1] == ':') name = "";
    }
    var safe: std.ArrayListUnmanaged(u8) = .empty;
    for (name) |c| {
        if (safe.items.len >= 80) break;
        const bad = c < 0x20 or c == 0x7f or std.mem.indexOfScalar(u8, "/\\:*?\"<>|", c) != null;
        try safe.append(arena, if (bad) '-' else c);
    }
    // Never cut a UTF-8 sequence in half, nor start with a dot (a hidden file).
    var end = safe.items.len;
    if (end < name.len) {
        while (end > 0 and name[end] & 0xC0 == 0x80) end -= 1;
    }
    var start: usize = 0;
    while (start < end and safe.items[start] == '.') start += 1;
    const folder = safe.items[start..end];
    const at = clockOf(in.overview.generated_at, in.query.utc_offset);
    if (folder.len == 0) {
        return std.fmt.allocPrint(arena, "disk-space-{d:0>4}-{d:0>2}-{d:0>2}.txt", .{ at.year, at.month, at.day });
    }
    return std.fmt.allocPrint(arena, "disk-space-{s}-{d:0>4}-{d:0>2}-{d:0>2}.txt", .{ folder, at.year, at.month, at.day });
}

// --- tests -------------------------------------------------------------------

const testing = std.testing;

fn expectSize(units: Units, bytes: u64, expected: []const u8) !void {
    var buf: [size_buf_len]u8 = undefined;
    testing.expectEqualStrings(expected, formatSize(bytes, units, &buf)) catch |err| {
        std.debug.print("bytes {d}\n", .{bytes});
        return err;
    };
}

// Anchor: Foundation's ByteCountFormatter (countStyle .file) on macOS 27,
// printed by a Swift script for each value; not this file's output.
test "decimal sizes are ByteCountFormatter's" {
    const cases = [_]struct { u64, []const u8 }{
        .{ 0, "Zero KB" },                         .{ 1, "1 byte" },
        .{ 2, "2 bytes" },                         .{ 999, "999 bytes" },
        .{ 1000, "1 KB" },                         .{ 1001, "1 KB" },
        .{ 1499, "1 KB" },                         .{ 1500, "2 KB" },
        .{ 999_499, "999 KB" },                    .{ 999_500, "1 MB" },
        .{ 999_999, "1 MB" },                      .{ 1_000_000, "1 MB" },
        .{ 1_049_999, "1 MB" },                    .{ 1_050_000, "1.1 MB" },
        .{ 644_600_000, "644.6 MB" },              .{ 644_649_999, "644.6 MB" },
        .{ 999_949_999, "999.9 MB" },              .{ 999_950_000, "1 GB" },
        .{ 1_000_000_000, "1 GB" },                .{ 1_064_999_999, "1.06 GB" },
        .{ 1_065_000_000, "1.07 GB" },             .{ 18_144_999_999, "18.14 GB" },
        .{ 303_710_000_000, "303.71 GB" },         .{ 999_994_999_999, "999.99 GB" },
        .{ 999_995_000_000, "1 TB" },              .{ 1_920_000_000_000, "1.92 TB" },
        .{ 2_000_000_000_000, "2 TB" },            .{ 1_234_567_890_123_456, "1.23 PB" },
        .{ 9_223_372_036_854_775_807, "9.22 EB" },
    };
    for (cases) |c| try expectSize(.decimal, c[0], c[1]);
}

// Anchor: the Svelte app's formatBytes (src/lib/utils/format.ts), run under
// Node for each value; not this file's output.
test "binary sizes are the Svelte app's formatBytes" {
    const cases = [_]struct { u64, []const u8 }{
        .{ 0, "0 B" },                         .{ 1, "1 B" },
        .{ 1023, "1023 B" },                   .{ 1024, "1.00 KB" },
        .{ 1025, "1.00 KB" },                  .{ 1152, "1.13 KB" },
        .{ 1535, "1.50 KB" },                  .{ 1536, "1.50 KB" },
        .{ 10485, "10.24 KB" },                .{ 1_048_575, "1024.00 KB" },
        .{ 1_048_576, "1.00 MB" },             .{ 1_073_741_823, "1024.00 MB" },
        .{ 1_073_741_824, "1.00 GB" },         .{ 5_368_709, "5.12 MB" },
        .{ 644_600_000, "614.74 MB" },         .{ 18_144_999_999, "16.90 GB" },
        .{ 303_710_000_000, "282.85 GB" },     .{ 1_099_511_627_775, "1024.00 GB" },
        .{ 1_099_511_627_776, "1.00 TB" },     .{ 2_000_000_000_000, "1.82 TB" },
        .{ 1_125_899_906_842_624, "1.00 PB" }, .{ 1_234_567_890_123_456, "1.10 PB" },
    };
    for (cases) |c| try expectSize(.binary, c[0], c[1]);
}

test "counts group digits in threes" {
    var out: Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    for ([_]u64{ 0, 7, 999, 1000, 584_019, 7_093_859, 18_446_744_073_709_551_615 }) |n| {
        try writeCount(&out.writer, n);
        try out.writer.writeByte(' ');
    }
    try testing.expectEqualStrings("0 7 999 1,000 584,019 7,093,859 18,446,744,073,709,551,615 ", out.written());
}

test "the scan time is read in the host's zone" {
    // 2026-11-07T19:54:30Z
    const at = clockOf(1_794_081_270_000, 0);
    try testing.expectEqual(Clock{ .year = 2026, .month = 11, .day = 7, .hour = 19, .minute = 54 }, at);
    // An hour east crosses midnight one way, five hours west the other.
    try testing.expectEqual(Clock{ .year = 2026, .month = 11, .day = 7, .hour = 20, .minute = 54 }, clockOf(1_794_081_270_000, 3600));
    try testing.expectEqual(Clock{ .year = 2026, .month = 11, .day = 8, .hour = 0, .minute = 24 }, clockOf(1_794_081_270_000, 16_200));
    try testing.expectEqual(Clock{ .year = 2026, .month = 11, .day = 7, .hour = 14, .minute = 54 }, clockOf(1_794_081_270_000, -18_000));
}

test "file names: the folder's own name, safe anywhere; none for a root without one" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const xs: [79]u8 = @splat('x');
    const long = xs ++ "\u{e9}";
    const cases = [_]struct { []const u8, []const u8, []const u8 }{
        .{ "dir", "/Users/director/work", "disk-space-work-2026-11-07.txt" },
        .{ "dir", "/Users/director/work/", "disk-space-work-2026-11-07.txt" },
        .{ "dir", "/", "disk-space-2026-11-07.txt" },
        .{ "dir", "C:\\", "disk-space-2026-11-07.txt" },
        .{ "dir", "C:\\Users\\rich\\Videos", "disk-space-Videos-2026-11-07.txt" },
        .{ "dir", "/home/x/a:b*c?", "disk-space-a-b-c--2026-11-07.txt" },
        .{ "dir", "/home/x/.config", "disk-space-config-2026-11-07.txt" },
        .{ "dir", "/home/x/..", "disk-space-2026-11-07.txt" },
        // 80 bytes kept, and the two-byte e-acute that starts at byte 79 left out whole.
        .{ "dir", "/home/x/" ++ long, "disk-space-" ++ xs ++ "-2026-11-07.txt" },
        .{ "all", "", "disk-space-2026-11-07.txt" },
    };
    for (cases) |c| {
        const in: Input = .{
            .query = .{},
            .overview = .{
                .roots = &.{},
                .generated_at = 1_794_081_270_000,
                .volume = .{ .mount = "/", .total = 0, .free = 0, .available = 0 },
                .files = 0,
                .dirs = 0,
                .bytes = 0,
            },
            .children = .{ .node = .{ .kind = c[0], .name = "", .path = c[1], .bytes = 0 }, .types = &.{}, .groups = &.{} },
            .folders = &.{},
            .files = &.{},
        };
        try testing.expectEqualStrings(c[2], try fileName(arena, in));
    }
}
