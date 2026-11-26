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
pub const filters = @import("filters.zig");
pub const removed = @import("removed.zig");
pub const session = @import("session.zig");
pub const space = @import("space.zig");
pub const clean = @import("clean.zig");

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

/// The allocator behind everything the C API hands out: libc's malloc where
/// there is a libc; on Windows (no C runtime linked) Zig's thread-safe
/// general-purpose allocator.
const core_alloc = if (builtin.os.tag == .windows) std.heap.smp_allocator else std.heap.c_allocator;

// Use libc for context allocation to avoid GPA self-referential issues
const libc_alloc = core_alloc;

const InternalContext = struct {
    config: Config,
    paths: std.ArrayListUnmanaged([]const u8),
    mode: Mode,
    result_json: ?[:0]u8,
    /// Owned copies of the names passed to zdedupe_add_exclude.
    user_excludes: std.ArrayListUnmanaged([]const u8),
    exclude_paths: std.ArrayListUnmanaged([]const u8),
    use_default_excludes: bool,
    use_credential_excludes: bool,
    /// Progress out / cancellation in. Lives in the context so its address is
    /// stable for the whole run and other threads can reach it.
    monitor: types.Monitor,
    /// The last zdedupe_clean_scan's report, which zdedupe_clean_trash moves
    /// from, and the answers and error the clean calls hand out (each valid
    /// until the next clean call on this context, or zdedupe_free).
    clean_report: ?clean.Report = null,
    clean_answer: ?[:0]u8 = null,
    clean_error: ?[:0]u8 = null,

    const Mode = enum(c_int) { find_duplicates = 0, compare_folders = 1, disk_space = 2 };
    const alloc = core_alloc;

    fn init() ?*InternalContext {
        const self = libc_alloc.create(InternalContext) catch return null;
        self.* = .{
            .config = .{},
            .paths = .empty,
            .mode = .find_duplicates,
            .result_json = null,
            .user_excludes = .empty,
            .exclude_paths = .empty,
            .use_default_excludes = false,
            .use_credential_excludes = false,
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
        for (self.exclude_paths.items) |p| alloc.free(p);
        self.exclude_paths.deinit(alloc);
        if (self.clean_report) |*r| r.deinit();
        if (self.clean_answer) |j| alloc.free(j);
        if (self.clean_error) |e| alloc.free(e);
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
    const alloc = core_alloc;
    // The core's path form (Windows: `C:\\x` becomes `C:/x`).
    const owned = filters.normalizeOwned(alloc, std.mem.span(path)) catch return -1;
    internal.paths.append(alloc, owned) catch {
        alloc.free(owned);
        return -1;
    };
    return 0;
}

pub export fn zdedupe_set_mode(ctx: ?*ZDedupeContext, mode: c_int) void {
    const c = ctx orelse return;
    const internal: *InternalContext = @ptrCast(@alignCast(c));
    // An unknown mode leaves the mode as it was rather than become one.
    internal.mode = std.enums.fromInt(InternalContext.Mode, mode) orelse return;
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
    // Windows: links and junctions are never followed (see sys_windows.zig);
    // their targets still count toward a folder's identity.
    internal.config.follow_symlinks = follow and builtin.os.tag != .windows;
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

pub export fn zdedupe_set_skip_app_libraries(ctx: ?*ZDedupeContext, skip: bool) void {
    const c = ctx orelse return;
    const internal: *InternalContext = @ptrCast(@alignCast(c));
    internal.config.skip_app_libraries = skip;
}

pub export fn zdedupe_set_one_filesystem(ctx: ?*ZDedupeContext, one: bool) void {
    const c = ctx orelse return;
    const internal: *InternalContext = @ptrCast(@alignCast(c));
    internal.config.one_filesystem = one;
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

pub export fn zdedupe_use_credential_excludes(ctx: ?*ZDedupeContext, use: bool) void {
    const c = ctx orelse return;
    const internal: *InternalContext = @ptrCast(@alignCast(c));
    internal.use_credential_excludes = use;
}

/// The names zdedupe_use_credential_excludes skips, as a JSON array of
/// strings, so a host can show the user what is left alone without keeping
/// a copy of the list. Static; never freed.
pub export fn zdedupe_credential_excludes_json() [*:0]const u8 {
    return credential_excludes_json;
}

const credential_excludes_json: [:0]const u8 = blk: {
    var out: []const u8 = "[";
    for (types.Config.credential_excludes, 0..) |name, i| {
        out = out ++ (if (i == 0) "\"" else ",\"") ++ name ++ "\"";
    }
    break :blk out ++ "]";
};

pub export fn zdedupe_add_exclude(ctx: ?*ZDedupeContext, name: [*:0]const u8) c_int {
    const c = ctx orelse return -1;
    const internal: *InternalContext = @ptrCast(@alignCast(c));
    const alloc = core_alloc;

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

pub export fn zdedupe_add_exclude_path(ctx: ?*ZDedupeContext, path: [*:0]const u8) c_int {
    const c = ctx orelse return -1;
    const internal: *InternalContext = @ptrCast(@alignCast(c));
    const alloc = core_alloc;

    // Matched against the walk's absolute paths, which carry no trailing
    // slash; a relative path could never match.
    const owned = filters.normalizeOwned(alloc, std.mem.span(path)) catch return -1;
    if (!filters.isAbsolute(owned) or filters.isRoot(owned)) {
        alloc.free(owned);
        return -1;
    }
    internal.exclude_paths.append(alloc, owned) catch {
        alloc.free(owned);
        return -1;
    };
    return 0;
}

// === Progress & cancellation ===
//
// The only entry points that may be called from another thread while a
// run is in progress: they touch nothing but atomics inside the context.

/// Mirrors `zdedupe_progress` in the C header.
pub const ZDedupeProgress = extern struct {
    /// `Monitor.Phase` numbering.
    phase: u32,
    _pad: u32 = 0,
    files_found: u64,
    done: u64,
    total: u64,
    bytes_done: u64,
    bytes_total: u64,
    stalled_ms: u64,
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
        .bytes_done = internal.monitor.bytes_done.load(.acquire),
        .bytes_total = internal.monitor.bytes_total.load(.acquire),
        .stalled_ms = internal.monitor.stalledNs() / std.time.ns_per_ms,
    };
}

/// Same threading contract as zdedupe_get_progress. Returns bytes written.
pub export fn zdedupe_get_current_path(
    ctx: ?*const ZDedupeContext,
    buf: ?[*]u8,
    cap: usize,
    truncated: ?*bool,
) usize {
    if (truncated) |t| t.* = false;
    const c = ctx orelse return 0;
    const out = buf orelse return 0;
    const internal: *const InternalContext = @ptrCast(@alignCast(c));
    const snap = internal.monitor.longestRunning(out[0..cap]);
    if (truncated) |t| t.* = snap.truncated;
    return snap.written;
}

pub export fn zdedupe_cancel(ctx: ?*ZDedupeContext) void {
    const c = ctx orelse return;
    const internal: *InternalContext = @ptrCast(@alignCast(c));
    internal.monitor.cancel();
}

// === Build output (zdedupe clean) ===

/// A zdedupe_clean_scan query.
const CleanQuery = struct {
    roots: []const []const u8 = &.{},
    main_roots: []const []const u8 = &.{},
    older_s: i64 = clean.default_older_s,
    threads: u32 = 0,
};

/// A zdedupe_clean_trash request.
const CleanTrashItems = struct {
    paths: []const []const u8 = &.{},
};

/// The process's environment, so the git the report asks finds its PATH.
fn hostEnviron() std.process.Environ {
    if (comptime builtin.os.tag == .windows) return .{ .block = .global };
    return .{ .block = .{ .slice = std.mem.span(std.c.environ) } };
}

fn cleanFail(internal: *InternalContext, comptime fmt: []const u8, args: anytype) ?[*:0]const u8 {
    const alloc = InternalContext.alloc;
    if (internal.clean_error) |e| alloc.free(e);
    internal.clean_error = std.fmt.allocPrintSentinel(alloc, fmt, args, 0) catch null;
    return null;
}

fn cleanAnswer(internal: *InternalContext, json: *std.Io.Writer.Allocating) ?[*:0]const u8 {
    const alloc = InternalContext.alloc;
    if (internal.clean_answer) |j| alloc.free(j);
    internal.clean_answer = null;
    const text = json.toOwnedSliceSentinel(0) catch return cleanFail(internal, "out of memory", .{});
    internal.clean_answer = text;
    return text.ptr;
}

pub export fn zdedupe_clean_scan(ctx: ?*ZDedupeContext, query_json: ?[*:0]const u8) ?[*:0]const u8 {
    const c = ctx orelse return null;
    const internal: *InternalContext = @ptrCast(@alignCast(c));
    const alloc = InternalContext.alloc;
    const text = query_json orelse return cleanFail(internal, "no query was given", .{});

    var parsed = std.json.parseFromSlice(CleanQuery, alloc, std.mem.span(text), .{ .ignore_unknown_fields = true }) catch
        return cleanFail(internal, "build output query is not valid JSON", .{});
    defer parsed.deinit();
    const query = parsed.value;
    if (query.roots.len == 0) return cleanFail(internal, "no folders were given to look in", .{});

    // The core's path form (Windows: `C:\\x` becomes `C:/x`).
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const roots = arena.alloc([]const u8, query.roots.len) catch return cleanFail(internal, "out of memory", .{});
    for (query.roots, roots) |given, *slot| slot.* = filters.normalizeOwned(arena, given) catch return cleanFail(internal, "out of memory", .{});
    const main_roots = arena.alloc([]const u8, query.main_roots.len) catch return cleanFail(internal, "out of memory", .{});
    for (query.main_roots, main_roots) |given, *slot| slot.* = filters.normalizeOwned(arena, given) catch return cleanFail(internal, "out of memory", .{});

    const monitor = &internal.monitor;
    const cancel_was_requested = monitor.cancelled();
    monitor.reset();
    if (cancel_was_requested) monitor.cancel();
    defer monitor.cancel_requested.store(false, .release);
    monitor.enter(.scanning, 0);

    var threaded: std.Io.Threaded = .init(alloc, .{ .environ = hostEnviron() });
    defer threaded.deinit();

    if (internal.clean_report) |*old| old.deinit();
    internal.clean_report = null;
    var found = clean.scan(alloc, threaded.io(), .{
        .roots = roots,
        .main_roots = main_roots,
        .older_s = @max(query.older_s, clean.min_older_s),
        .threads = query.threads,
        .monitor = monitor,
    }) catch |err| {
        releaseFreedMemory();
        return switch (err) {
            error.Cancelled => cleanFail(internal, "the scan was cancelled", .{}),
            else => cleanFail(internal, "the scan failed: {s}", .{@errorName(err)}),
        };
    };

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    clean.writeJson(alloc, &found, &out.writer) catch {
        found.deinit();
        return cleanFail(internal, "out of memory", .{});
    };
    internal.clean_report = found;
    monitor.enter(.done, 0);
    return cleanAnswer(internal, &out);
}

pub export fn zdedupe_clean_trash(
    ctx: ?*ZDedupeContext,
    items_json: ?[*:0]const u8,
    trash_fn: ?ZDedupeTrashFn,
    user: ?*anyopaque,
) ?[*:0]const u8 {
    const host: ?clean.HostTrash = if (trash_fn) |call| .{ .call = call, .user = user } else null;
    return cleanMove(ctx, items_json, host, false);
}

/// `zdedupe_clean_trash`, deleting each folder for good instead.
pub export fn zdedupe_clean_delete(ctx: ?*ZDedupeContext, items_json: ?[*:0]const u8) ?[*:0]const u8 {
    return cleanMove(ctx, items_json, null, true);
}

/// The build folders of the last clean scan named in `items_json`, each
/// checked again, moved to the Trash or deleted for good.
fn cleanMove(ctx: ?*ZDedupeContext, items_json: ?[*:0]const u8, host: ?clean.HostTrash, permanently: bool) ?[*:0]const u8 {
    const c = ctx orelse return null;
    const internal: *InternalContext = @ptrCast(@alignCast(c));
    const alloc = InternalContext.alloc;
    const what = if (permanently) "delete" else "move";
    const text = items_json orelse return cleanFail(internal, "no folders were given to {s}", .{what});
    const last = if (internal.clean_report) |*r| r else return cleanFail(internal, "there is no build output scan to {s} from", .{what});

    var parsed = std.json.parseFromSlice(CleanTrashItems, alloc, std.mem.span(text), .{ .ignore_unknown_fields = true }) catch
        return cleanFail(internal, "folder list is not valid JSON", .{});
    defer parsed.deinit();

    const monitor = &internal.monitor;
    const cancel_was_requested = monitor.cancelled();
    monitor.reset();
    if (cancel_was_requested) monitor.cancel();
    defer monitor.cancel_requested.store(false, .release);

    clean.trashSelected(alloc, last, parsed.value.paths, .{
        .roots = &.{},
        .older_s = last.older_s,
        .host_trash = host,
        .permanently = permanently,
        .monitor = monitor,
    }) catch return cleanFail(internal, "out of memory", .{});

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    var json: std.json.Stringify = .{ .writer = &out.writer };
    clean.writeTrashRun(&json, arena_state.allocator(), last.trash.?) catch return cleanFail(internal, "out of memory", .{});
    monitor.enter(.done, 0);
    return cleanAnswer(internal, &out);
}

pub export fn zdedupe_clean_error(ctx: ?*const ZDedupeContext) ?[*:0]const u8 {
    const c = ctx orelse return null;
    const internal: *const InternalContext = @ptrCast(@alignCast(c));
    return if (internal.clean_error) |e| e.ptr else null;
}

// === Execution ===

/// Run a duplicate scan and write the binary result store (see store.zig) to
/// `path`. Returns a `RunStatus`.
pub export fn zdedupe_run_to_file(ctx: ?*ZDedupeContext, path: ?[*:0]const u8) c_int {
    const c = ctx orelse return @intFromEnum(RunStatus.failed);
    const path_z = path orelse return @intFromEnum(RunStatus.failed);
    const internal: *InternalContext = @ptrCast(@alignCast(c));
    if (internal.mode == .disk_space) {
        const space_status = runSpaceScan(internal, std.mem.span(path_z));
        releaseFreedMemory();
        return @intFromEnum(space_status);
    }
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
    const alloc = core_alloc;

    // Clear previous result
    if (internal.result_json) |j| {
        alloc.free(j);
        internal.result_json = null;
    }

    const json_result: ?[]u8 = switch (internal.mode) {
        .find_duplicates => runDuplicates(internal),
        .compare_folders => runCompare(internal),
        // Only as a result store: a whole disk's tree is not a JSON document.
        .disk_space => null,
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
    const alloc = core_alloc;
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
    if (internal.use_credential_excludes) {
        excludes.appendSlice(alloc, &Config.credential_excludes) catch return .failed;
    }
    excludes.appendSlice(alloc, internal.user_excludes.items) catch return .failed;

    var config = internal.config;
    config.excludes = excludes.items;
    config.exclude_paths = internal.exclude_paths.items;
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

/// A disk-space scan: walk, aggregate, write the store. The walk keeps the
/// duplicate scan's scoping (same volume, app library packages skipped,
/// credential stores and the host's own excludes never entered, hidden files as
/// configured) but enters game libraries, which only a duplicate scan has to
/// keep out of, and ignores the default excludes: those are build output and
/// dependency folders, noise to a duplicate finder and exactly what a
/// disk-space view has to show.
fn runSpaceScan(internal: *InternalContext, out_path: []const u8) RunStatus {
    const alloc = core_alloc;
    const monitor = &internal.monitor;

    const cancel_was_requested = monitor.cancelled();
    monitor.reset();
    if (cancel_was_requested) monitor.cancel();
    defer monitor.cancel_requested.store(false, .release);

    var excludes: std.ArrayListUnmanaged([]const u8) = .empty;
    defer excludes.deinit(alloc);
    if (internal.use_credential_excludes) {
        excludes.appendSlice(alloc, &Config.credential_excludes) catch return .failed;
    }
    excludes.appendSlice(alloc, internal.user_excludes.items) catch return .failed;

    monitor.enter(.scanning, 0);
    space.scanToStore(alloc, .{
        .include_hidden = internal.config.include_hidden,
        .excludes = excludes.items,
        .exclude_paths = internal.exclude_paths.items,
        .one_filesystem = internal.config.one_filesystem,
        .skip_app_libraries = internal.config.skip_app_libraries,
        .threads = internal.config.threads,
        .monitor = monitor,
    }, internal.paths.items, out_path) catch |err| return switch (err) {
        error.Cancelled => .cancelled,
        else => .failed,
    };
    monitor.enter(.done, 0);
    return .ok;
}

fn runDuplicates(internal: *InternalContext) ?[]u8 {
    var json: ?[]u8 = null;
    const status = runDuplicateScan(internal, &json, struct {
        fn emit(out: *?[]u8, _: *InternalContext, finder: *DupeFinder) RunStatus {
            const alloc = core_alloc;
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
    const alloc = core_alloc;

    if (internal.paths.items.len < 2) return null;
    const monitor = &internal.monitor;

    // Progress restarts; a cancel requested before the run began still counts.
    const cancel_was_requested = monitor.cancelled();
    monitor.reset();
    if (cancel_was_requested) monitor.cancel();
    // Whatever happens, the next run on this context starts un-cancelled.
    defer monitor.cancel_requested.store(false, .release);

    // The monitor carries progress (files compared, bytes read) and Cancel.
    var config = internal.config;
    config.monitor = monitor;
    var cmp = FolderComparator.init(alloc, config);
    var result = cmp.compare(internal.paths.items[0], internal.paths.items[1]) catch return null;
    defer result.deinit();
    monitor.enter(.done, 0);

    // Generate JSON report using Allocating writer
    var alloc_writer: std.Io.Writer.Allocating = .init(alloc);
    errdefer alloc_writer.deinit();

    const reporter = ReportWriter.init(alloc, .{ .format = .json });
    reporter.writeCompareReport(&alloc_writer.writer, &result) catch return null;

    return alloc_writer.toOwnedSlice() catch null;
}

// =============================================================================
// === Results session ===
// =============================================================================
//
// Everything that happens after a scan: paging, the bulk rule, verified
// deletion, the removed overlay and export. See session.zig for the design and
// include/zdedupe.h for the contract. Queries in and answers out are JSON;
// every returned string is owned by the session and valid until the next call
// on it.

pub const ZDedupeResults = opaque {};

/// Mirrors `zdedupe_delete_progress` in the C header.
pub const ZDedupeDeleteProgress = session.DeleteProgress;

/// Mirrors `zdedupe_trash_fn` in the C header.
pub const ZDedupeTrashFn = session.TrashFn;

fn asSession(r: ?*ZDedupeResults) ?*session.Session {
    const handle = r orelse return null;
    return @ptrCast(@alignCast(handle));
}

fn asSessionConst(r: ?*const ZDedupeResults) ?*const session.Session {
    const handle = r orelse return null;
    return @ptrCast(@alignCast(handle));
}

pub export fn zdedupe_results_open(store_path: ?[*:0]const u8, roots_json: ?[*:0]const u8) ?*ZDedupeResults {
    const path = store_path orelse return null;
    const roots: ?[]const u8 = if (roots_json) |j| std.mem.span(j) else null;
    const opened = session.Session.open(core_alloc, std.mem.span(path), roots) catch return null;
    return @ptrCast(opened);
}

pub export fn zdedupe_results_close(r: ?*ZDedupeResults) void {
    if (asSession(r)) |s| s.close();
}

pub export fn zdedupe_results_last_error(r: ?*const ZDedupeResults) ?[*:0]const u8 {
    const s = asSessionConst(r) orelse return null;
    const message = s.lastError() orelse return null;
    return message.ptr;
}

pub export fn zdedupe_results_overview(r: ?*ZDedupeResults) ?[*:0]const u8 {
    const s = asSession(r) orelse return null;
    return (s.overview() orelse return null).ptr;
}

pub export fn zdedupe_results_groups(r: ?*ZDedupeResults, query_json: ?[*:0]const u8) ?[*:0]const u8 {
    const s = asSession(r) orelse return null;
    const query = query_json orelse return null;
    return (s.groups(std.mem.span(query)) orelse return null).ptr;
}

pub export fn zdedupe_results_bulk_summary(r: ?*ZDedupeResults, filters_json: ?[*:0]const u8) ?[*:0]const u8 {
    const s = asSession(r) orelse return null;
    const query = filters_json orelse return null;
    return (s.bulkSummary(std.mem.span(query)) orelse return null).ptr;
}

pub export fn zdedupe_results_bulk_plan(r: ?*ZDedupeResults, query_json: ?[*:0]const u8) ?[*:0]const u8 {
    const s = asSession(r) orelse return null;
    const query = query_json orelse return null;
    return (s.bulkPlan(std.mem.span(query)) orelse return null).ptr;
}

pub export fn zdedupe_results_set_protected(r: ?*ZDedupeResults, paths_json: ?[*:0]const u8) c_int {
    const s = asSession(r) orelse return -1;
    const paths = paths_json orelse return -1;
    return if (s.setProtected(std.mem.span(paths))) 0 else -1;
}

pub export fn zdedupe_results_set_home(r: ?*ZDedupeResults, path: ?[*:0]const u8) c_int {
    const s = asSession(r) orelse return -1;
    const home = path orelse return -1;
    return if (s.setHome(std.mem.span(home))) 0 else -1;
}

pub export fn zdedupe_results_protected(r: ?*ZDedupeResults) ?[*:0]const u8 {
    const s = asSession(r) orelse return null;
    return (s.protectedJson() orelse return null).ptr;
}

pub export fn zdedupe_results_delete(
    r: ?*ZDedupeResults,
    selection_json: ?[*:0]const u8,
    use_trash: bool,
    trash_fn: ?ZDedupeTrashFn,
    user: ?*anyopaque,
) ?[*:0]const u8 {
    const s = asSession(r) orelse return null;
    const selection = selection_json orelse return null;
    return (s.delete(std.mem.span(selection), use_trash, trash_fn, user) orelse return null).ptr;
}

pub export fn zdedupe_results_delete_progress(r: ?*const ZDedupeResults, out: ?*ZDedupeDeleteProgress) void {
    const s = asSessionConst(r) orelse return;
    const result = out orelse return;
    result.* = s.deleteProgress();
}

pub export fn zdedupe_results_cancel_delete(r: ?*ZDedupeResults) void {
    if (asSession(r)) |s| s.cancelDelete();
}

pub export fn zdedupe_results_removed_status(r: ?*ZDedupeResults) ?[*:0]const u8 {
    const s = asSession(r) orelse return null;
    return (s.removedStatus() orelse return null).ptr;
}

// === Folders ===

pub export fn zdedupe_results_identical_sets(r: ?*ZDedupeResults, query_json: ?[*:0]const u8) ?[*:0]const u8 {
    const s = asSession(r) orelse return null;
    const query = query_json orelse return null;
    return (s.identicalSets(std.mem.span(query)) orelse return null).ptr;
}

pub export fn zdedupe_results_set_members(r: ?*ZDedupeResults, index: usize) ?[*:0]const u8 {
    const s = asSession(r) orelse return null;
    return (s.setMembers(index) orelse return null).ptr;
}

pub export fn zdedupe_results_overlaps(r: ?*ZDedupeResults, query_json: ?[*:0]const u8) ?[*:0]const u8 {
    const s = asSession(r) orelse return null;
    const query = query_json orelse return null;
    return (s.overlaps(std.mem.span(query)) orelse return null).ptr;
}

pub export fn zdedupe_results_facets(r: ?*ZDedupeResults, query_json: ?[*:0]const u8) ?[*:0]const u8 {
    const s = asSession(r) orelse return null;
    const query = query_json orelse return null;
    return (s.facets(std.mem.span(query)) orelse return null).ptr;
}

pub export fn zdedupe_results_delete_folders(
    r: ?*ZDedupeResults,
    items_json: ?[*:0]const u8,
    use_trash: bool,
    trash_fn: ?ZDedupeTrashFn,
    user: ?*anyopaque,
) ?[*:0]const u8 {
    const s = asSession(r) orelse return null;
    const items = items_json orelse return null;
    return (s.deleteFolders(std.mem.span(items), use_trash, trash_fn, user) orelse return null).ptr;
}

// === Disk space ===

pub export fn zdedupe_results_space_overview(r: ?*ZDedupeResults) ?[*:0]const u8 {
    const s = asSession(r) orelse return null;
    return (s.spaceOverview() orelse return null).ptr;
}

pub export fn zdedupe_results_space_children(r: ?*ZDedupeResults, query_json: ?[*:0]const u8) ?[*:0]const u8 {
    const s = asSession(r) orelse return null;
    const query = query_json orelse return null;
    return (s.spaceChildren(std.mem.span(query)) orelse return null).ptr;
}

pub export fn zdedupe_results_space_largest(r: ?*ZDedupeResults, query_json: ?[*:0]const u8) ?[*:0]const u8 {
    const s = asSession(r) orelse return null;
    const query = query_json orelse return null;
    return (s.spaceLargest(std.mem.span(query)) orelse return null).ptr;
}

pub export fn zdedupe_results_space_skipped(r: ?*ZDedupeResults, query_json: ?[*:0]const u8) ?[*:0]const u8 {
    const s = asSession(r) orelse return null;
    const query = query_json orelse return null;
    return (s.spaceSkipped(std.mem.span(query)) orelse return null).ptr;
}

pub export fn zdedupe_results_space_suggest(r: ?*ZDedupeResults, query_json: ?[*:0]const u8) ?[*:0]const u8 {
    const s = asSession(r) orelse return null;
    const query = query_json orelse return null;
    return (s.spaceSuggest(std.mem.span(query)) orelse return null).ptr;
}

pub export fn zdedupe_results_space_report(r: ?*ZDedupeResults, query_json: ?[*:0]const u8) ?[*:0]const u8 {
    const s = asSession(r) orelse return null;
    const query = query_json orelse return null;
    return (s.spaceReport(std.mem.span(query)) orelse return null).ptr;
}

pub export fn zdedupe_results_space_history(r: ?*ZDedupeResults, history_dir: ?[*:0]const u8) ?[*:0]const u8 {
    const s = asSession(r) orelse return null;
    const dir = history_dir orelse return null;
    return (s.spaceHistory(std.mem.span(dir)) orelse return null).ptr;
}

pub export fn zdedupe_results_space_trash(
    r: ?*ZDedupeResults,
    items_json: ?[*:0]const u8,
    trash_fn: ?ZDedupeTrashFn,
    user: ?*anyopaque,
) ?[*:0]const u8 {
    const s = asSession(r) orelse return null;
    const items = items_json orelse return null;
    return (s.spaceTrash(std.mem.span(items), trash_fn, user) orelse return null).ptr;
}

pub export fn zdedupe_results_export(
    r: ?*ZDedupeResults,
    format: ?[*:0]const u8,
    path: ?[*:0]const u8,
) c_int {
    const s = asSession(r) orelse return -1;
    const format_z = format orelse return -1;
    const path_z = path orelse return -1;
    return if (s.exportTo(std.mem.span(format_z), std.mem.span(path_z))) 0 else -1;
}

pub export fn zdedupe_results_report(r: ?*ZDedupeResults, query_json: ?[*:0]const u8) ?[*:0]const u8 {
    const s = asSession(r) orelse return null;
    const query = query_json orelse return null;
    return (s.duplicatesReport(std.mem.span(query)) orelse return null).ptr;
}

// === Utilities ===

// File operations, through the platform's C library (sys.zig on Windows).
const unlink = @import("sys.zig").c.unlink;
const rename = @import("sys.zig").c.rename;

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

test "credential excludes are published as the list the engine applies" {
    const json = std.mem.span(zdedupe_credential_excludes_json());
    const parsed = try std.json.parseFromSlice([]const []const u8, std.testing.allocator, json, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(types.Config.credential_excludes.len, parsed.value.len);
    for (types.Config.credential_excludes, parsed.value) |want, got| try std.testing.expectEqualStrings(want, got);
}

test "build output through the C API: a scan, a move it refuses for a fresh folder, and errors that say why" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;
    const testing = std.testing;
    const Scratch = @import("testing_scratch.zig").Scratch;
    var scratch = try Scratch.init(testing.allocator, "lib-clean");
    defer scratch.deinit();
    try scratch.makeDir("app");
    try scratch.writeFile("app/package.json", "{\"name\":\"app\"}");
    try scratch.makeDir("app/node_modules");
    try scratch.writeFile("app/node_modules/x.js", "module.exports = 1;\n");

    const ctx = zdedupe_init() orelse return error.InitFailed;
    defer zdedupe_free(ctx);

    // Nothing to move from yet.
    try testing.expect(zdedupe_clean_trash(ctx, "{\"paths\":[]}", null, null) == null);
    try testing.expectEqualStrings("there is no build output scan to move from", std.mem.span(zdedupe_clean_error(ctx).?));
    try testing.expect(zdedupe_clean_delete(ctx, "{\"paths\":[]}") == null);
    try testing.expectEqualStrings("there is no build output scan to delete from", std.mem.span(zdedupe_clean_error(ctx).?));
    try testing.expect(zdedupe_clean_scan(ctx, "{") == null);
    try testing.expectEqualStrings("build output query is not valid JSON", std.mem.span(zdedupe_clean_error(ctx).?));
    try testing.expect(zdedupe_clean_scan(ctx, "{\"roots\":[]}") == null);

    const query = try std.fmt.allocPrintSentinel(testing.allocator, "{{\"roots\":[\"{s}\"],\"main_roots\":[\"{s}/none\"]}}", .{ scratch.path, scratch.path }, 0);
    defer testing.allocator.free(query);
    const answer = std.mem.span(zdedupe_clean_scan(ctx, query.ptr) orelse return error.ScanFailed);
    const doc = try std.json.parseFromSlice(std.json.Value, testing.allocator, answer, .{});
    defer doc.deinit();
    try testing.expectEqualStrings("zdedupe-clean/1", doc.value.object.get("schema").?.string);
    const dirs_found = doc.value.object.get("build_dirs").?.array.items;
    try testing.expectEqual(@as(usize, 1), dirs_found.len);
    const nm = dirs_found[0].object.get("path").?.string;
    try testing.expect(std.mem.endsWith(u8, nm, "/app/node_modules"));

    // Just written, so it stays; the answer says why.
    const items = try std.fmt.allocPrintSentinel(testing.allocator, "{{\"paths\":[\"{s}\"]}}", .{nm}, 0);
    defer testing.allocator.free(items);
    const moved = std.mem.span(zdedupe_clean_trash(ctx, items.ptr, null, null) orelse return error.TrashFailed);
    const run = try std.json.parseFromSlice(std.json.Value, testing.allocator, moved, .{});
    defer run.deinit();
    try testing.expectEqual(@as(usize, 0), run.value.object.get("moved").?.array.items.len);
    const skipped = run.value.object.get("skipped").?.array.items;
    try testing.expectEqual(@as(usize, 1), skipped.len);
    try testing.expect(std.mem.indexOf(u8, skipped[0].object.get("reason").?.string, "changed too recently") != null);
    try testing.expect(try scratch.exists("app/node_modules/x.js"));

    // A permanent delete checks the same way, and the folder stays.
    const deleted = std.mem.span(zdedupe_clean_delete(ctx, items.ptr) orelse return error.DeleteFailed);
    const gone = try std.json.parseFromSlice(std.json.Value, testing.allocator, deleted, .{});
    defer gone.deinit();
    try testing.expectEqual(@as(usize, 0), gone.value.object.get("moved").?.array.items.len);
    try testing.expect(std.mem.indexOf(u8, gone.value.object.get("skipped").?.array.items[0].object.get("reason").?.string, "changed too recently") != null);
    try testing.expect(try scratch.exists("app/node_modules/x.js"));
}
