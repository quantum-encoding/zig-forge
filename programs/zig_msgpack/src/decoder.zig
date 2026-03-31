//! MessagePack Decoder
//!
//! Decodes MessagePack binary format into Zig values.
//!
//! Example:
//! ```zig
//! const data = // ... msgpack bytes ...
//! var decoder = Decoder.init(data);
//!
//! const value = try decoder.read();
//! switch (value) {
//!     .string => |s| std.debug.print("String: {s}\n", .{s}),
//!     .uint => |n| std.debug.print("Number: {}\n", .{n}),
//!     // ...
//! }
//! ```

const std = @import("std");
const Format = @import("encoder.zig").Format;

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

/// Array iterator for lazy decoding
pub const ArrayIterator = struct {
    decoder: *Decoder,
    remaining: usize,

    pub fn next(self: *ArrayIterator) !?Value {
        if (self.remaining == 0) return null;
        self.remaining -= 1;
        return try self.decoder.read();
    }

    pub fn len(self: *const ArrayIterator) usize {
        return self.remaining;
    }
};

/// Map iterator for lazy decoding
pub const MapIterator = struct {
    decoder: *Decoder,
    remaining: usize,

    pub fn next(self: *MapIterator) !?struct { key: Value, value: Value } {
        if (self.remaining == 0) return null;
        self.remaining -= 1;
        const key = try self.decoder.read();
        const value = try self.decoder.read();
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

    const Self = @This();

    /// Initialize decoder with data
    pub fn init(data: []const u8) Self {
        return Self{
            .data = data,
            .pos = 0,
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

    /// Read multiple bytes
    fn readBytes(self: *Self, len: usize) ![]const u8 {
        if (self.pos + len > self.data.len) return error.UnexpectedEndOfData;
        const bytes = self.data[self.pos..][0..len];
        self.pos += len;
        return bytes;
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

    /// Read the next value
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
                break :blk Value{ .binary = try self.readBytes(len) };
            },
            Format.bin16 => blk: {
                const len = try self.readU16BE();
                break :blk Value{ .binary = try self.readBytes(len) };
            },
            Format.bin32 => blk: {
                const len = try self.readU32BE();
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
                break :blk Value{ .string = try self.readBytes(len) };
            },
            Format.str16 => blk: {
                const len = try self.readU16BE();
                break :blk Value{ .string = try self.readBytes(len) };
            },
            Format.str32 => blk: {
                const len = try self.readU32BE();
                break :blk Value{ .string = try self.readBytes(len) };
            },

            Format.array16 => Value{ .array = ArrayIterator{
                .decoder = self,
                .remaining = try self.readU16BE(),
            } },
            Format.array32 => Value{ .array = ArrayIterator{
                .decoder = self,
                .remaining = try self.readU32BE(),
            } },

            Format.map16 => Value{ .map = MapIterator{
                .decoder = self,
                .remaining = try self.readU16BE(),
            } },
            Format.map32 => Value{ .map = MapIterator{
                .decoder = self,
                .remaining = try self.readU32BE(),
            } },

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
                break :blk Value{ .ext = .{ .type_id = type_id, .data = try self.readBytes(len) } };
            },
            Format.ext16 => blk: {
                const len = try self.readU16BE();
                const type_id: i8 = @bitCast(try self.readByte());
                break :blk Value{ .ext = .{ .type_id = type_id, .data = try self.readBytes(len) } };
            },
            Format.ext32 => blk: {
                const len = try self.readU32BE();
                const type_id: i8 = @bitCast(try self.readByte());
                break :blk Value{ .ext = .{ .type_id = type_id, .data = try self.readBytes(len) } };
            },

            else => error.InvalidFormat,
        };
    }

    /// Skip the next value (useful for skipping unwanted values)
    pub fn skip(self: *Self) !void {
        const value = try self.read();
        switch (value) {
            .array => |arr| {
                var iter = arr;
                while (try iter.next()) |_| {}
            },
            .map => |m| {
                var iter = m;
                while (try iter.next()) |_| {}
            },
            else => {},
        }
    }

    /// Read and expect a specific type
    pub fn readString(self: *Self) ![]const u8 {
        const value = try self.read();
        return switch (value) {
            .string => |s| s,
            else => error.TypeMismatch,
        };
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
