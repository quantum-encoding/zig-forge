//! Directory walker for file enumeration
//!
//! Features:
//! - Recursive directory traversal
//! - Inode tracking (hard link detection)
//! - Hidden file filtering
//! - Size filtering
//! - Cross-platform (Linux, macOS)

const std = @import("std");
const builtin = @import("builtin");
const types = @import("types.zig");
const libc = std.c;

const is_linux = builtin.os.tag == .linux;
const is_darwin = builtin.os.tag == .macos or builtin.os.tag == .ios;

// Stat comes from pstat.zig: std.c ($INODE64-correct) on Darwin, statx on Linux.
const pstat = @import("pstat.zig");
const Stat = pstat.Stat;

/// Unique file identifier (device + inode)
pub const FileId = struct {
    dev: u64,
    ino: u64,

    pub fn fromStat(s: *const Stat) FileId {
        return .{
            .dev = s.dev,
            .ino = s.ino,
        };
    }
};

/// Directory walker result
pub const WalkResult = struct {
    /// All files found
    files: std.ArrayListUnmanaged(types.FileEntry),
    /// Total size of all files
    total_size: u64,
    /// Number of directories traversed
    dirs_traversed: u64,
    /// Errors encountered (non-fatal)
    errors: std.ArrayListUnmanaged(WalkError),

    pub fn init() WalkResult {
        return .{
            .files = .empty,
            .total_size = 0,
            .dirs_traversed = 0,
            .errors = .empty,
        };
    }

    pub fn deinit(self: *WalkResult, allocator: std.mem.Allocator) void {
        for (self.files.items) |*entry| {
            entry.deinit(allocator);
        }
        self.files.deinit(allocator);

        for (self.errors.items) |*err| {
            allocator.free(err.path);
        }
        self.errors.deinit(allocator);
    }
};

/// Hard bound on recursion depth. `walkRecursive` is recursive per directory
/// level; without a bound a deep (or adversarial) tree exhausts the stack.
const max_depth: u32 = 256;

/// Non-fatal error during walk
pub const WalkError = struct {
    path: []const u8,
    err: anyerror,
};

/// Directory walker
pub const Walker = struct {
    allocator: std.mem.Allocator,
    config: types.Config,
    /// Track seen inodes to detect hard links
    seen_inodes: std.AutoHashMap(FileId, void),
    /// Track directories already descended into. Without this, a symlink cycle
    /// (`ln -s .. loop`) recurses until the stack is exhausted.
    seen_dirs: std.AutoHashMap(FileId, void),
    /// Progress callback
    progress_callback: ?types.ProgressCallback,
    /// Current progress state
    progress: types.Progress,

    pub fn init(allocator: std.mem.Allocator, config: types.Config) Walker {
        return .{
            .allocator = allocator,
            .config = config,
            .seen_inodes = std.AutoHashMap(FileId, void).init(allocator),
            .seen_dirs = std.AutoHashMap(FileId, void).init(allocator),
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

    pub fn deinit(self: *Walker) void {
        self.seen_inodes.deinit();
        self.seen_dirs.deinit();
    }

    /// Set progress callback
    pub fn setProgressCallback(self: *Walker, callback: types.ProgressCallback) void {
        self.progress_callback = callback;
    }

    /// Walk a single directory path
    pub fn walk(self: *Walker, path: []const u8) !WalkResult {
        var result = WalkResult.init();
        errdefer result.deinit(self.allocator);

        try self.walkRecursive(path, &result);

        return result;
    }

    /// Walk multiple directory paths
    pub fn walkMultiple(self: *Walker, paths: []const []const u8) !WalkResult {
        var result = WalkResult.init();
        errdefer result.deinit(self.allocator);

        for (paths) |path| {
            self.walkRecursive(path, &result) catch |err| {
                const path_copy = self.allocator.dupe(u8, path) catch continue;
                result.errors.append(self.allocator, .{ .path = path_copy, .err = err }) catch {
                    self.allocator.free(path_copy);
                };
            };
        }

        return result;
    }

    fn walkRecursive(self: *Walker, path: []const u8, result: *WalkResult) !void {
        return self.walkRecursiveDepth(path, result, 0);
    }

    fn walkRecursiveDepth(self: *Walker, path: []const u8, result: *WalkResult, depth: u32) !void {
        if (depth > max_depth) return error.MaxDepthExceeded;

        const path_z = try self.allocator.dupeZ(u8, path);
        defer self.allocator.free(path_z);

        // Check if path is a directory or file
        const stat_buf = pstat.lstat(path_z.ptr) catch return error.StatFailed;

        if (!stat_buf.isDir()) {
            // It's a file, process it directly
            if (stat_buf.isFile()) {
                try self.processFileLstat(path, &stat_buf, result);
            } else if (stat_buf.isLink() and self.config.follow_symlinks) {
                try self.processSymlink(path, result, depth);
            }
            return;
        }

        // Cycle guard: a directory reached twice (only possible via a symlink or
        // a mount loop) is skipped rather than re-walked.
        const dir_id = FileId.fromStat(&stat_buf);
        if ((try self.seen_dirs.getOrPut(dir_id)).found_existing) return;

        // It's a directory - open and iterate
        const dir = libc.opendir(path_z.ptr) orelse {
            return error.CannotOpenDirectory;
        };
        defer _ = libc.closedir(dir);

        result.dirs_traversed += 1;

        while (true) {
            const entry = libc.readdir(dir) orelse break;

            const name_ptr: [*:0]const u8 = @ptrCast(&entry.name);
            const name = std.mem.span(name_ptr);

            // Skip . and ..
            if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) {
                continue;
            }

            // Skip hidden files if configured
            if (!self.config.include_hidden and name.len > 0 and name[0] == '.') {
                continue;
            }

            // Build full path
            const full_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ path, name });
            defer self.allocator.free(full_path);

            const full_path_z = try self.allocator.dupeZ(u8, full_path);
            defer self.allocator.free(full_path_z);

            // Get file info
            const entry_stat = pstat.lstat(full_path_z.ptr) catch continue;

            if (entry_stat.isDir()) {
                // Recurse into subdirectory
                self.walkRecursiveDepth(full_path, result, depth + 1) catch |err| {
                    const path_copy = self.allocator.dupe(u8, full_path) catch continue;
                    result.errors.append(self.allocator, .{ .path = path_copy, .err = err }) catch {
                        self.allocator.free(path_copy);
                    };
                };
            } else if (entry_stat.isFile()) {
                self.processFileLstat(full_path, &entry_stat, result) catch |err| {
                    const path_copy = self.allocator.dupe(u8, full_path) catch continue;
                    result.errors.append(self.allocator, .{ .path = path_copy, .err = err }) catch {
                        self.allocator.free(path_copy);
                    };
                };
            } else if (entry_stat.isLink() and self.config.follow_symlinks) {
                self.processSymlink(full_path, result, depth) catch |err| {
                    const path_copy = self.allocator.dupe(u8, full_path) catch continue;
                    result.errors.append(self.allocator, .{ .path = path_copy, .err = err }) catch {
                        self.allocator.free(path_copy);
                    };
                };
            }
        }
    }

    fn processFileLstat(self: *Walker, path: []const u8, stat_buf: *const Stat, result: *WalkResult) !void {
        const size: u64 = stat_buf.size;

        // Skip if size doesn't match criteria
        if (size < self.config.min_size) return;
        if (self.config.max_size > 0 and size > self.config.max_size) return;

        // Check for hard links (same inode already seen)
        const file_id = FileId.fromStat(stat_buf);
        if (self.seen_inodes.contains(file_id)) {
            return; // Skip duplicate inode (hard link)
        }
        try self.seen_inodes.put(file_id, {});

        // Create file entry
        const path_copy = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(path_copy);

        const file_entry = types.FileEntry{
            .path = path_copy,
            .size = size,
            .inode = stat_buf.ino,
            .dev = stat_buf.dev,
            .mtime = stat_buf.mtime_sec,
            .hash = null,
            .quick_hash = null,
        };

        try result.files.append(self.allocator, file_entry);
        result.total_size += size;

        // Update progress
        self.progress.files_processed += 1;
        self.progress.bytes_processed += size;
        self.progress.current_file = path_copy;

        if (self.progress_callback) |callback| {
            callback(&self.progress);
        }
    }

    fn processSymlink(self: *Walker, path: []const u8, result: *WalkResult, depth: u32) error{MaxDepthExceeded}!void {
        if (depth > max_depth) return error.MaxDepthExceeded;
        const path_z = self.allocator.dupeZ(u8, path) catch return;
        defer self.allocator.free(path_z);

        // Read symlink target
        var target_buf: [4096]u8 = undefined;
        const link_len = libc.readlink(path_z.ptr, &target_buf, target_buf.len);
        if (link_len <= 0) return;

        const target = target_buf[0..@intCast(link_len)];

        // Resolve to absolute path if relative
        const abs_target = if (target.len > 0 and target[0] == '/')
            self.allocator.dupe(u8, target) catch return
        else blk: {
            // Find directory of the symlink
            const last_slash = std.mem.lastIndexOf(u8, path, "/") orelse 0;
            const dir_part = if (last_slash > 0) path[0..last_slash] else ".";
            break :blk std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ dir_part, target }) catch return;
        };
        defer self.allocator.free(abs_target);

        const abs_z = self.allocator.dupeZ(u8, abs_target) catch return;
        defer self.allocator.free(abs_z);

        // stat the target (follow the link)
        const target_stat = pstat.stat(abs_z.ptr) catch return;

        if (target_stat.isDir()) {
            // walkRecursiveDepth's seen_dirs check breaks `ln -s .. loop`.
            self.walkRecursiveDepth(abs_target, result, depth + 1) catch return;
        } else if (target_stat.isFile()) {
            self.processFileLstat(abs_target, &target_stat, result) catch return;
        }
    }

    /// Get relative path from base
    pub fn relativePath(base: []const u8, full: []const u8) []const u8 {
        if (std.mem.startsWith(u8, full, base)) {
            var rel = full[base.len..];
            // Strip leading separator
            if (rel.len > 0 and (rel[0] == '/' or rel[0] == '\\')) {
                rel = rel[1..];
            }
            return rel;
        }
        return full;
    }
};

/// Quick file listing (just paths, no stats)
pub fn listFiles(allocator: std.mem.Allocator, path: []const u8) !std.ArrayListUnmanaged([]const u8) {
    var files: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer {
        for (files.items) |f| allocator.free(f);
        files.deinit(allocator);
    }

    try listFilesRecursive(allocator, path, &files);
    return files;
}

fn listFilesRecursive(allocator: std.mem.Allocator, path: []const u8, files: *std.ArrayListUnmanaged([]const u8)) !void {
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);

    const dir = libc.opendir(path_z.ptr) orelse {
        return error.CannotOpenDirectory;
    };
    defer _ = libc.closedir(dir);

    while (true) {
        const entry = libc.readdir(dir) orelse break;

        const name_ptr: [*:0]const u8 = @ptrCast(&entry.name);
        const name = std.mem.span(name_ptr);

        // Skip . and ..
        if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) {
            continue;
        }

        const full_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ path, name });
        errdefer allocator.free(full_path);

        const full_path_z = try allocator.dupeZ(u8, full_path);
        defer allocator.free(full_path_z);

        const stat_buf = pstat.lstat(full_path_z.ptr) catch {
            allocator.free(full_path);
            continue;
        };

        if (stat_buf.isDir()) {
            try listFilesRecursive(allocator, full_path, files);
            allocator.free(full_path);
        } else if (stat_buf.isFile()) {
            try files.append(allocator, full_path);
        } else {
            allocator.free(full_path);
        }
    }
}

// ============================================================================
// Tests
// ============================================================================

test "Walker initialization" {
    const allocator = std.testing.allocator;
    var walker = Walker.init(allocator, .{});
    defer walker.deinit();

    try std.testing.expect(walker.progress.phase == .scanning);
}

test "relativePath" {
    try std.testing.expectEqualStrings(
        "subdir/file.txt",
        Walker.relativePath("/home/user", "/home/user/subdir/file.txt"),
    );

    try std.testing.expectEqualStrings(
        "file.txt",
        Walker.relativePath("/home/user", "/home/user/file.txt"),
    );
}

test "FileId equality" {
    const id1 = FileId{ .dev = 1, .ino = 100 };
    const id2 = FileId{ .dev = 1, .ino = 100 };
    const id3 = FileId{ .dev = 1, .ino = 200 };

    try std.testing.expect(id1.dev == id2.dev and id1.ino == id2.ino);
    try std.testing.expect(id1.ino != id3.ino);
}
