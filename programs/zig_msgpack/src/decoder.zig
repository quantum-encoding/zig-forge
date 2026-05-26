//! MessagePack Decoder
//!
//! Decodes MessagePack binary format into Zig values.
//!
//! ## Threat model
//!
//! This decoder is designed to consume **untrusted input** safely. The
//! following defenses are enforced:
//!
//!   * **Depth limit** (`max_depth`, default 512): the internal `skip()`
//!     traversal uses an explicit iterative work-stack capped at this many
//!     levels and errors with `MaxDepthExceeded` past it. External callers
//!     who walk the tree recursively MUST bound their own recursion using
//!     `max_depth` as the recommended cap — see README for examples.
//!   * **Overflow-safe length math**: every `pos + len` computation goes
//!     through `std.math.add(usize, ...)` so a hostile 32-bit-overflow does
//!     not bypass the bounds check.
//!   * **Eager bounds check**: if a `str` / `bin` / `ext` length header
//!     claims more bytes than remain in the buffer, the decoder errors
//!     immediately at the header, not after partial allocation.
//!   * **Iterator poisoning**: when an iterator's element read fails, the
//!     iterator is marked exhausted so subsequent `next()` calls return
//!     `null` cleanly rather than reading at corrupt byte offsets.
//!
//! ## Lifetime contract
//!
//! Returned `string`, `binary`, and `ext.data` slices are **zero-copy
//! borrows** into the original input buffer. The caller MUST keep that input
//! alive for as long as any `Value` they retain. See README.md for examples.
//!
//! ## Why depth tracking lives in `skip()` and not in the iterators
//!
//! The lazy `ArrayIterator` / `MapIterator` design returns iterator handles
//! from `read()` and relies on the caller to drain them. There is no
//! observable "all done with this iterator" hook (Zig has no destructors for
//! non-allocated structs), which means iterators cannot reliably decrement a
//! depth counter when their container ends — every attempt to do so either
//! over-counts (depth oscillates and the cap never fires) or under-counts
//! (sibling containers exhaust the budget).
//!
//! Instead, `skip()` — the only library-internal recursive consumer — is
//! implemented iteratively with an explicit stack capped at `max_depth`.
//! External callers that recursively walk Values are responsible for their
//! own depth budget; the recommended pattern (see README) bounds their
//! recursion by the same `max_depth` value.

const std = @import("std");
const Format = @import("encoder.zig").Format;

/// Default container-nesting limit. msgpack-c uses 512; we match.
pub const DEFAULT_MAX_DEPTH: u32 = 512;

/// Decoded MessagePack value
pub const Value = union(enum) {
    nil,
    bool: bool,
    uint: u64,
    int: i64,
    float32: f32,
    float64: f64,
    string: []const u8,
    binary: []const u8,
    array: ArrayIterator,
    map: MapIterator,
    ext: Extension,
};

/// Extension type
pub const Extension = struct {
    type_id: i8,
    data: []const u8,
};

/// Array iterator for lazy decoding.
///
/// On any error from an element read, the iterator is **poisoned** —
/// `remaining` is forced to 0 so a subsequent `next()` returns `null`
/// cleanly. This prevents the decoder from reading at corrupt byte offsets
/// after a partial element failure.
pub const ArrayIterator = struct {
    decoder: *Decoder,
    remaining: usize,

    pub fn next(self: *ArrayIterator) !?Value {
        if (self.remaining == 0) return null;
        const value = self.decoder.read() catch |err| {
            // Poison the iterator so the caller can't accidentally drive
            // further reads at a corrupted position.
            self.remaining = 0;
            return err;
        };
        self.remaining -= 1;
        return value;
    }

    pub fn len(self: *const ArrayIterator) usize {
        return self.remaining;
    }
};

/// Map iterator for lazy decoding.
///
/// `next()` consumes a key+value pair **atomically**: the `remaining`
/// counter only decrements after both the key read AND the value read
/// succeed. If either read errors, the iterator is poisoned (`remaining`
/// set to 0) so further calls return `null` cleanly rather than reading at
/// corrupt offsets.
pub const MapIterator = struct {
    decoder: *Decoder,
    remaining: usize,

    pub fn next(self: *MapIterator) !?struct { key: Value, value: Value } {
        if (self.remaining == 0) return null;

        const key = self.decoder.read() catch |err| {
            self.remaining = 0;
            return err;
        };
        const value = self.decoder.read() catch |err| {
            self.remaining = 0;
            return err;
        };
        self.remaining -= 1;
        return .{ .key = key, .value = value };
    }

    pub fn len(self: *const MapIterator) usize {
        return self.remaining;
    }
};

/// MessagePack Decoder
pub const Decoder = struct {
    data: []const u8,
    pos: usize,

    /// Maximum allowed container nesting depth used by `skip()` and
    /// recommended as the cap for any external recursive walker. Default
    /// `DEFAULT_MAX_DEPTH` (512). Callers can override before parsing.
    max_depth: u32,

    const Self = @This();

    /// Initialize decoder with data
    pub fn init(data: []const u8) Self {
        return Self{
            .data = data,
            .pos = 0,
            .max_depth = DEFAULT_MAX_DEPTH,
        };
    }

    /// Check if more data is available
    pub fn hasMore(self: *const Self) bool {
        return self.pos < self.data.len;
    }

    /// Get remaining bytes
    pub fn remaining(self: *const Self) usize {
        return self.data.len - self.pos;
    }

    /// Read a single byte
    fn readByte(self: *Self) !u8 {
        if (self.pos >= self.data.len) return error.UnexpectedEndOfData;
        const byte = self.data[self.pos];
        self.pos += 1;
        return byte;
    }

    /// Read multiple bytes.
    ///
    /// Uses `std.math.add` so a hostile length value cannot overflow the
    /// bounds check on 32-bit platforms (where `usize` is u32 and a u32
    /// length prefix plus `pos` can wrap).
    fn readBytes(self: *Self, len: usize) ![]const u8 {
        const end = std.math.add(usize, self.pos, len) catch return error.UnexpectedEndOfData;
        if (end > self.data.len) return error.UnexpectedEndOfData;
        const bytes = self.data[self.pos..end];
        self.pos = end;
        return bytes;
    }

    /// Eagerly reject a header that claims more bytes than physically remain
    /// in the input. Called immediately after reading a `str` / `bin` / `ext`
    /// length prefix so the failure surfaces at the header, not after a
    /// partial allocation.
    fn ensureCanRead(self: *const Self, len: usize) !void {
        if (len > self.remaining()) return error.UnexpectedEndOfData;
    }

    /// Read big-endian u16
    fn readU16BE(self: *Self) !u16 {
        const bytes = try self.readBytes(2);
        return std.mem.readInt(u16, bytes[0..2], .big);
    }

    /// Read big-endian u32
    fn readU32BE(self: *Self) !u32 {
        const bytes = try self.readBytes(4);
        return std.mem.readInt(u32, bytes[0..4], .big);
    }

    /// Read big-endian u64
    fn readU64BE(self: *Self) !u64 {
        const bytes = try self.readBytes(8);
        return std.mem.readInt(u64, bytes[0..8], .big);
    }

    /// Read big-endian i16
    fn readI16BE(self: *Self) !i16 {
        const bytes = try self.readBytes(2);
        return std.mem.readInt(i16, bytes[0..2], .big);
    }

    /// Read big-endian i32
    fn readI32BE(self: *Self) !i32 {
        const bytes = try self.readBytes(4);
        return std.mem.readInt(i32, bytes[0..4], .big);
    }

    /// Read big-endian i64
    fn readI64BE(self: *Self) !i64 {
        const bytes = try self.readBytes(8);
        return std.mem.readInt(i64, bytes[0..8], .big);
    }

    /// Read the next value.
    ///
    /// Returns array/map iterators without any per-read depth check — depth
    /// bounding lives in `skip()` for internal use, and external recursive
    /// walkers are responsible for their own depth budget (see the module
    /// docstring for why).
    pub fn read(self: *Self) !Value {
        const format = try self.readByte();

        // Positive fixint (0x00 - 0x7f)
        if (format <= 0x7f) {
            return Value{ .uint = format };
        }

        // Fixmap (0x80 - 0x8f)
        if (format >= 0x80 and format <= 0x8f) {
            const len = format & 0x0f;
            return Value{ .map = MapIterator{ .decoder = self, .remaining = len } };
        }

        // Fixarray (0x90 - 0x9f)
        if (format >= 0x90 and format <= 0x9f) {
            const len = format & 0x0f;
            return Value{ .array = ArrayIterator{ .decoder = self, .remaining = len } };
        }

        // Fixstr (0xa0 - 0xbf)
        if (format >= 0xa0 and format <= 0xbf) {
            const len = format & 0x1f;
            try self.ensureCanRead(len);
            return Value{ .string = try self.readBytes(len) };
        }

        // Negative fixint (0xe0 - 0xff)
        if (format >= 0xe0) {
            return Value{ .int = @as(i8, @bitCast(format)) };
        }

        // Other formats
        return switch (format) {
            Format.nil => Value.nil,
            Format.false_val => Value{ .bool = false },
            Format.true_val => Value{ .bool = true },

            Format.bin8 => blk: {
                const len = try self.readByte();
                try self.ensureCanRead(len);
                break :blk Value{ .binary = try self.readBytes(len) };
            },
            Format.bin16 => blk: {
                const len = try self.readU16BE();
                try self.ensureCanRead(len);
                break :blk Value{ .binary = try self.readBytes(len) };
            },
            Format.bin32 => blk: {
                const len = try self.readU32BE();
                try self.ensureCanRead(len);
                break :blk Value{ .binary = try self.readBytes(len) };
            },

            Format.float32 => blk: {
                const bits = try self.readU32BE();
                break :blk Value{ .float32 = @bitCast(bits) };
            },
            Format.float64 => blk: {
                const bits = try self.readU64BE();
                break :blk Value{ .float64 = @bitCast(bits) };
            },

            Format.uint8 => Value{ .uint = try self.readByte() },
            Format.uint16 => Value{ .uint = try self.readU16BE() },
            Format.uint32 => Value{ .uint = try self.readU32BE() },
            Format.uint64 => Value{ .uint = try self.readU64BE() },

            Format.int8 => Value{ .int = @as(i8, @bitCast(try self.readByte())) },
            Format.int16 => Value{ .int = try self.readI16BE() },
            Format.int32 => Value{ .int = try self.readI32BE() },
            Format.int64 => Value{ .int = try self.readI64BE() },

            Format.str8 => blk: {
                const len = try self.readByte();
                try self.ensureCanRead(len);
                break :blk Value{ .string = try self.readBytes(len) };
            },
            Format.str16 => blk: {
                const len = try self.readU16BE();
                try self.ensureCanRead(len);
                break :blk Value{ .string = try self.readBytes(len) };
            },
            Format.str32 => blk: {
                const len = try self.readU32BE();
                try self.ensureCanRead(len);
                break :blk Value{ .string = try self.readBytes(len) };
            },

            Format.array16 => blk: {
                const len = try self.readU16BE();
                break :blk Value{ .array = ArrayIterator{ .decoder = self, .remaining = len } };
            },
            Format.array32 => blk: {
                const len = try self.readU32BE();
                break :blk Value{ .array = ArrayIterator{ .decoder = self, .remaining = len } };
            },

            Format.map16 => blk: {
                const len = try self.readU16BE();
                break :blk Value{ .map = MapIterator{ .decoder = self, .remaining = len } };
            },
            Format.map32 => blk: {
                const len = try self.readU32BE();
                break :blk Value{ .map = MapIterator{ .decoder = self, .remaining = len } };
            },

            Format.fixext1 => blk: {
                const type_id: i8 = @bitCast(try self.readByte());
                break :blk Value{ .ext = .{ .type_id = type_id, .data = try self.readBytes(1) } };
            },
            Format.fixext2 => blk: {
                const type_id: i8 = @bitCast(try self.readByte());
                break :blk Value{ .ext = .{ .type_id = type_id, .data = try self.readBytes(2) } };
            },
            Format.fixext4 => blk: {
                const type_id: i8 = @bitCast(try self.readByte());
                break :blk Value{ .ext = .{ .type_id = type_id, .data = try self.readBytes(4) } };
            },
            Format.fixext8 => blk: {
                const type_id: i8 = @bitCast(try self.readByte());
                break :blk Value{ .ext = .{ .type_id = type_id, .data = try self.readBytes(8) } };
            },
            Format.fixext16 => blk: {
                const type_id: i8 = @bitCast(try self.readByte());
                break :blk Value{ .ext = .{ .type_id = type_id, .data = try self.readBytes(16) } };
            },
            Format.ext8 => blk: {
                const len = try self.readByte();
                const type_id: i8 = @bitCast(try self.readByte());
                try self.ensureCanRead(len);
                break :blk Value{ .ext = .{ .type_id = type_id, .data = try self.readBytes(len) } };
            },
            Format.ext16 => blk: {
                const len = try self.readU16BE();
                const type_id: i8 = @bitCast(try self.readByte());
                try self.ensureCanRead(len);
                break :blk Value{ .ext = .{ .type_id = type_id, .data = try self.readBytes(len) } };
            },
            Format.ext32 => blk: {
                const len = try self.readU32BE();
                const type_id: i8 = @bitCast(try self.readByte());
                try self.ensureCanRead(len);
                break :blk Value{ .ext = .{ .type_id = type_id, .data = try self.readBytes(len) } };
            },

            else => error.InvalidFormat,
        };
    }

    /// Skip the next value, fully consuming any nested arrays or maps.
    ///
    /// Implemented iteratively with an explicit work stack capped at
    /// `max_depth` levels. A deeply-nested payload returns
    /// `error.MaxDepthExceeded` immediately rather than overflowing the
    /// stack — the previous recursive implementation could be crashed by
    /// a ~50KB hostile payload.
    ///
    /// Pre-audit bonus bug: the old `skip()` only drained the top level
    /// of containers — it called `iter.next()` and discarded values without
    /// recursing into them — so nested element bytes were left unread and
    /// the decoder position was wrong after skipping a nested structure.
    /// This version correctly drains every level.
    pub fn skip(self: *Self) !void {
        // Stack tracks "values still pending at this nesting level."
        // Each stack frame is one level deep, so size = max_depth.
        var stack_buf: [DEFAULT_MAX_DEPTH]usize = undefined;
        var stack_len: usize = 0;

        // Start with one value to consume: the root.
        var pending: usize = 1;

        while (pending > 0 or stack_len > 0) {
            if (pending == 0) {
                // Pop back to parent level.
                stack_len -= 1;
                pending = stack_buf[stack_len];
                continue;
            }

            pending -= 1;
            const value = try self.read();

            switch (value) {
                .array => |arr| {
                    if (arr.remaining == 0) continue; // empty container, nothing to drain
                    if (stack_len >= self.max_depth) return error.MaxDepthExceeded;
                    stack_buf[stack_len] = pending;
                    stack_len += 1;
                    pending = arr.remaining;
                },
                .map => |m| {
                    if (m.remaining == 0) continue;
                    if (stack_len >= self.max_depth) return error.MaxDepthExceeded;
                    stack_buf[stack_len] = pending;
                    stack_len += 1;
                    // A map of N entries has 2N values still to skip.
                    pending = m.remaining * 2;
                },
                else => {},
            }
        }
    }

    /// Read and expect a string. Returns the zero-copy slice into the input.
    /// Does **not** validate UTF-8 — use `readStringValidated` for that.
    pub fn readString(self: *Self) ![]const u8 {
        const value = try self.read();
        return switch (value) {
            .string => |s| s,
            else => error.TypeMismatch,
        };
    }

    /// Read and expect a string, additionally validating that it is
    /// well-formed UTF-8 per RFC 3629 (which the MessagePack spec mandates
    /// for the `str` family). Returns the slice unchanged on success; errors
    /// with `InvalidUtf8` if the bytes aren't valid UTF-8.
    ///
    /// Use this on any string that flows into UTF-8-aware downstream code
    /// (logging, display, hashing intended to match a UTF-8 implementation,
    /// etc.). Skip it only for strings you treat as opaque bytes.
    pub fn readStringValidated(self: *Self) ![]const u8 {
        const s = try self.readString();
        if (!std.unicode.utf8ValidateSlice(s)) return error.InvalidUtf8;
        return s;
    }

    pub fn readUint(self: *Self) !u64 {
        const value = try self.read();
        return switch (value) {
            .uint => |n| n,
            .int => |n| if (n >= 0) @intCast(n) else error.TypeMismatch,
            else => error.TypeMismatch,
        };
    }

    pub fn readInt(self: *Self) !i64 {
        const value = try self.read();
        return switch (value) {
            .int => |n| n,
            .uint => |n| if (n <= std.math.maxInt(i64)) @intCast(n) else error.TypeMismatch,
            else => error.TypeMismatch,
        };
    }

    pub fn readBool(self: *Self) !bool {
        const value = try self.read();
        return switch (value) {
            .bool => |b| b,
            else => error.TypeMismatch,
        };
    }
};

// ============================================================================
// Tests
// ============================================================================

test "decode nil" {
    var dec = Decoder.init(&[_]u8{0xc0});
    const value = try dec.read();
    try std.testing.expect(value == .nil);
}

test "decode bool" {
    var dec = Decoder.init(&[_]u8{ 0xc3, 0xc2 });
    try std.testing.expectEqual(true, (try dec.read()).bool);
    try std.testing.expectEqual(false, (try dec.read()).bool);
}

test "decode fixint" {
    var dec = Decoder.init(&[_]u8{ 0x00, 0x7f, 0xff, 0xe0 });
    try std.testing.expectEqual(@as(u64, 0), (try dec.read()).uint);
    try std.testing.expectEqual(@as(u64, 127), (try dec.read()).uint);
    try std.testing.expectEqual(@as(i64, -1), (try dec.read()).int);
    try std.testing.expectEqual(@as(i64, -32), (try dec.read()).int);
}

test "decode fixstr" {
    var dec = Decoder.init(&[_]u8{ 0xa5, 'h', 'e', 'l', 'l', 'o' });
    const value = try dec.read();
    try std.testing.expectEqualSlices(u8, "hello", value.string);
}

test "decode fixarray" {
    var dec = Decoder.init(&[_]u8{ 0x93, 0x01, 0x02, 0x03 });
    const value = try dec.read();
    var arr = value.array;
    try std.testing.expectEqual(@as(u64, 1), (try arr.next()).?.uint);
    try std.testing.expectEqual(@as(u64, 2), (try arr.next()).?.uint);
    try std.testing.expectEqual(@as(u64, 3), (try arr.next()).?.uint);
    try std.testing.expect((try arr.next()) == null);
}

test "decode fixmap" {
    var dec = Decoder.init(&[_]u8{ 0x81, 0xa3, 'k', 'e', 'y', 0xa3, 'v', 'a', 'l' });
    const value = try dec.read();
    var m = value.map;
    const entry = (try m.next()).?;
    try std.testing.expectEqualSlices(u8, "key", entry.key.string);
    try std.testing.expectEqualSlices(u8, "val", entry.value.string);
}

// ============================================================================
// Audit-driven hardening tests (DoS, overflow, length-sanity)
// ============================================================================

test "decoder: skip rejects deeply-nested arrays (DoS guard)" {
    // 50,000 levels of nested fixarrays-of-1 terminating in nil. The old
    // recursive skipValue would consume 50,000 Zig stack frames and crash
    // the process. The new iterative skip caps at max_depth = 512 and
    // returns MaxDepthExceeded.
    var buf: [60_000]u8 = undefined;
    const depth_attempt: usize = 50_000;
    for (0..depth_attempt) |i| buf[i] = 0x91;
    buf[depth_attempt] = 0xc0;

    var dec = Decoder.init(buf[0 .. depth_attempt + 1]);
    try std.testing.expectError(error.MaxDepthExceeded, dec.skip());
}

test "decoder: skip respects a tighter max_depth override" {
    // 6-deep nested array, max_depth=5 → error.
    var buf: [7]u8 = .{ 0x91, 0x91, 0x91, 0x91, 0x91, 0x91, 0xc0 };
    var dec = Decoder.init(&buf);
    dec.max_depth = 5;
    try std.testing.expectError(error.MaxDepthExceeded, dec.skip());
}

test "decoder: skip handles sibling containers at the same level fine" {
    // Outer array of 3 separate single-element arrays. Nesting depth is 2,
    // so a max_depth of 2 must allow this through (no decrement bookkeeping
    // bugs — the iterative stack pops between siblings).
    var buf: [7]u8 = .{ 0x93, 0x91, 0xc0, 0x91, 0xc0, 0x91, 0xc0 };
    var dec = Decoder.init(&buf);
    dec.max_depth = 2;
    try dec.skip();
    try std.testing.expectEqual(@as(usize, buf.len), dec.pos);
}

test "decoder: str8 with length exceeding remaining input fails fast" {
    // 0xd9 = str8; 0xff = claims 255 bytes; only 2 bytes follow.
    var buf: [4]u8 = .{ 0xd9, 0xff, 'a', 'b' };
    var dec = Decoder.init(&buf);
    try std.testing.expectError(error.UnexpectedEndOfData, dec.read());
}

test "decoder: bin32 with absurd length fails immediately at header" {
    // 0xc6 = bin32; length = 0xFFFFFFFF (4 GiB); buffer is 5 bytes total.
    var buf: [5]u8 = .{ 0xc6, 0xff, 0xff, 0xff, 0xff };
    var dec = Decoder.init(&buf);
    try std.testing.expectError(error.UnexpectedEndOfData, dec.read());
}

test "decoder: ext32 with absurd length fails immediately at header" {
    // 0xc9 = ext32; length = 0xFFFFFFFF; type byte = 0x42.
    var buf: [6]u8 = .{ 0xc9, 0xff, 0xff, 0xff, 0xff, 0x42 };
    var dec = Decoder.init(&buf);
    try std.testing.expectError(error.UnexpectedEndOfData, dec.read());
}

test "decoder: reserved opcode 0xc1 rejected" {
    var dec = Decoder.init(&[_]u8{0xc1});
    try std.testing.expectError(error.InvalidFormat, dec.read());
}

test "decoder: ArrayIterator poisons on element-read error" {
    // 0x92 = fixarray of 2 elements; first element is 0xc1 (invalid).
    var buf: [2]u8 = .{ 0x92, 0xc1 };
    var dec = Decoder.init(&buf);
    const v = try dec.read();
    var arr = v.array;

    // First next() should surface InvalidFormat AND poison the iterator.
    try std.testing.expectError(error.InvalidFormat, arr.next());
    // Iterator is now exhausted — further next() returns null, not another
    // error, and definitely doesn't read at a corrupted offset.
    try std.testing.expect((try arr.next()) == null);
    try std.testing.expectEqual(@as(usize, 0), arr.remaining);
}

test "decoder: MapIterator consumes key+value atomically" {
    // 0x82 = fixmap of 2 entries; first key reads OK ("k"), but then 0xc1
    // (reserved) appears where the value should be.
    var buf: [4]u8 = .{ 0x82, 0xa1, 'k', 0xc1 };
    var dec = Decoder.init(&buf);
    const v = try dec.read();
    var m = v.map;

    // The first call should surface InvalidFormat from the bad value read,
    // not silently consume an entry.
    try std.testing.expectError(error.InvalidFormat, m.next());
    // And the iterator must be poisoned afterwards.
    try std.testing.expect((try m.next()) == null);
    try std.testing.expectEqual(@as(usize, 0), m.remaining);
}

test "decoder: readStringValidated accepts valid UTF-8" {
    // "café" in UTF-8 = 63 61 66 c3 a9 — fixstr of 5 bytes.
    var buf: [6]u8 = .{ 0xa5, 0x63, 0x61, 0x66, 0xc3, 0xa9 };
    var dec = Decoder.init(&buf);
    const s = try dec.readStringValidated();
    try std.testing.expectEqualSlices(u8, "caf\xc3\xa9", s);
}

test "decoder: readStringValidated rejects invalid UTF-8" {
    // 0xa3 = fixstr of 3 bytes; 0xff 0xfe 0xfd are invalid UTF-8 bytes.
    var buf: [4]u8 = .{ 0xa3, 0xff, 0xfe, 0xfd };
    var dec = Decoder.init(&buf);
    try std.testing.expectError(error.InvalidUtf8, dec.readStringValidated());
}

test "decoder: skip fully drains nested containers (not just top level)" {
    // 0x91 0x91 0xc0 = array-of-1[ array-of-1[ nil ] ].
    // After skip(), the decoder position must be at end-of-buffer.
    // The pre-audit version only drained the outermost iterator, leaving
    // bytes unread.
    var buf: [3]u8 = .{ 0x91, 0x91, 0xc0 };
    var dec = Decoder.init(&buf);
    try dec.skip();
    try std.testing.expectEqual(@as(usize, 3), dec.pos);
    try std.testing.expect(!dec.hasMore());
}
