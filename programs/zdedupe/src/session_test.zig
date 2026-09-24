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
    /// Roll file identities up into folder identities, so the store carries
    /// the identical sets and overlap pairs the stage B calls page through.
    analyze_dirs: bool = false,

    fn init(gpa: Allocator, label: []const u8, files: []const File) !Fixture {
        return initWith(gpa, label, files, false);
    }

    /// The same, scanned with directory analysis on.
    fn initDirs(gpa: Allocator, label: []const u8, files: []const File) !Fixture {
        return initWith(gpa, label, files, true);
    }

    fn initWith(gpa: Allocator, label: []const u8, files: []const File, analyze_dirs: bool) !Fixture {
        var tree = try Scratch.init(gpa, label);
        errdefer tree.deinit();
        var out = try Scratch.init(gpa, "store");
        errdefer out.deinit();

        var self: Fixture = .{
            .gpa = gpa,
            .tree = tree,
            .out = out,
            .store_path = try out.joinZ("result.zds"),
            .analyze_dirs = analyze_dirs,
        };
        errdefer gpa.free(self.store_path);
        try self.write(files);
        try self.scan();
        return self;
    }

    /// Create `files`, making each one's parent directories as needed.
    fn write(self: *Fixture, files: []const File) !void {
        for (files) |file| {
            var cut: usize = 0;
            while (std.mem.indexOfScalarPos(u8, file.path, cut, '/')) |slash| {
                const dir = file.path[0..slash];
                if (!self.exists(dir)) try self.tree.makeDir(dir);
                cut = slash + 1;
            }
            const content = try self.gpa.alloc(u8, file.size);
            defer self.gpa.free(content);
            @memset(content, file.byte);
            try self.tree.writeFile(file.path, content);
        }
    }

    /// The engine, through the same C entry point a desktop host calls.
    fn scan(self: *Fixture) !void {
        const ctx = lib.zdedupe_init() orelse return error.ScannerInitFailed;
        defer lib.zdedupe_free(ctx);
        lib.zdedupe_set_mode(ctx, 0);
        lib.zdedupe_set_analyze_dirs(ctx, self.analyze_dirs);
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

        // The cap itself is exercised at full size in removed.zig; what
        // matters here is that the session reports an overflowed overlay.
        s.removed.cap = 2;
        try testing.expect(!s.removed.record(&.{ "/f/0", "/f/1", "/f/2" }));

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
    // One banner row per group (the fourth mention of the class is its CSS).
    try testing.expectEqual(@as(usize, 3), std.mem.count(u8, html, "<tr class=\"group-header\">"));
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
// Folders: identical sets
// ===========================================================================

/// Three copies of a small project. `p` and `q` are byte-identical; `big` has
/// one extra file, so it contains them without being a copy. That gives two
/// identical sets — {p, q} and the three `src/util` copies — and one overlap
/// pair, which is the shape `tier1_anchors.zig` already anchors the analyzer
/// against.
fn projectTree(comptime root: []const u8) [3]File {
    return .{
        .{ .path = root ++ "/readme.txt", .byte = 'r', .size = 400 },
        .{ .path = root ++ "/src/main.c", .byte = 'm', .size = 900 },
        .{ .path = root ++ "/src/util/str.c", .byte = 'u', .size = 300 },
    };
}

const folder_tree = projectTree("p") ++ projectTree("q") ++ projectTree("big") ++
    [_]File{.{ .path = "big/src/extra.c", .byte = 'x', .size = 150 }};

fn openDirs(gpa: Allocator, label: []const u8) !struct { Fixture, *Session } {
    var fixture = try Fixture.initDirs(gpa, label, &folder_tree);
    errdefer fixture.deinit();
    const s = try fixture.open(null);
    return .{ fixture, s };
}

test "the overview counts the folder findings the store carries" {
    const gpa = testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    var fixture, const s = try openDirs(gpa, "session-dirs-overview");
    defer fixture.deinit();
    defer s.close();

    const view = try parse(a, s.overview());
    try testing.expect(field(view, "has_directories").bool);
    try testing.expectEqual(@as(i64, 2), int(view, "identical_sets"));
    try testing.expectEqual(@as(i64, 1), int(view, "overlaps"));
    // The one pair is a containment, so it counts as redundant.
    try testing.expectEqual(@as(i64, 1), int(view, "redundant_pairs"));
    try testing.expect(int(view, "reclaimable") > 0);
    try testing.expect(int(view, "dirs_analyzed") > 0);
}

test "identical sets page with their member folders" {
    const gpa = testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    var fixture, const s = try openDirs(gpa, "session-sets");
    defer fixture.deinit();
    defer s.close();

    const page = try parse(a, s.identicalSets("{\"offset\":0,\"limit\":50}"));
    try testing.expectEqual(@as(i64, 2), int(page, "total"));
    try testing.expectEqual(@as(i64, 0), int(page, "offset"));
    const rows = field(page, "rows").array.items;
    try testing.expectEqual(@as(usize, 2), rows.len);

    // Largest reclaimable first: the whole-project set, then the three
    // src/util copies.
    const whole = rows[0];
    try testing.expectEqual(@as(usize, 64), field(whole, "digest").string.len);
    try testing.expectEqual(@as(i64, 2), int(whole, "count"));
    try testing.expectEqual(@as(i64, 3), int(whole, "file_count"));
    try testing.expectEqual(@as(i64, 1600), int(whole, "bytes")); // 400 + 900 + 300
    try testing.expectEqual(@as(i64, 1600), int(whole, "reclaimable"));
    try testing.expectEqualStrings(fixture.tree.path, field(whole, "common_parent").string);

    const dirs = field(whole, "dirs").array.items;
    try testing.expectEqual(@as(usize, 2), dirs.len);
    for (dirs) |dir| {
        _ = int(dir, "skipped_entries");
        try testing.expect(int(dir, "newest_mtime") > 1_500_000_000_000);
    }
    // Sorted by path, so p comes before q.
    try testing.expect(std.mem.endsWith(u8, field(dirs[0], "path").string, "/p"));
    try testing.expect(std.mem.endsWith(u8, field(dirs[1], "path").string, "/q"));

    try testing.expectEqual(@as(i64, 3), int(rows[1], "count"));
    try testing.expect(std.mem.endsWith(u8, field(rows[1], "common_parent").string, fixture.tree.path));

    // The row's index is the handle set_members takes.
    const members = try parse(a, s.setMembers(@intCast(int(whole, "index"))));
    try testing.expectEqual(@as(usize, 2), members.array.items.len);
}

test "set rows cap their member list where set_members does not" {
    const gpa = testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    // Ten identical copies: more than a row carries.
    var files: std.ArrayListUnmanaged(File) = .empty;
    for (0..10) |i| {
        try files.append(a, .{
            .path = try std.fmt.allocPrint(a, "copy{d}/data.bin", .{i}),
            .byte = 'c',
            .size = 700,
        });
    }
    var fixture = try Fixture.initDirs(gpa, "session-set-members", files.items);
    defer fixture.deinit();
    var s = try fixture.open(null);
    defer s.close();

    const page = try parse(a, s.identicalSets("{\"offset\":0,\"limit\":50}"));
    const row = field(page, "rows").array.items[0];
    try testing.expectEqual(@as(i64, 10), int(row, "count"));
    try testing.expectEqual(@as(usize, 8), field(row, "dirs").array.items.len);

    // Uncapped, and every one of them.
    const members = try parse(a, s.setMembers(@intCast(int(row, "index"))));
    try testing.expectEqual(@as(usize, 10), members.array.items.len);
    for (members.array.items) |member| _ = field(member, "path").string;

    // A set that is not there is an error, not a trap.
    try testing.expect(s.setMembers(9999) == null);
    try testing.expectEqualStrings("scan results file is corrupted", s.lastError().?);
}

test "sets page and filter" {
    const gpa = testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    var fixture, const s = try openDirs(gpa, "session-sets-filter");
    defer fixture.deinit();
    defer s.close();

    const second = try parse(a, s.identicalSets("{\"offset\":1,\"limit\":5}"));
    try testing.expectEqual(@as(usize, 1), field(second, "rows").array.items.len);
    try testing.expectEqual(@as(i64, 2), int(second, "total"));
    try testing.expectEqual(@as(i64, 1), int(second, "offset"));
    try testing.expectEqual(@as(i64, 3), int(field(second, "rows").array.items[0], "count"));

    // min_bytes is the size of one copy, so it drops the small src/util set.
    const big = try parse(a, s.identicalSets("{\"offset\":0,\"limit\":50,\"filters\":{\"min_bytes\":1000}}"));
    try testing.expectEqual(@as(i64, 1), int(big, "total"));

    // name matches a member folder, not the set.
    const named = try parse(a, s.identicalSets("{\"offset\":0,\"limit\":50,\"filters\":{\"name\":\"util\"}}"));
    try testing.expectEqual(@as(i64, 1), int(named, "total"));
    try testing.expectEqual(@as(i64, 3), int(field(named, "rows").array.items[0], "count"));

    const nowhere = try parse(a, s.identicalSets("{\"offset\":0,\"limit\":50,\"filters\":{\"text\":\"no-such-path\"}}"));
    try testing.expectEqual(@as(i64, 0), int(nowhere, "total"));
    try testing.expectEqual(@as(usize, 0), field(nowhere, "rows").array.items.len);

    try testing.expect(s.identicalSets("{not json") == null);
    try testing.expectEqualStrings("set query is not valid JSON", s.lastError().?);
}

// ===========================================================================
// Folders: overlaps
// ===========================================================================

test "an overlap pair reports both sides and what only one of them holds" {
    const gpa = testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    var fixture, const s = try openDirs(gpa, "session-overlaps");
    defer fixture.deinit();
    defer s.close();

    const page = try parse(a, s.overlaps("{\"offset\":0,\"limit\":50}"));
    try testing.expectEqual(@as(i64, 1), int(page, "total"));
    const row = field(page, "rows").array.items[0];

    // p and q are identical, so the pair is reported once against the set's
    // first path; big holds everything p does, so p adds nothing.
    try testing.expectEqualStrings("b_in_a", field(row, "relation").string);
    const side_a = field(row, "a");
    const side_b = field(row, "b");
    try testing.expect(std.mem.endsWith(u8, field(side_a, "path").string, "/big"));
    try testing.expect(std.mem.endsWith(u8, field(side_b, "path").string, "/p"));

    // The contained side has nothing of its own; the containing one has extra.c.
    try testing.expectEqual(@as(i64, 0), int(side_b, "only_count"));
    try testing.expectEqual(@as(usize, 0), field(side_b, "only").array.items.len);
    try testing.expectEqual(@as(i64, 1), int(side_a, "only_count"));
    const only = field(side_a, "only").array.items;
    try testing.expectEqual(@as(usize, 1), only.len);
    try testing.expect(std.mem.endsWith(u8, only[0].string, "/big/src/extra.c"));

    for ([_][]const u8{ "files", "bytes", "skipped_entries", "identical_copies", "shared_files", "shared_bytes" }) |name| {
        _ = int(side_a, name);
    }
    try testing.expect(field(side_a, "complete").bool);
    try testing.expect(int(side_a, "newest_mtime") > 1_500_000_000_000);
    // p stands for the whole {p, q} set.
    try testing.expectEqual(@as(i64, 2), int(side_b, "identical_copies"));
    try testing.expectEqual(@as(i64, 3), int(side_b, "shared_files"));
}

test "overlap filters, including redundant_only" {
    const gpa = testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    var fixture, const s = try openDirs(gpa, "session-overlap-filter");
    defer fixture.deinit();
    defer s.close();

    // The one pair is a containment, so "hide pairs where each side has
    // something unique" keeps it.
    const redundant = try parse(a, s.overlaps("{\"offset\":0,\"limit\":50,\"filters\":{\"redundant_only\":true}}"));
    try testing.expectEqual(@as(i64, 1), int(redundant, "total"));

    // min_bytes is the shared size.
    const huge = try parse(a, s.overlaps("{\"offset\":0,\"limit\":50,\"filters\":{\"min_bytes\":999999}}"));
    try testing.expectEqual(@as(i64, 0), int(huge, "total"));

    const named = try parse(a, s.overlaps("{\"offset\":0,\"limit\":50,\"filters\":{\"name\":\"big\"}}"));
    try testing.expectEqual(@as(i64, 1), int(named, "total"));
    const elsewhere = try parse(a, s.overlaps("{\"offset\":0,\"limit\":50,\"filters\":{\"name\":\"nowhere\"}}"));
    try testing.expectEqual(@as(i64, 0), int(elsewhere, "total"));

    try testing.expect(s.overlaps("[]") == null);
    try testing.expectEqualStrings("overlap query is not valid JSON", s.lastError().?);
}

// ===========================================================================
// Facets
// ===========================================================================

test "facets count findings by location, name and type" {
    const gpa = testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    var fixture = try Fixture.init(gpa, "session-facets", &results_tree);
    defer fixture.deinit();
    const roots_json = try query(a, "[{s}]", .{try jsonString(a, fixture.tree.path)});
    var s = try fixture.open(roots_json);
    defer s.close();

    // One scan root, so locations start inside it rather than offering the
    // root as the one and only facet. big.bin (4000 saved) is in Alpha+beta,
    // mid.dat (500) in gamma+delta, small.txt (30) in all four.
    const by_place = try parse(a, s.facets("{\"kind\":\"groups\",\"by\":\"location\",\"limit\":10}"));
    try testing.expectEqualStrings(fixture.tree.path, field(by_place, "base").string);
    try testing.expectEqual(@as(i64, 4), int(by_place, "total"));
    const places = field(by_place, "facets").array.items;
    const expected = [_]struct { dir: []const u8, count: i64, bytes: i64 }{
        .{ .dir = "Alpha", .count = 2, .bytes = 4030 },
        .{ .dir = "beta", .count = 2, .bytes = 4030 },
        .{ .dir = "delta", .count = 2, .bytes = 530 },
        .{ .dir = "gamma", .count = 2, .bytes = 530 },
    };
    try testing.expectEqual(expected.len, places.len);
    for (places, expected) |got, want| {
        const full = try std.fmt.allocPrint(a, "{s}/{s}", .{ fixture.tree.path, want.dir });
        try testing.expectEqualStrings(full, field(got, "key").string);
        try testing.expectEqual(want.count, int(got, "count"));
        try testing.expectEqual(want.bytes, int(got, "bytes"));
    }

    // Drilling into one location narrows what the facets describe.
    const in_alpha = try query(a, "{{\"kind\":\"groups\",\"by\":\"name\",\"limit\":10,\"filters\":{{\"under\":{s}}}}}", .{
        try jsonString(a, try std.fmt.allocPrint(a, "{s}/Alpha", .{fixture.tree.path})),
    });
    const by_name = try parse(a, s.facets(in_alpha));
    const names = field(by_name, "facets").array.items;
    try testing.expectEqual(@as(usize, 2), names.len);
    try testing.expectEqualStrings("big.bin", field(names[0], "key").string);
    try testing.expectEqual(@as(i64, 1), int(names[0], "count"));
    try testing.expectEqualStrings("small.txt", field(names[1], "key").string);

    // By type, largest bytes first, and the extension lower-cased.
    const by_type = try parse(a, s.facets("{\"kind\":\"groups\",\"by\":\"type\",\"limit\":10}"));
    const types = field(by_type, "facets").array.items;
    try testing.expectEqual(@as(usize, 3), types.len);
    try testing.expectEqualStrings(".bin", field(types[0], "key").string);
    try testing.expectEqual(@as(i64, 4000), int(types[0], "bytes"));
    try testing.expectEqualStrings(".dat", field(types[1], "key").string);
    try testing.expectEqualStrings(".txt", field(types[2], "key").string);
    try testing.expectEqual(@as(i64, 30), int(types[2], "bytes"));
    // A location facet is not offered when the question was about types.
    try testing.expectEqual(std.json.Value.null, field(by_type, "base"));

    // A minimum size drops small.txt everywhere, facets included.
    const big_only = try parse(a, s.facets("{\"kind\":\"groups\",\"by\":\"type\",\"limit\":10,\"filters\":{\"min_bytes\":100}}"));
    try testing.expectEqual(@as(usize, 2), field(big_only, "facets").array.items.len);

    // The limit is clamped and `total` still reports what was there.
    const one = try parse(a, s.facets("{\"kind\":\"groups\",\"by\":\"type\",\"limit\":1}"));
    try testing.expectEqual(@as(usize, 1), field(one, "facets").array.items.len);
    try testing.expectEqual(@as(i64, 3), int(one, "total"));

    try testing.expect(s.facets("{\"kind\":\"nope\",\"by\":\"type\",\"limit\":1}") == null);
    try testing.expectEqualStrings("facet query is not valid JSON", s.lastError().?);
}

test "a finding counts once per facet, however many members share it" {
    const gpa = testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    // Two copies of the same file in ONE folder, and a third elsewhere: the
    // group is one finding, counted once in each place, not twice in the first.
    const tree = [_]File{
        .{ .path = "one/a.bin", .byte = 'z', .size = 1000 },
        .{ .path = "one/b.bin", .byte = 'z', .size = 1000 },
        .{ .path = "two/c.bin", .byte = 'z', .size = 1000 },
    };
    var fixture = try Fixture.init(gpa, "session-facet-once", &tree);
    defer fixture.deinit();
    const roots_json = try query(a, "[{s}]", .{try jsonString(a, fixture.tree.path)});
    var s = try fixture.open(roots_json);
    defer s.close();

    const page = try parse(a, s.facets("{\"kind\":\"groups\",\"by\":\"location\",\"limit\":10}"));
    const places = field(page, "facets").array.items;
    try testing.expectEqual(@as(usize, 2), places.len);
    for (places) |place| {
        try testing.expectEqual(@as(i64, 1), int(place, "count"));
        try testing.expectEqual(@as(i64, 2000), int(place, "bytes")); // savings of the group
    }
}

test "facets over folder findings follow the overlay" {
    const gpa = testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    var fixture, const s = try openDirs(gpa, "session-facets-folders");
    defer fixture.deinit();
    defer s.close();

    const by_name = try parse(a, s.facets("{\"kind\":\"sets\",\"by\":\"name\",\"limit\":10}"));
    const names = field(by_name, "facets").array.items;
    // The {p, q} set contributes "p" and "q"; the src/util set contributes
    // "util" once, for all three of its members.
    try testing.expectEqual(@as(usize, 3), names.len);
    for (names) |name| try testing.expectEqual(@as(i64, 1), int(name, "count"));

    const overlaps_by_name = try parse(a, s.facets("{\"kind\":\"overlaps\",\"by\":\"name\",\"limit\":10}"));
    try testing.expectEqual(@as(usize, 2), field(overlaps_by_name, "facets").array.items.len);

    // Take q out from under them: the {p, q} set stops being a finding, so
    // neither name is attributed any more.
    const q = try fixture.path("q");
    defer gpa.free(q);
    _ = s.removed.record(&.{q});

    const after = try parse(a, s.facets("{\"kind\":\"sets\",\"by\":\"name\",\"limit\":10}"));
    const left = field(after, "facets").array.items;
    try testing.expectEqual(@as(usize, 1), left.len);
    try testing.expectEqualStrings("util", field(left[0], "key").string);
    try testing.expectEqual(@as(i64, 1), int(left[0], "count"));
}

test "the overlay drops set members, whole sets and overlap pairs" {
    const gpa = testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    var fixture, const s = try openDirs(gpa, "session-folder-overlay");
    defer fixture.deinit();
    defer s.close();

    const q = try fixture.path("q");
    defer gpa.free(q);
    _ = s.removed.record(&.{q});

    // {p, q} is down to one copy and is no longer a set; the src/util set
    // loses q's copy and keeps two — a deleted folder takes its contents.
    const sets = try parse(a, s.identicalSets("{\"offset\":0,\"limit\":50}"));
    try testing.expectEqual(@as(i64, 1), int(sets, "total"));
    const row = field(sets, "rows").array.items[0];
    try testing.expectEqual(@as(i64, 2), int(row, "count"));
    for (field(row, "dirs").array.items) |dir| {
        try testing.expect(std.mem.indexOf(u8, field(dir, "path").string, "/q/") == null);
    }

    // The pair named p, which survives, so it still stands.
    try testing.expectEqual(@as(i64, 1), int(try parse(a, s.overlaps("{\"offset\":0,\"limit\":50}")), "total"));

    // Take the other side and the pair says nothing at all.
    const big = try fixture.path("big");
    defer gpa.free(big);
    _ = s.removed.record(&.{big});
    try testing.expectEqual(@as(i64, 0), int(try parse(a, s.overlaps("{\"offset\":0,\"limit\":50}")), "total"));
}

// ===========================================================================
// Folder deletes
// ===========================================================================

test "a folder goes only if it is identical to a surviving copy right now" {
    const gpa = testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    var fixture, const s = try openDirs(gpa, "session-folder-verify");
    defer fixture.deinit();
    defer s.close();

    // A fourth copy that differs by one byte, in a hidden file the scan's
    // size window could have skipped.
    try fixture.write(&projectTree("drifted"));
    try fixture.tree.writeFile("p/.env", "KEY=aaaa\n");
    try fixture.tree.writeFile("q/.env", "KEY=aaaa\n");
    try fixture.tree.writeFile("drifted/.env", "KEY=bbbb\n");

    const items = try query(a, "[{{\"path\":{s},\"keepers\":[{s}],\"bytes\":1600}}," ++
        "{{\"path\":{s},\"keepers\":[{s}],\"bytes\":1600}}]", .{
        try jsonString(a, try treeJoin(a, &fixture, "q")),
        try jsonString(a, try treeJoin(a, &fixture, "p")),
        try jsonString(a, try treeJoin(a, &fixture, "drifted")),
        try jsonString(a, try treeJoin(a, &fixture, "p")),
    });
    const report = try parse(a, s.deleteFolders(items, false, null, null));

    try testing.expect(!fixture.exists("q"));
    try testing.expect(fixture.exists("drifted")); // differs in a hidden file
    try testing.expect(fixture.exists("p"));
    try testing.expectEqual(@as(i64, 1), int(report, "deleted"));
    try testing.expectEqual(@as(i64, 1600), int(report, "freed_bytes"));
    try testing.expectEqual(@as(i64, 1), int(report, "failed_count"));
    try testing.expectEqual(@as(i64, 1), int(report, "skipped_changed"));

    const failed = field(report, "failed").array.items;
    try testing.expect(std.mem.startsWith(u8, failed[0].array.items[1].string, "no longer identical"));

    // The whole subtree went, not just its top level.
    try testing.expect(!fixture.exists("q/src/util/str.c"));
    // And the results stop listing it without a rescan.
    try testing.expectEqual(@as(i64, 1), int(try parse(a, s.removedStatus()), "count"));
    try testing.expectEqual(@as(i64, 1), int(try parse(a, s.identicalSets("{\"offset\":0,\"limit\":50}")), "total"));
}

test "a keeper that is itself being deleted vouches for nothing" {
    const gpa = testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    var fixture, const s = try openDirs(gpa, "session-folder-mutual");
    defer fixture.deinit();
    defer s.close();

    // Each names the other as its surviving copy.
    const items = try query(a, "[{{\"path\":{s},\"keepers\":[{s}]}},{{\"path\":{s},\"keepers\":[{s}]}}]", .{
        try jsonString(a, try treeJoin(a, &fixture, "q")),
        try jsonString(a, try treeJoin(a, &fixture, "p")),
        try jsonString(a, try treeJoin(a, &fixture, "p")),
        try jsonString(a, try treeJoin(a, &fixture, "q")),
    });
    const report = try parse(a, s.deleteFolders(items, false, null, null));

    try testing.expect(fixture.exists("p") and fixture.exists("q"));
    try testing.expectEqual(@as(i64, 0), int(report, "deleted"));
    try testing.expectEqual(@as(i64, 2), int(report, "skipped_changed"));
}

test "links, relative paths and missing keepers are refused" {
    const gpa = testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    var fixture, const s = try openDirs(gpa, "session-folder-refuse");
    defer fixture.deinit();
    defer s.close();

    try fixture.tree.symLink("q", "alias");

    const items = try query(a,
        \\[{{"path":{s},"keepers":[{s}]}},
        \\ {{"path":{s},"keepers":[]}},
        \\ {{"path":"relative/path","keepers":["/x"]}},
        \\ {{"path":"/","keepers":["/x"]}},
        \\ {{"path":{s},"keepers":[{s}]}}]
    , .{
        try jsonString(a, try treeJoin(a, &fixture, "alias")),
        try jsonString(a, try treeJoin(a, &fixture, "p")),
        try jsonString(a, try treeJoin(a, &fixture, "q")),
        try jsonString(a, try treeJoin(a, &fixture, "gone")),
        try jsonString(a, try treeJoin(a, &fixture, "p")),
    });
    const report = try parse(a, s.deleteFolders(items, false, null, null));

    try testing.expectEqual(@as(i64, 0), int(report, "deleted"));
    try testing.expectEqual(@as(i64, 5), int(report, "failed_count"));
    try testing.expect(fixture.exists("q") and fixture.exists("alias") and fixture.exists("p"));

    const reasons = field(report, "failed").array.items;
    try testing.expectEqualStrings("not a real folder (a link or a file)", reasons[0].array.items[1].string);
    try testing.expectEqualStrings("no surviving copy was named", reasons[1].array.items[1].string);
    try testing.expectEqualStrings("not an absolute folder path", reasons[2].array.items[1].string);
    try testing.expectEqualStrings("is, or holds, a protected location", reasons[3].array.items[1].string);
    try testing.expectEqualStrings("cannot be read", reasons[4].array.items[1].string);
}

test "folders go to the Trash through the host, without a content check" {
    const gpa = testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    var fixture, const s = try openDirs(gpa, "session-folder-trash");
    defer fixture.deinit();
    defer s.close();

    // Drifted on purpose: the Trash is recoverable, so the UI's selection
    // rules are the safeguard and no comparison is made.
    try fixture.write(&projectTree("drifted"));
    try fixture.tree.writeFile("drifted/extra-file.txt", "not in any other copy\n");
    try fixture.tree.symLink("p", "alias");

    const bin = try fixture.out.join("bin");
    defer gpa.free(bin);
    try fixture.out.makeDir("bin");
    var trash: FakeTrash = .{ .gpa = gpa, .bin = bin };
    defer trash.deinit();

    const items = try query(a, "[{{\"path\":{s},\"bytes\":1750}},{{\"path\":{s}}}]", .{
        try jsonString(a, try treeJoin(a, &fixture, "drifted")),
        try jsonString(a, try treeJoin(a, &fixture, "alias")),
    });
    const report = try parse(a, s.deleteFolders(items, true, FakeTrash.callback, &trash));

    try testing.expect(!fixture.exists("drifted"));
    try testing.expectEqual(@as(i64, 1), int(report, "deleted"));
    try testing.expectEqual(@as(i64, 1750), int(report, "freed_bytes"));
    // A symlink to a folder is still refused: removing "it" is not what the
    // user picked.
    try testing.expect(fixture.exists("alias"));
    try testing.expectEqual(@as(i64, 1), int(report, "failed_count"));
    try testing.expectEqualStrings(
        "not a real folder (a link or a file)",
        field(report, "failed").array.items[0].array.items[1].string,
    );
    try testing.expectEqual(@as(usize, 1), trash.moved.items.len);
}

test "a folder delete reports progress, cancels, and refuses to overlap another" {
    const gpa = testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    var fixture, const s = try openDirs(gpa, "session-folder-progress");
    defer fixture.deinit();
    defer s.close();

    const items = try query(a, "[{{\"path\":{s},\"keepers\":[{s}]}}]", .{
        try jsonString(a, try treeJoin(a, &fixture, "q")),
        try jsonString(a, try treeJoin(a, &fixture, "p")),
    });

    // Cancelled before it starts, so nothing is touched.
    s.cancelDelete();
    const cancelled = try parse(a, s.deleteFolders(items, false, null, null));
    try testing.expect(field(cancelled, "cancelled").bool);
    try testing.expectEqual(@as(i64, 0), int(cancelled, "deleted"));
    try testing.expect(fixture.exists("q"));

    // And the cancel does not carry into the next one.
    const bin = try fixture.out.join("bin2");
    defer gpa.free(bin);
    try fixture.out.makeDir("bin2");
    var trash: FakeTrash = .{ .gpa = gpa, .bin = bin, .observe = s, .reenter = s };
    defer trash.deinit();

    const report = try parse(a, s.deleteFolders(items, true, FakeTrash.callback, &trash));
    try testing.expect(!field(report, "cancelled").bool);
    try testing.expectEqual(@as(i64, 1), int(report, "deleted"));

    // The whole plan was on the progress before anything moved, and a second
    // delete arriving mid-flight is refused rather than allowed to disturb it.
    try testing.expect(trash.seen.running);
    try testing.expectEqual(@as(u64, 1), trash.seen.total);
    try testing.expect(trash.reentry_refused);
    try testing.expectEqualStrings("A delete is already running", trash.reentry_message.?);

    const done = s.deleteProgress();
    try testing.expect(!done.running);
    try testing.expectEqual(@as(u64, 1), done.done);
}

test "a folder delete asking for the Trash without a callback is refused" {
    const gpa = testing.allocator;
    var fixture, const s = try openDirs(gpa, "session-folder-no-trash");
    defer fixture.deinit();
    defer s.close();

    try testing.expect(s.deleteFolders("[]", true, null, null) == null);
    try testing.expectEqualStrings("no Trash callback was provided", s.lastError().?);
    try testing.expect(s.deleteFolders("{not json", false, null, null) == null);
    try testing.expectEqualStrings("folder list is not valid JSON", s.lastError().?);
    try testing.expect(fixture.exists("p"));
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
    /// A directory to rename entries into. A real Trash moves rather than
    /// erases, and a rename is the only thing that works for a folder as well
    /// as a file. Null falls back to unlinking, which suits the file tests.
    bin: ?[]const u8 = null,
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
            if (!self.take(path)) {
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

    fn take(self: *FakeTrash, path: [*:0]const u8) bool {
        const bin = self.bin orelse return std.c.unlink(path) == 0;
        const target = std.fmt.allocPrintSentinel(
            self.gpa,
            "{s}/{d}",
            .{ bin, self.moved.items.len },
            0,
        ) catch return false;
        defer self.gpa.free(target);
        return rename(path, target.ptr) == 0;
    }
};

extern "c" fn rename(old: [*:0]const u8, new: [*:0]const u8) c_int;

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

/// `<tree>/<sub_path>`, likewise.
fn treeJoin(arena: Allocator, fixture: *const Fixture, sub_path: []const u8) ![]u8 {
    return std.fmt.allocPrint(arena, "{s}/{s}", .{ fixture.tree.path, sub_path });
}

// ===========================================================================
// Keep rules and protected locations
// ===========================================================================

/// Downloads holds a copy of everything; each file also lives where it belongs.
const keep_tree = [_]File{
    .{ .path = "Downloads/report.pdf", .byte = 'r', .size = 2000 },
    .{ .path = "Documents/report.pdf", .byte = 'r', .size = 2000 },
    .{ .path = "Downloads/photo.jpg", .byte = 'p', .size = 1000 },
    .{ .path = "Downloads/x/photo.jpg", .byte = 'p', .size = 1000 },
    .{ .path = "Pictures/photo.jpg", .byte = 'p', .size = 1000 },
    .{ .path = "vault/master.wav", .byte = 'w', .size = 800 },
    .{ .path = "Downloads/master.wav", .byte = 'w', .size = 800 },
};

fn rowOfSize(page: std.json.Value, size: i64) ?std.json.Value {
    for (field(page, "rows").array.items) |row| {
        if (int(row, "size") == size) return row;
    }
    return null;
}

test "rows say which copy the keep rule keeps and which it would delete" {
    const gpa = testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    var fixture = try Fixture.init(gpa, "session-keep-rows", &keep_tree);
    defer fixture.deinit();
    var s = try fixture.open(null);
    defer s.close();

    const q = try query(a, "{{\"keep\":{{\"prefer_under\":[{s}]}}}}", .{
        try jsonString(a, try treeJoin(a, &fixture, "Documents")),
    });
    const row = rowOfSize(try parse(a, s.groups(q)), 2000).?;
    try testing.expectEqualStrings(try treeJoin(a, &fixture, "Documents/report.pdf"), field(row, "keeper").string);

    const files = field(row, "files").array.items;
    const targets = field(row, "targets").array.items;
    const locked = field(row, "locked").array.items;
    try testing.expectEqual(files.len, targets.len);
    for (files, targets, locked) |file, target, lock| {
        try testing.expectEqual(std.mem.indexOf(u8, file.string, "/Downloads/") != null, target.bool);
        try testing.expect(!lock.bool);
    }
}

test "a rule per type keeps photos in Pictures, whatever their age" {
    const gpa = testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    var fixture = try Fixture.init(gpa, "session-keep-type", &keep_tree);
    defer fixture.deinit();
    var s = try fixture.open(null);
    defer s.close();

    const selection = try query(a,
        \\{{"rule":{{"filters":{{}},"keep":{{"by_type":[{{"ext":".jpg","prefer_under":[{s}]}}]}}}}}}
    , .{try jsonString(a, try treeJoin(a, &fixture, "Pictures"))});
    const report = try parse(a, s.delete(selection, false, null, null));
    try testing.expectEqual(@as(i64, 0), int(report, "failed_count"));

    try testing.expect(fixture.exists("Pictures/photo.jpg"));
    try testing.expect(!fixture.exists("Downloads/photo.jpg"));
    try testing.expect(!fixture.exists("Downloads/x/photo.jpg"));
    // The other types fell back to one copy each, as before.
    try testing.expectEqual(@as(usize, 1), @as(usize, @intFromBool(fixture.exists("Downloads/report.pdf"))) +
        @intFromBool(fixture.exists("Documents/report.pdf")));
}

test "a pinned copy is the one that stays" {
    const gpa = testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    var fixture = try Fixture.init(gpa, "session-keep-pin", &keep_tree);
    defer fixture.deinit();
    var s = try fixture.open(null);
    defer s.close();

    const hash = field(rowOfSize(try parse(a, s.groups("{}")), 1000).?, "hash").string;
    const pinned = try treeJoin(a, &fixture, "Downloads/x/photo.jpg");
    const selection = try query(a,
        \\{{"rule":{{"filters":{{"name":"photo.jpg"}},"keep":{{"pins":[{{"hash":"{s}","path":{s}}}]}}}}}}
    , .{ hash, try jsonString(a, pinned) });
    const report = try parse(a, s.delete(selection, false, null, null));
    try testing.expectEqual(@as(i64, 2), int(report, "deleted"));
    try testing.expect(fixture.exists("Downloads/x/photo.jpg"));
    try testing.expect(!fixture.exists("Pictures/photo.jpg"));
}

test "delete_only_under empties a folder of what exists elsewhere" {
    const gpa = testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    var fixture = try Fixture.init(gpa, "session-keep-only-under", &keep_tree);
    defer fixture.deinit();
    var s = try fixture.open(null);
    defer s.close();

    const selection = try query(a, "{{\"rule\":{{\"filters\":{{}},\"keep\":{{\"delete_only_under\":[{s}]}}}}}}", .{
        try jsonString(a, try treeJoin(a, &fixture, "Downloads")),
    });
    const report = try parse(a, s.delete(selection, false, null, null));
    try testing.expectEqual(@as(i64, 4), int(report, "deleted"));
    for ([_][]const u8{ "Downloads/report.pdf", "Downloads/photo.jpg", "Downloads/x/photo.jpg", "Downloads/master.wav" }) |gone| {
        try testing.expect(!fixture.exists(gone));
    }
    for ([_][]const u8{ "Documents/report.pdf", "Pictures/photo.jpg", "vault/master.wav" }) |kept| {
        try testing.expect(fixture.exists(kept));
    }
}

test "a protected copy is never deleted, by a rule or by hand" {
    const gpa = testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    var fixture = try Fixture.init(gpa, "session-protected", &keep_tree);
    defer fixture.deinit();
    var s = try fixture.open(null);
    defer s.close();

    const vault = try treeJoin(a, &fixture, "vault");
    try testing.expect(s.setProtected(try query(a, "[{s}]", .{try jsonString(a, vault)})));

    const row = rowOfSize(try parse(a, s.groups("{\"filters\":{\"name\":\"master.wav\"}}")), 800).?;
    const files = field(row, "files").array.items;
    const locked = field(row, "locked").array.items;
    const targets = field(row, "targets").array.items;
    for (files, locked, targets) |file, lock, target| {
        const in_vault = std.mem.startsWith(u8, file.string, vault);
        try testing.expectEqual(in_vault, lock.bool);
        // The vault copy is protected and the other is the one kept: nothing
        // is marked, because a system copy does not make an ordinary one
        // expendable.
        try testing.expect(!target.bool);
    }

    // Hand-ticked, it is refused and stays.
    const master = try treeJoin(a, &fixture, "vault/master.wav");
    const by_hand = try parse(a, s.delete(try query(a, "{{\"rule\":null,\"extra\":[{s}]}}", .{try jsonString(a, master)}), false, null, null));
    try testing.expectEqual(@as(i64, 0), int(by_hand, "deleted"));
    try testing.expectEqualStrings("is in a protected location", field(by_hand, "failed").array.items[0].array.items[1].string);
    try testing.expect(fixture.exists("vault/master.wav"));

    // Cleaning Downloads: here the protected copy is the survivor.
    const clean = try parse(a, s.delete(try query(a, "{{\"rule\":{{\"filters\":{{\"name\":\"master.wav\"}},\"keep\":{{\"delete_only_under\":[{s}]}}}}}}", .{
        try jsonString(a, try treeJoin(a, &fixture, "Downloads")),
    }), false, null, null));
    try testing.expectEqual(@as(i64, 1), int(clean, "deleted"));
    try testing.expect(fixture.exists("vault/master.wav"));
    try testing.expect(!fixture.exists("Downloads/master.wav"));

    const listed = try parse(a, s.protectedJson());
    try testing.expectEqualStrings(vault, field(listed, "user").array.items[0].string);
    try testing.expect(field(listed, "system").array.items.len > 0);
}

test "the plan says how much goes, and from where" {
    const gpa = testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    var fixture = try Fixture.init(gpa, "session-plan", &keep_tree);
    defer fixture.deinit();
    const roots_json = try query(a, "[{s}]", .{try jsonString(a, fixture.tree.path)});
    var s = try fixture.open(roots_json);
    defer s.close();
    try testing.expect(s.setProtected(try query(a, "[{s}]", .{try jsonString(a, try treeJoin(a, &fixture, "vault"))})));

    const downloads = try treeJoin(a, &fixture, "Downloads");
    const plan = try parse(a, s.bulkPlan(try query(a, "{{\"filters\":{{}},\"keep\":{{\"delete_only_under\":[{s}]}},\"excluded\":[{s}]}}", .{
        try jsonString(a, downloads),
        try jsonString(a, try treeJoin(a, &fixture, "Downloads/x/photo.jpg")),
    })));
    // report.pdf, photo.jpg and master.wav from Downloads; the unticked copy stays.
    try testing.expectEqual(@as(i64, 3), int(plan, "files"));
    try testing.expectEqual(@as(i64, 2000 + 1000 + 800), int(plan, "bytes"));
    try testing.expectEqual(@as(i64, 3), int(plan, "groups"));
    try testing.expectEqual(@as(i64, 1), int(plan, "locked"));
    try testing.expectEqual(@as(i64, 0), int(plan, "untouched"));

    const from = field(plan, "from");
    try testing.expectEqualStrings(fixture.tree.path, field(from, "base").string);
    const facets = field(from, "facets").array.items;
    try testing.expectEqual(@as(usize, 1), facets.len);
    try testing.expectEqualStrings(downloads, field(facets[0], "key").string);
    try testing.expectEqual(@as(i64, 3), int(facets[0], "count"));

    // A bare filters object is not a plan query.
    try testing.expect(s.bulkPlan("{\"text\":\"x\"}") == null);
}

test "a folder that is, or holds, a protected location is not deleted" {
    const gpa = testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    var fixture = try Fixture.init(gpa, "session-protected-folders", &keep_tree);
    defer fixture.deinit();
    var s = try fixture.open(null);
    defer s.close();
    try testing.expect(s.setProtected(try query(a, "[{s}]", .{try jsonString(a, try treeJoin(a, &fixture, "vault"))})));

    var trash: FakeTrash = .{ .gpa = gpa };
    defer trash.deinit();
    const items = try query(a, "[{{\"path\":{s},\"keepers\":[]}},{{\"path\":{s},\"keepers\":[]}}]", .{
        try jsonString(a, try treeJoin(a, &fixture, "vault")),
        try jsonString(a, fixture.tree.path),
    });
    const report = try parse(a, s.deleteFolders(items, true, FakeTrash.callback, &trash));
    try testing.expectEqual(@as(i64, 0), int(report, "deleted"));
    try testing.expectEqual(@as(i64, 2), int(report, "failed_count"));
    try testing.expect(fixture.exists("vault/master.wav"));
}

test "credential stores and shell history are never read" {
    const gpa = testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    // Each secret is duplicated, so reading it would put it in a group.
    const tree = [_]File{
        .{ .path = "u1/.codex/auth.json", .byte = 'c', .size = 100 },
        .{ .path = "u2/.codex/auth.json", .byte = 'c', .size = 100 },
        .{ .path = "u1/.claude/.credentials.json", .byte = 'k', .size = 100 },
        .{ .path = "u2/.claude/.credentials.json", .byte = 'k', .size = 100 },
        .{ .path = "u1/.claude.json", .byte = 'j', .size = 100 },
        .{ .path = "u2/.claude.json", .byte = 'j', .size = 100 },
        .{ .path = "u1/.gemini/oauth_creds.json", .byte = 'g', .size = 100 },
        .{ .path = "u2/.gemini/oauth_creds.json", .byte = 'g', .size = 100 },
        .{ .path = "u1/.zsh_history", .byte = 'z', .size = 100 },
        .{ .path = "u2/.zsh_history", .byte = 'z', .size = 100 },
        .{ .path = "u1/.bash_history", .byte = 'b', .size = 100 },
        .{ .path = "u2/.bash_history", .byte = 'b', .size = 100 },
        .{ .path = "u1/notes.txt", .byte = 'n', .size = 100 },
        .{ .path = "u2/notes.txt", .byte = 'n', .size = 100 },
    };
    var fixture = try Fixture.init(gpa, "session-credentials", &tree);
    defer fixture.deinit();

    // Rescan the same tree the way a desktop host does with the toggle on.
    const ctx = lib.zdedupe_init() orelse return error.ScannerInitFailed;
    defer lib.zdedupe_free(ctx);
    lib.zdedupe_set_mode(ctx, 0);
    lib.zdedupe_set_include_hidden(ctx, true);
    lib.zdedupe_use_credential_excludes(ctx, true);
    const root = try a.dupeZ(u8, fixture.tree.path);
    try testing.expectEqual(@as(c_int, 0), lib.zdedupe_add_path(ctx, root.ptr));
    try testing.expectEqual(@as(c_int, 0), lib.zdedupe_run_to_file(ctx, fixture.store_path.ptr));

    var s = try fixture.open(null);
    defer s.close();
    const rows = field(try parse(a, s.groups("{}")), "rows").array.items;
    // Only notes.txt is left to find.
    try testing.expectEqual(@as(usize, 1), rows.len);
    for (field(rows[0], "files").array.items) |f| {
        try testing.expect(std.mem.endsWith(u8, f.string, "/notes.txt"));
    }
}

test "folders in a protected location come back locked" {
    const gpa = testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    var fixture, const s = try openDirs(gpa, "session-folder-locked");
    defer fixture.deinit();
    defer s.close();

    const page = try parse(a, s.identicalSets("{\"offset\":0,\"limit\":10}"));
    const dirs = field(field(page, "rows").array.items[0], "dirs").array.items;
    for (dirs) |d| try testing.expect(!field(d, "locked").bool);

    // Protect the first copy's folder: it, and only it, is now locked.
    const first = field(dirs[0], "path").string;
    try testing.expect(s.setProtected(try query(a, "[{s}]", .{try jsonString(a, first)})));
    const again = try parse(a, s.identicalSets("{\"offset\":0,\"limit\":10}"));
    for (field(field(again, "rows").array.items[0], "dirs").array.items) |d| {
        try testing.expectEqual(std.mem.eql(u8, field(d, "path").string, first), field(d, "locked").bool);
    }
    const members = try parse(a, s.setMembers(0));
    for (members.array.items) |d| {
        try testing.expectEqual(std.mem.eql(u8, field(d, "path").string, first), field(d, "locked").bool);
    }
}

test "the protected home is the user's real one, not $HOME" {
    // A sandboxed Mac app runs with $HOME set to its container; the user
    // database still names the real home, and that is what gets protected.
    const gpa = testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    const pw = std.c.getpwuid(std.c.getuid()) orelse return error.SkipZigTest;
    const real = std.mem.trimEnd(u8, std.mem.span(pw.dir orelse return error.SkipZigTest), "/");

    var fixture = try Fixture.init(gpa, "session-real-home", &keep_tree);
    defer fixture.deinit();

    // What the sandbox does: $HOME names somewhere that is not the home.
    const saved = std.c.getenv("HOME");
    const saved_copy: ?[:0]u8 = if (saved) |h| try gpa.dupeZ(u8, std.mem.span(h)) else null;
    defer if (saved_copy) |h| gpa.free(h);
    _ = setenv("HOME", "/private/tmp/zdedupe-container-home", 1);
    defer {
        if (saved_copy) |h| _ = setenv("HOME", h.ptr, 1) else _ = unsetenv("HOME");
    }

    var s = try fixture.open(null);
    defer s.close();

    const listed = try parse(a, s.protectedJson());
    const homes = field(listed, "home").array.items;
    try testing.expect(homes.len > 0);
    try testing.expectEqualStrings(try query(a, "{s}/Library", .{real}), homes[0].string);
}

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

test "a host can say where home is, and only home moves" {
    const gpa = testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    var fixture = try Fixture.init(gpa, "session-set-home", &keep_tree);
    defer fixture.deinit();
    var s = try fixture.open(null);
    defer s.close();

    try testing.expect(s.setHome("/somewhere/else/"));
    const listed = try parse(a, s.protectedJson());
    try testing.expectEqualStrings("/somewhere/else/Library", field(listed, "home").array.items[0].string);
    try testing.expect(field(listed, "system").array.items.len > 0);
    try testing.expect(!s.setHome("relative"));
}

test "identical sets sort by reclaim, by size or by copies" {
    const gpa = testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    // Small folder in three copies (frees 2 x 100), big one in two (frees 500).
    const tree = [_]File{
        .{ .path = "small1/f.bin", .byte = 's', .size = 100 },
        .{ .path = "small2/f.bin", .byte = 's', .size = 100 },
        .{ .path = "small3/f.bin", .byte = 's', .size = 100 },
        .{ .path = "big1/g.bin", .byte = 'b', .size = 500 },
        .{ .path = "big2/g.bin", .byte = 'b', .size = 500 },
    };
    var fixture = try Fixture.initDirs(gpa, "session-set-sort", &tree);
    defer fixture.deinit();
    var s = try fixture.open(null);
    defer s.close();

    const Case = struct { sort: []const u8, counts: [2]i64 };
    for ([_]Case{
        .{ .sort = "reclaim", .counts = .{ 2, 3 } },
        .{ .sort = "size", .counts = .{ 2, 3 } },
        .{ .sort = "count", .counts = .{ 3, 2 } },
    }) |c| {
        const page = try parse(a, s.identicalSets(try query(a, "{{\"offset\":0,\"limit\":10,\"sort\":\"{s}\"}}", .{c.sort})));
        const rows = field(page, "rows").array.items;
        try testing.expectEqual(@as(usize, 2), rows.len);
        try testing.expectEqual(c.counts[0], int(rows[0], "count"));
        try testing.expectEqual(c.counts[1], int(rows[1], "count"));
    }
}
