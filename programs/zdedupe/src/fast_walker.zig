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

// Platform-specific stat structure
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

extern "c" fn lstat(path: [*:0]const u8, buf: *Stat) c_int;

// Linux statx for faster stat calls (request only needed fields)
const Statx = extern struct {
    stx_mask: u32,
    stx_blksize: u32,
    stx_attributes: u64,
    stx_nlink: u32,
    stx_uid: u32,
    stx_gid: u32,
    stx_mode: u16,
    __spare0: u16,
    stx_ino: u64,
    stx_size: u64,
    stx_blocks: u64,
    stx_attributes_mask: u64,
    stx_atime: extern struct { sec: i64, nsec: u32, __pad: i32 },
    stx_btime: extern struct { sec: i64, nsec: u32, __pad: i32 },
    stx_ctime: extern struct { sec: i64, nsec: u32, __pad: i32 },
    stx_mtime: extern struct { sec: i64, nsec: u32, __pad: i32 },
    stx_rdev_major: u32,
    stx_rdev_minor: u32,
    stx_dev_major: u32,
    stx_dev_minor: u32,
    stx_mnt_id: u64,
    stx_dio_mem_align: u32,
    stx_dio_offset_align: u32,
    __spare3: [12]u64,
};

// statx mask flags - request only what we need
const STATX_INO: u32 = 0x100;
const STATX_SIZE: u32 = 0x200;
const STATX_MTIME: u32 = 0x40;
const STATX_BASIC_STATS: u32 = 0x7ff;

// statx flags
const AT_FDCWD: c_int = -100;
const AT_SYMLINK_NOFOLLOW: c_int = 0x100;
const AT_STATX_DONT_SYNC: c_int = 0x4000; // Don't sync - faster for read-only queries

extern "c" fn statx(dirfd: c_int, path: [*:0]const u8, flags: c_int, mask: u32, buf: *Statx) c_int;

/// File identifier for hard link detection
pub const FileId = packed struct {
    dev: u32, // Reduced from u64 - device IDs rarely need full 64 bits
    ino: u64,
};

/// Lightweight file entry for fast collection
pub const FastFileEntry = struct {
    path: []const u8,
    size: u64,
    ino: u64,
    dev: u32,
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

        // Check if root is file or directory
        var stat_buf: Stat = undefined;
        if (lstat(@ptrCast(&self.path_buf), &stat_buf) != 0) {
            return error.StatFailed;
        }

        const mode = stat_buf.mode & 0o170000;
        if (mode == 0o100000) {
            // Root is a file - process it directly
            try self.addFileFromStat(&stat_buf);
            return;
        } else if (mode != 0o40000) {
            return error.NotADirectory;
        }

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
                self.addFileWithLstat(parent_len) catch {
                    self.stats.errors += 1;
                };
                self.path_len = parent_len;
            } else if (d_type == DT_LNK) {
                // Symlink - skip unless following
                if (self.follow_symlinks) {
                    self.addFileWithLstat(parent_len) catch {
                        self.stats.errors += 1;
                    };
                }
                self.path_len = parent_len;
            } else if (d_type == DT_UNKNOWN) {
                // Filesystem doesn't provide d_type - fall back to lstat
                var stat_buf: Stat = undefined;
                if (lstat(@ptrCast(&self.path_buf), &stat_buf) != 0) {
                    self.stats.errors += 1;
                    self.path_len = parent_len;
                    continue;
                }

                const mode = stat_buf.mode & 0o170000;
                if (mode == 0o40000) {
                    // Directory
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
                } else if (mode == 0o100000) {
                    // Regular file
                    self.addFileFromStat(&stat_buf) catch {
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

    /// Add file by doing stat (when d_type is known but we need size/inode)
    /// Uses statx on Linux for better performance (request only needed fields)
    fn addFileWithLstat(self: *FastWalker, parent_len: usize) !void {
        _ = parent_len;
        if (builtin.os.tag == .linux) {
            // Use statx - faster because we request only needed fields and skip sync
            var stx: Statx = undefined;
            const mask = STATX_INO | STATX_SIZE | STATX_MTIME;
            if (statx(AT_FDCWD, @ptrCast(&self.path_buf), AT_SYMLINK_NOFOLLOW | AT_STATX_DONT_SYNC, mask, &stx) != 0) {
                return error.StatFailed;
            }
            try self.addFileFromStatx(&stx);
        } else {
            // Fallback to lstat on other platforms
            var stat_buf: Stat = undefined;
            if (lstat(@ptrCast(&self.path_buf), &stat_buf) != 0) {
                return error.StatFailed;
            }
            try self.addFileFromStat(&stat_buf);
        }
    }

    /// Add file from statx result (Linux-specific fast path)
    fn addFileFromStatx(self: *FastWalker, stx: *const Statx) !void {
        const size: u64 = stx.stx_size;

        // Size filter
        if (size < self.min_size) return;
        if (self.max_size > 0 and size > self.max_size) return;

        // Hard link detection - combine dev major/minor into single u32
        if (self.track_hardlinks) {
            if (self.seen_inodes == null) {
                self.seen_inodes = .empty;
            }
            const dev: u32 = (stx.stx_dev_major << 8) | @as(u32, @truncate(stx.stx_dev_minor));
            const file_id = FileId{
                .dev = dev,
                .ino = stx.stx_ino,
            };
            const result = try self.seen_inodes.?.getOrPut(self.allocator, file_id);
            if (result.found_existing) {
                self.stats.hard_links_skipped += 1;
                return;
            }
        }

        // Copy path
        const path_alloc = if (self.arena) |*arena| arena.allocator() else self.allocator;
        const path_copy = try path_alloc.dupe(u8, self.path_buf[0..self.path_len]);

        const dev: u32 = if (self.track_hardlinks)
            (stx.stx_dev_major << 8) | @as(u32, @truncate(stx.stx_dev_minor))
        else
            0;

        try self.files.append(self.allocator, .{
            .path = path_copy,
            .size = size,
            .ino = stx.stx_ino,
            .dev = dev,
            .mtime = stx.stx_mtime.sec,
        });

        self.stats.files_found += 1;
        self.stats.total_size += size;
    }

    /// Add file from already-obtained stat buffer
    fn addFileFromStat(self: *FastWalker, stat_buf: *const Stat) !void {
        const size: u64 = @intCast(stat_buf.size);

        // Size filter
        if (size < self.min_size) return;
        if (self.max_size > 0 and size > self.max_size) return;

        // Hard link detection
        if (self.track_hardlinks) {
            if (self.seen_inodes == null) {
                self.seen_inodes = .empty;
            }
            const file_id = FileId{
                .dev = @truncate(@as(u64, @intCast(stat_buf.dev))),
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
            .dev = @truncate(@as(u64, @intCast(stat_buf.dev))),
            .mtime = stat_buf.mtim.sec,
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
            entries.appendAssumeCapacity(.{
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
