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
const builtin = @import("builtin");

// Re-export modules
pub const types = @import("types.zig");
pub const hasher = @import("hasher.zig");
pub const walker = @import("walker.zig");
pub const dedupe = @import("dedupe.zig");
pub const compare = @import("compare.zig");
pub const report = @import("report.zig");
pub const parallel = @import("parallel.zig");
pub const dirs = @import("dirs.zig");
pub const store = @import("store.zig");

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
pub const DirAnalysis = dirs.Analysis;
pub const Monitor = types.Monitor;

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
    /// Owned copies of the names passed to zdedupe_add_exclude.
    user_excludes: std.ArrayListUnmanaged([]const u8),
    use_default_excludes: bool,
    /// Progress out / cancellation in. Lives in the context so its address is
    /// stable for the whole run and other threads can reach it.
    monitor: types.Monitor,

    const Mode = enum(c_int) { find_duplicates = 0, compare_folders = 1 };
    const alloc = std.heap.c_allocator;

    fn init() ?*InternalContext {
        const self = libc_alloc.create(InternalContext) catch return null;
        self.* = .{
            .config = .{},
            .paths = .empty,
            .mode = .find_duplicates,
            .result_json = null,
            .user_excludes = .empty,
            .use_default_excludes = false,
            .monitor = .{},
        };
        return self;
    }

    fn deinit(self: *InternalContext) void {
        // Free internal allocations using c_allocator
        for (self.paths.items) |p| alloc.free(p);
        self.paths.deinit(alloc);
        if (self.result_json) |j| alloc.free(j);
        for (self.user_excludes.items) |name| alloc.free(name);
        self.user_excludes.deinit(alloc);
        // Free the context using libc allocator
        libc_alloc.destroy(self);
    }
};

// === Context Management ===

pub export fn zdedupe_init() ?*ZDedupeContext {
    const ctx = InternalContext.init() orelse return null;
    return @ptrCast(ctx);
}

pub export fn zdedupe_free(ctx: ?*ZDedupeContext) void {
    if (ctx) |c| {
        const internal: *InternalContext = @ptrCast(@alignCast(c));
        internal.deinit();
    }
}

// === Configuration ===

pub export fn zdedupe_add_path(ctx: ?*ZDedupeContext, path: [*:0]const u8) c_int {
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

pub export fn zdedupe_set_mode(ctx: ?*ZDedupeContext, mode: c_int) void {
    const c = ctx orelse return;
    const internal: *InternalContext = @ptrCast(@alignCast(c));
    internal.mode = @enumFromInt(mode);
}

pub export fn zdedupe_set_min_size(ctx: ?*ZDedupeContext, bytes: u64) void {
    const c = ctx orelse return;
    const internal: *InternalContext = @ptrCast(@alignCast(c));
    internal.config.min_size = bytes;
}

pub export fn zdedupe_set_max_size(ctx: ?*ZDedupeContext, bytes: u64) void {
    const c = ctx orelse return;
    const internal: *InternalContext = @ptrCast(@alignCast(c));
    internal.config.max_size = bytes;
}

pub export fn zdedupe_set_include_hidden(ctx: ?*ZDedupeContext, include: bool) void {
    const c = ctx orelse return;
    const internal: *InternalContext = @ptrCast(@alignCast(c));
    internal.config.include_hidden = include;
}

pub export fn zdedupe_set_follow_symlinks(ctx: ?*ZDedupeContext, follow: bool) void {
    const c = ctx orelse return;
    const internal: *InternalContext = @ptrCast(@alignCast(c));
    internal.config.follow_symlinks = follow;
}

pub export fn zdedupe_set_threads(ctx: ?*ZDedupeContext, count: u32) void {
    const c = ctx orelse return;
    const internal: *InternalContext = @ptrCast(@alignCast(c));
    internal.config.threads = count;
}

pub export fn zdedupe_use_sha256(ctx: ?*ZDedupeContext, use_sha256: bool) void {
    const c = ctx orelse return;
    const internal: *InternalContext = @ptrCast(@alignCast(c));
    internal.config.hash_algorithm = if (use_sha256) .sha256 else .blake3;
}

pub export fn zdedupe_set_analyze_dirs(ctx: ?*ZDedupeContext, analyze: bool) void {
    const c = ctx orelse return;
    const internal: *InternalContext = @ptrCast(@alignCast(c));
    internal.config.analyze_dirs = analyze;
}

pub export fn zdedupe_use_default_excludes(ctx: ?*ZDedupeContext, use_defaults: bool) void {
    const c = ctx orelse return;
    const internal: *InternalContext = @ptrCast(@alignCast(c));
    internal.use_default_excludes = use_defaults;
}

pub export fn zdedupe_add_exclude(ctx: ?*ZDedupeContext, name: [*:0]const u8) c_int {
    const c = ctx orelse return -1;
    const internal: *InternalContext = @ptrCast(@alignCast(c));
    const alloc = std.heap.c_allocator;

    // An exclude is one path component. A name holding a slash could never
    // match, so refuse it rather than accept a filter that silently does nothing.
    const span = std.mem.span(name);
    if (span.len == 0 or std.mem.indexOfScalar(u8, span, '/') != null) return -1;

    const owned = alloc.dupe(u8, span) catch return -1;
    internal.user_excludes.append(alloc, owned) catch {
        alloc.free(owned);
        return -1;
    };
    return 0;
}

// === Progress & cancellation ===
//
// The only two entry points that may be called from another thread while a
// run is in progress: they touch nothing but atomics inside the context.

/// Mirrors `zdedupe_progress` in the C header.
pub const ZDedupeProgress = extern struct {
    /// `Monitor.Phase` numbering.
    phase: u32,
    _pad: u32 = 0,
    files_found: u64,
    done: u64,
    total: u64,
};

pub export fn zdedupe_get_progress(ctx: ?*const ZDedupeContext, out: ?*ZDedupeProgress) void {
    const c = ctx orelse return;
    const result = out orelse return;
    const internal: *const InternalContext = @ptrCast(@alignCast(c));
    result.* = .{
        .phase = internal.monitor.phase.load(.acquire),
        .files_found = internal.monitor.files_found.load(.acquire),
        .done = internal.monitor.done.load(.acquire),
        .total = internal.monitor.total.load(.acquire),
    };
}

pub export fn zdedupe_cancel(ctx: ?*ZDedupeContext) void {
    const c = ctx orelse return;
    const internal: *InternalContext = @ptrCast(@alignCast(c));
    internal.monitor.cancel();
}

// === Execution ===

/// Run a duplicate scan and write the binary result store (see store.zig) to
/// `path`. Returns a `RunStatus`.
pub export fn zdedupe_run_to_file(ctx: ?*ZDedupeContext, path: ?[*:0]const u8) c_int {
    const c = ctx orelse return @intFromEnum(RunStatus.failed);
    const path_z = path orelse return @intFromEnum(RunStatus.failed);
    const internal: *InternalContext = @ptrCast(@alignCast(c));
    if (internal.mode != .find_duplicates) return @intFromEnum(RunStatus.unsupported);

    const status = runDuplicateScan(internal, std.mem.span(path_z), struct {
        fn emit(out_path: []const u8, inner: *InternalContext, finder: *DupeFinder) RunStatus {
            inner.monitor.enter(.writing, 0);
            store.write(out_path, .{
                .groups = finder.getGroups(),
                .summary = finder.getSummary(),
                .failed_paths = finder.getFailedPathCount(),
                .analysis = finder.getDirAnalysis(),
                .algorithm = inner.config.hash_algorithm,
            }) catch return .failed;
            return .ok;
        }
    }.emit);
    // Results are on disk and the scan's working memory has been freed; do not
    // leave the host process sitting on it.
    releaseFreedMemory();
    return @intFromEnum(status);
}

pub export fn zdedupe_run_sync(ctx: ?*ZDedupeContext) ?[*:0]const u8 {
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
    // The scan's working memory is gone by now; only the report is live.
    releaseFreedMemory();

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

/// True where libc is glibc, the one allocator this matters for.
const has_malloc_trim = builtin.os.tag == .linux and builtin.abi.isGnu();

extern "c" fn malloc_trim(pad: usize) c_int;

/// Give memory the scan has freed back to the operating system.
///
/// A scan makes millions of small, short-lived allocations. glibc keeps the
/// freed chunks for reuse rather than returning them, so a host process was
/// left holding most of the scan's peak after it finished — measured in the
/// desktop app: 1.08 GB still resident after a 2.4M-file scan whose results
/// were already on disk. `malloc_trim` releases the free pages; the same scan
/// pattern drops from 104 MB retained to 25 MB. Other allocators (macOS,
/// musl) either return memory on their own or have no equivalent call.
fn releaseFreedMemory() void {
    if (comptime has_malloc_trim) _ = malloc_trim(0);
}

/// Result codes of `zdedupe_run_to_file`; numbering is part of the C ABI.
const RunStatus = enum(c_int) { ok = 0, failed = 1, cancelled = 2, unsupported = 3 };

/// Runs the duplicate scan described by the context and hands the finished
/// finder to `emit`. Shared by the JSON and the result-store entry points so
/// both see exactly the same configuration.
fn runDuplicateScan(
    internal: *InternalContext,
    context: anytype,
    comptime emit: fn (@TypeOf(context), *InternalContext, *DupeFinder) RunStatus,
) RunStatus {
    const alloc = std.heap.c_allocator;
    const monitor = &internal.monitor;

    // Progress restarts; a cancel requested before the run began still counts.
    const cancel_was_requested = monitor.cancelled();
    monitor.reset();
    if (cancel_was_requested) monitor.cancel();
    // Whatever happens, the next run on this context starts un-cancelled.
    defer monitor.cancel_requested.store(false, .release);

    // Effective exclude list: the defaults (if asked for) plus added names.
    var excludes: std.ArrayListUnmanaged([]const u8) = .empty;
    defer excludes.deinit(alloc);
    if (internal.use_default_excludes) {
        excludes.appendSlice(alloc, &Config.default_excludes) catch return .failed;
    }
    excludes.appendSlice(alloc, internal.user_excludes.items) catch return .failed;

    var config = internal.config;
    config.excludes = excludes.items;
    config.exclude_cache_dirs = internal.use_default_excludes;
    config.monitor = monitor;

    var finder = DupeFinder.init(alloc, config);
    defer finder.deinit();

    finder.scan(internal.paths.items) catch |err| return switch (err) {
        error.Cancelled => .cancelled,
        else => .failed,
    };

    const status = emit(context, internal, &finder);
    if (status == .ok) monitor.enter(.done, 0);
    return status;
}

fn runDuplicates(internal: *InternalContext) ?[]u8 {
    var json: ?[]u8 = null;
    const status = runDuplicateScan(internal, &json, struct {
        fn emit(out: *?[]u8, _: *InternalContext, finder: *DupeFinder) RunStatus {
            const alloc = std.heap.c_allocator;
            // Generate JSON report using Allocating writer
            var alloc_writer: std.Io.Writer.Allocating = .init(alloc);

            const reporter = ReportWriter.init(alloc, .{ .format = .json });
            reporter.writeScanReport(&alloc_writer.writer, finder.getGroups(), finder.getSummary(), finder.getDirAnalysis()) catch {
                alloc_writer.deinit();
                return .failed;
            };
            out.* = alloc_writer.toOwnedSlice() catch {
                alloc_writer.deinit();
                return .failed;
            };
            return .ok;
        }
    }.emit);
    return if (status == .ok) json else null;
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

pub export fn zdedupe_delete_file(path: [*:0]const u8) c_int {
    const result = unlink(path);
    return if (result == 0) 0 else -1;
}

pub export fn zdedupe_move_file(src: [*:0]const u8, dst: [*:0]const u8) c_int {
    const result = rename(src, dst);
    return if (result == 0) 0 else -1;
}

/// Hash one file with the algorithm a scan would use, into `out` (32 bytes).
///
/// For hosts that are about to delete a duplicate *permanently*: a scan result
/// says what a file contained when it was scanned, which may be hours ago.
/// Re-hashing the file and the copy being kept, and comparing both with the
/// group's recorded hash, turns that into a statement about the disk now.
/// Same guards as the scan: non-regular files are refused, and a read error
/// is a failure, never a hash of whatever was read so far.
pub export fn zdedupe_hash_file(path: ?[*:0]const u8, use_sha256: bool, out: ?*[32]u8) c_int {
    const path_z = path orelse return -1;
    const result = out orelse return -1;
    const file_hasher = hasher.FileHasher.init(if (use_sha256) .sha256 else .blake3);
    result.* = file_hasher.hashFile(std.mem.span(path_z)) catch return -1;
    return 0;
}

pub export fn zdedupe_version() [*:0]const u8 {
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
    _ = dirs;
    _ = store;
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
    zdedupe_set_analyze_dirs(ctx, true);
    zdedupe_use_default_excludes(ctx, true);
    try std.testing.expectEqual(@as(c_int, 0), zdedupe_add_exclude(ctx, "vendor"));
    try std.testing.expectEqual(@as(c_int, -1), zdedupe_add_exclude(ctx, "some/path"));
    try std.testing.expectEqual(@as(c_int, -1), zdedupe_add_exclude(ctx, ""));
    zdedupe_free(ctx);
}

test "version" {
    const v = zdedupe_version();
    try std.testing.expectEqualStrings("0.1.0", std.mem.span(v));
}
