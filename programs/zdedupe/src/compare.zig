//! Folder comparison
//!
//! Compares two directories and sorts the files of both into:
//! - Identical: same relative path, same bytes
//! - Only in A / only in B
//! - Modified: same relative path, different size or bytes
//!
//! Each tree is walked by fast_walker on every core, every path listed (hard
//! links too: a folder and its copy must name the same files, however the
//! filesystem stores them). Files in both with one size are then compared
//! byte for byte, not by digest: each file is read once, and
//! a pair stops being read at its first difference. The pairs are cut into
//! ranges of `default_range_size` that any worker may take, so a single very large
//! file is read by every core rather than one.
//!
//! This is also the check behind a permanent folder delete
//! (`session.foldersIdentical`), so "identical" must hold for the files as they
//! are while they are read: every range checks that both files still have the
//! size the walk saw, and any error reading either counts as a difference.

const std = @import("std");
const types = @import("types.zig");
const hasher = @import("hasher.zig");
const walker = @import("walker.zig");
const fast_walker = @import("fast_walker.zig");
const libc = @import("sys.zig").c;
const realpath = @import("realpath.zig");

// Stat comes from pstat.zig: std.c ($INODE64-correct) on Darwin, statx on Linux.
const pstat = @import("pstat.zig");

/// Bytes of one pair a worker compares before it takes more work; see
/// `FolderComparator.range_size`.
pub const default_range_size: u64 = 64 * 1024 * 1024;

/// Bytes read from each side at a time.
const chunk_size: usize = 1024 * 1024;

/// Folder comparator
pub const FolderComparator = struct {
    allocator: std.mem.Allocator,
    config: types.Config,
    /// Progress callback, called from the thread that called `compare`.
    progress_callback: ?types.ProgressCallback,
    /// Current progress
    progress: types.Progress,
    /// Pairs are compared in ranges of this many bytes.
    range_size: u64 = default_range_size,

    pub fn init(allocator: std.mem.Allocator, config: types.Config) FolderComparator {
        return .{
            .allocator = allocator,
            .config = config,
            .progress_callback = null,
            .progress = .{
                .phase = .scanning,
                .files_processed = 0,
                .files_total = 0,
                .bytes_processed = 0,
                .bytes_total = 0,
                .current_file = null,
            },
        };
    }

    /// Set progress callback
    pub fn setProgressCallback(self: *FolderComparator, callback: types.ProgressCallback) void {
        self.progress_callback = callback;
    }

    /// Compare two folders. With `config.monitor`, reports progress through it
    /// and stops with error.Cancelled when it is cancelled.
    pub fn compare(self: *FolderComparator, given_a: []const u8, given_b: []const u8) !types.CompareResult {
        const allocator = self.allocator;
        const monitor = self.config.monitor;
        // Both sides by their real paths, as every scan walks its roots.
        const folder_a = try realpath.orGiven(allocator, given_a);
        defer allocator.free(folder_a);
        const folder_b = try realpath.orGiven(allocator, given_b);
        defer allocator.free(folder_b);
        var result = try types.CompareResult.init(allocator, folder_a, folder_b);
        errdefer result.deinit();

        if (monitor) |m| m.enter(.scanning, 0);
        self.updateProgress(.scanning, 0, 0, null);
        var files_a = try self.walkAndIndex(folder_a);
        defer freeIndex(allocator, &files_a);
        var files_b = try self.walkAndIndex(folder_b);
        defer freeIndex(allocator, &files_b);
        try checkCancelled(monitor);

        // Pair up by relative path. The lists keep the order the walk index
        // gives, as they always have.
        var pairs: std.ArrayListUnmanaged(Pair) = .empty;
        defer pairs.deinit(allocator);
        var iter_a = files_a.iterator();
        while (iter_a.next()) |kv| {
            if (files_b.get(kv.key_ptr.*)) |entry_b| {
                try pairs.append(allocator, .{ .rel = kv.key_ptr.*, .a = kv.value_ptr.*, .b = entry_b });
            } else {
                try appendOwned(allocator, &result.only_in_a, kv.key_ptr.*);
            }
        }
        var iter_b = files_b.iterator();
        while (iter_b.next()) |kv| {
            if (!files_a.contains(kv.key_ptr.*)) try appendOwned(allocator, &result.only_in_b, kv.key_ptr.*);
        }

        try self.compareContents(pairs.items);

        for (pairs.items) |*pair| {
            const list = if (pair.differs.load(.acquire)) &result.modified else &result.identical;
            try appendOwned(allocator, list, pair.rel);
        }
        const total = files_a.count() + files_b.count();
        self.updateProgress(.done, total, total, null);
        return result;
    }

    /// Decide every pair: `differs` is left false only for two files of one
    /// size whose bytes all matched.
    fn compareContents(self: *FolderComparator, pairs: []Pair) !void {
        const allocator = self.allocator;
        const monitor = self.config.monitor;

        // Different sizes differ without a read; empty files match without one.
        var units: std.ArrayListUnmanaged(Unit) = .empty;
        defer units.deinit(allocator);
        var bytes_total: u64 = 0;
        var decided: u64 = 0;
        for (pairs, 0..) |*pair, i| {
            if (pair.a.size != pair.b.size) {
                pair.differs.store(true, .monotonic);
                decided += 1;
                continue;
            }
            const size = pair.a.size;
            if (size == 0) {
                decided += 1;
                continue;
            }
            const ranges = std.math.divCeil(u64, size, self.range_size) catch unreachable;
            pair.ranges_left.store(@intCast(ranges), .monotonic);
            var start: u64 = 0;
            while (start < size) : (start += self.range_size) {
                try units.append(allocator, .{ .pair = @intCast(i), .start = start, .end = @min(size, start + self.range_size) });
            }
            bytes_total +|= 2 * size;
        }
        // Largest pairs first, so a big file is never what the last worker is
        // still reading alone; the stable sort keeps a file's ranges in order.
        std.mem.sort(Unit, units.items, pairs, struct {
            fn lessThan(ps: []Pair, x: Unit, y: Unit) bool {
                return ps[x.pair].a.size > ps[y.pair].a.size;
            }
        }.lessThan);

        if (monitor) |m| {
            m.enterBytes(.full_hashing, pairs.len, bytes_total);
            _ = m.done.fetchAdd(decided, .release);
        }
        self.updateProgress(.full_hashing, decided, pairs.len, null);
        if (units.items.len == 0) return;

        const workers: usize = @min(self.config.getThreadCount(), units.items.len, types.Monitor.slot_count);
        const buffers = try allocator.alloc(u8, workers * 2 * chunk_size);
        defer allocator.free(buffers);
        var shared: Shared = .{ .pairs = pairs, .units = units.items, .monitor = monitor, .buffers = buffers, .decided = .init(decided) };

        const threads = try allocator.alloc(std.Thread, workers);
        defer allocator.free(threads);
        var started: usize = 0;
        for (threads, 0..) |*t, index| {
            t.* = std.Thread.spawn(.{}, Shared.work, .{ &shared, index }) catch break;
            started += 1;
        }
        if (started == 0) {
            shared.work(0);
        } else if (self.progress_callback != null) {
            // The callback is the caller's and runs on the caller's thread.
            while (shared.finished.load(.acquire) < started) {
                self.updateProgress(.full_hashing, shared.decided.load(.monotonic), pairs.len, null);
                const tick: libc.timespec = .{ .sec = 0, .nsec = 100 * std.time.ns_per_ms };
                _ = libc.nanosleep(&tick, null);
            }
        }
        for (threads[0..started]) |t| t.join();
        try checkCancelled(monitor);
    }

    /// Internal file entry for indexing
    const IndexEntry = struct {
        path: []const u8, // Full absolute path
        size: u64,
    };

    const Index = std.StringHashMap(IndexEntry);

    /// Walk directory and build index by relative path
    fn walkAndIndex(self: *const FolderComparator, base_path: []const u8) !Index {
        var index = Index.init(self.allocator);
        errdefer freeIndex(self.allocator, &index);

        var fw = fast_walker.FastWalker.init(self.allocator);
        defer fw.deinit();
        fw.setIncludeHidden(self.config.include_hidden);
        fw.setFollowSymlinks(self.config.follow_symlinks);
        fw.setSizeFilter(self.config.min_size, self.config.max_size);
        fw.setOneFilesystem(self.config.one_filesystem);
        fw.disableHardLinkDetection();
        fw.setMonitor(self.config.monitor);
        fw.setThreads(self.config.getThreadCount());
        try fw.walk(base_path);
        try fw.finish();

        // The walker owns its paths, so the index takes copies.
        for (fw.files.items) |entry| {
            const rel_path = walker.Walker.relativePath(base_path, entry.path);
            if (index.contains(rel_path)) continue; // the same relative path twice: keep the first
            const rel_copy = try self.allocator.dupe(u8, rel_path);
            errdefer self.allocator.free(rel_copy);
            const abs_copy = try self.allocator.dupe(u8, entry.path);
            errdefer self.allocator.free(abs_copy);
            try index.put(rel_copy, .{ .path = abs_copy, .size = entry.size });
        }
        return index;
    }

    fn updateProgress(self: *FolderComparator, phase: types.Progress.Phase, processed: u64, total: u64, file: ?[]const u8) void {
        self.progress.phase = phase;
        self.progress.files_processed = processed;
        self.progress.files_total = total;
        self.progress.current_file = file;

        if (self.progress_callback) |cb| cb(&self.progress);
    }

};

/// Two files at one relative path.
const Pair = struct {
    rel: []const u8,
    a: FolderComparator.IndexEntry,
    b: FolderComparator.IndexEntry,
    /// Set by whoever finds a difference or cannot read a range; the pair's
    /// other ranges are then skipped.
    differs: std.atomic.Value(bool) = .init(false),
    /// Ranges not yet compared; the pair is decided when this reaches 0.
    ranges_left: std.atomic.Value(u32) = .init(0),
};

/// Bytes [start, end) of one pair.
const Unit = struct {
    pair: u32,
    start: u64,
    end: u64,
};

const Shared = struct {
    pairs: []Pair,
    units: []const Unit,
    monitor: ?*types.Monitor,
    /// Two `chunk_size` buffers per worker.
    buffers: []u8,
    next: std.atomic.Value(usize) = .init(0),
    /// Pairs whose every range has been compared or skipped.
    decided: std.atomic.Value(u64) = .init(0),
    /// Workers that have run out of work.
    finished: std.atomic.Value(usize) = .init(0),

    fn work(self: *Shared, index: usize) void {
        defer _ = self.finished.fetchAdd(1, .release);
        const mine = self.buffers[index * 2 * chunk_size ..][0 .. 2 * chunk_size];
        const buf_a = mine[0..chunk_size];
        const buf_b = mine[chunk_size..];
        while (true) {
            if (self.monitor) |m| if (m.cancelled()) return;
            const i = self.next.fetchAdd(1, .monotonic);
            if (i >= self.units.len) return;
            const unit = self.units[i];
            const pair = &self.pairs[unit.pair];
            if (!pair.differs.load(.acquire)) {
                if (self.monitor) |m| m.begin(index, pair.a.path);
                const same = rangeMatches(pair, unit, buf_a, buf_b, self.monitor) catch |err| switch (err) {
                    error.Cancelled => {
                        if (self.monitor) |m| m.end(index);
                        return;
                    },
                };
                if (self.monitor) |m| m.end(index);
                if (!same) pair.differs.store(true, .release);
            }
            if (pair.ranges_left.fetchSub(1, .acq_rel) == 1) {
                _ = self.decided.fetchAdd(1, .monotonic);
                if (self.monitor) |m| _ = m.done.fetchAdd(1, .release);
            }
        }
    }
};

/// Do both files hold the same bytes in `unit`, and still have the size the
/// walk saw? False on any error opening or reading either.
fn rangeMatches(pair: *const Pair, unit: Unit, buf_a: []u8, buf_b: []u8, monitor: ?*types.Monitor) error{Cancelled}!bool {
    var budget: hasher.Budget = .{ .monitor = monitor, .left = 2 * (unit.end - unit.start) };
    defer budget.finish();
    const fd_a = hasher.openRegularFile(pair.a.path) catch return false;
    defer _ = libc.close(fd_a);
    const fd_b = hasher.openRegularFile(pair.b.path) catch return false;
    defer _ = libc.close(fd_b);
    const st_a = pstat.fstat(fd_a) catch return false;
    const st_b = pstat.fstat(fd_b) catch return false;
    if (st_a.size != pair.a.size or st_b.size != pair.b.size) return false;

    var offset = unit.start;
    while (offset < unit.end) {
        if (monitor) |m| if (m.cancelled()) return error.Cancelled;
        // Another range of this pair already differs: nothing left to learn.
        if (pair.differs.load(.monotonic)) return false;
        const n: usize = @intCast(@min(chunk_size, unit.end - offset));
        const got_a = hasher.preadAll(fd_a, buf_a[0..n], offset) catch return false;
        const got_b = hasher.preadAll(fd_b, buf_b[0..n], offset) catch return false;
        // Short: the file shrank while it was read.
        if (got_a != n or got_b != n) return false;
        if (!std.mem.eql(u8, buf_a[0..n], buf_b[0..n])) return false;
        budget.add(2 * n);
        offset += n;
    }
    return true;
}

fn checkCancelled(monitor: ?*types.Monitor) error{Cancelled}!void {
    if (monitor) |m| if (m.cancelled()) return error.Cancelled;
}

fn freeIndex(allocator: std.mem.Allocator, index: *FolderComparator.Index) void {
    var iter = index.iterator();
    while (iter.next()) |kv| {
        allocator.free(kv.key_ptr.*);
        allocator.free(kv.value_ptr.path);
    }
    index.deinit();
}

fn appendOwned(allocator: std.mem.Allocator, list: *std.ArrayListUnmanaged([]const u8), s: []const u8) !void {
    const copy = try allocator.dupe(u8, s);
    errdefer allocator.free(copy);
    try list.append(allocator, copy);
}

/// Convenience function for folder comparison
pub fn compareFolders(
    allocator: std.mem.Allocator,
    folder_a: []const u8,
    folder_b: []const u8,
    config: types.Config,
) !types.CompareResult {
    var comparator = FolderComparator.init(allocator, config);
    return comparator.compare(folder_a, folder_b);
}

/// Generate summary statistics from comparison result
pub fn getSummary(result: *const types.CompareResult) types.CompareSummary {
    return .{
        .files_in_a = result.identical.items.len + result.only_in_a.items.len + result.modified.items.len,
        .files_in_b = result.identical.items.len + result.only_in_b.items.len + result.modified.items.len,
        .identical_count = result.identical.items.len,
        .only_in_a_count = result.only_in_a.items.len,
        .only_in_b_count = result.only_in_b.items.len,
        .modified_count = result.modified.items.len,
        .compare_time_ns = 0, // Caller should set this
    };
}

// ============================================================================
// Tests
// ============================================================================

test "FolderComparator initialization" {
    const allocator = std.testing.allocator;
    const comparator = FolderComparator.init(allocator, .{});
    _ = comparator;
}

test "CompareResult isIdentical" {
    const allocator = std.testing.allocator;
    var result = try types.CompareResult.init(allocator, "/a", "/b");
    defer result.deinit();

    // Empty result is identical
    try std.testing.expect(result.isIdentical());

    // Add identical file
    const dup1 = try allocator.dupe(u8, "file.txt");
    try result.identical.append(allocator, dup1);
    try std.testing.expect(result.isIdentical());

    // Add file only in A - no longer identical
    const dup2 = try allocator.dupe(u8, "extra.txt");
    try result.only_in_a.append(allocator, dup2);
    try std.testing.expect(!result.isIdentical());
}

test "getSummary" {
    const allocator = std.testing.allocator;
    var result = try types.CompareResult.init(allocator, "/folder_a", "/folder_b");
    defer result.deinit();

    // Add some test data
    const paths = [_][]const u8{ "a.txt", "b.txt", "c.txt" };
    for (paths) |p| {
        const dup = try allocator.dupe(u8, p);
        try result.identical.append(allocator, dup);
    }

    const only_a = try allocator.dupe(u8, "only_a.txt");
    try result.only_in_a.append(allocator, only_a);

    const modified = try allocator.dupe(u8, "changed.txt");
    try result.modified.append(allocator, modified);

    const summary = getSummary(&result);

    try std.testing.expectEqual(@as(u64, 5), summary.files_in_a); // 3 identical + 1 only_a + 1 modified
    try std.testing.expectEqual(@as(u64, 4), summary.files_in_b); // 3 identical + 1 modified
    try std.testing.expectEqual(@as(u64, 3), summary.identical_count);
    try std.testing.expectEqual(@as(u64, 1), summary.only_in_a_count);
    try std.testing.expectEqual(@as(u64, 0), summary.only_in_b_count);
    try std.testing.expectEqual(@as(u64, 1), summary.modified_count);
}

test "CompareResult isIdentical empty" {
    const allocator = std.testing.allocator;
    var result = try types.CompareResult.init(allocator, "/a", "/b");
    defer result.deinit();

    try std.testing.expect(result.isIdentical());
}

test "CompareResult isIdentical with only_in_a" {
    const allocator = std.testing.allocator;
    var result = try types.CompareResult.init(allocator, "/a", "/b");
    defer result.deinit();

    const path = try allocator.dupe(u8, "file.txt");
    try result.only_in_a.append(allocator, path);

    try std.testing.expect(!result.isIdentical());
}

test "CompareResult isIdentical with only_in_b" {
    const allocator = std.testing.allocator;
    var result = try types.CompareResult.init(allocator, "/a", "/b");
    defer result.deinit();

    const path = try allocator.dupe(u8, "file.txt");
    try result.only_in_b.append(allocator, path);

    try std.testing.expect(!result.isIdentical());
}

test "CompareResult isIdentical with modified" {
    const allocator = std.testing.allocator;
    var result = try types.CompareResult.init(allocator, "/a", "/b");
    defer result.deinit();

    const path = try allocator.dupe(u8, "file.txt");
    try result.modified.append(allocator, path);

    try std.testing.expect(!result.isIdentical());
}

test "getSummary all files only in B" {
    const allocator = std.testing.allocator;
    var result = try types.CompareResult.init(allocator, "/folder_a", "/folder_b");
    defer result.deinit();

    const path1 = try allocator.dupe(u8, "only_b1.txt");
    const path2 = try allocator.dupe(u8, "only_b2.txt");
    try result.only_in_b.append(allocator, path1);
    try result.only_in_b.append(allocator, path2);

    const summary = getSummary(&result);

    try std.testing.expectEqual(@as(u64, 0), summary.files_in_a);
    try std.testing.expectEqual(@as(u64, 2), summary.files_in_b);
    try std.testing.expectEqual(@as(u64, 0), summary.identical_count);
    try std.testing.expectEqual(@as(u64, 0), summary.only_in_a_count);
    try std.testing.expectEqual(@as(u64, 2), summary.only_in_b_count);
    try std.testing.expectEqual(@as(u64, 0), summary.modified_count);
}

test "getSummary all identical" {
    const allocator = std.testing.allocator;
    var result = try types.CompareResult.init(allocator, "/folder_a", "/folder_b");
    defer result.deinit();

    const paths = [_][]const u8{ "a.txt", "b.txt" };
    for (paths) |p| {
        const dup = try allocator.dupe(u8, p);
        try result.identical.append(allocator, dup);
    }

    const summary = getSummary(&result);

    try std.testing.expectEqual(@as(u64, 2), summary.files_in_a);
    try std.testing.expectEqual(@as(u64, 2), summary.files_in_b);
    try std.testing.expectEqual(@as(u64, 2), summary.identical_count);
    try std.testing.expectEqual(@as(u64, 0), summary.only_in_a_count);
    try std.testing.expectEqual(@as(u64, 0), summary.only_in_b_count);
    try std.testing.expectEqual(@as(u64, 0), summary.modified_count);
    try std.testing.expect(result.isIdentical());
}

const Scratch = @import("testing_scratch.zig").Scratch;

fn sortedNames(list: []const []const u8, buf: [][]const u8) [][]const u8 {
    const out = buf[0..list.len];
    @memcpy(out, list);
    std.mem.sort([]const u8, out, {}, struct {
        fn lessThan(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.order(u8, x, y) == .lt;
        }
    }.lessThan);
    return out;
}

fn expectNames(list: []const []const u8, want: []const []const u8) !void {
    var buf: [16][]const u8 = undefined;
    const got = sortedNames(list, &buf);
    try std.testing.expectEqual(want.len, got.len);
    for (want, got) |w, g| try std.testing.expectEqualStrings(w, g);
}

test "compare sorts files into identical, modified, only in A and only in B" {
    const allocator = std.testing.allocator;
    var scratch = try Scratch.init(allocator, "compare-sort");
    defer scratch.deinit();
    for ([_][]const u8{ "a", "b", "a/nested", "b/nested" }) |d| try scratch.makeDir(d);
    try scratch.writeFile("a/same.txt", "hello");
    try scratch.writeFile("b/same.txt", "hello");
    try scratch.writeFile("a/nested/deep.txt", "deep");
    try scratch.writeFile("b/nested/deep.txt", "deep");
    try scratch.writeFile("a/bytes.txt", "aaaa"); // one size, other bytes
    try scratch.writeFile("b/bytes.txt", "aaab");
    try scratch.writeFile("a/size.txt", "short");
    try scratch.writeFile("b/size.txt", "longer");
    try scratch.writeFile("a/empty", "");
    try scratch.writeFile("b/empty", "");
    try scratch.writeFile("a/only_a.txt", "a");
    try scratch.writeFile("b/only_b.txt", "b");
    const a = try scratch.join("a");
    defer allocator.free(a);
    const b = try scratch.join("b");
    defer allocator.free(b);

    var comparator = FolderComparator.init(allocator, .{ .min_size = 0, .threads = 3 });
    var result = try comparator.compare(a, b);
    defer result.deinit();

    try expectNames(result.identical.items, &.{ "empty", "nested/deep.txt", "same.txt" });
    try expectNames(result.modified.items, &.{ "bytes.txt", "size.txt" });
    try expectNames(result.only_in_a.items, &.{"only_a.txt"});
    try expectNames(result.only_in_b.items, &.{"only_b.txt"});
    try std.testing.expect(!result.isIdentical());
}

test "a file of many ranges is compared range by range, to its first and last byte" {
    const allocator = std.testing.allocator;
    var scratch = try Scratch.init(allocator, "compare-ranges");
    defer scratch.deinit();
    try scratch.makeDir("a");
    try scratch.makeDir("b");

    // Ten ranges and a bit, so the last range is short.
    var data: [10 * 4096 + 123]u8 = undefined;
    for (&data, 0..) |*x, i| x.* = @truncate(i *% 31 +% 7);
    try scratch.writeFile("a/same.bin", &data);
    try scratch.writeFile("b/same.bin", &data);
    try scratch.writeFile("a/last.bin", &data);
    try scratch.writeFile("a/first.bin", &data);
    data[data.len - 1] ^= 1;
    try scratch.writeFile("b/last.bin", &data);
    data[data.len - 1] ^= 1;
    data[0] ^= 1;
    try scratch.writeFile("b/first.bin", &data);
    const a = try scratch.join("a");
    defer allocator.free(a);
    const b = try scratch.join("b");
    defer allocator.free(b);

    var comparator = FolderComparator.init(allocator, .{ .min_size = 0, .threads = 4 });
    comparator.range_size = 4096;
    var result = try comparator.compare(a, b);
    defer result.deinit();

    try expectNames(result.identical.items, &.{"same.bin"});
    try expectNames(result.modified.items, &.{ "first.bin", "last.bin" });
}

test "every path is compared: two names for one file match two separate copies" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var scratch = try Scratch.init(allocator, "compare-links");
    defer scratch.deinit();
    try scratch.makeDir("a");
    try scratch.makeDir("b");
    try scratch.writeFile("a/x", "same content");
    try scratch.hardLink("a/x", "a/y");
    try scratch.writeFile("b/x", "same content");
    try scratch.writeFile("b/y", "same content");
    const a = try scratch.join("a");
    defer allocator.free(a);
    const b = try scratch.join("b");
    defer allocator.free(b);

    var comparator = FolderComparator.init(allocator, .{ .min_size = 0 });
    var result = try comparator.compare(a, b);
    defer result.deinit();
    try expectNames(result.identical.items, &.{ "x", "y" });
    try std.testing.expect(result.isIdentical());
}

test "a file whose size is not the one the walk saw never matches" {
    // What a permanent folder delete relies on: a file that grew or shrank
    // after the walk is not "identical", whatever its first bytes hold.
    const allocator = std.testing.allocator;
    var scratch = try Scratch.init(allocator, "compare-stale");
    defer scratch.deinit();
    try scratch.writeFile("x", "same bytes");
    try scratch.writeFile("y", "same bytes, and then some more");
    const x = try scratch.join("x");
    defer allocator.free(x);
    const y = try scratch.join("y");
    defer allocator.free(y);

    var buf_a: [64]u8 = undefined;
    var buf_b: [64]u8 = undefined;
    // The walk saw both at 10 bytes; y has grown since.
    const stale: Pair = .{ .rel = "f", .a = .{ .path = x, .size = 10 }, .b = .{ .path = y, .size = 10 } };
    try std.testing.expect(!try rangeMatches(&stale, .{ .pair = 0, .start = 0, .end = 10 }, &buf_a, &buf_b, null));
    const fresh: Pair = .{ .rel = "f", .a = .{ .path = x, .size = 10 }, .b = .{ .path = x, .size = 10 } };
    try std.testing.expect(try rangeMatches(&fresh, .{ .pair = 0, .start = 0, .end = 10 }, &buf_a, &buf_b, null));
}

test "a cancelled comparison stops with error.Cancelled" {
    const allocator = std.testing.allocator;
    var scratch = try Scratch.init(allocator, "compare-cancel");
    defer scratch.deinit();
    try scratch.makeDir("a");
    try scratch.makeDir("b");
    try scratch.writeFile("a/f", "data");
    try scratch.writeFile("b/f", "data");
    const a = try scratch.join("a");
    defer allocator.free(a);
    const b = try scratch.join("b");
    defer allocator.free(b);

    var monitor: types.Monitor = .{};
    monitor.cancel();
    var comparator = FolderComparator.init(allocator, .{ .min_size = 0, .monitor = &monitor });
    try std.testing.expectError(error.Cancelled, comparator.compare(a, b));
}


test "a folder given through a link is compared, and reported, by its real path" {
    const allocator = std.testing.allocator;
    var scratch = try Scratch.init(allocator, "compare-link");
    defer scratch.deinit();
    for ([_][]const u8{ "a", "b" }) |d| try scratch.makeDir(d);
    try scratch.writeFile("a/same.txt", "hello");
    try scratch.writeFile("b/same.txt", "hello");
    try scratch.symLink("a", "via-link");
    const link = try scratch.join("via-link");
    defer allocator.free(link);
    const a = try scratch.join("a");
    defer allocator.free(a);
    const b = try scratch.join("b");
    defer allocator.free(b);

    var comparator = FolderComparator.init(allocator, .{ .min_size = 0, .threads = 2 });
    var result = try comparator.compare(link, b);
    defer result.deinit();
    try std.testing.expectEqualStrings(a, result.folder_a);
    try expectNames(result.identical.items, &.{"same.txt"});
    try std.testing.expect(result.isIdentical());
}
