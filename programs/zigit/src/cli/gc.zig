// `zigit gc`
//
// Collapse loose storage into a single new pack + a single
// packed-refs file, then delete the originals.
//
// Workflow:
//   1. Walk .git/objects/ab/ directories → collect every loose oid.
//   2. Read each loose object → (kind, payload).
//   3. Sort by oid (the .idx must be sorted; PackWriter records in
//      add-order so we sort the (kind, payload, oid) tuple list once
//      up front and emit objects in oid order).
//   4. Build the pack via PackWriter.
//   5. Build the .idx via idx_writer (sorted entries).
//   6. Write pack-<sha>.{pack,idx} into .git/objects/pack/.
//   7. Walk refs/heads/* and refs/tags/*, gather (full-name, oid).
//   8. Write packed-refs (merging with any existing entries — though
//      typical workflows hit gc on a clean repo, so the simple
//      overwrite-from-loose approach is what we ship).
//   9. Delete the loose object files (and now-empty ab/ dirs).
//   10. Delete the loose ref files (keep refs/heads/ + refs/tags/).
//
// We skip cleanly when there are zero loose objects.

const std = @import("std");
const Io = std.Io;
const File = Io.File;
const Dir = Io.Dir;
const zigit = @import("zigit");

const heads_dir = "refs/heads";
const tags_dir = "refs/tags";

const StagedObject = struct {
    oid: zigit.Oid,
    kind: zigit.Kind,
    /// Owned by the gc allocator until the pack is built.
    payload: []u8,
};

const RefRow = struct {
    /// Full ref name like "refs/heads/main"; owned.
    name: []u8,
    /// 40-char hex of the oid the ref points at.
    oid_hex: [40]u8,
};

pub fn run(allocator: std.mem.Allocator, io: Io, args: []const []const u8) !void {
    if (args.len != 0) return error.GcTakesNoArgs;

    var repo = try zigit.Repository.discover(allocator, io);
    defer repo.deinit();

    // ── 1. Enumerate loose objects ────────────────────────────────────
    var staged: std.ArrayListUnmanaged(StagedObject) = .empty;
    defer {
        for (staged.items) |s| allocator.free(s.payload);
        staged.deinit(allocator);
    }

    try collectLooseObjects(allocator, io, repo.objects_dir, &staged);

    if (staged.items.len == 0) {
        try File.stdout().writeStreamingAll(io, "Nothing to repack.\n");
        // Even with zero loose objects, run the ref-packing pass so
        // gc-on-clean still consolidates refs.
        try packRefsAndDeleteLooseRefs(allocator, io, repo.git_dir);
        return;
    }

    // ── 2. Sort by oid for the pack/idx ───────────────────────────────
    std.mem.sort(StagedObject, staged.items, {}, struct {
        fn lt(_: void, a: StagedObject, b: StagedObject) bool {
            return std.mem.order(u8, &a.oid.bytes, &b.oid.bytes) == .lt;
        }
    }.lt);

    // ── 3. Build the pack ─────────────────────────────────────────────
    var pack_w = try zigit.pack.PackWriter.init(allocator, @intCast(staged.items.len));
    defer pack_w.deinit();

    var entries: std.ArrayListUnmanaged(zigit.pack.PackEntry) = .empty;
    defer entries.deinit(allocator);
    try entries.ensureTotalCapacityPrecise(allocator, staged.items.len);
    for (staged.items) |obj| {
        const e = try pack_w.addObject(obj.oid, obj.kind, obj.payload);
        entries.appendAssumeCapacity(e);
    }
    const finished = try pack_w.finish();
    defer allocator.free(finished.pack_bytes);

    // ── 4. Build the idx ──────────────────────────────────────────────
    const idx_bytes = try zigit.pack.idx_writer.build(allocator, entries.items, finished.pack_oid);
    defer allocator.free(idx_bytes);

    // ── 5. Write pack-<sha>.{pack,idx} ────────────────────────────────
    var pack_oid_hex: [40]u8 = undefined;
    finished.pack_oid.toHex(&pack_oid_hex);

    try repo.objects_dir.createDirPath(io, "pack");
    var pack_dir = try repo.objects_dir.openDir(io, "pack", .{});
    defer pack_dir.close(io);

    var name_buf: [64]u8 = undefined;
    const pack_name = try std.fmt.bufPrint(&name_buf, "pack-{s}.pack", .{pack_oid_hex[0..40]});
    try pack_dir.writeFile(io, .{ .sub_path = pack_name, .data = finished.pack_bytes });

    var name_buf2: [64]u8 = undefined;
    const idx_name = try std.fmt.bufPrint(&name_buf2, "pack-{s}.idx", .{pack_oid_hex[0..40]});
    try pack_dir.writeFile(io, .{ .sub_path = idx_name, .data = idx_bytes });

    // ── 6. Pack refs (merge with existing packed-refs + delete loose) ─
    try packRefsAndDeleteLooseRefs(allocator, io, repo.git_dir);

    // ── 7. Delete loose objects ───────────────────────────────────────
    try deleteLooseObjects(allocator, io, repo.objects_dir, staged.items);

    var msg_buf: [256]u8 = undefined;
    const msg = try std.fmt.bufPrint(
        &msg_buf,
        "Packed {d} objects → {s}\n",
        .{ staged.items.len, pack_name },
    );
    try File.stdout().writeStreamingAll(io, msg);
}

fn collectLooseObjects(
    allocator: std.mem.Allocator,
    io: Io,
    objects_dir: Dir,
    out: *std.ArrayListUnmanaged(StagedObject),
) !void {
    var top = objects_dir.openDir(io, ".", .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer top.close(io);

    var top_it = top.iterate();
    while (try top_it.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        // ab/ dirs are exactly two lowercase hex chars. Skip pack/, info/, etc.
        if (entry.name.len != 2) continue;
        if (!isHex(entry.name[0]) or !isHex(entry.name[1])) continue;

        var sub = try objects_dir.openDir(io, entry.name, .{ .iterate = true });
        defer sub.close(io);

        var sub_it = sub.iterate();
        while (try sub_it.next(io)) |sub_entry| {
            if (sub_entry.kind != .file) continue;
            if (sub_entry.name.len != 38) continue;

            // Reconstruct full hex.
            var hex: [40]u8 = undefined;
            @memcpy(hex[0..2], entry.name);
            @memcpy(hex[2..], sub_entry.name);
            const oid = zigit.Oid.fromHex(&hex) catch continue;

            // Use a transient LooseStore (no pack fallback — we want
            // *only* the loose copy; ones already in packs shouldn't
            // be re-packed, and a pure loose lookup is the right path
            // for that semantic).
            var loose_only: zigit.LooseStore = .init(objects_dir, io);
            const loaded = try loose_only.read(allocator, oid);
            // Move ownership of payload into the staged tuple; clear
            // the LoadedObject's pointer so its deinit doesn't free.
            const payload = loaded.payload;

            try out.append(allocator, .{ .oid = oid, .kind = loaded.kind, .payload = payload });
        }
    }
}

fn deleteLooseObjects(
    allocator: std.mem.Allocator,
    io: Io,
    objects_dir: Dir,
    staged: []const StagedObject,
) !void {
    // Delete each file. After all files for a given ab/ dir are gone,
    // try to remove the ab/ directory itself; ignore ENOTEMPTY (other
    // process raced us) or already-missing.
    var dirs_seen: std.StringHashMapUnmanaged(void) = .empty;
    defer {
        var it = dirs_seen.keyIterator();
        while (it.next()) |k| allocator.free(k.*);
        dirs_seen.deinit(allocator);
    }

    for (staged) |s| {
        var hex: [40]u8 = undefined;
        s.oid.toHex(&hex);

        var path_buf: [50]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ hex[0..2], hex[2..] });
        objects_dir.deleteFile(io, path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };

        const dir_key = try allocator.dupe(u8, hex[0..2]);
        if ((try dirs_seen.getOrPut(allocator, dir_key)).found_existing) {
            allocator.free(dir_key);
        }
    }

    var dir_it = dirs_seen.keyIterator();
    while (dir_it.next()) |dir_name| {
        objects_dir.deleteDir(io, dir_name.*) catch |err| switch (err) {
            error.FileNotFound, error.DirNotEmpty => {},
            else => return err,
        };
    }
}

fn packRefsAndDeleteLooseRefs(allocator: std.mem.Allocator, io: Io, git_dir: Dir) !void {
    // Gather (full-name, oid) for every loose ref under refs/heads/ and refs/tags/.
    var entries: std.ArrayListUnmanaged(RefRow) = .empty;
    defer {
        for (entries.items) |e| allocator.free(e.name);
        entries.deinit(allocator);
    }

    try collectLooseRefs(allocator, io, git_dir, heads_dir, &entries);
    try collectLooseRefs(allocator, io, git_dir, tags_dir, &entries);

    if (entries.items.len == 0) return;

    // Stable order for the file (also what real git emits).
    std.mem.sort(RefRow, entries.items, {}, struct {
        fn lt(_: void, a: RefRow, b: RefRow) bool {
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.lt);

    // Merge with any existing packed-refs to preserve refs we didn't
    // re-discover (e.g. tags that were already packed).
    var existing: std.StringHashMapUnmanaged([]const u8) = .empty;
    defer existing.deinit(allocator);

    if (git_dir.readFileAlloc(io, "packed-refs", allocator, .unlimited)) |existing_bytes| {
        defer allocator.free(existing_bytes);
        var line_it = std.mem.splitScalar(u8, existing_bytes, '\n');
        while (line_it.next()) |line| {
            if (line.len == 0 or line[0] == '#' or line[0] == '^') continue;
            if (line.len < 42) continue;
            const space = std.mem.indexOfScalar(u8, line, ' ') orelse continue;
            if (space != 40) continue;
            const ref_name = std.mem.trimEnd(u8, line[space + 1 ..], " \r\t");
            // We don't merge yet — the new entries take precedence.
            // Stash the old payload only if no new entry covers it.
            try existing.put(allocator, ref_name, line[0..40]);
        }
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }

    var allocating: std.Io.Writer.Allocating = try .initCapacity(allocator, 4096);
    defer allocating.deinit();
    try allocating.writer.writeAll("# pack-refs with: peeled fully-peeled sorted \n");

    // Emit the new (loose-derived) entries first, marking which names
    // we covered so we don't re-emit from `existing`.
    var covered: std.StringHashMapUnmanaged(void) = .empty;
    defer covered.deinit(allocator);
    for (entries.items) |e| {
        try allocating.writer.print("{s} {s}\n", .{ e.oid_hex, e.name });
        try covered.put(allocator, e.name, {});
    }
    // Then any ref that's only in the existing packed-refs.
    var ex_it = existing.iterator();
    while (ex_it.next()) |kv| {
        if (covered.contains(kv.key_ptr.*)) continue;
        try allocating.writer.print("{s} {s}\n", .{ kv.value_ptr.*, kv.key_ptr.* });
    }

    try git_dir.writeFile(io, .{ .sub_path = "packed-refs.tmp", .data = allocating.written() });
    try git_dir.rename("packed-refs.tmp", git_dir, "packed-refs", io);

    // Delete loose ref files (we keep the refs/heads + refs/tags dirs).
    for (entries.items) |e| {
        git_dir.deleteFile(io, e.name) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
    }
}

fn collectLooseRefs(
    allocator: std.mem.Allocator,
    io: Io,
    git_dir: Dir,
    base: []const u8,
    out: *std.ArrayListUnmanaged(RefRow),
) !void {
    var dir = git_dir.openDir(io, base, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer dir.close(io);

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (std.mem.endsWith(u8, entry.name, ".lock")) continue;

        const full_name = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ base, entry.name });
        errdefer allocator.free(full_name);

        const v = zigit.refs.read(allocator, io, git_dir, full_name) catch |err| switch (err) {
            error.RefNotFound => continue,
            else => return err,
        };
        defer zigit.refs.deinitValue(allocator, v);
        switch (v) {
            .symbolic => continue, // packed-refs only stores direct refs
            .direct => |oid| {
                var hex: [40]u8 = undefined;
                oid.toHex(&hex);
                try out.append(allocator, .{ .name = full_name, .oid_hex = hex });
            },
        }
    }
}

fn isHex(c: u8) bool {
    return (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f');
}
