// blame — line-level attribution against the commit graph.
//
// See docs/BLAME_SPEC.md for the design. The short version:
//
//   * Start from the target file's blob at the target ref. Split into
//     lines. The initial work item is one region covering every line
//     (or the -L range), in the target ref's frame.
//
//   * Walk commits newest-first via a priority queue keyed on
//     author_time. For each commit:
//       — root commit: attribute remaining regions to it and stop.
//       — single parent: tree-OID short-circuit if the file is
//         unchanged; otherwise Myers-diff parent vs child and split
//         each region into (carry-to-parent, attribute-to-child).
//       — merge commit: try each parent in turn. Lines matching some
//         parent's blob route to that parent; lines matching NO parent
//         (conflict-resolution content) attribute to the merge commit.
//
//   * Build BlameLine entries from the resolved attributions + the
//     target blob's lines.
//
// Everything (commit cache, tree-path cache, blob cache, author cache,
// region storage, output buffers) lives in one arena per call. Free
// via BlameResult.deinit().

const std = @import("std");
const Oid = @import("../object/oid.zig").Oid;
const Kind = @import("../object/kind.zig").Kind;
const LooseStore = @import("../object/loose_store.zig").LooseStore;
const commit_mod = @import("../object/commit.zig");
const tree_mod = @import("../object/tree.zig");
const myers = @import("../diff/myers.zig");
const region_mod = @import("region.zig");
const Region = region_mod.Region;

pub const BlameError = error{
    PathNotFoundAtRef,
    PathIsNotFile,
    RefNotFound,
    UnreadableBlob,
    MalformedCommit,
    MalformedAuthor,
    OutOfMemory,
};

pub const BlameOptions = struct {
    pub const LineRange = struct { start: u32, end: u32 };
    /// 1-based, inclusive. null = whole file.
    line_range: ?LineRange = null,
    /// Cap on commits walked. null = no cap.
    max_commits: ?u32 = null,
};

pub const BlameLine = struct {
    /// 1-based line in the target file.
    line_no: u32,
    /// Commit that last touched this line.
    commit_oid: Oid,
    author_name: []const u8,
    author_email: []const u8,
    /// Seconds since epoch.
    author_time: i64,
    author_tz_offset_minutes: i16,
    /// Line bytes as they appear in the target blob, INCLUDING the
    /// trailing '\n' if present. Borrows from the arena.
    content: []const u8,
};

pub const BlameMetrics = struct {
    total_ms: u64 = 0,
    commits_examined: u32 = 0,
    /// File unchanged between commit and parent (single-parent or
    /// merge step).
    short_circuit_hits: u32 = 0,
    /// Number of Myers diff calls made.
    diffs_run: u32 = 0,
    /// max_commits cap hit before everything attributed.
    partial: bool = false,
};

pub const BlameResult = struct {
    lines: []BlameLine,
    metrics: BlameMetrics,
    arena: *std.heap.ArenaAllocator,

    pub fn deinit(self: *BlameResult) void {
        const parent = self.arena.child_allocator;
        self.arena.deinit();
        parent.destroy(self.arena);
        self.* = undefined;
    }
};

// ── Internals ───────────────────────────────────────────────────────

const Author = struct {
    name: []const u8,
    email: []const u8,
    unix_time: i64,
    tz_offset_minutes: i16,
};

const ParsedCommit = struct {
    parent_oids: []const Oid,
    tree_oid: Oid,
    author: Author,
};

const WorkItem = struct {
    commit_oid: Oid,
    author_time: i64,
    regions: []Region,
};

fn workItemCompare(_: void, a: WorkItem, b: WorkItem) std.math.Order {
    // Newest commit first → return .lt when a is more recent than b.
    if (a.author_time > b.author_time) return .lt;
    if (a.author_time < b.author_time) return .gt;
    return std.mem.order(u8, &a.commit_oid.bytes, &b.commit_oid.bytes);
}

const WorkQueue = std.PriorityQueue(WorkItem, void, workItemCompare);

const Ctx = struct {
    arena: std.mem.Allocator,
    /// Used only for transient reads — output strings get duped into
    /// `arena`.
    transient: std.mem.Allocator,
    store: *LooseStore,
    path: []const u8,

    commits: std.AutoHashMapUnmanaged([20]u8, ParsedCommit),
    /// tree_oid → ?blob_oid at `path` under that tree.
    path_blob_at_tree: std.AutoHashMapUnmanaged([20]u8, ?Oid),
    /// blob_oid → blob bytes (owned by arena).
    blobs: std.AutoHashMapUnmanaged([20]u8, []const u8),
    /// blob_oid → lines (slices into the cached blob bytes).
    blob_lines: std.AutoHashMapUnmanaged([20]u8, []const []const u8),

    metrics: *BlameMetrics,
};

/// Parse a commit-object author line of the form
///   "<name> <<email>> <unix_ts> [+-]HHMM"
/// All slices borrow from `line`.
fn parseAuthorLine(line: []const u8) !Author {
    // Find the email delimiters from the right so names with '<' don't
    // trip us up.
    const email_end = std.mem.lastIndexOfScalar(u8, line, '>') orelse return error.MalformedAuthor;
    const email_start = std.mem.lastIndexOfScalar(u8, line[0..email_end], '<') orelse return error.MalformedAuthor;
    if (email_start == 0) return error.MalformedAuthor;
    // Name ends one before " <".
    var name_end = email_start;
    while (name_end > 0 and line[name_end - 1] == ' ') name_end -= 1;
    const name = line[0..name_end];
    const email = line[email_start + 1 .. email_end];

    // Time + tz follow the closing '>'.
    var rest = line[email_end + 1 ..];
    while (rest.len > 0 and rest[0] == ' ') rest = rest[1..];
    const space = std.mem.indexOfScalar(u8, rest, ' ') orelse return error.MalformedAuthor;
    const time_str = rest[0..space];
    const tz_str = rest[space + 1 ..];

    const unix_time = std.fmt.parseInt(i64, time_str, 10) catch return error.MalformedAuthor;

    // tz: '+HHMM' / '-HHMM'.
    if (tz_str.len != 5) return error.MalformedAuthor;
    const sign: i16 = switch (tz_str[0]) {
        '+' => 1,
        '-' => -1,
        else => return error.MalformedAuthor,
    };
    const hh = std.fmt.parseInt(i16, tz_str[1..3], 10) catch return error.MalformedAuthor;
    const mm = std.fmt.parseInt(i16, tz_str[3..5], 10) catch return error.MalformedAuthor;
    const offset = sign * (hh * 60 + mm);

    return .{
        .name = name,
        .email = email,
        .unix_time = unix_time,
        .tz_offset_minutes = offset,
    };
}

fn loadCommit(ctx: *Ctx, oid: Oid) !*const ParsedCommit {
    if (ctx.commits.getPtr(oid.bytes)) |p| return p;

    var loaded = ctx.store.read(ctx.transient, oid) catch return error.MalformedCommit;
    defer loaded.deinit(ctx.transient);
    if (loaded.kind != .commit) return error.MalformedCommit;

    var parsed = commit_mod.parse(ctx.transient, loaded.payload) catch return error.MalformedCommit;
    defer parsed.deinit(ctx.transient);

    const author = try parseAuthorLine(parsed.author_line);

    // Move everything into the arena.
    const parents_arena = try ctx.arena.alloc(Oid, parsed.parent_oids.len);
    @memcpy(parents_arena, parsed.parent_oids);
    const name_arena = try ctx.arena.dupe(u8, author.name);
    const email_arena = try ctx.arena.dupe(u8, author.email);

    const entry = ParsedCommit{
        .parent_oids = parents_arena,
        .tree_oid = parsed.tree_oid,
        .author = .{
            .name = name_arena,
            .email = email_arena,
            .unix_time = author.unix_time,
            .tz_offset_minutes = author.tz_offset_minutes,
        },
    };
    try ctx.commits.put(ctx.arena, oid.bytes, entry);
    return ctx.commits.getPtr(oid.bytes).?;
}

/// Resolve `path` under `tree_oid`. Result is cached by tree_oid so
/// commits with identical trees only pay the walk once.
///
/// Returns:
///   * Ok(non-null) — blob oid for the path.
///   * Ok(null)     — path doesn't exist in this tree.
///   * Err(.PathIsNotFile) — leaf is a directory, symlink, or submodule.
fn lookupPathInTree(ctx: *Ctx, tree_oid: Oid) BlameError!?Oid {
    if (ctx.path_blob_at_tree.get(tree_oid.bytes)) |cached| return cached;

    var current_tree = tree_oid;
    var remaining: []const u8 = ctx.path;

    var result: ?Oid = null;

    while (true) {
        const slash = std.mem.indexOfScalar(u8, remaining, '/');
        const segment = if (slash) |s| remaining[0..s] else remaining;
        const is_leaf = slash == null;

        var loaded = ctx.store.read(ctx.transient, current_tree) catch return error.UnreadableBlob;
        defer loaded.deinit(ctx.transient);
        if (loaded.kind != .tree) return error.UnreadableBlob;

        var it: tree_mod.Iterator = .{ .bytes = loaded.payload };
        var found: ?tree_mod.Entry = null;
        while (it.next() catch return error.UnreadableBlob) |entry| {
            if (std.mem.eql(u8, entry.name, segment)) {
                found = entry;
                break;
            }
        }

        const entry = found orelse {
            result = null;
            break;
        };

        if (is_leaf) {
            switch (entry.mode) {
                tree_mod.blob_mode_regular, tree_mod.blob_mode_executable => result = entry.oid,
                else => return error.PathIsNotFile,
            }
            break;
        }

        // Mid-path: must be a tree.
        if (!entry.isTree()) {
            result = null;
            break;
        }
        current_tree = entry.oid;
        remaining = remaining[segment.len + 1 ..];
    }

    try ctx.path_blob_at_tree.put(ctx.arena, tree_oid.bytes, result);
    return result;
}

fn loadBlobLines(ctx: *Ctx, blob_oid: Oid) ![]const []const u8 {
    if (ctx.blob_lines.get(blob_oid.bytes)) |cached| return cached;

    const bytes = if (ctx.blobs.get(blob_oid.bytes)) |b| b else blk: {
        var loaded = ctx.store.read(ctx.transient, blob_oid) catch return error.UnreadableBlob;
        defer loaded.deinit(ctx.transient);
        if (loaded.kind != .blob) return error.UnreadableBlob;
        const owned = try ctx.arena.dupe(u8, loaded.payload);
        try ctx.blobs.put(ctx.arena, blob_oid.bytes, owned);
        break :blk owned;
    };

    var lines: std.ArrayListUnmanaged([]const u8) = .empty;
    var start: usize = 0;
    var i: usize = 0;
    while (i < bytes.len) : (i += 1) {
        if (bytes[i] == '\n') {
            try lines.append(ctx.arena, bytes[start .. i + 1]);
            start = i + 1;
        }
    }
    if (start < bytes.len) try lines.append(ctx.arena, bytes[start..]);
    const slice = try lines.toOwnedSlice(ctx.arena);
    try ctx.blob_lines.put(ctx.arena, blob_oid.bytes, slice);
    return slice;
}

fn attributeRegion(attributions: []?Oid, region: Region, commit_oid: Oid) void {
    var i: u32 = region.target_line_start;
    while (i <= region.target_line_end) : (i += 1) {
        if (attributions[i - 1] == null) attributions[i - 1] = commit_oid;
    }
}

fn attributeAll(attributions: []?Oid, regions: []const Region, commit_oid: Oid) void {
    for (regions) |r| attributeRegion(attributions, r, commit_oid);
}

/// Single-parent step.
fn handleSingleParent(
    ctx: *Ctx,
    queue: *WorkQueue,
    attributions: []?Oid,
    commit_oid: Oid,
    parent_oid: Oid,
    blob_in_commit: Oid,
    regions_in: []Region,
) !void {
    const parent_commit = try loadCommit(ctx, parent_oid);
    const blob_in_parent_opt = try lookupPathInTree(ctx, parent_commit.tree_oid);

    if (blob_in_parent_opt == null) {
        // File didn't exist in parent → introduced in this commit.
        attributeAll(attributions, regions_in, commit_oid);
        return;
    }
    const blob_in_parent = blob_in_parent_opt.?;

    if (blob_in_parent.eql(blob_in_commit)) {
        // SHORT-CIRCUIT: file unchanged. Reframe regions to parent.
        ctx.metrics.short_circuit_hits += 1;
        const carried = try ctx.arena.alloc(Region, regions_in.len);
        for (regions_in, 0..) |r, i| carried[i] = .{
            .current_commit = parent_oid,
            .blob_line_start = r.blob_line_start,
            .blob_line_end = r.blob_line_end,
            .target_line_start = r.target_line_start,
            .target_line_end = r.target_line_end,
        };
        try queue.push(ctx.transient, .{
            .commit_oid = parent_oid,
            .author_time = parent_commit.author.unix_time,
            .regions = carried,
        });
        return;
    }

    // Compute the diff and split each region.
    const parent_lines = try loadBlobLines(ctx, blob_in_parent);
    const child_lines = try loadBlobLines(ctx, blob_in_commit);
    const edits = try myers.diff(ctx.transient, parent_lines, child_lines);
    defer ctx.transient.free(edits);
    ctx.metrics.diffs_run += 1;

    var carry_acc: std.ArrayListUnmanaged(Region) = .empty;
    defer carry_acc.deinit(ctx.transient);

    for (regions_in) |r| {
        var split = try region_mod.splitRegionAgainstDiff(ctx.transient, r, edits, parent_oid);
        defer split.deinit(ctx.transient);
        // Residue → attributed to this commit.
        for (split.residue_in_commit) |sub| attributeRegion(attributions, sub, commit_oid);
        // Carried → pushed to parent.
        try carry_acc.appendSlice(ctx.transient, split.carry_to_parent);
    }

    if (carry_acc.items.len == 0) return;
    const n = region_mod.coalesceContiguous(carry_acc.items);
    const final_regions = try ctx.arena.dupe(Region, carry_acc.items[0..n]);
    try queue.push(ctx.transient, .{
        .commit_oid = parent_oid,
        .author_time = parent_commit.author.unix_time,
        .regions = final_regions,
    });
}

/// Multi-parent step. See docs/BLAME_SPEC.md `handleMergeCommit`.
fn handleMergeCommit(
    ctx: *Ctx,
    queue: *WorkQueue,
    attributions: []?Oid,
    commit_oid: Oid,
    parents: []const Oid,
    blob_in_commit: Oid,
    regions_in: []Region,
) !void {
    // Per-parent accumulator: each parent has its own list of regions
    // routed to it.
    const Routed = struct {
        parent_oid: Oid,
        parent_time: i64,
        list: std.ArrayListUnmanaged(Region),
    };
    var routed = try ctx.transient.alloc(Routed, parents.len);
    defer ctx.transient.free(routed);
    for (parents, 0..) |p, i| {
        const pc = try loadCommit(ctx, p);
        routed[i] = .{
            .parent_oid = p,
            .parent_time = pc.author.unix_time,
            .list = .empty,
        };
    }
    defer for (routed) |*r| r.list.deinit(ctx.transient);

    var pending: std.ArrayListUnmanaged(Region) = .empty;
    defer pending.deinit(ctx.transient);
    try pending.appendSlice(ctx.transient, regions_in);

    for (parents, 0..) |parent_oid, pi| {
        if (pending.items.len == 0) break;

        const parent_commit = try loadCommit(ctx, parent_oid);
        const blob_in_parent_opt = try lookupPathInTree(ctx, parent_commit.tree_oid);
        if (blob_in_parent_opt == null) continue; // nothing to match against
        const blob_in_parent = blob_in_parent_opt.?;

        if (blob_in_parent.eql(blob_in_commit)) {
            // SHORT-CIRCUIT: every pending line matches this parent.
            ctx.metrics.short_circuit_hits += 1;
            for (pending.items) |r| {
                try routed[pi].list.append(ctx.transient, .{
                    .current_commit = parent_oid,
                    .blob_line_start = r.blob_line_start,
                    .blob_line_end = r.blob_line_end,
                    .target_line_start = r.target_line_start,
                    .target_line_end = r.target_line_end,
                });
            }
            pending.clearRetainingCapacity();
            break;
        }

        const parent_lines = try loadBlobLines(ctx, blob_in_parent);
        const child_lines = try loadBlobLines(ctx, blob_in_commit);
        const edits = try myers.diff(ctx.transient, parent_lines, child_lines);
        defer ctx.transient.free(edits);
        ctx.metrics.diffs_run += 1;

        var next_pending: std.ArrayListUnmanaged(Region) = .empty;
        defer next_pending.deinit(ctx.transient);

        for (pending.items) |r| {
            var split = try region_mod.splitRegionAgainstDiff(ctx.transient, r, edits, parent_oid);
            defer split.deinit(ctx.transient);
            try routed[pi].list.appendSlice(ctx.transient, split.carry_to_parent);
            try next_pending.appendSlice(ctx.transient, split.residue_in_commit);
        }

        pending.clearRetainingCapacity();
        try pending.appendSlice(ctx.transient, next_pending.items);
    }

    // Whatever's still pending matched no parent → resolution content.
    for (pending.items) |r| attributeRegion(attributions, r, commit_oid);

    // Push collected regions per parent.
    for (routed) |*r| {
        if (r.list.items.len == 0) continue;
        const n = region_mod.coalesceContiguous(r.list.items);
        const final_regions = try ctx.arena.dupe(Region, r.list.items[0..n]);
        try queue.push(ctx.transient, .{
            .commit_oid = r.parent_oid,
            .author_time = r.parent_time,
            .regions = final_regions,
        });
    }
}

// ── Public entry point ──────────────────────────────────────────────

pub fn blameFile(
    parent_allocator: std.mem.Allocator,
    store: *LooseStore,
    ref_oid: Oid,
    path: []const u8,
    opts: BlameOptions,
) BlameError!BlameResult {
    // `total_ms` is left at 0 in this entry point — wall-clock timing
    // requires an Io handle to read the awake clock, which we'd thread
    // in via a sibling `blameFileTimed(allocator, io, ...)`. For now,
    // counter-based metrics (commits_examined, short_circuit_hits,
    // diffs_run) are the durable perf signal; the ms field is reserved
    // for the next pass.

    // Allocate the arena on the parent heap so we can hand the pointer
    // back inside BlameResult and free everything in one shot via
    // result.deinit().
    const arena_box = try parent_allocator.create(std.heap.ArenaAllocator);
    errdefer parent_allocator.destroy(arena_box);
    arena_box.* = std.heap.ArenaAllocator.init(parent_allocator);
    errdefer arena_box.deinit();
    const arena = arena_box.allocator();

    var metrics: BlameMetrics = .{};

    var ctx: Ctx = .{
        .arena = arena,
        .transient = parent_allocator,
        .store = store,
        .path = try arena.dupe(u8, path),
        .commits = .empty,
        .path_blob_at_tree = .empty,
        .blobs = .empty,
        .blob_lines = .empty,
        .metrics = &metrics,
    };
    // Hash maps live in the arena and are freed with it; no per-map deinit.

    // Resolve target ref → commit → tree → blob → lines.
    const head_commit = loadCommit(&ctx, ref_oid) catch |e| return switch (e) {
        error.MalformedCommit, error.MalformedAuthor => error.RefNotFound,
        else => |x| x,
    };
    const target_blob_opt = try lookupPathInTree(&ctx, head_commit.tree_oid);
    const target_blob = target_blob_opt orelse return error.PathNotFoundAtRef;
    const target_lines = try loadBlobLines(&ctx, target_blob);
    const total_lines: u32 = @intCast(target_lines.len);

    // Determine which lines to attribute (-L range or whole file).
    var range_start: u32 = 1;
    var range_end: u32 = total_lines;
    if (opts.line_range) |r| {
        if (r.start == 0 or r.end == 0 or r.start > r.end or r.end > total_lines) {
            return error.PathNotFoundAtRef; // close-enough error for invalid range
        }
        range_start = r.start;
        range_end = r.end;
    }

    const requested_count: u32 = if (total_lines == 0) 0 else (range_end - range_start + 1);

    // attributions[i] holds the commit oid for target line (i+1), or
    // null if not yet attributed. Only slots in [range_start..range_end]
    // get written; the rest stay null and are filtered when we build
    // the final BlameLine array.
    var attributions = try arena.alloc(?Oid, total_lines);
    @memset(attributions, null);

    if (requested_count == 0) {
        // Empty file or empty range → no lines to attribute.
        const blank: []BlameLine = &.{};
        return .{
            .lines = blank,
            .metrics = metrics,
            .arena = arena_box,
        };
    }

    // Initial region: every line in the requested range.
    const initial_region = try arena.alloc(Region, 1);
    initial_region[0] = .{
        .current_commit = ref_oid,
        .blob_line_start = range_start,
        .blob_line_end = range_end,
        .target_line_start = range_start,
        .target_line_end = range_end,
    };

    var queue = WorkQueue.initContext({});
    defer queue.deinit(parent_allocator);
    try queue.push(ctx.transient, .{
        .commit_oid = ref_oid,
        .author_time = head_commit.author.unix_time,
        .regions = initial_region,
    });

    var examined: u32 = 0;

    while (queue.pop()) |item| {
        // Capture-the-pointer: getPtr is OK because we never mutate
        // ctx.commits across this borrow.
        if (opts.max_commits) |cap| {
            if (examined >= cap) {
                metrics.partial = true;
                // Pin the residue to the target ref's commit.
                attributeAll(attributions, item.regions, ref_oid);
                while (queue.pop()) |trailing| {
                    attributeAll(attributions, trailing.regions, ref_oid);
                }
                break;
            }
        }
        examined += 1;

        const commit_oid = item.commit_oid;
        const cm = try loadCommit(&ctx, commit_oid);
        const tree_oid = cm.tree_oid;
        const parents = cm.parent_oids;

        // Path may have vanished mid-walk (rare without rename
        // detection — happens if we mis-route via a merge). Be
        // defensive.
        const blob_in_commit_opt = try lookupPathInTree(&ctx, tree_oid);
        if (blob_in_commit_opt == null) {
            attributeAll(attributions, item.regions, commit_oid);
            continue;
        }
        const blob_in_commit = blob_in_commit_opt.?;

        if (parents.len == 0) {
            // Root commit.
            attributeAll(attributions, item.regions, commit_oid);
            continue;
        }

        if (parents.len == 1) {
            try handleSingleParent(&ctx, &queue, attributions, commit_oid, parents[0], blob_in_commit, item.regions);
        } else {
            try handleMergeCommit(&ctx, &queue, attributions, commit_oid, parents, blob_in_commit, item.regions);
        }
    }

    metrics.commits_examined = examined;

    // Anything still null in the requested range (shouldn't happen in
    // a connected history) gets pinned to the target ref.
    var i: u32 = range_start;
    while (i <= range_end) : (i += 1) {
        if (attributions[i - 1] == null) attributions[i - 1] = ref_oid;
    }

    // Build the BlameLine output.
    const out_lines = try arena.alloc(BlameLine, requested_count);
    var w_idx: usize = 0;
    var li: u32 = range_start;
    while (li <= range_end) : (li += 1) {
        const oid = attributions[li - 1].?;
        const cm = try loadCommit(&ctx, oid);
        out_lines[w_idx] = .{
            .line_no = li,
            .commit_oid = oid,
            .author_name = cm.author.name,
            .author_email = cm.author.email,
            .author_time = cm.author.unix_time,
            .author_tz_offset_minutes = cm.author.tz_offset_minutes,
            .content = target_lines[li - 1],
        };
        w_idx += 1;
    }

    return .{
        .lines = out_lines,
        .metrics = metrics,
        .arena = arena_box,
    };
}

// ── Tests ─────────────────────────────────────────────────────────

const testing = std.testing;
const compute_oid = @import("../object/mod.zig").computeOid;
const tree_mode_regular = tree_mod.blob_mode_regular;

/// Test-only helper: write `kind`/`payload` to `store` and return its
/// Oid. Mirrors the pattern other unit tests use.
fn putObject(
    allocator: std.mem.Allocator,
    store: *LooseStore,
    kind: Kind,
    payload: []const u8,
) !Oid {
    const oid = compute_oid(kind, payload);
    try store.write(allocator, kind, payload, oid);
    return oid;
}

/// Build a tree containing one entry — the blame fixture's file —
/// and return the tree oid.
fn writeSingleFileTree(
    allocator: std.mem.Allocator,
    store: *LooseStore,
    name: []const u8,
    blob_oid: Oid,
) !Oid {
    const entries = [_]tree_mod.Entry{
        .{ .mode = tree_mode_regular, .name = name, .oid = blob_oid },
    };
    const payload = try tree_mod.serialize(allocator, &entries);
    defer allocator.free(payload);
    return try putObject(allocator, store, .tree, payload);
}

fn writeCommit(
    allocator: std.mem.Allocator,
    store: *LooseStore,
    tree_oid: Oid,
    parents: []const Oid,
    author_name: []const u8,
    author_email: []const u8,
    author_time: i64,
    message: []const u8,
) !Oid {
    const author = commit_mod.Author{
        .name = author_name,
        .email = author_email,
        .when_unix = author_time,
    };
    const payload = try commit_mod.serialize(allocator, .{
        .tree_oid = tree_oid,
        .parent_oids = parents,
        .author = author,
        .committer = author,
        .message = message,
    });
    defer allocator.free(payload);
    return try putObject(allocator, store, .commit, payload);
}

test "blame: single-commit file — all lines attribute to that commit" {
    const allocator = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = LooseStore.init(tmp.dir, io);

    const blob = "hello\nworld\nthird line\n";
    const blob_oid = try putObject(allocator, &store, .blob, blob);
    const tree_oid = try writeSingleFileTree(allocator, &store, "file.txt", blob_oid);
    const commit_oid = try writeCommit(allocator, &store, tree_oid, &.{}, "Alice", "a@a", 1_700_000_000, "init\n");

    var result = try blameFile(allocator, &store, commit_oid, "file.txt", .{});
    defer result.deinit();

    try testing.expectEqual(@as(usize, 3), result.lines.len);
    for (result.lines, 1..) |line, idx| {
        try testing.expectEqual(@as(u32, @intCast(idx)), line.line_no);
        try testing.expect(line.commit_oid.eql(commit_oid));
        try testing.expectEqualStrings("Alice", line.author_name);
    }
}

test "blame: tree-OID short-circuit fires across unchanged commits" {
    const allocator = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = LooseStore.init(tmp.dir, io);

    const file_v1 = "alpha\nbeta\ngamma\ndelta\nepsilon\n";
    const file_v2 = "alpha\nbeta\nGAMMA-CHANGED\ndelta\nepsilon\n";

    const blob_v1 = try putObject(allocator, &store, .blob, file_v1);
    const blob_v2 = try putObject(allocator, &store, .blob, file_v2);

    const tree_v1 = try writeSingleFileTree(allocator, &store, "file.txt", blob_v1);

    // A: creates the file at v1.
    const a = try writeCommit(allocator, &store, tree_v1, &.{}, "Alice", "a@a", 1_700_000_000, "init\n");

    // 20 unchanged commits B1..B20 (each parents on the previous).
    var prev = a;
    var unchanged_oids: [20]Oid = undefined;
    var i: usize = 0;
    while (i < 20) : (i += 1) {
        // Use a different file in the tree per commit to make the tree
        // OID different, BUT keep "file.txt" pointing at blob_v1. We
        // simulate that by adding a sibling file with bumping content.
        //
        // Build a 2-entry tree: file.txt + bump_<i>.txt
        var bump_name_buf: [16]u8 = undefined;
        const bump_name = try std.fmt.bufPrint(&bump_name_buf, "bump_{d}.txt", .{i});
        const bump_blob = try putObject(allocator, &store, .blob, bump_name);
        var entries = [_]tree_mod.Entry{
            .{ .mode = tree_mode_regular, .name = "file.txt", .oid = blob_v1 },
            .{ .mode = tree_mode_regular, .name = bump_name, .oid = bump_blob },
        };
        std.mem.sort(tree_mod.Entry, &entries, {}, tree_mod.lessThanForTree);
        const tpayload = try tree_mod.serialize(allocator, &entries);
        defer allocator.free(tpayload);
        const tree_unchanged = try putObject(allocator, &store, .tree, tpayload);

        const parents = [_]Oid{prev};
        unchanged_oids[i] = try writeCommit(
            allocator,
            &store,
            tree_unchanged,
            &parents,
            "Bob",
            "b@b",
            1_700_000_001 + @as(i64, @intCast(i)),
            "no-op\n",
        );
        prev = unchanged_oids[i];
    }

    // C: modifies line 3 of file.txt — uses tree_v2 (only file.txt entry).
    // We deliberately drop the sibling so the file change is the *only*
    // delta between B20 and C.
    const c_tree_entries = [_]tree_mod.Entry{
        .{ .mode = tree_mode_regular, .name = "file.txt", .oid = blob_v2 },
    };
    const c_tree_payload = try tree_mod.serialize(allocator, &c_tree_entries);
    defer allocator.free(c_tree_payload);
    const c_tree = try putObject(allocator, &store, .tree, c_tree_payload);
    const parents_c = [_]Oid{prev};
    const c = try writeCommit(allocator, &store, c_tree, &parents_c, "Carol", "c@c", 1_800_000_000, "change\n");

    var result = try blameFile(allocator, &store, c, "file.txt", .{});
    defer result.deinit();

    try testing.expectEqual(@as(usize, 5), result.lines.len);
    // Lines 1,2,4,5 should attribute to A (Alice).
    try testing.expect(result.lines[0].commit_oid.eql(a)); // line 1
    try testing.expect(result.lines[1].commit_oid.eql(a)); // line 2
    try testing.expect(result.lines[2].commit_oid.eql(c)); // line 3 — changed
    try testing.expect(result.lines[3].commit_oid.eql(a)); // line 4
    try testing.expect(result.lines[4].commit_oid.eql(a)); // line 5

    // The short-circuit must have fired at every B_i where file.txt is
    // unchanged from its parent. That's 20 hits (each Bi vs Bi-1, and
    // B1 vs A all unchanged from the file's perspective).
    try testing.expectEqual(@as(u32, 20), result.metrics.short_circuit_hits);
    // Only one Myers call should have run — at C vs B20.
    try testing.expectEqual(@as(u32, 1), result.metrics.diffs_run);
}

test "blame: merge commit — line from non-trunk branch attributes to its origin, not the merge" {
    const allocator = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = LooseStore.init(tmp.dir, io);

    const v_base = "line1\nline2\nline3\nline4\nline5\n";
    const v_branch_b = "line1\nline2\nline3-B\nline4\nline5\n"; // line 3 changed
    const v_branch_c = "line1\nline2\nline3\nline4\nline5-C\n"; // line 5 changed
    const v_merge = "line1\nline2\nline3-B\nline4\nline5-C\n"; // both incorporated

    const blob_base = try putObject(allocator, &store, .blob, v_base);
    const blob_b = try putObject(allocator, &store, .blob, v_branch_b);
    const blob_c = try putObject(allocator, &store, .blob, v_branch_c);
    const blob_m = try putObject(allocator, &store, .blob, v_merge);

    const tree_base = try writeSingleFileTree(allocator, &store, "file.txt", blob_base);
    const tree_b = try writeSingleFileTree(allocator, &store, "file.txt", blob_b);
    const tree_c = try writeSingleFileTree(allocator, &store, "file.txt", blob_c);
    const tree_m = try writeSingleFileTree(allocator, &store, "file.txt", blob_m);

    const a = try writeCommit(allocator, &store, tree_base, &.{}, "Alice", "a@a", 1_700_000_000, "base\n");

    const parents_b = [_]Oid{a};
    const b = try writeCommit(allocator, &store, tree_b, &parents_b, "Bob", "b@b", 1_700_001_000, "branch-B\n");

    const parents_c = [_]Oid{a};
    const c = try writeCommit(allocator, &store, tree_c, &parents_c, "Carol", "c@c", 1_700_002_000, "branch-C\n");

    // M is the merge of B and C. First parent = B (the trunk).
    const parents_m = [_]Oid{ b, c };
    const m = try writeCommit(allocator, &store, tree_m, &parents_m, "Dave", "d@d", 1_700_003_000, "merge\n");

    var result = try blameFile(allocator, &store, m, "file.txt", .{});
    defer result.deinit();

    try testing.expectEqual(@as(usize, 5), result.lines.len);

    // Line 1: unchanged → A.
    try testing.expect(result.lines[0].commit_oid.eql(a));
    // Line 2: unchanged → A.
    try testing.expect(result.lines[1].commit_oid.eql(a));
    // Line 3: changed in branch B → B.
    try testing.expect(result.lines[2].commit_oid.eql(b));
    // Line 4: unchanged → A.
    try testing.expect(result.lines[3].commit_oid.eql(a));
    // Line 5: changed in branch C — MUST attribute to C, not to M.
    try testing.expect(result.lines[4].commit_oid.eql(c));
}

test "blame: merge introduces conflict-resolution content — that line attributes to the merge" {
    const allocator = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = LooseStore.init(tmp.dir, io);

    // A: line1, line2, line3
    // B: line1, line2, line3-B           (line 3 changed)
    // C: line1, line2, line3             (unchanged)
    // M merges B and C *and* inserts a brand-new "resolution-line" at line 4.
    //   M: line1, line2, line3-B, resolution-line
    const v_base = "line1\nline2\nline3\n";
    const v_b = "line1\nline2\nline3-B\n";
    const v_c = v_base; // identical to base
    const v_m = "line1\nline2\nline3-B\nresolution-line\n";

    const blob_base = try putObject(allocator, &store, .blob, v_base);
    const blob_b = try putObject(allocator, &store, .blob, v_b);
    const blob_c = try putObject(allocator, &store, .blob, v_c);
    const blob_m = try putObject(allocator, &store, .blob, v_m);

    const tree_base = try writeSingleFileTree(allocator, &store, "file.txt", blob_base);
    const tree_b = try writeSingleFileTree(allocator, &store, "file.txt", blob_b);
    const tree_c = try writeSingleFileTree(allocator, &store, "file.txt", blob_c);
    const tree_m = try writeSingleFileTree(allocator, &store, "file.txt", blob_m);

    const a = try writeCommit(allocator, &store, tree_base, &.{}, "Alice", "a@a", 1_700_000_000, "base\n");
    const parents_b = [_]Oid{a};
    const b = try writeCommit(allocator, &store, tree_b, &parents_b, "Bob", "b@b", 1_700_001_000, "branch-B\n");
    const parents_c = [_]Oid{a};
    const c = try writeCommit(allocator, &store, tree_c, &parents_c, "Carol", "c@c", 1_700_002_000, "branch-C\n");
    const parents_m = [_]Oid{ b, c };
    const m = try writeCommit(allocator, &store, tree_m, &parents_m, "Dave", "d@d", 1_700_003_000, "merge\n");

    var result = try blameFile(allocator, &store, m, "file.txt", .{});
    defer result.deinit();

    try testing.expectEqual(@as(usize, 4), result.lines.len);
    // Lines 1–2: unchanged across the whole history → A.
    try testing.expect(result.lines[0].commit_oid.eql(a));
    try testing.expect(result.lines[1].commit_oid.eql(a));
    // Line 3: changed in branch B → B.
    try testing.expect(result.lines[2].commit_oid.eql(b));
    // Line 4: the resolution-line — exists in NEITHER B's nor C's blob.
    //         MUST attribute to the merge commit M.
    try testing.expect(result.lines[3].commit_oid.eql(m));
}

test "blame: -L range returns only the requested lines" {
    const allocator = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = LooseStore.init(tmp.dir, io);

    const v1 = "a\nb\nc\nd\ne\n";
    const v2 = "a\nb\nC-changed\nd\ne\n";
    const blob1 = try putObject(allocator, &store, .blob, v1);
    const blob2 = try putObject(allocator, &store, .blob, v2);
    const tree1 = try writeSingleFileTree(allocator, &store, "f.txt", blob1);
    const tree2 = try writeSingleFileTree(allocator, &store, "f.txt", blob2);
    const a = try writeCommit(allocator, &store, tree1, &.{}, "A", "a@a", 1, "x\n");
    const parents = [_]Oid{a};
    const b = try writeCommit(allocator, &store, tree2, &parents, "B", "b@b", 2, "y\n");

    var result = try blameFile(allocator, &store, b, "f.txt", .{
        .line_range = .{ .start = 2, .end = 4 },
    });
    defer result.deinit();

    try testing.expectEqual(@as(usize, 3), result.lines.len);
    try testing.expectEqual(@as(u32, 2), result.lines[0].line_no);
    try testing.expectEqual(@as(u32, 4), result.lines[2].line_no);
    // Line 2 unchanged → A. Line 3 changed → B. Line 4 unchanged → A.
    try testing.expect(result.lines[0].commit_oid.eql(a));
    try testing.expect(result.lines[1].commit_oid.eql(b));
    try testing.expect(result.lines[2].commit_oid.eql(a));
}

test "blame: path not found at ref" {
    const allocator = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = LooseStore.init(tmp.dir, io);

    const blob = try putObject(allocator, &store, .blob, "x\n");
    const tree = try writeSingleFileTree(allocator, &store, "real.txt", blob);
    const c = try writeCommit(allocator, &store, tree, &.{}, "A", "a@a", 1, "x\n");

    try testing.expectError(error.PathNotFoundAtRef, blameFile(allocator, &store, c, "missing.txt", .{}));
}

test "blame: path is a directory" {
    const allocator = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = LooseStore.init(tmp.dir, io);

    // Build a tree where "src" is itself a tree.
    const inner_blob = try putObject(allocator, &store, .blob, "x\n");
    const inner_tree = try writeSingleFileTree(allocator, &store, "f.txt", inner_blob);
    const outer_entries = [_]tree_mod.Entry{
        .{ .mode = tree_mod.tree_mode_octal, .name = "src", .oid = inner_tree },
    };
    const outer_payload = try tree_mod.serialize(allocator, &outer_entries);
    defer allocator.free(outer_payload);
    const outer_tree = try putObject(allocator, &store, .tree, outer_payload);
    const c = try writeCommit(allocator, &store, outer_tree, &.{}, "A", "a@a", 1, "x\n");

    try testing.expectError(error.PathIsNotFile, blameFile(allocator, &store, c, "src", .{}));
}
