//! What has been deleted since the results on screen were scanned.
//!
//! The result store is an immutable snapshot, so after a delete it describes
//! files that are gone. Rescanning to correct that costs minutes; the session
//! already knows exactly what it deleted, so it records those paths here and
//! every query leaves them out: a deleted file drops out of its group, a
//! deleted folder out of its set, and anything *inside* a deleted folder goes
//! with it. A group left with a single copy is not a finding and disappears.
//! Rescanning is then something the user does when they are done.
//!
//! Persisted next to the store, so results reopened after a restart do not
//! resurrect what was already cleaned up. Paths are held — and persisted — as
//! the exact bytes the store holds, base64 in the sidecar, because `covers`
//! compares bytes and a name that is not UTF-8 would otherwise never match
//! again after a restart.

const std = @import("std");
const libc = std.c;

/// Past this many entries the set is dropped and the results are flagged as
/// needing a rescan instead: a bulk delete of a million files is cheaper to
/// rescan than to remember.
pub const max_tracked: usize = 100_000;

const base64 = std.base64.standard;

pub const Removed = struct {
    gpa: std.mem.Allocator,
    /// Keys are owned copies of the exact path bytes.
    paths: std.StringHashMapUnmanaged(void) = .empty,
    /// Bumped on every change; lets caches keyed on the results notice.
    generation: u64 = 0,
    /// More was deleted than is tracked: the results cannot be corrected in
    /// place any more.
    overflowed: bool = false,
    /// Where the overlay is persisted; null until `attach`.
    sidecar: ?[:0]u8 = null,

    pub fn init(gpa: std.mem.Allocator) Removed {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Removed) void {
        self.clearPaths();
        self.paths.deinit(self.gpa);
        if (self.sidecar) |s| self.gpa.free(s);
        self.sidecar = null;
    }

    fn clearPaths(self: *Removed) void {
        var it = self.paths.keyIterator();
        while (it.next()) |key| self.gpa.free(key.*);
        self.paths.clearRetainingCapacity();
    }

    /// Start tracking for the store at `store_file`, picking up what was
    /// recorded for it before. `fresh` (a new scan) forgets everything,
    /// sidecar included.
    pub fn attach(self: *Removed, store_file: []const u8, fresh: bool) !void {
        const sidecar = try sidecarPath(self.gpa, store_file, "removed.json");
        errdefer self.gpa.free(sidecar);

        self.clearPaths();
        self.overflowed = false;
        self.generation += 1;

        if (fresh) {
            _ = libc.unlink(sidecar.ptr);
        } else {
            self.load(sidecar) catch {};
        }
        if (self.sidecar) |old| self.gpa.free(old);
        self.sidecar = sidecar;
    }

    fn load(self: *Removed, sidecar: [:0]const u8) !void {
        const bytes = try readWholeFile(self.gpa, sidecar, 64 * 1024 * 1024);
        defer self.gpa.free(bytes);

        var arena: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena.deinit();
        const saved = try std.json.parseFromSliceLeaky(
            Sidecar,
            arena.allocator(),
            bytes,
            .{ .ignore_unknown_fields = true },
        );

        self.overflowed = saved.overflowed;
        for (saved.paths_b64) |encoded| {
            const len = base64.Decoder.calcSizeForSlice(encoded) catch continue;
            const path = try self.gpa.alloc(u8, len);
            base64.Decoder.decode(path, encoded) catch {
                self.gpa.free(path);
                continue;
            };
            self.insertOwned(path) catch {
                self.gpa.free(path);
                return error.OutOfMemory;
            };
        }
    }

    /// Takes ownership of `path` on success.
    fn insertOwned(self: *Removed, path: []u8) !void {
        const existing = try self.paths.getOrPut(self.gpa, path);
        if (existing.found_existing) {
            self.gpa.free(path);
            return;
        }
        existing.key_ptr.* = path;
    }

    pub fn isEmpty(self: *const Removed) bool {
        return self.paths.count() == 0;
    }

    pub fn len(self: *const Removed) usize {
        return self.paths.count();
    }

    pub fn needsRescan(self: *const Removed) bool {
        return self.overflowed;
    }

    /// True if `path` was deleted, or lies inside a folder that was.
    pub fn covers(self: *const Removed, path: []const u8) bool {
        if (self.paths.count() == 0) return false;
        // The path itself, then each ancestor: a handful of hash lookups,
        // however many paths have been removed.
        var current = path;
        while (true) {
            if (self.paths.contains(current)) return true;
            const slash = std.mem.lastIndexOfScalar(u8, current, '/') orelse return false;
            if (slash == 0) return false;
            current = current[0..slash];
        }
    }

    /// Record deleted paths (files or folders). Returns whether the results can
    /// still be corrected in place; false means they must be rescanned.
    pub fn record(self: *Removed, deleted: []const []const u8) bool {
        for (deleted) |path| {
            if (self.overflowed) break;
            if (self.paths.count() >= max_tracked) {
                self.overflowed = true;
                self.clearPaths();
                break;
            }
            const owned = self.gpa.dupe(u8, path) catch {
                // Out of memory mid-record: the overlay can no longer describe
                // what went, which is exactly what `overflowed` means.
                self.overflowed = true;
                self.clearPaths();
                break;
            };
            self.insertOwned(owned) catch {
                self.gpa.free(owned);
                self.overflowed = true;
                self.clearPaths();
                break;
            };
        }
        self.generation += 1;
        self.persist();
        return !self.overflowed;
    }

    /// Best effort: losing the sidecar only means a restored scan shows a few
    /// findings that a delete would then refuse or skip.
    fn persist(self: *const Removed) void {
        const sidecar = self.sidecar orelse return;

        var out: std.Io.Writer.Allocating = .init(self.gpa);
        defer out.deinit();
        self.writeSidecar(&out.writer) catch return;

        const path_z: [*:0]const u8 = sidecar.ptr;
        const fd = libc.open(path_z, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(libc.mode_t, 0o600));
        if (fd < 0) return;
        defer _ = libc.close(fd);

        const content = out.writer.buffered();
        var written: usize = 0;
        while (written < content.len) {
            const n = libc.write(fd, content.ptr + written, content.len - written);
            if (n < 0) {
                if (libc.errno(n) == .INTR) continue;
                return;
            }
            if (n == 0) return;
            written += @intCast(n);
        }
    }

    fn writeSidecar(self: *const Removed, writer: *std.Io.Writer) !void {
        var buf: [512]u8 = undefined;
        var json: std.json.Stringify = .{ .writer = writer };
        try json.beginObject();
        try json.objectField("overflowed");
        try json.write(self.overflowed);
        try json.objectField("paths_b64");
        try json.beginArray();
        var it = self.paths.keyIterator();
        while (it.next()) |key| {
            const path = key.*;
            const size = base64.Encoder.calcSize(path.len);
            // Long paths are rare; the stack buffer covers the rest.
            const scratch = if (size <= buf.len) buf[0..size] else try self.gpa.alloc(u8, size);
            defer if (size > buf.len) self.gpa.free(scratch);
            try json.write(base64.Encoder.encode(scratch, path));
        }
        try json.endArray();
        try json.endObject();
    }
};

/// On-disk form of the overlay. The overflow travels with the paths: a restart
/// after an untrackable delete must still ask for a rescan rather than
/// resurrect everything that went.
const Sidecar = struct {
    overflowed: bool = false,
    paths_b64: []const []const u8 = &.{},
};

/// `<dir>/<name>.zds` -> `<dir>/<name>.<suffix>`, matching the sidecar naming
/// the desktop apps already use. A name with no extension just gains one.
pub fn sidecarPath(gpa: std.mem.Allocator, store_file: []const u8, suffix: []const u8) ![:0]u8 {
    const slash = std.mem.lastIndexOfScalar(u8, store_file, '/');
    const name_start: usize = if (slash) |i| i + 1 else 0;
    const name = store_file[name_start..];
    // A leading dot is a hidden file, not an extension.
    const stem_len = blk: {
        const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse break :blk name.len;
        break :blk if (dot == 0) name.len else dot;
    };
    return std.fmt.allocPrintSentinel(
        gpa,
        "{s}.{s}",
        .{ store_file[0 .. name_start + stem_len], suffix },
        0,
    );
}

/// Read `path` whole, refusing anything above `max_bytes`. Sidecars are ours
/// and small; the cap keeps a replaced file from being read into memory.
pub fn readWholeFile(gpa: std.mem.Allocator, path: [*:0]const u8, max_bytes: usize) ![]u8 {
    const fd = libc.open(path, .{ .ACCMODE = .RDONLY }, @as(libc.mode_t, 0));
    if (fd < 0) return error.CannotOpenFile;
    defer _ = libc.close(fd);

    var list: std.ArrayListUnmanaged(u8) = .empty;
    errdefer list.deinit(gpa);
    var chunk: [16 * 1024]u8 = undefined;
    while (true) {
        const n = libc.read(fd, &chunk, chunk.len);
        if (n == 0) break;
        if (n < 0) {
            if (libc.errno(n) == .INTR) continue;
            return error.ReadFailed;
        }
        const read: usize = @intCast(n);
        if (list.items.len + read > max_bytes) return error.FileTooLarge;
        try list.appendSlice(gpa, chunk[0..read]);
    }
    return list.toOwnedSlice(gpa);
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;
const Scratch = @import("testing_scratch.zig").Scratch;

fn with(paths: []const []const u8) Removed {
    var removed: Removed = .init(testing.allocator);
    _ = removed.record(paths);
    return removed;
}

test "a deleted folder takes everything inside it" {
    var removed = with(&.{"/home/u/old"});
    defer removed.deinit();

    try testing.expect(removed.covers("/home/u/old"));
    try testing.expect(removed.covers("/home/u/old/src/main.c"));
    try testing.expect(!removed.covers("/home/u"));
    try testing.expect(!removed.covers("/home/u/new/src/main.c"));
    // A name that merely starts the same is a different folder.
    try testing.expect(!removed.covers("/home/u/old-backup/file"));
    try testing.expect(!removed.covers("/home/u/older"));
}

test "a deleted file is only itself" {
    var removed = with(&.{"/a/b/file.bin"});
    defer removed.deinit();

    try testing.expect(removed.covers("/a/b/file.bin"));
    try testing.expect(!removed.covers("/a/b/file.bin.bak"));
    try testing.expect(!removed.covers("/a/b"));
}

test "nothing is covered when nothing was removed" {
    var removed: Removed = .init(testing.allocator);
    defer removed.deinit();
    try testing.expect(!removed.covers("/anything"));
}

test "every change bumps the generation" {
    var removed: Removed = .init(testing.allocator);
    defer removed.deinit();
    const before = removed.generation;
    _ = removed.record(&.{"/x"});
    try testing.expect(removed.generation > before);
}

test "sidecar names sit beside the store, replacing its extension" {
    const gpa = testing.allocator;
    for ([_][2][]const u8{
        .{ "/a/last.zds", "/a/last.removed.json" },
        .{ "/a/last", "/a/last.removed.json" },
        .{ "last.zds", "last.removed.json" },
        .{ "/a/.hidden", "/a/.hidden.removed.json" },
        .{ "/a.b/last.zds", "/a.b/last.removed.json" },
    }) |case| {
        const got = try sidecarPath(gpa, case[0], "removed.json");
        defer gpa.free(got);
        try testing.expectEqualStrings(case[1], got);
    }
}

test "the overlay survives a restart and is forgotten by a new scan" {
    const gpa = testing.allocator;
    var scratch = try Scratch.init(gpa, "removed-persist");
    defer scratch.deinit();
    const store_file = try scratch.join("last.zds");
    defer gpa.free(store_file);

    var first: Removed = .init(gpa);
    try first.attach(store_file, true);
    _ = first.record(&.{"/home/u/old"});
    first.deinit();

    var reopened: Removed = .init(gpa);
    try reopened.attach(store_file, false);
    try testing.expect(reopened.covers("/home/u/old/file"));
    reopened.deinit();

    var rescanned: Removed = .init(gpa);
    try rescanned.attach(store_file, true);
    try testing.expect(rescanned.isEmpty());
    rescanned.deinit();

    var after: Removed = .init(gpa);
    try after.attach(store_file, false);
    try testing.expect(after.isEmpty()); // a new scan clears the sidecar too
    after.deinit();
}

test "a name that is not UTF-8 survives a restart byte for byte" {
    const gpa = testing.allocator;
    var scratch = try Scratch.init(gpa, "removed-bytes");
    defer scratch.deinit();
    const store_file = try scratch.join("last.zds");
    defer gpa.free(store_file);

    // A lone 0xE9 is not valid UTF-8; base64 in the sidecar is what keeps it.
    const raw = "/home/u/caf\xe9.bin";

    var first: Removed = .init(gpa);
    try first.attach(store_file, true);
    _ = first.record(&.{raw});
    first.deinit();

    var reopened: Removed = .init(gpa);
    defer reopened.deinit();
    try reopened.attach(store_file, false);
    try testing.expect(reopened.covers(raw));
    // The lossy spelling is a different byte string and must not match.
    try testing.expect(!reopened.covers("/home/u/caf\u{FFFD}.bin"));
}

test "too much to track asks for a rescan instead, and says so after a restart" {
    const gpa = testing.allocator;
    var scratch = try Scratch.init(gpa, "removed-overflow");
    defer scratch.deinit();
    const store_file = try scratch.join("last.zds");
    defer gpa.free(store_file);

    var flood: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (flood.items) |p| gpa.free(p);
        flood.deinit(gpa);
    }
    for (0..max_tracked + 1) |i| {
        try flood.append(gpa, try std.fmt.allocPrint(gpa, "/f/{d}", .{i}));
    }

    var first: Removed = .init(gpa);
    try first.attach(store_file, true);
    // Past the cap the results can no longer be corrected in place.
    try testing.expect(!first.record(flood.items));
    try testing.expect(first.isEmpty());
    try testing.expect(first.needsRescan());
    first.deinit();

    var reopened: Removed = .init(gpa);
    defer reopened.deinit();
    try reopened.attach(store_file, false);
    try testing.expect(reopened.needsRescan());
}
