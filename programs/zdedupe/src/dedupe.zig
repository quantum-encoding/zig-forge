//! Duplicate file finder
//!
//! Algorithm:
//! 1. Walk directories → collect files with metadata
//! 2. Group by size (files with unique sizes can't be duplicates)
//! 3. Quick hash (first 4KB) for fast rejection - PARALLEL
//! 4. Full hash (BLAKE3) for confirmation - PARALLEL
//! 5. Group duplicates
//! 6. Optionally roll file identities up into directory identities (dirs.zig)
//!
//! Performance: Uses parallel hashing to saturate NVMe bandwidth.
//! NVMe drives perform best with high queue depth (32-64 concurrent I/O).

const std = @import("std");
const types = @import("types.zig");
const hasher = @import("hasher.zig");
const fast_walker = @import("fast_walker.zig");
const parallel = @import("parallel.zig");
const dirs = @import("dirs.zig");
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
    /// Paths that could not be walked (unreadable, missing, not a directory).
    /// Counted rather than printed: this type is linked into GUI apps over the
    /// C FFI, where a write to stderr is invisible at best.
    failed_paths: u64,
    /// Directory-level results; present only when `config.analyze_dirs`.
    dir_analysis: ?dirs.Analysis,
    /// Owns every path in `files` (taken over from the walker), so each path
    /// exists once. Empty until a scan has collected files.
    path_storage: fast_walker.StringStorage,

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
            .failed_paths = 0,
            .dir_analysis = null,
            .path_storage = .{},
        };
    }

    pub fn deinit(self: *DupeFinder) void {
        // Paths are borrowed from `path_storage`; there is nothing per file to free.
        self.files.deinit(self.allocator);
        self.path_storage.deinit(self.allocator);

        for (self.groups.items) |*g| {
            g.deinit();
        }
        self.groups.deinit(self.allocator);

        if (self.dir_analysis) |*analysis| analysis.deinit();
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

        // One walker for every root: its inode table is what stops a file
        // reachable from two roots being reported as a duplicate of itself.
        var fw = fast_walker.FastWalker.init(self.allocator);
        defer fw.deinit();

        fw.setMonitor(self.config.monitor);
        fw.setIncludeHidden(self.config.include_hidden);
        fw.setExcludes(self.config.excludes);
        fw.setExcludePaths(self.config.exclude_paths);
        fw.setExcludeCacheDirs(self.config.exclude_cache_dirs);
        fw.setOneFilesystem(self.config.one_filesystem);
        fw.setSkipAppLibraries(self.config.skip_app_libraries);
        fw.enableHardLinkDetection();
        // The walk is syscall-bound, so it uses the same parallelism as hashing.
        fw.setThreads(self.config.getThreadCount());

        if (self.config.analyze_dirs) {
            // A directory verdict has to rest on everything the directory
            // holds, so the size window moves from the walk to the reported
            // groups (see buildDuplicateGroups). Symlinks are recorded, not
            // followed: followed, a link to a sibling makes that sibling look
            // like a second copy of itself.
            fw.enableTreeRecording();
            fw.setSizeFilter(0, 0);
            fw.setFollowSymlinks(false);
        } else {
            fw.setSizeFilter(self.config.min_size, self.config.max_size);
            fw.setFollowSymlinks(self.config.follow_symlinks);
        }

        const roots = try self.coveringRoots(paths);
        defer self.allocator.free(roots);
        self.summary.overlapping_roots = paths.len - roots.len;

        for (roots) |path| {
            fw.walk(path) catch |err| switch (err) {
                error.OutOfMemory, error.Cancelled => return err,
                else => self.failed_paths += 1,
            };
        }

        // Hard links and cross-worker directory verdicts are settled here,
        // once, across every root.
        try fw.finish();

        // Convert to FileEntry, borrowing the walker's path strings, then take
        // over the storage that holds them. Indices are kept: `FileEntry.link_of`
        // refers to positions in the walker's list. The walker's directory and
        // link records point into the same storage and stay valid below.
        std.debug.assert(self.files.items.len == 0 and self.path_storage.arenas.items.len == 0);
        self.files.deinit(self.allocator);
        self.files = try fw.toFileEntriesBorrowed(self.allocator);
        self.path_storage = fw.takeStrings();
        // The walker's own per-file records are dead weight from here on
        // (its directory and link records are still needed for analysis).
        fw.files.clearAndFree(self.allocator);

        self.summary.excluded_entries = fw.stats.excluded;
        self.summary.bytes_scanned = fw.stats.total_size;

        // Extra hard links are carried for directory analysis only.
        self.summary.files_scanned = fw.stats.files_found;

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

        try self.checkCancelled();

        // Phase 4: Full hash remaining candidates
        self.updateProgress(.full_hashing, 0, self.countCandidates(&size_groups), null);
        try self.fullHashGroups(&size_groups);
        // Hashes missing because the scan was stopped must not be read as
        // "these files are unique": never build results from a cancelled run.
        try self.checkCancelled();

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

        // Phase 6: Directory analysis (no I/O - reuses the hashes above)
        if (self.config.analyze_dirs) {
            self.dir_analysis = try dirs.analyze(
                self.allocator,
                self.files.items,
                fw.dirs.items,
                fw.links.items,
                self.config.hash_algorithm,
                .{},
            );
        }

        self.updateProgress(.done, self.files.items.len, self.files.items.len, null);
    }

    /// Get duplicate groups
    pub fn getGroups(self: *const DupeFinder) []types.DuplicateGroup {
        return self.groups.items;
    }

    /// Directory-level results, or null unless `config.analyze_dirs` was set.
    pub fn getDirAnalysis(self: *const DupeFinder) ?*const dirs.Analysis {
        return if (self.dir_analysis) |*analysis| analysis else null;
    }

    /// Number of input paths that could not be walked at all.
    pub fn getFailedPathCount(self: *const DupeFinder) u64 {
        return self.failed_paths;
    }

    /// Get summary statistics
    pub fn getSummary(self: *const DupeFinder) *const types.DuplicateSummary {
        return &self.summary;
    }

    // ========================================================================
    // Private implementation
    // ========================================================================

    /// The subset of `paths` (order kept) left after dropping every root that
    /// another root already covers — the same directory given twice, or a
    /// directory inside another. Walking both would list each file under the
    /// inner root twice, and the two entries would then be reported as
    /// duplicates of each other: one file, offered for deletion as its own
    /// copy. Compared by canonical path, so a symlinked spelling of a root is
    /// caught too. Caller frees the slice (not the strings).
    fn coveringRoots(self: *DupeFinder, paths: []const []const u8) ![]const []const u8 {
        const canonical = try self.allocator.alloc(?[]u8, paths.len);
        @memset(canonical, null);
        defer {
            for (canonical) |c| if (c) |owned| self.allocator.free(owned);
            self.allocator.free(canonical);
        }
        for (paths, canonical) |path, *slot| {
            slot.* = try canonicalPath(self.allocator, path);
        }

        var kept: std.ArrayListUnmanaged([]const u8) = .empty;
        errdefer kept.deinit(self.allocator);

        outer: for (paths, 0..) |path, i| {
            // Unresolvable (missing, unreadable): keep it so the walk fails
            // and the failure is counted where callers already look for it.
            const mine = canonical[i] orelse {
                try kept.append(self.allocator, path);
                continue;
            };
            for (canonical, 0..) |maybe_other, j| {
                const other = maybe_other orelse continue;
                if (i == j) continue;
                // zig-lens-ignore: EQL-FOR-SECRETS filesystem paths, not secrets
                const same = std.mem.eql(u8, mine, other);
                // Of two identical roots the first one wins.
                if (same and j < i) continue :outer;
                if (!same and isInside(mine, other)) continue :outer;
            }
            try kept.append(self.allocator, path);
        }
        return kept.toOwnedSlice(self.allocator);
    }

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
            // An extra hard link is the same file, not a copy of it.
            if (entry.link_of != null) continue;

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
            self.config.monitor,
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
            self.config.monitor,
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

            // Under directory analysis the walk ignored the size window (see
            // scan); it is applied here so the file groups are unchanged.
            if (!self.config.sizeInRange(size)) continue;

            var group = types.DuplicateGroup.init(self.allocator, size, kv.key_ptr.*);

            // Oldest first, path as the tie-break: consumers present the first
            // file as the one to keep, and "keep the oldest" should not depend
            // on the order the walk happened to visit things in.
            std.sort.heap(usize, kv.value_ptr.items, self.files.items, struct {
                fn lessThan(files: []types.FileEntry, lhs: usize, rhs: usize) bool {
                    if (files[lhs].mtime != files[rhs].mtime) return files[lhs].mtime < files[rhs].mtime;
                    return std.mem.order(u8, files[lhs].path, files[rhs].path) == .lt;
                }
            }.lessThan);

            for (kv.value_ptr.items) |idx| {
                const entry = &self.files.items[idx];
                try group.addFileWithInfo(entry.path, entry.mtime);
            }

            try self.groups.append(self.allocator, group);
        }

        // Sort groups by savings (largest first). The hash breaks ties so the
        // order is total: a parallel walk reports files in no fixed order, and
        // the same disk must still produce the same report every time.
        std.sort.heap(types.DuplicateGroup, self.groups.items, {}, struct {
            fn cmp(_: void, a: types.DuplicateGroup, b: types.DuplicateGroup) bool {
                if (a.savings != b.savings) return a.savings > b.savings;
                return std.mem.order(u8, &a.hash, &b.hash) == .lt;
            }
        }.cmp);
    }

    fn checkCancelled(self: *const DupeFinder) error{Cancelled}!void {
        if (self.config.monitor) |m| {
            if (m.cancelled()) return error.Cancelled;
        }
    }

    fn updateProgress(self: *DupeFinder, phase: types.Progress.Phase, processed: u64, total: u64, file: ?[]const u8) void {
        if (self.config.monitor) |m| {
            m.enter(switch (phase) {
                .scanning => .scanning,
                .size_grouping => .size_grouping,
                .quick_hashing => .quick_hashing,
                .full_hashing => .full_hashing,
                .reporting => .analyzing,
                .done => .done,
            }, total);
        }
        self.progress.phase = phase;
        self.progress.files_processed = processed;
        self.progress.files_total = total;
        self.progress.current_file = file;

        if (self.progress_callback) |cb| cb(&self.progress);
    }
};

/// Canonical absolute form of `path` (symlinks resolved), or null if it cannot
/// be resolved. Caller frees.
fn canonicalPath(allocator: std.mem.Allocator, path: []const u8) !?[]u8 {
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);

    var buf: [std.c.PATH_MAX]u8 = undefined;
    const resolved = std.c.realpath(path_z.ptr, &buf) orelse return null;
    return try allocator.dupe(u8, std.mem.span(resolved));
}

/// True if canonical path `inner` lies strictly inside canonical path `outer`.
fn isInside(inner: []const u8, outer: []const u8) bool {
    // zig-lens-ignore: EQL-FOR-SECRETS filesystem paths, not secrets
    if (std.mem.eql(u8, outer, "/")) return inner.len > 1;
    return inner.len > outer.len + 1 and
        inner[outer.len] == '/' and
        std.mem.startsWith(u8, inner, outer);
}

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
    // The failure is reported through the API, not printed to stderr.
    try std.testing.expectEqual(@as(u64, 1), finder.getFailedPathCount());
}
