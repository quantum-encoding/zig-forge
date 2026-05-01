// Apply a binary delta from the pack format to a base buffer.
//
// Delta wire format:
//   varint: source size (LSB-first 7-bit, continuation bit 0x80)
//   varint: target size
//   instruction stream until input ends:
//     byte b:
//       if (b & 0x80)        — copy from base
//         offset bits set in low nibble of b (bits 0..3) say which
//         offset bytes follow (LSB-first); offset_bytes go to a
//         u32 offset starting at 0.
//         size bits set in high nibble of b (bits 4..6) say which
//         size bytes follow; size_bytes go to a u24 size starting at 0.
//         If size ends up zero, treat as 0x10000.
//         Copy `size` bytes from base[offset..offset+size] into output.
//       else if (b != 0)     — insert literal
//         Take the next b bytes from the delta stream, append to output.
//       else                 — reserved (b == 0)
//         Treat as an error; real git rejects too.

const std = @import("std");

pub fn apply(allocator: std.mem.Allocator, base: []const u8, delta: []const u8) ![]u8 {
    var cursor: usize = 0;

    const source_size = try readVarint(delta, &cursor);
    if (source_size != base.len) return error.DeltaSourceSizeMismatch;

    const target_size = try readVarint(delta, &cursor);
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.ensureTotalCapacityPrecise(allocator, @intCast(target_size));

    while (cursor < delta.len) {
        const b = delta[cursor];
        cursor += 1;

        if ((b & 0x80) != 0) {
            // Copy from base.
            var offset: u32 = 0;
            if ((b & 0x01) != 0) {
                offset |= @as(u32, delta[cursor]);
                cursor += 1;
            }
            if ((b & 0x02) != 0) {
                offset |= @as(u32, delta[cursor]) << 8;
                cursor += 1;
            }
            if ((b & 0x04) != 0) {
                offset |= @as(u32, delta[cursor]) << 16;
                cursor += 1;
            }
            if ((b & 0x08) != 0) {
                offset |= @as(u32, delta[cursor]) << 24;
                cursor += 1;
            }

            var size: u32 = 0;
            if ((b & 0x10) != 0) {
                size |= @as(u32, delta[cursor]);
                cursor += 1;
            }
            if ((b & 0x20) != 0) {
                size |= @as(u32, delta[cursor]) << 8;
                cursor += 1;
            }
            if ((b & 0x40) != 0) {
                size |= @as(u32, delta[cursor]) << 16;
                cursor += 1;
            }
            if (size == 0) size = 0x10000;

            if (@as(u64, offset) + size > base.len) return error.DeltaCopyOutOfBounds;
            try out.appendSlice(allocator, base[offset .. offset + size]);
        } else if (b != 0) {
            // Insert literal.
            const len: usize = b;
            if (cursor + len > delta.len) return error.DeltaInsertOverrun;
            try out.appendSlice(allocator, delta[cursor .. cursor + len]);
            cursor += len;
        } else {
            return error.DeltaReservedOpcode;
        }
    }

    if (out.items.len != target_size) return error.DeltaTargetSizeMismatch;
    return try out.toOwnedSlice(allocator);
}

/// Read a 7-bit-per-byte varint, LSB-first, continuation bit 0x80.
/// Advances `cursor` past the consumed bytes.
fn readVarint(bytes: []const u8, cursor: *usize) !u64 {
    var value: u64 = 0;
    var shift: u6 = 0;
    while (true) {
        if (cursor.* >= bytes.len) return error.UnexpectedEofInVarint;
        const b = bytes[cursor.*];
        cursor.* += 1;
        value |= (@as(u64, b) & 0x7f) << shift;
        if ((b & 0x80) == 0) return value;
        shift += 7;
        if (shift >= 64) return error.VarintTooLarge;
    }
}

const testing = std.testing;

test "apply: pure insert produces literal output" {
    // source size = 0, target size = 5, then `05 H E L L O`
    const delta = [_]u8{ 0, 5, 5, 'H', 'E', 'L', 'L', 'O' };
    const out = try apply(testing.allocator, "", &delta);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("HELLO", out);
}

test "apply: copy whole base" {
    const base = "abcdef";
    // source size = 6, target size = 6, copy with offset=0 size=6:
    //   instruction byte: 0x80 | 0x10 | 0x01 = 0x91 (offset bit 0, size bit 4)
    //   offset = 0x00, size = 0x06
    const delta = [_]u8{ 6, 6, 0x91, 0x00, 0x06 };
    const out = try apply(testing.allocator, base, &delta);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(base, out);
}

test "apply: copy + insert mix" {
    // base = "the quick", target = "the quick brown"
    const base = "the quick";
    // sizes
    var delta: std.ArrayListUnmanaged(u8) = .empty;
    defer delta.deinit(testing.allocator);
    try delta.append(testing.allocator, 9); // source size
    try delta.append(testing.allocator, 15); // target size
    // copy 9 bytes from base offset 0
    try delta.appendSlice(testing.allocator, &.{ 0x91, 0x00, 0x09 });
    // insert " brown" (6 bytes)
    try delta.append(testing.allocator, 6);
    try delta.appendSlice(testing.allocator, " brown");

    const out = try apply(testing.allocator, base, delta.items);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("the quick brown", out);
}

test "apply: rejects reserved opcode" {
    const delta = [_]u8{ 0, 1, 0x00 };
    try testing.expectError(error.DeltaReservedOpcode, apply(testing.allocator, "", &delta));
}
