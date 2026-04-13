// Copyright (c) 2025 QUANTUM ENCODING LTD
// Licensed under the MIT License.

//! ZIP Archive Writer — creates ZIP files in memory using STORE method.
//!
//! Produces valid ZIP archives that Word, LibreOffice, and all standard
//! unzip tools can open. Uses STORE (no compression) which is fine for
//! DOCX files — the XML content is small and modern filesystems handle
//! it well. DEFLATE can be added later as an optimization.
//!
//! ZIP format reference: APPNOTE.TXT §4.3

const std = @import("std");

const LOCAL_SIGNATURE: u32 = 0x04034b50;
const CENTRAL_SIGNATURE: u32 = 0x02014b50;
const EOCD_SIGNATURE: u32 = 0x06054b50;

const CentralDirEntry = struct {
    filename: []const u8,
    local_header_offset: u32,
    compressed_size: u32,
    uncompressed_size: u32,
    crc32: u32,
};

pub const ZipWriter = struct {
    allocator: std.mem.Allocator,
    buffer: std.ArrayListUnmanaged(u8),
    entries: std.ArrayListUnmanaged(CentralDirEntry),

    pub fn init(allocator: std.mem.Allocator) ZipWriter {
        return .{
            .allocator = allocator,
            .buffer = .empty,
            .entries = .empty,
        };
    }

    pub fn deinit(self: *ZipWriter) void {
        for (self.entries.items) |e| {
            self.allocator.free(e.filename);
        }
        self.entries.deinit(self.allocator);
        self.buffer.deinit(self.allocator);
    }

    /// Add a file entry using STORE method (no compression).
    pub fn addFile(self: *ZipWriter, filename: []const u8, data: []const u8) !void {
        const crc = std.hash.crc.Crc32.hash(data);
        const size: u32 = @intCast(data.len);
        const offset: u32 = @intCast(self.buffer.items.len);

        // Local file header (30 bytes + filename)
        try self.writeU32(LOCAL_SIGNATURE);
        try self.writeU16(20); // version needed to extract
        try self.writeU16(0); // general purpose bit flag
        try self.writeU16(0); // compression method: STORE
        try self.writeU16(0); // last mod time
        try self.writeU16(0); // last mod date
        try self.writeU32(crc);
        try self.writeU32(size); // compressed size
        try self.writeU32(size); // uncompressed size
        try self.writeU16(@intCast(filename.len));
        try self.writeU16(0); // extra field length
        try self.buffer.appendSlice(self.allocator, filename);

        // File data (uncompressed)
        try self.buffer.appendSlice(self.allocator, data);

        // Record for central directory
        try self.entries.append(self.allocator, .{
            .filename = try self.allocator.dupe(u8, filename),
            .local_header_offset = offset,
            .compressed_size = size,
            .uncompressed_size = size,
            .crc32 = crc,
        });
    }

    /// Finalize the archive: write central directory + EOCD.
    /// Returns the complete ZIP file as an owned byte slice.
    pub fn finish(self: *ZipWriter) ![]u8 {
        const cd_offset: u32 = @intCast(self.buffer.items.len);

        // Central directory entries
        for (self.entries.items) |entry| {
            try self.writeU32(CENTRAL_SIGNATURE);
            try self.writeU16(20); // version made by
            try self.writeU16(20); // version needed
            try self.writeU16(0); // flags
            try self.writeU16(0); // compression: STORE
            try self.writeU16(0); // last mod time
            try self.writeU16(0); // last mod date
            try self.writeU32(entry.crc32);
            try self.writeU32(entry.compressed_size);
            try self.writeU32(entry.uncompressed_size);
            try self.writeU16(@intCast(entry.filename.len));
            try self.writeU16(0); // extra field length
            try self.writeU16(0); // file comment length
            try self.writeU16(0); // disk number start
            try self.writeU16(0); // internal file attributes
            try self.writeU32(0); // external file attributes
            try self.writeU32(entry.local_header_offset);
            try self.buffer.appendSlice(self.allocator, entry.filename);
        }

        const cd_size: u32 = @intCast(self.buffer.items.len - cd_offset);

        // End of central directory record (EOCD)
        try self.writeU32(EOCD_SIGNATURE);
        try self.writeU16(0); // disk number
        try self.writeU16(0); // disk with central directory
        try self.writeU16(@intCast(self.entries.items.len)); // entries on this disk
        try self.writeU16(@intCast(self.entries.items.len)); // total entries
        try self.writeU32(cd_size);
        try self.writeU32(cd_offset);
        try self.writeU16(0); // comment length

        // Transfer ownership of the buffer to the caller
        const result = try self.allocator.dupe(u8, self.buffer.items);
        return result;
    }

    // ── Little-endian integer writers ────────────────────────────

    fn writeU16(self: *ZipWriter, value: u16) !void {
        var buf: [2]u8 = undefined;
        std.mem.writeInt(u16, &buf, value, .little);
        try self.buffer.appendSlice(self.allocator, &buf);
    }

    fn writeU32(self: *ZipWriter, value: u32) !void {
        var buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &buf, value, .little);
        try self.buffer.appendSlice(self.allocator, &buf);
    }
};
