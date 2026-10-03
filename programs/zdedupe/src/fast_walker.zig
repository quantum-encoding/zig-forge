//! Parallel directory walker for trees of millions of files
//!
//! A walk is almost pure kernel time — one `getdents` per directory and one
//! `statx` per file — so the two things that matter are how much work each
//! syscall makes the kernel do, and how many of them are in flight at once:
//!
//!   * Files are stat'ed *relative to the open directory* (`statx(dirfd, name)`),
//!     so the kernel does not re-resolve every component of a long absolute
//!     path for each file. On macOS the listing itself carries each file's
//!     stat (`getattrlistbulk`, see dirstream.zig), so there is no per-file
//!     syscall at all.
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
const libc = @import("sys.zig").c;

const dirstream = @import("dirstream.zig");
const DirStream = dirstream.DirStream;

// Stat comes from pstat.zig: std.c ($INODE64-correct) on Darwin, statx on Linux.
const pstat = @import("pstat.zig");
const filters = @import("filters.zig");
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
    /// Bytes on disk; see `pstat.Stat.allocated`.
    allocated: u64 = 0,
    /// A cloud placeholder whose content is not on disk.
    dataless: bool = false,
    /// APFS data-stream id; see `pstat.Stat.clone_id`.
    clone_id: u64 = 0,
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

/// Work shared between the workers of one `walk()` call. Lives in a `Crew`
/// on the heap, so a worker abandoned in a blocked open can still reach it.
const Shared = struct {
    walker: *FastWalker,
    /// The walker's allocator, copied: an abandoned worker must not read the
    /// walker, which may be gone by the time its open returns.
    allocator: std.mem.Allocator,
    no_materialize: bool = false,
    crew: ?*Crew = null,
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
        try self.pending.append(self.allocator, path);
        self.work_available.signal();
    }

    /// Stop every worker: idle ones wake and leave, busy ones leave at their
    /// next check. The walk's supervisor uses it on cancel, when the workers
    /// still running may all be waiting for one that is stuck in an open.
    fn stop(self: *Shared, err: anyerror) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.failure == null) self.failure = err;
        self.work_available.broadcast();
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

const DT_UNKNOWN = dirstream.DT_UNKNOWN;
const DT_DIR = dirstream.DT_DIR;
const DT_REG = dirstream.DT_REG;
const DT_LNK = dirstream.DT_LNK;
const DT_OTHER = dirstream.DT_OTHER;

/// Where a worker is, as its supervisor (`FastWalker.supervise`) sees it.
const WorkerState = enum(u8) {
    running,
    /// Inside an open that may block indefinitely (a consent dialog nobody
    /// answers, a security agent holding the call).
    in_open,
    /// Given up on by the supervisor while `in_open`: the walk has returned
    /// without it. When its open does return it touches nothing but its crew.
    abandoned,
    finished,
};

/// One thread's private state.
const Worker = struct {
    shared: *Shared,
    state: std.atomic.Value(WorkerState) = .init(.running),
    /// Its results were moved into the walker; the crew must not free them.
    absorbed: bool = false,
    /// Position among the walk's workers; names its Monitor slot.
    index: usize = 0,
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
            // Abandoned: the walk is over and nothing outside the crew may
            // be touched, not even the shared queue's bookkeeping.
            if (failure) |err| if (err == error.Abandoned) return;
            self.shared.done(failure);
        }
    }

    /// Thread entry: run, then let go of the crew (which the last one out frees).
    fn threadMain(self: *Worker) void {
        if (self.shared.no_materialize) _ = noMaterializeThisThread();
        self.run();
        if (self.state.cmpxchgStrong(.running, .finished, .acq_rel, .acquire) != null) {
            // Abandoned while in an open, so the supervisor has detached
            // this thread; it only reaches here once the open returned.
        }
        self.shared.crew.?.release();
    }

    /// Mark the start of an open that may block; see `WorkerState`.
    fn enterOpen(self: *Worker) void {
        self.state.store(.in_open, .release);
    }

    /// False if the supervisor abandoned this worker while it was blocked.
    fn leaveOpen(self: *Worker) bool {
        return self.state.cmpxchgStrong(.in_open, .running, .acq_rel, .acquire) == null;
    }

    fn strings(self: *Worker) std.mem.Allocator {
        return self.arena.allocator();
    }

    fn scratch(self: *const Worker) std.mem.Allocator {
        return self.shared.allocator;
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
            m.begin(self.index, dir_path);
        }
        // Not touched again once abandoned: the monitor may be gone.
        var abandoned = false;
        defer if (!abandoned) if (w.monitor) |m| m.end(self.index);

        // Refused when the walk asked first (see `probeProtected`): no second
        // prompt, no second wait.
        if (w.isDenied(dir_path)) {
            self.stats.errors += 1;
            try self.markParent(dir_path, .incomplete);
            return;
        }

        // The checks that need the directory itself happen here, in whichever
        // worker picked it up; what they find is reported to the parent's
        // record by path (see ParentMark). Scan roots have no parent record.
        if (w.exclude_paths.len > 0 and !w.isRoot(dir_path) and w.isExcludedPath(dir_path)) {
            self.stats.excluded += 1;
            try self.markParent(dir_path, .skipped);
            return;
        }

        if (w.skip_app_libraries and !w.isRoot(dir_path) and isAppLibraryDir(dir_path)) {
            self.stats.excluded += 1;
            try self.markParent(dir_path, .skipped);
            return;
        }

        self.enterOpen();
        if (builtin.is_test) testing_hooks.beforeOpen(dir_path);
        const opened = DirStream.open(self.pathZ(dir_path));
        if (!self.leaveOpen()) {
            abandoned = true;
            if (opened) |o| {
                var s = o;
                s.close();
            }
            return error.Abandoned;
        }
        var stream = opened orelse {
            self.stats.errors += 1;
            try self.markParent(dir_path, .incomplete);
            return;
        };
        defer stream.close();
        const dir_fd = stream.fd();

        if (w.exclude_cache_dirs and !w.isRoot(dir_path) and isCacheDir(dir_fd)) {
            self.stats.excluded += 1;
            try self.markParent(dir_path, .skipped);
            return;
        }

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
        // A directory can hold millions of entries: report and honour cancel
        // as it is read, not only once it is finished.
        var unreported: u64 = 0;
        var entries_seen: u32 = 0;

        while (true) {
            const entry = (stream.next() catch {
                self.noteError(&record);
                break;
            }) orelse break;
            entries_seen +%= 1;
            if (entries_seen % 4096 == 0) {
                if (w.monitor) |m| {
                    if (m.cancelled()) return error.Cancelled;
                    _ = m.files_found.fetchAdd(found_here - unreported, .monotonic);
                    unreported = found_here;
                }
            }
            const name_ptr = entry.name;

            if (name_ptr[0] == '.' and !w.include_hidden) {
                record.skipped += 1;
                continue; // Hidden entry
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

            // Classify from the listing when it says enough (d_type, or the
            // bulk listing's own stat); otherwise ask.
            var kind: u8 = entry.kind;
            var known: ?Stat = entry.stat;
            if (known == null and (kind == DT_UNKNOWN or kind == DT_REG)) {
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
        if (w.monitor) |m| _ = m.files_found.fetchAdd(found_here - unreported, .monotonic);
    }

    fn join(self: *Worker, dir_path: []const u8, name: []const u8) ![]const u8 {
        // Under a root the separator is already there: "/x" and "C:/x", not
        // "//x" and "C://x".
        const base = if (dir_path.len > 0 and dir_path[dir_path.len - 1] == '/') dir_path[0 .. dir_path.len - 1] else dir_path;
        const out = try self.strings().alloc(u8, base.len + 1 + name.len);
        @memcpy(out[0..base.len], base);
        out[base.len] = '/';
        @memcpy(out[base.len + 1 ..], name);
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
            .allocated = st.allocated,
            .dataless = st.dataless,
            .clone_id = st.clone_id,
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
    /// Looked up relative to the open directory: one name to resolve, and a
    /// miss (nearly every directory) is answered from the name cache.
    fn isCacheDir(dir_fd: c_int) bool {
        // NOFOLLOW + NONBLOCK: never chase a link out of the tree, never hang
        // on a FIFO someone named CACHEDIR.TAG.
        const fd = libc.openat(
            dir_fd,
            "CACHEDIR.TAG",
            .{ .ACCMODE = .RDONLY, .NONBLOCK = true, .NOFOLLOW = true, .CLOEXEC = true },
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
        const parent = filters.parentDir(child_path) orelse return;
        try self.marks.append(self.scratch(), .{ .path = parent, .kind = kind });
    }
};

/// The workers of one walk and what they share, on the heap and reference
/// counted: the walk holds one reference and each started thread another.
/// When a cancelled walk gives up on a worker stuck in an open, it returns
/// without it; that thread drops its reference when its open finally comes
/// back, and whoever drops the last one frees the crew - including the
/// abandoned worker's buffers, which its open was using until then.
const Crew = struct {
    allocator: std.mem.Allocator,
    shared: Shared,
    workers: []Worker,
    threads: []std.Thread,
    refs: std.atomic.Value(usize) = .init(1),

    fn create(allocator: std.mem.Allocator, walker: *FastWalker, count: usize) !*Crew {
        const crew = try allocator.create(Crew);
        errdefer allocator.destroy(crew);
        const workers = try allocator.alloc(Worker, count);
        errdefer allocator.free(workers);
        const threads = try allocator.alloc(std.Thread, count);
        crew.* = .{
            .allocator = allocator,
            .shared = .{ .walker = walker, .allocator = allocator, .no_materialize = walker.no_materialize },
            .workers = workers,
            .threads = threads,
        };
        crew.shared.crew = crew;
        for (workers, 0..) |*worker, index| {
            worker.* = .{ .shared = &crew.shared, .index = index, .arena = std.heap.ArenaAllocator.init(allocator) };
        }
        return crew;
    }

    fn release(self: *Crew) void {
        if (self.refs.fetchSub(1, .acq_rel) != 1) return;
        const allocator = self.allocator;
        for (self.workers) |*worker| {
            // An absorbed worker's arena and lists now belong to the walker.
            if (worker.absorbed) continue;
            worker.arena.deinit();
            worker.files.deinit(allocator);
            worker.dirs.deinit(allocator);
            worker.links.deinit(allocator);
            worker.marks.deinit(allocator);
        }
        self.shared.pending.deinit(allocator);
        allocator.free(self.workers);
        allocator.free(self.threads);
        allocator.destroy(self);
        if (builtin.is_test) _ = testing_hooks.freed.fetchAdd(1, .release);
    }
};

/// Opens a list of directories one after another on a thread of its own, so
/// a walk can give up on an open that never returns. Reference counted like
/// `Crew`: the walk and the thread each hold one.
const ProbeJob = struct {
    allocator: std.mem.Allocator,
    paths: []const [:0]const u8,
    /// errno of each open, 0 for success; valid once `finished`.
    results: []c_int,
    /// Index of the path being opened, for the monitor.
    current: std.atomic.Value(usize) = .init(0),
    state: std.atomic.Value(WorkerState) = .init(.running),
    refs: std.atomic.Value(usize) = .init(2),
    no_materialize: bool,

    fn threadMain(self: *ProbeJob) void {
        if (self.no_materialize) _ = noMaterializeThisThread();
        for (self.paths, self.results, 0..) |path, *result, i| {
            self.current.store(i, .release);
            self.state.store(.in_open, .release);
            if (builtin.is_test) testing_hooks.beforeOpen(path);
            const fd = libc.open(path.ptr, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true }, @as(libc.mode_t, 0));
            const err: c_int = if (fd < 0) @intFromEnum(libc.errno(fd)) else 0;
            if (fd >= 0) _ = libc.close(fd);
            if (self.state.cmpxchgStrong(.in_open, .running, .acq_rel, .acquire) != null) break; // abandoned
            result.* = err;
        }
        _ = self.state.cmpxchgStrong(.running, .finished, .acq_rel, .acquire);
        self.release();
    }

    fn release(self: *ProbeJob) void {
        if (self.refs.fetchSub(1, .acq_rel) != 1) return;
        for (self.paths) |path| self.allocator.free(path);
        self.allocator.free(self.paths);
        self.allocator.free(self.results);
        self.allocator.destroy(self);
        if (builtin.is_test) _ = testing_hooks.freed.fetchAdd(1, .release);
    }
};

/// Test-only: an open that hangs on demand, standing in for a consent dialog
/// nobody answers.
const testing_hooks = struct {
    /// Opens of a path ending in this hang until `release` is set.
    var hang_suffix: ?[]const u8 = null;
    var release: std.atomic.Value(bool) = .init(false);
    var hung: std.atomic.Value(usize) = .init(0);
    /// Crews and probe jobs freed.
    var freed: std.atomic.Value(usize) = .init(0);

    fn beforeOpen(path: []const u8) void {
        const suffix = hang_suffix orelse return;
        if (!std.mem.endsWith(u8, path, suffix)) return;
        _ = hung.fetchAdd(1, .release);
        while (!release.load(.acquire)) sleepTick();
    }
};

/// How long a cancelled walk waits for a worker stuck in an open before it
/// gives up on it.
const abandon_grace_ns: u64 = 250 * std.time.ns_per_ms;
const supervise_tick_ms: u32 = 10;

fn sleepTick() void {
    if (comptime builtin.os.tag == .windows) {
        const Sleep = @extern(*const fn (ms: u32) callconv(.winapi) void, .{ .name = "Sleep", .library_name = "kernel32" });
        Sleep(supervise_tick_ms);
    } else {
        const usleep = @extern(*const fn (us: c_uint) callconv(.c) c_int, .{ .name = "usleep" });
        _ = usleep(supervise_tick_ms * 1000);
    }
}

/// `path` lies below `root` (not at it).
fn isStrictlyInside(path: []const u8, root: []const u8) bool {
    if (root.len == 1 and root[0] == '/') return path.len > 1;
    return path.len > root.len + 1 and std.mem.startsWith(u8, path, root) and path[root.len] == '/';
}

/// Folders macOS guards with a consent prompt, or with Full Disk Access,
/// relative to the home directory. `probeProtected` opens those inside a
/// root one at a time before the parallel walk, so at most one dialog is
/// pending and the monitor names it; one refused then is not asked again.
const protected_folders = [_][]const u8{
    "Desktop",                     "Documents",           "Downloads",
    "Pictures",                    "Movies",              "Music",
    "Public",                      "Library/Mobile Documents", "Library/CloudStorage",
    "Library/Mail",                "Library/Messages",    "Library/Safari",
    "Library/Calendars",           "Library/Reminders",   "Library/HomeKit",
    "Library/Containers",          "Library/Group Containers",
};
/// Of those, folders whose every child is another app's data, each guarded
/// on its own: their children are opened one at a time too.
const protected_parents = [_][]const u8{ "Library/Containers", "Library/Group Containers" };

extern "c" fn getiopolicy_np(iotype: c_int, scope: c_int) c_int;
extern "c" fn setiopolicy_np(iotype: c_int, scope: c_int, policy: c_int) c_int;

/// sys/resource.h
const IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES: c_int = 3;
const IOPOL_SCOPE_THREAD: c_int = 1;
const IOPOL_MATERIALIZE_DATALESS_FILES_OFF: c_int = 1;

/// macOS: from here on this thread never makes the system fetch a cloud
/// placeholder (iCloud Drive with "Optimize Mac Storage", File Provider
/// folders). An access that would have downloaded one fails instead, so a
/// dataless directory is reported unreadable rather than pulled down. Returns
/// the policy it replaced, for `restoreMaterialize`.
pub fn noMaterializeThisThread() c_int {
    if (comptime builtin.os.tag != .macos) return 0;
    const previous = getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD);
    _ = setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD, IOPOL_MATERIALIZE_DATALESS_FILES_OFF);
    return previous;
}

pub fn restoreMaterialize(previous: c_int) void {
    if (comptime builtin.os.tag != .macos) return;
    if (previous >= 0) _ = setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD, previous);
}

fn isAppLibraryDir(dir_path: []const u8) bool {
    for (types.Config.app_library_dirs) |suffix| {
        if (std.mem.endsWith(u8, dir_path, suffix)) return true;
    }
    return false;
}

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
    /// macOS: never trigger a download of a cloud placeholder while walking
    /// (see `noMaterializeThisThread`).
    no_materialize: bool = false,
    /// Progress out, cancellation in (borrowed).
    monitor: ?*types.Monitor = null,
    /// Worker threads; 0 = one per CPU.
    thread_count: u32 = 0,
    /// Folders whose open was refused when `probeProtected` asked first;
    /// workers skip them (unreadable) instead of asking again.
    denied: std.ArrayListUnmanaged([]const u8) = .empty,

    // Results. `files` is final (hard links resolved) only after `finish()`.
    /// Every file found, in walk order: a worker's records are appended as
    /// it is absorbed, so one directory's files stay together.
    files: std.ArrayListUnmanaged(types.FileEntry) = .empty,
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
        self.denied.deinit(self.allocator);
    }

    fn isDenied(self: *const FastWalker, path: []const u8) bool {
        for (self.denied.items) |d| {
            if (std.mem.eql(u8, d, path)) return true;
        }
        return false;
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

    /// Under `one_filesystem`, also enter directories on device `dev`. For a
    /// volume split into several filesystems that one path tree joins (macOS:
    /// the sealed system volume and the Data volume behind its firmlinks).
    pub fn allowDevice(self: *FastWalker, dev: u64) !void {
        try self.root_devs.append(self.allocator, dev);
    }

    /// Never download a cloud placeholder to walk it (macOS; a no-op elsewhere).
    pub fn setNoMaterialize(self: *FastWalker, on: bool) void {
        self.no_materialize = on;
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

        const previous_policy: c_int = if (self.no_materialize) noMaterializeThisThread() else -1;
        defer if (self.no_materialize) restoreMaterialize(previous_policy);

        // Remove trailing slash if present
        var trimmed = root_path;
        if (trimmed.len > 1 and trimmed[trimmed.len - 1] == '/') trimmed = trimmed[0 .. trimmed.len - 1];

        // The root's own bookkeeping (its path string, a root that is a
        // file) is done here, by a worker that never runs on a thread.
        var root_shared: Shared = .{ .walker = self, .allocator = self.allocator };
        var first: Worker = .{ .shared = &root_shared, .arena = std.heap.ArenaAllocator.init(self.allocator) };
        // Whatever happens below, what this worker recorded — at the very least
        // the root's own path string — ends up owned by the walker.
        defer self.absorb(&first) catch {};

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

        // The root and the guarded folders inside it are opened one at a
        // time first. An unopenable root is an error for the caller, not a
        // silently empty walk.
        try self.probeProtected(&first, root);

        try self.roots.append(self.allocator, root);
        try self.root_devs.append(self.allocator, root_stat.dev);

        const wanted: usize = if (self.thread_count == 0)
            std.Thread.getCpuCount() catch 4
        else
            self.thread_count;
        const count = @max(1, @min(wanted, 64));

        const crew = try Crew.create(self.allocator, self, count);
        // The walk's own reference; detached threads hold theirs.
        defer crew.release();
        try crew.shared.pending.append(self.allocator, root);

        // Every worker gets a thread, so that this one can stop waiting for a
        // worker whose open never returns. Fewer threads than asked for is
        // slower, not wrong.
        var started: usize = 0;
        for (crew.threads, crew.workers) |*thread, *worker| {
            _ = crew.refs.fetchAdd(1, .acq_rel);
            thread.* = std.Thread.spawn(.{}, Worker.threadMain, .{worker}) catch {
                _ = crew.refs.fetchSub(1, .acq_rel);
                break;
            };
            started += 1;
        }
        if (started == 0) {
            crew.workers[0].run();
            crew.workers[0].state.store(.finished, .release);
        }

        const abandoned = self.supervise(crew, started);

        if (abandoned) {
            // The stuck threads were detached; the crew goes with the last of
            // them. Nothing they found is kept: the walk was cancelled.
            return error.Cancelled;
        }

        // Merge even after a failure: every arena must end up somewhere it
        // will be freed.
        var merge_error: ?anyerror = null;
        for (crew.workers) |*worker| {
            worker.absorbed = true;
            self.absorb(worker) catch |err| {
                if (merge_error == null) merge_error = err;
            };
        }

        if (crew.shared.failure) |err| return err;
        if (merge_error) |err| return err;
    }

    /// Wait for the crew's threads. On cancel, idle workers are woken and
    /// told to stop; a worker still inside an open `abandon_grace_ns` later
    /// is given up on (its thread detached). True if any was.
    fn supervise(self: *FastWalker, crew: *Crew, started: usize) bool {
        var cancel_at: ?u64 = null;
        while (true) {
            var live: usize = 0;
            for (crew.workers[0..started]) |*worker| {
                switch (worker.state.load(.acquire)) {
                    .finished, .abandoned => {},
                    .running, .in_open => live += 1,
                }
            }
            if (live == 0) break;
            if (self.monitor) |m| if (m.cancelled()) {
                const now = types.nowNs();
                if (cancel_at == null) {
                    cancel_at = now;
                    crew.shared.stop(error.Cancelled);
                } else if (now - cancel_at.? >= abandon_grace_ns) {
                    for (crew.workers[0..started]) |*worker| {
                        _ = worker.state.cmpxchgStrong(.in_open, .abandoned, .acq_rel, .acquire);
                    }
                }
            };
            sleepTick();
        }
        var abandoned = false;
        for (crew.workers[0..started], crew.threads[0..started]) |*worker, thread| {
            if (worker.state.load(.acquire) == .abandoned) {
                thread.detach();
                abandoned = true;
            } else {
                thread.join();
            }
        }
        return abandoned;
    }

    /// Open `root`, and the guarded folders inside it (`protected_folders`,
    /// macOS), one at a time on a thread of their own, before the parallel
    /// walk. A consent dialog then appears for one folder at a time, with
    /// that folder named by the monitor, instead of eight workers each
    /// parking on a different one; and a cancel can return while one is
    /// pending. Folders refused (EPERM / EACCES: denied before, or now) are
    /// recorded in `denied` and skipped by the walk, never asked again.
    fn probeProtected(self: *FastWalker, first: *Worker, root: []const u8) !void {
        var paths: std.ArrayListUnmanaged([:0]const u8) = .empty;
        errdefer {
            for (paths.items) |p| self.allocator.free(p);
            paths.deinit(self.allocator);
        }
        try paths.append(self.allocator, try self.allocator.dupeZ(u8, root));

        if (comptime builtin.os.tag.isDarwin()) {
            if (libc.getenv("HOME")) |home_z| {
                const home = std.mem.span(home_z);
                for (protected_folders) |rel| {
                    const full = try std.fmt.allocPrintSentinel(self.allocator, "{s}/{s}", .{ home, rel }, 0);
                    if (!isStrictlyInside(full, root) or self.isExcludedPath(full)) {
                        self.allocator.free(full);
                        continue;
                    }
                    try paths.append(self.allocator, full);
                }
            }
        }

        const results = try self.runProbe(try paths.toOwnedSlice(self.allocator));
        defer self.allocator.free(results.errnos);
        defer {
            for (results.paths) |p| self.allocator.free(p);
            self.allocator.free(results.paths);
        }
        if (results.errnos[0] != 0) return error.CannotOpenDirectory;
        try self.recordDenied(first, results.paths[1..], results.errnos[1..]);

        // Second round: each app's own container, below the parents that
        // were opened.
        if (comptime builtin.os.tag.isDarwin()) {
            var children: std.ArrayListUnmanaged([:0]const u8) = .empty;
            errdefer {
                for (children.items) |p| self.allocator.free(p);
                children.deinit(self.allocator);
            }
            for (results.paths[1..], results.errnos[1..]) |path, err| {
                if (err != 0) continue;
                const is_parent = for (protected_parents) |rel| {
                    if (std.mem.endsWith(u8, path, rel)) break true;
                } else false;
                if (!is_parent) continue;
                const dir = libc.opendir(path.ptr) orelse continue;
                defer _ = libc.closedir(dir);
                while (libc.readdir(dir)) |entry| {
                    const name: [*:0]const u8 = @ptrCast(&entry.name);
                    if (name[0] == '.') continue;
                    const full = try std.fmt.allocPrintSentinel(self.allocator, "{s}/{s}", .{ path, std.mem.span(name) }, 0);
                    if (entry.type != DT_DIR or self.isExcludedPath(full)) {
                        self.allocator.free(full);
                        continue;
                    }
                    try children.append(self.allocator, full);
                }
            }
            if (children.items.len > 0) {
                const more = try self.runProbe(try children.toOwnedSlice(self.allocator));
                defer self.allocator.free(more.errnos);
                defer {
                    for (more.paths) |p| self.allocator.free(p);
                    self.allocator.free(more.paths);
                }
                try self.recordDenied(first, more.paths, more.errnos);
            } else children.deinit(self.allocator);
        }
    }

    fn recordDenied(self: *FastWalker, first: *Worker, paths: []const [:0]const u8, errnos: []const c_int) !void {
        for (paths, errnos) |path, err| {
            if (err == @intFromEnum(libc.E.PERM) or err == @intFromEnum(libc.E.ACCES)) {
                try self.denied.append(self.allocator, try first.strings().dupe(u8, path));
            }
        }
    }

    const ProbeResults = struct { paths: []const [:0]const u8, errnos: []c_int };

    /// Open each of `paths` (taken over) in turn on a thread of its own and
    /// wait, naming the one being opened in monitor slot 0. On cancel, an
    /// open still pending after `abandon_grace_ns` is given up on.
    fn runProbe(self: *FastWalker, paths: []const [:0]const u8) !ProbeResults {
        const results = self.allocator.alloc(c_int, paths.len) catch |err| {
            for (paths) |p| self.allocator.free(p);
            self.allocator.free(paths);
            return err;
        };
        @memset(results, 0);
        const job = self.allocator.create(ProbeJob) catch |err| {
            for (paths) |p| self.allocator.free(p);
            self.allocator.free(paths);
            self.allocator.free(results);
            return err;
        };
        job.* = .{ .allocator = self.allocator, .paths = paths, .results = results, .no_materialize = self.no_materialize };

        const thread = std.Thread.spawn(.{}, ProbeJob.threadMain, .{job}) catch {
            // No thread: open them here, without the protection.
            _ = job.refs.fetchSub(1, .acq_rel);
            job.threadMain();
            return self.takeProbe(job);
        };

        var cancel_at: ?u64 = null;
        var shown: ?usize = null;
        defer if (shown != null) if (self.monitor) |m| m.end(0);
        while (job.state.load(.acquire) != .finished) {
            if (self.monitor) |m| {
                const i = job.current.load(.acquire);
                if (shown != i) {
                    m.begin(0, paths[i]);
                    shown = i;
                }
                if (m.cancelled()) {
                    const now = types.nowNs();
                    if (cancel_at == null) cancel_at = now;
                    if (now - cancel_at.? >= abandon_grace_ns and
                        job.state.cmpxchgStrong(.in_open, .abandoned, .acq_rel, .acquire) == null)
                    {
                        thread.detach();
                        job.release();
                        return error.Cancelled;
                    }
                }
            }
            sleepTick();
        }
        thread.join();
        return self.takeProbe(job);
    }

    /// The results of a finished probe; the job is released.
    fn takeProbe(self: *FastWalker, job: *ProbeJob) !ProbeResults {
        const out: ProbeResults = .{ .paths = job.paths, .errnos = job.results };
        // The paths and results now belong to the caller.
        job.paths = &.{};
        job.results = &.{};
        _ = self;
        job.release();
        return out;
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
        // Converted here, one worker's batch at a time, so the walk's own
        // records and the final list are never both whole in memory.
        try self.files.ensureUnusedCapacity(self.allocator, worker.files.items.len);
        for (worker.files.items) |fast| {
            self.files.appendAssumeCapacity(.{
                .path = fast.path,
                .size = fast.size,
                .inode = fast.ino,
                .dev = fast.dev,
                .mtime = fast.mtime,
                .hash = null,
                .quick_hash = null,
                .nlink = fast.nlink,
                .allocated = fast.allocated,
                .dataless = fast.dataless,
                .clone_id = fast.clone_id,
            });
        }
        worker.files.clearAndFree(self.allocator);
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
            const gop = try primary.getOrPut(self.allocator, .{ .dev = entry.dev, .ino = entry.inode });
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
                const first = primary.get(.{ .dev = entry.dev, .ino = entry.inode }).?;
                if (first != i) {
                    entry.link_of = first;
                    // Two paths reach it, so it has at least two links. Where
                    // the walk saw no link count (Windows, whose directory
                    // records carry none), this is how the primary learns it.
                    self.files.items[first].nlink = @max(self.files.items[first].nlink, 2);
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
            if (primary.get(.{ .dev = entry.dev, .ino = entry.inode }).? != i) is_extra.set(i);
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
    fn cannotBeAliased(self: *const FastWalker, entry: types.FileEntry) bool {
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
    /// Together with `takeFiles` this is how a scan keeps ONE copy
    /// of each path instead of two: measured on 642k files, the second copy
    /// (one small heap allocation per file) was a quarter of peak memory.
    pub fn takeStrings(self: *FastWalker) StringStorage {
        const storage = self.storage;
        self.storage = .{};
        self.strings_released = true;
        return storage;
    }

    /// Hand the file list to the caller, who then owns it. The entries point
    /// at the walker's path strings: they are only valid while the storage
    /// from `takeStrings` (or the walker) is alive, and must NOT be passed to
    /// `FileEntry.deinit`. Indices (`link_of`) are unchanged.
    pub fn takeFiles(self: *FastWalker) std.ArrayListUnmanaged(types.FileEntry) {
        std.debug.assert(self.finished);
        const files = self.files;
        self.files = .empty;
        return files;
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

test "Steam's install and game libraries are skipped, unless picked as the root" {
    const Scratch = @import("testing_scratch.zig").Scratch;
    var scratch = try Scratch.init(std.testing.allocator, "steam");
    defer scratch.deinit();
    try scratch.makeDir(".local");
    try scratch.makeDir(".local/share");
    try scratch.makeDir(".local/share/Steam");
    try scratch.writeFile(".local/share/Steam/steam.sh", "x");
    try scratch.makeDir("Games");
    try scratch.makeDir("Games/steamapps");
    try scratch.makeDir("Games/steamapps/common");
    try scratch.writeFile("Games/steamapps/common/game.pak", "x");
    // Only whole components count.
    try scratch.makeDir("notsteamapps");
    try scratch.writeFile("notsteamapps/kept.txt", "x");
    try scratch.writeFile("kept.txt", "x");

    var fw = FastWalker.init(std.testing.allocator);
    defer fw.deinit();
    fw.setIncludeHidden(true);
    fw.setSkipAppLibraries(true);
    try fw.walk(scratch.path);
    try fw.finish();
    try std.testing.expectEqual(@as(usize, 2), fw.files.items.len);
    try std.testing.expectEqual(@as(u64, 2), fw.stats.excluded);

    // A library the user picks is scanned: they asked for it by name.
    const lib = try scratch.join("Games/steamapps");
    defer std.testing.allocator.free(lib);
    var picked = FastWalker.init(std.testing.allocator);
    defer picked.deinit();
    picked.setSkipAppLibraries(true);
    try picked.walk(lib);
    try picked.finish();
    try std.testing.expectEqual(@as(usize, 1), picked.files.items.len);
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

fn cancelAfter(monitor: *types.Monitor, opens_hung: usize) void {
    while (testing_hooks.hung.load(.acquire) < opens_hung) sleepTick();
    monitor.cancel();
}

/// Run a walk of `root` that hangs in the open of a path ending `suffix`,
/// cancel it once the open is stuck, and check that the walk returns without
/// waiting for the open - then let the open finish and the abandoned thread
/// free what it held.
fn expectCancelReturnsDespiteStuckOpen(root: []const u8, suffix: []const u8, freed_after: usize) !void {
    testing_hooks.hang_suffix = suffix;
    testing_hooks.release.store(false, .release);
    testing_hooks.hung.store(0, .release);
    defer testing_hooks.hang_suffix = null;
    const freed_before = testing_hooks.freed.load(.acquire);

    var monitor: types.Monitor = .{};
    var walker = FastWalker.init(std.testing.allocator);
    defer walker.deinit();
    walker.setMonitor(&monitor);
    walker.setThreads(4);
    const canceller = try std.Thread.spawn(.{}, cancelAfter, .{ &monitor, 1 });
    defer canceller.join();

    const started = types.nowNs();
    try std.testing.expectError(error.Cancelled, walker.walk(root));
    // Back within the grace period plus a few ticks, the open still stuck.
    try std.testing.expect(types.nowNs() - started < 5 * std.time.ns_per_s);
    try std.testing.expect(!testing_hooks.release.load(.acquire));

    // The open returns; the abandoned thread frees its crew or job and ends.
    testing_hooks.release.store(true, .release);
    var waited: usize = 0;
    while (testing_hooks.freed.load(.acquire) < freed_before + freed_after) : (waited += 1) {
        if (waited > 500) return error.AbandonedThreadNeverFinished;
        sleepTick();
    }
}

test "a cancelled walk returns while a worker is stuck in an open, and that worker cleans up after itself" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const Scratch = @import("testing_scratch.zig").Scratch;
    var scratch = try Scratch.init(std.testing.allocator, "walk-stuck");
    defer scratch.deinit();
    try scratch.makeDir("a");
    try scratch.writeFile("a/f", "x");
    try scratch.makeDir("stuck");
    // The probe frees its job; the crew is freed by the abandoned worker.
    try expectCancelReturnsDespiteStuckOpen(scratch.path, "/stuck", 2);
}

test "a cancelled walk returns while the first open of its root is stuck" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const Scratch = @import("testing_scratch.zig").Scratch;
    var scratch = try Scratch.init(std.testing.allocator, "walk-stuck-root");
    defer scratch.deinit();
    try scratch.makeDir("root");
    const root = try scratch.join("root");
    defer std.testing.allocator.free(root);
    try expectCancelReturnsDespiteStuckOpen(root, "/root", 1);
}

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn chmod(path: [*:0]const u8, mode: libc.mode_t) c_int;

test "a guarded folder refused when first asked is recorded and skipped, not asked again" {
    if (comptime !builtin.os.tag.isDarwin()) return error.SkipZigTest;
    const Scratch = @import("testing_scratch.zig").Scratch;
    const allocator = std.testing.allocator;
    var scratch = try Scratch.init(allocator, "walk-denied");
    defer scratch.deinit();
    try scratch.makeDir("Documents");
    try scratch.writeFile("Documents/secret", "x");
    try scratch.makeDir("Music");
    try scratch.writeFile("Music/song", "y");
    const docs = try scratch.joinZ("Documents");
    defer allocator.free(docs);
    // Refused like a folder the user said no to: EACCES on open.
    if (chmod(docs, 0) != 0) return error.SkipZigTest;
    defer _ = chmod(docs, 0o700);

    // The scratch directory plays the home directory.
    const old_home = libc.getenv("HOME");
    const old_home_copy = if (old_home) |h| try allocator.dupeZ(u8, std.mem.span(h)) else null;
    defer if (old_home_copy) |h| allocator.free(h);
    defer if (old_home_copy) |h| {
        _ = setenv("HOME", h, 1);
    };
    _ = setenv("HOME", scratch.path, 1);

    var walker = FastWalker.init(allocator);
    defer walker.deinit();
    walker.setThreads(2);
    walker.enableTreeRecording();
    try walker.walk(scratch.path);
    try walker.finish();

    try std.testing.expectEqual(@as(usize, 1), walker.denied.items.len);
    try std.testing.expect(std.mem.endsWith(u8, walker.denied.items[0], "/Documents"));
    // Music was asked and allowed: its file is found; Documents is unreadable.
    try std.testing.expectEqual(@as(u64, 1), walker.stats.files_found);
    try std.testing.expect(walker.stats.errors >= 1);
}
