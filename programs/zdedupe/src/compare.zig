//! Folder comparison module
//!
//! Compares two directories and categorizes files into:
//! - Identical: Same relative path, same content
//! - Only in A: Files only in first folder
//! - Only in B: Files only in second folder
//! - Modified: Same relative path, different content

const std = @import("std");
const types = @import("types.zig");
const hasher = @import("hasher.zig");
const walker = @import("walker.zig");
const libc = std.c;
const builtin = @import("builtin");

// Cross-platform Stat structure
const Stat = switch (builtin.os.tag) {
    .linux => extern struct {
        dev: u64,
        ino: u64,
        nlink: u64,
        mode: u32,
        uid: u32,
        gid: u32,
        __pad0: u32 = 0,
        rdev: u64,
        size: i64,
        blksize: i64,
        blocks: i64,
        atim: libc.timespec,
        mtim: libc.timespec,
        ctim: libc.timespec,
        __unused: [3]i64 = .{ 0, 0, 0 },
    },
    .macos, .ios, .tvos, .watchos => extern struct {
        dev: i32,
        mode: u16,
        nlink: u16,
        ino: u64,
        uid: u32,
        gid: u32,
        rdev: i32,
        atim: libc.timespec,
        mtim: libc.timespec,
        ctim: libc.timespec,
        birthtim: libc.timespec,
        size: i64,
        blocks: i64,
        blksize: i32,
        flags: u32,
        gen: u32,
        lspare: i32,
        qspare: [2]i64,
    },
    else => libc.Stat,
};

extern "c" fn stat(path: [*:0]const u8, buf: *Stat) c_int;

/// Folder comparator
pub const FolderComparator = struct {
    allocator: std.mem.Allocator,
    config: types.Config,
    file_hasher: hasher.FileHasher,
    /// Progress callback
    progress_callback: ?types.ProgressCallback,
    /// Current progress
    progress: types.Progress,

    pub fn init(allocator: std.mem.Allocator, config: types.Config) FolderComparator {
        return .{
            .allocator = allocator,
            .config = config,
            .file_hasher = hasher.FileHasher.init(config.hash_algorithm),
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

    /// Compare two folders
    pub fn compare(self: *FolderComparator, folder_a: []const u8, folder_b: []const u8) !types.CompareResult {
        var result = try types.CompareResult.init(self.allocator, folder_a, folder_b);
        errdefer result.deinit();

        // Phase 1: Walk folder A
        self.updateProgress(.scanning, 0, 0, null);
        var files_a = try self.walkAndIndex(folder_a);
        defer {
            // Free both keys (rel_path) and values (abs_path)
            var iter = files_a.iterator();
            while (iter.next()) |kv| {
                self.allocator.free(kv.key_ptr.*);
                self.allocator.free(kv.value_ptr.path);
            }
            files_a.deinit();
        }

        // Phase 2: Walk folder B
        var files_b = try self.walkAndIndex(folder_b);
        defer {
            // Free both keys (rel_path) and values (abs_path)
            var iter = files_b.iterator();
            while (iter.next()) |kv| {
                self.allocator.free(kv.key_ptr.*);
                self.allocator.free(kv.value_ptr.path);
            }
            files_b.deinit();
        }

        // Calculate total for progress
        const total_files = files_a.count() + files_b.count();
        self.updateProgress(.full_hashing, 0, total_files, null);

        var processed: u64 = 0;

        // Phase 3: Compare files
        // Check all files in A against B
        var iter_a = files_a.iterator();
        while (iter_a.next()) |kv| {
            const rel_path = kv.key_ptr.*;
            const entry_a = kv.value_ptr.*;

            processed += 1;
            self.progress.files_processed = processed;
            self.progress.current_file = entry_a.path;
            if (self.progress_callback) |cb| cb(&self.progress);

            if (files_b.get(rel_path)) |entry_b| {
                // File exists in both - compare content
                const same = try self.compareFiles(entry_a.path, entry_b.path);
                const rel_copy = try self.allocator.dupe(u8, rel_path);

                if (same) {
                    try result.identical.append(self.allocator, rel_copy);
                } else {
                    try result.modified.append(self.allocator, rel_copy);
                }
            } else {
                // File only in A
                const rel_copy = try self.allocator.dupe(u8, rel_path);
                try result.only_in_a.append(self.allocator, rel_copy);
            }
        }

        // Check files only in B
        var iter_b = files_b.iterator();
        while (iter_b.next()) |kv| {
            const rel_path = kv.key_ptr.*;
            const entry_b = kv.value_ptr.*;

            processed += 1;
            self.progress.files_processed = processed;
            self.progress.current_file = entry_b.path;
            if (self.progress_callback) |cb| cb(&self.progress);

            if (!files_a.contains(rel_path)) {
                // File only in B
                const rel_copy = try self.allocator.dupe(u8, rel_path);
                try result.only_in_b.append(self.allocator, rel_copy);
            }
        }

        self.updateProgress(.done, total_files, total_files, null);

        return result;
    }

    /// Internal file entry for indexing
    const IndexEntry = struct {
        path: []const u8, // Full absolute path
        size: u64,
    };

    /// Walk directory and build index by relative path
    fn walkAndIndex(self: *FolderComparator, base_path: []const u8) !std.StringHashMap(IndexEntry) {
        var index = std.StringHashMap(IndexEntry).init(self.allocator);
        errdefer {
            var iter = index.valueIterator();
            while (iter.next()) |entry| {
                self.allocator.free(entry.path);
            }
            index.deinit();
        }

        var w = walker.Walker.init(self.allocator, self.config);
        defer w.deinit();

        var walk_result = try w.walk(base_path);
        defer walk_result.deinit(self.allocator);

        // Transfer files to index with relative paths as keys
        // Note: walk_result.deinit() will free the original entry.path strings,
        // so we make copies for the index
        for (walk_result.files.items) |entry| {
            const rel_path = walker.Walker.relativePath(base_path, entry.path);
            const rel_copy = try self.allocator.dupe(u8, rel_path);
            errdefer self.allocator.free(rel_copy);

            // Keep the absolute path for later hashing
            const abs_copy = try self.allocator.dupe(u8, entry.path);
            errdefer self.allocator.free(abs_copy);

            const gop = try index.getOrPut(rel_copy);
            if (gop.found_existing) {
                // Duplicate relative path (shouldn't happen normally)
                self.allocator.free(rel_copy);
                self.allocator.free(abs_copy);
            } else {
                gop.value_ptr.* = .{
                    .path = abs_copy,
                    .size = entry.size,
                };
            }
        }

        // walk_result.deinit() will be called by defer and free the original paths
        return index;
    }

    /// Compare two files for identical content
    fn compareFiles(self: *FolderComparator, path_a: []const u8, path_b: []const u8) !bool {
        // Quick size check first using libc stat
        const size_a = getFileSize(self.allocator, path_a) orelse return false;
        const size_b = getFileSize(self.allocator, path_b) orelse return false;

        if (size_a != size_b) {
            return false;
        }

        // Empty files are identical
        if (size_a == 0) {
            return true;
        }

        // Hash both files and compare
        const hash_a = self.file_hasher.hashFile(path_a) catch return false;
        const hash_b = self.file_hasher.hashFile(path_b) catch return false;

        return std.mem.eql(u8, &hash_a, &hash_b);
    }

    fn updateProgress(self: *FolderComparator, phase: types.Progress.Phase, processed: u64, total: u64, file: ?[]const u8) void {
        self.progress.phase = phase;
        self.progress.files_processed = processed;
        self.progress.files_total = total;
        self.progress.current_file = file;

        if (self.progress_callback) |cb| cb(&self.progress);
    }
};

fn getFileSize(allocator: std.mem.Allocator, path: []const u8) ?u64 {
    const path_z = allocator.dupeZ(u8, path) catch return null;
    defer allocator.free(path_z);

    var stat_buf: Stat = undefined;
    if (stat(path_z.ptr, &stat_buf) != 0) {
        return null;
    }
    return @intCast(stat_buf.size);
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
