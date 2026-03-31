// Copyright (c) 2025 QUANTUM ENCODING LTD
// Licensed under the MIT License.

//! File change watcher using polling with lstat.
//!
//! Walks a directory tree, records mtime for each file,
//! and detects new, modified, and deleted files on each scan.

const std = @import("std");
const builtin = @import("builtin");

// Platform-specific stat structure
const Stat = switch (builtin.os.tag) {
    .linux => switch (builtin.cpu.arch) {
        .aarch64, .aarch64_be => extern struct {
            // aarch64-linux uses asm-generic/stat.h layout
            dev: u64,
            ino: u64,
            mode: u32, // mode comes BEFORE nlink on aarch64
            nlink: u32, // u32, not u64 like x86_64
            uid: u32,
            gid: u32,
            rdev: u64,
            __pad1: u64 = 0,
            size: i64,
            blksize: i32,
            __pad2: i32 = 0,
            blocks: i64,
            atim: std.c.timespec,
            mtim: std.c.timespec,
            ctim: std.c.timespec,
            __unused: [2]u32 = .{ 0, 0 },
        },
        else => extern struct {
            // x86_64-linux uses arch/x86/include/uapi/asm/stat.h layout
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
            atim: std.c.timespec,
            mtim: std.c.timespec,
            ctim: std.c.timespec,
            __unused: [3]i64 = .{ 0, 0, 0 },
        },
    },
    .macos, .ios, .tvos, .watchos => extern struct {
        dev: i32,
        mode: u16,
        nlink: u16,
        ino: u64,
        uid: u32,
        gid: u32,
        rdev: i32,
        atim: std.c.timespec,
        mtim: std.c.timespec,
        ctim: std.c.timespec,
        birthtim: std.c.timespec,
        size: i64,
        blocks: i64,
        blksize: i32,
        flags: u32,
        gen: u32,
        lspare: i32,
        qspare: [2]i64,
    },
    else => std.c.Stat,
};

extern "c" fn lstat(path: [*:0]const u8, buf: *Stat) c_int;

const FileEntry = struct {
    mtime_sec: isize,
    mtime_nsec: isize,
    last_reported_sec: c_long,
};

pub const Watcher = struct {
    allocator: std.mem.Allocator,
    files: std.StringHashMapUnmanaged(FileEntry),
    extensions: ?[]const []const u8,
    ignore_patterns: ?[]const []const u8,
    debounce_ms: u64,
    path_buf: [4096]u8,
    path_len: usize,

    pub fn init(allocator: std.mem.Allocator, extensions: ?[]const []const u8) Watcher {
        return .{
            .allocator = allocator,
            .files = .{},
            .extensions = extensions,
            .ignore_patterns = null,
            .debounce_ms = 0,
            .path_buf = undefined,
            .path_len = 0,
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

    pub fn deinit(self: *Watcher) void {
        var it = self.files.keyIterator();
        while (it.next()) |key| {
            self.allocator.free(key.*);
        }
        self.files.deinit(self.allocator);
    }

    /// Scan the root path and return a list of changed file paths.
    /// On first scan, no changes are reported (establishes baseline).
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

        // Stat the root itself to check if it's a file or directory
        @memcpy(self.path_buf[0..root.len], root);
        self.path_buf[root.len] = 0;
        var root_stat: Stat = undefined;
        if (lstat(@ptrCast(self.path_buf[0..root.len :0]), &root_stat) == 0) {
            // Check if it's a regular file (S_IFREG = 0o100000)
            const is_regular = switch (builtin.os.tag) {
                .linux => (root_stat.mode & 0o170000) == 0o100000,
                .macos, .ios, .tvos, .watchos => (root_stat.mode & 0o170000) == 0o100000,
                else => false,
            };
            if (is_regular) {
                try self.checkFile(root, &root_stat, &changed, &seen);
                // Check for deleted files
                try self.checkDeleted(&seen, &changed);
                return changed.toOwnedSlice(self.allocator);
            }
        }

        // Walk the directory tree
        try self.walkDir(root, &changed, &seen);

        // Check for deleted files (in our map but not seen this scan)
        try self.checkDeleted(&seen, &changed);

        return changed.toOwnedSlice(self.allocator);
    }

    fn shouldIgnore(self: *Watcher, path: []const u8) bool {
        if (self.ignore_patterns) |patterns| {
            for (patterns) |pattern| {
                if (self.matchesPattern(path, pattern)) {
                    return true;
                }
            }
        }
        return false;
    }

    fn matchesPattern(self: *Watcher, path: []const u8, pattern: []const u8) bool {
        // Simple wildcard matching for patterns like ".git", "node_modules", "*.swp"
        if (std.mem.startsWith(u8, pattern, "*")) {
            // Suffix match: "*.swp"
            const suffix = pattern[1..];
            return std.mem.endsWith(u8, path, suffix);
        } else if (std.mem.endsWith(u8, pattern, "*")) {
            // Prefix match: ".git*"
            const prefix = pattern[0 .. pattern.len - 1];
            return std.mem.startsWith(u8, path, prefix);
        } else {
            // Literal component match: ".git", "node_modules"
            // Match full component or at start of path
            if (std.mem.eql(u8, path, pattern)) return true;
            // Check if it's a directory component
            const search_str = std.fmt.allocPrint(self.allocator, "/{s}/", .{pattern}) catch return false;
            defer self.allocator.free(search_str);
            if (std.mem.indexOf(u8, path, search_str) != null) return true;
            // Check at start: "/pattern/"
            const start_str = std.fmt.allocPrint(self.allocator, "{s}/", .{pattern}) catch return false;
            defer self.allocator.free(start_str);
            if (std.mem.startsWith(u8, path, start_str)) return true;
        }
        return false;
    }

    fn checkFile(
        self: *Watcher,
        path: []const u8,
        stat_buf: *const Stat,
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

        const mtime_sec: isize = @intCast(stat_buf.mtim.sec);
        const mtime_nsec: isize = @intCast(stat_buf.mtim.nsec);
        const now_sec: c_long = @intCast(stat_buf.mtim.sec);

        if (self.files.get(path)) |entry| {
            // Mark as seen
            try seen.put(self.allocator, path, {});

            // Check if modified
            if (entry.mtime_sec != mtime_sec or entry.mtime_nsec != mtime_nsec) {
                // Check debounce
                const should_report = if (self.debounce_ms > 0) should_debounce: {
                    const elapsed_ms = (now_sec - entry.last_reported_sec) * 1000;
                    break :should_debounce elapsed_ms >= @as(c_long, @intCast(self.debounce_ms));
                } else true;

                if (should_report) {
                    // Update stored mtime and last_reported time
                    const key = self.findKey(path).?;
                    self.files.putAssumeCapacity(key, .{
                        .mtime_sec = mtime_sec,
                        .mtime_nsec = mtime_nsec,
                        .last_reported_sec = now_sec,
                    });
                    const dupe = try self.allocator.dupe(u8, path);
                    try changed.append(self.allocator, dupe);
                } else {
                    // Still update mtime but not last_reported_sec
                    const key = self.findKey(path).?;
                    self.files.putAssumeCapacity(key, .{
                        .mtime_sec = mtime_sec,
                        .mtime_nsec = mtime_nsec,
                        .last_reported_sec = entry.last_reported_sec,
                    });
                }
            }
        } else {
            // New file
            const owned_path = try self.allocator.dupe(u8, path);
            try self.files.put(self.allocator, owned_path, .{
                .mtime_sec = mtime_sec,
                .mtime_nsec = mtime_nsec,
                .last_reported_sec = now_sec,
            });
            try seen.put(self.allocator, owned_path, {});

            // Only report as changed if this isn't the initial scan
            if (self.files.count() > 1 or self.hasExistingFiles()) {
                const dupe = try self.allocator.dupe(u8, path);
                try changed.append(self.allocator, dupe);
            }
        }
    }

    fn hasExistingFiles(self: *Watcher) bool {
        // If we already have entries beyond the one we just added, we're past initial scan
        return self.files.count() > 0;
    }

    fn findKey(self: *Watcher, path: []const u8) ?[]const u8 {
        if (self.files.getKey(path)) |k| return k;
        return null;
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

                const mode = stat_buf.mode;
                const is_dir = (mode & 0o170000) == 0o040000;
                const is_regular = (mode & 0o170000) == 0o100000;

                if (is_dir) {
                    // Push to stack for later traversal
                    try dir_stack.append(self.allocator, full_path);
                } else if (is_regular) {
                    try self.checkFile(full_path, &stat_buf, changed, seen);
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

// ============================================================
// Tests
// ============================================================

extern "c" fn open(path: [*:0]const u8, flags: c_int, mode: c_uint) c_int;
extern "c" fn close(fd: c_int) c_int;
extern "c" fn write(fd: c_int, buf: [*]const u8, count: usize) isize;
extern "c" fn unlink(path: [*:0]const u8) c_int;
extern "c" fn rmdir(path: [*:0]const u8) c_int;
extern "c" fn mkdir(path: [*:0]const u8, mode: c_uint) c_int;

const O_CREAT = 0o100;
const O_WRONLY = 0o1;
const O_TRUNC = 0o1000;

test "Watcher init and deinit" {
    const allocator = std.testing.allocator;
    var w = Watcher.init(allocator, null);
    defer w.deinit();
}

test "extension matching" {
    try std.testing.expect(std.mem.endsWith(u8, "foo.zig", ".zig"));
    try std.testing.expect(!std.mem.endsWith(u8, "foo.txt", ".zig"));
    try std.testing.expect(std.mem.endsWith(u8, "bar.json", ".json"));
}

test "file creation detection" {
    const allocator = std.testing.allocator;
    var w = Watcher.init(allocator, null);
    defer w.deinit();

    const test_dir = "/tmp/zig_watch_test_creation";
    const test_file_z = "/tmp/zig_watch_test_creation/test.txt\x00";

    // Cleanup any existing test dir
    _ = unlink(@as([*:0]const u8, @ptrCast(test_file_z.ptr)));
    _ = rmdir(@as([*:0]const u8, @ptrCast(test_dir)));
    _ = mkdir(@as([*:0]const u8, @ptrCast(test_dir.ptr)), 0o755);

    // Baseline scan
    try w.baseline(test_dir);
    try std.testing.expectEqual(@as(usize, 0), w.files.count());

    // Create a file
    const fd = open(@as([*:0]const u8, @ptrCast(test_file_z.ptr)), O_CREAT | O_WRONLY | O_TRUNC, 0o644);
    if (fd >= 0) {
        _ = write(fd, "hello", 5);
        _ = close(fd);
    }

    // Scan and verify detection
    const changed = try w.scan(test_dir);
    defer {
        for (changed) |p| allocator.free(p);
        allocator.free(changed);
    }
    try std.testing.expect(changed.len > 0);

    // Cleanup
    _ = unlink(@as([*:0]const u8, @ptrCast(test_file_z.ptr)));
    _ = rmdir(@as([*:0]const u8, @ptrCast(test_dir)));
}

test "file modification detection" {
    const allocator = std.testing.allocator;
    var w = Watcher.init(allocator, null);
    defer w.deinit();

    const test_dir = "/tmp/zig_watch_test_modify";
    const test_file_z = "/tmp/zig_watch_test_modify/test.txt\x00";

    _ = unlink(@as([*:0]const u8, @ptrCast(test_file_z.ptr)));
    _ = rmdir(@as([*:0]const u8, @ptrCast(test_dir)));
    _ = mkdir(@as([*:0]const u8, @ptrCast(test_dir.ptr)), 0o755);

    // Create initial file
    var fd = open(@as([*:0]const u8, @ptrCast(test_file_z.ptr)), O_CREAT | O_WRONLY | O_TRUNC, 0o644);
    if (fd >= 0) {
        _ = write(fd, "v1", 2);
        _ = close(fd);
    }

    // Baseline
    try w.baseline(test_dir);

    // Modify file
    fd = open(@as([*:0]const u8, @ptrCast(test_file_z.ptr)), O_WRONLY | O_TRUNC, 0o644);
    if (fd >= 0) {
        _ = write(fd, "v2modified", 10);
        _ = close(fd);
    }

    // Scan and verify
    const changed = try w.scan(test_dir);
    defer {
        for (changed) |p| allocator.free(p);
        allocator.free(changed);
    }
    try std.testing.expect(changed.len > 0);

    _ = unlink(@as([*:0]const u8, @ptrCast(test_file_z.ptr)));
    _ = rmdir(@as([*:0]const u8, @ptrCast(test_dir)));
}

test "file deletion detection" {
    const allocator = std.testing.allocator;
    var w = Watcher.init(allocator, null);
    defer w.deinit();

    const test_dir = "/tmp/zig_watch_test_delete";
    const test_file_z = "/tmp/zig_watch_test_delete/test.txt\x00";

    _ = unlink(@as([*:0]const u8, @ptrCast(test_file_z.ptr)));
    _ = rmdir(@as([*:0]const u8, @ptrCast(test_dir)));
    _ = mkdir(@as([*:0]const u8, @ptrCast(test_dir.ptr)), 0o755);

    // Create initial file
    const fd = open(@as([*:0]const u8, @ptrCast(test_file_z.ptr)), O_CREAT | O_WRONLY | O_TRUNC, 0o644);
    if (fd >= 0) {
        _ = write(fd, "content", 7);
        _ = close(fd);
    }

    // Baseline
    try w.baseline(test_dir);
    try std.testing.expectEqual(@as(usize, 1), w.files.count());

    // Delete file
    _ = unlink(@as([*:0]const u8, @ptrCast(test_file_z.ptr)));

    // Scan and verify
    const changed = try w.scan(test_dir);
    defer {
        for (changed) |p| allocator.free(p);
        allocator.free(changed);
    }
    try std.testing.expect(changed.len > 0);
    try std.testing.expectEqual(@as(usize, 0), w.files.count());

    _ = rmdir(@as([*:0]const u8, @ptrCast(test_dir)));
}

test "extension filtering" {
    const allocator = std.testing.allocator;
    const exts = try allocator.alloc([]const u8, 1);
    defer allocator.free(exts);
    exts[0] = ".zig";

    var w = Watcher.init(allocator, exts);
    defer w.deinit();

    const test_dir = "/tmp/zig_watch_test_ext";
    const test_zig = "/tmp/zig_watch_test_ext/test.zig\x00";
    const test_txt = "/tmp/zig_watch_test_ext/test.txt\x00";

    _ = unlink(@as([*:0]const u8, @ptrCast(test_zig.ptr)));
    _ = unlink(@as([*:0]const u8, @ptrCast(test_txt.ptr)));
    _ = rmdir(@as([*:0]const u8, @ptrCast(test_dir)));
    _ = mkdir(@as([*:0]const u8, @ptrCast(test_dir.ptr)), 0o755);

    // Create both files
    var fd = open(@as([*:0]const u8, @ptrCast(test_zig.ptr)), O_CREAT | O_WRONLY | O_TRUNC, 0o644);
    if (fd >= 0) {
        _ = write(fd, "code", 4);
        _ = close(fd);
    }
    fd = open(@as([*:0]const u8, @ptrCast(test_txt.ptr)), O_CREAT | O_WRONLY | O_TRUNC, 0o644);
    if (fd >= 0) {
        _ = write(fd, "text", 4);
        _ = close(fd);
    }

    // Baseline
    try w.baseline(test_dir);

    // Only .zig file should be tracked
    try std.testing.expectEqual(@as(usize, 1), w.files.count());

    _ = unlink(@as([*:0]const u8, @ptrCast(test_zig.ptr)));
    _ = unlink(@as([*:0]const u8, @ptrCast(test_txt.ptr)));
    _ = rmdir(@as([*:0]const u8, @ptrCast(test_dir)));
}

test "ignore pattern matching" {
    const allocator = std.testing.allocator;
    const patterns = try allocator.alloc([]const u8, 1);
    defer allocator.free(patterns);
    patterns[0] = ".git";

    var w = Watcher.init(allocator, null);
    w.ignore_patterns = patterns;
    defer w.deinit();

    try std.testing.expect(w.shouldIgnore(".git"));
    try std.testing.expect(w.shouldIgnore("/.git/config"));
    try std.testing.expect(!w.shouldIgnore("test.zig"));
}

test "debounce behavior" {
    const allocator = std.testing.allocator;
    var w = Watcher.init(allocator, null);
    w.debounce_ms = 1000; // 1 second debounce
    defer w.deinit();

    const test_dir = "/tmp/zig_watch_test_debounce";
    const test_file_z = "/tmp/zig_watch_test_debounce/test.txt\x00";

    _ = unlink(@as([*:0]const u8, @ptrCast(test_file_z.ptr)));
    _ = rmdir(@as([*:0]const u8, @ptrCast(test_dir)));
    _ = mkdir(@as([*:0]const u8, @ptrCast(test_dir.ptr)), 0o755);

    // Create file
    const fd = open(@as([*:0]const u8, @ptrCast(test_file_z.ptr)), O_CREAT | O_WRONLY | O_TRUNC, 0o644);
    if (fd >= 0) {
        _ = write(fd, "v1", 2);
        _ = close(fd);
    }

    try w.baseline(test_dir);

    // Note: Full debounce test would require time manipulation
    // This test verifies the debounce field is set
    try std.testing.expectEqual(@as(u64, 1000), w.debounce_ms);

    _ = unlink(@as([*:0]const u8, @ptrCast(test_file_z.ptr)));
    _ = rmdir(@as([*:0]const u8, @ptrCast(test_dir)));
}
