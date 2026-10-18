//! End-to-end tests for disk-space scans.
//!
//! The real engine walks a real temp tree through the C entry points a host
//! calls, writes a real store, and the session answers the disk-space queries
//! over it. The Trash is a fake that renames into a scratch bin — no test may
//! touch the user's real Trash.

const std = @import("std");
/// The platform C library (std.c on Linux and macOS; see sys.zig).
const sysc = @import("sys.zig").c;
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
        return initIn(gpa, false);
    }

    /// `temp`: the tree in the operating system's temporary folder (on macOS
    /// /private/tmp, a temp area inside the protected /private tree), not
    /// where test fixtures normally live.
    fn initIn(gpa: Allocator, temp: bool) !Fixture {
        if (temp and @import("builtin").os.tag != .windows) _ = setenv("TMPDIR", "/tmp", 1);
        var tree = if (temp) try Scratch.initTemp(gpa, "space") else try Scratch.init(gpa, "space");
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
        return self.scanAt(self.tree.path);
    }

    /// Scan the tree as `root` spells it (its real path, say).
    fn scanAt(self: *Fixture, root: [:0]const u8) !void {
        const ctx = lib.zdedupe_init() orelse return error.ScannerInitFailed;
        defer lib.zdedupe_free(ctx);
        lib.zdedupe_set_mode(ctx, 2);
        // Default excludes would hide node_modules; a disk-space scan ignores them.
        lib.zdedupe_use_default_excludes(ctx, true);
        lib.zdedupe_use_credential_excludes(ctx, true);
        if (lib.zdedupe_add_path(ctx, root.ptr) != 0) return error.AddPathFailed;
        if (lib.zdedupe_run_to_file(ctx, self.store_path.ptr) != 0) return error.ScanFailed;
    }

    fn open(self: *Fixture, fresh: bool) !*Session {
        if (!fresh) return Session.open(self.gpa, self.store_path, null);
        return self.openAt(self.tree.path);
    }

    fn openAt(self: *Fixture, root: []const u8) !*Session {
        const roots = try std.fmt.allocPrint(self.gpa, "[\"{s}\"]", .{root});
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

// Windows: the platform layer; elsewhere libc's own (std.c declares none).
const setenv = if (@import("builtin").os.tag == .windows) sysc.setenv else struct {
    extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
}.setenv;
const rename = @import("sys.zig").c.rename;
const utimes = if (@import("builtin").os.tag == .windows) sysc.utimes else struct {
    extern "c" fn utimes(path: [*:0]const u8, times: ?*const [2]sysc.timeval) c_int;
}.utimes;

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

    // Nested: each folder item carries its own largest children, one level
    // per extra depth; without depth there is no `children` field at all.
    try testing.expect(findItem(items, "proj").?.object.get("children") == null);
    const nested = try parse(arena, s.spaceChildren("{\"depth\":3,\"nested_limit\":1}"));
    const proj_nested = findItem(field(field(nested, "groups").array.items[0], "items"), "proj").?;
    const proj_kids = field(proj_nested, "children").array.items;
    try testing.expectEqual(@as(usize, 1), proj_kids.len);
    try testing.expectEqualStrings("node_modules", str(proj_kids[0], "name"));
    try testing.expectEqual(@as(i64, 1), int(field(proj_nested, "children_rest"), "count"));
    try testing.expectEqual(int(proj_nested, "bytes") - int(proj_kids[0], "bytes"), int(field(proj_nested, "children_rest"), "bytes"));
    // Depth 3 reaches node_modules' own child, and no further.
    const pkg = field(proj_kids[0], "children").array.items[0];
    try testing.expectEqualStrings("pkg", str(pkg, "name"));
    try testing.expect(pkg.object.get("children") == null);

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

test "children page: offset passes over ranked items, group answers one cluster" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit();
    try fx.scan();
    const s = try fx.open(true);
    defer s.close();

    // Folder view: pages of two walk the same ranking one answer gives.
    const whole = field(field(try parse(arena, s.spaceChildren("{\"limit\":500}")), "groups").array.items[0], "items").array.items;
    const page = field(try parse(arena, s.spaceChildren("{\"limit\":2,\"offset\":2}")), "groups").array.items[0];
    const page_items = field(page, "items").array.items;
    try testing.expectEqual(@as(usize, 2), page_items.len);
    try testing.expectEqualStrings(str(whole[2], "name"), str(page_items[0], "name"));
    try testing.expectEqualStrings(str(whole[3], "name"), str(page_items[1], "name"));
    // The rest is what follows the page.
    try testing.expectEqual(@as(i64, 2), int(field(page, "rest"), "count"));
    try testing.expectEqual(int(whole[4], "bytes") + int(whole[5], "bytes"), int(field(page, "rest"), "bytes"));
    // Past the end: nothing listed, nothing left.
    const past = field(try parse(arena, s.spaceChildren("{\"offset\":99}")), "groups").array.items[0];
    try testing.expectEqual(@as(usize, 0), field(past, "items").array.items.len);
    try testing.expectEqual(@as(i64, 0), int(field(past, "rest"), "count"));

    // Size view, one band: every file is under 1 MB, so the band holds all nine.
    const band_all = try parse(arena, s.spaceChildren("{\"by\":\"size\",\"group\":\"under_1m\",\"per_group\":200}"));
    const ranked = field(field(band_all, "groups").array.items[0], "items").array.items;
    try testing.expectEqual(@as(usize, 9), ranked.len);
    const band_page = try parse(arena, s.spaceChildren("{\"by\":\"size\",\"group\":\"under_1m\",\"per_group\":3,\"offset\":3}"));
    const groups = field(band_page, "groups").array.items;
    try testing.expectEqual(@as(usize, 1), groups.len);
    const band_items = field(groups[0], "items").array.items;
    try testing.expectEqual(@as(usize, 3), band_items.len);
    for (band_items, 0..) |item, i| try testing.expectEqual(int(ranked[3 + i], "id"), int(item, "id"));
    try testing.expectEqual(@as(i64, 3), int(field(groups[0], "rest"), "count"));

    // Type view, one type; an unknown key answers no groups.
    const docs = try parse(arena, s.spaceChildren("{\"by\":\"type\",\"group\":\"documents\",\"offset\":1}"));
    const doc_groups = field(docs, "groups").array.items;
    try testing.expectEqual(@as(usize, 1), doc_groups.len);
    try testing.expectEqualStrings("documents", str(doc_groups[0], "key"));
    try testing.expectEqual(@as(i64, 2), int(doc_groups[0], "files"));
    try testing.expectEqual(@as(usize, 1), field(doc_groups[0], "items").array.items.len);
    try testing.expectEqualStrings("notes.txt", str(field(doc_groups[0], "items").array.items[0], "name"));
    const none = try parse(arena, s.spaceChildren("{\"by\":\"type\",\"group\":\"nope\"}"));
    try testing.expectEqual(@as(usize, 0), field(none, "groups").array.items.len);
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
            const target = std.fmt.bufPrintSentinel(&buf, "{s}/{d}", .{ self.bin, self.moved }, 0) catch return 1;
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
    // docs lost a.pdf, which sat directly inside it: its own total says so.
    const docs_after = try parse(arena, s.spaceChildren(try std.fmt.allocPrint(arena, "{{\"node\":{d}}}", .{int(findItem(items, "docs").?, "id")})));
    try testing.expectEqual(@as(i64, 1), int(field(docs_after, "node"), "files"));
    try testing.expectEqual(int(field(docs, "node"), "bytes") - int(findItem(docs_items, "a.pdf").?, "bytes"), int(field(docs_after, "node"), "bytes"));
    const listing = try parse(arena, s.spaceChildren("{\"limit\":500}"));
    try testing.expect(findItem(field(field(listing, "groups").array.items[0], "items"), "proj") == null);
    s.close();
    closed = true;

    // Reopened later, what went stays gone; without the roots sidecar the
    // roots come from the tree itself.
    const sidecar = try std.fmt.allocPrintSentinel(arena, "{s}", .{fx.store_path}, 0);
    const roots_sidecar = try std.fmt.allocPrintSentinel(arena, "{s}.roots.json", .{sidecar[0 .. sidecar.len - ".zds".len]}, 0);
    _ = sysc.unlink(roots_sidecar.ptr);
    const again = try fx.open(false);
    defer again.close();
    const reopened = try parse(arena, again.spaceOverview());
    try testing.expectEqual(int(after, "files"), int(reopened, "files"));
    try testing.expectEqual(int(after, "bytes"), int(reopened, "bytes"));
    try testing.expectEqualStrings(fx.tree.path, field(reopened, "roots").array.items[0].string);
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
    const pause: sysc.timespec = .{ .sec = 1, .nsec = 100_000_000 };
    _ = sysc.nanosleep(&pause, null);
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
    const fd = sysc.open(path.ptr, .{ .ACCMODE = .WRONLY, .TRUNC = true }, @as(sysc.mode_t, 0));
    if (fd < 0) return error.OpenFailed;
    defer _ = sysc.close(fd);
    var written: usize = 0;
    while (written < bytes.len) {
        const n = sysc.write(fd, bytes.ptr + written, bytes.len - written);
        if (n <= 0) return error.WriteFailed;
        written += @intCast(n);
    }
}

test "an unreadable folder marks everything above it incomplete" {
    if (sysc.getuid() == 0) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit();
    try fx.write("docs/locked/secret.bin", 9_000);
    const locked = try fx.tree.joinZ("docs/locked");
    defer testing.allocator.free(locked);
    try testing.expectEqual(@as(c_int, 0), sysc.chmod(locked.ptr, 0));
    defer _ = sysc.chmod(locked.ptr, 0o700);

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

fn rootItems(s: *Session, arena: Allocator) !Value {
    const root = try parse(arena, s.spaceChildren("{\"limit\":500}"));
    return field(field(root, "groups").array.items[0], "items");
}

fn childItems(s: *Session, arena: Allocator, id: i64) !Value {
    const answer = try parse(arena, s.spaceChildren(try std.fmt.allocPrint(arena, "{{\"node\":{d},\"limit\":500}}", .{id})));
    return field(field(answer, "groups").array.items[0], "items");
}

test "what the scan left out is listed with its reason, under the folder that holds it" {
    if (sysc.getuid() == 0) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit();
    try fx.write("docs/locked/secret.bin", 9_000);
    try fx.write(".ssh/id_ed25519", 400);
    try fx.write("Pictures/Photos Library.photoslibrary/originals/a.jpg", 70_000);
    try fx.write("Pictures/holiday.jpg", 2_000);
    const locked = try fx.tree.joinZ("docs/locked");
    defer testing.allocator.free(locked);
    try testing.expectEqual(@as(c_int, 0), sysc.chmod(locked.ptr, 0));
    defer _ = sysc.chmod(locked.ptr, 0o700);

    try fx.scan();
    var bin = try Scratch.init(testing.allocator, "space-bin");
    defer bin.deinit();
    var trash: FakeTrash = .{ .bin = bin.path };
    const s = try fx.open(true);
    defer s.close();

    const skipped = field(try parse(arena, s.spaceOverview()), "skipped");
    try testing.expect(field(skipped, "recorded").bool);
    try testing.expectEqual(@as(i64, 1), int(skipped, "denied"));
    try testing.expectEqual(@as(i64, 1), int(skipped, "credentials"));
    try testing.expectEqual(@as(i64, 1), int(skipped, "app_library"));
    try testing.expectEqual(@as(i64, 0), int(skipped, "other_volume"));
    try testing.expectEqual(@as(i64, 0), int(skipped, "unreadable"));

    const items = try rootItems(s, arena);
    const docs_id = int(findItem(items, "docs").?, "id");
    const pictures = findItem(items, "Pictures").?;
    const root_id = int(field(try parse(arena, s.spaceChildren("{}")), "node"), "id");

    const all = try parse(arena, s.spaceSkipped("{}"));
    try testing.expectEqual(@as(i64, 3), int(all, "total"));
    const listed = field(all, "items");
    const lock = findItem(listed, "locked").?;
    try testing.expectEqualStrings("denied", str(lock, "reason"));
    try testing.expectEqual(docs_id, int(lock, "node"));
    try testing.expect(field(lock, "dir").bool);
    try testing.expectEqualStrings(try std.fmt.allocPrint(arena, "{s}/docs/locked", .{fx.tree.path}), str(lock, "path"));
    const keys = findItem(listed, ".ssh").?;
    try testing.expectEqualStrings("credentials", str(keys, "reason"));
    try testing.expectEqual(root_id, int(keys, "node"));
    const library = findItem(listed, "Photos Library.photoslibrary").?;
    try testing.expectEqualStrings("app_library", str(library, "reason"));
    try testing.expectEqual(int(pictures, "id"), int(library, "node"));

    // Narrowed to a folder, or to a reason.
    const in_docs = try parse(arena, s.spaceSkipped(try std.fmt.allocPrint(arena, "{{\"node\":{d}}}", .{docs_id})));
    try testing.expectEqual(@as(i64, 1), int(in_docs, "total"));
    const credentials = try parse(arena, s.spaceSkipped("{\"reason\":\"credentials\"}"));
    try testing.expectEqual(@as(i64, 1), int(credentials, "total"));
    try testing.expectEqualStrings(".ssh", str(field(credentials, "items").array.items[0], "name"));
    const paged = try parse(arena, s.spaceSkipped("{\"limit\":1,\"offset\":1}"));
    try testing.expectEqual(@as(i64, 3), int(paged, "total"));
    try testing.expectEqual(@as(usize, 1), field(paged, "items").array.items.len);

    // The folder holding the photo library the scan never entered stays:
    // trashing it would take the library along unseen.
    try testing.expect(field(pictures, "protected").bool);
    const holiday_id = int(findItem(try childItems(s, arena, int(pictures, "id")), "holiday.jpg").?, "id");
    const request = try std.fmt.allocPrint(arena,
        \\{{"items":[{{"kind":"dir","id":{d}}},{{"kind":"file","id":{d}}}]}}
    , .{ int(pictures, "id"), holiday_id });
    const report = try parse(arena, s.spaceTrash(request, FakeTrash.callback, &trash));
    try testing.expectEqual(@as(i64, 1), int(report, "deleted"));
    try testing.expectEqual(@as(i64, 1), int(report, "failed_count"));
    try testing.expect(fx.tree.exists("Pictures/Photos Library.photoslibrary/originals/a.jpg") catch false);
    try testing.expect(!(fx.tree.exists("Pictures/holiday.jpg") catch true));
}

test "game libraries are measured as applications, and nothing holding one goes to the Trash" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit();
    try fx.write("Games/steamapps/common/Game/data.pak", 80_000);
    try fx.write("Games/notes.txt", 100);
    try fx.write(".local/share/Steam/steam.sh", 3_000);
    try fx.write(".local/bin/tool", 500);
    try fx.scan();
    var bin = try Scratch.init(testing.allocator, "space-bin");
    defer bin.deinit();
    var trash: FakeTrash = .{ .bin = bin.path };
    const s = try fx.open(true);
    defer s.close();

    const overview = try parse(arena, s.spaceOverview());
    try testing.expectEqual(@as(i64, tree_files.len + 4), int(overview, "files"));
    try testing.expectEqual(@as(i64, 0), int(field(overview, "skipped"), "app_library"));

    const items = try rootItems(s, arena);
    const games = findItem(items, "Games").?;
    try testing.expect(field(games, "protected").bool);
    try testing.expectEqualStrings("applications", str(games, "type"));
    const local = findItem(items, ".local").?;
    try testing.expect(field(local, "protected").bool);

    const in_games = try childItems(s, arena, int(games, "id"));
    const steamapps = findItem(in_games, "steamapps").?;
    try testing.expect(field(steamapps, "protected").bool);
    const notes_id = int(findItem(in_games, "notes.txt").?, "id");
    const common = findItem(try childItems(s, arena, int(steamapps, "id")), "common").?;
    const game = findItem(try childItems(s, arena, int(common, "id")), "Game").?;
    const pak = findItem(try childItems(s, arena, int(game, "id")), "data.pak").?;
    try testing.expect(field(pak, "protected").bool);
    const tool_dir = findItem(try childItems(s, arena, int(local, "id")), "bin").?;
    try testing.expect(!field(tool_dir, "protected").bool);

    const request = try std.fmt.allocPrint(arena,
        \\{{"items":[{{"kind":"dir","id":{d}}},{{"kind":"dir","id":{d}}},{{"kind":"dir","id":{d}}},{{"kind":"file","id":{d}}},{{"kind":"file","id":{d}}}]}}
    , .{ int(games, "id"), int(steamapps, "id"), int(local, "id"), int(pak, "id"), notes_id });
    const report = try parse(arena, s.spaceTrash(request, FakeTrash.callback, &trash));
    try testing.expectEqual(@as(i64, 1), int(report, "deleted"));
    try testing.expectEqual(@as(i64, 4), int(report, "failed_count"));
    try testing.expect(fx.tree.exists("Games/steamapps/common/Game/data.pak") catch false);
    try testing.expect(fx.tree.exists(".local/share/Steam/steam.sh") catch false);
    try testing.expect(!(fx.tree.exists("Games/notes.txt") catch true));
}

test "a store from before skips were recorded still opens, with none listed" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit();
    try fx.write(".ssh/id_ed25519", 400);
    try fx.scan();

    // Rewrite the blob header as version 1 wrote it: 256 bytes, the rest of
    // today's header unused.
    const bytes = try readAll(testing.allocator, fx.store_path);
    defer testing.allocator.free(bytes);
    const header = std.mem.bytesToValue(@import("store.zig").Header, bytes[0..256]);
    const at: usize = @intCast(header.space.offset);
    std.mem.writeInt(u32, bytes[at + @offsetOf(space.BlobHeader, "version") ..][0..4], 1, .little);
    std.mem.writeInt(u32, bytes[at + @offsetOf(space.BlobHeader, "header_size") ..][0..4], 256, .little);
    @memset(bytes[at + 256 .. at + space.blob_header_size], 0);
    try writeAll(fx.store_path, bytes);

    const s = try fx.open(true);
    defer s.close();
    const overview = try parse(arena, s.spaceOverview());
    try testing.expect(!field(field(overview, "skipped"), "recorded").bool);
    try testing.expectEqual(@as(i64, 0), int(field(overview, "skipped"), "credentials"));
    try testing.expectEqual(@as(i64, tree_files.len), int(overview, "files"));
    const none = try parse(arena, s.spaceSkipped("{}"));
    try testing.expectEqual(@as(i64, 0), int(none, "total"));
    try testing.expect(findItem(try rootItems(s, arena), "docs") != null);
}

fn kindOf(answer: Value, key: []const u8) Value {
    for (field(answer, "kinds").array.items) |k| {
        if (std.mem.eql(u8, str(k, "key"), key)) return k;
    }
    std.debug.panic("missing kind {s}", .{key});
}

test "suggestions: build output, cache entries, unfinished downloads, large untouched files" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit();
    // Rust build output: `target` beside Cargo.toml is build output; one
    // without a manifest is somebody's folder called target.
    try fx.write("rs/Cargo.toml", 100);
    try fx.write("rs/target/debug/app", 30_000);
    try fx.write("plans/target/goals.txt", 2_000);
    // A cache root is offered entry by entry.
    try fx.write(".cache/pip/wheel.whl", 8_000);
    try fx.write(".cache/huggingface/blob.incomplete", 90_000);
    try fx.write(".cache/stray.db", 4_000);
    try fx.write("Library/Caches/com.example/cache.db", 6_000);
    // Unfinished downloads, one inside build output (claimed by it, not twice).
    try fx.write("Downloads/movie.mkv.part", 1_300_000);
    try fx.write("Downloads/setup.crdownload", 1_100_000);
    // A program's atomic-write staging file, not a download.
    try fx.write("app/.staging/message.json.part", 900);
    try fx.write("proj/node_modules/pkg/tarball.tgz.partial", 1_000);
    try fx.scan();
    const s = try fx.open(true);
    defer s.close();

    // Files written just now; a year 2200 clock sees them all as untouched.
    const far_future: i64 = 7_258_118_400;
    const later = std.fmt.allocPrint(arena, "{{\"stale_days\":365,\"stale_min_bytes\":30000,\"now\":{d}}}", .{far_future}) catch unreachable;
    const answer = try parse(arena, s.spaceSuggest(later));
    try testing.expectEqual(@as(usize, 4), field(answer, "kinds").array.items.len);

    const build = kindOf(answer, "build_output");
    const build_items = field(build, "items");
    try testing.expect(findItem(build_items, "node_modules") != null);
    const target = findItem(build_items, "target") orelse return error.TestUnexpectedResult;
    try testing.expect(std.mem.endsWith(u8, str(target, "path"), "/rs/target"));
    try testing.expectEqual(@as(usize, 2), build_items.array.items.len);
    try testing.expectEqual(@as(i64, 2), int(build, "count"));

    const caches = field(kindOf(answer, "caches"), "items");
    try testing.expect(findItem(caches, "pip") != null);
    try testing.expect(findItem(caches, "huggingface") != null);
    try testing.expect(findItem(caches, "stray.db") != null);
    try testing.expect(findItem(caches, "com.example") != null);
    try testing.expect(findItem(caches, ".cache") == null);
    try testing.expectEqual(@as(usize, 4), caches.array.items.len);

    // The .incomplete blob is inside a cache, so it is a cache entry only.
    const partial = kindOf(answer, "partial_downloads");
    const partial_items = field(partial, "items");
    try testing.expectEqual(@as(usize, 2), partial_items.array.items.len);
    try testing.expectEqualStrings("movie.mkv.part", str(partial_items.array.items[0], "name"));
    try testing.expect(findItem(partial_items, "setup.crdownload") != null);

    try testing.expect(findItem(partial_items, "message.json.part") == null);

    // Untouched and >= 30 KB, outside anything already claimed: the zip is.
    // Media and documents are never suggested for age alone; the .part
    // download and the cache blob are claimed by their own kinds.
    const stale_items = field(kindOf(answer, "stale_large_files"), "items");
    try testing.expectEqual(@as(usize, 1), stale_items.array.items.len);
    try testing.expectEqualStrings("archive.zip", str(stale_items.array.items[0], "name"));

    // Kinds never overlap: no path appears twice across them.
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    for (field(answer, "kinds").array.items) |k| {
        for (field(k, "items").array.items) |item| {
            const gop = try seen.getOrPut(arena, str(item, "path"));
            try testing.expect(!gop.found_existing);
        }
    }

    // Measured now, nothing is untouched yet; stale_days 0 turns it off.
    const now = try parse(arena, s.spaceSuggest("{}"));
    try testing.expectEqual(@as(i64, 0), int(kindOf(now, "stale_large_files"), "count"));
    const off_query = std.fmt.allocPrint(arena, "{{\"stale_days\":0,\"now\":{d}}}", .{far_future}) catch unreachable;
    const off = try parse(arena, s.spaceSuggest(off_query));
    try testing.expectEqual(@as(i64, 0), int(kindOf(off, "stale_large_files"), "count"));

    // Trashed build output stops being suggested.
    const id = int(target, "id");
    const items = std.fmt.allocPrint(arena, "{{\"items\":[{{\"kind\":\"dir\",\"id\":{d}}}]}}", .{id}) catch unreachable;
    var bin = try Scratch.init(testing.allocator, "space-bin");
    defer bin.deinit();
    var fake: FakeTrash = .{ .bin = bin.path };
    _ = try parse(arena, s.spaceTrash(items, FakeTrash.callback, &fake));
    const after = try parse(arena, s.spaceSuggest("{}"));
    try testing.expect(findItem(field(kindOf(after, "build_output"), "items"), "target") == null);
    try testing.expectEqual(@as(i64, 1), int(kindOf(after, "build_output"), "count"));

    // Below a folder: only what is inside it.
    const in_downloads = std.fmt.allocPrint(arena, "{{\"path\":\"{s}/Downloads\"}}", .{fx.tree.path}) catch unreachable;
    const scoped = try parse(arena, s.spaceSuggest(in_downloads));
    try testing.expectEqual(@as(i64, 2), int(kindOf(scoped, "partial_downloads"), "count"));
    try testing.expectEqual(@as(i64, 0), int(kindOf(scoped, "build_output"), "count"));
}

test "suggestions know a Zig cache, Xcode derived data and a tagged cache, not a near miss or a virtual environment" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit();
    try fx.write("work/zcache3/h/manifest.txt", 1_000);
    try fx.write("work/zcache3/o/abc/libx.a", 9_000);
    try fx.write("work/zcache3/tmp/t", 10);
    try fx.write("work/zcache3/z/src", 10);
    try fx.write("work/dd/info.plist", 300);
    try fx.write("work/dd/Build/Products/app", 9_000);
    try fx.write("work/dd/Logs/build.log", 2_000);
    try fx.write("work/dd/Index.noindex/DataStore/v5", 100);
    // A project with h/, o/ and z/ but no tmp/; one with Info.plist, Build
    // and Logs but nothing of Xcode's own.
    try fx.write("work/letters/h/1", 10);
    try fx.write("work/letters/o/2", 10);
    try fx.write("work/letters/z/3", 10);
    try fx.write("work/MyApp/Info.plist", 300);
    try fx.write("work/MyApp/Build/notes", 10);
    try fx.write("work/MyApp/Logs/l", 10);
    // A tagged cache by any name, and a file merely called CACHEDIR.TAG.
    try fx.write("work/blobs/data", 4_000);
    try fx.tree.writeFile("work/blobs/CACHEDIR.TAG", "Signature: 8a477f597d28d172789f06886806bc55\n");
    try fx.write("work/notes/todo", 10);
    try fx.tree.writeFile("work/notes/CACHEDIR.TAG", "");
    // A Python virtual environment uv tagged: not build output, though what
    // is inside it may be.
    try fx.write("work/.venv/pyvenv.cfg", 40);
    try fx.tree.writeFile("work/.venv/CACHEDIR.TAG", "Signature: 8a477f597d28d172789f06886806bc55\n");
    try fx.write("work/.venv/lib/pkg/mod.py", 2_000);
    try fx.write("work/.venv/lib/pkg/__pycache__/mod.pyc", 3_000);
    try fx.scan();
    const s = try fx.open(true);
    defer s.close();

    const answer = try parse(arena, s.spaceSuggest("{}"));
    const items = field(kindOf(answer, "build_output"), "items");
    try testing.expect(findItem(items, "zcache3") != null);
    try testing.expect(findItem(items, "dd") != null);
    try testing.expect(findItem(items, "node_modules") != null);
    try testing.expect(findItem(items, "letters") == null);
    try testing.expect(findItem(items, "MyApp") == null);
    try testing.expect(findItem(items, "blobs") != null);
    try testing.expect(findItem(items, "notes") == null);
    try testing.expect(findItem(items, ".venv") == null);
    const pyc = findItem(items, "__pycache__") orelse return error.TestUnexpectedResult;
    try testing.expect(std.mem.endsWith(u8, str(pyc, "path"), "/.venv/lib/pkg/__pycache__"));
    try testing.expectEqual(@as(usize, 5), items.array.items.len);
}

test "temp areas: build output there is suggested and goes to the Trash, the rest stays protected" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fx = try Fixture.initIn(testing.allocator, true);
    defer fx.deinit();
    try fx.write("zc/h/manifest.txt", 1_000);
    try fx.write("zc/o/abc/libx.a", 9_000);
    try fx.write("zc/tmp/t", 10);
    try fx.write("zc/z/src", 10);
    try fx.write("dd/info.plist", 300);
    try fx.write("dd/Build/app", 9_000);
    try fx.write("dd/Logs/build.log", 2_000);
    try fx.write("dd/Index.noindex/i", 100);
    // The tree by its real path: on macOS that is /private/tmp/..., a temp
    // area inside the protected /private tree; on Linux /tmp, which nothing
    // protects to begin with.
    var real_buf: [sysc.PATH_MAX]u8 = undefined;
    const real_c = sysc.realpath(fx.tree.path.ptr, &real_buf) orelse return error.TestUnexpectedResult;
    const real = try arena.dupeSentinel(u8, std.mem.span(real_c), 0);
    const darwin = comptime @import("builtin").os.tag.isDarwin();
    if (darwin) try testing.expect(std.mem.startsWith(u8, real, "/private/tmp/"));
    try fx.scanAt(real);
    const s = try fx.openAt(real);
    defer s.close();

    // Suggested, though they sit in /private.
    const answer = try parse(arena, s.spaceSuggest("{}"));
    const build_items = field(kindOf(answer, "build_output"), "items");
    try testing.expect(findItem(build_items, "node_modules") != null);
    try testing.expect(findItem(build_items, "zc") != null);
    try testing.expect(findItem(build_items, "dd") != null);

    const root = try parse(arena, s.spaceChildren("{\"limit\":500}"));
    const root_items = field(field(root, "groups").array.items[0], "items");
    const zc_id = int(findItem(root_items, "zc").?, "id");
    const docs_id = int(findItem(root_items, "docs").?, "id");
    const zip_id = int(findItem(root_items, "archive.zip").?, "id");
    const logs = try parse(arena, s.spaceChildren(try std.fmt.allocPrint(arena, "{{\"path\":\"{s}/dd/Logs\"}}", .{real})));
    const log_id = int(findItem(field(field(logs, "groups").array.items[0], "items"), "build.log").?, "id");

    var bin = try Scratch.init(testing.allocator, "space-bin");
    defer bin.deinit();
    var trash: FakeTrash = .{ .bin = bin.path };
    // A build folder, a file inside build output, a plain folder, a loose file.
    const request = try std.fmt.allocPrint(arena,
        \\{{"items":[{{"kind":"dir","id":{d}}},{{"kind":"file","id":{d}}},{{"kind":"dir","id":{d}}},{{"kind":"file","id":{d}}}]}}
    , .{ zc_id, log_id, docs_id, zip_id });
    const report = try parse(arena, s.spaceTrash(request, FakeTrash.callback, &trash));
    try testing.expect(!(fx.tree.exists("zc") catch true));
    try testing.expect(!(fx.tree.exists("dd/Logs/build.log") catch true));
    if (darwin) {
        try testing.expectEqual(@as(i64, 2), int(report, "deleted"));
        try testing.expectEqual(@as(i64, 2), int(report, "failed_count"));
        try testing.expect(fx.tree.exists("docs/a.pdf") catch false);
        try testing.expect(fx.tree.exists("archive.zip") catch false);
    } else {
        try testing.expectEqual(@as(i64, 4), int(report, "deleted"));
    }
}

/// A Trash that records what it was asked to take and moves nothing.
const RecordingTrash = struct {
    asked: usize = 0,

    fn callback(user: ?*anyopaque, paths: [*]const [*:0]const u8, count: usize, err_out: [*]u8, err_cap: usize) callconv(.c) c_int {
        _ = paths;
        _ = err_out;
        _ = err_cap;
        const self: *RecordingTrash = @ptrCast(@alignCast(user.?));
        self.asked += count;
        return 0;
    }
};

fn realOf(arena: Allocator, path: [*:0]const u8) ![]const u8 {
    var buf: [sysc.PATH_MAX]u8 = undefined;
    const r = sysc.realpath(path, &buf) orelse return error.TestUnexpectedResult;
    return arena.dupe(u8, std.mem.span(r));
}

test "a root given through a link is scanned, protected and reported by its real path" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit();
    var links = try Scratch.init(testing.allocator, "space-links");
    defer links.deinit();
    try links.symLink(fx.tree.path, "tree-link");
    const via = try links.joinZ("tree-link");
    defer testing.allocator.free(via);

    try fx.scanAt(via);
    const s = try fx.openAt(via);
    defer s.close();
    const overview = try parse(arena, s.spaceOverview());
    try testing.expectEqualStrings(fx.tree.path, field(overview, "roots").array.items[0].string);

    // The host protects one folder by its real path and one by the link's
    // spelling: the results carry real paths, and both hold.
    const protected = try std.fmt.allocPrint(arena, "[\"{s}/docs\",\"{s}/media\"]", .{ fx.tree.path, via });
    try testing.expect(s.setProtected(protected));
    const root = try parse(arena, s.spaceChildren("{\"limit\":500}"));
    const items = field(field(root, "groups").array.items[0], "items");
    try testing.expect(std.mem.startsWith(u8, str(findItem(items, "docs").?, "path"), fx.tree.path));
    try testing.expect(field(findItem(items, "docs").?, "protected").bool);
    try testing.expect(field(findItem(items, "media").?, "protected").bool);
    try testing.expect(!field(findItem(items, "archive.zip").?, "protected").bool);

    var recorder: RecordingTrash = .{};
    const docs = try parse(arena, s.spaceChildren(try std.fmt.allocPrint(arena, "{{\"node\":{d}}}", .{int(findItem(items, "docs").?, "id")})));
    const pdf_id = int(findItem(field(field(docs, "groups").array.items[0], "items"), "a.pdf").?, "id");
    const refused = try parse(arena, s.spaceTrash(try std.fmt.allocPrint(arena, "{{\"items\":[{{\"kind\":\"file\",\"id\":{d}}}]}}", .{pdf_id}), RecordingTrash.callback, &recorder));
    try testing.expectEqual(@as(i64, 0), int(refused, "deleted"));
    try testing.expectEqual(@as(usize, 0), recorder.asked);

    // An ordinary file there goes, by its real path.
    var bin = try Scratch.init(testing.allocator, "space-bin");
    defer bin.deinit();
    var trash: FakeTrash = .{ .bin = bin.path };
    const zip_id = int(findItem(items, "archive.zip").?, "id");
    const moved = try parse(arena, s.spaceTrash(try std.fmt.allocPrint(arena, "{{\"items\":[{{\"kind\":\"file\",\"id\":{d}}}]}}", .{zip_id}), FakeTrash.callback, &trash));
    try testing.expectEqual(@as(i64, 1), int(moved, "deleted"));
    try testing.expect(!(fx.tree.exists("archive.zip") catch true));
}

test "a root given through a link into a system tree is protected under its real path" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // A small folder inside a protected tree, under whichever spelling this
    // system has (on macOS the first is really /private/var/db/timezone/...).
    const candidates = [_][:0]const u8{ "/usr/share/zoneinfo/Antarctica", "/usr/share/dict" };
    const target = for (candidates) |c| {
        const st = pstat.stat(c.ptr) catch continue;
        if (st.isDir()) break c;
    } else return error.SkipZigTest;
    const real_target = try realOf(arena, target.ptr);

    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit();
    var links = try Scratch.init(testing.allocator, "space-syslink");
    defer links.deinit();
    try links.symLink(target, "sys");
    const via = try links.joinZ("sys");
    defer testing.allocator.free(via);

    try fx.scanAt(via);
    const s = try fx.openAt(via);
    defer s.close();
    const overview = try parse(arena, s.spaceOverview());
    try testing.expectEqualStrings(real_target, field(overview, "roots").array.items[0].string);

    const root = try parse(arena, s.spaceChildren("{\"limit\":500}"));
    const items = field(field(root, "groups").array.items[0], "items").array.items;
    try testing.expect(items.len > 0);
    var request: std.ArrayListUnmanaged(u8) = .empty;
    try request.appendSlice(arena, "{\"items\":[");
    for (items, 0..) |item, i| {
        try testing.expect(std.mem.startsWith(u8, str(item, "path"), real_target));
        try testing.expect(field(item, "protected").bool);
        if (i > 0) try request.append(arena, ',');
        const kind = if (std.mem.eql(u8, str(item, "kind"), "file")) "file" else "dir";
        try request.print(arena, "{{\"kind\":\"{s}\",\"id\":{d}}}", .{ kind, int(item, "id") });
    }
    try request.appendSlice(arena, "]}");
    // Nothing is even offered to the Trash, which would move nothing anyway.
    var recorder: RecordingTrash = .{};
    const report = try parse(arena, s.spaceTrash(request.items, RecordingTrash.callback, &recorder));
    try testing.expectEqual(@as(i64, 0), int(report, "deleted"));
    try testing.expectEqual(@as(usize, 0), recorder.asked);
}

/// Folder links: a symbolic link everywhere, and on Windows a junction too.
const LinkKind = enum { symlink, junction };

/// `rename(name, moved_to)` inside `tree`, then a `kind` link at `name` to
/// `target` (inside the tree too).
fn swapForLink(arena: Allocator, tree: *const Scratch, kind: LinkKind, name: []const u8, moved_to: []const u8, target: []const u8) !void {
    const from = try std.fmt.allocPrintSentinel(arena, "{s}/{s}", .{ tree.path, name }, 0);
    const to = try std.fmt.allocPrintSentinel(arena, "{s}/{s}", .{ tree.path, moved_to }, 0);
    try testing.expectEqual(@as(c_int, 0), rename(from.ptr, to.ptr));
    const abs = try std.fmt.allocPrint(arena, "{s}/{s}", .{ tree.path, target });
    switch (kind) {
        .symlink => try tree.symLink(abs, name),
        .junction => try tree.junction(abs, name),
    }
}

test "the space Trash never acts through a link: a folder or file replaced by one, or below one" {
    try spaceTrashThroughLinks(.symlink);
}

test "the space Trash never acts through a link, with junctions (Windows)" {
    if (comptime @import("builtin").os.tag != .windows) return error.SkipZigTest;
    try spaceTrashThroughLinks(.junction);
}

fn spaceTrashThroughLinks(kind: LinkKind) !void {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit();
    // A second home for what the links will lead to: same names, same sizes.
    try fx.write("elsewhere/a.pdf", 20_000);
    try fx.write("elsewhere/node_modules/pkg/index.js", 5_000);
    try fx.scan();
    const s = try fx.open(true);
    defer s.close();

    const root = try parse(arena, s.spaceChildren("{\"limit\":500}"));
    const items = field(field(root, "groups").array.items[0], "items");
    const archive_id = int(findItem(items, "archive.zip").?, "id");
    const media_id = int(findItem(items, "media").?, "id");
    const docs = try parse(arena, s.spaceChildren(try std.fmt.allocPrint(arena, "{{\"node\":{d}}}", .{int(findItem(items, "docs").?, "id")})));
    const pdf = findItem(field(field(docs, "groups").array.items[0], "items"), "a.pdf").?;
    const proj = try parse(arena, s.spaceChildren(try std.fmt.allocPrint(arena, "{{\"node\":{d}}}", .{int(findItem(items, "proj").?, "id")})));
    const nm_id = int(findItem(field(field(proj, "groups").array.items[0], "items"), "node_modules").?, "id");

    // elsewhere/a.pdf gets docs/a.pdf's modification time, so only the
    // path tells them apart.
    const pdf_path = try std.fmt.allocPrintSentinel(arena, "{s}/docs/a.pdf", .{fx.tree.path}, 0);
    const st = try pstat.lstat(pdf_path.ptr);
    const other_pdf = try std.fmt.allocPrintSentinel(arena, "{s}/elsewhere/a.pdf", .{fx.tree.path}, 0);
    const times = [2]sysc.timeval{ .{ .sec = st.mtime_sec, .usec = 0 }, .{ .sec = st.mtime_sec, .usec = 0 } };
    try testing.expectEqual(@as(c_int, 0), utimes(other_pdf.ptr, &times));

    // After the scan: media and archive.zip become links to elsewhere's
    // things, and docs and proj become links to elsewhere itself.
    try swapForLink(arena, &fx.tree, kind, "media", "media-moved", "elsewhere");
    // A junction cannot lead to a file: the file stays a symbolic link.
    try swapForLink(arena, &fx.tree, .symlink, "archive.zip", "archive-moved.zip", "elsewhere/a.pdf");
    try swapForLink(arena, &fx.tree, kind, "docs", "docs-moved", "elsewhere");
    try swapForLink(arena, &fx.tree, kind, "proj", "proj-moved", "elsewhere");

    var recorder: RecordingTrash = .{};
    const request = try std.fmt.allocPrint(arena,
        \\{{"items":[{{"kind":"dir","id":{d}}},{{"kind":"file","id":{d}}},{{"kind":"file","id":{d}}},{{"kind":"dir","id":{d}}}]}}
    , .{ media_id, archive_id, int(pdf, "id"), nm_id });
    const report = try parse(arena, s.spaceTrash(request, RecordingTrash.callback, &recorder));
    try testing.expectEqual(@as(i64, 0), int(report, "deleted"));
    try testing.expectEqual(@as(i64, 4), int(report, "failed_count"));
    try testing.expectEqual(@as(usize, 0), recorder.asked);
    try testing.expect(fx.tree.exists("elsewhere/a.pdf") catch false);
    try testing.expect(fx.tree.exists("elsewhere/node_modules/pkg/index.js") catch false);
}
