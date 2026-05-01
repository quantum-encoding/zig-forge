// diff3 — line-level three-way merger.
//
// Strategy:
//   1. Run Myers between (base, ours) and (base, theirs).
//   2. For each base line, classify it as kept-by-both / kept-by-one /
//      deleted-by-both. For each "gap" between base lines (where
//      inserts can land), gather the lines ours and theirs add.
//   3. Walk base line-by-line, emitting:
//        * if both sides kept the base line → emit it
//        * if only one side kept it → emit nothing (the other deleted)
//        * if neither kept it → emit nothing (consensus delete)
//      Then handle the gap after the line:
//        * if ours == theirs (including both empty) → emit either
//        * if only one side inserted → emit it
//        * if both inserted but different → CONFLICT, emit markers
//          wrapping ours then theirs.
//   4. Same for the trailing gap after the last base line.
//
// This catches the common "disjoint edits" case (each side touches a
// different region) cleanly, and falls back to single-hunk conflict
// markers when the changes overlap. It's noticeably less precise
// than git's recursive diff3 (no rerere, no zealous matching) but
// good enough to remove the "merge gives up at the file level"
// limitation.

const std = @import("std");
const myers = @import("myers.zig");

pub const Result = struct {
    /// Final merged file contents. Owned.
    bytes: []u8,
    /// True if any conflict markers were emitted.
    had_conflict: bool,

    pub fn deinit(self: *Result, allocator: std.mem.Allocator) void {
        allocator.free(self.bytes);
        self.* = undefined;
    }
};

pub const ConflictLabels = struct {
    ours: []const u8 = "ours",
    theirs: []const u8 = "theirs",
};

pub fn merge(
    allocator: std.mem.Allocator,
    base: []const []const u8,
    ours: []const []const u8,
    theirs: []const []const u8,
    labels: ConflictLabels,
) !Result {
    // Per-base-line classification + per-gap insertion lists.
    const ours_view = try classify(allocator, base, ours);
    defer ours_view.deinit(allocator);
    const theirs_view = try classify(allocator, base, theirs);
    defer theirs_view.deinit(allocator);

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    var had_conflict = false;

    // Walk base. At each step: first emit the gap *before* base[i]
    // (inserts that classify accumulated at index i), then the line
    // itself if both sides kept it. After the loop, emit the trailing
    // gap (index = base.len) for inserts after the last base line.
    var i: usize = 0;
    while (i <= base.len) : (i += 1) {
        const o_inserts = ours_view.insertsAt(i);
        const t_inserts = theirs_view.insertsAt(i);

        if (slicesEql(o_inserts, t_inserts)) {
            for (o_inserts) |line| try appendLine(allocator, &out, line);
        } else if (o_inserts.len > 0 and t_inserts.len == 0) {
            for (o_inserts) |line| try appendLine(allocator, &out, line);
        } else if (t_inserts.len > 0 and o_inserts.len == 0) {
            for (t_inserts) |line| try appendLine(allocator, &out, line);
        } else {
            had_conflict = true;
            try appendStr(allocator, &out, "<<<<<<< ");
            try appendStr(allocator, &out, labels.ours);
            try appendStr(allocator, &out, "\n");
            for (o_inserts) |line| try appendLine(allocator, &out, line);
            try appendStr(allocator, &out, "=======\n");
            for (t_inserts) |line| try appendLine(allocator, &out, line);
            try appendStr(allocator, &out, ">>>>>>> ");
            try appendStr(allocator, &out, labels.theirs);
            try appendStr(allocator, &out, "\n");
        }

        if (i < base.len) {
            const o_kept = ours_view.kept[i];
            const t_kept = theirs_view.kept[i];
            if (o_kept and t_kept) {
                try appendLine(allocator, &out, base[i]);
            }
        }
    }

    return .{ .bytes = try out.toOwnedSlice(allocator), .had_conflict = had_conflict };
}

fn appendLine(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), line: []const u8) !void {
    try out.appendSlice(allocator, line);
    if (line.len == 0 or line[line.len - 1] != '\n') {
        try out.append(allocator, '\n');
    }
}

fn appendStr(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), s: []const u8) !void {
    try out.appendSlice(allocator, s);
}

fn slicesEql(a: []const []const u8, b: []const []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ai, bi| if (!std.mem.eql(u8, ai, bi)) return false;
    return true;
}

/// Per-base-line view: which lines were kept by `side`, and which
/// new lines from `side` should be inserted between them.
const SideView = struct {
    /// kept[i] = true iff base[i] survived to `side` unchanged.
    kept: []bool,
    /// inserts[i] = list of `side` lines to insert just before base[i]
    /// for i ∈ [0, base.len], plus a trailing slot at i = base.len.
    /// Borrowed slices into the original `side` array.
    inserts_storage: []const []const u8,
    /// Offsets into inserts_storage. inserts_offsets[i] = start;
    /// inserts_offsets[i+1] = end. Total length = base.len + 2.
    inserts_offsets: []usize,

    fn deinit(self: SideView, allocator: std.mem.Allocator) void {
        allocator.free(self.kept);
        allocator.free(self.inserts_storage);
        allocator.free(self.inserts_offsets);
    }

    fn insertsAt(self: SideView, gap_index: usize) []const []const u8 {
        return self.inserts_storage[self.inserts_offsets[gap_index]..self.inserts_offsets[gap_index + 1]];
    }
};

fn classify(
    allocator: std.mem.Allocator,
    base: []const []const u8,
    side: []const []const u8,
) !SideView {
    const ops = try myers.diff(allocator, base, side);
    defer allocator.free(ops);

    const kept = try allocator.alloc(bool, base.len);
    errdefer allocator.free(kept);
    @memset(kept, false);

    // For each gap (0..base.len inclusive), collect the inserts that
    // land in it. We build a flat list + offsets so the caller can
    // index without extra allocations.
    var inserts_per_gap: std.ArrayListUnmanaged(std.ArrayListUnmanaged([]const u8)) = .empty;
    defer inserts_per_gap.deinit(allocator);
    try inserts_per_gap.resize(allocator, base.len + 1);
    for (inserts_per_gap.items) |*g| g.* = .empty;
    defer for (inserts_per_gap.items) |*g| g.deinit(allocator);

    // Walk ops. We need to know which gap inserts land in: it's the
    // gap immediately after the most recent base line we've seen
    // (or gap 0 if we're at the very start).
    var current_base_pos: usize = 0;
    for (ops) |op| {
        switch (op.op) {
            .equal => {
                kept[op.a_idx] = true;
                current_base_pos = op.a_idx + 1;
            },
            .delete => {
                current_base_pos = op.a_idx + 1;
            },
            .insert => {
                try inserts_per_gap.items[current_base_pos].append(allocator, side[op.b_idx]);
            },
        }
    }

    // Flatten.
    var total: usize = 0;
    for (inserts_per_gap.items) |g| total += g.items.len;

    const flat = try allocator.alloc([]const u8, total);
    errdefer allocator.free(flat);
    const offsets = try allocator.alloc(usize, base.len + 2);
    errdefer allocator.free(offsets);

    var cursor: usize = 0;
    for (inserts_per_gap.items, 0..) |g, gi| {
        offsets[gi] = cursor;
        for (g.items) |line| {
            flat[cursor] = line;
            cursor += 1;
        }
    }
    offsets[base.len + 1] = cursor;

    return .{
        .kept = kept,
        .inserts_storage = flat,
        .inserts_offsets = offsets,
    };
}

const testing = std.testing;

test "all three identical: clean output, no conflict" {
    const lines = [_][]const u8{ "line a", "line b", "line c" };
    var r = try merge(testing.allocator, &lines, &lines, &lines, .{});
    defer r.deinit(testing.allocator);
    try testing.expect(!r.had_conflict);
    try testing.expectEqualStrings("line a\nline b\nline c\n", r.bytes);
}

test "ours added at end, theirs untouched: take ours" {
    const base = [_][]const u8{ "a", "b" };
    const ours = [_][]const u8{ "a", "b", "c" };
    const theirs = [_][]const u8{ "a", "b" };

    var r = try merge(testing.allocator, &base, &ours, &theirs, .{});
    defer r.deinit(testing.allocator);
    try testing.expect(!r.had_conflict);
    try testing.expectEqualStrings("a\nb\nc\n", r.bytes);
}

test "disjoint edits — ours top, theirs bottom: clean merge" {
    const base = [_][]const u8{ "L1", "L2", "L3" };
    const ours = [_][]const u8{ "L1-changed", "L2", "L3" };
    const theirs = [_][]const u8{ "L1", "L2", "L3-changed" };

    var r = try merge(testing.allocator, &base, &ours, &theirs, .{});
    defer r.deinit(testing.allocator);
    try testing.expect(!r.had_conflict);
    try testing.expectEqualStrings("L1-changed\nL2\nL3-changed\n", r.bytes);
}

test "overlapping edits in same region: conflict markers" {
    const base = [_][]const u8{ "shared" };
    const ours = [_][]const u8{ "from-ours" };
    const theirs = [_][]const u8{ "from-theirs" };

    var r = try merge(testing.allocator, &base, &ours, &theirs, .{});
    defer r.deinit(testing.allocator);
    try testing.expect(r.had_conflict);
    // The "shared" line is deleted by both sides; both inserted into
    // the same gap (gap 0, before the deleted line). Expected output
    // has conflict markers around the inserts.
    try testing.expect(std.mem.indexOf(u8, r.bytes, "<<<<<<< ours\n") != null);
    try testing.expect(std.mem.indexOf(u8, r.bytes, "from-ours\n") != null);
    try testing.expect(std.mem.indexOf(u8, r.bytes, "=======\n") != null);
    try testing.expect(std.mem.indexOf(u8, r.bytes, "from-theirs\n") != null);
    try testing.expect(std.mem.indexOf(u8, r.bytes, ">>>>>>> theirs\n") != null);
}

test "both insert same line: take once, no conflict" {
    const base = [_][]const u8{ "a", "c" };
    const ours = [_][]const u8{ "a", "b", "c" };
    const theirs = [_][]const u8{ "a", "b", "c" };

    var r = try merge(testing.allocator, &base, &ours, &theirs, .{});
    defer r.deinit(testing.allocator);
    try testing.expect(!r.had_conflict);
    try testing.expectEqualStrings("a\nb\nc\n", r.bytes);
}
