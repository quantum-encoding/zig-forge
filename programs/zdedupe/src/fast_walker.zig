//! High-performance directory walker optimized for millions of files
//!
//! Key optimizations over standard walker:
//! - Reusable path buffer (single allocation for path building)
//! - Throttled progress callbacks (every N ms, not every file)
//! - Iterative traversal with explicit directory stack
//! - Pre-allocated result capacity
//! - Minimal allocations per file (only final path copy)
//! - Direct libc calls with no abstraction overhead

const std = @import("std");
const builtin = @import("builtin");
const types = @import("types.zig");
const libc = std.c;

// Stat comes from pstat.zig: std.c ($INODE64-correct) on Darwin, statx on Linux.
const pstat = @import("pstat.zig");
const Stat = pstat.Stat;

/// File identifier for hard link detection
pub const FileId = packed struct {
    // Full-width device id. A narrower dev could alias two distinct devices
    // onto one FileId, which would silently drop a real file as a "hard link".
    dev: u64,
    ino: u64,
};

/// Lightweight file entry for fast collection
pub const FastFileEntry = struct {
    path: []const u8,
    size: u64,
    ino: u64,
    dev: u64,
    mtime: i64,
};

/// Fast walker statistics
pub const WalkStats = struct {
    files_found: u64 = 0,
    dirs_traversed: u64 = 0,
    total_size: u64 = 0,
    errors: u64 = 0,
    hard_links_skipped: u64 = 0,
};

/// Progress callback type (called at throttled intervals)
pub const ProgressFn = *const fn (stats: *const WalkStats, current_path: []const u8) void;

/// High-performance directory walker
pub const FastWalker = struct {
    allocator: std.mem.Allocator,

    // Arena allocator for path strings (single bulk free at end)
    arena: ?std.heap.ArenaAllocator,

    // Configuration
    min_size: u64,
    max_size: u64,
    include_hidden: bool,
    follow_symlinks: bool,
    track_hardlinks: bool, // When false, skip inode tracking for faster scanning
    use_arena: bool, // Use arena allocator for paths (faster but uses more peak memory)

    // Reusable path buffer (avoids per-file allocations)
    path_buf: [8192]u8 = undefined,
    path_len: usize = 0,

    // Directory stack for iterative traversal
    dir_stack: std.ArrayListUnmanaged(DirState),

    // Results
    files: std.ArrayListUnmanaged(FastFileEntry),
    stats: WalkStats,

    // Hard link tracking (optional)
    seen_inodes: ?std.AutoHashMapUnmanaged(FileId, void),

    // Visited directories, used only under follow_symlinks to break cycles
    seen_dirs: std.AutoHashMapUnmanaged(FileId, void),

    // Progress throttling - use counter for speed (avoid Instant.now() overhead)
    progress_fn: ?ProgressFn,
    progress_counter: u64,
    progress_interval_count: u64, // Report every N files/directories

    const DirState = struct {
        dir: *libc.DIR,
        path_len: usize, // Length of path when this dir was pushed
    };

    // d_type constants from dirent.h
    const DT_UNKNOWN: u8 = 0;
    const DT_REG: u8 = 8; // Regular file
    const DT_DIR: u8 = 4; // Directory
    const DT_LNK: u8 = 10; // Symbolic link

    pub fn init(allocator: std.mem.Allocator) FastWalker {
        return .{
            .allocator = allocator,
            .arena = null,
            .min_size = 0,
            .max_size = 0,
            .include_hidden = false,
            .follow_symlinks = false,
            .track_hardlinks = true,
            .use_arena = false,
            .dir_stack = .empty,
            .files = .empty,
            .stats = .{},
            .seen_inodes = null,
            .seen_dirs = .empty,
            .progress_fn = null,
            .progress_counter = 0,
            .progress_interval_count = 10000, // Report every 10k items
        };
    }

    pub fn deinit(self: *FastWalker) void {
        // Close any open directories
        for (self.dir_stack.items) |state| {
            _ = libc.closedir(state.dir);
        }
        self.dir_stack.deinit(self.allocator);

        // Free file paths - arena does bulk free, otherwise individual frees
        if (self.arena) |*arena| {
            // Single bulk free for all paths
            arena.deinit();
        } else {
            // Individual frees
            for (self.files.items) |entry| {
                self.allocator.free(entry.path);
            }
        }
        self.files.deinit(self.allocator);

        // Free inode map
        if (self.seen_inodes) |*map| {
            map.deinit(self.allocator);
        }
        self.seen_dirs.deinit(self.allocator);
    }

    /// Enable arena allocator for path strings (faster, higher peak memory)
    pub fn enableArenaAllocator(self: *FastWalker) void {
        if (self.arena == null) {
            self.arena = std.heap.ArenaAllocator.init(self.allocator);
        }
        self.use_arena = true;
    }

    /// Configure size filters
    pub fn setSizeFilter(self: *FastWalker, min: u64, max: u64) void {
        self.min_size = min;
        self.max_size = max;
    }

    /// Enable hard link detection (default: enabled)
    pub fn enableHardLinkDetection(self: *FastWalker) void {
        self.track_hardlinks = true;
        if (self.seen_inodes == null) {
            self.seen_inodes = .empty;
        }
    }

    /// Disable hard link detection for faster pure scanning
    pub fn disableHardLinkDetection(self: *FastWalker) void {
        self.track_hardlinks = false;
        if (self.seen_inodes) |*map| {
            map.deinit(self.allocator);
            self.seen_inodes = null;
        }
    }

    /// Set progress callback and interval (in number of items, not time)
    pub fn setProgress(self: *FastWalker, callback: ProgressFn, interval_count: u32) void {
        self.progress_fn = callback;
        self.progress_interval_count = interval_count;
    }

    /// Include hidden files
    pub fn setIncludeHidden(self: *FastWalker, include: bool) void {
        self.include_hidden = include;
    }

    /// Follow symlinks: stat targets and descend into symlinked directories
    /// (cycle-guarded). Off by default.
    pub fn setFollowSymlinks(self: *FastWalker, follow: bool) void {
        self.follow_symlinks = follow;
    }

    /// Walk a directory tree
    pub fn walk(self: *FastWalker, root_path: []const u8) !void {
        // Pre-allocate for expected file count (estimate 100k files initially)
        try self.files.ensureTotalCapacity(self.allocator, 100_000);

        // Pre-size hardlink hashmap to avoid rehashing during scan
        if (self.track_hardlinks) {
            if (self.seen_inodes == null) {
                self.seen_inodes = .empty;
            }
            try self.seen_inodes.?.ensureTotalCapacity(self.allocator, 100_000);
        }

        // Initialize path buffer with root
        if (root_path.len >= self.path_buf.len - 1) {
            return error.PathTooLong;
        }
        @memcpy(self.path_buf[0..root_path.len], root_path);
        self.path_len = root_path.len;

        // Remove trailing slash if present
        if (self.path_len > 1 and self.path_buf[self.path_len - 1] == '/') {
            self.path_len -= 1;
        }

        // Null terminate
        self.path_buf[self.path_len] = 0;

        // Check if root is file or directory. The root is always followed:
        // scanning `zdedupe /some/symlink-to-dir` should scan the target.
        const root_stat = try pstat.stat(@ptrCast(&self.path_buf));

        if (root_stat.isFile()) {
            // Root is a file - process it directly
            try self.addFileFromStat(&root_stat);
            return;
        } else if (!root_stat.isDir()) {
            return error.NotADirectory;
        }
        _ = try self.markDirVisited(&root_stat);

        // Open root directory
        const root_dir = libc.opendir(@ptrCast(&self.path_buf)) orelse {
            return error.CannotOpenDirectory;
        };

        try self.dir_stack.append(self.allocator, .{
            .dir = root_dir,
            .path_len = self.path_len,
        });

        // Iterative traversal
        while (self.dir_stack.items.len > 0) {
            try self.processCurrentDir();
        }
    }

    fn processCurrentDir(self: *FastWalker) !void {
        const state = &self.dir_stack.items[self.dir_stack.items.len - 1];

        while (true) {
            const entry = libc.readdir(state.dir) orelse {
                // Directory exhausted - pop from stack
                _ = libc.closedir(state.dir);
                _ = self.dir_stack.pop();
                // Restore path length
                if (self.dir_stack.items.len > 0) {
                    self.path_len = self.dir_stack.items[self.dir_stack.items.len - 1].path_len;
                }
                return;
            };

            const name_ptr: [*:0]const u8 = @ptrCast(&entry.name);

            // Quick skip for . and ..
            if (name_ptr[0] == '.') {
                if (name_ptr[1] == 0) continue; // "."
                if (name_ptr[1] == '.' and name_ptr[2] == 0) continue; // ".."
                if (!self.include_hidden) continue; // Hidden file
            }

            // Get name length
            const name_len = std.mem.len(name_ptr);

            // Build full path in buffer
            const parent_len = state.path_len;
            const new_len = parent_len + 1 + name_len;

            if (new_len >= self.path_buf.len - 1) {
                self.stats.errors += 1;
                continue; // Path too long
            }

            self.path_buf[parent_len] = '/';
            @memcpy(self.path_buf[parent_len + 1 ..][0..name_len], name_ptr[0..name_len]);
            self.path_buf[new_len] = 0;
            self.path_len = new_len;

            // Use d_type to determine entry type without syscall when possible
            const d_type: u8 = entry.type;

            if (d_type == DT_DIR) {
                // Directory - push to stack (no lstat needed)
                const sub_dir = libc.opendir(@ptrCast(&self.path_buf)) orelse {
                    self.stats.errors += 1;
                    self.path_len = parent_len;
                    continue;
                };

                self.stats.dirs_traversed += 1;

                try self.dir_stack.append(self.allocator, .{
                    .dir = sub_dir,
                    .path_len = self.path_len,
                });

                // Report progress (throttled)
                self.maybeReportProgress();

                return; // Process new directory on next iteration
            } else if (d_type == DT_REG) {
                // Regular file - need lstat for size/inode
                self.addFileWithStat(false) catch {
                    self.stats.errors += 1;
                };
                self.path_len = parent_len;
            } else if (d_type == DT_LNK) {
                // Symlink - skipped entirely unless -L/follow_symlinks is set.
                // When following we stat the TARGET (an lstat here would record
                // the link's own size/inode, which is never what the user meant)
                // and descend into symlinked directories under a visited-dir
                // guard so `ln -s .. loop` terminates instead of recursing.
                if (self.follow_symlinks) {
                    const target = pstat.stat(@ptrCast(&self.path_buf)) catch {
                        self.stats.errors += 1;
                        self.path_len = parent_len;
                        continue;
                    };
                    if (target.isDir()) {
                        if (self.enterSymlinkedDir(&target, parent_len)) |descended| {
                            if (descended) return;
                        } else |_| {
                            self.stats.errors += 1;
                        }
                    } else if (target.isFile()) {
                        self.addFileFromStat(&target) catch {
                            self.stats.errors += 1;
                        };
                    }
                }
                self.path_len = parent_len;
            } else if (d_type == DT_UNKNOWN) {
                // Filesystem doesn't provide d_type - fall back to lstat
                const stat_buf = pstat.lstat(@ptrCast(&self.path_buf)) catch {
                    self.stats.errors += 1;
                    self.path_len = parent_len;
                    continue;
                };

                if (stat_buf.isDir()) {
                    const sub_dir = libc.opendir(@ptrCast(&self.path_buf)) orelse {
                        self.stats.errors += 1;
                        self.path_len = parent_len;
                        continue;
                    };
                    self.stats.dirs_traversed += 1;
                    try self.dir_stack.append(self.allocator, .{
                        .dir = sub_dir,
                        .path_len = self.path_len,
                    });
                    self.maybeReportProgress();
                    return;
                } else if (stat_buf.isFile()) {
                    self.addFileFromStat(&stat_buf) catch {
                        self.stats.errors += 1;
                    };
                } else if (stat_buf.isLink() and self.follow_symlinks) {
                    self.addFileWithStat(true) catch {
                        self.stats.errors += 1;
                    };
                }
                self.path_len = parent_len;
            } else {
                // Other types (socket, fifo, etc) - skip
                self.path_len = parent_len;
            }
        }
    }

    /// Stat the current path and record it as a file.
    /// `follow` picks stat() (target) over lstat() (the link itself).
    fn addFileWithStat(self: *FastWalker, follow: bool) !void {
        const stat_buf = if (follow)
            try pstat.stat(@ptrCast(&self.path_buf))
        else
            try pstat.lstat(@ptrCast(&self.path_buf));
        try self.addFileFromStat(&stat_buf);
    }

    /// Record a directory as visited. Returns false if it was already seen,
    /// which is how symlink cycles (`ln -s .. loop`) are broken.
    fn markDirVisited(self: *FastWalker, stat_buf: *const Stat) !bool {
        if (!self.follow_symlinks) return true; // cycles need a symlink to exist
        const result = try self.seen_dirs.getOrPut(self.allocator, .{
            .dev = stat_buf.dev,
            .ino = stat_buf.ino,
        });
        return !result.found_existing;
    }

    /// Descend into a symlinked directory. Returns true if the dir was pushed
    /// onto the stack (caller must return to process it), false if it was
    /// skipped as already-visited or unopenable.
    fn enterSymlinkedDir(self: *FastWalker, target: *const Stat, parent_len: usize) !bool {
        if (!try self.markDirVisited(target)) {
            self.path_len = parent_len;
            return false;
        }
        const sub_dir = libc.opendir(@ptrCast(&self.path_buf)) orelse {
            self.path_len = parent_len;
            return false;
        };
        self.stats.dirs_traversed += 1;
        try self.dir_stack.append(self.allocator, .{
            .dir = sub_dir,
            .path_len = self.path_len,
        });
        self.maybeReportProgress();
        return true;
    }

    /// Add file from already-obtained stat buffer
    fn addFileFromStat(self: *FastWalker, stat_buf: *const Stat) !void {
        const size: u64 = stat_buf.size;

        // Size filter
        if (size < self.min_size) return;
        if (self.max_size > 0 and size > self.max_size) return;

        // Hard link detection
        if (self.track_hardlinks) {
            if (self.seen_inodes == null) {
                self.seen_inodes = .empty;
            }
            const file_id = FileId{
                .dev = stat_buf.dev,
                .ino = stat_buf.ino,
            };
            const result = try self.seen_inodes.?.getOrPut(self.allocator, file_id);
            if (result.found_existing) {
                self.stats.hard_links_skipped += 1;
                return;
            }
        }

        // Copy path - use arena if enabled (faster bulk free), otherwise regular allocator
        const path_alloc = if (self.arena) |*arena| arena.allocator() else self.allocator;
        const path_copy = try path_alloc.dupe(u8, self.path_buf[0..self.path_len]);

        try self.files.append(self.allocator, .{
            .path = path_copy,
            .size = size,
            .ino = stat_buf.ino,
            .dev = stat_buf.dev,
            .mtime = stat_buf.mtime_sec,
        });

        self.stats.files_found += 1;
        self.stats.total_size += size;
    }

    fn maybeReportProgress(self: *FastWalker) void {
        if (self.progress_fn == null) return;

        self.progress_counter += 1;
        if (self.progress_counter < self.progress_interval_count) return;
        self.progress_counter = 0;
        self.progress_fn.?(&self.stats, self.path_buf[0..self.path_len]);
    }

    /// Get results as types.FileEntry array (for compatibility with existing code)
    pub fn toFileEntries(self: *FastWalker, allocator: std.mem.Allocator) !std.ArrayListUnmanaged(types.FileEntry) {
        var entries: std.ArrayListUnmanaged(types.FileEntry) = .empty;
        try entries.ensureTotalCapacity(allocator, self.files.items.len);

        for (self.files.items) |fast_entry| {
            const path_copy = try allocator.dupe(u8, fast_entry.path);
            try entries.append(allocator, .{
                .path = path_copy,
                .size = fast_entry.size,
                .inode = fast_entry.ino,
                .dev = fast_entry.dev,
                .mtime = fast_entry.mtime,
                .hash = null,
                .quick_hash = null,
            });
        }

        return entries;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "FastWalker initialization" {
    const allocator = std.testing.allocator;
    var walker = FastWalker.init(allocator);
    defer walker.deinit();

    try std.testing.expect(walker.stats.files_found == 0);
}

test "FastWalker size filter" {
    const allocator = std.testing.allocator;
    var walker = FastWalker.init(allocator);
    defer walker.deinit();

    walker.setSizeFilter(1024, 1024 * 1024);
    try std.testing.expect(walker.min_size == 1024);
    try std.testing.expect(walker.max_size == 1024 * 1024);
}
