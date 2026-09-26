//! End-to-end tests for disk-space scans.
//!
//! The real engine walks a real temp tree through the C entry points a host
//! calls, writes a real store, and the session answers the disk-space queries
//! over it. The Trash is a fake that renames into a scratch bin — no test may
//! touch the user's real Trash.

const std = @import("std");
const lib = @import("lib.zig");
const session = @import("session.zig");
const space = @import("space.zig");
const pstat = @import("pstat.zig");
const Scratch = @import("testing_scratch.zig").Scratch;

const testing = std.testing;
const Allocator = std.mem.Allocator;
const Session = session.Session;
const Value = std.json.Value;

const File = struct { path: []const u8, size: usize };

const tree_files = [_]File{
    .{ .path = "media/big.mov", .size = 300_000 },
    .{ .path = "media/photo.jpg", .size = 50_000 },
    .{ .path = "docs/a.pdf", .size = 20_000 },
    .{ .path = "docs/notes.txt", .size = 1_000 },
    .{ .path = "proj/node_modules/pkg/index.js", .size = 5_000 },
    .{ .path = "proj/node_modules/pkg/logo.png", .size = 7_000 },
    .{ .path = "proj/src/main.zig", .size = 3_000 },
    .{ .path = "Tool.app/Contents/MacOS/Tool", .size = 10_000 },
    .{ .path = "archive.zip", .size = 40_000 },
};

const Fixture = struct {
    gpa: Allocator,
    tree: Scratch,
    out: Scratch,
    store_path: [:0]u8,

    fn init(gpa: Allocator) !Fixture {
        // Scratch trees default to $TMPDIR, which on macOS is under /var — a
        // system tree, where every file would be categorised `system`.
        _ = setenv("TMPDIR", "/tmp", 1);
        var tree = try Scratch.init(gpa, "space");
        errdefer tree.deinit();
        var out = try Scratch.init(gpa, "space-store");
        errdefer out.deinit();
        var self: Fixture = .{ .gpa = gpa, .tree = tree, .out = out, .store_path = try out.joinZ("space.zds") };
        errdefer gpa.free(self.store_path);
        for (tree_files) |file| try self.write(file.path, file.size);
        try self.tree.hardLink("media/big.mov", "media/big-link.mov");
        try self.tree.symLink(".", "loop");
        try self.tree.makeDir("empty");
        return self;
    }

    fn write(self: *Fixture, sub_path: []const u8, size: usize) !void {
        var cut: usize = 0;
        while (std.mem.indexOfScalarPos(u8, sub_path, cut, '/')) |slash| {
            if (!(self.tree.exists(sub_path[0..slash]) catch false)) try self.tree.makeDir(sub_path[0..slash]);
            cut = slash + 1;
        }
        const content = try self.gpa.alloc(u8, size);
        defer self.gpa.free(content);
        @memset(content, 'x');
        try self.tree.writeFile(sub_path, content);
    }

    fn scan(self: *Fixture) !void {
        const ctx = lib.zdedupe_init() orelse return error.ScannerInitFailed;
        defer lib.zdedupe_free(ctx);
        lib.zdedupe_set_mode(ctx, 2);
        // Default excludes would hide node_modules; a disk-space scan ignores them.
        lib.zdedupe_use_default_excludes(ctx, true);
        lib.zdedupe_use_credential_excludes(ctx, true);
        if (lib.zdedupe_add_path(ctx, self.tree.path.ptr) != 0) return error.AddPathFailed;
        if (lib.zdedupe_run_to_file(ctx, self.store_path.ptr) != 0) return error.ScanFailed;
    }

    fn open(self: *Fixture, fresh: bool) !*Session {
        if (!fresh) return Session.open(self.gpa, self.store_path, null);
        const roots = try std.fmt.allocPrint(self.gpa, "[\"{s}\"]", .{self.tree.path});
        defer self.gpa.free(roots);
        return Session.open(self.gpa, self.store_path, roots);
    }

    fn deinit(self: *Fixture) void {
        self.gpa.free(self.store_path);
        self.out.deinit();
        self.tree.deinit();
    }

    /// Bytes on disk of the listed files, as the filesystem reports them now.
    fn diskBytes(self: *Fixture, paths: []const []const u8) !u64 {
        var sum: u64 = 0;
        for (paths) |sub| {
            const full = try self.tree.joinZ(sub);
            defer self.gpa.free(full);
            const st = try pstat.lstat(full.ptr);
            sum += if (st.allocated == 0) st.size else st.allocated;
        }
        return sum;
    }
};

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn rename(old: [*:0]const u8, new: [*:0]const u8) c_int;

fn parse(arena: Allocator, json: ?[:0]const u8) !Value {
    const text = json orelse return error.CallFailed;
    return std.json.parseFromSliceLeaky(Value, arena, text, .{});
}

fn field(v: Value, name: []const u8) Value {
    return v.object.get(name) orelse std.debug.panic("missing field {s}", .{name});
}

fn int(v: Value, name: []const u8) i64 {
    return field(v, name).integer;
}

fn str(v: Value, name: []const u8) []const u8 {
    return field(v, name).string;
}

fn typeEntry(types: Value, name: []const u8) Value {
    for (types.array.items) |entry| {
        if (std.mem.eql(u8, str(entry, "type"), name)) return entry;
    }
    std.debug.panic("no type {s}", .{name});
}

fn findItem(items: Value, name: []const u8) ?Value {
    for (items.array.items) |item| {
        if (std.mem.eql(u8, str(item, "name"), name)) return item;
    }
    return null;
}

const all_files = [_][]const u8{
    "media/big.mov",                  "media/photo.jpg",                "docs/a.pdf",
    "docs/notes.txt",                 "proj/node_modules/pkg/index.js", "proj/node_modules/pkg/logo.png",
    "proj/src/main.zig",              "Tool.app/Contents/MacOS/Tool",   "archive.zip",
};

test "a disk-space scan adds up every file once, by type, with node_modules and bundles classified" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit();
    try fx.scan();
    const s = try fx.open(true);
    defer s.close();

    const overview = try parse(arena, s.spaceOverview());
    // The hard link is counted once; the symlink loop is not followed.
    try testing.expectEqual(@as(i64, 9), int(overview, "files"));
    try testing.expectEqual(@as(i64, 1), int(overview, "hard_links"));
    try testing.expectEqual(@as(i64, @intCast(try fx.diskBytes(&all_files))), int(overview, "bytes"));
    const types = field(overview, "types");
    try testing.expectEqual(@as(i64, 2), int(typeEntry(types, "media"), "files"));
    try testing.expectEqual(@as(i64, 2), int(typeEntry(types, "documents"), "files"));
    // index.js, logo.png (inside node_modules), main.zig.
    try testing.expectEqual(@as(i64, 3), int(typeEntry(types, "code"), "files"));
    try testing.expectEqual(@as(i64, 1), int(typeEntry(types, "applications"), "files"));
    try testing.expectEqual(@as(i64, 1), int(typeEntry(types, "archives"), "files"));
    try testing.expect(field(overview, "volume").object.get("total").?.integer > 0);

    // A duplicate-scan session method still works on a space store.
    try testing.expect(s.overview() != null);
}

test "children come back largest first, capped, with the remainder summed" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit();
    try fx.scan();
    const s = try fx.open(true);
    defer s.close();

    const all = try parse(arena, s.spaceChildren("{\"by\":\"folder\",\"limit\":500}"));
    const node = field(all, "node");
    try testing.expectEqualStrings("dir", str(node, "kind"));
    try testing.expect(field(node, "root").bool);
    const group = field(all, "groups").array.items[0];
    const items = field(group, "items");
    // media, docs, proj, Tool.app, empty, archive.zip.
    try testing.expectEqual(@as(usize, 6), items.array.items.len);
    var previous: i64 = std.math.maxInt(i64);
    var sum: i64 = 0;
    for (items.array.items) |item| {
        try testing.expect(int(item, "bytes") <= previous);
        previous = int(item, "bytes");
        sum += int(item, "bytes");
    }
    try testing.expectEqual(int(node, "bytes"), sum);
    try testing.expectEqualStrings("media", str(items.array.items[0], "name"));
    try testing.expectEqual(@as(i64, 0), int(field(group, "rest"), "count"));

    const capped = try parse(arena, s.spaceChildren("{\"limit\":2}"));
    const capped_group = field(capped, "groups").array.items[0];
    try testing.expectEqual(@as(usize, 2), field(capped_group, "items").array.items.len);
    const rest = field(capped_group, "rest");
    try testing.expectEqual(@as(i64, 4), int(rest, "count"));
    var shown: i64 = 0;
    for (field(capped_group, "items").array.items) |item| shown += int(item, "bytes");
    try testing.expectEqual(int(node, "bytes") - shown, int(rest, "bytes"));

    // Zoom by path; the trail leads back to the root.
    const proj_path = try std.fmt.allocPrint(arena, "{{\"path\":\"{s}/proj\"}}", .{fx.tree.path});
    const proj = try parse(arena, s.spaceChildren(proj_path));
    try testing.expectEqualStrings("proj", str(field(proj, "node"), "name"));
    try testing.expectEqual(@as(usize, 2), field(proj, "trail").array.items.len);
    try testing.expectEqualStrings("code", str(field(proj, "node"), "type"));

    // By type and by size.
    const by_type = try parse(arena, s.spaceChildren("{\"by\":\"type\",\"per_group\":1}"));
    const first_type = field(by_type, "groups").array.items[0];
    try testing.expectEqualStrings("media", str(first_type, "key"));
    try testing.expectEqual(@as(i64, 2), int(first_type, "files"));
    try testing.expectEqual(@as(usize, 1), field(first_type, "items").array.items.len);
    try testing.expectEqual(@as(i64, 1), int(field(first_type, "rest"), "count"));

    const by_size = try parse(arena, s.spaceChildren("{\"by\":\"size\"}"));
    const bands = field(by_size, "groups").array.items;
    try testing.expectEqual(@as(usize, 1), bands.len);
    try testing.expectEqualStrings("under_1m", str(bands[0], "key"));
    try testing.expectEqual(@as(i64, 9), int(bands[0], "files"));

    // Not a folder in these results.
    try testing.expect(s.spaceChildren("{\"path\":\"/definitely/not/scanned\"}") == null);
    try testing.expect(s.spaceChildren("{\"node\":999999}") == null);
}

test "largest files and folders; wrappers left out" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit();
    try fx.scan();
    const s = try fx.open(true);
    defer s.close();

    const files = try parse(arena, s.spaceLargest("{\"kind\":\"files\",\"limit\":3}"));
    const items = field(files, "items").array.items;
    try testing.expectEqual(@as(usize, 3), items.len);
    // Of two hard links the lexicographically smallest path holds the bytes.
    try testing.expectEqualStrings("big-link.mov", str(items[0], "name"));
    try testing.expect(field(items[0], "hard_linked").bool);
    try testing.expect(int(items[0], "mtime") > 0);

    const docs = try parse(arena, s.spaceLargest("{\"kind\":\"files\",\"type\":\"documents\"}"));
    try testing.expectEqual(@as(usize, 2), field(docs, "items").array.items.len);

    const folders = try parse(arena, s.spaceLargest("{\"kind\":\"folders\"}"));
    const found = field(folders, "items");
    try testing.expect(findItem(found, "media") != null);
    try testing.expect(findItem(found, "pkg") != null);
    // node_modules is nothing but pkg.
    try testing.expect(findItem(found, "node_modules") == null);
}

const FakeTrash = struct {
    bin: [:0]const u8,
    moved: usize = 0,

    fn callback(user: ?*anyopaque, paths: [*]const [*:0]const u8, count: usize, err_out: [*]u8, err_cap: usize) callconv(.c) c_int {
        _ = err_cap;
        const self: *FakeTrash = @ptrCast(@alignCast(user.?));
        for (paths[0..count]) |path| {
            var buf: [4096]u8 = undefined;
            const target = std.fmt.bufPrintZ(&buf, "{s}/{d}", .{ self.bin, self.moved }) catch return 1;
            if (rename(path, target.ptr) != 0) {
                err_out[0] = 0;
                return 1;
            }
            self.moved += 1;
        }
        return 0;
    }
};

test "trash: verified, protected roots refused, changes skipped, totals corrected and remembered" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit();
    try fx.scan();
    var bin = try Scratch.init(testing.allocator, "space-bin");
    defer bin.deinit();
    var trash: FakeTrash = .{ .bin = bin.path };

    const s = try fx.open(true);
    var closed = false;
    defer if (!closed) s.close();
    const before = try parse(arena, s.spaceOverview());

    // Ids by name, from the root listing.
    const root = try parse(arena, s.spaceChildren("{\"limit\":500}"));
    const root_id = int(field(root, "node"), "id");
    const items = field(field(root, "groups").array.items[0], "items");
    const proj_id = int(findItem(items, "proj").?, "id");
    const docs = try parse(arena, s.spaceChildren(try std.fmt.allocPrint(arena, "{{\"node\":{d}}}", .{int(findItem(items, "docs").?, "id")})));
    const docs_items = field(field(docs, "groups").array.items[0], "items");
    const pdf_id = int(findItem(docs_items, "a.pdf").?, "id");
    const notes_id = int(findItem(docs_items, "notes.txt").?, "id");

    // notes.txt changes after the scan: it must be skipped, not trashed.
    try fx.write("docs/notes.txt", 1_234);

    const request = try std.fmt.allocPrint(arena,
        \\{{"items":[{{"kind":"dir","id":{d}}},{{"kind":"file","id":{d}}},{{"kind":"dir","id":{d}}},{{"kind":"file","id":{d}}}]}}
    , .{ proj_id, pdf_id, root_id, notes_id });
    const report = try parse(arena, s.spaceTrash(request, FakeTrash.callback, &trash));
    try testing.expectEqual(@as(i64, 2), int(report, "deleted"));
    try testing.expectEqual(@as(i64, 1), int(report, "skipped_changed"));
    try testing.expectEqual(@as(i64, 2), int(report, "failed_count"));
    try testing.expect(!(fx.tree.exists("proj") catch true));
    try testing.expect(!(fx.tree.exists("docs/a.pdf") catch true));
    try testing.expect(fx.tree.exists("docs/notes.txt") catch false);

    const after = try parse(arena, s.spaceOverview());
    // proj held 3 files, plus a.pdf.
    try testing.expectEqual(int(before, "files") - 4, int(after, "files"));
    try testing.expectEqual(@as(i64, 2), int(after, "removed_count"));
    try testing.expect(int(after, "bytes") < int(before, "bytes"));
    try testing.expectEqual(@as(i64, 0), int(typeEntry(field(after, "types"), "code"), "files"));
    const listing = try parse(arena, s.spaceChildren("{\"limit\":500}"));
    try testing.expect(findItem(field(field(listing, "groups").array.items[0], "items"), "proj") == null);
    s.close();
    closed = true;

    // Reopened later, what went stays gone.
    const again = try fx.open(false);
    defer again.close();
    const reopened = try parse(arena, again.spaceOverview());
    try testing.expectEqual(int(after, "files"), int(reopened, "files"));
    try testing.expectEqual(int(after, "bytes"), int(reopened, "bytes"));
}

test "history records each scan once and reports what grew" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit();
    var history_dir = try Scratch.init(testing.allocator, "space-history");
    defer history_dir.deinit();

    try fx.scan();
    {
        const s = try fx.open(true);
        defer s.close();
        const first = try parse(arena, s.spaceHistory(history_dir.path));
        try testing.expectEqual(@as(usize, 1), field(first, "entries").array.items.len);
        try testing.expect(field(first, "previous") == .null);
        // Asking again does not record the same scan twice.
        const same = try parse(arena, s.spaceHistory(history_dir.path));
        try testing.expectEqual(@as(usize, 1), field(same, "entries").array.items.len);
    }

    // Scan times have one-second resolution.
    const pause: std.c.timespec = .{ .sec = 1, .nsec = 100_000_000 };
    _ = std.c.nanosleep(&pause, null);
    try fx.write("media/new.mov", 3 << 20);
    try fx.scan();
    const s = try fx.open(true);
    defer s.close();
    const second = try parse(arena, s.spaceHistory(history_dir.path));
    try testing.expectEqual(@as(usize, 2), field(second, "entries").array.items.len);
    try testing.expect(field(second, "previous") == .integer);
    const growth = field(second, "growth").array.items;
    try testing.expect(growth.len > 0);
    const media_path = try std.fmt.allocPrint(arena, "{s}/media", .{fx.tree.path});
    var found = false;
    for (growth) |change| {
        if (std.mem.eql(u8, str(change, "path"), media_path)) {
            found = true;
            try testing.expect(int(change, "delta") >= 3 << 20);
            try testing.expect(field(change, "id") == .integer);
        }
    }
    try testing.expect(found);
}

test "a duplicate scan's store has no disk-space data, and says so" {
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit();
    const ctx = lib.zdedupe_init() orelse return error.ScannerInitFailed;
    defer lib.zdedupe_free(ctx);
    lib.zdedupe_set_mode(ctx, 0);
    try testing.expectEqual(@as(c_int, 0), lib.zdedupe_add_path(ctx, fx.tree.path.ptr));
    try testing.expectEqual(@as(c_int, 0), lib.zdedupe_run_to_file(ctx, fx.store_path.ptr));
    const s = try fx.open(true);
    defer s.close();
    try testing.expect(s.spaceOverview() == null);
    try testing.expect(std.mem.indexOf(u8, s.lastError().?, "disk-space") != null);
}

test "an unknown mode is ignored rather than trusted" {
    const ctx = lib.zdedupe_init() orelse return error.ScannerInitFailed;
    defer lib.zdedupe_free(ctx);
    lib.zdedupe_set_mode(ctx, 2);
    lib.zdedupe_set_mode(ctx, 77);
    // Still a disk-space context: the JSON entry point refuses it.
    try testing.expect(lib.zdedupe_run_sync(ctx) == null);
}

test "a corrupted folder table is rejected when the store is opened" {
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit();
    try fx.scan();

    const bytes = try readAll(testing.allocator, fx.store_path);
    defer testing.allocator.free(bytes);
    const header = std.mem.bytesToValue(@import("store.zig").Header, bytes[0..256]);
    const blob_at: usize = @intCast(header.space.offset);
    const blob = std.mem.bytesToValue(space.BlobHeader, bytes[blob_at..][0..space.blob_header_size]);
    // Point the first folder's subtree back at itself: a walk would never end.
    const dir0 = blob_at + @as(usize, @intCast(blob.dirs.offset));
    const end_field = dir0 + @offsetOf(space.DirRecord, "subtree_end");
    std.mem.writeInt(u32, bytes[end_field..][0..4], 0, .little);
    try writeAll(fx.store_path, bytes);
    try testing.expectError(error.StoreIsInvalid, fx.open(true));
}

fn readAll(gpa: Allocator, path: [:0]const u8) ![]u8 {
    return @import("removed.zig").readWholeFile(gpa, path.ptr, 64 * 1024 * 1024);
}

fn writeAll(path: [:0]const u8, bytes: []const u8) !void {
    const fd = std.c.open(path.ptr, .{ .ACCMODE = .WRONLY, .TRUNC = true }, @as(std.c.mode_t, 0));
    if (fd < 0) return error.OpenFailed;
    defer _ = std.c.close(fd);
    var written: usize = 0;
    while (written < bytes.len) {
        const n = std.c.write(fd, bytes.ptr + written, bytes.len - written);
        if (n <= 0) return error.WriteFailed;
        written += @intCast(n);
    }
}

test "an unreadable folder marks everything above it incomplete" {
    if (std.c.getuid() == 0) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit();
    try fx.write("docs/locked/secret.bin", 9_000);
    const locked = try fx.tree.joinZ("docs/locked");
    defer testing.allocator.free(locked);
    try testing.expectEqual(@as(c_int, 0), std.c.chmod(locked.ptr, 0));
    defer _ = std.c.chmod(locked.ptr, 0o700);

    try fx.scan();
    const s = try fx.open(true);
    defer s.close();
    const overview = try parse(arena, s.spaceOverview());
    try testing.expect(int(overview, "incomplete_dirs") >= 1);
    try testing.expectEqual(@as(i64, 9), int(overview, "files"));
    const root = try parse(arena, s.spaceChildren("{}"));
    try testing.expect(field(field(root, "node"), "incomplete").bool);
    const docs = findItem(field(field(root, "groups").array.items[0], "items"), "docs").?;
    try testing.expect(field(docs, "incomplete").bool);
    const media = findItem(field(field(root, "groups").array.items[0], "items"), "media").?;
    try testing.expect(!field(media, "incomplete").bool);
}
