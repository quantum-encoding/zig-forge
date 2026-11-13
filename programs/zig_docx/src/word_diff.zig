// Copyright (c) 2026 QUANTUM ENCODING LTD
// Licensed under the MIT License.

//! Word-level diff: what was removed from one text and added to make another.
//!
//! The texts are cut into tokens, each either a run of whitespace or a run of
//! anything else, so a change reads in whole words and the spaces between them
//! are kept exactly. The longest common subsequence of tokens is what stayed;
//! between two stretches that stayed, the tokens of `before` were removed and
//! those of `after` added.
//!
//! The raw subsequence is tidied for a reader, the way a proofreader marks a
//! page: a stretch that stayed but is only whitespace, or is no longer than
//! the change on each side of it, is folded into those changes, so
//! "by similar standard of" → "with a" reads as one replacement rather than
//! four words struck through between kept spaces.
//!
//! The same subsequence over whole paragraphs (diffTokens) lines up two
//! documents paragraph by paragraph.

const std = @import("std");

/// One stretch of the diff. `before` and `after` are slices of the two
/// inputs; a kept stretch has the same text in both, a removal has an empty
/// `after`, an addition an empty `before`, and a replacement neither.
pub const Segment = struct {
    kind: Kind,
    before: []const u8,
    after: []const u8,

    pub const Kind = enum { same, changed };
};

/// Above this many token pairs between the common head and tail, the middle
/// is reported as one replacement instead of being searched: the table the
/// search needs grows as the product of the two lengths.
pub const MAX_CELLS: usize = 4_000_000;

/// The tokens of `text`: alternating runs of whitespace and of everything
/// else, which concatenated give `text` back.
pub fn tokenize(allocator: std.mem.Allocator, text: []const u8) ![][]const u8 {
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < text.len) {
        const start = i;
        const ws = isSpace(text[i]);
        while (i < text.len and isSpace(text[i]) == ws) i += 1;
        try out.append(allocator, text[start..i]);
    }
    return out.toOwnedSlice(allocator);
}

fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r';
}

/// What a diff did with each token.
pub const Op = enum { same, removed, added };

/// The edit script turning `a` into `b`: one op per token of `a` that was
/// kept or removed and per token of `b` that was added, in reading order,
/// with removals before additions where both happen at one place.
pub fn diffTokens(allocator: std.mem.Allocator, a: []const []const u8, b: []const []const u8) ![]Op {
    var ops: std.ArrayListUnmanaged(Op) = .empty;
    errdefer ops.deinit(allocator);

    // The common head and tail cost nothing to find and shrink the search.
    var head: usize = 0;
    while (head < a.len and head < b.len and std.mem.eql(u8, a[head], b[head])) head += 1;
    var tail: usize = 0;
    while (tail < a.len - head and tail < b.len - head and
        std.mem.eql(u8, a[a.len - 1 - tail], b[b.len - 1 - tail])) tail += 1;

    try ops.appendNTimes(allocator, .same, head);

    const ma = a[head .. a.len - tail];
    const mb = b[head .. b.len - tail];
    const n = ma.len;
    const m = mb.len;
    if (n == 0 or m == 0 or (n + 1) * (m + 1) > MAX_CELLS) {
        try ops.appendNTimes(allocator, .removed, n);
        try ops.appendNTimes(allocator, .added, m);
    } else {
        // lcs[i][j] = length of the longest common subsequence of ma[i..] and mb[j..].
        const w = m + 1;
        const lcs = try allocator.alloc(u32, (n + 1) * w);
        defer allocator.free(lcs);
        @memset(lcs, 0);
        var i = n;
        while (i > 0) {
            i -= 1;
            var j = m;
            while (j > 0) {
                j -= 1;
                lcs[i * w + j] = if (std.mem.eql(u8, ma[i], mb[j]))
                    lcs[(i + 1) * w + j + 1] + 1
                else
                    @max(lcs[(i + 1) * w + j], lcs[i * w + j + 1]);
            }
        }
        // Walk the table forwards. Removals are taken before additions, so a
        // replacement reads as the old words then the new.
        i = 0;
        var j: usize = 0;
        while (i < n and j < m) {
            if (std.mem.eql(u8, ma[i], mb[j])) {
                try ops.append(allocator, .same);
                i += 1;
                j += 1;
            } else if (lcs[(i + 1) * w + j] >= lcs[i * w + j + 1]) {
                try ops.append(allocator, .removed);
                i += 1;
            } else {
                try ops.append(allocator, .added);
                j += 1;
            }
        }
        try ops.appendNTimes(allocator, .removed, n - i);
        try ops.appendNTimes(allocator, .added, m - j);
    }

    try ops.appendNTimes(allocator, .same, tail);
    return ops.toOwnedSlice(allocator);
}

/// A stretch of the diff in token indices: a[a0..a1] became b[b0..b1].
const Block = struct {
    same: bool,
    a0: usize,
    a1: usize,
    b0: usize,
    b1: usize,
};

/// The word diff of `before` → `after`, tidied for reading (see the file
/// header). Segment slices point into the two inputs.
pub fn diffWords(allocator: std.mem.Allocator, before: []const u8, after: []const u8) ![]Segment {
    const ta = try tokenize(allocator, before);
    defer allocator.free(ta);
    const tb = try tokenize(allocator, after);
    defer allocator.free(tb);

    const ops = try diffTokens(allocator, ta, tb);
    defer allocator.free(ops);

    // Ops → alternating blocks of kept and changed tokens.
    var blocks: std.ArrayListUnmanaged(Block) = .empty;
    defer blocks.deinit(allocator);
    var ia: usize = 0;
    var ib: usize = 0;
    for (ops) |op| {
        const same = op == .same;
        if (blocks.items.len == 0 or blocks.items[blocks.items.len - 1].same != same) {
            try blocks.append(allocator, .{ .same = same, .a0 = ia, .a1 = ia, .b0 = ib, .b1 = ib });
        }
        switch (op) {
            .same => {
                ia += 1;
                ib += 1;
            },
            .removed => ia += 1,
            .added => ib += 1,
        }
        const blk = &blocks.items[blocks.items.len - 1];
        blk.a1 = ia;
        blk.b1 = ib;
    }

    // Fold kept stretches that are only whitespace, or no longer than the
    // change on each side of them, into one change with their neighbours.
    // Every fold removes two blocks, so this ends.
    var folded = true;
    while (folded) {
        folded = false;
        var k: usize = 1;
        while (k + 1 < blocks.items.len) : (k += 1) {
            const mid = blocks.items[k];
            const left = blocks.items[k - 1];
            const right = blocks.items[k + 1];
            if (!mid.same or left.same or right.same) continue;
            const kept = textLen(ta, mid.a0, mid.a1);
            const left_size = @max(textLen(ta, left.a0, left.a1), textLen(tb, left.b0, left.b1));
            const right_size = @max(textLen(ta, right.a0, right.a1), textLen(tb, right.b0, right.b1));
            if (isAllSpace(ta, mid.a0, mid.a1) or (kept <= left_size and kept <= right_size)) {
                blocks.items[k - 1] = .{ .same = false, .a0 = left.a0, .a1 = right.a1, .b0 = left.b0, .b1 = right.b1 };
                _ = blocks.orderedRemove(k + 1);
                _ = blocks.orderedRemove(k);
                folded = true;
                break;
            }
        }
    }

    // A change whose two sides start or end with the same tokens (a folded
    // replacement often ends in the same space on both) gives those tokens
    // back to the kept text beside it: "14b- " → "15b- " reads "14b-" → "15b-".
    var tidy: std.ArrayListUnmanaged(Block) = .empty;
    defer tidy.deinit(allocator);
    for (blocks.items) |blk| {
        if (blk.same) {
            try appendBlock(allocator, &tidy, blk);
            continue;
        }
        var tail: usize = 0;
        while (blk.a1 - tail > blk.a0 and blk.b1 - tail > blk.b0 and
            std.mem.eql(u8, ta[blk.a1 - 1 - tail], tb[blk.b1 - 1 - tail])) tail += 1;
        var head: usize = 0;
        while (blk.a0 + head < blk.a1 - tail and blk.b0 + head < blk.b1 - tail and
            std.mem.eql(u8, ta[blk.a0 + head], tb[blk.b0 + head])) head += 1;
        const core = Block{ .same = false, .a0 = blk.a0 + head, .a1 = blk.a1 - tail, .b0 = blk.b0 + head, .b1 = blk.b1 - tail };
        if (head > 0) try appendBlock(allocator, &tidy, .{ .same = true, .a0 = blk.a0, .a1 = core.a0, .b0 = blk.b0, .b1 = core.b0 });
        if (core.a1 > core.a0 or core.b1 > core.b0) try appendBlock(allocator, &tidy, core);
        if (tail > 0) try appendBlock(allocator, &tidy, .{ .same = true, .a0 = core.a1, .a1 = blk.a1, .b0 = core.b1, .b1 = blk.b1 });
    }

    // A pure insertion or removal that starts with a space slides past it
    // when the kept text after it starts with the same space, so the change
    // starts at a word: " board in [the ]hallway", not " board in[ the] hallway".
    var k: usize = 0;
    while (k + 1 < tidy.items.len) : (k += 1) {
        if (tidy.items[k].same) continue;
        const insert = tidy.items[k].a0 == tidy.items[k].a1;
        const remove = tidy.items[k].b0 == tidy.items[k].b1;
        if (!insert and !remove) continue;
        while (k + 1 < tidy.items.len) {
            const cur = tidy.items[k];
            const next = tidy.items[k + 1];
            if (!next.same or next.a0 == next.a1) break;
            const first = if (insert) tb[cur.b0] else ta[cur.a0];
            if (!isAllSpace(&.{first}, 0, 1) or !std.mem.eql(u8, first, ta[next.a0])) break;
            // The kept text before takes the space; the change and the kept
            // text after move along by one token.
            if (k > 0 and tidy.items[k - 1].same) {
                tidy.items[k - 1].a1 += 1;
                tidy.items[k - 1].b1 += 1;
            } else {
                try tidy.insert(allocator, k, .{ .same = true, .a0 = cur.a0, .a1 = cur.a0 + 1, .b0 = cur.b0, .b1 = cur.b0 + 1 });
                k += 1;
            }
            const c = &tidy.items[k];
            c.a0 += 1;
            c.a1 += 1;
            c.b0 += 1;
            c.b1 += 1;
            const n = &tidy.items[k + 1];
            n.a0 += 1;
            n.b0 += 1;
            if (n.a0 == n.a1) {
                _ = tidy.orderedRemove(k + 1);
                break;
            }
        }
    }

    var out: std.ArrayListUnmanaged(Segment) = .empty;
    errdefer out.deinit(allocator);
    for (tidy.items) |blk| {
        try out.append(allocator, .{
            .kind = if (blk.same) .same else .changed,
            .before = joinTokens(before, ta, blk.a0, blk.a1),
            .after = joinTokens(after, tb, blk.b0, blk.b1),
        });
    }
    return out.toOwnedSlice(allocator);
}

/// Append `blk`, joined onto the last block when both are kept text.
fn appendBlock(allocator: std.mem.Allocator, list: *std.ArrayListUnmanaged(Block), blk: Block) !void {
    if (list.items.len > 0) {
        const last = &list.items[list.items.len - 1];
        if (last.same and blk.same) {
            last.a1 = blk.a1;
            last.b1 = blk.b1;
            return;
        }
    }
    try list.append(allocator, blk);
}

fn textLen(tokens: []const []const u8, from: usize, to: usize) usize {
    var n: usize = 0;
    for (tokens[from..to]) |t| n += t.len;
    return n;
}

fn isAllSpace(tokens: []const []const u8, from: usize, to: usize) bool {
    for (tokens[from..to]) |t| {
        for (t) |c| if (!isSpace(c)) return false;
    }
    return true;
}

/// tokens[from..to] as one slice of `source`: the tokens are consecutive
/// slices of it, so the stretch is contiguous.
fn joinTokens(source: []const u8, tokens: []const []const u8, from: usize, to: usize) []const u8 {
    if (from >= to) return source[0..0];
    const start = @intFromPtr(tokens[from].ptr) - @intFromPtr(source.ptr);
    const last = tokens[to - 1];
    const end = @intFromPtr(last.ptr) - @intFromPtr(source.ptr) + last.len;
    return source[start..end];
}

/// How alike two texts are: twice the length of what the word diff keeps
/// over their total length, from 0 (nothing shared) to 1 (identical).
pub fn similarity(allocator: std.mem.Allocator, a: []const u8, b: []const u8) !f32 {
    if (a.len + b.len == 0) return 1;
    const segs = try diffWords(allocator, a, b);
    defer allocator.free(segs);
    var kept: usize = 0;
    for (segs) |s| {
        if (s.kind == .same) kept += s.before.len;
    }
    return @as(f32, @floatFromInt(2 * kept)) / @as(f32, @floatFromInt(a.len + b.len));
}

// ─── Tests ─────────────────────────────────────────────────────────

const testing = std.testing;

fn expectSegments(before: []const u8, after: []const u8, want: []const [3][]const u8) !void {
    const segs = try diffWords(testing.allocator, before, after);
    defer testing.allocator.free(segs);
    if (segs.len != want.len) {
        std.debug.print("got {d} segments, want {d}:\n", .{ segs.len, want.len });
        for (segs) |s| std.debug.print("  {t} [{s}] -> [{s}]\n", .{ s.kind, s.before, s.after });
        return error.TestUnexpectedResult;
    }
    for (segs, want) |s, w| {
        const kind: Segment.Kind = if (std.mem.eql(u8, w[0], "=")) .same else .changed;
        try testing.expectEqual(kind, s.kind);
        try testing.expectEqualStrings(w[1], s.before);
        try testing.expectEqualStrings(w[2], s.after);
    }
}

test "tokens alternate words and whitespace and give the text back" {
    const toks = try tokenize(testing.allocator, "No  5 here\tthen");
    defer testing.allocator.free(toks);
    const want = [_][]const u8{ "No", "  ", "5", " ", "here", "\t", "then" };
    try testing.expectEqual(want.len, toks.len);
    for (want, toks) |w, t| try testing.expectEqualStrings(w, t);
}

test "one word changed keeps the words around it" {
    try expectSegments("No  5", "No  7", &.{
        .{ "=", "No  ", "No  " },
        .{ "~", "5", "7" },
    });
}

test "a duplicated word is removed and the rest kept" {
    try expectSegments(
        "kept free free from storage",
        "kept free from storage",
        &.{
            .{ "=", "kept free ", "kept free " },
            .{ "~", "free ", "" },
            .{ "=", "from storage", "from storage" },
        },
    );
}

test "a replacement spanning several words reads as one change" {
    try expectSegments(
        "to be replaced by similar standard of robust doors",
        "to be replaced with a robust doors",
        &.{
            .{ "=", "to be replaced ", "to be replaced " },
            .{ "~", "by similar standard of", "with a" },
            .{ "=", " robust doors", " robust doors" },
        },
    );
}

test "a change gives the space it shares on both sides back to the kept text" {
    try expectSegments(
        "14b- Fire notices on Notice board in hallway",
        "15b- Fire notices on the notice board in the hallway",
        &.{
            .{ "~", "14b-", "15b-" },
            .{ "=", " Fire notices on ", " Fire notices on " },
            .{ "~", "Notice", "the notice" },
            .{ "=", " board in ", " board in " },
            .{ "~", "", "the " },
            .{ "=", "hallway", "hallway" },
        },
    );
}

test "words added at the end" {
    try expectSegments(
        "all angles of swing.",
        "all angles of swing, and the hole repaired.",
        &.{
            .{ "=", "all angles of ", "all angles of " },
            .{ "~", "swing.", "swing, and the hole repaired." },
        },
    );
}

test "identical and empty texts" {
    try expectSegments("same text", "same text", &.{.{ "=", "same text", "same text" }});
    try expectSegments("", "new words", &.{.{ "~", "", "new words" }});
    try expectSegments("old words", "", &.{.{ "~", "old words", "" }});
    const none = try diffWords(testing.allocator, "", "");
    defer testing.allocator.free(none);
    try testing.expectEqual(@as(usize, 0), none.len);
}

test "a short shared word between two larger changes is folded in" {
    // "the" is kept by the raw subsequence but is shorter than the changes
    // on both sides, so it reads as part of one replacement.
    try expectSegments(
        "alpha beta the gamma delta",
        "omega sigma the kappa lambda",
        &.{.{ "~", "alpha beta the gamma delta", "omega sigma the kappa lambda" }},
    );
}

test "the segments rebuild both texts" {
    const before = "Appropriate self closing device to be fitted to the flat entrance door.";
    const after = "Appropriate self-closing device to be fitted to the flat entrance door, and the hole repaired.";
    const segs = try diffWords(testing.allocator, before, after);
    defer testing.allocator.free(segs);
    var a: std.ArrayListUnmanaged(u8) = .empty;
    defer a.deinit(testing.allocator);
    var b: std.ArrayListUnmanaged(u8) = .empty;
    defer b.deinit(testing.allocator);
    for (segs) |s| {
        try a.appendSlice(testing.allocator, s.before);
        try b.appendSlice(testing.allocator, s.after);
    }
    try testing.expectEqualStrings(before, a.items);
    try testing.expectEqualStrings(after, b.items);
}

test "diffTokens lines up whole paragraphs" {
    const a = [_][]const u8{ "one", "two", "three", "four" };
    const b = [_][]const u8{ "one", "2", "three", "four", "five" };
    const ops = try diffTokens(testing.allocator, &a, &b);
    defer testing.allocator.free(ops);
    const want = [_]Op{ .same, .removed, .added, .same, .same, .added };
    try testing.expectEqualSlices(Op, &want, ops);
}

test "a middle too large to search is one replacement" {
    // Distinct tokens on each side with a shared head and tail: the middle
    // exceeds MAX_CELLS and is reported whole rather than searched.
    var a_buf: std.ArrayListUnmanaged([]const u8) = .empty;
    defer a_buf.deinit(testing.allocator);
    var b_buf: std.ArrayListUnmanaged([]const u8) = .empty;
    defer b_buf.deinit(testing.allocator);
    try a_buf.append(testing.allocator, "head");
    try b_buf.append(testing.allocator, "head");
    try a_buf.appendNTimes(testing.allocator, "x", 2100);
    try b_buf.appendNTimes(testing.allocator, "y", 2100);
    try a_buf.append(testing.allocator, "tail");
    try b_buf.append(testing.allocator, "tail");
    const ops = try diffTokens(testing.allocator, a_buf.items, b_buf.items);
    defer testing.allocator.free(ops);
    try testing.expectEqual(@as(usize, 1 + 2100 + 2100 + 1), ops.len);
    try testing.expectEqual(Op.same, ops[0]);
    try testing.expectEqual(Op.removed, ops[1]);
    try testing.expectEqual(Op.added, ops[2101]);
    try testing.expectEqual(Op.same, ops[ops.len - 1]);
}

test "similarity runs from nothing shared to identical" {
    try testing.expectEqual(@as(f32, 1), try similarity(testing.allocator, "a b c", "a b c"));
    try testing.expectEqual(@as(f32, 0), try similarity(testing.allocator, "abc", "xyz"));
    const part = try similarity(testing.allocator, "keep this part", "keep this other");
    try testing.expect(part > 0.5 and part < 1);
}
