//! The duplicates report: a duplicate scan's findings as plain text, for a
//! person to read, paste or save. It is rendered from the answers a host
//! reads (overview, group pages, set pages and their members, overlap pages),
//! in the order and with the filters the host's lists use, so it states what
//! the screens state, with full paths where a screen shortens them.
//!
//! Sizes are written as the host writes them (space_report.Units).

const std = @import("std");
const space_report = @import("space_report.zig");
const filters_mod = @import("filters.zig");

const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const Filters = filters_mod.Filters;

pub const Units = space_report.Units;

// The parts of the session's answers the report reads. Field names are the
// wire names (schema/results-session.schema.json); everything else is ignored.

pub const Overview = struct {
    roots: []const []const u8 = &.{},
    generated_at: i64 = 0,
    files_scanned: u64 = 0,
    bytes_scanned: u64 = 0,
    duplicate_groups: u64 = 0,
    duplicate_files: u64 = 0,
    space_savings: u64 = 0,
    scan_time_ns: u64 = 0,
    failed_paths: u64 = 0,
    dataless_skipped: u64 = 0,
    dataless_bytes: u64 = 0,
    has_directories: bool = false,
    dirs_analyzed: u64 = 0,
    dirs_incomplete: u64 = 0,
    identical_sets: u64 = 0,
    overlaps: u64 = 0,
    redundant_pairs: u64 = 0,
    overlaps_capped: bool = false,
    reclaimable: u64 = 0,
    deletable_savings: u64 = 0,
    deletable_reclaimable: u64 = 0,
};

pub const GroupRow = struct {
    count: u64 = 0,
    size: u64 = 0,
    savings: u64 = 0,
    deletable: u64 = 0,
    files: []const []const u8 = &.{},
    mtimes: []const i64 = &.{},
    keeper: ?[]const u8 = null,
    locked: []const bool = &.{},
    clones: []const u32 = &.{},
    elsewhere: []const bool = &.{},
};

pub const Dir = struct {
    path: []const u8,
    newest_mtime: i64 = 0,
    locked: bool = false,
    storage_class: u32 = 0,
};

pub const SetRow = struct {
    index: u64 = 0,
    count: u64 = 0,
    file_count: u64 = 0,
    bytes: u64 = 0,
    reclaimable: u64 = 0,
    deletable: u64 = 0,
    dirs: []const Dir = &.{},
};

pub const Side = struct {
    path: []const u8,
    files: u64 = 0,
    bytes: u64 = 0,
    complete: bool = true,
    identical_copies: u64 = 1,
    shared_files: u64 = 0,
    shared_bytes: u64 = 0,
    only_count: u64 = 0,
    only: []const []const u8 = &.{},
};

pub const OverlapRow = struct {
    relation: []const u8,
    a: Side,
    b: Side,
};

/// Orders, by their wire names.
pub const GroupSort = enum { savings, size, count };
pub const SetSort = enum { reclaim, size, count };

pub const Groups = struct {
    sort: GroupSort,
    filters: Filters,
    /// Matching groups in all, and the first of them in order.
    total: u64,
    rows: []const GroupRow,
    /// Files listed per group.
    files: usize,
};

pub const Sets = struct {
    sort: SetSort,
    filters: Filters,
    total: u64,
    /// Each row's `dirs` holds every alive member up to `dirs`, in path order.
    rows: []const SetRow,
    dirs: usize,
};

pub const Overlaps = struct {
    filters: Filters,
    total: u64,
    rows: []const OverlapRow,
    /// Paths listed per side from what only it holds.
    only: usize,
};

pub const Input = struct {
    units: Units,
    /// Seconds east of UTC, for times in the reader's time zone.
    utc_offset: i32,
    overview: Overview,
    /// Files and folders deleted through these results since the scan.
    removed: u64,
    groups: ?Groups,
    sets: ?Sets,
    overlaps: ?Overlaps,
};

const size_buf_len = space_report.size_buf_len;
const writeCount = space_report.writeCount;
const writeCounted = space_report.writeCounted;

const label_width = 10;

fn writeLabel(w: *Writer, label: []const u8) Writer.Error!void {
    try w.writeAll(label);
    try w.splatByteAll(' ', label_width -| label.len);
}

fn size(bytes: u64, units: Units, buf: *[size_buf_len]u8) []const u8 {
    return space_report.formatSize(bytes, units, buf);
}

/// A size threshold as a list's filter names it: "1 MB or more", without
/// the formatter's trailing zeros.
fn writeThreshold(w: *Writer, bytes: u64, units: Units) Writer.Error!void {
    var buf: [size_buf_len]u8 = undefined;
    const text = size(bytes, units, &buf);
    const space = std.mem.indexOfScalar(u8, text, ' ') orelse text.len;
    var number = text[0..space];
    if (std.mem.indexOfScalar(u8, number, '.') != null) {
        number = std.mem.trimEnd(u8, number, "0");
        number = std.mem.trimEnd(u8, number, ".");
    }
    try w.print("{s}{s} or more", .{ number, text[space..] });
}

fn writeDate(w: *Writer, millis: i64, utc_offset: i32) Writer.Error!void {
    const at = space_report.clockOf(millis, utc_offset);
    try w.print("{d:0>4}-{d:0>2}-{d:0>2}", .{ at.year, at.month, at.day });
}

/// "45 s", "3 min 12 s", "1 h 4 min".
fn writeDuration(w: *Writer, ns: u64) Writer.Error!void {
    const seconds = ns / std.time.ns_per_s;
    if (seconds < 60) return w.print("{d} s", .{seconds});
    if (seconds < 3600) return w.print("{d} min {d} s", .{ seconds / 60, seconds % 60 });
    return w.print("{d} h {d} min", .{ seconds / 3600, (seconds % 3600) / 60 });
}

/// What narrows a list, after its order, as the apps describe their lists.
/// `redundant_only` narrows only the overlap list; every other list ignores it.
fn writeFilters(w: *Writer, f: Filters, units: Units, overlaps: bool) Writer.Error!void {
    if (overlaps and f.redundant_only) try w.writeAll(" · partial overlaps hidden");
    if (f.under) |under| try w.print(" · in {s}", .{under});
    if (f.name) |name| try w.print(" · named {s}", .{name});
    if (f.ext) |ext| {
        if (ext.len == 0) try w.writeAll(" · no extension") else try w.print(" · {s}", .{ext});
    }
    const text = std.mem.trim(u8, f.text, " \t");
    if (text.len > 0) try w.print(" · path contains \"{s}\"", .{text});
    if (f.min_bytes > 0) {
        try w.writeAll(" · ");
        try writeThreshold(w, f.min_bytes, units);
    }
}

/// "1,504 sets · sorted by ... · 1 MB or more. The first 50:" and the like.
fn writeListHead(w: *Writer, total: u64, one: []const u8, many: []const u8, order: ?[]const u8, f: Filters, units: Units, listed: usize, overlaps: bool) Writer.Error!void {
    try writeCounted(w, total, one, many);
    if (order) |o| try w.print(" · sorted by {s}", .{o});
    try writeFilters(w, f, units, overlaps);
    if (total == 0) return w.writeAll(". None match.\n");
    if (listed >= total) return w.writeAll(". All of them:\n");
    try w.writeAll(". The first ");
    try writeCount(w, listed);
    try w.writeAll(":\n");
}

/// The number of the first earlier entry of `classes` sharing `classes[i]`
/// (1-based), or null when there is none.
fn sharedWith(comptime T: type, classes: []const T, i: usize) ?usize {
    if (i >= classes.len or classes[i] == 0) return null;
    for (classes[0..i], 0..) |c, j| {
        if (c == classes[i]) return j + 1;
    }
    return null;
}

/// "1.02 GB to reclaim", then `how` (" as whole folders" or empty), and
/// what protected locations keep of `all` beside it: `deletable` is what
/// deleting the copies that may go frees.
fn writeReclaim(w: *Writer, deletable: u64, all: u64, how: []const u8, units: Units) Writer.Error!void {
    var buf: [size_buf_len]u8 = undefined;
    const kept = all -| deletable;
    if (deletable == 0 and kept > 0) {
        return w.print("nothing to reclaim{s} ({s} is kept by protected locations)", .{ how, size(kept, units, &buf) });
    }
    try w.print("{s} to reclaim{s}", .{ size(deletable, units, &buf), how });
    if (kept > 0) try w.print(" ({s} more is kept by protected locations)", .{size(kept, units, &buf)});
}

fn baseName(path: []const u8) []const u8 {
    const trimmed = std.mem.trimEnd(u8, path, "/\\");
    const cut = std.mem.lastIndexOfAny(u8, trimmed, "/\\") orelse return trimmed;
    if (cut + 1 == trimmed.len) return trimmed;
    return trimmed[cut + 1 ..];
}

/// The report, as UTF-8 text ending in a newline.
pub fn render(w: *Writer, in: Input) !void {
    const o = in.overview;
    const u = in.units;
    var buf: [size_buf_len]u8 = undefined;
    const pad: [label_width]u8 = @splat(' ');

    try w.writeAll("Duplicates Report\n\n");

    const at = space_report.clockOf(o.generated_at, in.utc_offset);
    try writeLabel(w, "Scanned:");
    for (o.roots, 0..) |root, i| {
        if (i > 0) try w.writeAll(", ");
        try w.writeAll(root);
    }
    try w.print(" on {d:0>4}-{d:0>2}-{d:0>2} at {d:0>2}:{d:0>2}, ", .{ at.year, at.month, at.day, at.hour, at.minute });
    try writeCounted(w, o.files_scanned, "file", "files");
    try w.print(" ({s}) in ", .{size(o.bytes_scanned, u, &buf)});
    try writeDuration(w, o.scan_time_ns);
    try w.writeByte('\n');

    try writeLabel(w, "Files:");
    try writeCounted(w, o.duplicate_files, "duplicate file", "duplicate files");
    try w.writeAll(" in ");
    try writeCounted(w, o.duplicate_groups, "group", "groups");
    try w.writeAll(", ");
    try writeReclaim(w, o.deletable_savings, o.space_savings, "", u);
    try w.writeByte('\n');

    if (o.has_directories) {
        try writeLabel(w, "Folders:");
        try writeCounted(w, o.identical_sets, "identical folder set", "identical folder sets");
        try w.writeAll(", ");
        try writeReclaim(w, o.deletable_reclaimable, o.reclaimable, " as whole folders", u);
        try w.writeByte('\n');
        try w.writeAll(&pad);
        if (o.overlaps_capped) {
            try w.writeAll("the ");
            try writeCount(w, o.overlaps);
            try w.writeAll(" largest overlapping pairs");
        } else {
            try writeCounted(w, o.overlaps, "overlapping pair", "overlapping pairs");
        }
        try w.writeAll(", ");
        try writeCount(w, o.redundant_pairs);
        try w.writeAll(" where one folder holds all of the other\n");
        try w.writeAll(&pad);
        try writeCounted(w, o.dirs_analyzed, "folder", "folders");
        try w.writeAll(" compared");
        if (o.dirs_incomplete > 0) {
            try w.writeAll(", ");
            try writeCount(w, o.dirs_incomplete);
            try w.writeAll(" could not be read completely and are not offered for deletion");
        }
        try w.writeAll("\n");
    }
    if (o.failed_paths > 0) {
        try w.writeAll(&pad);
        try writeCounted(w, o.failed_paths, "folder", "folders");
        try w.writeAll(" given to the scan could not be read.\n");
    }
    if (o.dataless_skipped > 0) {
        try w.writeAll(&pad);
        try writeCounted(w, o.dataless_skipped, "file", "files");
        try w.print(" only in iCloud {s} not compared ({s} not on this disk).\n", .{
            if (o.dataless_skipped == 1) "was" else "were", size(o.dataless_bytes, u, &buf),
        });
    }
    try w.writeAll(&pad);
    try w.writeAll("These figures are the scan's.");
    if (in.removed > 0) {
        try w.writeAll(" ");
        try writeCounted(w, in.removed, "item", "items");
        try w.writeAll(" deleted since are left out of the lists below.");
    }
    try w.writeByte('\n');

    if (in.sets) |sets| if (o.has_directories) try renderSets(w, sets, in);
    if (in.overlaps) |overlaps| if (o.has_directories) try renderOverlaps(w, overlaps, in);
    if (in.groups) |groups| try renderGroups(w, groups, in);
}

fn renderSets(w: *Writer, sets: Sets, in: Input) !void {
    const u = in.units;
    var buf: [size_buf_len]u8 = undefined;
    try w.writeAll("\nIdentical Folders\n");
    try writeListHead(w, sets.total, "set", "sets", switch (sets.sort) {
        .reclaim => "space to reclaim",
        .size => "size of one copy",
        .count => "copies",
    }, sets.filters, u, sets.rows.len, false);
    for (sets.rows, 1..) |row, n| {
        const first = if (row.dirs.len > 0) row.dirs[0].path else "";
        try w.print("\n{d}. {s}\n   ", .{ n, baseName(first) });
        try writeCounted(w, row.count, "copy", "copies");
        try w.writeAll(" · ");
        try writeCounted(w, row.file_count, "file", "files");
        try w.print(" · {s} each · ", .{size(row.bytes, u, &buf)});
        try writeReclaim(w, row.deletable, row.reclaimable, "", u);
        try w.writeByte('\n');

        var classes: [256]u32 = undefined;
        const listed = row.dirs[0..@min(row.dirs.len, sets.dirs, classes.len)];
        for (listed, 0..) |dir, i| classes[i] = dir.storage_class;
        for (listed, 0..) |dir, i| {
            try w.print("   {s}  (newest file ", .{dir.path});
            try writeDate(w, dir.newest_mtime, in.utc_offset);
            if (dir.locked) try w.writeAll(", protected");
            if (sharedWith(u32, classes[0..listed.len], i)) |copy| {
                try w.print(", shares its storage with copy {d}", .{copy});
            }
            try w.writeAll(")\n");
        }
        if (row.count > listed.len) {
            try w.writeAll("   and ");
            try writeCount(w, row.count - listed.len);
            try w.writeAll(" more\n");
        }
    }
}

fn renderOverlaps(w: *Writer, overlaps: Overlaps, in: Input) !void {
    const u = in.units;
    var buf: [size_buf_len]u8 = undefined;
    try w.writeAll("\nOverlapping Folders\n");
    try writeListHead(w, overlaps.total, "pair", "pairs", "shared size", overlaps.filters, u, overlaps.rows.len, true);
    if (in.overview.overlaps_capped) {
        try w.writeAll("The scan kept the ");
        try writeCount(w, in.overview.overlaps);
        try w.writeAll(" largest pairs; more folders may overlap.\n");
    }
    for (overlaps.rows, 1..) |row, n| {
        try w.print("\n{d}. ", .{n});
        if (std.mem.eql(u8, row.relation, "same_content")) {
            try w.writeAll("A and B hold the same files, named or arranged differently\n");
        } else if (std.mem.eql(u8, row.relation, "a_in_b")) {
            try w.writeAll("B holds all of A\n");
        } else if (std.mem.eql(u8, row.relation, "b_in_a")) {
            try w.writeAll("A holds all of B\n");
        } else {
            try w.writeAll("Each holds files the other does not\n");
        }
        for ([_]struct { []const u8, Side }{ .{ "A", row.a }, .{ "B", row.b } }) |entry| {
            const name, const side = entry;
            try w.print("   {s}: {s}\n      ", .{ name, side.path });
            try writeCounted(w, side.files, "file", "files");
            try w.print(" · {s} · shares ", .{size(side.bytes, u, &buf)});
            try writeCounted(w, side.shared_files, "file", "files");
            try w.print(" ({s})", .{size(side.shared_bytes, u, &buf)});
            if (side.only_count == 0) {
                try w.writeAll(" · nothing only here");
            } else {
                try w.writeAll(" · ");
                try writeCounted(w, side.only_count, "file", "files");
                try w.writeAll(" only here");
            }
            if (!side.complete) try w.writeAll(" · could not be read completely");
            if (side.identical_copies > 1) {
                try w.writeAll(" · stands for ");
                try writeCount(w, side.identical_copies);
                try w.writeAll(" identical copies");
            }
            try w.writeByte('\n');
            const only = side.only[0..@min(side.only.len, overlaps.only)];
            for (only) |path| try w.print("        only here: {s}\n", .{path});
            if (side.only_count > only.len and only.len > 0) {
                try w.writeAll("        and ");
                try writeCount(w, side.only_count - only.len);
                try w.writeAll(" more only here\n");
            }
        }
    }
}

fn renderGroups(w: *Writer, groups: Groups, in: Input) !void {
    const u = in.units;
    var buf: [size_buf_len]u8 = undefined;
    try w.writeAll("\nDuplicate Files\n");
    try writeListHead(w, groups.total, "group", "groups", switch (groups.sort) {
        .savings => "space to reclaim",
        .size => "file size",
        .count => "copies",
    }, groups.filters, u, groups.rows.len, false);
    for (groups.rows, 1..) |row, n| {
        try w.print("\n{d}. {s} each · ", .{ n, size(row.size, u, &buf) });
        try writeCounted(w, row.count, "copy", "copies");
        try w.writeAll(" · ");
        try writeReclaim(w, row.deletable, row.savings, "", u);
        try w.writeByte('\n');
        const listed = row.files[0..@min(row.files.len, groups.files)];
        for (listed, 0..) |path, i| {
            const kept = if (row.keeper) |k| std.mem.eql(u8, k, path) else false;
            try w.print("   {s} {s}  (modified ", .{ if (kept) "keep" else "    ", path });
            if (i < row.mtimes.len) try writeDate(w, row.mtimes[i], in.utc_offset);
            if (i < row.locked.len and row.locked[i]) try w.writeAll(", protected");
            if (sharedWith(u32, row.clones[0..@min(row.clones.len, listed.len)], i)) |copy| {
                try w.print(", clone of copy {d}", .{copy});
            }
            if (i < row.elsewhere.len and row.elsewhere[i]) {
                try w.writeAll(", shares its storage with a file outside the scan");
            }
            try w.writeAll(")\n");
        }
        if (row.count > listed.len) {
            try w.writeAll("   and ");
            try writeCount(w, row.count - listed.len);
            try w.writeAll(" more");
            if (row.keeper) |k| {
                var shown = false;
                for (listed) |path| shown = shown or std.mem.eql(u8, path, k);
                if (!shown) try w.print("; keeps {s}", .{k});
            }
            try w.writeByte('\n');
        }
    }
}

/// "duplicates-<root's name>-<scan date>.txt" for one root with a name,
/// "duplicates-<scan date>.txt" otherwise.
pub fn fileName(arena: Allocator, in: Input) ![]u8 {
    const root: ?[]const u8 = if (in.overview.roots.len == 1) in.overview.roots[0] else null;
    return space_report.namedFile(arena, "duplicates", root, in.overview.generated_at, in.utc_offset);
}

// --- tests -------------------------------------------------------------------

const testing = std.testing;

test "a threshold drops the formatter's trailing zeros" {
    var out: Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try writeThreshold(&out.writer, 1024 * 1024, .binary);
    try out.writer.writeAll("|");
    try writeThreshold(&out.writer, 1_000_000, .decimal);
    try out.writer.writeAll("|");
    try writeThreshold(&out.writer, 1536 * 1024, .binary);
    try testing.expectEqualStrings("1 MB or more|1 MB or more|1.5 MB or more", out.written());
}

test "durations read in the largest units that fit" {
    var out: Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try writeDuration(&out.writer, 45 * std.time.ns_per_s);
    try out.writer.writeAll("|");
    try writeDuration(&out.writer, 192 * std.time.ns_per_s);
    try out.writer.writeAll("|");
    try writeDuration(&out.writer, 3840 * std.time.ns_per_s);
    try testing.expectEqualStrings("45 s|3 min 12 s|1 h 4 min", out.written());
}

test "a clone names the first listed copy of its class" {
    const classes = [_]u32{ 0, 1, 2, 1, 1 };
    try testing.expectEqual(@as(?usize, null), sharedWith(u32, &classes, 0));
    try testing.expectEqual(@as(?usize, null), sharedWith(u32, &classes, 1));
    try testing.expectEqual(@as(?usize, null), sharedWith(u32, &classes, 2));
    try testing.expectEqual(@as(?usize, 2), sharedWith(u32, &classes, 3));
    try testing.expectEqual(@as(?usize, 2), sharedWith(u32, &classes, 4));
}

test "space to reclaim is what can be deleted, with what protected locations keep beside it" {
    var out: Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try writeReclaim(&out.writer, 1024, 1024, "", .binary);
    try out.writer.writeAll("|");
    try writeReclaim(&out.writer, 1024, 3072, " as whole folders", .binary);
    try out.writer.writeAll("|");
    try writeReclaim(&out.writer, 0, 2048, "", .binary);
    try testing.expectEqualStrings("1.00 KB to reclaim|" ++
        "1.00 KB to reclaim as whole folders (2.00 KB more is kept by protected locations)|" ++
        "nothing to reclaim (2.00 KB is kept by protected locations)", out.written());
}

test "only the overlap list says partial overlaps are hidden" {
    var out: Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    const f: Filters = .{ .redundant_only = true, .min_bytes = 1024 };
    try writeFilters(&out.writer, f, .binary, false);
    try out.writer.writeAll("|");
    try writeFilters(&out.writer, f, .binary, true);
    try testing.expectEqualStrings(" · 1 KB or more| · partial overlaps hidden · 1 KB or more", out.written());
}
