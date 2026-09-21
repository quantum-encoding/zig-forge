//! High-performance directory walker optimized for millions of files
//!
//! Key optimizations over standard walker:
//! - Reusable path buffer (single allocation for path building)
//! - Throttled progress callbacks (every N ms, not every file)
//! - Iterative traversal with explicit directory stack
//! - Pre-allocated result capacity
//! - Minimal allocations per file (only final path copy)
//! - Direct libc calls with no abstraction overhead
//!
//! Beyond the flat file list it can prune entries by basename / CACHEDIR.TAG
//! and, in tree-recording mode, remember every directory, unfollowed symlink
//! and extra hard link it saw — the raw material for directory analysis
//! (dirs.zig), which must know everything a directory contains, not just the
//! files that are interesting as file-level duplicates.

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
    /// Index of the first-seen entry with the same (dev, ino). Only ever set
    /// in tree-recording mode; otherwise extra hard links are dropped.
    link_of: ?usize = null,
};

/// A directory seen by a tree-recording walk. Records are appended in
/// pre-order, so a parent always precedes its children.
pub const DirRecord = struct {
    path: []const u8,
    /// Something directly inside could not be read (unopenable subdirectory,
    /// failed stat, over-long path, symlink cycle). What the directory really
    /// holds is unknown, so it must never be reported as a copy of another.
    incomplete: bool = false,
    /// Direct children deliberately ignored: excluded names, tagged cache
    /// directories, hidden entries when those are off, and special files
    /// (sockets, FIFOs, devices — no content to lose).
    skipped: u32 = 0,
};

/// A symlink that was not followed, recorded with its target text.
pub const LinkRecord = struct {
    path: []const u8,
    target: []const u8,
};

/// First line of a valid CACHEDIR.TAG (https://bford.info/cachedir/).
pub const cache_dir_signature = "Signature: 8a477f597d28d172789f06886806bc55";

/// Fast walker statistics
pub const WalkStats = struct {
    files_found: u64 = 0,
    dirs_traversed: u64 = 0,
    total_size: u64 = 0,
    errors: u64 = 0,
    hard_links_skipped: u64 = 0,
    /// Entries pruned by name or by CACHEDIR.TAG.
    excluded: u64 = 0,
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
    excludes: []const []const u8, // Entry basenames to prune (borrowed)
    exclude_cache_dirs: bool, // Prune directories holding a valid CACHEDIR.TAG
    record_tree: bool, // Also record dirs, unfollowed symlinks and extra hard links

    // Reusable path buffer (avoids per-file allocations)
    path_buf: [8192]u8 = undefined,
    path_len: usize = 0,

    // Directory stack for iterative traversal
    dir_stack: std.ArrayListUnmanaged(DirState),

    // Results
    files: std.ArrayListUnmanaged(FastFileEntry),
    dirs: std.ArrayListUnmanaged(DirRecord),
    links: std.ArrayListUnmanaged(LinkRecord),
    stats: WalkStats,

    // Hard link tracking (optional): inode -> index of its first entry in `files`
    seen_inodes: ?std.AutoHashMapUnmanaged(FileId, usize),

    // Visited directories, used only under follow_symlinks to break cycles
    seen_dirs: std.AutoHashMapUnmanaged(FileId, void),

    // Progress throttling - use counter for speed (avoid Instant.now() overhead)
    progress_fn: ?ProgressFn,
    progress_counter: u64,
    progress_interval_count: u64, // Report every N files/directories

    const DirState = struct {
        dir: *libc.DIR,
        path_len: usize, // Length of path when this dir was pushed
        dir_index: usize, // Index into `dirs`; meaningful only when record_tree
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
            .excludes = &.{},
            .exclude_cache_dirs = false,
            .record_tree = false,
            .dir_stack = .empty,
            .files = .empty,
            .dirs = .empty,
            .links = .empty,
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

        // Free recorded strings - arena does bulk free, otherwise individual frees
        if (self.arena) |*arena| {
            // Single bulk free for all paths
            arena.deinit();
        } else {
            // Individual frees
            for (self.files.items) |entry| {
                self.allocator.free(entry.path);
            }
            for (self.dirs.items) |record| {
                self.allocator.free(record.path);
            }
            for (self.links.items) |record| {
                self.allocator.free(record.path);
                self.allocator.free(record.target);
            }
        }
        self.files.deinit(self.allocator);
        self.dirs.deinit(self.allocator);
        self.links.deinit(self.allocator);

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

    /// Prune entries whose basename equals one of `names` (exact match, files
    /// and directories alike). The slice is borrowed and must outlive the walk.
    pub fn setExcludes(self: *FastWalker, names: []const []const u8) void {
        self.excludes = names;
    }

    /// Prune directories that carry a valid CACHEDIR.TAG.
    pub fn setExcludeCacheDirs(self: *FastWalker, exclude: bool) void {
        self.exclude_cache_dirs = exclude;
    }

    /// Record directories, unfollowed symlinks and extra hard links alongside
    /// the file list (see `dirs`, `links`, `FastFileEntry.link_of`).
    pub fn enableTreeRecording(self: *FastWalker) void {
        self.record_tree = true;
    }

    /// Walk a directory tree. May be called once per root on the same walker:
    /// results accumulate, and because the inode table is shared a file
    /// reachable from two roots is still only reported once.
    pub fn walk(self: *FastWalker, root_path: []const u8) !void {
        // A previous walk that failed part-way leaves its directories open.
        for (self.dir_stack.items) |state| {
            _ = libc.closedir(state.dir);
        }
        self.dir_stack.clearRetainingCapacity();

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

        // Open root directory. Roots are never pruned, whatever they are
        // called: the user asked for them by name.
        const root_dir = libc.opendir(@ptrCast(&self.path_buf)) orelse {
            return error.CannotOpenDirectory;
        };
        errdefer _ = libc.closedir(root_dir);

        const root_index = try self.recordDir();
        try self.dir_stack.append(self.allocator, .{
            .dir = root_dir,
            .path_len = self.path_len,
            .dir_index = root_index,
        });

        // Iterative traversal
        while (self.dir_stack.items.len > 0) {
            try self.processCurrentDir();
        }
    }

    fn processCurrentDir(self: *FastWalker) !void {
        // Copied out, not pointed at: pushing a subdirectory may reallocate
        // the stack.
        const state = self.dir_stack.items[self.dir_stack.items.len - 1];
        const cur_dir = state.dir_index;

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
                if (!self.include_hidden) {
                    self.noteSkipped(cur_dir);
                    continue; // Hidden file
                }
            }

            // Get name length
            const name_len = std.mem.len(name_ptr);

            if (self.isExcluded(name_ptr[0..name_len])) {
                self.stats.excluded += 1;
                self.noteSkipped(cur_dir);
                continue;
            }

            // Build full path in buffer
            const parent_len = state.path_len;
            const new_len = parent_len + 1 + name_len;

            if (new_len >= self.path_buf.len - 1) {
                self.noteError(cur_dir);
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
                if (try self.pushDir(parent_len, cur_dir)) return; // Process it on next iteration
            } else if (d_type == DT_REG) {
                // Regular file - need lstat for size/inode
                self.addFileWithStat(false) catch {
                    self.noteError(cur_dir);
                };
                self.path_len = parent_len;
            } else if (d_type == DT_LNK) {
                if (try self.handleSymlink(parent_len, cur_dir)) return;
            } else if (d_type == DT_UNKNOWN) {
                // Filesystem doesn't provide d_type - fall back to lstat
                const stat_buf = pstat.lstat(@ptrCast(&self.path_buf)) catch {
                    self.noteError(cur_dir);
                    self.path_len = parent_len;
                    continue;
                };

                if (stat_buf.isDir()) {
                    if (try self.pushDir(parent_len, cur_dir)) return;
                } else if (stat_buf.isFile()) {
                    self.addFileFromStat(&stat_buf) catch {
                        self.noteError(cur_dir);
                    };
                    self.path_len = parent_len;
                } else if (stat_buf.isLink()) {
                    if (try self.handleSymlink(parent_len, cur_dir)) return;
                } else {
                    self.noteSkipped(cur_dir);
                    self.path_len = parent_len;
                }
            } else {
                // Other types (socket, fifo, etc) - skip
                self.noteSkipped(cur_dir);
                self.path_len = parent_len;
            }
        }
    }

    /// Open the directory at the current path and push it onto the stack.
    /// Returns true if pushed (the caller must return so it is processed
    /// next); on false the path has been restored to `parent_len`.
    fn pushDir(self: *FastWalker, parent_len: usize, parent_dir: usize) !bool {
        if (self.exclude_cache_dirs and self.isCacheDir()) {
            self.stats.excluded += 1;
            self.noteSkipped(parent_dir);
            self.path_len = parent_len;
            return false;
        }

        const sub_dir = libc.opendir(@ptrCast(&self.path_buf)) orelse {
            self.noteError(parent_dir);
            self.path_len = parent_len;
            return false;
        };
        errdefer _ = libc.closedir(sub_dir);

        self.stats.dirs_traversed += 1;

        const dir_index = try self.recordDir();
        try self.dir_stack.append(self.allocator, .{
            .dir = sub_dir,
            .path_len = self.path_len,
            .dir_index = dir_index,
        });

        // Report progress (throttled)
        self.maybeReportProgress();
        return true;
    }

    /// Handle the symlink at the current path. Skipped entirely unless
    /// -L/follow_symlinks is set. When following we stat the TARGET (an lstat
    /// here would record the link's own size/inode, which is never what the
    /// user meant) and descend into symlinked directories under a visited-dir
    /// guard so `ln -s .. loop` terminates instead of recursing.
    ///
    /// Returns true if a directory was pushed; otherwise the path has been
    /// restored to `parent_len`.
    fn handleSymlink(self: *FastWalker, parent_len: usize, cur_dir: usize) !bool {
        if (!self.follow_symlinks) {
            // Not followed, but a directory still *contains* the link: two
            // copies only match if the link is in both, pointing the same way.
            if (self.record_tree) {
                self.recordLink() catch |err| switch (err) {
                    error.OutOfMemory => return err,
                    error.ReadLinkFailed => self.noteError(cur_dir),
                };
            }
            self.path_len = parent_len;
            return false;
        }

        const target = pstat.stat(@ptrCast(&self.path_buf)) catch {
            self.noteError(cur_dir); // dangling link
            self.path_len = parent_len;
            return false;
        };

        if (target.isDir()) {
            if (!try self.markDirVisited(&target)) {
                // Already walked via another route. Its files are reported
                // there, so from here this directory looks emptier than it is.
                self.noteError(cur_dir);
                self.path_len = parent_len;
                return false;
            }
            return self.pushDir(parent_len, cur_dir);
        }

        if (target.isFile()) {
            self.addFileFromStat(&target) catch {
                self.noteError(cur_dir);
            };
        } else {
            self.noteSkipped(cur_dir);
        }
        self.path_len = parent_len;
        return false;
    }

    fn isExcluded(self: *const FastWalker, name: []const u8) bool {
        for (self.excludes) |excluded| {
            // zig-lens-ignore: EQL-FOR-SECRETS file names, not secrets
            if (std.mem.eql(u8, excluded, name)) return true;
        }
        return false;
    }

    /// True if the directory at the current path holds a valid CACHEDIR.TAG.
    /// The tag must be a regular file starting with the fixed signature; its
    /// mere presence is not enough (that is the spec, and it stops an empty
    /// file of that name from hiding a directory from the scan).
    fn isCacheDir(self: *FastWalker) bool {
        const tag = "/CACHEDIR.TAG";
        if (self.path_len + tag.len >= self.path_buf.len) return false;

        @memcpy(self.path_buf[self.path_len..][0..tag.len], tag);
        self.path_buf[self.path_len + tag.len] = 0;
        defer self.path_buf[self.path_len] = 0;

        // NOFOLLOW + NONBLOCK: never chase a link out of the tree, never hang
        // on a FIFO someone named CACHEDIR.TAG.
        const fd = libc.open(
            @ptrCast(&self.path_buf),
            .{ .ACCMODE = .RDONLY, .NONBLOCK = true, .NOFOLLOW = true },
            @as(libc.mode_t, 0),
        );
        if (fd < 0) return false;
        defer _ = libc.close(fd);

        const st = pstat.fstat(fd) catch return false;
        if (!st.isFile()) return false;

        var buf: [cache_dir_signature.len]u8 = undefined;
        var got: usize = 0;
        while (got < buf.len) {
            const n = libc.read(fd, buf[got..].ptr, buf.len - got);
            if (n == 0) break;
            if (n < 0) {
                if (libc.errno(n) == .INTR) continue;
                return false;
            }
            got += @intCast(n);
        }
        // zig-lens-ignore: EQL-FOR-SECRETS public file-format magic
        return got == buf.len and std.mem.eql(u8, &buf, cache_dir_signature);
    }

    /// Record the directory at the current path; returns its index in `dirs`
    /// (0 when tree recording is off, where the index is never read).
    fn recordDir(self: *FastWalker) !usize {
        if (!self.record_tree) return 0;
        const path_copy = try self.stringAllocator().dupe(u8, self.path_buf[0..self.path_len]);
        try self.dirs.append(self.allocator, .{ .path = path_copy });
        return self.dirs.items.len - 1;
    }

    /// Record the unfollowed symlink at the current path with its target.
    fn recordLink(self: *FastWalker) error{ OutOfMemory, ReadLinkFailed }!void {
        var target_buf: [4096]u8 = undefined;
        const n = libc.readlink(@ptrCast(&self.path_buf), &target_buf, target_buf.len);
        // A result that fills the buffer may have been truncated; treat it as
        // unreadable rather than compare a prefix.
        if (n < 0 or @as(usize, @intCast(n)) >= target_buf.len) return error.ReadLinkFailed;

        const string_alloc = self.stringAllocator();
        const path_copy = try string_alloc.dupe(u8, self.path_buf[0..self.path_len]);
        const target_copy = try string_alloc.dupe(u8, target_buf[0..@intCast(n)]);
        try self.links.append(self.allocator, .{ .path = path_copy, .target = target_copy });
    }

    fn stringAllocator(self: *FastWalker) std.mem.Allocator {
        return if (self.arena) |*arena| arena.allocator() else self.allocator;
    }

    /// Count a failure and, when recording, flag the directory it happened in.
    fn noteError(self: *FastWalker, dir_index: usize) void {
        self.stats.errors += 1;
        if (self.record_tree and dir_index < self.dirs.items.len) {
            self.dirs.items[dir_index].incomplete = true;
        }
    }

    fn noteSkipped(self: *FastWalker, dir_index: usize) void {
        if (self.record_tree and dir_index < self.dirs.items.len) {
            self.dirs.items[dir_index].skipped += 1;
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
                // No space to win back, so never a file-level duplicate. A
                // directory still contains it though, so tree recording keeps
                // the entry, pointed at the first one.
                if (self.record_tree) {
                    try self.appendFile(stat_buf, result.value_ptr.*);
                }
                return;
            }
            result.value_ptr.* = self.files.items.len;
        }

        try self.appendFile(stat_buf, null);

        self.stats.files_found += 1;
        self.stats.total_size += size;
    }

    fn appendFile(self: *FastWalker, stat_buf: *const Stat, link_of: ?usize) !void {
        // Copy path - use arena if enabled (faster bulk free), otherwise regular allocator
        const path_copy = try self.stringAllocator().dupe(u8, self.path_buf[0..self.path_len]);

        try self.files.append(self.allocator, .{
            .path = path_copy,
            .size = stat_buf.size,
            .ino = stat_buf.ino,
            .dev = stat_buf.dev,
            .mtime = stat_buf.mtime_sec,
            .link_of = link_of,
        });
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
                .link_of = fast_entry.link_of,
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
