// Copyright (c) 2025 QUANTUM ENCODING LTD
// Licensed under the MIT License.

//! File change watcher using polling with lstat.
//!
//! Walks a directory tree, records mtime for each file,
//! and detects new, modified, and deleted files on each scan.

const std = @import("std");

// Use libc's stat structure and the libc-provided `fstatat`. `std.c.Stat` carries
// the correct per-OS/arch layout, and `std.c.fstatat` resolves to the `$INODE64`
// symbol on x86_64 macOS (the hand-rolled `extern "c" fn lstat` bound plain `_lstat`,
// which is the legacy 32-bit-inode layout on Intel Macs → misaligned mtime reads).
const Stat = std.c.Stat;

/// lstat semantics (do not follow the final symlink) via libc `fstatat` with
/// AT_SYMLINK_NOFOLLOW, keeping the same signature/return convention (0 on success).
fn lstat(path: [*:0]const u8, buf: *Stat) c_int {
    return std.c.fstatat(std.c.AT.FDCWD, path, buf, std.c.AT.SYMLINK_NOFOLLOW);
}

/// Millisecond clock used for debounce accounting.
///
/// Debounce windows are elapsed-time math, so they must never read a wall clock
/// (or, as the pre-fix code did, a file's own mtime): NTP steps and clock drift
/// would stretch or collapse the window. The default implementation is
/// `std.time.Instant` (monotonic); tests inject a deterministic fake.
pub const Clock = struct {
    ctx: ?*anyopaque = null,
    nowMsFn: *const fn (ctx: ?*anyopaque) u64,

    pub fn nowMs(self: Clock) u64 {
        return self.nowMsFn(self.ctx);
    }
};

const FileEntry = struct {
    mtime_sec: isize,
    mtime_nsec: isize,
    /// Monotonic ms at which this path was last reported as changed.
    /// `null` = never reported, so the debounce window is open.
    last_reported_ms: ?u64,
    /// A change was observed but suppressed by the debounce window; it must
    /// still fire on the trailing edge once the window elapses.
    dirty: bool,
};

pub const Watcher = struct {
    allocator: std.mem.Allocator,
    files: std.StringHashMapUnmanaged(FileEntry),
    extensions: ?[]const []const u8,
    ignore_patterns: ?[]const []const u8,
    debounce_ms: u64,
    /// Injected clock; `null` uses the internal monotonic clock below.
    clock: ?Clock,
    mono_base_ms: ?u64,
    /// Set once the first `scan()` completes. New files found during that first
    /// scan establish the baseline and are not reported (see `scan`'s contract).
    initial_scan_done: bool,

    pub fn init(allocator: std.mem.Allocator, extensions: ?[]const []const u8) Watcher {
        return .{
            .allocator = allocator,
            .files = .{},
            .extensions = extensions,
            .ignore_patterns = null,
            .debounce_ms = 0,
            .clock = null,
            .mono_base_ms = null,
            .initial_scan_done = false,
        };
    }

    pub fn withIgnorePatterns(self: *Watcher, patterns: ?[]const []const u8) *Watcher {
        self.ignore_patterns = patterns;
        return self;
    }

    pub fn withDebounce(self: *Watcher, debounce_ms: u64) *Watcher {
        self.debounce_ms = debounce_ms;
        return self;
    }

    pub fn withClock(self: *Watcher, clock: Clock) *Watcher {
        self.clock = clock;
        return self;
    }

    /// Monotonic milliseconds since the first call (or the injected clock's value).
    fn nowMs(self: *Watcher) u64 {
        if (self.clock) |c| return c.nowMs();
        var ts: std.c.timespec = undefined;
        if (std.c.clock_gettime(.MONOTONIC, &ts) != 0) return self.mono_base_ms orelse 0;
        // CLOCK_MONOTONIC is non-negative by definition, but a narrowing cast of a
        // negative value would panic rather than misbehave — fall back instead.
        const sec = std.math.cast(u64, ts.sec) orelse return self.mono_base_ms orelse 0;
        const nsec = std.math.cast(u64, ts.nsec) orelse 0;
        const abs_ms: u64 = sec *| std.time.ms_per_s +| nsec / std.time.ns_per_ms;
        const base = self.mono_base_ms orelse base: {
            self.mono_base_ms = abs_ms;
            break :base abs_ms;
        };
        return abs_ms -| base;
    }

    pub fn deinit(self: *Watcher) void {
        var it = self.files.keyIterator();
        while (it.next()) |key| {
            self.allocator.free(key.*);
        }
        self.files.deinit(self.allocator);
    }

    /// Scan the root path and return a list of changed file paths.
    ///
    /// The first `scan()` on a fresh `Watcher` establishes the baseline: every
    /// pre-existing file is recorded but none is reported. Later scans report
    /// added, modified, and deleted paths. `baseline()` is a convenience wrapper
    /// that runs that first scan and frees its (empty) result.
    ///
    /// Hidden entries (name starting with `.`) are skipped, at every depth.
    /// Symlinks are neither followed nor tracked (lstat semantics).
    ///
    /// Caller must free the returned slice and each string in it.
    pub fn scan(self: *Watcher, root: []const u8) ![][]const u8 {
        var changed: std.ArrayListUnmanaged([]const u8) = .empty;
        errdefer {
            for (changed.items) |p| self.allocator.free(p);
            changed.deinit(self.allocator);
        }

        // Track which files we've seen this scan
        var seen = std.StringHashMapUnmanaged(void){};
        defer seen.deinit(self.allocator);

        const now_ms = self.nowMs();

        // Stat the root itself to check if it's a file or directory. The path is
        // heap-allocated with a sentinel rather than copied into a fixed
        // `[4096]u8`: the old buffer was memcpy'd into with no length check, so a
        // root path >= 4096 bytes was an out-of-bounds write.
        const root_z = try self.allocator.allocSentinel(u8, root.len, 0);
        defer self.allocator.free(root_z);
        @memcpy(root_z, root);

        var root_stat: Stat = undefined;
        if (lstat(root_z.ptr, &root_stat) == 0 and isRegular(root_stat.mode)) {
            try self.checkFile(root, &root_stat, now_ms, &changed, &seen);
            // Check for deleted files
            try self.checkDeleted(&seen, &changed);
            self.initial_scan_done = true;
            return changed.toOwnedSlice(self.allocator);
        }

        // Walk the directory tree
        try self.walkDir(root, now_ms, &changed, &seen);

        // Check for deleted files (in our map but not seen this scan)
        try self.checkDeleted(&seen, &changed);

        self.initial_scan_done = true;
        return changed.toOwnedSlice(self.allocator);
    }

    fn shouldIgnore(self: *Watcher, path: []const u8) bool {
        if (self.ignore_patterns) |patterns| {
            for (patterns) |pattern| {
                if (matchesPattern(path, pattern)) {
                    return true;
                }
            }
        }
        return false;
    }

    fn checkFile(
        self: *Watcher,
        path: []const u8,
        stat_buf: *const Stat,
        now_ms: u64,
        changed: *std.ArrayListUnmanaged([]const u8),
        seen: *std.StringHashMapUnmanaged(void),
    ) !void {
        // Check ignore patterns
        if (self.shouldIgnore(path)) return;

        // Check extension filter
        if (self.extensions) |exts| {
            var matches = false;
            for (exts) |ext| {
                if (std.mem.endsWith(u8, path, ext)) {
                    matches = true;
                    break;
                }
            }
            if (!matches) return;
        }

        const mtime = stat_buf.mtime();
        const mtime_sec: isize = @intCast(mtime.sec);
        const mtime_nsec: isize = @intCast(mtime.nsec);

        if (self.files.getEntry(path)) |kv| {
            // Mark as seen using the map-owned key, NOT the caller's transient
            // `path` slice: walkDir frees `full_path` immediately after checkFile
            // returns, so storing `path` here would leave `seen` holding dangling
            // keys that checkDeleted later hashes/eqls against (use-after-free).
            try seen.put(self.allocator, kv.key_ptr.*, {});

            const entry = kv.value_ptr;
            if (entry.mtime_sec != mtime_sec or entry.mtime_nsec != mtime_nsec) {
                entry.mtime_sec = mtime_sec;
                entry.mtime_nsec = mtime_nsec;
                entry.dirty = true;
            }

            // Debounce is defer-and-coalesce, not drop: a change seen inside the
            // window leaves the entry dirty, and this branch re-fires it on a
            // later scan once the window has elapsed — even if the mtime has not
            // moved again. (The pre-fix code updated the stored mtime without
            // reporting, losing the change permanently.)
            if (entry.dirty and self.debounceElapsed(entry.last_reported_ms, now_ms)) {
                entry.dirty = false;
                entry.last_reported_ms = now_ms;
                const dupe = try self.allocator.dupe(u8, path);
                try changed.append(self.allocator, dupe);
            }
        } else {
            // New file
            const owned_path = try self.allocator.dupe(u8, path);
            {
                // Scoped so the errdefer covers only the insert: once the map
                // owns the key, freeing it here would double-free at deinit.
                errdefer self.allocator.free(owned_path);
                try self.files.put(self.allocator, owned_path, .{
                    .mtime_sec = mtime_sec,
                    .mtime_nsec = mtime_nsec,
                    .last_reported_ms = if (self.initial_scan_done) now_ms else null,
                    .dirty = false,
                });
            }
            try seen.put(self.allocator, owned_path, {});

            // Files discovered by the very first scan establish the baseline and
            // are not reported (see `scan`'s doc contract).
            if (self.initial_scan_done) {
                const dupe = try self.allocator.dupe(u8, path);
                try changed.append(self.allocator, dupe);
            }
        }
    }

    /// True when a report is allowed right now: debounce off, never reported
    /// before, or the window since the last report has fully elapsed.
    fn debounceElapsed(self: *Watcher, last_reported_ms: ?u64, now_ms: u64) bool {
        if (self.debounce_ms == 0) return true;
        const last = last_reported_ms orelse return true;
        return now_ms -| last >= self.debounce_ms;
    }

    fn checkDeleted(
        self: *Watcher,
        seen: *std.StringHashMapUnmanaged(void),
        changed: *std.ArrayListUnmanaged([]const u8),
    ) !void {
        // Collect paths to remove (can't modify while iterating)
        var to_remove: std.ArrayListUnmanaged([]const u8) = .empty;
        defer to_remove.deinit(self.allocator);

        var it = self.files.keyIterator();
        while (it.next()) |key| {
            if (!seen.contains(key.*)) {
                try to_remove.append(self.allocator, key.*);
            }
        }

        for (to_remove.items) |path| {
            _ = self.files.remove(path);
            const dupe = try self.allocator.dupe(u8, path);
            try changed.append(self.allocator, dupe);
            self.allocator.free(path);
        }
    }

    fn walkDir(
        self: *Watcher,
        root: []const u8,
        now_ms: u64,
        changed: *std.ArrayListUnmanaged([]const u8),
        seen: *std.StringHashMapUnmanaged(void),
    ) !void {
        // Use a stack for iterative directory traversal
        var dir_stack: std.ArrayListUnmanaged([]const u8) = .empty;
        defer {
            for (dir_stack.items) |d| self.allocator.free(d);
            dir_stack.deinit(self.allocator);
        }

        const root_dupe = try self.allocator.dupe(u8, root);
        try dir_stack.append(self.allocator, root_dupe);

        while (dir_stack.items.len > 0) {
            const dir_path = dir_stack.pop() orelse break;
            defer self.allocator.free(dir_path);

            // Open directory
            const dir_z = try self.allocator.allocSentinel(u8, dir_path.len, 0);
            defer self.allocator.free(dir_z);
            @memcpy(dir_z, dir_path);

            const dir = std.c.opendir(dir_z.ptr) orelse continue;
            defer _ = std.c.closedir(dir);

            while (std.c.readdir(dir)) |entry| {
                const name_ptr = @as([*:0]const u8, @ptrCast(&entry.name));
                const name_len = std.mem.len(name_ptr);
                const name = name_ptr[0..name_len];

                // Skip . and ..
                if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;

                // Skip hidden files/dirs
                if (name[0] == '.') continue;

                // Build full path
                const full_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ dir_path, name });

                // Stat the file
                const path_z = try self.allocator.allocSentinel(u8, full_path.len, 0);
                defer self.allocator.free(path_z);
                @memcpy(path_z, full_path);

                var stat_buf: Stat = undefined;
                if (lstat(path_z.ptr, &stat_buf) != 0) {
                    self.allocator.free(full_path);
                    continue;
                }

                if (isDir(stat_buf.mode)) {
                    // Push to stack for later traversal
                    try dir_stack.append(self.allocator, full_path);
                } else if (isRegular(stat_buf.mode)) {
                    try self.checkFile(full_path, &stat_buf, now_ms, changed, seen);
                    self.allocator.free(full_path);
                } else {
                    self.allocator.free(full_path);
                }
            }
        }
    }

    /// Perform initial scan to establish baseline (no changes reported).
    pub fn baseline(self: *Watcher, root: []const u8) !void {
        const changed = try self.scan(root);
        for (changed) |p| self.allocator.free(p);
        self.allocator.free(changed);
    }
};

const S_IFMT: std.c.mode_t = 0o170000;

fn isRegular(mode: std.c.mode_t) bool {
    return (mode & S_IFMT) == 0o100000;
}

fn isDir(mode: std.c.mode_t) bool {
    return (mode & S_IFMT) == 0o040000;
}

/// Match one ignore pattern against a path. Allocation-free by construction:
/// the previous implementation built `/{pattern}/` probe strings with
/// `allocPrint ... catch return false`, which allocated per file x pattern x
/// scan and failed *open* under OOM (an ignore pattern silently stopped
/// ignoring). Supported forms: `*suffix`, `prefix*`, and a literal path
/// component.
fn matchesPattern(path: []const u8, pattern: []const u8) bool {
    if (pattern.len == 0) return false;

    if (pattern[0] == '*') {
        // Suffix match: "*.swp"
        return std.mem.endsWith(u8, path, pattern[1..]);
    }
    if (pattern[pattern.len - 1] == '*') {
        // Prefix match: ".git*"
        return std.mem.startsWith(u8, path, pattern[0 .. pattern.len - 1]);
    }

    // Literal path-component match: ".git", "node_modules" — the pattern must
    // occupy a whole `/`-delimited component, so "node_modules" does not match
    // "my_node_modules_backup/x".
    if (pattern.len > path.len) return false;
    var i: usize = 0;
    while (i + pattern.len <= path.len) : (i += 1) {
        if (!std.mem.eql(u8, path[i .. i + pattern.len], pattern)) continue;
        const at_start = i == 0 or path[i - 1] == '/';
        const end = i + pattern.len;
        const at_end = end == path.len or path[end] == '/';
        if (at_start and at_end) return true;
    }
    return false;
}
// ============================================================
// Tests
// ============================================================
//
// Every filesystem test runs in its own scratch directory under `TMPDIR`
// (per-user and per-process; falls back to `/tmp`), so parallel `zig build test`
// runs cannot collide on a shared fixed path and nothing is ever written into
// the repository tree. Fixture failures hard-fail via `try` rather than being
// silently tolerated, so a permissions problem surfaces at its cause instead of
// as a confusing downstream assertion.

/// Scratch directory fixture: unique per test name and per process.
///
/// Fixture I/O goes through libc directly (`std.fs` in this Zig release is the
/// `std.Io.Dir` API, which would drag an Io instance into every test) using the
/// same primitives the watcher itself uses. Flags come from the portable
/// `std.c.O` packed struct rather than hard-coded Linux octal constants — the
/// old tests used `O_CREAT = 0o100`, which is not `O_CREAT` on macOS.
const TestDir = struct {
    allocator: std.mem.Allocator,
    path: []const u8,

    fn create(allocator: std.mem.Allocator, name: []const u8) !TestDir {
        const base: []const u8 = if (std.c.getenv("TMPDIR")) |p| std.mem.span(p) else "/tmp";
        var trimmed: []const u8 = base;
        while (trimmed.len > 1 and trimmed[trimmed.len - 1] == '/') trimmed = trimmed[0 .. trimmed.len - 1];
        const path = try std.fmt.allocPrint(
            allocator,
            "{s}/zig_watch_test_{s}_{d}",
            .{ trimmed, name, std.c.getpid() },
        );
        errdefer allocator.free(path);
        var self = TestDir{ .allocator = allocator, .path = path };
        try self.rmTree(path);
        try self.mkdirAbs(path);
        return self;
    }

    fn deinit(self: *TestDir) void {
        self.rmTree(self.path) catch {};
        self.allocator.free(self.path);
    }

    /// Absolute path of an entry inside the scratch dir; caller frees.
    fn join(self: *TestDir, sub: []const u8) ![]u8 {
        return std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ self.path, sub });
    }

    /// NUL-terminated copy of an absolute path; caller frees.
    fn dupeZ(self: *TestDir, p: []const u8) ![:0]u8 {
        const z = try self.allocator.allocSentinel(u8, p.len, 0);
        @memcpy(z, p);
        return z;
    }

    fn mkdirAbs(self: *TestDir, p: []const u8) !void {
        const z = try self.dupeZ(p);
        defer self.allocator.free(z);
        try std.testing.expectEqual(@as(c_int, 0), std.c.mkdir(z.ptr, 0o755));
    }

    fn writeFile(self: *TestDir, sub: []const u8, contents: []const u8) !void {
        const p = try self.join(sub);
        defer self.allocator.free(p);
        const z = try self.dupeZ(p);
        defer self.allocator.free(z);
        const fd = std.c.open(z.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o644));
        try std.testing.expect(fd >= 0);
        defer _ = std.c.close(fd);
        const n = std.c.write(fd, contents.ptr, contents.len);
        try std.testing.expectEqual(@as(isize, @intCast(contents.len)), n);
    }

    /// Create `sub`, including any missing parent components.
    fn makeDir(self: *TestDir, sub: []const u8) !void {
        var end: usize = 0;
        while (end <= sub.len) : (end += 1) {
            if (end != sub.len and sub[end] != '/') continue;
            if (end == 0) continue;
            const p = try self.join(sub[0..end]);
            defer self.allocator.free(p);
            const z = try self.dupeZ(p);
            defer self.allocator.free(z);
            // EEXIST is fine; anything else surfaces on the next operation.
            _ = std.c.mkdir(z.ptr, 0o755);
        }
    }

    fn remove(self: *TestDir, sub: []const u8) !void {
        const p = try self.join(sub);
        defer self.allocator.free(p);
        try self.rmTree(p);
    }

    /// Recursively delete `p` (file, symlink, or directory). Missing is not an error.
    fn rmTree(self: *TestDir, p: []const u8) !void {
        const z = try self.dupeZ(p);
        defer self.allocator.free(z);

        var st: Stat = undefined;
        if (lstat(z.ptr, &st) != 0) return; // already gone
        if (!isDir(st.mode)) {
            _ = std.c.unlink(z.ptr);
            return;
        }

        const dir = std.c.opendir(z.ptr) orelse return;
        var children: std.ArrayListUnmanaged([]const u8) = .empty;
        defer {
            for (children.items) |c| self.allocator.free(c);
            children.deinit(self.allocator);
        }
        while (std.c.readdir(dir)) |ent| {
            const name_ptr: [*:0]const u8 = @ptrCast(&ent.name);
            const name = name_ptr[0..std.mem.len(name_ptr)];
            if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
            try children.append(
                self.allocator,
                try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ p, name }),
            );
        }
        _ = std.c.closedir(dir);

        for (children.items) |child| try self.rmTree(child);
        _ = std.c.rmdir(z.ptr);
    }

    fn symlink(self: *TestDir, target: []const u8, sub: []const u8) !void {
        const p = try self.join(sub);
        defer self.allocator.free(p);
        const target_z = try self.dupeZ(target);
        defer self.allocator.free(target_z);
        const link_z = try self.dupeZ(p);
        defer self.allocator.free(link_z);
        try std.testing.expectEqual(@as(c_int, 0), std.c.symlink(target_z.ptr, link_z.ptr));
    }

    fn rename(self: *TestDir, from_sub: []const u8, to_sub: []const u8) !void {
        const from = try self.join(from_sub);
        defer self.allocator.free(from);
        const to = try self.join(to_sub);
        defer self.allocator.free(to);
        const from_z = try self.dupeZ(from);
        defer self.allocator.free(from_z);
        const to_z = try self.dupeZ(to);
        defer self.allocator.free(to_z);
        try std.testing.expectEqual(@as(c_int, 0), std.c.rename(from_z.ptr, to_z.ptr));
    }

    /// Set an exact mtime. Filesystem timestamp granularity and the speed of the
    /// test loop make "write twice and hope the mtimes differ" flaky; stamping
    /// the mtime explicitly makes change detection deterministic.
    fn setMtime(self: *TestDir, sub: []const u8, sec: isize, nsec: isize) !void {
        const p = try self.join(sub);
        defer self.allocator.free(p);
        const p_z = try self.dupeZ(p);
        defer self.allocator.free(p_z);
        const times = [2]std.c.timespec{
            .{ .sec = @intCast(sec), .nsec = @intCast(nsec) },
            .{ .sec = @intCast(sec), .nsec = @intCast(nsec) },
        };
        try std.testing.expectEqual(
            @as(c_int, 0),
            std.c.utimensat(std.c.AT.FDCWD, p_z.ptr, &times, 0),
        );
    }
};

/// Deterministic clock for debounce tests: the test moves time by hand.
const FakeClock = struct {
    now_ms: u64 = 0,

    fn read(ctx: ?*anyopaque) u64 {
        const self: *FakeClock = @ptrCast(@alignCast(ctx.?));
        return self.now_ms;
    }

    fn clock(self: *FakeClock) Clock {
        return .{ .ctx = self, .nowMsFn = FakeClock.read };
    }
};

/// Run one scan and return the changed paths sorted, so assertions are order-independent.
fn scanSorted(w: *Watcher, root: []const u8) ![][]const u8 {
    const changed = try w.scan(root);
    std.mem.sort([]const u8, changed, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lt);
    return changed;
}

fn freeChanged(allocator: std.mem.Allocator, changed: [][]const u8) void {
    for (changed) |p| allocator.free(p);
    allocator.free(changed);
}

/// Assert the scan reported exactly `expected` (basenames relative to `dir`).
fn expectChanged(dir: *TestDir, changed: []const []const u8, expected: []const []const u8) !void {
    try std.testing.expectEqual(expected.len, changed.len);
    for (expected, changed) |want_sub, got| {
        const want = try dir.join(want_sub);
        defer dir.allocator.free(want);
        try std.testing.expectEqualStrings(want, got);
    }
}

test "Watcher init and deinit" {
    const allocator = std.testing.allocator;
    var w = Watcher.init(allocator, null);
    defer w.deinit();
}

test "matchesPattern: suffix, prefix, and whole-component matching" {
    // Suffix form.
    try std.testing.expect(matchesPattern("src/a.swp", "*.swp"));
    try std.testing.expect(!matchesPattern("src/a.zig", "*.swp"));
    // Prefix form.
    try std.testing.expect(matchesPattern("build-out/x", "build-*"));
    try std.testing.expect(!matchesPattern("src/build-out", "build-*"));
    // Literal component form.
    try std.testing.expect(matchesPattern(".git", ".git"));
    try std.testing.expect(matchesPattern("/repo/.git/config", ".git"));
    try std.testing.expect(matchesPattern("node_modules/x/y", "node_modules"));
    try std.testing.expect(matchesPattern("a/b/node_modules", "node_modules"));
    // A component match must not fire on a substring of a longer component.
    try std.testing.expect(!matchesPattern("my_node_modules_backup/x", "node_modules"));
    try std.testing.expect(!matchesPattern("src/gitignore", ".git"));
    // Degenerate input.
    try std.testing.expect(!matchesPattern("anything", ""));
    try std.testing.expect(!matchesPattern("ab", "abc"));
}

test "first scan establishes the baseline and reports nothing" {
    // The documented contract: pre-existing files are recorded, not reported.
    // (The old guard `count() > 1 or hasExistingFiles()` ran after the insert and
    // was therefore always true — every pre-existing file was reported on scan #1.)
    const allocator = std.testing.allocator;
    var dir = try TestDir.create(allocator, "baseline");
    defer dir.deinit();
    try dir.writeFile("a.txt", "1");
    try dir.writeFile("b.txt", "2");

    var w = Watcher.init(allocator, null);
    defer w.deinit();

    const first = try scanSorted(&w, dir.path);
    defer freeChanged(allocator, first);
    try std.testing.expectEqual(@as(usize, 0), first.len);
    try std.testing.expectEqual(@as(usize, 2), w.files.count());
    try std.testing.expect(w.initial_scan_done);
}

test "file creation detection" {
    const allocator = std.testing.allocator;
    var dir = try TestDir.create(allocator, "creation");
    defer dir.deinit();

    var w = Watcher.init(allocator, null);
    defer w.deinit();

    try w.baseline(dir.path);
    try std.testing.expectEqual(@as(usize, 0), w.files.count());

    try dir.writeFile("test.txt", "hello");

    const changed = try scanSorted(&w, dir.path);
    defer freeChanged(allocator, changed);
    try expectChanged(&dir, changed, &.{"test.txt"});
}

test "file modification detection" {
    const allocator = std.testing.allocator;
    var dir = try TestDir.create(allocator, "modify");
    defer dir.deinit();
    try dir.writeFile("test.txt", "v1");
    try dir.setMtime("test.txt", 1_600_000_000, 0);

    var w = Watcher.init(allocator, null);
    defer w.deinit();
    try w.baseline(dir.path);

    // Unchanged: no report.
    {
        const stable = try scanSorted(&w, dir.path);
        defer freeChanged(allocator, stable);
        try std.testing.expectEqual(@as(usize, 0), stable.len);
    }

    try dir.writeFile("test.txt", "v2modified");
    try dir.setMtime("test.txt", 1_600_000_001, 0);

    const changed = try scanSorted(&w, dir.path);
    defer freeChanged(allocator, changed);
    try expectChanged(&dir, changed, &.{"test.txt"});
}

test "rapid rewrite within the same second is detected (sub-second mtime)" {
    // Two writes inside one wall-clock second differ only in mtime nanoseconds;
    // a seconds-only comparison would miss the second write entirely.
    const allocator = std.testing.allocator;
    var dir = try TestDir.create(allocator, "rapid");
    defer dir.deinit();
    try dir.writeFile("f.txt", "a");
    try dir.setMtime("f.txt", 1_600_000_000, 1_000_000);

    var w = Watcher.init(allocator, null);
    defer w.deinit();
    try w.baseline(dir.path);

    try dir.writeFile("f.txt", "b");
    try dir.setMtime("f.txt", 1_600_000_000, 2_000_000);

    const changed = try scanSorted(&w, dir.path);
    defer freeChanged(allocator, changed);
    try expectChanged(&dir, changed, &.{"f.txt"});
}

test "file deletion detection" {
    const allocator = std.testing.allocator;
    var dir = try TestDir.create(allocator, "delete");
    defer dir.deinit();
    try dir.writeFile("test.txt", "content");

    var w = Watcher.init(allocator, null);
    defer w.deinit();
    try w.baseline(dir.path);
    try std.testing.expectEqual(@as(usize, 1), w.files.count());

    try dir.remove("test.txt");

    const changed = try scanSorted(&w, dir.path);
    defer freeChanged(allocator, changed);
    try expectChanged(&dir, changed, &.{"test.txt"});
    try std.testing.expectEqual(@as(usize, 0), w.files.count());

    // The path is gone from the map, so it must not be reported again.
    const again = try scanSorted(&w, dir.path);
    defer freeChanged(allocator, again);
    try std.testing.expectEqual(@as(usize, 0), again.len);
}

test "rename reports both the old and the new path" {
    const allocator = std.testing.allocator;
    var dir = try TestDir.create(allocator, "rename");
    defer dir.deinit();
    try dir.writeFile("old.txt", "x");

    var w = Watcher.init(allocator, null);
    defer w.deinit();
    try w.baseline(dir.path);

    try dir.rename("old.txt", "new.txt");

    const changed = try scanSorted(&w, dir.path);
    defer freeChanged(allocator, changed);
    // Sorted: new.txt (added) before old.txt (deleted).
    try expectChanged(&dir, changed, &.{ "new.txt", "old.txt" });
    try std.testing.expectEqual(@as(usize, 1), w.files.count());
}

test "stable rescan reports no changes (seen-set key ownership)" {
    // Regression for the seen-set use-after-free: over an unchanged multi-file
    // directory, every scan after the baseline must return zero changes. With the
    // pre-fix code the `seen` set held dangling `full_path` keys (freed by walkDir),
    // so checkDeleted could miss live files and spuriously report deletions.
    const allocator = std.testing.allocator;
    var dir = try TestDir.create(allocator, "stable");
    defer dir.deinit();
    try dir.writeFile("a.txt", "x");
    try dir.writeFile("b.txt", "x");
    try dir.writeFile("c.txt", "x");
    try dir.makeDir("nested/deeper");
    try dir.writeFile("nested/d.txt", "x");
    try dir.writeFile("nested/deeper/e.txt", "x");

    var w = Watcher.init(allocator, null);
    defer w.deinit();
    try w.baseline(dir.path);
    try std.testing.expectEqual(@as(usize, 5), w.files.count());

    var round: usize = 0;
    while (round < 3) : (round += 1) {
        const changed = try scanSorted(&w, dir.path);
        defer freeChanged(allocator, changed);
        try std.testing.expectEqual(@as(usize, 0), changed.len);
        try std.testing.expectEqual(@as(usize, 5), w.files.count());
    }
}

test "a file replaced by a directory is reported deleted and stops being tracked" {
    const allocator = std.testing.allocator;
    var dir = try TestDir.create(allocator, "file_to_dir");
    defer dir.deinit();
    try dir.writeFile("thing", "file now");

    var w = Watcher.init(allocator, null);
    defer w.deinit();
    try w.baseline(dir.path);
    try std.testing.expectEqual(@as(usize, 1), w.files.count());

    try dir.remove("thing");
    try dir.makeDir("thing");
    try dir.writeFile("thing/inner.txt", "x");

    const changed = try scanSorted(&w, dir.path);
    defer freeChanged(allocator, changed);
    // "thing" is gone as a file; "thing/inner.txt" is new. Sorted: thing, thing/inner.txt.
    try expectChanged(&dir, changed, &.{ "thing", "thing/inner.txt" });
    try std.testing.expectEqual(@as(usize, 1), w.files.count());
}

test "symlinks are neither followed nor tracked" {
    const allocator = std.testing.allocator;
    var dir = try TestDir.create(allocator, "symlink");
    defer dir.deinit();
    try dir.writeFile("real.txt", "x");
    try dir.symlink("real.txt", "link.txt");
    // A self-referential directory link would hang a follow-symlinks walker.
    try dir.symlink(dir.path, "loop");

    var w = Watcher.init(allocator, null);
    defer w.deinit();
    try w.baseline(dir.path);

    // Only the regular file is tracked: lstat reports the links as symlinks,
    // which are neither regular files nor directories.
    try std.testing.expectEqual(@as(usize, 1), w.files.count());
    const key = try dir.join("real.txt");
    defer allocator.free(key);
    try std.testing.expect(w.files.contains(key));

    const changed = try scanSorted(&w, dir.path);
    defer freeChanged(allocator, changed);
    try std.testing.expectEqual(@as(usize, 0), changed.len);
}

test "a watched root that disappears reports its files deleted, then stays quiet" {
    const allocator = std.testing.allocator;
    var dir = try TestDir.create(allocator, "vanish");
    defer dir.deinit();
    try dir.writeFile("a.txt", "x");

    var w = Watcher.init(allocator, null);
    defer w.deinit();
    try w.baseline(dir.path);

    // The whole watched tree goes away mid-run: scan must not error.
    try dir.rmTree(dir.path);

    const changed = try scanSorted(&w, dir.path);
    defer freeChanged(allocator, changed);
    try expectChanged(&dir, changed, &.{"a.txt"});

    const again = try scanSorted(&w, dir.path);
    defer freeChanged(allocator, again);
    try std.testing.expectEqual(@as(usize, 0), again.len);
}

test "a root path longer than the old 4096-byte buffer is handled, not overflowed" {
    // scan() used to @memcpy the root into a fixed [4096]u8 with no length check.
    const allocator = std.testing.allocator;
    var w = Watcher.init(allocator, null);
    defer w.deinit();

    const long_root = try allocator.alloc(u8, 5000);
    defer allocator.free(long_root);
    @memset(long_root, 'a');
    long_root[0] = '/';

    const changed = try w.scan(long_root);
    defer freeChanged(allocator, changed);
    try std.testing.expectEqual(@as(usize, 0), changed.len);
}

test "watching a single regular file (not a directory)" {
    const allocator = std.testing.allocator;
    var dir = try TestDir.create(allocator, "single_file");
    defer dir.deinit();
    try dir.writeFile("only.txt", "v1");
    try dir.setMtime("only.txt", 1_600_000_000, 0);

    const target = try dir.join("only.txt");
    defer allocator.free(target);

    var w = Watcher.init(allocator, null);
    defer w.deinit();
    try w.baseline(target);
    try std.testing.expectEqual(@as(usize, 1), w.files.count());

    try dir.writeFile("only.txt", "v2");
    try dir.setMtime("only.txt", 1_600_000_002, 0);

    const changed = try scanSorted(&w, target);
    defer freeChanged(allocator, changed);
    try std.testing.expectEqual(@as(usize, 1), changed.len);
    try std.testing.expectEqualStrings(target, changed[0]);
}

test "extension filtering" {
    const allocator = std.testing.allocator;
    var dir = try TestDir.create(allocator, "ext");
    defer dir.deinit();
    try dir.writeFile("test.zig", "code");
    try dir.writeFile("test.txt", "text");

    const exts = try allocator.alloc([]const u8, 1);
    defer allocator.free(exts);
    exts[0] = ".zig";

    var w = Watcher.init(allocator, exts);
    defer w.deinit();
    try w.baseline(dir.path);

    // Only the .zig file is tracked.
    try std.testing.expectEqual(@as(usize, 1), w.files.count());

    // Touching the filtered-out file produces no report.
    try dir.writeFile("test.txt", "text changed a lot");
    const quiet = try scanSorted(&w, dir.path);
    defer freeChanged(allocator, quiet);
    try std.testing.expectEqual(@as(usize, 0), quiet.len);
}

test "ignored directories are not tracked" {
    const allocator = std.testing.allocator;
    var dir = try TestDir.create(allocator, "ignore");
    defer dir.deinit();
    try dir.makeDir("node_modules");
    try dir.writeFile("node_modules/dep.js", "x");
    try dir.writeFile("keep.js", "x");

    const patterns = try allocator.alloc([]const u8, 1);
    defer allocator.free(patterns);
    patterns[0] = "node_modules";

    var w = Watcher.init(allocator, null);
    _ = w.withIgnorePatterns(patterns);
    defer w.deinit();

    try std.testing.expect(w.shouldIgnore("node_modules"));
    try std.testing.expect(w.shouldIgnore("/x/node_modules/dep.js"));
    try std.testing.expect(!w.shouldIgnore("keep.js"));

    try w.baseline(dir.path);
    try std.testing.expectEqual(@as(usize, 1), w.files.count());
    const kept = try dir.join("keep.js");
    defer allocator.free(kept);
    try std.testing.expect(w.files.contains(kept));
}

test "hidden entries are skipped at every depth" {
    const allocator = std.testing.allocator;
    var dir = try TestDir.create(allocator, "hidden");
    defer dir.deinit();
    try dir.writeFile(".hidden.txt", "x");
    try dir.makeDir(".git");
    try dir.writeFile(".git/config", "x");
    try dir.makeDir("visible");
    try dir.writeFile("visible/.dotfile", "x");
    try dir.writeFile("visible/shown.txt", "x");

    var w = Watcher.init(allocator, null);
    defer w.deinit();
    try w.baseline(dir.path);

    try std.testing.expectEqual(@as(usize, 1), w.files.count());
    const shown = try dir.join("visible/shown.txt");
    defer allocator.free(shown);
    try std.testing.expect(w.files.contains(shown));
}

test "debounce coalesces a burst and fires once on the trailing edge" {
    // The pre-fix debounce compared file *mtimes* as if they were a clock and,
    // when it suppressed a report, still advanced the stored mtime — so the
    // change was dropped forever and never re-fired. This asserts the real
    // contract: leading-edge report, burst coalesced, one trailing-edge fire.
    const allocator = std.testing.allocator;
    var dir = try TestDir.create(allocator, "debounce");
    defer dir.deinit();
    try dir.writeFile("f.txt", "v0");
    try dir.setMtime("f.txt", 1_600_000_000, 0);

    var fake = FakeClock{ .now_ms = 0 };
    var w = Watcher.init(allocator, null);
    _ = w.withDebounce(1000);
    _ = w.withClock(fake.clock());
    defer w.deinit();

    try w.baseline(dir.path);

    // t=10: first change — never reported before, so it fires immediately.
    fake.now_ms = 10;
    try dir.setMtime("f.txt", 1_600_000_001, 0);
    {
        const c = try scanSorted(&w, dir.path);
        defer freeChanged(allocator, c);
        try expectChanged(&dir, c, &.{"f.txt"});
    }

    // t=200 and t=400: two more writes inside the 1000ms window — coalesced.
    fake.now_ms = 200;
    try dir.setMtime("f.txt", 1_600_000_002, 0);
    {
        const c = try scanSorted(&w, dir.path);
        defer freeChanged(allocator, c);
        try std.testing.expectEqual(@as(usize, 0), c.len);
    }
    fake.now_ms = 400;
    try dir.setMtime("f.txt", 1_600_000_003, 0);
    {
        const c = try scanSorted(&w, dir.path);
        defer freeChanged(allocator, c);
        try std.testing.expectEqual(@as(usize, 0), c.len);
    }

    // t=1010: window elapsed. The suppressed burst fires exactly once, even
    // though the mtime has not moved since t=400.
    fake.now_ms = 1010;
    {
        const c = try scanSorted(&w, dir.path);
        defer freeChanged(allocator, c);
        try expectChanged(&dir, c, &.{"f.txt"});
    }

    // t=2100: nothing further happened, so nothing further is reported.
    fake.now_ms = 2100;
    {
        const c = try scanSorted(&w, dir.path);
        defer freeChanged(allocator, c);
        try std.testing.expectEqual(@as(usize, 0), c.len);
    }
}

test "debounce off reports every change" {
    const allocator = std.testing.allocator;
    var dir = try TestDir.create(allocator, "no_debounce");
    defer dir.deinit();
    try dir.writeFile("f.txt", "v0");
    try dir.setMtime("f.txt", 1_600_000_000, 0);

    var fake = FakeClock{ .now_ms = 0 };
    var w = Watcher.init(allocator, null);
    _ = w.withClock(fake.clock());
    defer w.deinit();
    try w.baseline(dir.path);

    var i: isize = 1;
    while (i <= 3) : (i += 1) {
        fake.now_ms += 1; // far inside any window; debounce is off
        try dir.setMtime("f.txt", 1_600_000_000 + i, 0);
        const c = try scanSorted(&w, dir.path);
        defer freeChanged(allocator, c);
        try expectChanged(&dir, c, &.{"f.txt"});
    }
}
