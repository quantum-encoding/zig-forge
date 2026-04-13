// Copyright (c) 2025 QUANTUM ENCODING LTD
// Licensed under the MIT License.

//! ZIP Archive Writer — creates ZIP files in memory using DEFLATE compression.
//!
//! Produces valid ZIP archives that Word, LibreOffice, and all standard
//! unzip tools can open. Uses DEFLATE (method 8) for compressible content
//! and STORE (method 0) for already-compressed data like images.
//!
//! ZIP format reference: APPNOTE.TXT §4.3

const std = @import("std");
const flate = std.compress.flate;

const LOCAL_SIGNATURE: u32 = 0x04034b50;
const CENTRAL_SIGNATURE: u32 = 0x02014b50;
const EOCD_SIGNATURE: u32 = 0x06054b50;

const METHOD_STORE: u16 = 0;
const METHOD_DEFLATE: u16 = 8;

const CentralDirEntry = struct {
    filename: []const u8,
    local_header_offset: u32,
    compressed_size: u32,
    uncompressed_size: u32,
    crc32: u32,
    method: u16,
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

    /// Add a file entry, using DEFLATE for compressible content or STORE for images.
    pub fn addFile(self: *ZipWriter, filename: []const u8, data: []const u8) !void {
        const crc = std.hash.crc.Crc32.hash(data);
        const uncompressed_size: u32 = @intCast(data.len);
        const offset: u32 = @intCast(self.buffer.items.len);

        // Decide method: STORE for small files or binary image data, DEFLATE for text/XML
        const use_deflate = data.len > 64 and !isImageData(filename);

        var compressed_data: ?[]u8 = null;
        defer if (compressed_data) |cd| self.allocator.free(cd);

        var method: u16 = METHOD_STORE;
        var compressed_size: u32 = uncompressed_size;

        if (use_deflate) {
            if (deflateData(self.allocator, data)) |cd| {
                // Only use DEFLATE if it actually saves space
                if (cd.len < data.len) {
                    compressed_data = cd;
                    method = METHOD_DEFLATE;
                    compressed_size = @intCast(cd.len);
                } else {
                    self.allocator.free(cd);
                }
            }
        }

        const file_data = compressed_data orelse data;

        // Local file header (30 bytes + filename)
        try self.writeU32(LOCAL_SIGNATURE);
        try self.writeU16(20); // version needed to extract
        try self.writeU16(0); // general purpose bit flag
        try self.writeU16(method);
        try self.writeU16(0); // last mod time
        try self.writeU16(0); // last mod date
        try self.writeU32(crc);
        try self.writeU32(compressed_size);
        try self.writeU32(uncompressed_size);
        try self.writeU16(@intCast(filename.len));
        try self.writeU16(0); // extra field length
        try self.buffer.appendSlice(self.allocator, filename);

        // File data
        try self.buffer.appendSlice(self.allocator, file_data);

        // Record for central directory
        try self.entries.append(self.allocator, .{
            .filename = try self.allocator.dupe(u8, filename),
            .local_header_offset = offset,
            .compressed_size = compressed_size,
            .uncompressed_size = uncompressed_size,
            .crc32 = crc,
            .method = method,
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
            try self.writeU16(entry.method);
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

/// Check if filename suggests image/binary data (already compressed, STORE is better).
fn isImageData(filename: []const u8) bool {
    const ext_starts = std.mem.lastIndexOfScalar(u8, filename, '.') orelse return false;
    const ext = filename[ext_starts + 1 ..];
    return std.mem.eql(u8, ext, "png") or
        std.mem.eql(u8, ext, "jpg") or
        std.mem.eql(u8, ext, "jpeg") or
        std.mem.eql(u8, ext, "gif") or
        std.mem.eql(u8, ext, "bmp") or
        std.mem.eql(u8, ext, "webp") or
        std.mem.eql(u8, ext, "tiff");
}

/// Compress data using raw DEFLATE. Returns owned compressed bytes, or null on failure.
fn deflateData(allocator: std.mem.Allocator, data: []const u8) ?[]u8 {
    // Allocate working buffer for deflate (must be >= max_window_len = 64KB)
    const work_buf = allocator.alloc(u8, flate.max_window_len) catch return null;
    defer allocator.free(work_buf);

    // Output writer — pre-allocate to satisfy Compress assertion (buffer.len > 8)
    var output = std.Io.Writer.Allocating.initCapacity(allocator, @max(data.len, 256)) catch return null;
    defer output.deinit();

    // Init compressor with raw DEFLATE (no gzip/zlib wrapper)
    var compressor = flate.Compress.init(
        &output.writer,
        work_buf,
        .raw,
        flate.Compress.Options.level_6,
    ) catch return null;

    // Feed all input data through the compressor
    compressor.writer.writeAll(data) catch return null;

    // Finish the stream
    compressor.finish() catch return null;

    // Extract the compressed bytes
    return output.toOwnedSlice() catch return null;
}
