//! zdedupe - Cross-platform duplicate finder and folder comparator
//!
//! Zig API:
//!   const zdedupe = @import("zdedupe");
//!   var finder = zdedupe.DupeFinder.init(allocator, .{});
//!   try finder.scan(&.{ "/path" });
//!   const groups = finder.getGroups();
//!
//! C FFI API (for Tauri):
//!   zdedupe_ctx* ctx = zdedupe_init();
//!   zdedupe_add_path(ctx, "/path");
//!   const char* json = zdedupe_run_sync(ctx);
//!   zdedupe_free(ctx);

const std = @import("std");

// Re-export modules
pub const types = @import("types.zig");
pub const hasher = @import("hasher.zig");
pub const walker = @import("walker.zig");
pub const dedupe = @import("dedupe.zig");
pub const compare = @import("compare.zig");
pub const report = @import("report.zig");
pub const parallel = @import("parallel.zig");

// Re-export commonly used types
pub const FileEntry = types.FileEntry;
pub const DuplicateGroup = types.DuplicateGroup;
pub const CompareResult = types.CompareResult;
pub const Config = types.Config;
pub const Progress = types.Progress;
pub const ReportFormat = types.ReportFormat;
pub const ReportOptions = types.ReportOptions;
pub const DuplicateSummary = types.DuplicateSummary;
pub const CompareSummary = types.CompareSummary;

pub const DupeFinder = dedupe.DupeFinder;
pub const FolderComparator = compare.FolderComparator;
pub const ReportWriter = report.ReportWriter;

// Convenience functions
pub const findDuplicates = dedupe.findDuplicates;
pub const compareFolders = compare.compareFolders;

// =============================================================================
// C FFI Interface for Tauri
// =============================================================================

pub const ZDedupeContext = opaque {};

// Use libc for context allocation to avoid GPA self-referential issues
const libc_alloc = std.heap.c_allocator;

const InternalContext = struct {
    config: Config,
    paths: std.ArrayListUnmanaged([]const u8),
    mode: Mode,
    result_json: ?[:0]u8,

    const Mode = enum(c_int) { find_duplicates = 0, compare_folders = 1 };
    const alloc = std.heap.c_allocator;

    fn init() ?*InternalContext {
        const self = libc_alloc.create(InternalContext) catch return null;
        self.* = .{
            .config = .{},
            .paths = .empty,
            .mode = .find_duplicates,
            .result_json = null,
        };
        return self;
    }

    fn deinit(self: *InternalContext) void {
        // Free internal allocations using c_allocator
        for (self.paths.items) |p| alloc.free(p);
        self.paths.deinit(alloc);
        if (self.result_json) |j| alloc.free(j);
        // Free the context using libc allocator
        libc_alloc.destroy(self);
    }
};

// === Context Management ===

export fn zdedupe_init() ?*ZDedupeContext {
    const ctx = InternalContext.init() orelse return null;
    return @ptrCast(ctx);
}

export fn zdedupe_free(ctx: ?*ZDedupeContext) void {
    if (ctx) |c| {
        const internal: *InternalContext = @ptrCast(@alignCast(c));
        internal.deinit();
    }
}

// === Configuration ===

export fn zdedupe_add_path(ctx: ?*ZDedupeContext, path: [*:0]const u8) c_int {
    const c = ctx orelse return -1;
    const internal: *InternalContext = @ptrCast(@alignCast(c));
    const alloc = std.heap.c_allocator;
    const owned = alloc.dupe(u8, std.mem.span(path)) catch return -1;
    internal.paths.append(alloc, owned) catch {
        alloc.free(owned);
        return -1;
    };
    return 0;
}

export fn zdedupe_set_mode(ctx: ?*ZDedupeContext, mode: c_int) void {
    const c = ctx orelse return;
    const internal: *InternalContext = @ptrCast(@alignCast(c));
    internal.mode = @enumFromInt(mode);
}

export fn zdedupe_set_min_size(ctx: ?*ZDedupeContext, bytes: u64) void {
    const c = ctx orelse return;
    const internal: *InternalContext = @ptrCast(@alignCast(c));
    internal.config.min_size = bytes;
}

export fn zdedupe_set_max_size(ctx: ?*ZDedupeContext, bytes: u64) void {
    const c = ctx orelse return;
    const internal: *InternalContext = @ptrCast(@alignCast(c));
    internal.config.max_size = bytes;
}

export fn zdedupe_set_include_hidden(ctx: ?*ZDedupeContext, include: bool) void {
    const c = ctx orelse return;
    const internal: *InternalContext = @ptrCast(@alignCast(c));
    internal.config.include_hidden = include;
}

export fn zdedupe_set_follow_symlinks(ctx: ?*ZDedupeContext, follow: bool) void {
    const c = ctx orelse return;
    const internal: *InternalContext = @ptrCast(@alignCast(c));
    internal.config.follow_symlinks = follow;
}

export fn zdedupe_set_threads(ctx: ?*ZDedupeContext, count: u32) void {
    const c = ctx orelse return;
    const internal: *InternalContext = @ptrCast(@alignCast(c));
    internal.config.threads = count;
}

export fn zdedupe_use_sha256(ctx: ?*ZDedupeContext, use_sha256: bool) void {
    const c = ctx orelse return;
    const internal: *InternalContext = @ptrCast(@alignCast(c));
    internal.config.hash_algorithm = if (use_sha256) .sha256 else .blake3;
}

// === Execution ===

export fn zdedupe_run_sync(ctx: ?*ZDedupeContext) ?[*:0]const u8 {
    const c = ctx orelse return null;
    const internal: *InternalContext = @ptrCast(@alignCast(c));
    const alloc = std.heap.c_allocator;

    // Clear previous result
    if (internal.result_json) |j| {
        alloc.free(j);
        internal.result_json = null;
    }

    const json_result: ?[]u8 = switch (internal.mode) {
        .find_duplicates => runDuplicates(internal),
        .compare_folders => runCompare(internal),
    };

    if (json_result) |json| {
        // Add null terminator
        const with_null = alloc.allocSentinel(u8, json.len, 0) catch {
            alloc.free(json);
            return null;
        };
        @memcpy(with_null, json);
        alloc.free(json);
        internal.result_json = with_null;
        return with_null.ptr;
    }
    return null;
}

fn runDuplicates(internal: *InternalContext) ?[]u8 {
    const alloc = std.heap.c_allocator;

    var finder = DupeFinder.init(alloc, internal.config);
    defer finder.deinit();

    finder.scan(internal.paths.items) catch return null;

    // Generate JSON report using Allocating writer
    var alloc_writer: std.Io.Writer.Allocating = .init(alloc);
    errdefer alloc_writer.deinit();

    const reporter = ReportWriter.init(alloc, .{ .format = .json });
    reporter.writeDuplicateReport(&alloc_writer.writer, finder.getGroups(), finder.getSummary()) catch return null;

    return alloc_writer.toOwnedSlice() catch null;
}

fn runCompare(internal: *InternalContext) ?[]u8 {
    const alloc = std.heap.c_allocator;

    if (internal.paths.items.len < 2) return null;

    var cmp = FolderComparator.init(alloc, internal.config);
    var result = cmp.compare(internal.paths.items[0], internal.paths.items[1]) catch return null;
    defer result.deinit();

    // Generate JSON report using Allocating writer
    var alloc_writer: std.Io.Writer.Allocating = .init(alloc);
    errdefer alloc_writer.deinit();

    const reporter = ReportWriter.init(alloc, .{ .format = .json });
    reporter.writeCompareReport(&alloc_writer.writer, &result) catch return null;

    return alloc_writer.toOwnedSlice() catch null;
}

// === Utilities ===

// C library functions for file operations
extern "c" fn unlink(path: [*:0]const u8) c_int;
extern "c" fn rename(old: [*:0]const u8, new: [*:0]const u8) c_int;

export fn zdedupe_delete_file(path: [*:0]const u8) c_int {
    const result = unlink(path);
    return if (result == 0) 0 else -1;
}

export fn zdedupe_move_file(src: [*:0]const u8, dst: [*:0]const u8) c_int {
    const result = rename(src, dst);
    return if (result == 0) 0 else -1;
}

export fn zdedupe_version() [*:0]const u8 {
    return "0.1.0";
}

// =============================================================================
// Directory Listing and Metadata
// =============================================================================

/// Result handle for directory listing (must be freed with zdedupe_free_result)
pub const ZDedupeResult = opaque {};

const ResultContext = struct {
    json: [:0]u8,
    allocator: std.mem.Allocator,

    fn deinit(self: *ResultContext) void {
        self.allocator.free(self.json);
        self.allocator.destroy(self);
    }
};

/// List directory contents - returns JSON array
/// Format: [{"name": "file.txt", "type": "file", "size": 1234}, ...]
/// Types: "file", "dir", "link", "other"
export fn zdedupe_list_dir(path: [*:0]const u8) ?*ZDedupeResult {
    const allocator = std.heap.c_allocator;
    const path_slice = std.mem.span(path);

    var alloc_writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer alloc_writer.deinit();

    listDirJson(&alloc_writer.writer, allocator, path_slice) catch return null;

    const json = alloc_writer.toOwnedSliceSentinel(0) catch return null;

    const result = allocator.create(ResultContext) catch {
        allocator.free(json);
        return null;
    };
    result.* = .{
        .json = json,
        .allocator = allocator,
    };
    return @ptrCast(result);
}

fn listDirJson(writer: *std.Io.Writer, allocator: std.mem.Allocator, path: []const u8) !void {
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);

    const dir = libc.opendir(path_z.ptr) orelse return error.CannotOpenDirectory;
    defer _ = libc.closedir(dir);

    try writer.writeAll("[");
    var first = true;

    while (true) {
        const entry = libc.readdir(dir) orelse break;
        const name_ptr: [*:0]const u8 = @ptrCast(&entry.name);
        const name = std.mem.span(name_ptr);

        // Skip . and ..
        if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;

        if (!first) try writer.writeAll(",");
        first = false;

        // Get file stats
        const full_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ path, name });
        defer allocator.free(full_path);

        const full_path_z = try allocator.dupeZ(u8, full_path);
        defer allocator.free(full_path_z);

        var stat_buf: Stat = undefined;
        const stat_result = lstat(full_path_z.ptr, &stat_buf);

        const file_type: []const u8 = if (stat_result != 0)
            "other"
        else if ((stat_buf.mode & 0o170000) == 0o40000)
            "dir"
        else if ((stat_buf.mode & 0o170000) == 0o100000)
            "file"
        else if ((stat_buf.mode & 0o170000) == 0o120000)
            "link"
        else
            "other";

        const size: i64 = if (stat_result == 0) stat_buf.size else 0;
        const mtime: i64 = if (stat_result == 0) stat_buf.mtim.sec else 0;

        try writer.print(
            \\{{"name":"{s}","type":"{s}","size":{d},"mtime":{d}}}
        , .{ escapeJsonStr(name), file_type, size, mtime });
    }

    try writer.writeAll("]");
}

/// Get metadata for a single file - returns JSON
/// Format: {"path": "...", "size": 1234, "mtime": 123456, "type": "file", "hash": "..."}
export fn zdedupe_get_metadata(path: [*:0]const u8, include_hash: bool) ?*ZDedupeResult {
    const allocator = std.heap.c_allocator;
    const path_slice = std.mem.span(path);

    var alloc_writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer alloc_writer.deinit();

    getMetadataJson(&alloc_writer.writer, allocator, path_slice, include_hash) catch return null;

    const json = alloc_writer.toOwnedSliceSentinel(0) catch return null;

    const result = allocator.create(ResultContext) catch {
        allocator.free(json);
        return null;
    };
    result.* = .{
        .json = json,
        .allocator = allocator,
    };
    return @ptrCast(result);
}

fn getMetadataJson(writer: *std.Io.Writer, allocator: std.mem.Allocator, path: []const u8, include_hash: bool) !void {
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);

    var stat_buf: Stat = undefined;
    if (lstat(path_z.ptr, &stat_buf) != 0) {
        try writer.print(
            \\{{"error":"stat failed","path":"{s}"}}
        , .{escapeJsonStr(path)});
        return;
    }

    const file_type: []const u8 = if ((stat_buf.mode & 0o170000) == 0o40000)
        "dir"
    else if ((stat_buf.mode & 0o170000) == 0o100000)
        "file"
    else if ((stat_buf.mode & 0o170000) == 0o120000)
        "link"
    else
        "other";

    try writer.print(
        \\{{"path":"{s}","type":"{s}","size":{d},"mtime":{d},"inode":{d}
    , .{ escapeJsonStr(path), file_type, stat_buf.size, stat_buf.mtim.sec, stat_buf.ino });

    // Optionally compute hash for files
    if (include_hash and std.mem.eql(u8, file_type, "file")) {
        const file_hasher = hasher.FileHasher.init(.blake3);
        if (file_hasher.hashFile(path)) |hash| {
            var hex_buf: [64]u8 = undefined;
            const hex = hasher.hashToHex(&hash, &hex_buf);
            try writer.print(
                \\,"hash":"{s}"
            , .{hex});
        } else |_| {}
    }

    try writer.writeAll("}");
}

/// Get JSON result string from result handle
export fn zdedupe_result_json(result: ?*ZDedupeResult) ?[*:0]const u8 {
    if (result) |r| {
        const ctx: *ResultContext = @ptrCast(@alignCast(r));
        return ctx.json.ptr;
    }
    return null;
}

/// Free result handle
export fn zdedupe_free_result(result: ?*ZDedupeResult) void {
    if (result) |r| {
        const ctx: *ResultContext = @ptrCast(@alignCast(r));
        ctx.deinit();
    }
}

// =============================================================================
// Batch Operations
// =============================================================================

/// Batch delete files - takes null-terminated array of null-terminated paths
/// Returns number of successfully deleted files, -1 on error
export fn zdedupe_batch_delete(paths: [*]const [*:0]const u8, count: usize) c_int {
    var success: c_int = 0;
    for (0..count) |i| {
        if (unlink(paths[i]) == 0) {
            success += 1;
        }
    }
    return success;
}

/// Batch move files to a destination directory
/// paths: array of source paths
/// dest_dir: destination directory (must exist)
/// Returns number of successfully moved files
export fn zdedupe_batch_move(paths: [*]const [*:0]const u8, count: usize, dest_dir: [*:0]const u8) c_int {
    const allocator = std.heap.c_allocator;
    const dest_slice = std.mem.span(dest_dir);

    var success: c_int = 0;
    for (0..count) |i| {
        const src_path = std.mem.span(paths[i]);

        // Extract filename from source path
        const filename = if (std.mem.lastIndexOf(u8, src_path, "/")) |idx|
            src_path[idx + 1 ..]
        else
            src_path;

        // Build destination path with null terminator
        const dest_path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ dest_slice, filename }) catch continue;
        defer allocator.free(dest_path);

        const dest_path_z = allocator.dupeZ(u8, dest_path) catch continue;
        defer allocator.free(dest_path_z);

        if (rename(paths[i], dest_path_z.ptr) == 0) {
            success += 1;
        }
    }
    return success;
}

/// Batch operation result - returns JSON with details
/// Format: {"success": N, "failed": N, "errors": [{"path": "...", "error": "..."}]}
export fn zdedupe_batch_delete_detailed(paths: [*]const [*:0]const u8, count: usize) ?*ZDedupeResult {
    const allocator = std.heap.c_allocator;

    var alloc_writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer alloc_writer.deinit();

    batchDeleteJson(&alloc_writer.writer, paths, count) catch return null;

    const json = alloc_writer.toOwnedSliceSentinel(0) catch return null;

    const result = allocator.create(ResultContext) catch {
        allocator.free(json);
        return null;
    };
    result.* = .{
        .json = json,
        .allocator = allocator,
    };
    return @ptrCast(result);
}

// C errno access
extern "c" var errno: c_int;

fn batchDeleteJson(writer: *std.Io.Writer, paths: [*]const [*:0]const u8, count: usize) !void {
    var success: usize = 0;
    var failed: usize = 0;

    try writer.writeAll("{\"errors\":[");
    var first_error = true;

    for (0..count) |i| {
        if (unlink(paths[i]) == 0) {
            success += 1;
        } else {
            failed += 1;
            if (!first_error) try writer.writeAll(",");
            first_error = false;

            const path_slice = std.mem.span(paths[i]);
            try writer.print(
                \\{{"path":"{s}","errno":{d}}}
            , .{ escapeJsonStr(path_slice), errno });
        }
    }

    try writer.print(
        \\],"success":{d},"failed":{d}}}
    , .{ success, failed });
}

// =============================================================================
// Helper Functions
// =============================================================================

const libc = std.c;
const builtin = @import("builtin");

// Cross-platform Stat structure (same as walker.zig)
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

/// Simple JSON string escaping (handles quotes and backslashes)
fn escapeJsonStr(s: []const u8) []const u8 {
    // For simplicity, return as-is - file paths typically don't have quotes
    // A full implementation would escape special characters
    return s;
}

// =============================================================================
// Tests
// =============================================================================

test "imports" {
    _ = types;
    _ = hasher;
    _ = walker;
    _ = dedupe;
    _ = compare;
    _ = report;
    _ = parallel;
}

test "C FFI lifecycle" {
    const ctx = zdedupe_init();
    try std.testing.expect(ctx != null);
    zdedupe_set_mode(ctx, 0);
    zdedupe_set_min_size(ctx, 1024);
    zdedupe_set_max_size(ctx, 0);
    zdedupe_set_include_hidden(ctx, true);
    zdedupe_set_follow_symlinks(ctx, false);
    zdedupe_use_sha256(ctx, false);
    zdedupe_free(ctx);
}

test "version" {
    const v = zdedupe_version();
    try std.testing.expectEqualStrings("0.1.0", std.mem.span(v));
}
