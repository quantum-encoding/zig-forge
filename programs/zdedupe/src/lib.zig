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
