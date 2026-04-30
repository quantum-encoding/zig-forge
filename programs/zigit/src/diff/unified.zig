// Unified-diff renderer.
//
// Takes a Myers edit script + the original line slices and emits the
// classic `git diff` body:
//
//   diff --git a/<path> b/<path>
//   index <oldOid>..<newOid> <mode>
//   --- a/<path>
//   +++ b/<path>
//   @@ -oldStart,oldCount +newStart,newCount @@
//    context line
//   -deleted line
//   +inserted line
//    context line
//
// Hunks are formed by walking the edit script and grouping each
// non-equal run with up to N lines of context on each side (default 3).
//
// We don't implement git's `--no-prefix`, `-U N` for context or
// rename detection yet — Phase 4 is the bare unified format.
//
// Lines passed in should keep their trailing newlines. We append
// `\ No newline at end of file` markers when the source line lacks
// one.

const std = @import("std");
const myers = @import("myers.zig");
const Edit = myers.Edit;
const Op = myers.Op;

pub const default_context: usize = 3;

pub const FileHeader = struct {
    /// Display path (typically just the relative path; we add the
    /// `a/` and `b/` prefixes ourselves).
    path: []const u8,
    /// Hex oid before the change. Empty string for new files.
    old_oid_hex: []const u8,
    /// Hex oid after the change. Empty string for deletions.
    new_oid_hex: []const u8,
    /// Octal mode like "100644". Used in the `index OLD..NEW MODE` line.
    mode: []const u8,
};

/// Render a single file's diff into `out`.
pub fn renderFile(
    allocator: std.mem.Allocator,
    out: *std.Io.Writer,
    header: FileHeader,
    a_lines: []const []const u8,
    b_lines: []const []const u8,
    edits: []const Edit,
    context: usize,
) !void {
    try out.print("diff --git a/{s} b/{s}\n", .{ header.path, header.path });

    // The classic `index <abbrev>..<abbrev> <mode>` line. We use
    // 7-char abbreviations (git's default).
    const old_abbrev = if (header.old_oid_hex.len >= 7) header.old_oid_hex[0..7] else header.old_oid_hex;
    const new_abbrev = if (header.new_oid_hex.len >= 7) header.new_oid_hex[0..7] else header.new_oid_hex;
    try out.print("index {s}..{s} {s}\n", .{ old_abbrev, new_abbrev, header.mode });

    try out.print("--- a/{s}\n", .{header.path});
    try out.print("+++ b/{s}\n", .{header.path});

    // Group edits into hunks.
    const hunks = try groupHunks(allocator, edits, a_lines.len, b_lines.len, context);
    defer allocator.free(hunks);

    for (hunks) |h| try renderHunk(out, h, edits, a_lines, b_lines);
}

const Hunk = struct {
    /// Inclusive start index into `edits`.
    edit_start: usize,
    /// Exclusive end index into `edits`.
    edit_end: usize,
    /// 1-based starting line numbers in A and B.
    a_start: usize,
    a_count: usize,
    b_start: usize,
    b_count: usize,
};

fn groupHunks(
    allocator: std.mem.Allocator,
    edits: []const Edit,
    a_total: usize,
    b_total: usize,
    context: usize,
) ![]Hunk {
    _ = a_total;
    _ = b_total;

    var hunks: std.ArrayListUnmanaged(Hunk) = .empty;
    errdefer hunks.deinit(allocator);

    var i: usize = 0;
    while (i < edits.len) {
        // Skip equal lines until we find a change.
        while (i < edits.len and edits[i].op == .equal) : (i += 1) {}
        if (i >= edits.len) break;

        // The change starts at `i`. Pull in `context` equal lines
        // immediately before it (if available).
        var hunk_start: usize = i;
        var pre: usize = 0;
        while (hunk_start > 0 and pre < context and edits[hunk_start - 1].op == .equal) {
            hunk_start -= 1;
            pre += 1;
        }

        // Find the end: walk forward through the change run and any
        // run of ≤ 2*context equal lines that bridges to another
        // change. Past 2*context equal lines the hunks split.
        var j: usize = i;
        while (j < edits.len) {
            if (edits[j].op != .equal) {
                j += 1;
                continue;
            }
            // Count this run of equals.
            const run_start = j;
            while (j < edits.len and edits[j].op == .equal) : (j += 1) {}
            const run_len = j - run_start;
            if (j == edits.len) {
                // Trailing equals — keep up to `context` of them.
                j = run_start + @min(run_len, context);
                break;
            }
            if (run_len > 2 * context) {
                // Split: trim back to `context` trailing equals.
                j = run_start + context;
                break;
            }
            // Bridge: keep walking.
        }
        const hunk_end: usize = j;

        // Compute 1-based starts and counts.
        // a_start: line number of first A-side line in the hunk (delete or equal).
        // b_start: same for B (insert or equal). For all-inserts/all-deletes
        // hunks the missing side falls back to the insertion/deletion
        // position (git's "0,0" convention for pure inserts before line 1).
        var a_first: ?usize = null;
        var b_first: ?usize = null;
        var a_count: usize = 0;
        var b_count: usize = 0;
        for (edits[hunk_start..hunk_end]) |e| {
            switch (e.op) {
                .equal => {
                    if (a_first == null) a_first = e.a_idx + 1;
                    if (b_first == null) b_first = e.b_idx + 1;
                    a_count += 1;
                    b_count += 1;
                },
                .delete => {
                    if (a_first == null) a_first = e.a_idx + 1;
                    a_count += 1;
                },
                .insert => {
                    if (b_first == null) b_first = e.b_idx + 1;
                    b_count += 1;
                },
            }
        }
        const first = edits[hunk_start];
        const a_start: usize = a_first orelse first.a_idx;
        const b_start: usize = b_first orelse first.b_idx;

        try hunks.append(allocator, .{
            .edit_start = hunk_start,
            .edit_end = hunk_end,
            .a_start = a_start,
            .a_count = a_count,
            .b_start = b_start,
            .b_count = b_count,
        });
        i = hunk_end;
    }

    return try hunks.toOwnedSlice(allocator);
}

fn renderHunk(
    out: *std.Io.Writer,
    h: Hunk,
    edits: []const Edit,
    a_lines: []const []const u8,
    b_lines: []const []const u8,
) !void {
    // git omits the `,N` if N == 1. Match that for tighter diffs.
    if (h.a_count == 1 and h.b_count == 1) {
        try out.print("@@ -{d} +{d} @@\n", .{ h.a_start, h.b_start });
    } else if (h.a_count == 1) {
        try out.print("@@ -{d} +{d},{d} @@\n", .{ h.a_start, h.b_start, h.b_count });
    } else if (h.b_count == 1) {
        try out.print("@@ -{d},{d} +{d} @@\n", .{ h.a_start, h.a_count, h.b_start });
    } else {
        try out.print("@@ -{d},{d} +{d},{d} @@\n", .{ h.a_start, h.a_count, h.b_start, h.b_count });
    }

    for (edits[h.edit_start..h.edit_end]) |e| {
        const prefix: u8 = switch (e.op) {
            .equal => ' ',
            .delete => '-',
            .insert => '+',
        };
        const line = switch (e.op) {
            .equal, .delete => a_lines[e.a_idx],
            .insert => b_lines[e.b_idx],
        };
        try out.writeByte(prefix);
        try out.writeAll(line);
        if (line.len == 0 or line[line.len - 1] != '\n') {
            try out.writeAll("\n\\ No newline at end of file\n");
        }
    }
}

/// Split a byte slice into lines, keeping the trailing '\n' on each
/// line. The final fragment without a newline (if any) is included
/// without an appended newline — `renderHunk` adds the
/// "\ No newline at end of file" marker when emitting it.
pub fn splitLinesKeepingNewline(allocator: std.mem.Allocator, bytes: []const u8) ![][]const u8 {
    var lines: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer lines.deinit(allocator);

    var cursor: usize = 0;
    while (cursor < bytes.len) {
        const next_nl = std.mem.indexOfScalarPos(u8, bytes, cursor, '\n');
        if (next_nl) |nl| {
            try lines.append(allocator, bytes[cursor .. nl + 1]);
            cursor = nl + 1;
        } else {
            try lines.append(allocator, bytes[cursor..]);
            cursor = bytes.len;
        }
    }
    return try lines.toOwnedSlice(allocator);
}

const testing = std.testing;

test "splitLinesKeepingNewline preserves newlines and trailing fragment" {
    const lines = try splitLinesKeepingNewline(testing.allocator, "a\nb\nc");
    defer testing.allocator.free(lines);
    try testing.expectEqual(@as(usize, 3), lines.len);
    try testing.expectEqualStrings("a\n", lines[0]);
    try testing.expectEqualStrings("b\n", lines[1]);
    try testing.expectEqualStrings("c", lines[2]);
}

test "renderFile emits a single hunk for a single line change" {
    const a_bytes = "x\nold\ny\n";
    const b_bytes = "x\nnew\ny\n";
    const a_lines = try splitLinesKeepingNewline(testing.allocator, a_bytes);
    defer testing.allocator.free(a_lines);
    const b_lines = try splitLinesKeepingNewline(testing.allocator, b_bytes);
    defer testing.allocator.free(b_lines);

    const edits = try myers.diff(testing.allocator, a_lines, b_lines);
    defer testing.allocator.free(edits);

    var allocating: std.Io.Writer.Allocating = try .initCapacity(testing.allocator, 256);
    defer allocating.deinit();

    try renderFile(
        testing.allocator,
        &allocating.writer,
        .{
            .path = "f.txt",
            .old_oid_hex = "abcdef0",
            .new_oid_hex = "1234567",
            .mode = "100644",
        },
        a_lines,
        b_lines,
        edits,
        default_context,
    );

    const expected =
        "diff --git a/f.txt b/f.txt\n" ++
        "index abcdef0..1234567 100644\n" ++
        "--- a/f.txt\n" ++
        "+++ b/f.txt\n" ++
        "@@ -1,3 +1,3 @@\n" ++
        " x\n" ++
        "-old\n" ++
        "+new\n" ++
        " y\n";
    try testing.expectEqualStrings(expected, allocating.written());
}
