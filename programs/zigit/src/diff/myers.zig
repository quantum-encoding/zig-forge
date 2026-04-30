// Myers' O(ND) line-diff (Eugene W. Myers, 1986).
//
// Given two slices of lines A and B, return an `Edit` script — the
// minimum sequence of equal/delete/insert operations that turns A
// into B. The script preserves the input order so a renderer can
// walk it left-to-right.
//
// We work over `[]const []const u8` (lines as byte-slices). Equality
// is byte-equality; line endings stay attached. The hunk grouper in
// `unified.zig` uses the indices on each Edit to look the original
// content back up for printing — Edits don't carry the line bytes.

const std = @import("std");

pub const Op = enum { equal, insert, delete };

pub const Edit = struct {
    op: Op,
    /// 0-based index into A. Valid for `equal` and `delete`.
    a_idx: usize,
    /// 0-based index into B. Valid for `equal` and `insert`.
    b_idx: usize,
};

/// Return the edit script. Caller owns the returned slice.
pub fn diff(
    allocator: std.mem.Allocator,
    a: []const []const u8,
    b: []const []const u8,
) ![]Edit {
    const n = a.len;
    const m = b.len;

    if (n == 0 and m == 0) return try allocator.alloc(Edit, 0);
    if (n == 0) {
        const out = try allocator.alloc(Edit, m);
        for (0..m) |i| out[i] = .{ .op = .insert, .a_idx = 0, .b_idx = i };
        return out;
    }
    if (m == 0) {
        const out = try allocator.alloc(Edit, n);
        for (0..n) |i| out[i] = .{ .op = .delete, .a_idx = i, .b_idx = 0 };
        return out;
    }

    const max_d: usize = n + m;
    // V[k] is the furthest x reachable on diagonal k (= x - y) using
    // exactly `d` non-diagonal moves so far. Diagonals span -max_d..max_d
    // so we offset by max_d to keep indices non-negative.
    const v_size = 2 * max_d + 1;

    var v = try allocator.alloc(isize, v_size);
    defer allocator.free(v);
    @memset(v, 0);

    var trace: std.ArrayListUnmanaged([]isize) = .empty;
    defer {
        for (trace.items) |snap| allocator.free(snap);
        trace.deinit(allocator);
    }

    var d: usize = 0;
    var found_d: ?usize = null;
    outer: while (d <= max_d) : (d += 1) {
        const di: isize = @intCast(d);
        var k: isize = -di;
        while (k <= di) : (k += 2) {
            const k_idx: usize = @intCast(k + @as(isize, @intCast(max_d)));
            // Choose whether to come from above (down move = insert)
            // or from the left (right move = delete).
            var x: isize = undefined;
            if (k == -di or (k != di and v[k_idx - 1] < v[k_idx + 1])) {
                x = v[k_idx + 1];
            } else {
                x = v[k_idx - 1] + 1;
            }
            var y: isize = x - k;
            // Follow the diagonal as far as A and B agree.
            while (x < @as(isize, @intCast(n)) and y < @as(isize, @intCast(m))) {
                if (!std.mem.eql(u8, a[@intCast(x)], b[@intCast(y)])) break;
                x += 1;
                y += 1;
            }
            v[k_idx] = x;
            if (x >= @as(isize, @intCast(n)) and y >= @as(isize, @intCast(m))) {
                found_d = d;
                // Snapshot the final V too — backtrace consumes it.
                try trace.append(allocator, try allocator.dupe(isize, v));
                break :outer;
            }
        }
        try trace.append(allocator, try allocator.dupe(isize, v));
    }

    return try backtrace(allocator, a, b, trace.items, found_d orelse max_d, max_d);
}

fn backtrace(
    allocator: std.mem.Allocator,
    a: []const []const u8,
    b: []const []const u8,
    trace: []const []isize,
    final_d: usize,
    max_d: usize,
) ![]Edit {
    var edits: std.ArrayListUnmanaged(Edit) = .empty;
    errdefer edits.deinit(allocator);

    var x: isize = @intCast(a.len);
    var y: isize = @intCast(b.len);

    var d: isize = @intCast(final_d);
    while (d >= 0) : (d -= 1) {
        const v = trace[@intCast(d)];
        const k = x - y;
        const k_idx: usize = @intCast(k + @as(isize, @intCast(max_d)));

        const prev_k: isize = blk: {
            if (k == -d or (k != d and v[k_idx - 1] < v[k_idx + 1])) {
                break :blk k + 1; // came down → previous step was on k+1
            } else {
                break :blk k - 1;
            }
        };
        const prev_k_idx: usize = @intCast(prev_k + @as(isize, @intCast(max_d)));
        const prev_x: isize = v[prev_k_idx];
        const prev_y: isize = prev_x - prev_k;

        // Walk back diagonally first (these are equal lines).
        while (x > prev_x and y > prev_y) {
            try edits.append(allocator, .{
                .op = .equal,
                .a_idx = @intCast(x - 1),
                .b_idx = @intCast(y - 1),
            });
            x -= 1;
            y -= 1;
        }

        if (d > 0) {
            if (prev_k == k + 1) {
                // We took a down move at step d → an insert from B.
                try edits.append(allocator, .{
                    .op = .insert,
                    .a_idx = @intCast(prev_x),
                    .b_idx = @intCast(prev_y - 1 + 1), // prev_y points after the insert
                });
            } else {
                try edits.append(allocator, .{
                    .op = .delete,
                    .a_idx = @intCast(prev_x - 1 + 1),
                    .b_idx = @intCast(prev_y),
                });
            }
            x = prev_x;
            y = prev_y;
        }
    }

    // Edits were collected in reverse order — flip to forward.
    std.mem.reverse(Edit, edits.items);

    return try edits.toOwnedSlice(allocator);
}

const testing = std.testing;

fn linesOf(comptime s: []const u8) []const []const u8 {
    return comptime blk: {
        var arr: [256][]const u8 = undefined;
        var n: usize = 0;
        var it = std.mem.splitScalar(u8, s, '\n');
        while (it.next()) |line| : (n += 1) {
            if (line.len == 0 and n > 0 and it.peek() == null) break; // drop trailing empty
            arr[n] = line;
        }
        const out: [n][]const u8 = arr[0..n].*;
        break :blk &out;
    };
}

test "diff of two empties" {
    const out = try diff(testing.allocator, &.{}, &.{});
    defer testing.allocator.free(out);
    try testing.expectEqual(@as(usize, 0), out.len);
}

test "diff of identical sequences is all equal" {
    const a: []const []const u8 = &.{ "a", "b", "c" };
    const out = try diff(testing.allocator, a, a);
    defer testing.allocator.free(out);
    try testing.expectEqual(@as(usize, 3), out.len);
    for (out) |e| try testing.expectEqual(Op.equal, e.op);
}

test "diff one insert" {
    const a: []const []const u8 = &.{ "a", "c" };
    const b: []const []const u8 = &.{ "a", "b", "c" };
    const out = try diff(testing.allocator, a, b);
    defer testing.allocator.free(out);
    var inserts: usize = 0;
    var equals: usize = 0;
    for (out) |e| {
        switch (e.op) {
            .insert => inserts += 1,
            .equal => equals += 1,
            .delete => return error.UnexpectedDelete,
        }
    }
    try testing.expectEqual(@as(usize, 1), inserts);
    try testing.expectEqual(@as(usize, 2), equals);
}

test "diff one delete" {
    const a: []const []const u8 = &.{ "a", "b", "c" };
    const b: []const []const u8 = &.{ "a", "c" };
    const out = try diff(testing.allocator, a, b);
    defer testing.allocator.free(out);
    var deletes: usize = 0;
    for (out) |e| {
        if (e.op == .delete) deletes += 1;
    }
    try testing.expectEqual(@as(usize, 1), deletes);
}

test "diff replace single line" {
    const a: []const []const u8 = &.{ "x", "old", "y" };
    const b: []const []const u8 = &.{ "x", "new", "y" };
    const out = try diff(testing.allocator, a, b);
    defer testing.allocator.free(out);
    var deletes: usize = 0;
    var inserts: usize = 0;
    for (out) |e| {
        switch (e.op) {
            .delete => deletes += 1,
            .insert => inserts += 1,
            .equal => {},
        }
    }
    try testing.expectEqual(@as(usize, 1), deletes);
    try testing.expectEqual(@as(usize, 1), inserts);
}
