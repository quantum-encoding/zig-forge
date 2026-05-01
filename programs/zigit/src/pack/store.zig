// PackStore — owns every (idx, pack) pair found in
// .git/objects/pack/ and resolves objects across them.
//
// We slurp each pack file into memory once at open time. Real git
// mmaps; for our scale (test repos, small clones) a heap copy is
// fine and avoids the platform-specific mmap dance. We can switch
// later if it ever matters.
//
// Object lookup tries each open pack until one's idx contains the
// target oid. On hit, we read the header at the recorded offset
// and follow OFS_DELTA / REF_DELTA chains until we land on a base
// of one of the four real object kinds.
//
// Delta chain depth is capped at `max_delta_depth` (50, matching
// real git) to defend against malicious or corrupted packs.

const std = @import("std");
const Io = std.Io;
const Dir = Io.Dir;
const idx_mod = @import("idx.zig");
const pack_mod = @import("pack.zig");
const delta_mod = @import("delta.zig");
const oid_mod = @import("../object/oid.zig");
const Oid = oid_mod.Oid;
const OidPrefix = oid_mod.OidPrefix;
const Kind = @import("../object/kind.zig").Kind;
const LoadedObject = @import("../object/loose_store.zig").LoadedObject;

pub const max_delta_depth: usize = 50;

/// Explicit error set so mutual recursion between read() and readAt()
/// (REF_DELTA bases can live in any pack — readAt → read) doesn't
/// trip Zig's inferred-error-set dependency check.
pub const ReadError = error{
    OutOfMemory,
    DeltaChainTooDeep,
    DeltaSourceSizeMismatch,
    DeltaTargetSizeMismatch,
    DeltaCopyOutOfBounds,
    DeltaInsertOverrun,
    DeltaReservedOpcode,
    UnexpectedEofInVarint,
    VarintTooLarge,
    OffsetOutOfRange,
    BadPackObjectType,
    UnexpectedEof,
    OfsDeltaOutOfRange,
    PayloadSizeMismatch,
    RefDeltaBaseMissing,
} || std.compress.flate.Decompress.Error || std.Io.Reader.Error;

pub const OpenPack = struct {
    /// Backing storage owned by the PackStore arena.
    pack_bytes: []const u8,
    idx_bytes: []const u8,
    pack: pack_mod.Pack,
    idx: idx_mod.Idx,
};

pub const PackStore = struct {
    arena: std.heap.ArenaAllocator,
    packs: []OpenPack,

    /// Open every pair of pack-XXX.{pack,idx} under `pack_dir`.
    /// `pack_dir` is `.git/objects/pack`. Returns an empty store if
    /// the directory is missing.
    pub fn open(allocator: std.mem.Allocator, io: Io, objects_dir: Dir) !PackStore {
        var arena: std.heap.ArenaAllocator = .init(allocator);
        errdefer arena.deinit();

        var pack_dir = objects_dir.openDir(io, "pack", .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => return .{ .arena = arena, .packs = &.{} },
            else => return err,
        };
        defer pack_dir.close(io);

        var packs: std.ArrayListUnmanaged(OpenPack) = .empty;
        errdefer packs.deinit(arena.allocator());

        var it = pack_dir.iterate();
        while (try it.next(io)) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, ".idx")) continue;

            const stem = entry.name[0 .. entry.name.len - 4];
            var pack_name_buf: [256]u8 = undefined;
            const pack_name = try std.fmt.bufPrint(&pack_name_buf, "{s}.pack", .{stem});

            const idx_bytes = try pack_dir.readFileAlloc(io, entry.name, arena.allocator(), .unlimited);
            const pack_bytes = try pack_dir.readFileAlloc(io, pack_name, arena.allocator(), .unlimited);

            const parsed_idx = try idx_mod.Idx.parse(idx_bytes);
            const parsed_pack = try pack_mod.Pack.parse(pack_bytes);
            try packs.append(arena.allocator(), .{
                .idx_bytes = idx_bytes,
                .pack_bytes = pack_bytes,
                .pack = parsed_pack,
                .idx = parsed_idx,
            });
        }

        return .{ .arena = arena, .packs = try packs.toOwnedSlice(arena.allocator()) };
    }

    pub fn deinit(self: *PackStore) void {
        self.arena.deinit();
        self.* = undefined;
    }

    /// Resolve `oid` to a fully-decoded LoadedObject, following any
    /// delta chain. Returns null if no pack contains the oid. Caller
    /// owns `payload` (allocated with `allocator`).
    pub fn read(self: *PackStore, allocator: std.mem.Allocator, oid: Oid) ReadError!?LoadedObject {
        for (self.packs) |op| {
            if (op.idx.findOffset(oid)) |offset| {
                return try self.readAt(allocator, op, offset, 0);
            }
        }
        return null;
    }

    /// Return any oid matching `prefix` across all packs. If multiple
    /// match (anywhere in any pack), `ambiguous` is set true.
    pub fn matchPrefix(self: *PackStore, prefix: OidPrefix, ambiguous: *bool) ?Oid {
        var found: ?Oid = null;
        for (self.packs) |op| {
            var local_amb = false;
            if (op.idx.matchPrefix(prefix, &local_amb)) |hit| {
                if (local_amb) {
                    ambiguous.* = true;
                    return hit;
                }
                if (found) |prev| {
                    if (!prev.eql(hit)) {
                        ambiguous.* = true;
                        return prev;
                    }
                } else {
                    found = hit;
                }
            }
        }
        return found;
    }

    /// Read the object at `offset` in `op.pack`, recursively
    /// resolving deltas. `depth` guards against malicious chains.
    fn readAt(
        self: *PackStore,
        allocator: std.mem.Allocator,
        op: OpenPack,
        offset: u64,
        depth: usize,
    ) ReadError!LoadedObject {
        if (depth > max_delta_depth) return error.DeltaChainTooDeep;

        const header = try op.pack.readHeader(offset);
        switch (header.kind) {
            .commit, .tree, .blob, .tag => {
                const payload = try op.pack.inflateAt(allocator, header.body_offset, header.payload_size);
                return .{
                    .kind = switch (header.kind) {
                        .commit => .commit,
                        .tree => .tree,
                        .blob => .blob,
                        .tag => .tag,
                        else => unreachable,
                    },
                    .payload = payload,
                };
            },
            .ofs_delta => {
                const ofs = try op.pack.readOfsDelta(header.body_offset, offset);
                const delta_bytes = try op.pack.inflateAt(allocator, ofs.payload_offset, header.payload_size);
                defer allocator.free(delta_bytes);

                var base = try self.readAt(allocator, op, ofs.base_offset, depth + 1);
                defer base.deinit(allocator);

                const reconstructed = try delta_mod.apply(allocator, base.payload, delta_bytes);
                return .{ .kind = base.kind, .payload = reconstructed };
            },
            .ref_delta => {
                const ref = try op.pack.readRefDelta(header.body_offset);
                const delta_bytes = try op.pack.inflateAt(allocator, ref.payload_offset, header.payload_size);
                defer allocator.free(delta_bytes);

                const base_oid: Oid = .{ .bytes = ref.base };
                var base = (try self.read(allocator, base_oid)) orelse return error.RefDeltaBaseMissing;
                defer base.deinit(allocator);

                const reconstructed = try delta_mod.apply(allocator, base.payload, delta_bytes);
                return .{ .kind = base.kind, .payload = reconstructed };
            },
        }
    }
};
