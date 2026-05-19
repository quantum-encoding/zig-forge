// Region — the unit of work the blame walker passes around.
//
// A `Region` describes a contiguous run of lines that are currently
// being traced together: they all need attribution and they all live
// in the same blob at the same commit's frame of reference.
//
//   blob_line_*    — 1-based, inclusive, line range within the current
//                    frame's blob (`current_commit`).
//   target_line_*  — 1-based, inclusive, line range in the TARGET file
//                    (the blob at the ref we're blaming). Stable for
//                    the duration of the walk — that's where the
//                    eventual attribution gets written.
//
// `splitRegionAgainstDiff` is the core helper: given a region in a
// child commit's frame and a Myers diff from parent to child, produce
//   * a list of sub-regions whose lines existed unchanged in parent
//     (with their blob_line range expressed in parent's coordinates,
//     and current_commit updated to the parent OID), and
//   * a list of sub-regions whose lines were added in the child (still
//     in child's frame, current_commit unchanged).
//
// For single-parent commits the caller attributes the second list to
// the child and pushes the first list onto the work queue. For merge
// commits the caller carries the second list forward to the next
// parent in turn, attributing to the merge only if it survives every
// parent.

const std = @import("std");
const Oid = @import("../object/oid.zig").Oid;
const myers = @import("../diff/myers.zig");

pub const Region = struct {
    /// The commit whose blob's line numbers `blob_line_*` indexes into.
    current_commit: Oid,
    /// 1-based, inclusive.
    blob_line_start: u32,
    blob_line_end: u32,
    /// 1-based line range in the TARGET file (the blame query's
    /// reference frame). `target_line_end - target_line_start`
    /// equals `blob_line_end - blob_line_start`.
    target_line_start: u32,
    target_line_end: u32,

    pub fn lineCount(self: Region) u32 {
        return self.blob_line_end - self.blob_line_start + 1;
    }

    pub fn isValid(self: Region) bool {
        if (self.blob_line_start == 0 or self.target_line_start == 0) return false;
        if (self.blob_line_end < self.blob_line_start) return false;
        if (self.target_line_end < self.target_line_start) return false;
        return (self.blob_line_end - self.blob_line_start) ==
            (self.target_line_end - self.target_line_start);
    }
};

pub const SplitResult = struct {
    /// Lines that existed unchanged in `parent_oid` — push these onto
    /// the work queue keyed by parent.
    carry_to_parent: []Region,
    /// Lines added in the child relative to the parent. Still in the
    /// child's frame. For single-parent commits the caller attributes
    /// these to the child. For merges the caller carries them forward
    /// to the next parent.
    residue_in_commit: []Region,

    pub fn deinit(self: *SplitResult, allocator: std.mem.Allocator) void {
        allocator.free(self.carry_to_parent);
        allocator.free(self.residue_in_commit);
        self.* = undefined;
    }
};

/// Walk the Myers edit script once, classifying each child-blob line
/// (the `b_idx` side) that falls in `region.blob_line_*`:
///   * `.equal`  → matched parent at `a_idx + 1` — carry to parent.
///   * `.insert` → added in child — residue.
///   * `.delete` → no child line, skipped.
///
/// Consecutive same-disposition lines are coalesced into contiguous
/// sub-regions. The diff's edit list MUST be in walk order (which is
/// what `myers.diff` returns).
///
/// `parent_oid` becomes `current_commit` for the carried sub-regions.
pub fn splitRegionAgainstDiff(
    allocator: std.mem.Allocator,
    region: Region,
    edits: []const myers.Edit,
    parent_oid: Oid,
) !SplitResult {
    std.debug.assert(region.isValid());

    var carry: std.ArrayListUnmanaged(Region) = .empty;
    errdefer carry.deinit(allocator);
    var residue: std.ArrayListUnmanaged(Region) = .empty;
    errdefer residue.deinit(allocator);

    // `target_offset` translates a 1-based child-blob line into the
    // 1-based target file line:
    //     target_line = blob_line + target_offset
    const target_offset: i64 = @as(i64, region.target_line_start) - @as(i64, region.blob_line_start);

    const Group = struct {
        const Kind = enum { carry, residue, none };
        kind: Kind,
        // For .carry: parent line range (1-based).
        // For .residue: child line range (1-based).
        line_start: u32,
        line_end: u32,
        // The child blob_line of the first line in the group — used to
        // compute the target line range when flushing.
        first_blob_line: u32,
    };

    var current: Group = .{ .kind = .none, .line_start = 0, .line_end = 0, .first_blob_line = 0 };

    const flush = struct {
        fn call(
            a: std.mem.Allocator,
            carry_list: *std.ArrayListUnmanaged(Region),
            residue_list: *std.ArrayListUnmanaged(Region),
            g: Group,
            r: Region,
            p_oid: Oid,
            t_offset: i64,
        ) !void {
            if (g.kind == .none) return;
            const group_len: u32 = g.line_end - g.line_start + 1;
            // The first child blob line in this group, used to anchor
            // the target line range.
            const blob_line_of_first: u32 = g.first_blob_line;
            const target_start: u32 = @intCast(@as(i64, blob_line_of_first) + t_offset);
            const target_end: u32 = target_start + group_len - 1;
            const out = Region{
                .current_commit = if (g.kind == .carry) p_oid else r.current_commit,
                .blob_line_start = g.line_start,
                .blob_line_end = g.line_end,
                .target_line_start = target_start,
                .target_line_end = target_end,
            };
            switch (g.kind) {
                .carry => try carry_list.append(a, out),
                .residue => try residue_list.append(a, out),
                .none => unreachable,
            }
        }
    }.call;

    for (edits) |e| {
        switch (e.op) {
            .delete => continue, // line lived in parent, not in child
            .equal, .insert => {
                const child_blob_line: u32 = @intCast(e.b_idx + 1);
                // Skip child lines outside this region.
                if (child_blob_line < region.blob_line_start) continue;
                if (child_blob_line > region.blob_line_end) {
                    // We've walked past the region's end. The edit list
                    // is in order, so nothing further will be in range.
                    break;
                }
                const kind: Group.Kind = if (e.op == .equal) .carry else .residue;
                const line_val: u32 = switch (e.op) {
                    .equal => @intCast(e.a_idx + 1), // parent line
                    .insert => child_blob_line, // residue uses child lines
                    else => unreachable,
                };

                if (current.kind == kind and line_val == current.line_end + 1) {
                    // Same disposition AND contiguous → extend.
                    current.line_end = line_val;
                } else {
                    try flush(allocator, &carry, &residue, current, region, parent_oid, target_offset);
                    current = .{
                        .kind = kind,
                        .line_start = line_val,
                        .line_end = line_val,
                        .first_blob_line = child_blob_line,
                    };
                }
            },
        }
    }

    try flush(allocator, &carry, &residue, current, region, parent_oid, target_offset);

    return .{
        .carry_to_parent = try carry.toOwnedSlice(allocator),
        .residue_in_commit = try residue.toOwnedSlice(allocator),
    };
}

/// Coalesce a list of regions into the smallest set of contiguous
/// regions that cover the same target line numbers. Two regions can
/// merge when their `current_commit` matches and their blob_line and
/// target_line ranges are immediately adjacent (no gap, no overlap).
///
/// Mutates the slice in place; returns the new length. The trimmed
/// tail is left undefined.
pub fn coalesceContiguous(regions: []Region) usize {
    if (regions.len < 2) return regions.len;

    // Sort by (current_commit.bytes, blob_line_start).
    std.mem.sort(Region, regions, {}, struct {
        fn lt(_: void, a: Region, b: Region) bool {
            const cmp = std.mem.order(u8, &a.current_commit.bytes, &b.current_commit.bytes);
            if (cmp != .eq) return cmp == .lt;
            return a.blob_line_start < b.blob_line_start;
        }
    }.lt);

    var write_idx: usize = 0;
    var cur = regions[0];
    var i: usize = 1;
    while (i < regions.len) : (i += 1) {
        const next = regions[i];
        const same_commit = cur.current_commit.eql(next.current_commit);
        const blob_adjacent = cur.blob_line_end + 1 == next.blob_line_start;
        const target_adjacent = cur.target_line_end + 1 == next.target_line_start;
        if (same_commit and blob_adjacent and target_adjacent) {
            cur.blob_line_end = next.blob_line_end;
            cur.target_line_end = next.target_line_end;
        } else {
            regions[write_idx] = cur;
            write_idx += 1;
            cur = next;
        }
    }
    regions[write_idx] = cur;
    return write_idx + 1;
}

// ── Tests ─────────────────────────────────────────────────────────

const testing = std.testing;

fn makeOid(byte: u8) Oid {
    var o: Oid = undefined;
    @memset(&o.bytes, byte);
    return o;
}

test "Region.isValid catches misaligned ranges" {
    const oid = makeOid(0x11);
    try testing.expect((Region{
        .current_commit = oid,
        .blob_line_start = 1,
        .blob_line_end = 5,
        .target_line_start = 10,
        .target_line_end = 14,
    }).isValid());

    // blob range is 5 lines, target is 4 lines — invalid.
    try testing.expect(!(Region{
        .current_commit = oid,
        .blob_line_start = 1,
        .blob_line_end = 5,
        .target_line_start = 10,
        .target_line_end = 13,
    }).isValid());

    // zero blob_line_start (must be 1-based).
    try testing.expect(!(Region{
        .current_commit = oid,
        .blob_line_start = 0,
        .blob_line_end = 4,
        .target_line_start = 1,
        .target_line_end = 5,
    }).isValid());
}

test "split: file unchanged → entire region carried to parent" {
    const allocator = testing.allocator;
    const child = makeOid(0xAA);
    const parent = makeOid(0xBB);

    // Three identical lines.
    const edits = [_]myers.Edit{
        .{ .op = .equal, .a_idx = 0, .b_idx = 0 },
        .{ .op = .equal, .a_idx = 1, .b_idx = 1 },
        .{ .op = .equal, .a_idx = 2, .b_idx = 2 },
    };

    var result = try splitRegionAgainstDiff(allocator, .{
        .current_commit = child,
        .blob_line_start = 1,
        .blob_line_end = 3,
        .target_line_start = 1,
        .target_line_end = 3,
    }, &edits, parent);
    defer result.deinit(allocator);

    try testing.expectEqual(@as(usize, 1), result.carry_to_parent.len);
    try testing.expectEqual(@as(usize, 0), result.residue_in_commit.len);

    const r = result.carry_to_parent[0];
    try testing.expect(r.current_commit.eql(parent));
    try testing.expectEqual(@as(u32, 1), r.blob_line_start);
    try testing.expectEqual(@as(u32, 3), r.blob_line_end);
    try testing.expectEqual(@as(u32, 1), r.target_line_start);
    try testing.expectEqual(@as(u32, 3), r.target_line_end);
}

test "split: pure insert → entire region is residue" {
    const allocator = testing.allocator;
    const child = makeOid(0xAA);
    const parent = makeOid(0xBB);

    // Parent was empty; child has three new lines.
    const edits = [_]myers.Edit{
        .{ .op = .insert, .a_idx = 0, .b_idx = 0 },
        .{ .op = .insert, .a_idx = 0, .b_idx = 1 },
        .{ .op = .insert, .a_idx = 0, .b_idx = 2 },
    };

    var result = try splitRegionAgainstDiff(allocator, .{
        .current_commit = child,
        .blob_line_start = 1,
        .blob_line_end = 3,
        .target_line_start = 1,
        .target_line_end = 3,
    }, &edits, parent);
    defer result.deinit(allocator);

    try testing.expectEqual(@as(usize, 0), result.carry_to_parent.len);
    try testing.expectEqual(@as(usize, 1), result.residue_in_commit.len);

    const r = result.residue_in_commit[0];
    try testing.expect(r.current_commit.eql(child)); // residue stays in child's frame
    try testing.expectEqual(@as(u32, 1), r.blob_line_start);
    try testing.expectEqual(@as(u32, 3), r.blob_line_end);
}

test "split: mid-file change — parent 1,2,3,4,5 → child 1,2,X,Y,4,5" {
    // Parent has 5 lines; child replaces line 3 with two new lines (X,Y)
    // and keeps the rest. Child blob is now 6 lines long.
    // Myers edits we hand-construct (one of several valid scripts):
    //   equal  a=0 b=0    parent[1] == child[1]
    //   equal  a=1 b=1    parent[2] == child[2]
    //   delete a=2        parent[3] (the old line) removed
    //   insert       b=2  child[3] (X) new
    //   insert       b=3  child[4] (Y) new
    //   equal  a=3 b=4    parent[4] == child[5]
    //   equal  a=4 b=5    parent[5] == child[6]
    const allocator = testing.allocator;
    const child = makeOid(0xAA);
    const parent = makeOid(0xBB);

    const edits = [_]myers.Edit{
        .{ .op = .equal, .a_idx = 0, .b_idx = 0 },
        .{ .op = .equal, .a_idx = 1, .b_idx = 1 },
        .{ .op = .delete, .a_idx = 2, .b_idx = 0 },
        .{ .op = .insert, .a_idx = 0, .b_idx = 2 },
        .{ .op = .insert, .a_idx = 0, .b_idx = 3 },
        .{ .op = .equal, .a_idx = 3, .b_idx = 4 },
        .{ .op = .equal, .a_idx = 4, .b_idx = 5 },
    };

    var result = try splitRegionAgainstDiff(allocator, .{
        .current_commit = child,
        .blob_line_start = 1,
        .blob_line_end = 6,
        .target_line_start = 1,
        .target_line_end = 6,
    }, &edits, parent);
    defer result.deinit(allocator);

    // Expect 2 carry sub-regions (lines 1–2 and lines 5–6 from parent)
    // and 1 residue sub-region (lines 3–4 in child).
    try testing.expectEqual(@as(usize, 2), result.carry_to_parent.len);
    try testing.expectEqual(@as(usize, 1), result.residue_in_commit.len);

    // First carry: child lines 1–2 ↔ parent lines 1–2.
    try testing.expectEqual(@as(u32, 1), result.carry_to_parent[0].blob_line_start);
    try testing.expectEqual(@as(u32, 2), result.carry_to_parent[0].blob_line_end);
    try testing.expectEqual(@as(u32, 1), result.carry_to_parent[0].target_line_start);
    try testing.expectEqual(@as(u32, 2), result.carry_to_parent[0].target_line_end);
    try testing.expect(result.carry_to_parent[0].current_commit.eql(parent));

    // Second carry: child lines 5–6 ↔ parent lines 4–5.
    try testing.expectEqual(@as(u32, 4), result.carry_to_parent[1].blob_line_start);
    try testing.expectEqual(@as(u32, 5), result.carry_to_parent[1].blob_line_end);
    try testing.expectEqual(@as(u32, 5), result.carry_to_parent[1].target_line_start);
    try testing.expectEqual(@as(u32, 6), result.carry_to_parent[1].target_line_end);

    // Residue: child lines 3–4 attributed to child (target lines 3–4).
    try testing.expectEqual(@as(u32, 3), result.residue_in_commit[0].blob_line_start);
    try testing.expectEqual(@as(u32, 4), result.residue_in_commit[0].blob_line_end);
    try testing.expectEqual(@as(u32, 3), result.residue_in_commit[0].target_line_start);
    try testing.expectEqual(@as(u32, 4), result.residue_in_commit[0].target_line_end);
    try testing.expect(result.residue_in_commit[0].current_commit.eql(child));
}

test "split: -L sub-region only sees its slice" {
    // Same file as the previous test, but the caller is only asking
    // about target lines 3–4 (the inserted block). The region spans
    // child blob lines 3–4 only. We should get one residue region,
    // zero carry regions.
    const allocator = testing.allocator;
    const child = makeOid(0xAA);
    const parent = makeOid(0xBB);

    const edits = [_]myers.Edit{
        .{ .op = .equal, .a_idx = 0, .b_idx = 0 },
        .{ .op = .equal, .a_idx = 1, .b_idx = 1 },
        .{ .op = .delete, .a_idx = 2, .b_idx = 0 },
        .{ .op = .insert, .a_idx = 0, .b_idx = 2 },
        .{ .op = .insert, .a_idx = 0, .b_idx = 3 },
        .{ .op = .equal, .a_idx = 3, .b_idx = 4 },
        .{ .op = .equal, .a_idx = 4, .b_idx = 5 },
    };

    var result = try splitRegionAgainstDiff(allocator, .{
        .current_commit = child,
        .blob_line_start = 3,
        .blob_line_end = 4,
        .target_line_start = 3,
        .target_line_end = 4,
    }, &edits, parent);
    defer result.deinit(allocator);

    try testing.expectEqual(@as(usize, 0), result.carry_to_parent.len);
    try testing.expectEqual(@as(usize, 1), result.residue_in_commit.len);
    try testing.expectEqual(@as(u32, 3), result.residue_in_commit[0].blob_line_start);
    try testing.expectEqual(@as(u32, 4), result.residue_in_commit[0].blob_line_end);
}

test "coalesce: merges adjacent regions with same commit" {
    const oid_a = makeOid(0x11);
    const oid_b = makeOid(0x22);
    var regions = [_]Region{
        .{ .current_commit = oid_a, .blob_line_start = 1, .blob_line_end = 3, .target_line_start = 1, .target_line_end = 3 },
        .{ .current_commit = oid_a, .blob_line_start = 4, .blob_line_end = 5, .target_line_start = 4, .target_line_end = 5 },
        .{ .current_commit = oid_b, .blob_line_start = 10, .blob_line_end = 12, .target_line_start = 6, .target_line_end = 8 },
    };
    const n = coalesceContiguous(&regions);
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expect(regions[0].current_commit.eql(oid_a));
    try testing.expectEqual(@as(u32, 1), regions[0].blob_line_start);
    try testing.expectEqual(@as(u32, 5), regions[0].blob_line_end);
    try testing.expect(regions[1].current_commit.eql(oid_b));
}

test "coalesce: keeps non-adjacent regions separate" {
    const oid = makeOid(0x11);
    var regions = [_]Region{
        .{ .current_commit = oid, .blob_line_start = 1, .blob_line_end = 3, .target_line_start = 1, .target_line_end = 3 },
        // Gap of one line between blob 3 and blob 5 → don't merge.
        .{ .current_commit = oid, .blob_line_start = 5, .blob_line_end = 7, .target_line_start = 5, .target_line_end = 7 },
    };
    const n = coalesceContiguous(&regions);
    try testing.expectEqual(@as(usize, 2), n);
}
