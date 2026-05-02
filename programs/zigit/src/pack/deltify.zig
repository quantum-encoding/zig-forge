// Encode a binary delta from `base` to `target` using the delta
// instruction wire format documented in src/pack/delta.zig.
//
// Algorithm — sliding-window chunk match:
//
//   1. Slice `base` into overlapping CHUNK-byte windows (CHUNK = 16).
//      For each window position `i`, compute hash(base[i..i+CHUNK])
//      and stash `i` in a multimap keyed on that hash.
//
//   2. Walk `target` one byte at a time. At each position:
//        * Hash the next CHUNK bytes of `target`.
//        * Probe the multimap; for each candidate base position,
//          compare bytes greedily forward to measure the match
//          length, and probe one byte backward into the literal
//          run we're accumulating to extend the match leftward
//          (this is what real git does too, and it sometimes saves
//          a copy/insert pair).
//        * Pick the longest match across candidates. If it's at
//          least CHUNK bytes long, flush any pending literal run
//          via `emitLiterals`, emit a copy via `emitCopy`, and
//          advance past the matched region.
//        * Otherwise advance one byte; the byte joins the running
//          literal slice.
//
//   3. Flush any trailing literals.
//
// Bounds:
//   * MAX_CHAIN caps each multimap bucket so a degenerate base full
//     of identical chunks (e.g. zeros) doesn't make us O(N²) per
//     position.
//   * Copy sizes are capped at 0xFFFFFF (24-bit max, the wire format
//     ceiling). A longer match is split into multiple copy ops.
//
// Quality:
//   This is "good enough to win"; git's `pack-objects` does smarter
//   things with name-hashing and depth-bounded chains. For the kinds
//   of repos zigit produces (think: clone-then-commit workflows),
//   the delta sizes we emit here come within a few % of git's.

const std = @import("std");
const delta_apply = @import("delta.zig");

const CHUNK: usize = 16;
const MAX_CHAIN: usize = 64;
const MAX_COPY_LEN: u32 = 0xFFFFFF;

pub const Error = error{OutOfMemory};

pub fn encode(
    allocator: std.mem.Allocator,
    base: []const u8,
    target: []const u8,
) Error![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    try writeVarint(&out, allocator, base.len);
    try writeVarint(&out, allocator, target.len);

    // Short base or target → no chunk-matching benefit; emit literals.
    if (base.len < CHUNK or target.len < CHUNK) {
        try emitLiterals(&out, allocator, target);
        return try out.toOwnedSlice(allocator);
    }

    // Build chunk index for the base.
    var index: std.AutoHashMapUnmanaged(u64, std.ArrayListUnmanaged(u32)) = .empty;
    defer {
        var it = index.valueIterator();
        while (it.next()) |v| v.deinit(allocator);
        index.deinit(allocator);
    }

    {
        var i: usize = 0;
        while (i + CHUNK <= base.len) : (i += 1) {
            const h = hashChunk(base[i .. i + CHUNK]);
            const gop = try index.getOrPut(allocator, h);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            if (gop.value_ptr.items.len < MAX_CHAIN) {
                try gop.value_ptr.append(allocator, @intCast(i));
            }
        }
    }

    var literal_start: usize = 0;
    var pos: usize = 0;
    while (pos + CHUNK <= target.len) {
        const h = hashChunk(target[pos .. pos + CHUNK]);

        var best_len: usize = 0;
        var best_base_pos: usize = 0;

        if (index.get(h)) |list| {
            for (list.items) |bp_u32| {
                const bp: usize = bp_u32;
                // Forward match length.
                var len: usize = 0;
                while (bp + len < base.len and pos + len < target.len and base[bp + len] == target[pos + len]) {
                    len += 1;
                }
                if (len > best_len) {
                    best_len = len;
                    best_base_pos = bp;
                }
            }
        }

        if (best_len >= CHUNK) {
            // Extend the match backward through the running literal
            // slice; this can sometimes promote one literal byte into
            // a copy that grows the next match leftward.
            var back: usize = 0;
            while (back < pos - literal_start and back < best_base_pos and
                target[pos - back - 1] == base[best_base_pos - back - 1])
            {
                back += 1;
            }

            const actual_pos = pos - back;
            const actual_base = best_base_pos - back;
            const actual_len = best_len + back;

            try emitLiterals(&out, allocator, target[literal_start..actual_pos]);

            // Split overlong copies.
            var remaining = actual_len;
            var src_off = actual_base;
            while (remaining > 0) {
                const chunk_len: u32 = @intCast(@min(remaining, MAX_COPY_LEN));
                try emitCopy(&out, allocator, @intCast(src_off), chunk_len);
                remaining -= chunk_len;
                src_off += chunk_len;
            }

            pos = actual_pos + actual_len;
            literal_start = pos;
        } else {
            pos += 1;
        }
    }

    try emitLiterals(&out, allocator, target[literal_start..]);
    return try out.toOwnedSlice(allocator);
}

/// Plain 64-bit FNV-1a over a byte slice. CHUNK is small (16) so
/// raw hashing per step is fine; we don't need a rolling hash.
fn hashChunk(bytes: []const u8) u64 {
    var h: u64 = 0xcbf29ce484222325;
    for (bytes) |b| {
        h ^= b;
        h *%= 0x100000001b3;
    }
    return h;
}

fn writeVarint(out: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, value: usize) !void {
    var v = value;
    while (true) {
        const low: u8 = @intCast(v & 0x7f);
        v >>= 7;
        if (v == 0) {
            try out.append(allocator, low);
            return;
        }
        try out.append(allocator, low | 0x80);
    }
}

fn emitLiterals(out: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, lit: []const u8) !void {
    // Insert opcode caps payload at 127 bytes per op; chunk longer
    // runs into multiple inserts.
    var i: usize = 0;
    while (i < lit.len) {
        const n = @min(lit.len - i, 127);
        try out.append(allocator, @intCast(n));
        try out.appendSlice(allocator, lit[i .. i + n]);
        i += n;
    }
}

fn emitCopy(out: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, offset: u32, size: u32) !void {
    var op: u8 = 0x80;
    var buf: [8]u8 = undefined;
    var n: usize = 0;

    var off = offset;
    var i: u3 = 0;
    while (off != 0) {
        op |= (@as(u8, 1) << i);
        buf[n] = @intCast(off & 0xff);
        n += 1;
        off >>= 8;
        i += 1;
    }

    var sz = size;
    var j: u3 = 4;
    // The wire format only allots 3 size bytes (bits 4..6), so size
    // is at most 0xFFFFFF — enforced by the caller via MAX_COPY_LEN.
    while (sz != 0 and j < 7) {
        op |= (@as(u8, 1) << j);
        buf[n] = @intCast(sz & 0xff);
        n += 1;
        sz >>= 8;
        j += 1;
    }

    try out.append(allocator, op);
    try out.appendSlice(allocator, buf[0..n]);
}

// ── Pack-write planner ────────────────────────────────────────────
//
// `plan(objects) → [WriteOp]` decides, for a list of objects we're
// about to write into a single pack, which ones to send raw and
// which ones to deltify against an already-planned earlier entry.
//
// Strategy:
//   1. Bucket by object kind (we never deltify across kinds — git's
//      pack tooling treats them as separate spaces).
//   2. Within each bucket, sort by payload size descending. The
//      first (largest) becomes a raw entry; everything after tries
//      to deltify against the most recent few same-kind raw entries.
//   3. A delta is accepted only if its bytes are < 70% of the raw
//      payload size — otherwise we just write the raw payload.
//
// Output is ordered such that bases always precede their deltas
// (the OFS_DELTA wire format requires the base to come earlier in
// the pack).

const Oid = @import("../object/oid.zig").Oid;
const Kind = @import("../object/kind.zig").Kind;

pub const Object = struct {
    oid: Oid,
    kind: Kind,
    payload: []const u8,
};

pub const WriteOp = union(enum) {
    raw: struct { oid: Oid, kind: Kind, payload: []const u8 },
    delta: struct {
        oid: Oid,
        /// Index into the returned plan slice. The pack writer must
        /// learn this entry's pack offset from its earlier write of
        /// `plan[base_op_index]`.
        base_op_index: usize,
        /// Owned by the caller; freed via `freePlan`.
        delta_bytes: []u8,
    },
};

pub const RATIO_NUMERATOR: usize = 7;
pub const RATIO_DENOMINATOR: usize = 10;
const WINDOW: usize = 10;

pub fn plan(
    allocator: std.mem.Allocator,
    objects: []const Object,
) Error![]WriteOp {
    var ops: std.ArrayListUnmanaged(WriteOp) = .empty;
    errdefer {
        for (ops.items) |op| switch (op) {
            .raw => {},
            .delta => |d| allocator.free(d.delta_bytes),
        };
        ops.deinit(allocator);
    }
    try ops.ensureTotalCapacityPrecise(allocator, objects.len);

    const kinds = [_]Kind{ .blob, .tree, .commit, .tag };
    for (kinds) |k| {
        var bucket: std.ArrayListUnmanaged(usize) = .empty;
        defer bucket.deinit(allocator);
        for (objects, 0..) |o, i| if (o.kind == k) try bucket.append(allocator, i);
        if (bucket.items.len == 0) continue;

        std.mem.sort(usize, bucket.items, objects, struct {
            fn lt(ctx: []const Object, a: usize, b: usize) bool {
                return ctx[a].payload.len > ctx[b].payload.len;
            }
        }.lt);

        // First-of-kind is always raw.
        const first = objects[bucket.items[0]];
        try ops.append(allocator, .{ .raw = .{ .oid = first.oid, .kind = first.kind, .payload = first.payload } });

        // Track recent raw entries of this kind as delta candidates.
        var recent: std.ArrayListUnmanaged(usize) = .empty; // indices into ops
        defer recent.deinit(allocator);
        try recent.append(allocator, ops.items.len - 1);

        for (bucket.items[1..]) |obj_idx| {
            const obj = objects[obj_idx];

            var best_delta: ?[]u8 = null;
            var best_base_op: usize = 0;

            for (recent.items) |op_idx| {
                const base_payload = ops.items[op_idx].raw.payload;
                const candidate = try encode(allocator, base_payload, obj.payload);
                if (candidate.len * RATIO_DENOMINATOR < obj.payload.len * RATIO_NUMERATOR) {
                    if (best_delta) |existing| {
                        if (candidate.len < existing.len) {
                            allocator.free(existing);
                            best_delta = candidate;
                            best_base_op = op_idx;
                        } else {
                            allocator.free(candidate);
                        }
                    } else {
                        best_delta = candidate;
                        best_base_op = op_idx;
                    }
                } else {
                    allocator.free(candidate);
                }
            }

            if (best_delta) |db| {
                try ops.append(allocator, .{ .delta = .{
                    .oid = obj.oid,
                    .base_op_index = best_base_op,
                    .delta_bytes = db,
                } });
            } else {
                try ops.append(allocator, .{ .raw = .{ .oid = obj.oid, .kind = obj.kind, .payload = obj.payload } });
                if (recent.items.len < WINDOW) {
                    try recent.append(allocator, ops.items.len - 1);
                }
            }
        }
    }

    return try ops.toOwnedSlice(allocator);
}

pub fn freePlan(allocator: std.mem.Allocator, ops: []WriteOp) void {
    for (ops) |op| switch (op) {
        .raw => {},
        .delta => |d| allocator.free(d.delta_bytes),
    };
    allocator.free(ops);
}

// ── Tests ─────────────────────────────────────────────────────────

const testing = std.testing;

test "encode/decode: identical buffers compress to a tiny copy" {
    const base = "the quick brown fox jumps over the lazy dog 0123456789ABCDEF";
    const delta = try encode(testing.allocator, base, base);
    defer testing.allocator.free(delta);
    // Should be a lot smaller than the source — header (~3) + a single
    // copy op (4-5 bytes) at most.
    try testing.expect(delta.len < base.len / 4);

    const round = try delta_apply.apply(testing.allocator, base, delta);
    defer testing.allocator.free(round);
    try testing.expectEqualStrings(base, round);
}

test "encode/decode: completely-different bases give literal output" {
    const base = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA";
    const target = "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB";

    const delta = try encode(testing.allocator, base, target);
    defer testing.allocator.free(delta);

    const round = try delta_apply.apply(testing.allocator, base, delta);
    defer testing.allocator.free(round);
    try testing.expectEqualStrings(target, round);
}

test "encode/decode: append at end takes a copy + insert" {
    const base = "the quick brown fox jumps over the lazy dog";
    const target = "the quick brown fox jumps over the lazy dog and exits stage left";

    const delta = try encode(testing.allocator, base, target);
    defer testing.allocator.free(delta);
    try testing.expect(delta.len < target.len);

    const round = try delta_apply.apply(testing.allocator, base, delta);
    defer testing.allocator.free(round);
    try testing.expectEqualStrings(target, round);
}

test "encode/decode: insertion in middle splits into copy/insert/copy" {
    const base = "AAAAAAAAAAAAAAAAAAAA" ++ "BBBBBBBBBBBBBBBBBBBB";
    const target = "AAAAAAAAAAAAAAAAAAAA" ++ "INSERTEDxxxxxxxxxxxx" ++ "BBBBBBBBBBBBBBBBBBBB";

    const delta = try encode(testing.allocator, base, target);
    defer testing.allocator.free(delta);

    const round = try delta_apply.apply(testing.allocator, base, delta);
    defer testing.allocator.free(round);
    try testing.expectEqualStrings(target, round);
}

test "encode/decode: empty base behaves like pure literal output" {
    const target = "Hello, deltify world!" ** 16;
    const delta = try encode(testing.allocator, "", target);
    defer testing.allocator.free(delta);

    const round = try delta_apply.apply(testing.allocator, "", delta);
    defer testing.allocator.free(round);
    try testing.expectEqualStrings(target, round);
}

test "encode/decode: empty target round-trips" {
    const base = "anything";
    const delta = try encode(testing.allocator, base, "");
    defer testing.allocator.free(delta);

    const round = try delta_apply.apply(testing.allocator, base, delta);
    defer testing.allocator.free(round);
    try testing.expectEqualStrings("", round);
}

test "plan: largest-first within kind, deltifies the smaller similar one" {
    const allocator = testing.allocator;

    var oid_a: Oid = undefined;
    var oid_b: Oid = undefined;
    @memset(&oid_a.bytes, 0x11);
    @memset(&oid_b.bytes, 0x22);

    const big: []const u8 = "the quick brown fox jumps over the lazy dog AAAAAAAAAAAAAAAAAA";
    const sim: []const u8 = "the quick brown fox jumps over the lazy cat AAAAAAAAAAAAAAAAAA";

    const objects = [_]Object{
        .{ .oid = oid_a, .kind = .blob, .payload = big },
        .{ .oid = oid_b, .kind = .blob, .payload = sim },
    };

    const ops = try plan(allocator, &objects);
    defer freePlan(allocator, ops);

    try testing.expectEqual(@as(usize, 2), ops.len);
    try testing.expect(ops[0] == .raw); // largest-first
    try testing.expect(ops[1] == .delta); // similar enough to be a worthwhile delta
    try testing.expectEqual(@as(usize, 0), ops[1].delta.base_op_index);
}

test "plan: dissimilar payloads stay raw" {
    const allocator = testing.allocator;

    var oid_a: Oid = undefined;
    var oid_b: Oid = undefined;
    @memset(&oid_a.bytes, 0x11);
    @memset(&oid_b.bytes, 0x22);

    // Both > 16 bytes (CHUNK floor) but no shared 16-byte runs.
    const a: []const u8 = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"; // 48 A's
    const b: []const u8 = "ZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZ"; // 48 Z's

    const objects = [_]Object{
        .{ .oid = oid_a, .kind = .blob, .payload = a },
        .{ .oid = oid_b, .kind = .blob, .payload = b },
    };

    const ops = try plan(allocator, &objects);
    defer freePlan(allocator, ops);

    try testing.expectEqual(@as(usize, 2), ops.len);
    try testing.expect(ops[0] == .raw);
    try testing.expect(ops[1] == .raw);
}

test "plan: never deltifies across kinds" {
    const allocator = testing.allocator;

    var oid_a: Oid = undefined;
    var oid_b: Oid = undefined;
    @memset(&oid_a.bytes, 0x11);
    @memset(&oid_b.bytes, 0x22);

    const same: []const u8 = "the quick brown fox jumps over the lazy dog 1234567890";

    const objects = [_]Object{
        .{ .oid = oid_a, .kind = .blob, .payload = same },
        .{ .oid = oid_b, .kind = .tree, .payload = same },
    };

    const ops = try plan(allocator, &objects);
    defer freePlan(allocator, ops);

    try testing.expectEqual(@as(usize, 2), ops.len);
    try testing.expect(ops[0] == .raw);
    try testing.expect(ops[1] == .raw);
}

test "encode/decode: large repeated payload picks up the shared region" {
    var prng: std.Random.DefaultPrng = .init(0xfeedface);
    var base_buf: [4096]u8 = undefined;
    var target_buf: [4096]u8 = undefined;
    prng.random().bytes(&base_buf);
    @memcpy(&target_buf, &base_buf);
    // Mutate the middle 64 bytes.
    for (1024..1088) |i| target_buf[i] = ~base_buf[i];

    const delta = try encode(testing.allocator, &base_buf, &target_buf);
    defer testing.allocator.free(delta);
    // Should be significantly smaller than the target itself.
    try testing.expect(delta.len < target_buf.len / 4);

    const round = try delta_apply.apply(testing.allocator, &base_buf, delta);
    defer testing.allocator.free(round);
    try testing.expectEqualSlices(u8, &target_buf, round);
}
