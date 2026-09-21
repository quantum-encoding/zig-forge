//! Directory-level duplicate analysis
//!
//! File-level duplicate groups answer "which files are the same?". After years
//! of copy-paste backups that is the wrong granularity: twenty thousand groups
//! nobody can review. The question a person can act on is "which *folders* are
//! the same, and does the stale one hold anything the other does not?".
//!
//! Two results, both derived from hashes the file pipeline already computed —
//! this module performs no file I/O:
//!
//!   * Identical sets — directories whose whole subtree is the same: same
//!     names, same content, same symlinks. Found with a Merkle digest, so any
//!     number of copies lands in one set, and only the top-most directory of
//!     each copied tree is reported.
//!   * Overlaps — directory pairs that share most of their content but are not
//!     identical: the working folder that moved on versus its old backup. Each
//!     side lists the files found nowhere in the other, which is exactly what
//!     would be lost by deleting it.
//!
//! Content identity of a file (its *token*):
//!   * `H` + content hash, when the pipeline hashed it (it has a same-size,
//!     same-prefix twin somewhere in the scan);
//!   * `U` + (dev, ino) of its first-seen hard link otherwise. A file the
//!     pipeline never had to hash is provably unique in this scan, so no other
//!     inode can share its token — but its other hard links do, which is what
//!     makes `cp -al` / `rsync --link-dest` snapshot trees compare equal
//!     without reading a byte. A file whose hashing *failed* also lands here:
//!     treated as unique, it can only ever make the verdict more cautious.
//!
//! Directory digest, H being the configured file hash algorithm:
//!
//!     H( "zdedupe-dir-v1\x00" || entry* )      entries sorted by name bytes
//!     entry = kind || u64le(len(name)) || name || payload
//!       'F' file     payload = token (33 bytes, zero padded)
//!       'D' subdir   payload = its digest (32 bytes)
//!       'L' symlink  payload = u64le(len(target)) || target
//!
//! Safety rules, because these results are used to decide what to delete:
//!   * A directory with anything unreadable beneath it is `incomplete`: it is
//!     never part of an identical set and never the contained side of a
//!     containment verdict.
//!   * Entries pruned on purpose (excludes, cache dirs, hidden-when-off,
//!     special files) do not block a verdict, but every result carries the
//!     count so a consumer can say "identical, ignoring N entries".
//!   * Overlap relations are about regular-file content. Symlinks and empty
//!     directories only matter to identical sets.
//!   * No finding points at or inside version-control metadata (`.git`, `.hg`,
//!     `.svn`). In there a file's *location* is its meaning: `.git/refs/heads`
//!     can match `.git/refs/remotes/origin` byte for byte, and "heads adds
//!     nothing" is then true of the content and ruinous as advice — deleting
//!     it deletes the local branches. That metadata still counts toward the
//!     identity of the project around it, so two copies of a project whose
//!     histories differ are never called identical.

const std = @import("std");
const types = @import("types.zig");
const fast_walker = @import("fast_walker.zig");

pub const Digest = [32]u8;

/// Content identity of one file; see the module doc.
const Token = [33]u8;

const NodeId = u32;
const no_node: NodeId = std.math.maxInt(NodeId);

const digest_domain = "zdedupe-dir-v1\x00";

/// Directory names that hold version-control metadata.
const vcs_dir_names = [_][]const u8{ ".git", ".hg", ".svn" };

/// True if `path` is, or lies inside, a version-control metadata directory.
fn insideVcsDir(path: []const u8) bool {
    var components = std.mem.tokenizeScalar(u8, path, '/');
    while (components.next()) |component| {
        for (vcs_dir_names) |name| {
            // zig-lens-ignore: EQL-FOR-SECRETS directory names, not secrets
            if (std.mem.eql(u8, component, name)) return true;
        }
    }
    return false;
}

pub const Options = struct {
    /// A pair is reported when at least this share of the files on one side
    /// also exists on the other.
    overlap_threshold: f64 = 0.5,
    /// ...and at least this many files are shared. One shared file between two
    /// small folders is a duplicate file, not a copied folder.
    min_shared_files: u64 = 2,
    /// Cap on the per-side "found only here" path list. Counts stay exact.
    max_only_listed: usize = 100,
    /// Cap on reported overlap pairs (largest shared size first).
    max_overlaps: usize = 500,
    /// Content with more copies than this does not seed overlap candidates.
    /// A licence file present 400 times says nothing about which folders are
    /// copies of each other, and seeding is quadratic in the copy count.
    max_seed_copies: usize = 32,
    /// Upper bound on tracked candidate pairs; past it, new pairs are ignored.
    max_candidate_pairs: usize = 2_000_000,
};

/// One member of an identical set.
pub const DirInfo = struct {
    path: []const u8,
    /// Newest file modification time in the subtree (seconds since epoch).
    newest_mtime: i64,
    /// Entries under this directory that were deliberately ignored.
    skipped_entries: u64,
};

/// Directories whose subtrees are identical.
pub const IdenticalSet = struct {
    digest: Digest,
    /// Regular files in each copy (recursive).
    file_count: u64,
    /// Logical size of each copy in bytes (recursive).
    bytes: u64,
    /// `bytes * (copies - 1)`. An upper bound: files that are hard links of
    /// one another across the copies take no extra space to begin with.
    reclaimable: u64,
    /// Sorted by path.
    dirs: []DirInfo,
};

pub const Relation = enum {
    /// Both sides hold exactly the same file content (arranged or named
    /// differently, or the digests would have matched).
    same_content,
    /// Every file in A also exists in B.
    a_in_b,
    /// Every file in B also exists in A.
    b_in_a,
    /// Each side has content the other lacks — or containment cannot be
    /// vouched for because the contained side is incomplete.
    overlap,
};

/// One side of an overlap pair.
pub const OverlapSide = struct {
    path: []const u8,
    files: u64,
    bytes: u64,
    newest_mtime: i64,
    skipped_entries: u64,
    /// False if something beneath could not be read.
    complete: bool,
    /// How many directories in the scan are identical to this one, itself
    /// included. Above 1, this side stands for a whole identical set (it is
    /// the set's first path) and the pair is reported once, not per copy.
    identical_copies: u64,
    /// Files here whose content also exists on the other side.
    shared_files: u64,
    shared_bytes: u64,
    /// Files here whose content exists nowhere on the other side.
    only_count: u64,
    /// Their paths, sorted, at most `Options.max_only_listed`.
    only: [][]const u8,
};

pub const Overlap = struct {
    relation: Relation,
    a: OverlapSide,
    b: OverlapSide,
};

pub const Analysis = struct {
    arena: std.heap.ArenaAllocator,
    dirs_analyzed: u64,
    dirs_incomplete: u64,
    /// Largest `reclaimable` first.
    identical_sets: []IdenticalSet,
    /// Largest shared size first.
    overlaps: []Overlap,

    pub fn deinit(self: *Analysis) void {
        self.arena.deinit();
    }
};

const Node = struct {
    path: []const u8,
    parent: NodeId = no_node,
    children: std.ArrayListUnmanaged(NodeId) = .empty,
    files: std.ArrayListUnmanaged(u32) = .empty,
    links: std.ArrayListUnmanaged(u32) = .empty,
    own_incomplete: bool,
    own_skipped: u32,
    /// Is, or lies inside, `.git` / `.hg` / `.svn`: never reported on.
    in_vcs: bool,

    // Recursive aggregates, filled bottom-up.
    complete: bool = true,
    skipped: u64 = 0,
    file_count: u64 = 0,
    bytes: u64 = 0,
    newest_mtime: i64 = std.math.minInt(i64),
    digest: Digest = @splat(0),
    /// Span of file indices covered by the subtree: [file_lo, file_hi).
    /// The walk is depth-first, so everything recorded between entering a
    /// directory and leaving it belongs to that directory — its subtree is one
    /// contiguous slice of the file list, and needs no collecting.
    file_lo: u32 = std.math.maxInt(u32),
    file_hi: u32 = 0,

    /// False if the span holds anything but this subtree (it never should;
    /// a pair involving such a node is skipped rather than trusted).
    fn spanIsExact(self: *const Node) bool {
        return self.file_count == 0 or self.file_hi - self.file_lo == self.file_count;
    }
};

const TreeHasher = union(types.Config.HashAlgorithm) {
    blake3: std.crypto.hash.Blake3,
    sha256: std.crypto.hash.sha2.Sha256,

    fn init(algorithm: types.Config.HashAlgorithm) TreeHasher {
        return switch (algorithm) {
            .blake3 => .{ .blake3 = std.crypto.hash.Blake3.init(.{}) },
            .sha256 => .{ .sha256 = std.crypto.hash.sha2.Sha256.init(.{}) },
        };
    }

    fn update(self: *TreeHasher, data: []const u8) void {
        switch (self.*) {
            inline else => |*h| h.update(data),
        }
    }

    fn updateLen(self: *TreeHasher, len: usize) void {
        var buf: [8]u8 = undefined;
        std.mem.writeInt(u64, &buf, len, .little);
        self.update(&buf);
    }

    fn final(self: *TreeHasher) Digest {
        var out: Digest = undefined;
        switch (self.*) {
            inline else => |*h| h.final(&out),
        }
        return out;
    }
};

/// Analyze the directories recorded by a tree-recording walk.
///
/// `files` must be the walk's entries, in walk order, *after* the hashing
/// pipeline has run. `dir_records` must be in pre-order (parents first), which
/// is how `FastWalker` emits them.
pub fn analyze(
    allocator: std.mem.Allocator,
    files: []const types.FileEntry,
    dir_records: []const fast_walker.DirRecord,
    link_records: []const fast_walker.LinkRecord,
    algorithm: types.Config.HashAlgorithm,
    options: Options,
) !Analysis {
    if (files.len >= no_node or dir_records.len >= no_node or link_records.len >= no_node) {
        return error.TooManyEntries;
    }

    var result: Analysis = .{
        .arena = std.heap.ArenaAllocator.init(allocator),
        .dirs_analyzed = dir_records.len,
        .dirs_incomplete = 0,
        .identical_sets = &.{},
        .overlaps = &.{},
    };
    errdefer result.arena.deinit();

    // Everything that does not outlive this call.
    var scratch_arena = std.heap.ArenaAllocator.init(allocator);
    defer scratch_arena.deinit();

    var analyzer: Analyzer = .{
        .scratch = scratch_arena.allocator(),
        .out = result.arena.allocator(),
        .files = files,
        .links = link_records,
        .algorithm = algorithm,
        .options = options,
        .nodes = &.{},
        .file_node = &.{},
    };

    try analyzer.buildTree(dir_records);
    try analyzer.aggregate();
    try analyzer.internContent();

    for (analyzer.nodes) |*node| {
        if (!node.complete) result.dirs_incomplete += 1;
    }

    result.identical_sets = try analyzer.findIdenticalSets();
    result.overlaps = try analyzer.findOverlaps();
    return result;
}

const Analyzer = struct {
    scratch: std.mem.Allocator,
    out: std.mem.Allocator,
    files: []const types.FileEntry,
    links: []const fast_walker.LinkRecord,
    algorithm: types.Config.HashAlgorithm,
    options: Options,
    nodes: []Node,
    /// Directory holding each file, or `no_node` (a scan root that is a file).
    file_node: []NodeId,
    /// Per digest: the first member by path, and how many members there are.
    /// Filled by findIdenticalSets for every digest shared by 2+ directories.
    twins: std.AutoHashMapUnmanaged(Digest, Twins) = .empty,

    /// Token of each file interned to a small integer: equal ids <=> equal
    /// tokens. Ids below `shared_ids` belong to content that can exist more
    /// than once (hashed files, hard-link families); every other file is
    /// unique and simply gets the next free id, without touching a hash map.
    content_id: []u32 = &.{},
    shared_ids: u32 = 0,
    /// Set membership by stamping, indexed by content id: `seen_a[id] == tag`
    /// means "in side A of the pair being compared". Comparing a pair is then
    /// two linear passes with no hashing and no allocation — this is what
    /// keeps a thousand comparisons over node_modules-sized trees cheap.
    seen_a: []u32 = &.{},
    seen_b: []u32 = &.{},
    pair_tag: u32 = 0,
    only_scratch: std.ArrayListUnmanaged([]const u8) = .empty,

    const Twins = struct { representative: NodeId, count: u64 };

    // ------------------------------------------------------------------
    // Tree construction
    // ------------------------------------------------------------------

    fn buildTree(self: *Analyzer, dir_records: []const fast_walker.DirRecord) !void {
        self.nodes = try self.scratch.alloc(Node, dir_records.len);

        var by_path: std.StringHashMapUnmanaged(NodeId) = .empty;
        try by_path.ensureTotalCapacity(self.scratch, @intCast(dir_records.len));

        for (dir_records, 0..) |record, i| {
            self.nodes[i] = .{
                // Result structures point at this copy, so it lives in `out`.
                .path = try self.out.dupe(u8, record.path),
                .own_incomplete = record.incomplete,
                .own_skipped = record.skipped,
                .in_vcs = insideVcsDir(record.path),
            };
            const id: NodeId = @intCast(i);
            // Pre-order guarantees the parent is already registered. Scan
            // roots have no registered parent and become tree roots.
            if (parentPath(record.path)) |parent_path| {
                if (by_path.get(parent_path)) |parent_id| {
                    self.nodes[i].parent = parent_id;
                    try self.nodes[parent_id].children.append(self.scratch, id);
                }
            }
            const gop = by_path.getOrPutAssumeCapacity(self.nodes[i].path);
            // The same path recorded twice means overlapping scan roots got
            // through. Keep the first; the second stays an orphan rather than
            // making a directory a "copy" of itself.
            if (!gop.found_existing) gop.value_ptr.* = id;
        }

        self.file_node = try self.scratch.alloc(NodeId, self.files.len);
        for (self.files, 0..) |entry, i| {
            const owner = if (parentPath(entry.path)) |p| by_path.get(p) orelse no_node else no_node;
            self.file_node[i] = owner;
            if (owner != no_node) {
                try self.nodes[owner].files.append(self.scratch, @intCast(i));
            }
        }

        for (self.links, 0..) |record, i| {
            const parent_path = parentPath(record.path) orelse continue;
            const owner = by_path.get(parent_path) orelse continue;
            try self.nodes[owner].links.append(self.scratch, @intCast(i));
        }
    }

    // ------------------------------------------------------------------
    // Bottom-up aggregation and Merkle digests
    // ------------------------------------------------------------------

    const DigestEntry = struct {
        name: []const u8,
        kind: enum(u8) { file = 'F', dir = 'D', link = 'L' },
        index: u32,

        fn lessThan(_: void, lhs: DigestEntry, rhs: DigestEntry) bool {
            return std.mem.order(u8, lhs.name, rhs.name) == .lt;
        }
    };

    fn aggregate(self: *Analyzer) !void {
        var entries: std.ArrayListUnmanaged(DigestEntry) = .empty;

        // Reverse pre-order visits every child before its parent.
        var i = self.nodes.len;
        while (i > 0) {
            i -= 1;
            const node = &self.nodes[i];

            node.complete = !node.own_incomplete;
            node.skipped = node.own_skipped;

            entries.clearRetainingCapacity();

            for (node.files.items) |file_index| {
                const entry = &self.files[file_index];
                node.file_lo = @min(node.file_lo, file_index);
                node.file_hi = @max(node.file_hi, file_index + 1);
                node.file_count += 1;
                node.bytes += entry.size;
                node.newest_mtime = @max(node.newest_mtime, entry.mtime);
                try entries.append(self.scratch, .{
                    .name = baseName(entry.path),
                    .kind = .file,
                    .index = file_index,
                });
            }
            for (node.children.items) |child_id| {
                const child = &self.nodes[child_id];
                node.complete = node.complete and child.complete;
                node.skipped += child.skipped;
                if (child.file_count > 0) {
                    node.file_lo = @min(node.file_lo, child.file_lo);
                    node.file_hi = @max(node.file_hi, child.file_hi);
                }
                node.file_count += child.file_count;
                node.bytes += child.bytes;
                node.newest_mtime = @max(node.newest_mtime, child.newest_mtime);
                try entries.append(self.scratch, .{
                    .name = baseName(child.path),
                    .kind = .dir,
                    .index = child_id,
                });
            }
            for (node.links.items) |link_index| {
                try entries.append(self.scratch, .{
                    .name = baseName(self.links[link_index].path),
                    .kind = .link,
                    .index = link_index,
                });
            }

            // An incomplete directory never enters a digest comparison, and
            // taints every ancestor, so its digest is simply left zeroed.
            if (!node.complete) continue;

            std.sort.heap(DigestEntry, entries.items, {}, DigestEntry.lessThan);

            var hasher = TreeHasher.init(self.algorithm);
            hasher.update(digest_domain);
            for (entries.items) |entry| {
                hasher.update(&.{@intFromEnum(entry.kind)});
                hasher.updateLen(entry.name.len);
                hasher.update(entry.name);
                switch (entry.kind) {
                    .file => hasher.update(&self.token(entry.index)),
                    .dir => hasher.update(&self.nodes[entry.index].digest),
                    .link => {
                        const target = self.links[entry.index].target;
                        hasher.updateLen(target.len);
                        hasher.update(target);
                    },
                }
            }
            node.digest = hasher.final();
        }
    }

    fn token(self: *const Analyzer, file_index: u32) Token {
        const primary = self.files[file_index].link_of orelse file_index;
        const entry = &self.files[primary];

        var out: Token = @splat(0);
        if (entry.hash) |hash| {
            out[0] = 'H';
            @memcpy(out[1..33], &hash);
        } else {
            out[0] = 'U';
            std.mem.writeInt(u64, out[1..9], entry.dev, .little);
            std.mem.writeInt(u64, out[9..17], entry.inode, .little);
        }
        return out;
    }

    fn internContent(self: *Analyzer) !void {
        self.content_id = try self.scratch.alloc(u32, self.files.len);

        // Only content that can exist twice needs a lookup: hashed files
        // (they have a twin) and hard-link families.
        var has_links = try std.DynamicBitSetUnmanaged.initEmpty(self.scratch, self.files.len);
        for (self.files) |entry| {
            if (entry.link_of) |primary| has_links.set(primary);
        }

        var ids: std.AutoHashMapUnmanaged(Token, u32) = .empty;
        defer ids.deinit(self.scratch);
        for (self.files, 0..) |entry, i| {
            if (entry.hash == null and entry.link_of == null and !has_links.isSet(i)) continue;
            const gop = try ids.getOrPut(self.scratch, self.token(@intCast(i)));
            if (!gop.found_existing) gop.value_ptr.* = ids.count() - 1;
            self.content_id[i] = gop.value_ptr.*;
        }
        self.shared_ids = ids.count();

        var next = self.shared_ids;
        for (self.files, 0..) |entry, i| {
            if (entry.hash == null and entry.link_of == null and !has_links.isSet(i)) {
                self.content_id[i] = next;
                next += 1;
            }
        }

        self.seen_a = try self.scratch.alloc(u32, next);
        self.seen_b = try self.scratch.alloc(u32, next);
        @memset(self.seen_a, 0);
        @memset(self.seen_b, 0);
    }

    // ------------------------------------------------------------------
    // Identical sets
    // ------------------------------------------------------------------

    fn findIdenticalSets(self: *Analyzer) ![]IdenticalSet {
        var by_digest: std.AutoHashMapUnmanaged(Digest, std.ArrayListUnmanaged(NodeId)) = .empty;

        for (self.nodes, 0..) |*node, i| {
            // Empty directories are all "identical" to each other: noise.
            if (!node.complete or node.file_count == 0) continue;
            if (node.in_vcs) continue; // see the module doc: never advise on VCS metadata
            const gop = try by_digest.getOrPut(self.scratch, node.digest);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            try gop.value_ptr.append(self.scratch, @intCast(i));
        }

        var sets: std.ArrayListUnmanaged(IdenticalSet) = .empty;

        var iter = by_digest.iterator();
        while (iter.next()) |kv| {
            const members = kv.value_ptr.items;
            if (members.len < 2) continue;

            var representative = members[0];
            for (members[1..]) |member| {
                if (std.mem.order(u8, self.nodes[member].path, self.nodes[representative].path) == .lt) {
                    representative = member;
                }
            }
            try self.twins.put(self.scratch, kv.key_ptr.*, .{
                .representative = representative,
                .count = members.len,
            });

            if (self.impliedByParents(members)) continue;

            const first = &self.nodes[members[0]];
            const dirs = try self.out.alloc(DirInfo, members.len);
            for (members, dirs) |member, *info| {
                const node = &self.nodes[member];
                info.* = .{
                    .path = node.path,
                    .newest_mtime = node.newest_mtime,
                    .skipped_entries = node.skipped,
                };
            }
            std.sort.heap(DirInfo, dirs, {}, struct {
                fn lessThan(_: void, lhs: DirInfo, rhs: DirInfo) bool {
                    return std.mem.order(u8, lhs.path, rhs.path) == .lt;
                }
            }.lessThan);

            try sets.append(self.out, .{
                .digest = kv.key_ptr.*,
                .file_count = first.file_count,
                .bytes = first.bytes,
                .reclaimable = first.bytes * (members.len - 1),
                .dirs = dirs,
            });
        }

        std.sort.heap(IdenticalSet, sets.items, {}, struct {
            fn lessThan(_: void, lhs: IdenticalSet, rhs: IdenticalSet) bool {
                if (lhs.reclaimable != rhs.reclaimable) return lhs.reclaimable > rhs.reclaimable;
                return std.mem.order(u8, lhs.dirs[0].path, rhs.dirs[0].path) == .lt;
            }
        }.lessThan);

        return sets.toOwnedSlice(self.out);
    }

    /// True if this set says nothing its parents' set does not already say:
    /// every member sits in a *different* parent and those parents are all
    /// identical to one another. `P1/src == P2/src` is implied by `P1 == P2`.
    ///
    /// Not implied, and therefore still reported: a member whose parent is no
    /// copy of the others (`P1/src == elsewhere/src`), and two members inside
    /// one parent (`P1/a == P1/b` is a duplicate *within* each copy).
    fn impliedByParents(self: *const Analyzer, members: []const NodeId) bool {
        const first_parent = self.nodes[members[0]].parent;
        if (first_parent == no_node) return false;
        const parent_node = &self.nodes[first_parent];
        if (!parent_node.complete) return false;

        for (members[1..], 1..) |member, i| {
            const parent = self.nodes[member].parent;
            if (parent == no_node) return false;
            const node = &self.nodes[parent];
            if (!node.complete) return false;
            // zig-lens-ignore: EQL-FOR-SECRETS content digests, not secrets
            if (!std.mem.eql(u8, &node.digest, &parent_node.digest)) return false;
            for (members[0..i]) |earlier| {
                if (self.nodes[earlier].parent == parent) return false;
            }
        }
        return true;
    }

    // ------------------------------------------------------------------
    // Overlap pairs
    // ------------------------------------------------------------------

    const PairKey = struct {
        lo: NodeId,
        hi: NodeId,

        fn of(x: NodeId, y: NodeId) PairKey {
            return if (x < y) .{ .lo = x, .hi = y } else .{ .lo = y, .hi = x };
        }
    };

    const PairMap = std.AutoHashMapUnmanaged(PairKey, u64);

    fn findOverlaps(self: *Analyzer) ![]Overlap {
        var support: PairMap = .empty;
        try self.seedCandidates(&support);

        // Pairs whose estimated overlap clears the threshold.
        var kept: std.AutoHashMapUnmanaged(PairKey, f64) = .empty;
        var iter = support.iterator();
        while (iter.next()) |kv| {
            const score = self.estimate(kv.key_ptr.*, kv.value_ptr.*) orelse continue;
            if (score >= self.options.overlap_threshold) {
                try kept.put(self.scratch, kv.key_ptr.*, score);
            }
        }

        // Report the top of each copied tree, not every matching subdirectory
        // beneath it: drop a pair when the pair of parents says the same thing
        // about as well. (When the parents are a much weaker match — one
        // project inside two otherwise unrelated folders — the child pair is
        // the real finding and stays.)
        const Candidate = struct { key: PairKey, shared: u64 };
        var candidates: std.ArrayListUnmanaged(Candidate) = .empty;
        var emitted: std.AutoHashMapUnmanaged(PairKey, void) = .empty;
        var kept_iter = kept.iterator();
        while (kept_iter.next()) |kv| {
            const key = kv.key_ptr.*;
            const parent_a = self.nodes[key.lo].parent;
            const parent_b = self.nodes[key.hi].parent;
            if (parent_a != no_node and parent_b != no_node) {
                if (kept.get(PairKey.of(parent_a, parent_b))) |parent_score| {
                    if (parent_score + 0.02 >= kv.value_ptr.*) continue;
                }
            }
            if (self.identical(key)) continue; // reported as an identical set

            // Seven identical worktrees against one that drifted are one
            // finding, not seven: let the first of an identical set speak for
            // all of them.
            const canonical = self.canonicalPair(key);
            const seen = try emitted.getOrPut(self.scratch, canonical);
            if (seen.found_existing) continue;
            try candidates.append(self.scratch, .{ .key = canonical, .shared = support.get(key).? });
        }

        // The estimate only ranks; verdicts come from an exact comparison.
        // Examine a bounded number, best-supported first (ties broken by path
        // so the selection is deterministic).
        const Ctx = struct {
            nodes: []const Node,
            fn lessThan(ctx: @This(), lhs: Candidate, rhs: Candidate) bool {
                if (lhs.shared != rhs.shared) return lhs.shared > rhs.shared;
                const order = std.mem.order(u8, ctx.nodes[lhs.key.lo].path, ctx.nodes[rhs.key.lo].path);
                if (order != .eq) return order == .lt;
                return std.mem.order(u8, ctx.nodes[lhs.key.hi].path, ctx.nodes[rhs.key.hi].path) == .lt;
            }
        };
        std.sort.heap(Candidate, candidates.items, Ctx{ .nodes = self.nodes }, Ctx.lessThan);

        const examine = @min(candidates.items.len, self.options.max_overlaps * 2);
        var overlaps: std.ArrayListUnmanaged(Overlap) = .empty;
        for (candidates.items[0..examine]) |candidate| {
            if (try self.compareExact(candidate.key)) |overlap| {
                try overlaps.append(self.out, overlap);
            }
        }

        std.sort.heap(Overlap, overlaps.items, {}, struct {
            fn lessThan(_: void, lhs: Overlap, rhs: Overlap) bool {
                const l = @max(lhs.a.shared_bytes, lhs.b.shared_bytes);
                const r = @max(rhs.a.shared_bytes, rhs.b.shared_bytes);
                if (l != r) return l > r;
                const order = std.mem.order(u8, lhs.a.path, rhs.a.path);
                if (order != .eq) return order == .lt;
                return std.mem.order(u8, lhs.b.path, rhs.b.path) == .lt;
            }
        }.lessThan);

        if (overlaps.items.len > self.options.max_overlaps) {
            overlaps.shrinkRetainingCapacity(self.options.max_overlaps);
        }
        return overlaps.toOwnedSlice(self.out);
    }

    /// For every piece of content that exists more than once, credit the pair
    /// of directories holding two of its copies — and then the pair of their
    /// parents, and so on upward in lockstep. A copied tree keeps its internal
    /// layout, so walking up both sides together lands on the two roots of the
    /// copy however deep either of them sits, and credit piles up there.
    fn seedCandidates(self: *Analyzer, support: *PairMap) !void {
        const by_content = try self.scratch.alloc(std.ArrayListUnmanaged(u32), self.shared_ids);
        @memset(by_content, .empty);
        for (self.content_id, 0..) |id, i| {
            if (id >= self.shared_ids or self.file_node[i] == no_node) continue;
            try by_content[id].append(self.scratch, @intCast(i));
        }

        for (by_content) |copies| {
            const items = copies.items;
            if (items.len < 2 or items.len > self.options.max_seed_copies) continue;

            for (items, 0..) |file_x, i| {
                for (items[i + 1 ..]) |file_y| {
                    var x = self.file_node[file_x];
                    var y = self.file_node[file_y];
                    while (x != no_node and y != no_node) {
                        if (x == y or self.isAncestor(x, y) or self.isAncestor(y, x)) break;

                        // Pairs inside VCS metadata earn no credit, but the
                        // climb goes on: matching objects under two `.git`
                        // directories are evidence for the *projects* above.
                        if (!self.nodes[x].in_vcs and !self.nodes[y].in_vcs) {
                            const key = PairKey.of(x, y);
                            if (support.getPtr(key)) |count| {
                                count.* += 1;
                            } else if (support.count() < self.options.max_candidate_pairs) {
                                try support.put(self.scratch, key, 1);
                            }
                        }

                        x = self.nodes[x].parent;
                        y = self.nodes[y].parent;
                    }
                }
            }
        }
    }

    /// Estimated share of the smaller directory that also exists in the other.
    fn estimate(self: *const Analyzer, key: PairKey, shared: u64) ?f64 {
        const smaller = @min(self.nodes[key.lo].file_count, self.nodes[key.hi].file_count);
        // A one-file directory "overlapping" another is just a duplicate file,
        // which the file-level groups already report.
        if (smaller < 2) return null;
        const ratio = @as(f64, @floatFromInt(shared)) / @as(f64, @floatFromInt(smaller));
        return @min(ratio, 1.0);
    }

    /// `key` with each side swapped for the representative of its identical
    /// set, where it has one. Falls back to `key` if that would pair a
    /// directory with its own ancestor (a twin of one side encloses the other).
    fn canonicalPair(self: *const Analyzer, key: PairKey) PairKey {
        const x = self.representativeOf(key.lo);
        const y = self.representativeOf(key.hi);
        if (x == y or self.isAncestor(x, y) or self.isAncestor(y, x)) return key;
        return PairKey.of(x, y);
    }

    fn representativeOf(self: *const Analyzer, id: NodeId) NodeId {
        const node = &self.nodes[id];
        if (!node.complete or node.file_count == 0) return id;
        const twins = self.twins.get(node.digest) orelse return id;
        return twins.representative;
    }

    fn identicalCopies(self: *const Analyzer, id: NodeId) u64 {
        const node = &self.nodes[id];
        if (!node.complete or node.file_count == 0) return 1;
        const twins = self.twins.get(node.digest) orelse return 1;
        return twins.count;
    }

    fn identical(self: *const Analyzer, key: PairKey) bool {
        const a = &self.nodes[key.lo];
        const b = &self.nodes[key.hi];
        // zig-lens-ignore: EQL-FOR-SECRETS content digests, not secrets
        return a.complete and b.complete and std.mem.eql(u8, &a.digest, &b.digest);
    }

    fn isAncestor(self: *const Analyzer, ancestor: NodeId, descendant: NodeId) bool {
        const parent = self.nodes[ancestor].path;
        const child = self.nodes[descendant].path;
        return child.len > parent.len + 1 and
            child[parent.len] == '/' and
            std.mem.startsWith(u8, child, parent);
    }

    /// Compare two subtrees by content. Returns null when, measured exactly,
    /// the pair falls below the reporting threshold.
    fn compareExact(self: *Analyzer, key: PairKey) !?Overlap {
        // A is whichever path sorts first, so output is stable across runs.
        const path_order = std.mem.order(u8, self.nodes[key.lo].path, self.nodes[key.hi].path);
        const id_a = if (path_order == .gt) key.hi else key.lo;
        const id_b = if (path_order == .gt) key.lo else key.hi;

        const node_a = &self.nodes[id_a];
        const node_b = &self.nodes[id_b];
        if (!node_a.spanIsExact() or !node_b.spanIsExact()) return null;

        self.pair_tag += 1;
        const tag = self.pair_tag;
        for (self.content_id[node_a.file_lo..node_a.file_hi]) |id| self.seen_a[id] = tag;
        for (self.content_id[node_b.file_lo..node_b.file_hi]) |id| self.seen_b[id] = tag;

        var side_a = try self.buildSide(id_a, self.seen_b, tag);
        var side_b = try self.buildSide(id_b, self.seen_a, tag);

        const share_a = share(side_a.shared_files, side_a.files);
        const share_b = share(side_b.shared_files, side_b.files);
        if (@max(share_a, share_b) < self.options.overlap_threshold) return null;
        if (@max(side_a.shared_files, side_b.shared_files) < self.options.min_shared_files) return null;

        // "Everything in X is also over there" is only a safe thing to say
        // about an X we could read all of.
        const a_contained = side_a.only_count == 0 and side_a.complete;
        const b_contained = side_b.only_count == 0 and side_b.complete;
        const relation: Relation = if (a_contained and b_contained)
            .same_content
        else if (a_contained)
            .a_in_b
        else if (b_contained)
            .b_in_a
        else
            .overlap;

        side_a.path = self.nodes[id_a].path;
        side_b.path = self.nodes[id_b].path;
        return .{ .relation = relation, .a = side_a, .b = side_b };
    }

    /// Keep `list` as the `max_only_listed` smallest paths seen, in order. The
    /// listed subset has to be deterministic (walk order is not), but sorting
    /// every unshared path of a large tree just to keep a hundred of them
    /// dominated the whole analysis. Nearly every path fails the single
    /// comparison against the current largest and costs nothing more.
    fn keepSmallest(self: *Analyzer, list: *std.ArrayListUnmanaged([]const u8), path: []const u8) !void {
        const limit = self.options.max_only_listed;
        if (limit == 0) return;
        if (list.items.len == limit) {
            if (std.mem.order(u8, path, list.items[limit - 1]) != .lt) return;
            _ = list.pop();
        }

        // Binary search for the insertion point.
        var lo: usize = 0;
        var hi: usize = list.items.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (std.mem.order(u8, list.items[mid], path) == .lt) lo = mid + 1 else hi = mid;
        }
        try list.insert(self.scratch, lo, path);
    }

    fn share(part: u64, whole: u64) f64 {
        if (whole == 0) return 0;
        return @as(f64, @floatFromInt(part)) / @as(f64, @floatFromInt(whole));
    }

    /// Describe one side of a pair. `other_seen[id] == tag` <=> the other side
    /// holds content `id`.
    fn buildSide(self: *Analyzer, id: NodeId, other_seen: []const u32, tag: u32) !OverlapSide {
        const node = &self.nodes[id];
        var side: OverlapSide = .{
            .path = node.path,
            .files = node.file_count,
            .bytes = node.bytes,
            .newest_mtime = node.newest_mtime,
            .skipped_entries = node.skipped,
            .complete = node.complete,
            .identical_copies = self.identicalCopies(id),
            .shared_files = 0,
            .shared_bytes = 0,
            .only_count = 0,
            .only = &.{},
        };

        const only = &self.only_scratch;
        only.clearRetainingCapacity();

        for (node.file_lo..node.file_hi) |file_index| {
            const entry = &self.files[file_index];
            if (other_seen[self.content_id[file_index]] == tag) {
                side.shared_files += 1;
                side.shared_bytes += entry.size;
            } else {
                side.only_count += 1;
                try self.keepSmallest(only, entry.path);
            }
        }

        side.only = try self.out.alloc([]const u8, only.items.len);
        for (only.items, side.only) |path, *slot| {
            slot.* = try self.out.dupe(u8, path);
        }
        return side;
    }
};

/// Parent directory of `path`, or null for a bare name or the filesystem root.
fn parentPath(path: []const u8) ?[]const u8 {
    const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return null;
    if (slash == 0) return if (path.len > 1) "/" else null;
    return path[0..slash];
}

fn baseName(path: []const u8) []const u8 {
    const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return path;
    return path[slash + 1 ..];
}

// ============================================================================
// Tests
// ============================================================================
//
// Unit tests for the pure helpers live here. Behaviour against real trees on
// disk — the part that decides what a user is told is safe to delete — is
// covered end to end in tier1_anchors.zig.

test "parentPath" {
    try std.testing.expectEqualStrings("/a/b", parentPath("/a/b/c").?);
    try std.testing.expectEqualStrings("/", parentPath("/a").?);
    try std.testing.expect(parentPath("/") == null);
    try std.testing.expect(parentPath("name") == null);
}

test "insideVcsDir" {
    try std.testing.expect(insideVcsDir("/home/u/proj/.git"));
    try std.testing.expect(insideVcsDir("/home/u/proj/.git/refs/heads"));
    try std.testing.expect(insideVcsDir("/srv/repo/.hg/store"));
    try std.testing.expect(!insideVcsDir("/home/u/proj"));
    try std.testing.expect(!insideVcsDir("/home/u/proj/src"));
    // A name that merely contains ".git" is an ordinary directory.
    try std.testing.expect(!insideVcsDir("/home/u/proj/.github/workflows"));
    try std.testing.expect(!insideVcsDir("/home/u/my.git.notes"));
}

test "baseName" {
    try std.testing.expectEqualStrings("c", baseName("/a/b/c"));
    try std.testing.expectEqualStrings("name", baseName("name"));
}

test "analyze with nothing recorded" {
    var analysis = try analyze(std.testing.allocator, &.{}, &.{}, &.{}, .blake3, .{});
    defer analysis.deinit();
    try std.testing.expectEqual(@as(usize, 0), analysis.identical_sets.len);
    try std.testing.expectEqual(@as(usize, 0), analysis.overlaps.len);
}
