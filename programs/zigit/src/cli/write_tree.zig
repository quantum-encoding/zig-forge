// `zigit write-tree`
//
// Builds a tree object from the staged index and prints its oid.
//
// The index stores entries as flat slash-separated paths
// ("a.txt", "sub/c.txt", "sub/deep/d.txt"). Trees are nested. To
// translate, we group entries by their first path component:
//
//   * Entries with no '/' become blob entries in the current tree.
//   * Entries with at least one '/' get pushed into a sub-bucket
//     keyed by the first component, with the leading prefix
//     stripped, then we recursively build that sub-tree.
//
// We materialise the bucket map as a HashMap keyed by component name
// — small repos so a flat structure is fine. Tree entries are always
// sorted with `lessThanForTree` before serialising.

const std = @import("std");
const Io = std.Io;
const File = Io.File;
const zigit = @import("zigit");

const TreeEntry = zigit.object.TreeEntry;

pub fn run(allocator: std.mem.Allocator, io: Io, args: []const []const u8) !void {
    if (args.len != 0) return error.WriteTreeTakesNoArgs;

    var repo = try zigit.Repository.discover(allocator, io);
    defer repo.deinit();

    var index = try zigit.Index.load(allocator, io, repo.git_dir);
    defer index.deinit();

    var store = repo.looseStore();

    // Adapt index entries into a flat list of (path, mode, oid)
    // tuples that buildTree can chew through.
    var staged: std.ArrayListUnmanaged(StagedFile) = .empty;
    defer staged.deinit(allocator);
    for (index.entries.items) |e| {
        try staged.append(allocator, .{ .path = e.path, .mode = e.mode, .oid = e.oid });
    }

    const root_oid = try buildTree(allocator, &store, staged.items);

    var hex: [40]u8 = undefined;
    root_oid.toHex(&hex);
    var line: [42]u8 = undefined;
    @memcpy(line[0..40], &hex);
    line[40] = '\n';
    try File.stdout().writeStreamingAll(io, line[0..41]);
}

const StagedFile = struct {
    path: []const u8,
    mode: u32,
    oid: zigit.Oid,
};

/// Recursively build a tree object from `entries` (paths are
/// relative to the current tree level). Writes every tree it
/// produces — including itself — to `store` and returns the root
/// tree's Oid.
fn buildTree(
    allocator: std.mem.Allocator,
    store: *zigit.LooseStore,
    entries: []const StagedFile,
) !zigit.Oid {
    // Bucket by first path component. Blobs (no '/') go straight
    // into `tree_entries`. Sub-buckets are recursed into; the
    // resulting subtree oid is what we add to `tree_entries`.
    var subdirs: std.StringArrayHashMapUnmanaged(std.ArrayListUnmanaged(StagedFile)) = .empty;
    defer {
        var it = subdirs.iterator();
        while (it.next()) |kv| kv.value_ptr.deinit(allocator);
        subdirs.deinit(allocator);
    }

    var tree_entries: std.ArrayListUnmanaged(TreeEntry) = .empty;
    defer tree_entries.deinit(allocator);

    for (entries) |se| {
        if (std.mem.indexOfScalar(u8, se.path, '/')) |slash| {
            const component = se.path[0..slash];
            const remainder = se.path[slash + 1 ..];

            const gop = try subdirs.getOrPut(allocator, component);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            try gop.value_ptr.append(allocator, .{
                .path = remainder,
                .mode = se.mode,
                .oid = se.oid,
            });
        } else {
            try tree_entries.append(allocator, .{
                .mode = se.mode,
                .name = se.path,
                .oid = se.oid,
            });
        }
    }

    // Recurse into each subdir and add its oid as a tree entry here.
    var it = subdirs.iterator();
    while (it.next()) |kv| {
        const sub_oid = try buildTree(allocator, store, kv.value_ptr.items);
        try tree_entries.append(allocator, .{
            .mode = zigit.object.tree.tree_mode_octal,
            .name = kv.key_ptr.*,
            .oid = sub_oid,
        });
    }

    std.mem.sort(TreeEntry, tree_entries.items, {}, zigit.object.tree.lessThanForTree);

    const payload = try zigit.object.tree.serialize(allocator, tree_entries.items);
    defer allocator.free(payload);

    const oid = zigit.object.computeOid(.tree, payload);
    try store.write(allocator, .tree, payload, oid);
    return oid;
}
