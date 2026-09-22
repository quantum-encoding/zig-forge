//! End-to-end tests for the results session.
//!
//! Every test here runs the real engine over a real temp tree, writes a real
//! result store, and then asks the session the questions a frontend asks. The
//! cases are the ones the Rust reference's own tests enumerate
//! (`src-tauri/src/commands/results.rs`, `commands/bulk.rs`, `removed.rs` in
//! the desktop app), because that implementation is what this one replaces:
//! anything it refused to delete, this must refuse too.
//!
//! Deletes are permanent (`use_trash = false`) unless the test is specifically
//! about the Trash, which is a fake that unlinks and records — no test may
//! touch the user's real Trash.

const std = @import("std");
const lib = @import("lib.zig");
const session = @import("session.zig");
const store = @import("store.zig");
const removed_mod = @import("removed.zig");
const Scratch = @import("testing_scratch.zig").Scratch;

const testing = std.testing;
const Allocator = std.mem.Allocator;
const Session = session.Session;

// ===========================================================================
// Fixtures
// ===========================================================================

const File = struct { path: []const u8, byte: u8, size: usize };

/// A scanned tree plus the store written from it. The store lives in its own
/// scratch directory: written inside the tree it would become part of the next
/// scan, and the sidecars with it.
const Fixture = struct {
    gpa: Allocator,
    tree: Scratch,
    out: Scratch,
    store_path: [:0]u8,

    fn init(gpa: Allocator, label: []const u8, files: []const File) !Fixture {
        var tree = try Scratch.init(gpa, label);
        errdefer tree.deinit();
        var out = try Scratch.init(gpa, "store");
        errdefer out.deinit();

        var made: std.StringHashMapUnmanaged(void) = .empty;
        defer made.deinit(gpa);
        for (files) |file| {
            const dir = std.fs.path.dirname(file.path) orelse "";
            if (dir.len > 0 and !made.contains(dir)) {
                try tree.makeDir(dir);
                try made.put(gpa, dir, {});
            }
            const content = try gpa.alloc(u8, file.size);
            defer gpa.free(content);
            @memset(content, file.byte);
            try tree.writeFile(file.path, content);
        }

        var self: Fixture = .{
            .gpa = gpa,
            .tree = tree,
            .out = out,
            .store_path = try out.joinZ("result.zds"),
        };
        errdefer gpa.free(self.store_path);
        try self.scan();
        return self;
    }

    /// The engine, through the same C entry point a desktop host calls.
    fn scan(self: *Fixture) !void {
        const ctx = lib.zdedupe_init() orelse return error.ScannerInitFailed;
        defer lib.zdedupe_free(ctx);
        lib.zdedupe_set_mode(ctx, 0);
        const root = try self.gpa.dupeZ(u8, self.tree.path);
        defer self.gpa.free(root);
        if (lib.zdedupe_add_path(ctx, root.ptr) != 0) return error.AddPathFailed;
        if (lib.zdedupe_run_to_file(ctx, self.store_path.ptr) != 0) return error.ScanFailed;
    }

    fn deinit(self: *Fixture) void {
        self.gpa.free(self.store_path);
        self.out.deinit();
        self.tree.deinit();
    }

    fn open(self: *Fixture, roots_json: ?[]const u8) !*Session {
        return Session.open(self.gpa, self.store_path, roots_json);
    }

    /// Absolute path of `sub_path` inside the tree. Caller frees.
    fn path(self: *const Fixture, sub_path: []const u8) ![]u8 {
        return self.tree.join(sub_path);
    }

    fn exists(self: *const Fixture, sub_path: []const u8) bool {
        return self.tree.exists(sub_path) catch false;
    }

    /// How many of `dirs` still hold `name`.
    fn remaining(self: *const Fixture, dirs: []const []const u8, name: []const u8) usize {
        var count: usize = 0;
        for (dirs) |dir| {
            const sub = std.fmt.allocPrint(self.gpa, "{s}/{s}", .{ dir, name }) catch continue;
            defer self.gpa.free(sub);
            if (self.exists(sub)) count += 1;
        }
        return count;
    }
};

/// big.bin x2 (most savings), small.txt x4 (most copies), mid.dat x2.
const results_tree = [_]File{
    .{ .path = "Alpha/big.bin", .byte = 'b', .size = 4000 },
    .{ .path = "beta/big.bin", .byte = 'b', .size = 4000 },
    .{ .path = "Alpha/small.txt", .byte = 's', .size = 10 },
    .{ .path = "beta/small.txt", .byte = 's', .size = 10 },
    .{ .path = "gamma/small.txt", .byte = 's', .size = 10 },
    .{ .path = "delta/small.txt", .byte = 's', .size = 10 },
    .{ .path = "gamma/mid.dat", .byte = 'm', .size = 500 },
    .{ .path = "delta/mid.dat", .byte = 'm', .size = 500 },
};

/// dup.bin in three folders, other.bin in two.
const bulk_tree = [_]File{
    .{ .path = "a/dup.bin", .byte = 'd', .size = 3000 },
    .{ .path = "b/dup.bin", .byte = 'd', .size = 3000 },
    .{ .path = "c/dup.bin", .byte = 'd', .size = 3000 },
    .{ .path = "a/other.bin", .byte = 'o', .size = 500 },
    .{ .path = "b/other.bin", .byte = 'o', .size = 500 },
};

const abc = [_][]const u8{ "a", "b", "c" };

// ===========================================================================
// JSON helpers
// ===========================================================================

/// Parsed answers live in `arena`; the session's own copy is freed by the next
/// call on it, so every assertion parses first.
fn parse(arena: Allocator, json: ?[:0]const u8) !std.json.Value {
    const text = json orelse return error.CallFailed;
    return std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{});
}

fn field(value: std.json.Value, name: []const u8) std.json.Value {
    return value.object.get(name).?;
}

fn int(value: std.json.Value, name: []const u8) i64 {
    return field(value, name).integer;
}

/// The `size` of every row of a group page, in order.
fn rowSizes(arena: Allocator, page: std.json.Value) ![]i64 {
    const rows = field(page, "rows").array.items;
    const out = try arena.alloc(i64, rows.len);
    for (rows, out) |row, *slot| slot.* = int(row, "size");
    return out;
}

fn query(arena: Allocator, comptime fmt: []const u8, args: anytype) ![]u8 {
    return std.fmt.allocPrint(arena, fmt, args);
}

/// A JSON string literal for `value`, escaped — paths in these trees contain a
/// random component and, in one test, characters JSON must escape.
fn jsonString(arena: Allocator, value: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    try std.json.Stringify.encodeJsonString(value, .{}, &out.writer);
    return out.written();
}

// ===========================================================================
// Opening
// ===========================================================================

test "a store that fails validation does not open" {
    const gpa = testing.allocator;
    var scratch = try Scratch.init(gpa, "session-bad-store");
    defer scratch.deinit();

    try scratch.writeFile("not-a-store.zds", "ZDSTORE1" ++ "garbage" ** 40);
    const bad = try scratch.join("not-a-store.zds");
    defer gpa.free(bad);
    try testing.expectError(error.StoreIsInvalid, Session.open(gpa, bad, null));

    // Too short to hold a header at all.
    try scratch.writeFile("stub.zds", "ZDS");
    const stub = try scratch.join("stub.zds");
    defer gpa.free(stub);
    try testing.expectError(error.StoreIsInvalid, Session.open(gpa, stub, null));

    // And a path that is not there.
    try testing.expectError(error.CannotOpenStore, Session.open(gpa, "/no/such/zdedupe/store.zds", null));
}

test "the overview reports the scan's own counters and its roots" {
    const gpa = testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    var fixture = try Fixture.init(gpa, "session-overview", &results_tree);
    defer fixture.deinit();

    const roots_json = try query(a, "[{s}]", .{try jsonString(a, fixture.tree.path)});
    var s = try fixture.open(roots_json);
    defer s.close();

    const view = try parse(a, s.overview());
    try testing.expectEqual(@as(i64, 8), int(view, "files_scanned"));
    try testing.expectEqual(@as(i64, 3), int(view, "duplicate_groups"));
    // 4000 + 500 + 3 * 10
    try testing.expectEqual(@as(i64, 4530), int(view, "space_savings"));
    try testing.expectEqual(@as(i64, 0), int(view, "identical_sets"));
    try testing.expect(!field(view, "has_directories").bool);

    const roots = field(view, "roots").array.items;
    try testing.expectEqual(@as(usize, 1), roots.len);
    try testing.expectEqualStrings(fixture.tree.path, roots[0].string);

    // Epoch milliseconds, not seconds.
    try testing.expect(int(view, "generated_at") > 1_500_000_000_000);
}

test "reopening without roots derives them from the paths in the results" {
    const gpa = testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    var fixture = try Fixture.init(gpa, "session-derived-roots", &results_tree);
    defer fixture.deinit();

    // No sidecar was ever written, so the deepest folder holding every result
    // stands in for the scan roots.
    var s = try fixture.open(null);
    defer s.close();
    const roots = field(try parse(a, s.overview()), "roots").array.items;
    try testing.expectEqual(@as(usize, 1), roots.len);
    try testing.expectEqualStrings(fixture.tree.path, roots[0].string);
}

// ===========================================================================
// Paging, order and filters
// ===========================================================================

test "groups come back in the requested order" {
    const gpa = testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    var fixture = try Fixture.init(gpa, "session-order", &results_tree);
    defer fixture.deinit();
    var s = try fixture.open(null);
    defer s.close();

    // savings: 4000*1, 500*1, 10*3
    for ([_][]const u8{ "savings", "size" }) |sort| {
        const q = try query(a, "{{\"offset\":0,\"limit\":50,\"sort\":\"{s}\"}}", .{sort});
        const page = try parse(a, s.groups(q));
        try testing.expectEqualSlices(i64, &.{ 4000, 500, 10 }, try rowSizes(a, page));
    }
    // copies: small.txt x4 first; the two-copy groups keep their savings order.
    const by_count = try parse(a, s.groups("{\"offset\":0,\"limit\":50,\"sort\":\"count\"}"));
    try testing.expectEqualSlices(i64, &.{ 10, 4000, 500 }, try rowSizes(a, by_count));
}

test "paging reports the full match count and clamps the page size" {
    const gpa = testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    var fixture = try Fixture.init(gpa, "session-paging", &results_tree);
    defer fixture.deinit();
    var s = try fixture.open(null);
    defer s.close();

    const second = try parse(a, s.groups("{\"offset\":1,\"limit\":1,\"sort\":\"savings\"}"));
    try testing.expectEqualSlices(i64, &.{500}, try rowSizes(a, second));
    try testing.expectEqual(@as(i64, 3), int(second, "total"));
    try testing.expectEqual(@as(i64, 1), int(second, "offset"));

    const past_the_end = try parse(a, s.groups("{\"offset\":50,\"limit\":10,\"sort\":\"savings\"}"));
    try testing.expectEqual(@as(usize, 0), field(past_the_end, "rows").array.items.len);
    try testing.expectEqual(@as(i64, 3), int(past_the_end, "total"));

    // A caller cannot ask for an unbounded page; the clamp is what bounds the
    // work, so it must hold for a limit no caller could honestly mean.
    const huge = try parse(a, s.groups("{\"offset\":0,\"limit\":18446744073709551615,\"sort\":\"savings\"}"));
    try testing.expectEqual(@as(usize, 3), field(huge, "rows").array.items.len);
}

test "rows list the oldest file first, with live savings and millisecond times" {
    const gpa = testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    var fixture = try Fixture.init(gpa, "session-rows", &results_tree);
    defer fixture.deinit();
    var s = try fixture.open(null);
    defer s.close();

    const page = try parse(a, s.groups("{\"offset\":0,\"limit\":1,\"sort\":\"savings\"}"));
    const row = field(page, "rows").array.items[0];
    try testing.expectEqual(@as(usize, 64), field(row, "hash").string.len);
    try testing.expectEqual(@as(i64, 4000), int(row, "size"));
    try testing.expectEqual(@as(i64, 4000), int(row, "savings"));
    try testing.expectEqual(@as(i64, 2), int(row, "count"));
    try testing.expect(!field(row, "bulk").bool);

    const files = field(row, "files").array.items;
    const mtimes = field(row, "mtimes").array.items;
    try testing.expectEqual(@as(usize, 2), files.len);
    try testing.expectEqual(@as(usize, 2), mtimes.len);
    try testing.expect(mtimes[0].integer <= mtimes[1].integer);
    for (mtimes) |ms| try testing.expect(ms.integer > 1_500_000_000_000);
}

test "a bulk rule marks the rows it covers, and only those" {
    const gpa = testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    var fixture = try Fixture.init(gpa, "session-bulk-mark", &results_tree);
    defer fixture.deinit();
    var s = try fixture.open(null);
    defer s.close();

    const everything = try parse(a, s.groups("{\"offset\":0,\"limit\":50,\"sort\":\"savings\",\"bulk\":{}}"));
    for (field(everything, "rows").array.items) |row| try testing.expect(field(row, "bulk").bool);

    // A rule that matches one group marks that row and leaves the rest clear.
    const some = try parse(a, s.groups(
        "{\"offset\":0,\"limit\":50,\"sort\":\"savings\",\"bulk\":{\"min_bytes\":1000}}",
    ));
    const rows = field(some, "rows").array.items;
    try testing.expect(field(rows[0], "bulk").bool);
    try testing.expect(!field(rows[1], "bulk").bool);
    try testing.expect(!field(rows[2], "bulk").bool);

    const nowhere = try parse(a, s.groups(
        "{\"offset\":0,\"limit\":50,\"sort\":\"savings\",\"bulk\":{\"text\":\"no-such-path\"}}",
    ));
    for (field(nowhere, "rows").array.items) |row| try testing.expect(!field(row, "bulk").bool);
}

test "every filter field narrows the list" {
    const gpa = testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    var fixture = try Fixture.init(gpa, "session-filters", &results_tree);
    defer fixture.deinit();
    var s = try fixture.open(null);
    defer s.close();

    const sizes = struct {
        fn of(inner_arena: Allocator, sess: *Session, filters: []const u8) ![]i64 {
            const q = try query(inner_arena, "{{\"offset\":0,\"limit\":50,\"sort\":\"savings\",\"filters\":{s}}}", .{filters});
            return rowSizes(inner_arena, try parse(inner_arena, sess.groups(q)));
        }
    }.of;

    // text: trimmed, ASCII-case-insensitive, over any member's path. The
    // directory is spelled "Alpha" and holds big.bin and small.txt.
    try testing.expectEqualSlices(i64, &.{ 4000, 10 }, try sizes(a, s, "{\"text\":\"  alpha \"}"));
    try testing.expectEqualSlices(i64, &.{500}, try sizes(a, s, "{\"text\":\"MID.DAT\"}"));
    try testing.expectEqualSlices(i64, &.{}, try sizes(a, s, "{\"text\":\"no-such-path\"}"));

    // min_bytes is the size of one file in the group.
    try testing.expectEqualSlices(i64, &.{ 4000, 500 }, try sizes(a, s, "{\"min_bytes\":100}"));
    try testing.expectEqualSlices(i64, &.{}, try sizes(a, s, "{\"min_bytes\":4001}"));

    // name and ext.
    try testing.expectEqualSlices(i64, &.{10}, try sizes(a, s, "{\"name\":\"small.txt\"}"));
    try testing.expectEqualSlices(i64, &.{4000}, try sizes(a, s, "{\"ext\":\".BIN\"}"));
    try testing.expectEqualSlices(i64, &.{}, try sizes(a, s, "{\"ext\":\"\"}"));

    // under, by whole path components.
    const under_alpha = try query(a, "{{\"under\":{s}}}", .{
        try jsonString(a, try std.fmt.allocPrint(a, "{s}/Alpha", .{fixture.tree.path})),
    });
    try testing.expectEqualSlices(i64, &.{ 4000, 10 }, try sizes(a, s, under_alpha));

    // A sibling whose name merely starts the same is a different folder.
    const under_prefix = try query(a, "{{\"under\":{s}}}", .{
        try jsonString(a, try std.fmt.allocPrint(a, "{s}/Alph", .{fixture.tree.path})),
    });
    try testing.expectEqualSlices(i64, &.{}, try sizes(a, s, under_prefix));

    // The facets must hold for the SAME member: nothing under Alpha is called
    // mid.dat, though both exist in these results.
    const alpha_mid = try query(a, "{{\"under\":{s},\"name\":\"mid.dat\"}}", .{
        try jsonString(a, try std.fmt.allocPrint(a, "{s}/Alpha", .{fixture.tree.path})),
    });
    try testing.expectEqualSlices(i64, &.{}, try sizes(a, s, alpha_mid));
}

// ===========================================================================
// Bulk summary
// ===========================================================================

test "the bulk summary counts every copy but the oldest" {
    const gpa = testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    var fixture = try Fixture.init(gpa, "session-bulk-summary", &results_tree);
    defer fixture.deinit();
    var s = try fixture.open(null);
    defer s.close();

    const all = try parse(a, s.bulkSummary("{}"));
    try testing.expectEqual(@as(i64, 3), int(all, "groups"));
    // big.bin 1 + mid.dat 1 + small.txt 3
    try testing.expectEqual(@as(i64, 5), int(all, "files"));
    try testing.expectEqual(@as(i64, 4530), int(all, "bytes"));

    const big_only = try parse(a, s.bulkSummary("{\"min_bytes\":1000}"));
    try testing.expectEqual(@as(i64, 1), int(big_only, "groups"));
    try testing.expectEqual(@as(i64, 1), int(big_only, "files"));
    try testing.expectEqual(@as(i64, 4000), int(big_only, "bytes"));
}

test "the bulk summary follows a delete without a rescan" {
    const gpa = testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    var fixture = try Fixture.init(gpa, "session-summary-after", &results_tree);
    defer fixture.deinit();
    var s = try fixture.open(null);
    defer s.close();

    // Take every copy but one of small.txt: 4 copies -> 1, so that group stops
    // being a finding at all.
    const report = try parse(a, s.delete("{\"rule\":{\"filters\":{\"name\":\"small.txt\"}}}", false, null, null));
    try testing.expectEqual(@as(i64, 3), int(report, "deleted"));
    try testing.expectEqual(@as(i64, 30), int(report, "freed_bytes"));
    try testing.expect(!field(report, "needs_rescan").bool);

    const after = try parse(a, s.bulkSummary("{}"));
    try testing.expectEqual(@as(i64, 2), int(after, "groups"));
    try testing.expectEqual(@as(i64, 2), int(after, "files"));
    try testing.expectEqual(@as(i64, 4500), int(after, "bytes"));

    // And the rows agree: small.txt is down to one copy and is gone from them.
    const page = try parse(a, s.groups("{\"offset\":0,\"limit\":50,\"sort\":\"savings\"}"));
    try testing.expectEqualSlices(i64, &.{ 4000, 500 }, try rowSizes(a, page));

    const status = try parse(a, s.removedStatus());
    try testing.expectEqual(@as(i64, 3), int(status, "count"));
    try testing.expect(!field(status, "needs_rescan").bool);
}

// ===========================================================================
// Delete
// ===========================================================================

test "a rule deletes every copy but one and reports what it freed" {
    const gpa = testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    var fixture = try Fixture.init(gpa, "session-delete-all", &bulk_tree);
    defer fixture.deinit();
    var s = try fixture.open(null);
    defer s.close();

    const report = try parse(a, s.delete("{\"rule\":{\"filters\":{}}}", false, null, null));
    try testing.expectEqual(@as(i64, 3), int(report, "deleted")); // 2 dup.bin + 1 other.bin
    try testing.expectEqual(@as(i64, 2 * 3000 + 500), int(report, "freed_bytes"));
    try testing.expectEqual(@as(i64, 0), int(report, "skipped_changed"));
    try testing.expectEqual(@as(i64, 0), int(report, "failed_count"));
    try testing.expect(!field(report, "cancelled").bool);
    try testing.expectEqual(@as(usize, 1), fixture.remaining(&abc, "dup.bin"));
    try testing.expectEqual(@as(usize, 1), fixture.remaining(&abc, "other.bin"));
}

test "an unticked copy is left alone" {
    const gpa = testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    var fixture = try Fixture.init(gpa, "session-unticked", &bulk_tree);
    defer fixture.deinit();
    var s = try fixture.open(null);
    defer s.close();

    const spare = try fixture.path("c/dup.bin");
    defer gpa.free(spare);
    const selection = try query(a, "{{\"rule\":{{\"filters\":{{}},\"excluded\":[{s}]}}}}", .{try jsonString(a, spare)});

    const report = try parse(a, s.delete(selection, false, null, null));
    try testing.expectEqual(@as(i64, 2), int(report, "deleted"));
    try testing.expect(fixture.exists("c/dup.bin"));
}

test "a permanent delete goes by content, not by timestamp" {
    const gpa = testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    var fixture = try Fixture.init(gpa, "session-content", &bulk_tree);
    defer fixture.deinit();

    // b: same length, different bytes, and its old mtime put back. A metadata
    // check would wave it through; its content says otherwise.
    const edited = try fixture.path("b/dup.bin");
    defer gpa.free(edited);
    const edited_z = try gpa.dupeZ(u8, edited);
    defer gpa.free(edited_z);
    const before = try @import("pstat.zig").lstat(edited_z.ptr);
    try fixture.tree.writeFile("b/dup.bin", &[_]u8{'X'} ** 3000);
    try setMtime(edited_z, before.mtime_sec);

    var s = try fixture.open(null);
    defer s.close();
    const report = try parse(a, s.delete("{\"rule\":{\"filters\":{}}}", false, null, null));

    // Its content is no longer what the scan hashed, so it stays.
    try testing.expect(fixture.exists("b/dup.bin"));
    try testing.expectEqual(@as(i64, 1), int(report, "skipped_changed"));
    // a/dup.bin is kept, b is skipped, c goes; other.bin loses one copy.
    try testing.expectEqual(@as(usize, 2), fixture.remaining(&abc, "dup.bin"));
    try testing.expectEqual(@as(i64, 2), int(report, "deleted"));
}

test "a copy modified since the scan is not trashed either" {
    const gpa = testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    var fixture = try Fixture.init(gpa, "session-metadata", &bulk_tree);
    defer fixture.deinit();

    // Same bytes, a newer mtime: content would pass, metadata must not.
    const touched = try fixture.path("b/dup.bin");
    defer gpa.free(touched);
    const touched_z = try gpa.dupeZ(u8, touched);
    defer gpa.free(touched_z);
    const before = try @import("pstat.zig").lstat(touched_z.ptr);
    try setMtime(touched_z, before.mtime_sec + 3600);

    var trash: FakeTrash = .{ .gpa = gpa };
    defer trash.deinit();

    var s = try fixture.open(null);
    defer s.close();
    const report = try parse(a, s.delete("{\"rule\":{\"filters\":{}}}", true, FakeTrash.callback, &trash));

    try testing.expect(fixture.exists("b/dup.bin"));
    try testing.expectEqual(@as(i64, 1), int(report, "skipped_changed"));
    try testing.expectEqual(@as(usize, 2), fixture.remaining(&abc, "dup.bin"));
    // The Trash was the host's callback, and only for files that verified.
    try testing.expectEqual(@as(usize, 2), trash.moved.items.len);
}

test "nothing in a group goes if no copy would survive" {
    const gpa = testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    var fixture = try Fixture.init(gpa, "session-keeper", &bulk_tree);
    defer fixture.deinit();

    // Something else took the copy that was to be kept.
    const keeper = try fixture.path("a/dup.bin");
    defer gpa.free(keeper);
    const keeper_z = try gpa.dupeZ(u8, keeper);
    defer gpa.free(keeper_z);
    try testing.expectEqual(@as(c_int, 0), std.c.unlink(keeper_z.ptr));

    var s = try fixture.open(null);
    defer s.close();
    const report = try parse(a, s.delete("{\"rule\":{\"filters\":{}}}", false, null, null));

    // Deleting the other two would leave nothing of that group.
    try testing.expectEqual(@as(usize, 2), fixture.remaining(&abc, "dup.bin"));
    try testing.expectEqual(@as(i64, 2), int(report, "skipped_changed"));
    try testing.expectEqual(@as(i64, 1), int(report, "deleted")); // other.bin is unaffected
}

test "ticking every copy by hand still keeps one" {
    const gpa = testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    var fixture = try Fixture.init(gpa, "session-by-hand", &bulk_tree);
    defer fixture.deinit();

    var every: std.ArrayListUnmanaged([]const u8) = .empty;
    for (abc) |dir| {
        try every.append(a, try jsonString(a, try treePath(a, &fixture, dir, "dup.bin")));
    }

    {
        var s = try fixture.open(null);
        defer s.close();
        const selection = try query(a, "{{\"extra\":[{s},{s},{s}]}}", .{ every.items[0], every.items[1], every.items[2] });
        const report = try parse(a, s.delete(selection, false, null, null));
        // All three ticked: no copy would survive, so none goes.
        try testing.expectEqual(@as(i64, 0), int(report, "deleted"));
        try testing.expectEqual(@as(i64, 3), int(report, "skipped_changed"));
        try testing.expectEqual(@as(usize, 3), fixture.remaining(&abc, "dup.bin"));
    }
    {
        // Two of the three, and the group keeps its third.
        var s = try fixture.open(null);
        defer s.close();
        const selection = try query(a, "{{\"extra\":[{s},{s}]}}", .{ every.items[0], every.items[1] });
        const report = try parse(a, s.delete(selection, false, null, null));
        try testing.expectEqual(@as(i64, 2), int(report, "deleted"));
        try testing.expectEqual(@as(usize, 1), fixture.remaining(&abc, "dup.bin"));
    }
}

test "a hand-picked path that is not in the results is never deleted" {
    const gpa = testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    var fixture = try Fixture.init(gpa, "session-stranger", &bulk_tree);
    defer fixture.deinit();
    try fixture.tree.writeFile("a/unrelated.txt", "not a duplicate of anything");

    var s = try fixture.open(null);
    defer s.close();
    const stranger = try fixture.path("a/unrelated.txt");
    defer gpa.free(stranger);
    const selection = try query(a, "{{\"extra\":[{s}]}}", .{try jsonString(a, stranger)});

    const report = try parse(a, s.delete(selection, false, null, null));
    try testing.expect(fixture.exists("a/unrelated.txt"));
    try testing.expectEqual(@as(i64, 0), int(report, "deleted"));
    try testing.expectEqual(@as(i64, 1), int(report, "failed_count"));

    const failed = field(report, "failed").array.items;
    try testing.expectEqual(@as(usize, 1), failed.len);
    try testing.expectEqualStrings(stranger, failed[0].array.items[0].string);
    try testing.expectEqualStrings("not a duplicate in the current results", failed[0].array.items[1].string);
}

test "a second delete plans around what the first one removed" {
    const gpa = testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    var fixture = try Fixture.init(gpa, "session-second-pass", &bulk_tree);
    defer fixture.deinit();
    var s = try fixture.open(null);
    defer s.close();

    // First pass takes only the copies the rule covers in the dup.bin group,
    // by hand-picking the middle one; the keeper is untouched.
    const middle = try fixture.path("b/dup.bin");
    defer gpa.free(middle);
    const first = try parse(a, s.delete(
        try query(a, "{{\"extra\":[{s}]}}", .{try jsonString(a, middle)}),
        false,
        null,
        null,
    ));
    try testing.expectEqual(@as(i64, 1), int(first, "deleted"));

    // Second pass: the overlay already knows b/dup.bin is gone, so the rule
    // keeps a/ and takes c/ — it does not target a copy that no longer exists
    // and then find no survivor.
    const second = try parse(a, s.delete("{\"rule\":{\"filters\":{}}}", false, null, null));
    try testing.expectEqual(@as(i64, 0), int(second, "skipped_changed"));
    try testing.expectEqual(@as(usize, 1), fixture.remaining(&abc, "dup.bin"));
    try testing.expect(fixture.exists("a/dup.bin"));
}

test "a cancelled delete stops before touching anything more" {
    const gpa = testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    var fixture = try Fixture.init(gpa, "session-cancel", &bulk_tree);
    defer fixture.deinit();
    var s = try fixture.open(null);
    defer s.close();

    // Cancelling before the run is the deterministic shape of cancelling
    // during one: the flag is checked before each group.
    s.cancelDelete();
    const report = try parse(a, s.delete("{\"rule\":{\"filters\":{}}}", false, null, null));

    try testing.expect(field(report, "cancelled").bool);
    try testing.expectEqual(@as(i64, 0), int(report, "deleted"));
    try testing.expectEqual(@as(usize, 3), fixture.remaining(&abc, "dup.bin"));
    try testing.expectEqual(@as(usize, 2), fixture.remaining(&.{ "a", "b" }, "other.bin"));

    // And the cancel does not persist into the next delete.
    const after = try parse(a, s.delete("{\"rule\":{\"filters\":{}}}", false, null, null));
    try testing.expect(!field(after, "cancelled").bool);
    try testing.expectEqual(@as(i64, 3), int(after, "deleted"));
}

test "progress carries the whole plan before anything is deleted" {
    const gpa = testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    var fixture = try Fixture.init(gpa, "session-progress", &bulk_tree);
    defer fixture.deinit();
    var s = try fixture.open(null);
    defer s.close();

    try testing.expectEqual(session.DeleteProgress{ .running = false, .done = 0, .total = 0 }, s.deleteProgress());

    // The callback runs while the delete holds the session, which is exactly
    // the window a UI polls in.
    var trash: FakeTrash = .{ .gpa = gpa, .observe = s };
    defer trash.deinit();

    const report = try parse(a, s.delete("{\"rule\":{\"filters\":{}}}", true, FakeTrash.callback, &trash));
    try testing.expectEqual(@as(i64, 3), int(report, "deleted"));

    // Seen from inside: running, and the total already the full plan.
    try testing.expect(trash.seen.running);
    try testing.expectEqual(@as(u64, 3), trash.seen.total);

    const done = s.deleteProgress();
    try testing.expect(!done.running);
    try testing.expectEqual(@as(u64, 3), done.total);
    try testing.expectEqual(@as(u64, 3), done.done);
}

test "a second delete while one runs is refused" {
    const gpa = testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    var fixture = try Fixture.init(gpa, "session-reentrant", &bulk_tree);
    defer fixture.deinit();
    var s = try fixture.open(null);
    defer s.close();

    // Re-entering from the Trash callback is the same contract a second thread
    // would hit, without the race.
    var trash: FakeTrash = .{ .gpa = gpa, .reenter = s };
    defer trash.deinit();

    const report = try parse(a, s.delete("{\"rule\":{\"filters\":{}}}", true, FakeTrash.callback, &trash));
    try testing.expectEqual(@as(i64, 3), int(report, "deleted"));
    try testing.expect(trash.reentry_refused);
    try testing.expectEqualStrings("A delete is already running", trash.reentry_message.?);
}

test "a delete that asks for the Trash without a callback is refused" {
    const gpa = testing.allocator;
    var fixture = try Fixture.init(gpa, "session-no-trash", &bulk_tree);
    defer fixture.deinit();
    var s = try fixture.open(null);
    defer s.close();

    try testing.expect(s.delete("{\"rule\":{\"filters\":{}}}", true, null, null) == null);
    try testing.expectEqualStrings("no Trash callback was provided", s.lastError().?);
    try testing.expectEqual(@as(usize, 3), fixture.remaining(&abc, "dup.bin"));
}

test "a malformed query fails the call and says why" {
    const gpa = testing.allocator;
    var fixture = try Fixture.init(gpa, "session-bad-query", &bulk_tree);
    defer fixture.deinit();
    var s = try fixture.open(null);
    defer s.close();

    try testing.expect(s.groups("{not json") == null);
    try testing.expectEqualStrings("group query is not valid JSON", s.lastError().?);
    try testing.expect(s.bulkSummary("[]") == null);
    try testing.expect(s.delete("{\"rule\":", false, null, null) == null);
    // An unknown sort is a query error, not a silent default.
    try testing.expect(s.groups("{\"offset\":0,\"limit\":1,\"sort\":\"whatever\"}") == null);
}

// ===========================================================================
// The removed overlay, through the session
// ===========================================================================

test "what a delete removed is still gone after the session is reopened" {
    const gpa = testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    var fixture = try Fixture.init(gpa, "session-overlay", &bulk_tree);
    defer fixture.deinit();

    {
        var s = try fixture.open(null);
        defer s.close();
        const report = try parse(a, s.delete("{\"rule\":{\"filters\":{}}}", false, null, null));
        try testing.expectEqual(@as(i64, 3), int(report, "deleted"));
    }
    {
        // Reopening loads the sidecar: the groups do not come back.
        var s = try fixture.open(null);
        defer s.close();
        const status = try parse(a, s.removedStatus());
        try testing.expectEqual(@as(i64, 3), int(status, "count"));
        const page = try parse(a, s.groups("{\"offset\":0,\"limit\":50,\"sort\":\"savings\"}"));
        try testing.expectEqual(@as(i64, 0), int(page, "total"));
    }
    {
        // Opening with roots is a fresh scan: the overlay is discarded.
        const roots_json = try query(a, "[{s}]", .{try jsonString(a, fixture.tree.path)});
        var s = try fixture.open(roots_json);
        defer s.close();
        const status = try parse(a, s.removedStatus());
        try testing.expectEqual(@as(i64, 0), int(status, "count"));
        try testing.expect(!field(status, "needs_rescan").bool);
    }
}

test "a deleted folder covers everything the results list inside it" {
    const gpa = testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    var fixture = try Fixture.init(gpa, "session-ancestor", &results_tree);
    defer fixture.deinit();
    var s = try fixture.open(null);
    defer s.close();

    // Stage A deletes files, but the overlay is what a folder delete will
    // write, so the rows must already honour an ancestor.
    const beta = try fixture.path("beta");
    defer gpa.free(beta);
    // Recording bumps the overlay's generation, which is part of the cached
    // order's key, so the next page recomputes on its own.
    _ = s.removed.record(&.{beta});

    // big.bin is down to one copy and stops being a finding; small.txt loses
    // the beta copy.
    const page = try parse(a, s.groups("{\"offset\":0,\"limit\":50,\"sort\":\"savings\"}"));
    try testing.expectEqualSlices(i64, &.{ 500, 10 }, try rowSizes(a, page));

    const small = field(page, "rows").array.items[1];
    try testing.expectEqual(@as(i64, 3), int(small, "count"));
    for (field(small, "files").array.items) |file| {
        try testing.expect(std.mem.indexOf(u8, file.string, "/beta/") == null);
    }
}

test "an overflowed overlay asks for a rescan, through the session and after reopening" {
    const gpa = testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    var fixture = try Fixture.init(gpa, "session-overflow", &bulk_tree);
    defer fixture.deinit();

    {
        var s = try fixture.open(null);
        defer s.close();

        var flood: std.ArrayListUnmanaged([]const u8) = .empty;
        for (0..removed_mod.max_tracked + 1) |i| {
            try flood.append(a, try std.fmt.allocPrint(a, "/f/{d}", .{i}));
        }
        try testing.expect(!s.removed.record(flood.items));

        const status = try parse(a, s.removedStatus());
        try testing.expectEqual(@as(i64, 0), int(status, "count"));
        try testing.expect(field(status, "needs_rescan").bool);
    }
    {
        var s = try fixture.open(null);
        defer s.close();
        const status = try parse(a, s.removedStatus());
        try testing.expect(field(status, "needs_rescan").bool);

        // A delete that removes nothing still reports the standing overflow.
        s.cancelDelete();
        const report = try parse(a, s.delete("{\"rule\":{\"filters\":{}}}", false, null, null));
        try testing.expect(field(report, "needs_rescan").bool);
    }
}

// ===========================================================================
// Non-UTF-8 names
// ===========================================================================

test "a name that is not UTF-8 pages, spells and deletes correctly" {
    if (@import("builtin").os.tag.isDarwin()) {
        // APFS validates file names and refuses invalid UTF-8, so the tree
        // this needs cannot be built here. The byte round trip that carries
        // such a name through the overlay's sidecar is asserted directly in
        // removed.zig; the lossy spelling itself is asserted in session.zig.
        return error.SkipZigTest;
    }
    const gpa = testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    var fixture = try Fixture.init(gpa, "session-raw-bytes", &.{});
    defer fixture.deinit();

    // Two copies whose names are not valid UTF-8, and one plain copy of the
    // same content to keep.
    const payload = [_]u8{'z'} ** 600;
    try fixture.tree.makeDir("raw");
    try fixture.tree.writeFile("raw/keep.bin", &payload);
    try fixture.tree.writeFile("raw/caf\xe9.bin", &payload);
    try fixture.scan();

    var s = try fixture.open(null);
    defer s.close();

    const page = try parse(a, s.groups("{\"offset\":0,\"limit\":50,\"sort\":\"savings\"}"));
    const files = field(field(page, "rows").array.items[0], "files").array.items;
    try testing.expectEqual(@as(usize, 2), files.len);

    // The row carries the lossy spelling, and it is what comes back in.
    const lossy_name = for (files) |file| {
        if (std.mem.indexOf(u8, file.string, "\u{FFFD}") != null) break file.string;
    } else return error.LossyNameMissing;

    const selection = try query(a, "{{\"extra\":[{s}]}}", .{try jsonString(a, lossy_name)});
    const report = try parse(a, s.delete(selection, false, null, null));
    try testing.expectEqual(@as(i64, 1), int(report, "deleted"));
    try testing.expectEqual(@as(i64, 0), int(report, "failed_count"));
    // The exact bytes went, not a lossy re-spelling of them.
    try testing.expect(!fixture.exists("raw/caf\xe9.bin"));
    try testing.expect(fixture.exists("raw/keep.bin"));
}

// ===========================================================================
// Export
// ===========================================================================

test "export writes every alive group in each format" {
    const gpa = testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    var fixture = try Fixture.init(gpa, "session-export", &results_tree);
    defer fixture.deinit();
    var s = try fixture.open(null);
    defer s.close();

    const csv_path = try fixture.out.join("out.csv");
    defer gpa.free(csv_path);
    try testing.expect(s.exportTo("csv", csv_path));

    const csv = try readFile(a, csv_path);
    // A header plus one line per file across the three groups: 2 + 4 + 2.
    try testing.expectEqual(@as(usize, 9), std.mem.count(u8, csv, "\n"));
    try testing.expect(std.mem.startsWith(u8, csv, "Group Hash,File Path,File Size (bytes),Group Savings (bytes),Modified\n"));

    const json_path = try fixture.out.join("out.json");
    defer gpa.free(json_path);
    try testing.expect(s.exportTo("json", json_path));

    const exported = try std.json.parseFromSliceLeaky(std.json.Value, a, try readFile(a, json_path), .{});
    try testing.expectEqualStrings("duplicates", field(exported, "report_type").string);
    const groups = field(exported, "groups").array.items;
    try testing.expectEqual(@as(usize, 3), groups.len);
    try testing.expectEqual(@as(i64, 4000), int(groups[0], "size"));
    try testing.expectEqual(@as(i64, 2), int(groups[0], "count"));
    try testing.expectEqual(@as(usize, 4), field(groups[2], "files").array.items.len);
    try testing.expectEqual(@as(usize, 64), field(groups[0], "hash").string.len);
    _ = field(field(groups[0], "files").array.items[0], "mtime").string;
    // The scan's own counters, as the desktop exports carry them.
    try testing.expectEqual(@as(i64, 8), int(field(exported, "summary"), "files_scanned"));

    const html_path = try fixture.out.join("out.html");
    defer gpa.free(html_path);
    try testing.expect(s.exportTo("html", html_path));
    const html = try readFile(a, html_path);
    // The column header plus one row per file across the three groups.
    try testing.expectEqual(@as(usize, 1 + 8), std.mem.count(u8, html, "<tr"));
    try testing.expectEqual(@as(usize, 3), std.mem.count(u8, html, "group-header"));
    try testing.expect(std.mem.endsWith(u8, html, "</table>\n</body></html>\n"));

    // An unknown format is refused rather than guessed at.
    const nowhere = try fixture.out.join("out.pdf");
    defer gpa.free(nowhere);
    try testing.expect(!s.exportTo("pdf", nowhere));
    try testing.expect(std.mem.startsWith(u8, s.lastError().?, "unknown export format"));
}

test "export leaves out what was deleted, and escapes a hostile name" {
    const gpa = testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    // A name that breaks naive emission in all three formats at once. No
    // slash: it has to stay one path component.
    const hostile = "evil\" ,\"injected\":1, \\ <script>alert(1)<x>.bin";
    var fixture = try Fixture.init(gpa, "session-export-hostile", &.{});
    defer fixture.deinit();
    const payload = [_]u8{'h'} ** 700;
    try fixture.tree.makeDir("h");
    try fixture.tree.writeFile("h/plain.bin", &payload);
    try fixture.tree.writeFile(try std.fmt.allocPrint(a, "h/{s}", .{hostile}), &payload);
    try fixture.scan();

    var s = try fixture.open(null);
    defer s.close();

    const json_path = try fixture.out.join("hostile.json");
    defer gpa.free(json_path);
    try testing.expect(s.exportTo("json", json_path));

    // The hostile name survives encode -> parse without injecting a field.
    const exported = try std.json.parseFromSliceLeaky(std.json.Value, a, try readFile(a, json_path), .{});
    try testing.expect(exported.object.get("injected") == null);
    const files = field(field(exported, "groups").array.items[0], "files").array.items;
    var found = false;
    for (files) |file| {
        if (std.mem.endsWith(u8, field(file, "path").string, hostile)) found = true;
    }
    try testing.expect(found);

    const csv_path = try fixture.out.join("hostile.csv");
    defer gpa.free(csv_path);
    try testing.expect(s.exportTo("csv", csv_path));
    const csv = try readFile(a, csv_path);
    // The comma and quotes are inside one quoted field, so the row still has
    // five of them: a bare write would have split it.
    try testing.expectEqual(@as(usize, 3), std.mem.count(u8, csv, "\n"));
    try testing.expect(std.mem.indexOf(u8, csv, "\"\"injected\"\"") != null);

    const html_path = try fixture.out.join("hostile.html");
    defer gpa.free(html_path);
    try testing.expect(s.exportTo("html", html_path));
    const html = try readFile(a, html_path);
    try testing.expect(std.mem.indexOf(u8, html, "<script>") == null);
    try testing.expect(std.mem.indexOf(u8, html, "&lt;script&gt;") != null);

    // After a delete the group is down to one copy and drops out entirely.
    _ = try parse(a, s.delete("{\"rule\":{\"filters\":{}}}", false, null, null));
    const after_path = try fixture.out.join("after.json");
    defer gpa.free(after_path);
    try testing.expect(s.exportTo("json", after_path));
    const after = try std.json.parseFromSliceLeaky(std.json.Value, a, try readFile(a, after_path), .{});
    try testing.expectEqual(@as(usize, 0), field(after, "groups").array.items.len);
}

// ===========================================================================
// Helpers
// ===========================================================================

/// A stand-in for the host's Trash: unlinks what it is given and records it,
/// so no test goes near the user's real one. Optionally observes or re-enters
/// the session while the delete holds it.
const FakeTrash = struct {
    gpa: Allocator,
    moved: std.ArrayListUnmanaged([]u8) = .empty,
    /// Progress read from inside the delete, on the first call.
    observe: ?*Session = null,
    seen: session.DeleteProgress = .{ .running = false, .done = 0, .total = 0 },
    /// Session to attempt a nested delete on, once.
    reenter: ?*Session = null,
    reentry_refused: bool = false,
    reentry_message: ?[]const u8 = null,
    calls: usize = 0,

    fn deinit(self: *FakeTrash) void {
        for (self.moved.items) |path| self.gpa.free(path);
        self.moved.deinit(self.gpa);
    }

    fn callback(
        user: ?*anyopaque,
        paths: [*]const [*:0]const u8,
        count: usize,
        err_out: [*]u8,
        err_cap: usize,
    ) callconv(.c) c_int {
        _ = err_cap;
        const self: *FakeTrash = @ptrCast(@alignCast(user.?));
        if (self.calls == 0) {
            if (self.observe) |s| self.seen = s.deleteProgress();
            if (self.reenter) |s| {
                self.reentry_refused = s.delete("{\"rule\":{\"filters\":{}}}", false, null, null) == null;
                self.reentry_message = s.lastError();
            }
        }
        self.calls += 1;

        for (paths[0..count]) |path| {
            if (std.c.unlink(path) != 0) {
                err_out[0] = 0;
                return 1;
            }
            const owned = self.gpa.dupe(u8, std.mem.span(path)) catch return 1;
            self.moved.append(self.gpa, owned) catch {
                self.gpa.free(owned);
                return 1;
            };
        }
        return 0;
    }
};

extern "c" fn utimes(path: [*:0]const u8, times: ?*const [2]std.c.timeval) c_int;

fn setMtime(path: [:0]const u8, seconds: i64) !void {
    const times = [2]std.c.timeval{
        .{ .sec = seconds, .usec = 0 },
        .{ .sec = seconds, .usec = 0 },
    };
    if (utimes(path.ptr, &times) != 0) return error.SetMtimeFailed;
}

fn readFile(arena: Allocator, path: []const u8) ![]u8 {
    const path_z = try arena.dupeZ(u8, path);
    return removed_mod.readWholeFile(arena, path_z.ptr, 16 * 1024 * 1024);
}

/// `<tree>/<dir>/<name>`, in the test's arena rather than the scratch's owner.
fn treePath(arena: Allocator, fixture: *const Fixture, dir: []const u8, name: []const u8) ![]u8 {
    return std.fmt.allocPrint(arena, "{s}/{s}/{s}", .{ fixture.tree.path, dir, name });
}
