//! ═══════════════════════════════════════════════════════════════════════════
//! WIRE PROTOCOL - Binary message format for Warp Gate
//! ═══════════════════════════════════════════════════════════════════════════
//!
//! Message format:
//! ┌─────────┬──────────┬────────────┬──────────────┐
//! │ Magic   │ Type     │ Length     │ Payload      │
//! │ 4 bytes │ 1 byte   │ 4 bytes    │ variable     │
//! └─────────┴──────────┴────────────┴──────────────┘
//!
//! All multi-byte integers are big-endian.

const std = @import("std");
const mem = std.mem;
const posix = std.posix;

pub const MAGIC: [4]u8 = .{ 'W', 'A', 'R', 'P' };
pub const MAX_PAYLOAD_SIZE: u32 = 64 * 1024 * 1024; // 64 MiB
pub const CHUNK_SIZE: usize = 64 * 1024; // 64 KiB chunks

pub const MessageType = enum(u8) {
    // Handshake
    hello = 0x01,
    hello_ack = 0x02,

    // File transfer
    file_start = 0x10,
    file_chunk = 0x11,
    file_end = 0x12,

    // Directory transfer
    dir_start = 0x20,
    dir_entry = 0x21,
    dir_end = 0x22,

    // Control
    ack = 0x30,
    nack = 0x31,
    ping = 0x32,
    pong = 0x33,

    // Errors
    err_checksum = 0xE0,
    err_timeout = 0xE1,
    err_cancelled = 0xE2,

    _,
};

pub const Header = struct {
    magic: [4]u8 = MAGIC,
    msg_type: MessageType,
    length: u32,

    pub const SIZE = 9;

    pub fn serialize(self: *const Header) [SIZE]u8 {
        var buf: [SIZE]u8 = undefined;
        @memcpy(buf[0..4], &self.magic);
        buf[4] = @intFromEnum(self.msg_type);
        mem.writeInt(u32, buf[5..9], self.length, .big);
        return buf;
    }

    pub fn deserialize(buf: *const [SIZE]u8) !Header {
        if (!mem.eql(u8, buf[0..4], &MAGIC)) {
            return error.InvalidMagic;
        }

        const length = mem.readInt(u32, buf[5..9], .big);
        if (length > MAX_PAYLOAD_SIZE) {
            return error.PayloadTooLarge;
        }

        return Header{
            .msg_type = @enumFromInt(buf[4]),
            .length = length,
        };
    }
};

/// Hello message for handshake
pub const HelloMsg = struct {
    version: u16 = 1,
    code_hash: [16]u8, // First 16 bytes of code hash
    public_key: [32]u8, // X25519 public key for key exchange

    pub const SIZE = 2 + 16 + 32;

    pub fn serialize(self: *const HelloMsg) [SIZE]u8 {
        var buf: [SIZE]u8 = undefined;
        mem.writeInt(u16, buf[0..2], self.version, .big);
        @memcpy(buf[2..18], &self.code_hash);
        @memcpy(buf[18..50], &self.public_key);
        return buf;
    }

    pub fn deserialize(buf: *const [SIZE]u8) HelloMsg {
        return HelloMsg{
            .version = mem.readInt(u16, buf[0..2], .big),
            .code_hash = buf[2..18].*,
            .public_key = buf[18..50].*,
        };
    }
};

/// File metadata header
pub const FileStartMsg = struct {
    name_len: u16,
    name: []const u8,
    size: u64,
    mode: u32,
    checksum: [32]u8, // BLAKE3 hash of file

    pub fn serialize(self: *const FileStartMsg, buf: []u8) !usize {
        if (buf.len < 2 + self.name.len + 8 + 4 + 32) return error.BufferTooSmall;

        var offset: usize = 0;
        mem.writeInt(u16, buf[0..2], self.name_len, .big);
        offset += 2;

        @memcpy(buf[offset .. offset + self.name.len], self.name);
        offset += self.name.len;

        mem.writeInt(u64, buf[offset..][0..8], self.size, .big);
        offset += 8;

        mem.writeInt(u32, buf[offset..][0..4], self.mode, .big);
        offset += 4;

        @memcpy(buf[offset .. offset + 32], &self.checksum);
        offset += 32;

        return offset;
    }

    pub fn deserialize(buf: []const u8) !FileStartMsg {
        if (buf.len < 2) return error.BufferTooSmall;

        const name_len = mem.readInt(u16, buf[0..2], .big);
        if (buf.len < 2 + name_len + 8 + 4 + 32) return error.BufferTooSmall;

        var offset: usize = 2;
        const name = buf[offset .. offset + name_len];
        offset += name_len;

        const size = mem.readInt(u64, buf[offset..][0..8], .big);
        offset += 8;

        const mode = mem.readInt(u32, buf[offset..][0..4], .big);
        offset += 4;

        return FileStartMsg{
            .name_len = name_len,
            .name = name,
            .size = size,
            .mode = mode,
            .checksum = buf[offset..][0..32].*,
        };
    }
};

/// File chunk with sequence number for ordering
pub const FileChunkMsg = struct {
    sequence: u32,
    offset: u64,
    data: []const u8,

    pub fn serialize(self: *const FileChunkMsg, buf: []u8) !usize {
        const header_size = 4 + 8;
        if (buf.len < header_size + self.data.len) return error.BufferTooSmall;

        mem.writeInt(u32, buf[0..4], self.sequence, .big);
        mem.writeInt(u64, buf[4..12], self.offset, .big);
        @memcpy(buf[header_size .. header_size + self.data.len], self.data);

        return header_size + self.data.len;
    }

    pub fn deserialize(buf: []const u8) !FileChunkMsg {
        if (buf.len < 12) return error.BufferTooSmall;

        return FileChunkMsg{
            .sequence = mem.readInt(u32, buf[0..4], .big),
            .offset = mem.readInt(u64, buf[4..12], .big),
            .data = buf[12..],
        };
    }
};

/// File stream for reading/writing transfers
pub const FileStream = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    file: ?std.Io.File = null,
    path: []const u8,
    mode: Mode,
    total_size: u64 = 0,
    bytes_transferred: u64 = 0,
    current_sequence: u32 = 0,
    chunk_buf: []u8,

    pub const Mode = enum { read, write };

    pub fn init(allocator: std.mem.Allocator, path: []const u8) !Self {
        const io = std.Io.Threaded.global_single_threaded.io();
        const chunk_buf = try allocator.alloc(u8, CHUNK_SIZE);
        errdefer allocator.free(chunk_buf);

        // Check if path is a file or directory
        const stat = try std.Io.Dir.cwd().statFile(io, path, .{});
        _ = stat;

        const file = try std.Io.Dir.cwd().openFile(io, path, .{});

        return Self{
            .allocator = allocator,
            .file = file,
            .path = path,
            .mode = .read,
            .chunk_buf = chunk_buf,
        };
    }

    pub fn initWrite(allocator: std.mem.Allocator, path: []const u8) !Self {
        const io = std.Io.Threaded.global_single_threaded.io();
        const chunk_buf = try allocator.alloc(u8, CHUNK_SIZE);
        errdefer allocator.free(chunk_buf);

        const file = try std.Io.Dir.cwd().createFile(io, path, .{});

        return Self{
            .allocator = allocator,
            .file = file,
            .path = path,
            .mode = .write,
            .chunk_buf = chunk_buf,
        };
    }

    pub fn deinit(self: *Self) void {
        const io = std.Io.Threaded.global_single_threaded.io();
        if (self.file) |f| f.close(io);
        self.allocator.free(self.chunk_buf);
    }

    /// Read next chunk for sending
    pub fn nextChunk(self: *Self) !?[]const u8 {
        const io = std.Io.Threaded.global_single_threaded.io();
        if (self.mode != .read) return error.InvalidMode;
        const file = self.file orelse return null;

        const bytes_read = file.readPositionalAll(io, self.chunk_buf, self.bytes_transferred) catch return error.ReadError;
        if (bytes_read == 0) return null;

        self.bytes_transferred += bytes_read;
        self.current_sequence += 1;

        return self.chunk_buf[0..bytes_read];
    }

    /// Write received chunk
    pub fn writeChunk(self: *Self, data: []const u8) !void {
        const io = std.Io.Threaded.global_single_threaded.io();
        if (self.mode != .write) return error.InvalidMode;
        const file = self.file orelse return error.FileClosed;

        var write_buf: [8192]u8 = undefined;
        var writer = file.writer(io, &write_buf);
        writer.interface.writeAll(data) catch return error.WriteError;
        writer.interface.flush() catch return error.WriteError;
        self.bytes_transferred += data.len;
    }

    /// Get transfer progress (0.0 - 1.0)
    pub fn progress(self: *const Self) f64 {
        if (self.total_size == 0) return 0.0;
        return @as(f64, @floatFromInt(self.bytes_transferred)) /
            @as(f64, @floatFromInt(self.total_size));
    }
};

// ═══════════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════════

test "header serialization round-trip" {
    const header = Header{
        .msg_type = .file_chunk,
        .length = 1024, // Must be <= MAX_PAYLOAD_SIZE
    };

    const buf = header.serialize();
    const decoded = try Header.deserialize(&buf);

    try std.testing.expectEqual(header.msg_type, decoded.msg_type);
    try std.testing.expectEqual(header.length, decoded.length);
}

test "hello message round-trip" {
    const hello = HelloMsg{
        .code_hash = [_]u8{0xAB} ** 16,
        .public_key = [_]u8{0xCD} ** 32,
    };

    const buf = hello.serialize();
    const decoded = HelloMsg.deserialize(&buf);

    try std.testing.expectEqual(hello.version, decoded.version);
    try std.testing.expectEqualSlices(u8, &hello.code_hash, &decoded.code_hash);
}

test "file chunk serialization" {
    const data = "Hello, Warp Gate!";
    const chunk = FileChunkMsg{
        .sequence = 42,
        .offset = 1024,
        .data = data,
    };

    var buf: [1024]u8 = undefined;
    const len = try chunk.serialize(&buf);
    const decoded = try FileChunkMsg.deserialize(buf[0..len]);

    try std.testing.expectEqual(chunk.sequence, decoded.sequence);
    try std.testing.expectEqual(chunk.offset, decoded.offset);
    try std.testing.expectEqualStrings(data, decoded.data);
}
