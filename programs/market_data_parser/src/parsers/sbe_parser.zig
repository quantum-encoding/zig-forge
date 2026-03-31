//! Simple Binary Encoding (SBE) Parser
//! Fixed-layout binary protocol used by CME, LSE, and other exchanges
//!
//! SBE Message Format:
//! - Header (8 bytes): block_length (u16), template_id (u16), schema_id (u16), version (u16)
//! - Body: fixed-size fields based on template
//! - Repeating groups: group_size_header + entries
//! - Variable data: length (u16) + data
//!
//! Performance: <50ns per field read (binary format advantage)

const std = @import("std");

/// SBE group entry header
pub const SbeGroupHeader = struct {
    block_length: u16,
    num_in_group: u16,
};

/// State for iterating through SBE repeating groups
pub const SbeGroup = struct {
    block_length: u16,
    num_in_group: u16,
    current: u16,
    decoder: *SbeDecoder,

    /// Check if there are more entries in the group
    pub fn next(self: *SbeGroup) bool {
        if (self.current < self.num_in_group) {
            self.current += 1;
            return true;
        }
        return false;
    }

    /// Get current entry index (0-based)
    pub fn currentIndex(self: *const SbeGroup) u16 {
        return self.current;
    }

    /// Skip to next entry
    pub fn skipEntry(self: *SbeGroup) !void {
        if (self.current >= self.num_in_group) return;
        try self.decoder.skipBytes(self.block_length);
    }
};

/// High-performance SBE decoder
/// Little-endian binary format
pub const SbeDecoder = struct {
    data: []const u8,
    pos: usize,

    // Header fields
    block_length: u16,
    template_id: u16,
    schema_id: u16,
    version: u16,

    /// Initialize decoder with raw binary data
    /// Reads and validates the 8-byte SBE header
    pub fn init(data: []const u8) !SbeDecoder {
        if (data.len < 8) return error.InvalidHeader;

        var decoder: SbeDecoder = undefined;
        decoder.data = data;
        decoder.pos = 0;

        // Read header (little-endian)
        decoder.block_length = decoder.readU16Little() catch 0;
        decoder.template_id = decoder.readU16Little() catch 0;
        decoder.schema_id = decoder.readU16Little() catch 0;
        decoder.version = decoder.readU16Little() catch 0;

        return decoder;
    }

    /// Read unsigned 8-bit integer
    pub fn readU8(self: *SbeDecoder) !u8 {
        if (self.pos >= self.data.len) return error.EndOfData;
        const value = self.data[self.pos];
        self.pos += 1;
        return value;
    }

    /// Read unsigned 16-bit integer (little-endian)
    pub fn readU16(self: *SbeDecoder) !u16 {
        return self.readU16Little();
    }

    fn readU16Little(self: *SbeDecoder) !u16 {
        if (self.pos + 1 >= self.data.len) return error.EndOfData;
        const value = std.mem.readInt(u16, self.data[self.pos .. self.pos + 2], .little);
        self.pos += 2;
        return value;
    }

    /// Read unsigned 32-bit integer (little-endian)
    pub fn readU32(self: *SbeDecoder) !u32 {
        if (self.pos + 3 >= self.data.len) return error.EndOfData;
        const value = std.mem.readInt(u32, self.data[self.pos .. self.pos + 4], .little);
        self.pos += 4;
        return value;
    }

    /// Read unsigned 64-bit integer (little-endian)
    pub fn readU64(self: *SbeDecoder) !u64 {
        if (self.pos + 7 >= self.data.len) return error.EndOfData;
        const value = std.mem.readInt(u64, self.data[self.pos .. self.pos + 8], .little);
        self.pos += 8;
        return value;
    }

    /// Read signed 32-bit integer (little-endian)
    pub fn readI32(self: *SbeDecoder) !i32 {
        if (self.pos + 3 >= self.data.len) return error.EndOfData;
        const value = std.mem.readInt(i32, self.data[self.pos .. self.pos + 4], .little);
        self.pos += 4;
        return value;
    }

    /// Read signed 64-bit integer (little-endian)
    pub fn readI64(self: *SbeDecoder) !i64 {
        if (self.pos + 7 >= self.data.len) return error.EndOfData;
        const value = std.mem.readInt(i64, self.data[self.pos .. self.pos + 8], .little);
        self.pos += 8;
        return value;
    }

    /// Read IEEE 754 float (little-endian)
    pub fn readF32(self: *SbeDecoder) !f32 {
        const bits = try self.readU32();
        return @bitCast(bits);
    }

    /// Read IEEE 754 double (little-endian)
    pub fn readF64(self: *SbeDecoder) !f64 {
        const bits = try self.readU64();
        return @bitCast(bits);
    }

    /// Read fixed-length string (null-padded or space-padded)
    /// Returns slice without trailing nulls/spaces
    pub fn readFixedString(self: *SbeDecoder, len: usize) ![]const u8 {
        if (self.pos + len > self.data.len) return error.EndOfData;

        var end = self.pos + len;
        // Trim trailing nulls and spaces
        while (end > self.pos) : (end -= 1) {
            const byte = self.data[end - 1];
            if (byte != 0 and byte != ' ') break;
        }

        const result = self.data[self.pos .. end];
        self.pos += len;
        return result;
    }

    /// Read variable-length data (length prefix of u16 + data)
    pub fn readVarData(self: *SbeDecoder) ![]const u8 {
        const length = try self.readU16();
        if (self.pos + length > self.data.len) return error.EndOfData;

        const result = self.data[self.pos .. self.pos + length];
        self.pos += length;
        return result;
    }

    /// Skip N bytes
    pub fn skipBytes(self: *SbeDecoder, count: usize) !void {
        if (self.pos + count > self.data.len) return error.EndOfData;
        self.pos += count;
    }

    /// Enter a repeating group
    /// Reads group size header (block_length u16, num_in_group u16)
    /// Call next() on the returned group to iterate
    pub fn enterGroup(self: *SbeDecoder) !SbeGroup {
        const block_length = try self.readU16();
        const num_in_group = try self.readU16();

        return SbeGroup{
            .block_length = block_length,
            .num_in_group = num_in_group,
            .current = 0,
            .decoder = self,
        };
    }

    /// Get current position in buffer
    pub fn getPosition(self: *const SbeDecoder) usize {
        return self.pos;
    }

    /// Set current position in buffer
    pub fn setPosition(self: *SbeDecoder, pos: usize) !void {
        if (pos > self.data.len) return error.InvalidPosition;
        self.pos = pos;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "sbe decoder - init header" {
    var buffer: [100]u8 = undefined;

    // Create a test message: block_length=10, template_id=1, schema_id=1, version=1
    std.mem.writeInt(u16, buffer[0..2], 10, .little);
    std.mem.writeInt(u16, buffer[2..4], 1, .little);
    std.mem.writeInt(u16, buffer[4..6], 1, .little);
    std.mem.writeInt(u16, buffer[6..8], 1, .little);

    const decoder = try SbeDecoder.init(&buffer);

    try std.testing.expectEqual(@as(u16, 10), decoder.block_length);
    try std.testing.expectEqual(@as(u16, 1), decoder.template_id);
    try std.testing.expectEqual(@as(u16, 1), decoder.schema_id);
    try std.testing.expectEqual(@as(u16, 1), decoder.version);
}

test "sbe decoder - read u8" {
    var buffer: [10]u8 = undefined;
    buffer[8] = 42; // Place after header

    var decoder = try SbeDecoder.init(&buffer);
    const value = try decoder.readU8();

    try std.testing.expectEqual(@as(u8, 42), value);
}

test "sbe decoder - read u16" {
    var buffer: [20]u8 = undefined;

    std.mem.writeInt(u16, buffer[8..10], 1000, .little);

    var decoder = try SbeDecoder.init(&buffer);
    const value = try decoder.readU16();

    try std.testing.expectEqual(@as(u16, 1000), value);
}

test "sbe decoder - read u32" {
    var buffer: [20]u8 = undefined;

    std.mem.writeInt(u32, buffer[8..12], 123456, .little);

    var decoder = try SbeDecoder.init(&buffer);
    const value = try decoder.readU32();

    try std.testing.expectEqual(@as(u32, 123456), value);
}

test "sbe decoder - read u64" {
    var buffer: [20]u8 = undefined;

    std.mem.writeInt(u64, buffer[8..16], 9876543210, .little);

    var decoder = try SbeDecoder.init(&buffer);
    const value = try decoder.readU64();

    try std.testing.expectEqual(@as(u64, 9876543210), value);
}

test "sbe decoder - read i32" {
    var buffer: [20]u8 = undefined;

    std.mem.writeInt(i32, buffer[8..12], -12345, .little);

    var decoder = try SbeDecoder.init(&buffer);
    const value = try decoder.readI32();

    try std.testing.expectEqual(@as(i32, -12345), value);
}

test "sbe decoder - read i64" {
    var buffer: [20]u8 = undefined;

    std.mem.writeInt(i64, buffer[8..16], -9876543210, .little);

    var decoder = try SbeDecoder.init(&buffer);
    const value = try decoder.readI64();

    try std.testing.expectEqual(@as(i64, -9876543210), value);
}

test "sbe decoder - read f32" {
    var buffer: [20]u8 = undefined;

    const float_val: f32 = 123.456;
    std.mem.writeInt(u32, buffer[8..12], @bitCast(float_val), .little);

    var decoder = try SbeDecoder.init(&buffer);
    const value = try decoder.readF32();

    try std.testing.expectApproxEqAbs(123.456, value, 0.001);
}

test "sbe decoder - read f64" {
    var buffer: [20]u8 = undefined;

    const double_val: f64 = 123.456789;
    std.mem.writeInt(u64, buffer[8..16], @bitCast(double_val), .little);

    var decoder = try SbeDecoder.init(&buffer);
    const value = try decoder.readF64();

    try std.testing.expectApproxEqAbs(123.456789, value, 0.000001);
}

test "sbe decoder - read fixed string" {
    var buffer: [30]u8 = undefined;

    const test_string = "BTCUSDT";
    @memcpy(buffer[8 .. 8 + test_string.len], test_string);
    @memset(buffer[8 + test_string.len .. 20], 0); // Null-pad remainder

    var decoder = try SbeDecoder.init(&buffer);
    const result = try decoder.readFixedString(12);

    try std.testing.expectEqualStrings("BTCUSDT", result);
}

test "sbe decoder - read var data" {
    var buffer: [50]u8 = undefined;

    const test_data = "Hello, World!";
    std.mem.writeInt(u16, buffer[8..10], test_data.len, .little);
    @memcpy(buffer[10 .. 10 + test_data.len], test_data);

    var decoder = try SbeDecoder.init(&buffer);
    const result = try decoder.readVarData();

    try std.testing.expectEqualStrings(test_data, result);
}

test "sbe decoder - skip bytes" {
    var buffer: [50]u8 = undefined;

    var decoder = try SbeDecoder.init(&buffer);
    try decoder.skipBytes(10);

    try std.testing.expectEqual(@as(usize, 18), decoder.getPosition());
}

test "sbe decoder - enter group" {
    var buffer: [100]u8 = undefined;

    // Group header at offset 8: block_length=16, num_in_group=3
    std.mem.writeInt(u16, buffer[8..10], 16, .little);
    std.mem.writeInt(u16, buffer[10..12], 3, .little);

    var decoder = try SbeDecoder.init(&buffer);
    const group = try decoder.enterGroup();

    try std.testing.expectEqual(@as(u16, 16), group.block_length);
    try std.testing.expectEqual(@as(u16, 3), group.num_in_group);
    try std.testing.expectEqual(@as(u16, 0), group.current);
}

test "sbe group - next iteration" {
    var buffer: [100]u8 = undefined;

    // Group header: block_length=16, num_in_group=3
    std.mem.writeInt(u16, buffer[8..10], 16, .little);
    std.mem.writeInt(u16, buffer[10..12], 3, .little);

    var decoder = try SbeDecoder.init(&buffer);
    var group = try decoder.enterGroup();

    try std.testing.expect(group.next());
    try std.testing.expectEqual(@as(u16, 1), group.current);

    try std.testing.expect(group.next());
    try std.testing.expectEqual(@as(u16, 2), group.current);

    try std.testing.expect(group.next());
    try std.testing.expectEqual(@as(u16, 3), group.current);

    try std.testing.expect(!group.next());
    try std.testing.expectEqual(@as(u16, 3), group.current);
}

test "sbe decoder - position tracking" {
    var buffer: [50]u8 = undefined;

    var decoder = try SbeDecoder.init(&buffer);
    try std.testing.expectEqual(@as(usize, 8), decoder.getPosition());

    try decoder.skipBytes(5);
    try std.testing.expectEqual(@as(usize, 13), decoder.getPosition());

    try decoder.setPosition(20);
    try std.testing.expectEqual(@as(usize, 20), decoder.getPosition());
}

test "sbe decoder - end of data detection" {
    var buffer: [10]u8 = undefined;

    var decoder = try SbeDecoder.init(&buffer);
    try decoder.skipBytes(2); // pos = 10

    const result = decoder.readU32();
    try std.testing.expectError(error.EndOfData, result);
}

test "sbe decoder - sequence of reads" {
    var buffer: [50]u8 = undefined;

    // Write test data after header
    std.mem.writeInt(u8, buffer[8..9], 42, .little);
    std.mem.writeInt(u16, buffer[9..11], 1000, .little);
    std.mem.writeInt(u32, buffer[11..15], 123456, .little);
    std.mem.writeInt(u64, buffer[15..23], 9876543210, .little);

    var decoder = try SbeDecoder.init(&buffer);

    const b = try decoder.readU8();
    const w = try decoder.readU16();
    const dw = try decoder.readU32();
    const qw = try decoder.readU64();

    try std.testing.expectEqual(@as(u8, 42), b);
    try std.testing.expectEqual(@as(u16, 1000), w);
    try std.testing.expectEqual(@as(u32, 123456), dw);
    try std.testing.expectEqual(@as(u64, 9876543210), qw);
}
