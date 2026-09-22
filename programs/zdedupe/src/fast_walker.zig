//! Parallel directory walker for trees of millions of files
//!
//! A walk is almost pure kernel time — one `getdents` per directory and one
//! `statx` per file — so the two things that matter are how much work each
//! syscall makes the kernel do, and how many of them are in flight at once:
//!
//!   * Files are stat'ed *relative to the open directory* (`statx(dirfd, name)`),
//!     so the kernel does not re-resolve every component of a long absolute
//!     path for each file.
//!   * Directories are processed by a pool of workers pulling from a shared
//!     stack. On a warm cache this spreads the syscall cost across cores; on a
//!     cold one it is what gives an NVMe drive a queue depth worth having.
//!
//! Workers share nothing on the hot path: each has its own arena for strings
//! and its own result lists, merged when the walk ends. The price is that
//! results come back in no particular order, so nothing downstream may depend
//! on walk order (dirs.zig ranks the tree itself), and anything that used to
//! be decided by "whichever came first" is decided afterwards instead:
//!
//!   * Hard links are resolved in `finish()`. Of several paths to one inode the
//!     lexicographically smallest is the file; the others are extra links
//!     (dropped, or kept with `link_of` in tree-recording mode). That is
//!     deterministic, which first-seen order never was. Files whose link count
//!     is 1 skip inode tracking entirely — no multi-million-entry hash map for
//!     the 99.9% of files that cannot be hard links. (Only while symlinks are
//!     not followed: followed, a link gives an inode a second path without
//!     being a hard link — see `cannotBeAliased`.)
//!   * A subdirectory that turns out to be unreadable, or a tagged cache
//!     directory, is discovered by whichever worker picks it up, not by the
//!     worker that owns its parent's record; such verdicts are queued and
//!     applied to the parent in `finish()`.
//!
//! Known limit: with symlinks followed, a directory reachable by two routes is
//! recorded under whichever route a worker opens first, so the *path* it is
//! reported under can differ between runs. Every file is still reported
//! exactly once. Without `-L` (how GUI hosts run it) output is deterministic.
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

/// POSIX `dirfd`: the descriptor behind an open `DIR*` (not in Zig 0.16's std.c).
extern "c" fn dirfd(dir: *libc.DIR) c_int;

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
    /// Hard-link count as reported by the filesystem (0 = unknown).
    nlink: u32 = 0,
    /// Index of the entry that stands for this inode, when this entry is an
    /// extra hard link to it. Only ever set in tree-recording mode; otherwise
    /// extra hard links are dropped.
    link_of: ?usize = null,
};

/// A directory seen by a tree-recording walk. Order is unspecified.
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
    /// Distinct files (extra hard links not counted). Final after `finish()`.
    files_found: u64 = 0,
    dirs_traversed: u64 = 0,
    /// Total size of the distinct files. Final after `finish()`.
    total_size: u64 = 0,
    errors: u64 = 0,
    hard_links_skipped: u64 = 0,
    /// Entries pruned by name or by CACHEDIR.TAG.
    excluded: u64 = 0,

    fn add(self: *WalkStats, other: WalkStats) void {
        self.dirs_traversed += other.dirs_traversed;
        self.errors += other.errors;
        self.excluded += other.excluded;
    }
};

/// Every string a walk recorded. Owned by whoever holds it.
pub const StringStorage = struct {
    arenas: std.ArrayListUnmanaged(std.heap.ArenaAllocator) = .empty,

    pub fn deinit(self: *StringStorage, allocator: std.mem.Allocator) void {
        for (self.arenas.items) |*arena| arena.deinit();
        self.arenas.deinit(allocator);
    }
};

// ---------------------------------------------------------------------------
// pthread-backed locks. Zig 0.16 has no std.Thread.Mutex / Condition; this is
// the same minimal wrapper the monorepo uses in async_scheduler/src/sync.zig.
// ---------------------------------------------------------------------------

const Mutex = struct {
    inner: libc.pthread_mutex_t = libc.PTHREAD_MUTEX_INITIALIZER,

    fn lock(self: *Mutex) void {
        _ = libc.pthread_mutex_lock(&self.inner);
    }

    fn unlock(self: *Mutex) void {
        _ = libc.pthread_mutex_unlock(&self.inner);
    }
};

const Condition = struct {
    inner: libc.pthread_cond_t = libc.PTHREAD_COND_INITIALIZER,

    fn wait(self: *Condition, mutex: *Mutex) void {
        _ = libc.pthread_cond_wait(&self.inner, &mutex.inner);
    }

    fn signal(self: *Condition) void {
        _ = libc.pthread_cond_signal(&self.inner);
    }

    fn broadcast(self: *Condition) void {
        _ = libc.pthread_cond_broadcast(&self.inner);
    }
};

const MarkKind = enum { incomplete, skipped };

/// Something a worker learned about a directory whose record belongs to a
/// different worker: applied by path in `finish()`.
const ParentMark = struct {
    path: []const u8,
    kind: MarkKind,
};

/// Work shared between the workers of one `walk()` call.
const Shared = struct {
    walker: *FastWalker,
    mutex: Mutex = .{},
    work_available: Condition = .{},
    /// Directories waiting to be read. A stack: depth-first keeps it small.
    pending: std.ArrayListUnmanaged([]const u8) = .empty,
    /// Workers currently reading a directory (and so able to push more).
    active: usize = 0,
    /// First fatal error (out of memory, cancellation); stops every worker.
    failure: ?anyerror = null,

    /// Blocks until there is a directory to read, or the walk is over.
    fn take(self: *Shared) ?[]const u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        while (true) {
            if (self.failure != null) return null;
            if (self.pending.pop()) |path| {
                self.active += 1;
                return path;
            }
            // Nothing queued and nobody who could queue more: finished.
            if (self.active == 0) return null;
            self.work_available.wait(&self.mutex);
        }
    }

    fn push(self: *Shared, path: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.pending.append(self.walker.allocator, path);
        self.work_available.signal();
    }

    fn done(self: *Shared, failure: ?anyerror) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.active -= 1;
        if (failure) |err| {
            if (self.failure == null) self.failure = err;
        }
        if (self.failure != null or (self.active == 0 and self.pending.items.len == 0)) {
            self.work_available.broadcast();
        }
    }
};

/// Longest path the walker will record.
const max_path = 8190;

// d_type constants from dirent.h
const DT_UNKNOWN: u8 = 0;
const DT_DIR: u8 = 4; // Directory
const DT_REG: u8 = 8; // Regular file
const DT_LNK: u8 = 10; // Symbolic link
const DT_OTHER: u8 = 255; // Anything else, once classified by stat

/// One thread's private state.
const Worker = struct {
    shared: *Shared,
    arena: std.heap.ArenaAllocator,
    files: std.ArrayListUnmanaged(FastFileEntry) = .empty,
    dirs: std.ArrayListUnmanaged(DirRecord) = .empty,
    links: std.ArrayListUnmanaged(LinkRecord) = .empty,
    marks: std.ArrayListUnmanaged(ParentMark) = .empty,
    stats: WalkStats = .{},
    /// Scratch for the NUL-terminated paths a few syscalls need.
    path_buf: [max_path + 64]u8 = undefined,

    fn run(self: *Worker) void {
        while (self.shared.take()) |path| {
            const failure: ?anyerror = if (self.readDir(path)) |_| null else |err| err;
            self.shared.done(failure);
        }
    }

    fn strings(self: *Worker) std.mem.Allocator {
        return self.arena.allocator();
    }

    fn scratch(self: *const Worker) std.mem.Allocator {
        return self.shared.walker.allocator;
    }

    /// `path` NUL-terminated in the scratch buffer.
    fn pathZ(self: *Worker, path: []const u8) [*:0]const u8 {
        std.debug.assert(path.len < self.path_buf.len);
        @memcpy(self.path_buf[0..path.len], path);
        self.path_buf[path.len] = 0;
        return @ptrCast(&self.path_buf);
    }

    /// Read one directory: record its files, queue its subdirectories.
    fn readDir(self: *Worker, dir_path: []const u8) !void {
        const w = self.shared.walker;
        if (w.monitor) |m| {
            if (m.cancelled()) return error.Cancelled;
        }

        // The checks that need the directory itself happen here, in whichever
        // worker picked it up; what they find is reported to the parent's
        // record by path (see ParentMark). Scan roots have no parent record.
        if (w.exclude_paths.len > 0 and !w.isRoot(dir_path) and w.isExcludedPath(dir_path)) {
            self.stats.excluded += 1;
            try self.markParent(dir_path, .skipped);
            return;
        }

        if (w.exclude_cache_dirs and !w.isRoot(dir_path) and self.isCacheDir(dir_path)) {
            self.stats.excluded += 1;
            try self.markParent(dir_path, .skipped);
            return;
        }

        const dir = libc.opendir(self.pathZ(dir_path)) orelse {
            self.stats.errors += 1;
            try self.markParent(dir_path, .incomplete);
            return;
        };
        defer _ = libc.closedir(dir);
        const dir_fd = dirfd(dir);

        // A mount point inside a root belongs to another filesystem; reading
        // from one (a network share, a phone's DeviceFS) can block forever.
        if (w.one_filesystem and !w.isRoot(dir_path)) {
            const here = pstat.fstat(dir_fd) catch {
                self.stats.errors += 1;
                try self.markParent(dir_path, .incomplete);
                return;
            };
            if (std.mem.indexOfScalar(u64, w.root_devs.items, here.dev) == null) {
                self.stats.excluded += 1;
                try self.markParent(dir_path, .skipped);
                return;
            }
        }

        // When symlinks are followed a directory can be reached by more than
        // one route (`ln -s .. loop`), so every directory — not just the ones
        // entered through a link — is checked against the visited set, by the
        // identity of what was actually opened.
        if (w.follow_symlinks) {
            const identity = pstat.fstat(dir_fd) catch {
                self.stats.errors += 1;
                try self.markParent(dir_path, .incomplete);
                return;
            };
            if (!try w.markDirVisited(&identity)) {
                // Already walked via another route. Its files are reported
                // there, so from here the parent looks emptier than it is.
                self.stats.errors += 1;
                try self.markParent(dir_path, .incomplete);
                return;
            }
        }

        self.stats.dirs_traversed += 1;
        var record: DirRecord = .{ .path = dir_path };
        var found_here: u64 = 0;

        while (libc.readdir(dir)) |entry| {
            const name_ptr: [*:0]const u8 = @ptrCast(&entry.name);

            // Quick skip for . and ..
            if (name_ptr[0] == '.') {
                if (name_ptr[1] == 0) continue; // "."
                if (name_ptr[1] == '.' and name_ptr[2] == 0) continue; // ".."
                if (!w.include_hidden) {
                    record.skipped += 1;
                    continue; // Hidden entry
                }
            }

            const name = name_ptr[0..std.mem.len(name_ptr)];

            if (w.isExcluded(name)) {
                self.stats.excluded += 1;
                record.skipped += 1;
                continue;
            }

            if (dir_path.len + 1 + name.len > max_path) {
                self.noteError(&record); // Path too long
                continue;
            }

            // Use d_type to classify without a syscall when the filesystem
            // provides it; otherwise ask.
            var kind: u8 = entry.type;
            var known: ?Stat = null;
            if (kind == DT_UNKNOWN or kind == DT_REG) {
                // Relative to the directory we hold open: an absolute-path stat
                // makes the kernel re-walk every component of a deep path.
                const st = pstat.lstatAt(dir_fd, name_ptr) catch {
                    self.noteError(&record);
                    continue;
                };
                known = st;
                // Trust the stat over d_type: the entry may have been replaced
                // between readdir and stat.
                kind = if (st.isFile()) DT_REG else if (st.isDir()) DT_DIR else if (st.isLink()) DT_LNK else DT_OTHER;
            }

            switch (kind) {
                DT_REG => {
                    const path = try self.join(dir_path, name);
                    if (w.exclude_paths.len > 0 and w.isExcludedPath(path)) {
                        self.stats.excluded += 1;
                        record.skipped += 1;
                        continue;
                    }
                    if (try self.addFile(path, &known.?)) found_here += 1;
                },
                DT_DIR => try self.shared.push(try self.join(dir_path, name)),
                DT_LNK => {
                    if (try self.handleSymlink(dir_path, name, &record)) found_here += 1;
                },
                // Sockets, FIFOs, devices: no content to lose.
                else => record.skipped += 1,
            }
        }

        if (w.record_tree) try self.dirs.append(self.scratch(), record);
        if (w.monitor) |m| _ = m.files_found.fetchAdd(found_here, .monotonic);
    }

    fn join(self: *Worker, dir_path: []const u8, name: []const u8) ![]const u8 {
        const out = try self.strings().alloc(u8, dir_path.len + 1 + name.len);
        @memcpy(out[0..dir_path.len], dir_path);
        out[dir_path.len] = '/';
        @memcpy(out[dir_path.len + 1 ..], name);
        return out;
    }

    /// Record a regular file at `path` (already owned by the arena). Returns
    /// false if the size filter dropped it.
    fn addFile(self: *Worker, path: []const u8, st: *const Stat) !bool {
        const w = self.shared.walker;
        if (st.size < w.min_size) return false;
        if (w.max_size > 0 and st.size > w.max_size) return false;

        try self.files.append(self.scratch(), .{
            .path = path,
            .size = st.size,
            .ino = st.ino,
            .dev = st.dev,
            .mtime = st.mtime_sec,
            .nlink = st.nlink,
        });
        return true;
    }

    /// Handle a symlink entry. Skipped entirely unless -L/follow_symlinks is
    /// set. When following we stat the TARGET (an lstat here would record the
    /// link's own size/inode, which is never what the user meant) and descend
    /// into symlinked directories under a visited-dir guard so `ln -s .. loop`
    /// terminates instead of recursing. Returns true if a file was recorded.
    fn handleSymlink(self: *Worker, dir_path: []const u8, name: []const u8, record: *DirRecord) !bool {
        const w = self.shared.walker;
        if (!w.follow_symlinks and !w.record_tree) return false;

        const full = try self.join(dir_path, name);

        if (!w.follow_symlinks) {
            // Not followed, but a directory still *contains* the link: two
            // copies only match if the link is in both, pointing the same way.
            var target_buf: [4096]u8 = undefined;
            const n = libc.readlink(self.pathZ(full), &target_buf, target_buf.len);
            // A result that fills the buffer may have been truncated; treat it
            // as unreadable rather than compare a prefix.
            if (n < 0 or @as(usize, @intCast(n)) >= target_buf.len) {
                self.noteError(record);
            } else {
                try self.links.append(self.scratch(), .{
                    .path = full,
                    .target = try self.strings().dupe(u8, target_buf[0..@intCast(n)]),
                });
            }
            return false;
        }

        const target = pstat.stat(self.pathZ(full)) catch {
            self.noteError(record); // dangling link
            return false;
        };

        if (target.isDir()) {
            // Whether it was already walked is decided when it is opened.
            try self.shared.push(full);
            return false;
        }
        if (target.isFile()) return self.addFile(full, &target);

        record.skipped += 1;
        return false;
    }

    /// True if the directory holds a valid CACHEDIR.TAG. The tag must be a
    /// regular file starting with the fixed signature; its mere presence is
    /// not enough (that is the spec, and it stops an empty file of that name
    /// from hiding a directory from the scan).
    fn isCacheDir(self: *Worker, dir_path: []const u8) bool {
        const tag = "/CACHEDIR.TAG";
        if (dir_path.len + tag.len >= self.path_buf.len) return false;
        @memcpy(self.path_buf[0..dir_path.len], dir_path);
        @memcpy(self.path_buf[dir_path.len..][0..tag.len], tag);
        self.path_buf[dir_path.len + tag.len] = 0;

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

    fn noteError(self: *Worker, record: *DirRecord) void {
        self.stats.errors += 1;
        record.incomplete = true;
    }

    fn markParent(self: *Worker, child_path: []const u8, kind: MarkKind) !void {
        if (!self.shared.walker.record_tree) return;
        const slash = std.mem.lastIndexOfScalar(u8, child_path, '/') orelse return;
        const parent = if (slash == 0) child_path[0..1] else child_path[0..slash];
        try self.marks.append(self.scratch(), .{ .path = parent, .kind = kind });
    }
};

/// High-performance directory walker
pub const FastWalker = struct {
    allocator: std.mem.Allocator,

    // Configuration
    min_size: u64 = 0,
    max_size: u64 = 0,
    include_hidden: bool = false,
    follow_symlinks: bool = false,
    /// When false, extra hard links are reported as ordinary files.
    track_hardlinks: bool = true,
    /// Entry basenames to prune (borrowed).
    excludes: []const []const u8 = &.{},
    /// Absolute paths to prune, without a trailing slash (borrowed).
    exclude_paths: []const []const u8 = &.{},
    /// Prune directories holding a valid CACHEDIR.TAG.
    exclude_cache_dirs: bool = false,
    /// Do not enter a directory whose device is not one of the roots'.
    one_filesystem: bool = false,
    /// Prune entries named like another app's library package.
    skip_app_libraries: bool = false,
    /// Also record dirs, unfollowed symlinks and extra hard links.
    record_tree: bool = false,
    /// Progress out, cancellation in (borrowed).
    monitor: ?*types.Monitor = null,
    /// Worker threads; 0 = one per CPU.
    thread_count: u32 = 0,

    // Results. `files` is final (hard links resolved) only after `finish()`.
    files: std.ArrayListUnmanaged(FastFileEntry) = .empty,
    dirs: std.ArrayListUnmanaged(DirRecord) = .empty,
    links: std.ArrayListUnmanaged(LinkRecord) = .empty,
    stats: WalkStats = .{},

    storage: StringStorage = .{},
    /// `takeStrings()` was called: the strings are no longer ours to free.
    strings_released: bool = false,
    finished: bool = false,

    marks: std.ArrayListUnmanaged(ParentMark) = .empty,
    /// The roots walked so far; never pruned, whatever they are called.
    roots: std.ArrayListUnmanaged([]const u8) = .empty,
    /// The device of each root, for `one_filesystem`.
    root_devs: std.ArrayListUnmanaged(u64) = .empty,

    // Visited directories, used only under follow_symlinks to break cycles.
    seen_dirs: std.AutoHashMapUnmanaged(FileId, void) = .empty,
    seen_dirs_mutex: Mutex = .{},

    pub fn init(allocator: std.mem.Allocator) FastWalker {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *FastWalker) void {
        if (!self.strings_released) self.storage.deinit(self.allocator);
        self.files.deinit(self.allocator);
        self.dirs.deinit(self.allocator);
        self.links.deinit(self.allocator);
        self.marks.deinit(self.allocator);
        self.roots.deinit(self.allocator);
        self.root_devs.deinit(self.allocator);
        self.seen_dirs.deinit(self.allocator);
    }

    /// Configure size filters
    pub fn setSizeFilter(self: *FastWalker, min: u64, max: u64) void {
        self.min_size = min;
        self.max_size = max;
    }

    /// Enable hard link detection (default: enabled)
    pub fn enableHardLinkDetection(self: *FastWalker) void {
        self.track_hardlinks = true;
    }

    /// Report extra hard links as ordinary files (pure counting scans).
    pub fn disableHardLinkDetection(self: *FastWalker) void {
        self.track_hardlinks = false;
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

    pub fn setExcludePaths(self: *FastWalker, paths: []const []const u8) void {
        self.exclude_paths = paths;
    }

    fn isExcludedPath(self: *const FastWalker, path: []const u8) bool {
        for (self.exclude_paths) |p| {
            if (std.mem.eql(u8, p, path)) return true;
        }
        return false;
    }

    pub fn setOneFilesystem(self: *FastWalker, one: bool) void {
        self.one_filesystem = one;
    }

    pub fn setSkipAppLibraries(self: *FastWalker, skip: bool) void {
        self.skip_app_libraries = skip;
    }

    /// Record directories, unfollowed symlinks and extra hard links alongside
    /// the file list (see `dirs`, `links`, `FastFileEntry.link_of`).
    pub fn enableTreeRecording(self: *FastWalker) void {
        self.record_tree = true;
    }

    /// Publish progress to, and take cancellation from, `monitor`.
    pub fn setMonitor(self: *FastWalker, monitor: ?*types.Monitor) void {
        self.monitor = monitor;
    }

    /// Worker threads for the walk; 0 = one per CPU.
    pub fn setThreads(self: *FastWalker, count: u32) void {
        self.thread_count = count;
    }

    /// Walk a directory tree. May be called once per root on the same walker:
    /// results accumulate. Call `finish()` after the last root.
    pub fn walk(self: *FastWalker, root_path: []const u8) !void {
        std.debug.assert(!self.finished);
        if (root_path.len > max_path) return error.PathTooLong;

        // Remove trailing slash if present
        var trimmed = root_path;
        if (trimmed.len > 1 and trimmed[trimmed.len - 1] == '/') trimmed = trimmed[0 .. trimmed.len - 1];

        var shared: Shared = .{ .walker = self };
        defer shared.pending.deinit(self.allocator);

        // The calling thread is worker 0.
        var first: Worker = .{ .shared = &shared, .arena = std.heap.ArenaAllocator.init(self.allocator) };
        // Whatever happens below, what this worker recorded — at the very least
        // the root's own path string — ends up owned by the walker.
        var first_absorbed = false;
        defer if (!first_absorbed) self.absorb(&first) catch {};

        const root = try first.strings().dupe(u8, trimmed);

        // Check if root is file or directory. The root is always followed:
        // scanning `zdedupe /some/symlink-to-dir` should scan the target.
        const root_stat = try pstat.stat(first.pathZ(root));

        if (root_stat.isFile()) {
            if (try first.addFile(root, &root_stat)) {
                if (self.monitor) |m| _ = m.files_found.fetchAdd(1, .monotonic);
            }
            return;
        } else if (!root_stat.isDir()) {
            return error.NotADirectory;
        }

        // An unopenable root is an error for the caller, not a silently empty
        // walk — find out now, before any thread is started.
        const probe = libc.opendir(first.pathZ(root)) orelse return error.CannotOpenDirectory;
        _ = libc.closedir(probe);

        try self.roots.append(self.allocator, root);
        try self.root_devs.append(self.allocator, root_stat.dev);
        try shared.pending.append(self.allocator, root);

        const wanted: usize = if (self.thread_count == 0)
            std.Thread.getCpuCount() catch 4
        else
            self.thread_count;
        const extra = @max(1, @min(wanted, 64)) - 1;

        // Only the extra workers get threads, so a single-threaded walk starts
        // none at all.
        const workers = try self.allocator.alloc(Worker, extra);
        defer self.allocator.free(workers);
        const threads = try self.allocator.alloc(std.Thread, extra);
        defer self.allocator.free(threads);

        for (workers) |*worker| {
            worker.* = .{ .shared = &shared, .arena = std.heap.ArenaAllocator.init(self.allocator) };
        }
        var started: usize = 0;
        for (threads, workers) |*thread, *worker| {
            // Fewer threads than asked for is slower, not wrong.
            thread.* = std.Thread.spawn(.{}, Worker.run, .{worker}) catch break;
            started += 1;
        }

        first.run();
        for (threads[0..started]) |thread| thread.join();

        // Merge even after a failure: every arena must end up somewhere it
        // will be freed.
        var merge_error: ?anyerror = null;
        first_absorbed = true;
        self.absorb(&first) catch |err| {
            merge_error = err;
        };
        for (workers) |*worker| {
            self.absorb(worker) catch |err| {
                if (merge_error == null) merge_error = err;
            };
        }

        if (shared.failure) |err| return err;
        if (merge_error) |err| return err;
    }

    /// Move a worker's results into the walker.
    fn absorb(self: *FastWalker, worker: *Worker) !void {
        defer {
            worker.files.deinit(self.allocator);
            worker.dirs.deinit(self.allocator);
            worker.links.deinit(self.allocator);
            worker.marks.deinit(self.allocator);
        }
        // The arena first: if anything below fails, the strings are still
        // owned (and later freed) by the walker.
        self.storage.arenas.append(self.allocator, worker.arena) catch |err| {
            worker.arena.deinit();
            return err;
        };
        self.stats.add(worker.stats);
        try self.files.appendSlice(self.allocator, worker.files.items);
        try self.dirs.appendSlice(self.allocator, worker.dirs.items);
        try self.links.appendSlice(self.allocator, worker.links.items);
        try self.marks.appendSlice(self.allocator, worker.marks.items);
    }

    /// Resolve everything that could not be decided while the walk was
    /// running. Call once, after the last `walk()`.
    pub fn finish(self: *FastWalker) !void {
        if (self.finished) return;
        try self.resolveHardLinks();
        try self.applyParentMarks();

        self.stats.files_found = 0;
        self.stats.total_size = 0;
        for (self.files.items) |entry| {
            if (entry.link_of != null) continue;
            self.stats.files_found += 1;
            self.stats.total_size += entry.size;
        }
        self.finished = true;
    }

    /// Of several paths to one inode, the lexicographically smallest is the
    /// file and the rest are extra links.
    fn resolveHardLinks(self: *FastWalker) !void {
        if (!self.track_hardlinks) return;

        var primary: std.AutoHashMapUnmanaged(FileId, usize) = .empty;
        defer primary.deinit(self.allocator);

        // Pass 1: the smallest path per inode. A link count of exactly 1 rules
        // a file out without touching the map; 0 means "not reported".
        for (self.files.items, 0..) |entry, i| {
            if (self.cannotBeAliased(entry)) continue;
            const gop = try primary.getOrPut(self.allocator, .{ .dev = entry.dev, .ino = entry.ino });
            if (!gop.found_existing or
                std.mem.order(u8, entry.path, self.files.items[gop.value_ptr.*].path) == .lt)
            {
                gop.value_ptr.* = i;
            }
        }
        if (primary.count() == 0) return;

        if (self.record_tree) {
            // Extra links stay, pointed at their primary.
            for (self.files.items, 0..) |*entry, i| {
                if (self.cannotBeAliased(entry.*)) continue;
                const first = primary.get(.{ .dev = entry.dev, .ino = entry.ino }).?;
                if (first != i) {
                    entry.link_of = first;
                    self.stats.hard_links_skipped += 1;
                }
            }
            return;
        }

        // Extra links are dropped. Indices shift, but nothing refers to them:
        // the map is not consulted again and `link_of` is only used in
        // tree-recording mode. Decide first, compact after, so the lookups all
        // see the original indices.
        var is_extra = try std.DynamicBitSetUnmanaged.initEmpty(self.allocator, self.files.items.len);
        defer is_extra.deinit(self.allocator);
        for (self.files.items, 0..) |entry, i| {
            if (self.cannotBeAliased(entry)) continue;
            if (primary.get(.{ .dev = entry.dev, .ino = entry.ino }).? != i) is_extra.set(i);
        }
        var kept: usize = 0;
        for (self.files.items, 0..) |entry, i| {
            if (is_extra.isSet(i)) {
                self.stats.hard_links_skipped += 1;
                continue;
            }
            self.files.items[kept] = entry;
            kept += 1;
        }
        self.files.shrinkRetainingCapacity(kept);
    }

    /// True if no other recorded path can lead to this file's inode. A link
    /// count of 1 proves that only while symlinks are NOT followed: followed, a
    /// symlink to a file — or a symlinked directory above it — gives the same
    /// inode a second path without being a hard link, and missing that would
    /// report a file as a duplicate of itself.
    fn cannotBeAliased(self: *const FastWalker, entry: FastFileEntry) bool {
        return entry.nlink == 1 and !self.follow_symlinks;
    }

    fn applyParentMarks(self: *FastWalker) !void {
        if (self.marks.items.len == 0) return;

        var by_path: std.StringHashMapUnmanaged(usize) = .empty;
        defer by_path.deinit(self.allocator);
        try by_path.ensureTotalCapacity(self.allocator, @intCast(self.dirs.items.len));
        for (self.dirs.items, 0..) |record, i| by_path.putAssumeCapacity(record.path, i);

        for (self.marks.items) |mark| {
            const index = by_path.get(mark.path) orelse continue;
            switch (mark.kind) {
                .incomplete => self.dirs.items[index].incomplete = true,
                .skipped => self.dirs.items[index].skipped += 1,
            }
        }
        self.marks.clearRetainingCapacity();
    }

    /// Record a directory as visited. Returns false if it was already seen,
    /// which is how symlink cycles (`ln -s .. loop`) are broken. Two workers
    /// arriving at one directory by different routes race here; one wins.
    fn markDirVisited(self: *FastWalker, stat_buf: *const Stat) !bool {
        self.seen_dirs_mutex.lock();
        defer self.seen_dirs_mutex.unlock();
        const result = try self.seen_dirs.getOrPut(self.allocator, .{
            .dev = stat_buf.dev,
            .ino = stat_buf.ino,
        });
        return !result.found_existing;
    }

    fn isExcluded(self: *const FastWalker, name: []const u8) bool {
        for (self.excludes) |excluded| {
            // zig-lens-ignore: EQL-FOR-SECRETS file names, not secrets
            if (std.mem.eql(u8, excluded, name)) return true;
        }
        if (self.skip_app_libraries) {
            for (types.Config.app_library_suffixes) |suffix| {
                if (std.ascii.endsWithIgnoreCase(name, suffix)) return true;
            }
        }
        return false;
    }

    /// Scan roots are never pruned, whatever they are called or contain: the
    /// user asked for them by name. Compared by identity — a root is only ever
    /// queued as the very slice stored in `roots`.
    fn isRoot(self: *const FastWalker, path: []const u8) bool {
        for (self.roots.items) |root| {
            if (root.ptr == path.ptr and root.len == path.len) return true;
        }
        return false;
    }

    /// Hand every recorded string (paths, link targets) to the caller, who then
    /// owns the storage and must `deinit` it. The walker's lists stay valid for
    /// as long as that storage lives.
    ///
    /// Together with `toFileEntriesBorrowed` this is how a scan keeps ONE copy
    /// of each path instead of two: measured on 642k files, the second copy
    /// (one small heap allocation per file) was a quarter of peak memory.
    pub fn takeStrings(self: *FastWalker) StringStorage {
        const storage = self.storage;
        self.storage = .{};
        self.strings_released = true;
        return storage;
    }

    /// The files as `types.FileEntry`, pointing at the walker's own path
    /// strings. Only valid while the storage from `takeStrings` (or the walker)
    /// is alive; the entries must NOT be passed to `FileEntry.deinit`.
    pub fn toFileEntriesBorrowed(self: *FastWalker, allocator: std.mem.Allocator) !std.ArrayListUnmanaged(types.FileEntry) {
        std.debug.assert(self.finished);
        var entries: std.ArrayListUnmanaged(types.FileEntry) = .empty;
        errdefer entries.deinit(allocator);
        try entries.ensureTotalCapacityPrecise(allocator, self.files.items.len);

        for (self.files.items) |fast_entry| {
            entries.appendAssumeCapacity(.{
                .path = fast_entry.path,
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
//
// Behaviour against real trees (excludes, cache dirs, hard links, symlink
// cycles, unreadable directories, cancellation) is covered end to end through
// DupeFinder in tier1_anchors.zig.

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

test "a walk finds the same files whatever the thread count" {
    const Scratch = @import("testing_scratch.zig").Scratch;
    const allocator = std.testing.allocator;
    var scratch = try Scratch.init(allocator, "walk-threads");
    defer scratch.deinit();

    // Wide and deep enough that several workers really do overlap.
    var name_buf: [64]u8 = undefined;
    for (0..12) |d| {
        try scratch.makeDir(try std.fmt.bufPrint(&name_buf, "d{d}", .{d}));
        try scratch.makeDir(try std.fmt.bufPrint(&name_buf, "d{d}/sub", .{d}));
        for (0..6) |f| {
            try scratch.writeFile(try std.fmt.bufPrint(&name_buf, "d{d}/sub/f{d}.txt", .{ d, f }), "payload");
        }
    }

    var expected: ?u64 = null;
    for ([_]u32{ 1, 2, 8 }) |threads| {
        var walker = FastWalker.init(allocator);
        defer walker.deinit();
        walker.setThreads(threads);
        walker.setIncludeHidden(true);
        walker.enableTreeRecording();
        try walker.walk(scratch.path);
        try walker.finish();

        try std.testing.expectEqual(@as(u64, 72), walker.stats.files_found);
        try std.testing.expectEqual(@as(usize, 25), walker.dirs.items.len);

        // Order differs between runs; the set of paths must not.
        var digest: u64 = 0;
        for (walker.files.items) |entry| digest +%= std.hash.Wyhash.hash(0, entry.path);
        if (expected) |want| try std.testing.expectEqual(want, digest) else expected = digest;
    }
}

test "another app's library package is skipped by its extension" {
    const Scratch = @import("testing_scratch.zig").Scratch;
    var scratch = try Scratch.init(std.testing.allocator, "applib");
    defer scratch.deinit();
    try scratch.makeDir("Syndication.photoslibrary");
    try scratch.makeDir("Syndication.photoslibrary/originals");
    try scratch.writeFile("Syndication.photoslibrary/originals/a.jpg", "x");
    try scratch.writeFile("kept.jpg", "x");

    var fw = FastWalker.init(std.testing.allocator);
    defer fw.deinit();
    fw.setSkipAppLibraries(true);
    try fw.walk(scratch.path);
    try fw.finish();
    try std.testing.expectEqual(@as(usize, 1), fw.files.items.len);
    try std.testing.expectEqual(@as(u64, 1), fw.stats.excluded);
}

test "an excluded path skips that folder with its contents, or that one file" {
    const Scratch = @import("testing_scratch.zig").Scratch;
    var scratch = try Scratch.init(std.testing.allocator, "exclpath");
    defer scratch.deinit();
    try scratch.makeDir("private");
    try scratch.makeDir("private/deep");
    try scratch.writeFile("private/deep/a.txt", "x");
    try scratch.writeFile("skip-me.txt", "x");
    try scratch.writeFile("kept.txt", "x");
    const folder = try scratch.join("private");
    defer std.testing.allocator.free(folder);
    const file = try scratch.join("skip-me.txt");
    defer std.testing.allocator.free(file);

    var fw = FastWalker.init(std.testing.allocator);
    defer fw.deinit();
    fw.setExcludePaths(&.{ folder, file });
    try fw.walk(scratch.path);
    try fw.finish();
    try std.testing.expectEqual(@as(usize, 1), fw.files.items.len);
    try std.testing.expectEqual(@as(u64, 2), fw.stats.excluded);
}
