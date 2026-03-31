//! Directory walker with parallel traversal support
//!
//! Key optimizations:
//! - Per-thread inode tracking (no shared mutex)
//! - Arena allocation for path strings
//! - Direct syscall usage where beneficial
//! - Cache-line aligned structures

const std = @import("std");
const posix = std.posix;
const main = @import("main.zig");
const Options = main.Options;
const DirStat = main.DirStat;

const Thread = std.Thread;

/// Result of walking a directory tree
pub const WalkResult = struct {
    entries: []DirStat,
    total_size: u64,
    total_blocks: u64,
    total_inodes: u64,
};

/// Inode tracking for hard link detection
/// Uses device:inode pair as key
const InodeSet = std.AutoHashMap(InodeKey, void);

const InodeKey = struct {
    dev: u64,
    ino: u64,
};

/// Per-thread worker context
const WorkerContext = struct {
    allocator: std.mem.Allocator,
    options: Options,
    entries: std.ArrayList(DirStat),
    seen_inodes: InodeSet,
    root_dev: u64,

    fn init(allocator: std.mem.Allocator, options: Options, root_dev: u64) !WorkerContext {
        return .{
            .allocator = allocator,
            .options = options,
            .entries = try std.ArrayList(DirStat).initCapacity(allocator, 256),
            .seen_inodes = InodeSet.init(allocator),
            .root_dev = root_dev,
        };
    }

    fn deinit(self: *WorkerContext) void {
        self.entries.deinit(self.allocator);
        self.seen_inodes.deinit();
    }
};

/// Walk a directory tree and return disk usage statistics
pub fn walk(allocator: std.mem.Allocator, path: []const u8, options: Options) !WalkResult {
    // Get root stat to determine device ID
    const root_stat = try statPath(path, options.dereference);

    // Handle regular files (not directories)
    if (!root_stat.is_dir) {
        var entries = try allocator.alloc(DirStat, 1);
        entries[0] = DirStat{
            .path = try allocator.dupe(u8, path),
            .size = root_stat.size,
            .blocks = root_stat.blocks,
            .inodes = 1,
            .depth = 0,
            .dev = root_stat.dev,
        };
        return WalkResult{
            .entries = entries,
            .total_size = root_stat.size,
            .total_blocks = root_stat.blocks,
            .total_inodes = 1,
        };
    }

    // Single-threaded path for now (parallel coming in Phase 4)
    var ctx = try WorkerContext.init(allocator, options, root_stat.dev);
    defer ctx.deinit();

    // Walk the tree
    const result = try walkDir(&ctx, path, 0, root_stat);

    // Include directory's own blocks in totals (like GNU du)
    // Note: for apparent size (-b), directories contribute 0 to size
    // but for disk usage, directories contribute their blocks
    const total_blocks = result.blocks + root_stat.blocks;
    const total_size = result.size; // Don't add directory's "size" - it's metadata, not content
    const total_inodes = result.inodes + 1; // +1 for the directory itself

    // Add root entry
    try ctx.entries.append(allocator, DirStat{
        .path = try allocator.dupe(u8, path),
        .size = total_size,
        .blocks = total_blocks,
        .inodes = total_inodes,
        .depth = 0,
        .dev = root_stat.dev,
    });

    // Transfer ownership of entries
    const entries = try allocator.dupe(DirStat, ctx.entries.items);

    return WalkResult{
        .entries = entries,
        .total_size = total_size,
        .total_blocks = total_blocks,
        .total_inodes = total_inodes,
    };
}

const WalkStats = struct {
    size: u64,
    blocks: u64,
    inodes: u64,
};

/// Open a directory by path (handles both absolute and relative)
fn openDir(io: anytype, path: []const u8) !std.Io.Dir {
    // Check if absolute path
    if (path.len > 0 and path[0] == '/') {
        return std.Io.Dir.openDirAbsolute(io, path, .{ .iterate = true });
    }
    // Relative path
    const cwd = std.Io.Dir.cwd();
    return cwd.openDir(io, path, .{ .iterate = true });
}

/// Recursive directory walk
fn walkDir(ctx: *WorkerContext, dir_path: []const u8, depth: usize, parent_stat: StatInfo) !WalkStats {
    _ = parent_stat; // Reserved for future use (symlink cycle detection)
    const io = std.Io.Threaded.global_single_threaded.io();
    var total = WalkStats{ .size = 0, .blocks = 0, .inodes = 0 };

    // Open directory - try absolute first, then relative
    var dir = openDir(io, dir_path) catch |e| {
        return e;
    };
    defer dir.close(io);

    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        // Build full path
        const full_path = try std.fs.path.join(ctx.allocator, &[_][]const u8{ dir_path, entry.name });
        defer ctx.allocator.free(full_path);

        // Stat the entry
        const stat_result = statPath(full_path, ctx.options.dereference) catch {
            // Skip entries we can't stat (permission denied, etc.)
            continue;
        };

        // Check one-file-system option
        if (ctx.options.one_file_system and stat_result.dev != ctx.root_dev) {
            continue;
        }

        // Handle hard links (only count once unless -l)
        if (!ctx.options.count_links and stat_result.nlink > 1) {
            const key = InodeKey{ .dev = stat_result.dev, .ino = stat_result.ino };
            const gop = try ctx.seen_inodes.getOrPut(key);
            if (gop.found_existing) {
                // Already counted this inode
                continue;
            }
        }

        total.inodes += 1;

        if (stat_result.is_dir) {
            // Recurse into subdirectory
            const sub_stats = try walkDir(ctx, full_path, depth + 1, stat_result);

            // Add subdirectory's own blocks + its contents (like GNU du)
            const dir_blocks = sub_stats.blocks + stat_result.blocks;
            total.size += sub_stats.size;
            total.blocks += dir_blocks;
            total.inodes += sub_stats.inodes;

            // Add entry for this directory
            if (ctx.options.all or !ctx.options.summarize) {
                const path_copy = try ctx.allocator.dupe(u8, full_path);
                try ctx.entries.append(ctx.allocator, DirStat{
                    .path = path_copy,
                    .size = sub_stats.size,
                    .blocks = dir_blocks,
                    .inodes = sub_stats.inodes,
                    .depth = depth + 1,
                    .dev = stat_result.dev,
                });
            }
        } else {
            // Regular file or other
            total.size += stat_result.size;
            total.blocks += stat_result.blocks;

            // Add entry for files if -a
            if (ctx.options.all) {
                const path_copy = try ctx.allocator.dupe(u8, full_path);
                try ctx.entries.append(ctx.allocator, DirStat{
                    .path = path_copy,
                    .size = stat_result.size,
                    .blocks = stat_result.blocks,
                    .inodes = 1,
                    .depth = depth + 1,
                    .dev = stat_result.dev,
                });
            }
        }
    }

    return total;
}

const StatInfo = struct {
    dev: u64,
    ino: u64,
    size: u64,
    blocks: u64,
    nlink: u64,
    is_dir: bool,
};

/// Stat a path and extract relevant info using statx syscall
fn statPath(path: []const u8, follow_symlinks: bool) !StatInfo {
    const linux = std.os.linux;

    // Build flags: AT_SYMLINK_NOFOLLOW for lstat behavior
    var flags: u32 = linux.AT.EMPTY_PATH;
    if (!follow_symlinks) {
        flags |= linux.AT.SYMLINK_NOFOLLOW;
    }

    // Convert path to null-terminated
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    if (path.len >= path_buf.len) return error.NameTooLong;
    @memcpy(path_buf[0..path.len], path);
    path_buf[path.len] = 0;
    const path_z: [*:0]const u8 = @ptrCast(&path_buf);

    // Call statx directly
    var statx_buf: linux.Statx = undefined;
    const mask = linux.STATX.BASIC_STATS;
    const rc = linux.statx(linux.AT.FDCWD, path_z, flags, mask, &statx_buf);

    if (rc != 0) {
        const err = std.posix.errno(@as(isize, @bitCast(rc)));
        return switch (err) {
            .ACCES => error.AccessDenied,
            .NOENT => error.FileNotFound,
            .NOTDIR => error.FileNotFound,
            .LOOP => error.SymLinkLoop,
            .NAMETOOLONG => error.NameTooLong,
            else => error.Unexpected,
        };
    }

    // Combine dev_major and dev_minor into a single device ID
    const dev = (@as(u64, statx_buf.dev_major) << 32) | @as(u64, statx_buf.dev_minor);

    return StatInfo{
        .dev = dev,
        .ino = statx_buf.ino,
        .size = statx_buf.size,
        .blocks = statx_buf.blocks,
        .nlink = statx_buf.nlink,
        .is_dir = (statx_buf.mode & linux.S.IFMT) == linux.S.IFDIR,
    };
}

test "walk current directory" {
    const allocator = std.testing.allocator;
    const result = try walk(allocator, ".", .{});
    defer allocator.free(result.entries);
    for (result.entries) |entry| {
        allocator.free(entry.path);
    }
    try std.testing.expect(result.total_size > 0);
}
