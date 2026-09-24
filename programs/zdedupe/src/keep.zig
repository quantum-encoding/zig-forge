//! Which copy of a duplicate group stays, and which copies a rule deletes.
//!
//! "Every copy but the oldest" is correct about content and blind to place:
//! filtered to ~/Downloads, it would delete the copy in ~/Documents whenever
//! the Downloads one happened to be older. A `Spec` says where copies belong:
//!
//!   1. A pinned copy (the user chose it for this group) is kept.
//!   2. Otherwise the first copy under the earliest `prefer_under` is kept.
//!   3. Otherwise, with `delete_only_under` set, a copy outside those folders
//!      is the survivor and every copy inside them is deleted.
//!   4. Otherwise one unprotected copy is kept by `fallback`, avoiding the
//!      `avoid_under` folders while any other copy exists.
//!
//! Protected copies (see protect.zig) are always kept and never deleted, but
//! only in step 3 do they stand in for the survivor: elsewhere a system copy
//! does not make a project's own copy expendable.
//!
//! Steps 2 and 4 can be set per file type (`by_type`), matched on the
//! extension of the group's oldest copy.

const std = @import("std");
const filters = @import("filters.zig");

pub const Fallback = enum { oldest, newest, shortest_path };

pub const TypeRule = struct {
    /// Lower-case with the dot (".jpg"); "" is "no extension". Compared
    /// ASCII-case-insensitively.
    ext: []const u8,
    prefer_under: []const []const u8 = &.{},
    avoid_under: []const []const u8 = &.{},
    fallback: Fallback = .oldest,
};

/// One group's chosen survivor, by the group's content hash (64 hex digits,
/// as the rows carry it) and the lossy spelling of the path.
pub const Pin = struct {
    hash: []const u8,
    path: []const u8,
};

pub const Spec = struct {
    prefer_under: []const []const u8 = &.{},
    avoid_under: []const []const u8 = &.{},
    fallback: Fallback = .oldest,
    by_type: []const TypeRule = &.{},
    pins: []const Pin = &.{},
    /// Empty: a copy anywhere may be deleted. Otherwise only copies under
    /// these folders are, and a copy outside them is the survivor.
    delete_only_under: []const []const u8 = &.{},

    const Policy = struct {
        prefer_under: []const []const u8,
        avoid_under: []const []const u8,
        fallback: Fallback,
    };

    fn policyFor(self: *const Spec, ext: []const u8) Policy {
        for (self.by_type) |rule| {
            if (std.ascii.eqlIgnoreCase(rule.ext, ext)) return .{
                .prefer_under = rule.prefer_under,
                .avoid_under = rule.avoid_under,
                .fallback = rule.fallback,
            };
        }
        return .{
            .prefer_under = self.prefer_under,
            .avoid_under = self.avoid_under,
            .fallback = self.fallback,
        };
    }
};

pub const Member = struct {
    path: []const u8,
    mtime: i64,
    protected: bool,
};

/// Decide one group. `members` are its surviving copies, oldest first;
/// `pinned` indexes the pinned copy if the spec pins one here. Fills
/// `kept` and `targets` (both `members.len` long) and returns the copy to
/// present as the keeper, or null for an empty group.
pub fn plan(
    spec: *const Spec,
    members: []const Member,
    pinned: ?usize,
    kept: []bool,
    targets: []bool,
) ?usize {
    std.debug.assert(kept.len == members.len and targets.len == members.len);
    if (members.len == 0) return null;
    for (members, kept) |m, *k| k.* = m.protected;

    const policy = spec.policyFor(filters.extension(members[0].path));
    var primary: ?usize = null;

    if (pinned) |p| {
        primary = p;
    } else for (policy.prefer_under) |dir| {
        primary = for (members, 0..) |m, i| {
            if (filters.isAtOrUnder(m.path, dir)) break i;
        } else null;
        if (primary != null) break;
    }
    if (primary) |p| kept[p] = true;

    if (primary == null and spec.delete_only_under.len > 0) {
        // Not marked kept: it is not a target in any case, and marking it
        // would not change which copies inside the folders go.
        primary = for (members, 0..) |m, i| {
            if (!underAny(m.path, spec.delete_only_under)) break i;
        } else null;
    }

    if (primary == null) {
        primary = pick(policy, members, true) orelse pick(policy, members, false);
        if (primary) |p| kept[p] = true;
    }

    // Every copy is protected: nothing goes, and the oldest is shown as kept.
    if (primary == null) primary = 0;

    for (members, kept, targets) |m, k, *t| {
        t.* = !k and (spec.delete_only_under.len == 0 or underAny(m.path, spec.delete_only_under));
    }
    return primary;
}

fn underAny(path: []const u8, dirs: []const []const u8) bool {
    for (dirs) |dir| {
        if (filters.isAtOrUnder(path, dir)) return true;
    }
    return false;
}

/// The fallback survivor among unprotected copies, or null if there are none
/// (with `avoid`, none outside the avoided folders). Ties go to the older.
fn pick(policy: Spec.Policy, members: []const Member, avoid: bool) ?usize {
    var best: ?usize = null;
    for (members, 0..) |m, i| {
        if (m.protected) continue;
        if (avoid and underAny(m.path, policy.avoid_under)) continue;
        const b = best orelse {
            best = i;
            continue;
        };
        const better = switch (policy.fallback) {
            .oldest => false,
            .newest => m.mtime > members[b].mtime,
            .shortest_path => m.path.len < members[b].path.len,
        };
        if (better) best = i;
    }
    return best;
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

fn run(spec: Spec, members: []const Member, pinned: ?usize) !struct { primary: ?usize, targets: [8]bool } {
    var kept: [8]bool = undefined;
    var targets: [8]bool = @splat(false);
    const primary = plan(&spec, members, pinned, kept[0..members.len], targets[0..members.len]);
    return .{ .primary = primary, .targets = targets };
}

fn mem(path: []const u8, mtime: i64) Member {
    return .{ .path = path, .mtime = mtime, .protected = false };
}

test "the default keeps the oldest and deletes the rest" {
    const g = [_]Member{ mem("/d/a", 1), mem("/d/b", 2), mem("/d/c", 3) };
    const r = try run(.{}, &g, null);
    try testing.expectEqual(@as(?usize, 0), r.primary);
    try testing.expectEqualSlices(bool, &.{ false, true, true }, r.targets[0..3]);
}

test "prefer_under keeps the copy that belongs there, whatever its age" {
    const g = [_]Member{ mem("/u/Downloads/a.pdf", 1), mem("/u/Documents/a.pdf", 5) };
    const spec: Spec = .{ .prefer_under = &.{"/u/Documents"} };
    const r = try run(spec, &g, null);
    try testing.expectEqual(@as(?usize, 1), r.primary);
    try testing.expectEqualSlices(bool, &.{ true, false }, r.targets[0..2]);
}

test "avoid_under is only a last resort" {
    const g = [_]Member{ mem("/u/Downloads/a", 1), mem("/u/Desktop/a", 2), mem("/u/work/a", 3) };
    const spec: Spec = .{ .avoid_under = &.{ "/u/Downloads", "/u/Desktop" } };
    try testing.expectEqual(@as(?usize, 2), (try run(spec, &g, null)).primary);

    const only_avoided = [_]Member{ mem("/u/Downloads/a", 1), mem("/u/Desktop/a", 2) };
    try testing.expectEqual(@as(?usize, 0), (try run(spec, &only_avoided, null)).primary);
}

test "a pin beats every rule" {
    const g = [_]Member{ mem("/u/Documents/a", 1), mem("/u/Downloads/a", 2) };
    const spec: Spec = .{ .prefer_under = &.{"/u/Documents"} };
    const r = try run(spec, &g, 1);
    try testing.expectEqual(@as(?usize, 1), r.primary);
    try testing.expectEqualSlices(bool, &.{ true, false }, r.targets[0..2]);
}

test "rules per type replace the general one" {
    const photos = [_]Member{ mem("/u/Downloads/p.JPG", 1), mem("/u/Pictures/p.jpg", 2) };
    const docs = [_]Member{ mem("/u/Downloads/d.pdf", 1), mem("/u/Pictures/d.pdf", 2) };
    const spec: Spec = .{
        .prefer_under = &.{"/u/Downloads"},
        .by_type = &.{.{ .ext = ".jpg", .prefer_under = &.{"/u/Pictures"} }},
    };
    try testing.expectEqual(@as(?usize, 1), (try run(spec, &photos, null)).primary);
    try testing.expectEqual(@as(?usize, 0), (try run(spec, &docs, null)).primary);
}

test "delete_only_under takes only copies there, if one survives elsewhere" {
    const g = [_]Member{ mem("/u/Downloads/a", 1), mem("/u/work/a", 2), mem("/u/Downloads/b/a", 3) };
    const spec: Spec = .{ .delete_only_under = &.{"/u/Downloads"} };
    const r = try run(spec, &g, null);
    try testing.expectEqual(@as(?usize, 1), r.primary);
    try testing.expectEqualSlices(bool, &.{ true, false, true }, r.targets[0..3]);

    // All in Downloads: one of them has to stay.
    const all_there = [_]Member{ mem("/u/Downloads/a", 1), mem("/u/Downloads/b", 2) };
    const r2 = try run(spec, &all_there, null);
    try testing.expectEqualSlices(bool, &.{ false, true }, r2.targets[0..2]);
}

test "protected copies are never targets" {
    var g = [_]Member{ mem("/usr/lib/x.so", 1), mem("/u/proj/x.so", 2), mem("/u/Downloads/x.so", 3) };
    g[0].protected = true;
    // Normal mode: the system copy does not make the project's copy expendable.
    const r = try run(.{}, &g, null);
    try testing.expectEqual(@as(?usize, 1), r.primary);
    try testing.expectEqualSlices(bool, &.{ false, false, true }, r.targets[0..3]);

    // Cleaning Downloads: the system copy is the survivor.
    const r2 = try run(.{ .delete_only_under = &.{"/u/Downloads"} }, &g, null);
    try testing.expectEqualSlices(bool, &.{ false, false, true }, r2.targets[0..3]);

    var all = [_]Member{ mem("/usr/a", 1), mem("/opt/a", 2) };
    all[0].protected = true;
    all[1].protected = true;
    const r3 = try run(.{}, &all, null);
    try testing.expectEqual(@as(?usize, 0), r3.primary);
    try testing.expectEqualSlices(bool, &.{ false, false }, r3.targets[0..2]);
}

test "newest and shortest path fallbacks" {
    const g = [_]Member{ mem("/u/a/b/c/x", 1), mem("/u/x", 3), mem("/u/q/x", 3) };
    try testing.expectEqual(@as(?usize, 1), (try run(.{ .fallback = .newest }, &g, null)).primary);
    try testing.expectEqual(@as(?usize, 1), (try run(.{ .fallback = .shortest_path }, &g, null)).primary);
}
