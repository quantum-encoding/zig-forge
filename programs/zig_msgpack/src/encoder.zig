//! MessagePack Encoder
//!
//! Encodes Zig values into MessagePack binary format.
//! Supports all MessagePack types: nil, bool, integers, floats, strings, binary, arrays, maps.
//!
//! Example:
//! ```zig
//! var buffer: [1024]u8 = undefined;
//! var encoder = Encoder.init(&buffer);
//!
//! try encoder.writeMap(2);
//! try encoder.writeString("name");
//! try encoder.writeString("Alice");
//! try encoder.writeString("age");
//! try encoder.writeInt(30);
//!
//! const data = encoder.getWritten();
//! ```

const std = @import("std");

/// MessagePack format markers
pub const Format = struct {
    // Positive fixint: 0x00 - 0x7f
    // Negative fixint: 0xe0 - 0xff
    // Fixmap: 0x80 - 0x8f
    // Fixarray: 0x90 - 0x9f
    // Fixstr: 0xa0 - 0xbf

    pub const nil: u8 = 0xc0;
    pub const never_used: u8 = 0xc1;
    pub const false_val: u8 = 0xc2;
    pub const true_val: u8 = 0xc3;

    pub const bin8: u8 = 0xc4;
    pub const bin16: u8 = 0xc5;
    pub const bin32: u8 = 0xc6;

    pub const ext8: u8 = 0xc7;
    pub const ext16: u8 = 0xc8;
    pub const ext32: u8 = 0xc9;

    pub const float32: u8 = 0xca;
    pub const float64: u8 = 0xcb;

    pub const uint8: u8 = 0xcc;
    pub const uint16: u8 = 0xcd;
    pub const uint32: u8 = 0xce;
    pub const uint64: u8 = 0xcf;

    pub const int8: u8 = 0xd0;
    pub const int16: u8 = 0xd1;
    pub const int32: u8 = 0xd2;
    pub const int64: u8 = 0xd3;

    pub const fixext1: u8 = 0xd4;
    pub const fixext2: u8 = 0xd5;
    pub const fixext4: u8 = 0xd6;
    pub const fixext8: u8 = 0xd7;
    pub const fixext16: u8 = 0xd8;

    pub const str8: u8 = 0xd9;
    pub const str16: u8 = 0xda;
    pub const str32: u8 = 0xdb;

    pub const array16: u8 = 0xdc;
    pub const array32: u8 = 0xdd;

    pub const map16: u8 = 0xde;
    pub const map32: u8 = 0xdf;
};

/// MessagePack Encoder
pub const Encoder = struct {
    buffer: []u8,
    pos: usize,

    const Self = @This();

    /// Initialize encoder with a buffer
    pub fn init(buffer: []u8) Self {
        return Self{
            .buffer = buffer,
            .pos = 0,
        };
    }

    /// Get the written portion of the buffer
    pub fn getWritten(self: *const Self) []const u8 {
        return self.buffer[0..self.pos];
    }

    /// Get remaining buffer capacity
    pub fn remaining(self: *const Self) usize {
        return self.buffer.len - self.pos;
    }

    /// Reset the encoder
    pub fn reset(self: *Self) void {
        self.pos = 0;
    }

    /// Write a single byte
    fn writeByte(self: *Self, byte: u8) !void {
        if (self.pos >= self.buffer.len) return error.BufferOverflow;
        self.buffer[self.pos] = byte;
        self.pos += 1;
    }

    /// Write multiple bytes
    fn writeBytes(self: *Self, bytes: []const u8) !void {
        if (self.pos + bytes.len > self.buffer.len) return error.BufferOverflow;
        @memcpy(self.buffer[self.pos..][0..bytes.len], bytes);
        self.pos += bytes.len;
    }

    /// Write big-endian u16
    fn writeU16BE(self: *Self, value: u16) !void {
        const bytes = std.mem.toBytes(std.mem.nativeToBig(u16, value));
        try self.writeBytes(&bytes);
    }

    /// Write big-endian u32
    fn writeU32BE(self: *Self, value: u32) !void {
        const bytes = std.mem.toBytes(std.mem.nativeToBig(u32, value));
        try self.writeBytes(&bytes);
    }

    /// Write big-endian u64
    fn writeU64BE(self: *Self, value: u64) !void {
        const bytes = std.mem.toBytes(std.mem.nativeToBig(u64, value));
        try self.writeBytes(&bytes);
    }

    /// Write nil
    pub fn writeNil(self: *Self) !void {
        try self.writeByte(Format.nil);
    }

    /// Write boolean
    pub fn writeBool(self: *Self, value: bool) !void {
        try self.writeByte(if (value) Format.true_val else Format.false_val);
    }

    /// Write unsigned integer
    pub fn writeUint(self: *Self, value: u64) !void {
        if (value <= 0x7f) {
            // Positive fixint
            try self.writeByte(@intCast(value));
        } else if (value <= 0xff) {
            try self.writeByte(Format.uint8);
            try self.writeByte(@intCast(value));
        } else if (value <= 0xffff) {
            try self.writeByte(Format.uint16);
            try self.writeU16BE(@intCast(value));
        } else if (value <= 0xffffffff) {
            try self.writeByte(Format.uint32);
            try self.writeU32BE(@intCast(value));
        } else {
            try self.writeByte(Format.uint64);
            try self.writeU64BE(value);
        }
    }

    /// Write signed integer
    pub fn writeInt(self: *Self, value: i64) !void {
        if (value >= 0) {
            try self.writeUint(@intCast(value));
        } else if (value >= -32) {
            // Negative fixint
            try self.writeByte(@bitCast(@as(i8, @intCast(value))));
        } else if (value >= -128) {
            try self.writeByte(Format.int8);
            try self.writeByte(@bitCast(@as(i8, @intCast(value))));
        } else if (value >= -32768) {
            try self.writeByte(Format.int16);
            const bytes = std.mem.toBytes(std.mem.nativeToBig(i16, @intCast(value)));
            try self.writeBytes(&bytes);
        } else if (value >= -2147483648) {
            try self.writeByte(Format.int32);
            const bytes = std.mem.toBytes(std.mem.nativeToBig(i32, @intCast(value)));
            try self.writeBytes(&bytes);
        } else {
            try self.writeByte(Format.int64);
            const bytes = std.mem.toBytes(std.mem.nativeToBig(i64, value));
            try self.writeBytes(&bytes);
        }
    }

    /// Write 32-bit float
    pub fn writeFloat32(self: *Self, value: f32) !void {
        try self.writeByte(Format.float32);
        const bits = @as(u32, @bitCast(value));
        try self.writeU32BE(bits);
    }

    /// Write 64-bit float
    pub fn writeFloat64(self: *Self, value: f64) !void {
        try self.writeByte(Format.float64);
        const bits = @as(u64, @bitCast(value));
        try self.writeU64BE(bits);
    }

    /// Write a float (automatically chooses precision)
    pub fn writeFloat(self: *Self, value: f64) !void {
        // Try f32 if it fits without loss
        const f32_val: f32 = @floatCast(value);
        if (@as(f64, f32_val) == value) {
            try self.writeFloat32(f32_val);
        } else {
            try self.writeFloat64(value);
        }
    }

    /// Write string
    pub fn writeString(self: *Self, str: []const u8) !void {
        const len = str.len;
        if (len <= 31) {
            // Fixstr
            try self.writeByte(0xa0 | @as(u8, @intCast(len)));
        } else if (len <= 0xff) {
            try self.writeByte(Format.str8);
            try self.writeByte(@intCast(len));
        } else if (len <= 0xffff) {
            try self.writeByte(Format.str16);
            try self.writeU16BE(@intCast(len));
        } else if (len <= 0xffffffff) {
            try self.writeByte(Format.str32);
            try self.writeU32BE(@intCast(len));
        } else {
            return error.StringTooLong;
        }
        try self.writeBytes(str);
    }

    /// Write binary data
    pub fn writeBinary(self: *Self, data: []const u8) !void {
        const len = data.len;
        if (len <= 0xff) {
            try self.writeByte(Format.bin8);
            try self.writeByte(@intCast(len));
        } else if (len <= 0xffff) {
            try self.writeByte(Format.bin16);
            try self.writeU16BE(@intCast(len));
        } else if (len <= 0xffffffff) {
            try self.writeByte(Format.bin32);
            try self.writeU32BE(@intCast(len));
        } else {
            return error.BinaryTooLong;
        }
        try self.writeBytes(data);
    }

    /// Write array header (caller must write array elements)
    pub fn writeArrayHeader(self: *Self, len: usize) !void {
        if (len <= 15) {
            // Fixarray
            try self.writeByte(0x90 | @as(u8, @intCast(len)));
        } else if (len <= 0xffff) {
            try self.writeByte(Format.array16);
            try self.writeU16BE(@intCast(len));
        } else if (len <= 0xffffffff) {
            try self.writeByte(Format.array32);
            try self.writeU32BE(@intCast(len));
        } else {
            return error.ArrayTooLong;
        }
    }

    /// Write map header (caller must write key-value pairs)
    pub fn writeMapHeader(self: *Self, len: usize) !void {
        if (len <= 15) {
            // Fixmap
            try self.writeByte(0x80 | @as(u8, @intCast(len)));
        } else if (len <= 0xffff) {
            try self.writeByte(Format.map16);
            try self.writeU16BE(@intCast(len));
        } else if (len <= 0xffffffff) {
            try self.writeByte(Format.map32);
            try self.writeU32BE(@intCast(len));
        } else {
            return error.MapTooLong;
        }
    }

    /// Write extension type
    pub fn writeExt(self: *Self, ext_type: i8, data: []const u8) !void {
        const len = data.len;
        switch (len) {
            1 => {
                try self.writeByte(Format.fixext1);
                try self.writeByte(@bitCast(ext_type));
            },
            2 => {
                try self.writeByte(Format.fixext2);
                try self.writeByte(@bitCast(ext_type));
            },
            4 => {
                try self.writeByte(Format.fixext4);
                try self.writeByte(@bitCast(ext_type));
            },
            8 => {
                try self.writeByte(Format.fixext8);
                try self.writeByte(@bitCast(ext_type));
            },
            16 => {
                try self.writeByte(Format.fixext16);
                try self.writeByte(@bitCast(ext_type));
            },
            else => {
                if (len <= 0xff) {
                    try self.writeByte(Format.ext8);
                    try self.writeByte(@intCast(len));
                } else if (len <= 0xffff) {
                    try self.writeByte(Format.ext16);
                    try self.writeU16BE(@intCast(len));
                } else if (len <= 0xffffffff) {
                    try self.writeByte(Format.ext32);
                    try self.writeU32BE(@intCast(len));
                } else {
                    return error.ExtTooLong;
                }
                try self.writeByte(@bitCast(ext_type));
            },
        }
        try self.writeBytes(data);
    }

    /// Write a timestamp extension (type -1)
    pub fn writeTimestamp(self: *Self, seconds: i64, nanoseconds: u32) !void {
        if (seconds >= 0 and seconds <= 0xffffffff and nanoseconds == 0) {
            // Timestamp 32
            var data: [4]u8 = undefined;
            std.mem.writeInt(u32, &data, @intCast(seconds), .big);
            try self.writeExt(-1, &data);
        } else if (seconds >= 0 and seconds <= 0x3ffffffff) {
            // Timestamp 64
            var data: [8]u8 = undefined;
            const val = (@as(u64, nanoseconds) << 34) | @as(u64, @intCast(seconds));
            std.mem.writeInt(u64, &data, val, .big);
            try self.writeExt(-1, &data);
        } else {
            // Timestamp 96
            var data: [12]u8 = undefined;
            std.mem.writeInt(u32, data[0..4], nanoseconds, .big);
            std.mem.writeInt(i64, data[4..12], seconds, .big);
            try self.writeExt(-1, &data);
        }
    }
};

// ============================================================================
// Tests
// ============================================================================

test "encode nil" {
    var buffer: [16]u8 = undefined;
    var enc = Encoder.init(&buffer);

    try enc.writeNil();
    try std.testing.expectEqualSlices(u8, &[_]u8{0xc0}, enc.getWritten());
}

test "encode bool" {
    var buffer: [16]u8 = undefined;
    var enc = Encoder.init(&buffer);

    try enc.writeBool(true);
    try enc.writeBool(false);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0xc3, 0xc2 }, enc.getWritten());
}

test "encode positive fixint" {
    var buffer: [16]u8 = undefined;
    var enc = Encoder.init(&buffer);

    try enc.writeUint(0);
    try enc.writeUint(127);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x00, 0x7f }, enc.getWritten());
}

test "encode negative fixint" {
    var buffer: [16]u8 = undefined;
    var enc = Encoder.init(&buffer);

    try enc.writeInt(-1);
    try enc.writeInt(-32);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0xff, 0xe0 }, enc.getWritten());
}

test "encode fixstr" {
    var buffer: [64]u8 = undefined;
    var enc = Encoder.init(&buffer);

    try enc.writeString("hello");
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0xa5, 'h', 'e', 'l', 'l', 'o' }, enc.getWritten());
}

test "encode fixarray" {
    var buffer: [64]u8 = undefined;
    var enc = Encoder.init(&buffer);

    try enc.writeArrayHeader(3);
    try enc.writeUint(1);
    try enc.writeUint(2);
    try enc.writeUint(3);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x93, 0x01, 0x02, 0x03 }, enc.getWritten());
}

test "encode fixmap" {
    var buffer: [64]u8 = undefined;
    var enc = Encoder.init(&buffer);

    try enc.writeMapHeader(1);
    try enc.writeString("key");
    try enc.writeString("val");
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x81, 0xa3, 'k', 'e', 'y', 0xa3, 'v', 'a', 'l' }, enc.getWritten());
}
