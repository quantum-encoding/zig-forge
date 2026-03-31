//! Duplicate file finder
//!
//! Algorithm:
//! 1. Walk directories → collect files with metadata
//! 2. Group by size (files with unique sizes can't be duplicates)
//! 3. Quick hash (first 4KB) for fast rejection - PARALLEL
//! 4. Full hash (BLAKE3) for confirmation - PARALLEL
//! 5. Group duplicates
//!
//! Performance: Uses parallel hashing to saturate NVMe bandwidth.
//! NVMe drives perform best with high queue depth (32-64 concurrent I/O).

const std = @import("std");
const types = @import("types.zig");
const hasher = @import("hasher.zig");
const fast_walker = @import("fast_walker.zig");
const parallel = @import("parallel.zig");
const builtin = @import("builtin");

/// Cross-platform timestamp for elapsed time measurement using clock_gettime
const Timestamp = struct {
    ts: std.c.timespec,

    fn now() Timestamp {
        var ts: std.c.timespec = undefined;
        _ = std.c.clock_gettime(.MONOTONIC, &ts);
        return .{ .ts = ts };
    }

    fn elapsedNs(end: Timestamp, start: Timestamp) u64 {
        const end_ns: i128 = @as(i128, end.ts.sec) * 1_000_000_000 + end.ts.nsec;
        const start_ns: i128 = @as(i128, start.ts.sec) * 1_000_000_000 + start.ts.nsec;
        const diff = end_ns - start_ns;
        return if (diff > 0) @intCast(diff) else 0;
    }
};

/// Duplicate file finder
pub const DupeFinder = struct {
    allocator: std.mem.Allocator,
    config: types.Config,
    /// All files scanned
    files: std.ArrayListUnmanaged(types.FileEntry),
    /// Duplicate groups
    groups: std.ArrayListUnmanaged(types.DuplicateGroup),
    /// Progress callback
    progress_callback: ?types.ProgressCallback,
    /// Current progress
    progress: types.Progress,
    /// Summary statistics
    summary: types.DuplicateSummary,
    /// File hasher
    file_hasher: hasher.FileHasher,

    pub fn init(allocator: std.mem.Allocator, config: types.Config) DupeFinder {
        return .{
            .allocator = allocator,
            .config = config,
            .files = .empty,
            .groups = .empty,
            .progress_callback = null,
            .progress = .{
                .phase = .scanning,
                .files_processed = 0,
                .files_total = 0,
                .bytes_processed = 0,
                .bytes_total = 0,
                .current_file = null,
            },
            .summary = std.mem.zeroes(types.DuplicateSummary),
            .file_hasher = hasher.FileHasher.init(config.hash_algorithm),
        };
    }

    pub fn deinit(self: *DupeFinder) void {
        for (self.files.items) |*f| {
            f.deinit(self.allocator);
        }
        self.files.deinit(self.allocator);

        for (self.groups.items) |*g| {
            g.deinit();
        }
        self.groups.deinit(self.allocator);
    }

    /// Set progress callback
    pub fn setProgressCallback(self: *DupeFinder, callback: types.ProgressCallback) void {
        self.progress_callback = callback;
    }

    /// Scan directories for duplicates
    pub fn scan(self: *DupeFinder, paths: []const []const u8) !void {
        const start_time = Timestamp.now();

        // Phase 1: Walk directories using fast_walker (statx optimization)
        self.updateProgress(.scanning, 0, 0, null);

        var total_size: u64 = 0;

        for (paths) |path| {
            var fw = fast_walker.FastWalker.init(self.allocator);
            defer fw.deinit();

            // Configure fast walker
            fw.setSizeFilter(self.config.min_size, self.config.max_size);
            fw.setIncludeHidden(self.config.include_hidden);
            fw.enableHardLinkDetection();
            fw.enableArenaAllocator();

            // Walk this path
            fw.walk(path) catch |err| {
                std.debug.print("Warning: Failed to scan {s}: {}\n", .{ path, err });
                continue;
            };

            total_size += fw.stats.total_size;

            // Convert to FileEntry and transfer ownership
            var entries = try fw.toFileEntries(self.allocator);
            defer entries.deinit(self.allocator);

            for (entries.items) |entry| {
                try self.files.append(self.allocator, entry);
            }
        }

        self.summary.files_scanned = self.files.items.len;
        self.summary.bytes_scanned = total_size;

        if (self.files.items.len == 0) {
            self.updateProgress(.done, 0, 0, null);
            return;
        }

        // Phase 2: Group by size
        self.updateProgress(.size_grouping, 0, self.files.items.len, null);
        var size_groups = try self.groupBySize();
        defer {
            var iter = size_groups.valueIterator();
            while (iter.next()) |g| g.deinit();
            size_groups.deinit();
        }

        // Phase 3: Quick hash candidates
        self.updateProgress(.quick_hashing, 0, self.countCandidates(&size_groups), null);
        try self.quickHashGroups(&size_groups);

        // Phase 4: Full hash remaining candidates
        self.updateProgress(.full_hashing, 0, self.countCandidates(&size_groups), null);
        try self.fullHashGroups(&size_groups);

        // Phase 5: Build duplicate groups
        self.updateProgress(.reporting, 0, 0, null);
        try self.buildDuplicateGroups(&size_groups);

        // Calculate summary
        const end_time = Timestamp.now();
        self.summary.scan_time_ns = end_time.elapsedNs(start_time);
        self.summary.duplicate_groups = self.groups.items.len;

        var total_dupes: u64 = 0;
        var total_savings: u64 = 0;
        for (self.groups.items) |*g| {
            total_dupes += g.count() - 1; // Exclude one "original"
            total_savings += g.savings;
        }
        self.summary.duplicate_files = total_dupes;
        self.summary.space_savings = total_savings;

        self.updateProgress(.done, self.files.items.len, self.files.items.len, null);
    }

    /// Get duplicate groups
    pub fn getGroups(self: *const DupeFinder) []types.DuplicateGroup {
        return self.groups.items;
    }

    /// Get summary statistics
    pub fn getSummary(self: *const DupeFinder) *const types.DuplicateSummary {
        return &self.summary;
    }

    // ========================================================================
    // Private implementation
    // ========================================================================

    const SizeGroup = struct {
        size: u64,
        indices: std.ArrayListUnmanaged(usize),
        allocator: std.mem.Allocator,

        fn init(allocator: std.mem.Allocator, size: u64) SizeGroup {
            return .{
                .size = size,
                .indices = .empty,
                .allocator = allocator,
            };
        }

        fn deinit(self: *SizeGroup) void {
            self.indices.deinit(self.allocator);
        }
    };

    fn groupBySize(self: *DupeFinder) !std.AutoHashMap(u64, SizeGroup) {
        var groups = std.AutoHashMap(u64, SizeGroup).init(self.allocator);
        errdefer {
            var iter = groups.valueIterator();
            while (iter.next()) |g| g.deinit();
            groups.deinit();
        }

        for (self.files.items, 0..) |entry, idx| {
            const gop = try groups.getOrPut(entry.size);
            if (!gop.found_existing) {
                gop.value_ptr.* = SizeGroup.init(self.allocator, entry.size);
            }
            try gop.value_ptr.indices.append(self.allocator, idx);

            self.progress.files_processed = idx + 1;
            if (self.progress_callback) |cb| cb(&self.progress);
        }

        // Remove groups with only one file (can't be duplicates)
        var to_remove: std.ArrayListUnmanaged(u64) = .empty;
        defer to_remove.deinit(self.allocator);

        var iter = groups.iterator();
        while (iter.next()) |kv| {
            if (kv.value_ptr.indices.items.len < 2) {
                kv.value_ptr.deinit();
                try to_remove.append(self.allocator, kv.key_ptr.*);
            }
        }

        for (to_remove.items) |size| {
            _ = groups.remove(size);
        }

        return groups;
    }

    fn countCandidates(self: *DupeFinder, size_groups: *const std.AutoHashMap(u64, SizeGroup)) u64 {
        _ = self;
        var count: u64 = 0;
        var iter = size_groups.valueIterator();
        while (iter.next()) |g| {
            count += g.indices.items.len;
        }
        return count;
    }

    fn quickHashGroups(self: *DupeFinder, size_groups: *std.AutoHashMap(u64, SizeGroup)) !void {
        // Collect all file indices that need quick hashing
        var indices_to_hash: std.ArrayListUnmanaged(usize) = .empty;
        defer indices_to_hash.deinit(self.allocator);

        var iter = size_groups.valueIterator();
        while (iter.next()) |group| {
            // Only quick hash files larger than quick_hash_size
            if (group.size <= self.config.quick_hash_size) {
                // Small files - skip quick hash, go straight to full hash
                continue;
            }

            for (group.indices.items) |idx| {
                try indices_to_hash.append(self.allocator, idx);
            }
        }

        if (indices_to_hash.items.len == 0) return;

        // Hash in parallel
        const thread_count = self.config.getThreadCount();
        try parallel.parallelQuickHash(
            self.allocator,
            self.files.items,
            indices_to_hash.items,
            self.config.quick_hash_size,
            self.config.hash_algorithm,
            thread_count,
            self.progress_callback,
        );
    }

    fn fullHashGroups(self: *DupeFinder, size_groups: *std.AutoHashMap(u64, SizeGroup)) !void {
        // Collect all file indices that need full hashing
        // Only hash files with matching quick hashes (potential duplicates)
        var indices_to_hash: std.ArrayListUnmanaged(usize) = .empty;
        defer indices_to_hash.deinit(self.allocator);

        var iter = size_groups.valueIterator();
        while (iter.next()) |group| {
            // Build quick hash sub-groups
            var quick_groups = std.AutoHashMap([32]u8, std.ArrayListUnmanaged(usize)).init(self.allocator);
            defer {
                var qiter = quick_groups.valueIterator();
                while (qiter.next()) |list| list.deinit(self.allocator);
                quick_groups.deinit();
            }

            for (group.indices.items) |idx| {
                const entry = &self.files.items[idx];

                // Use quick hash if available, otherwise use zero hash (will be unique)
                const key = entry.quick_hash orelse [_]u8{0} ** 32;

                const gop = try quick_groups.getOrPut(key);
                if (!gop.found_existing) {
                    gop.value_ptr.* = .empty;
                }
                try gop.value_ptr.append(self.allocator, idx);
            }

            // Collect indices that have matching quick hashes (potential duplicates)
            var qiter = quick_groups.valueIterator();
            while (qiter.next()) |indices| {
                if (indices.items.len < 2) continue; // Skip unique quick hashes

                for (indices.items) |idx| {
                    try indices_to_hash.append(self.allocator, idx);
                }
            }
        }

        if (indices_to_hash.items.len == 0) return;

        // Hash in parallel
        const thread_count = self.config.getThreadCount();
        try parallel.parallelFullHash(
            self.allocator,
            self.files.items,
            indices_to_hash.items,
            self.config.hash_algorithm,
            thread_count,
            self.progress_callback,
        );
    }

    fn buildDuplicateGroups(self: *DupeFinder, size_groups: *std.AutoHashMap(u64, SizeGroup)) !void {
        // Group by full hash
        var hash_groups = std.AutoHashMap([32]u8, std.ArrayListUnmanaged(usize)).init(self.allocator);
        defer {
            var iter = hash_groups.valueIterator();
            while (iter.next()) |list| list.deinit(self.allocator);
            hash_groups.deinit();
        }

        var sg_iter = size_groups.valueIterator();
        while (sg_iter.next()) |sg| {
            for (sg.indices.items) |idx| {
                const entry = &self.files.items[idx];

                // Only include files with computed hashes
                const hash_key = entry.hash orelse continue;

                const gop = try hash_groups.getOrPut(hash_key);
                if (!gop.found_existing) {
                    gop.value_ptr.* = .empty;
                }
                try gop.value_ptr.append(self.allocator, idx);
            }
        }

        // Build DuplicateGroup for each group with 2+ files
        var hg_iter = hash_groups.iterator();
        while (hg_iter.next()) |kv| {
            if (kv.value_ptr.items.len < 2) continue;

            const first_idx = kv.value_ptr.items[0];
            const size = self.files.items[first_idx].size;

            var group = types.DuplicateGroup.init(self.allocator, size, kv.key_ptr.*);

            for (kv.value_ptr.items) |idx| {
                const entry = &self.files.items[idx];
                try group.addFileWithInfo(entry.path, entry.mtime);
            }

            try self.groups.append(self.allocator, group);
        }

        // Sort groups by savings (largest first)
        std.mem.sort(types.DuplicateGroup, self.groups.items, {}, struct {
            fn cmp(_: void, a: types.DuplicateGroup, b: types.DuplicateGroup) bool {
                return a.savings > b.savings;
            }
        }.cmp);
    }

    fn updateProgress(self: *DupeFinder, phase: types.Progress.Phase, processed: u64, total: u64, file: ?[]const u8) void {
        self.progress.phase = phase;
        self.progress.files_processed = processed;
        self.progress.files_total = total;
        self.progress.current_file = file;

        if (self.progress_callback) |cb| cb(&self.progress);
    }
};

/// Convenience function to find duplicates
pub fn findDuplicates(
    allocator: std.mem.Allocator,
    paths: []const []const u8,
    config: types.Config,
) !DupeFinder {
    var finder = DupeFinder.init(allocator, config);
    try finder.scan(paths);
    return finder;
}

// ============================================================================
// Tests
// ============================================================================

test "DupeFinder initialization" {
    const allocator = std.testing.allocator;
    var finder = DupeFinder.init(allocator, .{});
    defer finder.deinit();

    try std.testing.expectEqual(@as(usize, 0), finder.getGroups().len);
}

test "DupeFinder empty scan" {
    const allocator = std.testing.allocator;
    var finder = DupeFinder.init(allocator, .{});
    defer finder.deinit();

    // Scan non-existent path - should handle gracefully
    finder.scan(&.{"/nonexistent/path/zdedupe_test_12345"}) catch {};

    const summary = finder.getSummary();
    try std.testing.expectEqual(@as(u64, 0), summary.duplicate_groups);
}
