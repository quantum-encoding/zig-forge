// Copyright (c) 2025 QUANTUM ENCODING LTD
// Licensed under the MIT License.

//! ZIP archive reader for XLSX files
//!
//! Reads entire file into memory, parses the central directory,
//! and extracts entries using raw copy (STORED) or std.compress.flate (DEFLATED).

const std = @import("std");

// C file I/O (not all available in std.c on Zig 0.16)
extern "c" fn fseek(stream: *std.c.FILE, offset: c_long, whence: c_int) c_int;
extern "c" fn ftell(stream: *std.c.FILE) c_long;
const SEEK_END: c_int = 2;
const SEEK_SET: c_int = 0;

pub const ZipError = error{
    NotAZipFile,
    CorruptArchive,
    UnsupportedCompression,
    DecompressionFailed,
    FileNotFound,
    FileTooLarge,
    OutOfMemory,
    ReadFailed,
};

pub const Entry = struct {
    filename: []const u8,
    compressed_size: u32,
    uncompressed_size: u32,
    compression_method: u16,
    local_header_offset: u32,
};

pub const ZipArchive = struct {
    entries: []Entry,
    data: []const u8,
    allocator: std.mem.Allocator,
    filenames: [][]const u8, // owned copies of filenames

    const EOCD_SIGNATURE: u32 = 0x06054b50;
    const CD_SIGNATURE: u32 = 0x02014b50;
    const LOCAL_SIGNATURE: u32 = 0x04034b50;
    const MAX_FILE_SIZE: usize = 256 * 1024 * 1024; // 256 MB

    pub fn open(allocator: std.mem.Allocator, path: []const u8) ZipError!ZipArchive {
        // Read entire file into memory
        const data = readFile(allocator, path) orelse return ZipError.ReadFailed;
        errdefer allocator.free(data);

        return openFromMemory(allocator, data);
    }

    pub fn openFromMemory(allocator: std.mem.Allocator, data: []const u8) ZipError!ZipArchive {
        if (data.len < 22) return ZipError.NotAZipFile;

        // Find End of Central Directory
        const eocd_offset = findEOCD(data) orelse return ZipError.NotAZipFile;

        // Parse EOCD
        const cd_entries = readU16(data, eocd_offset + 10);
        const cd_offset = readU32(data, eocd_offset + 16);

        if (cd_offset >= data.len) return ZipError.CorruptArchive;

        // Parse Central Directory entries
        var entries = allocator.alloc(Entry, cd_entries) catch return ZipError.OutOfMemory;
        errdefer allocator.free(entries);

        var filenames = allocator.alloc([]const u8, cd_entries) catch return ZipError.OutOfMemory;
        errdefer {
            for (filenames[0..0]) |f| allocator.free(f);
            allocator.free(filenames);
        }

        var offset: usize = cd_offset;
        var i: usize = 0;
        while (i < cd_entries) : (i += 1) {
            if (offset + 46 > data.len) return ZipError.CorruptArchive;
            if (readU32(data, offset) != CD_SIGNATURE) return ZipError.CorruptArchive;

            const method = readU16(data, offset + 10);
            const comp_size = readU32(data, offset + 20);
            const uncomp_size = readU32(data, offset + 24);
            const name_len = readU16(data, offset + 28);
            const extra_len = readU16(data, offset + 30);
            const comment_len = readU16(data, offset + 32);
            const local_offset = readU32(data, offset + 42);

            if (offset + 46 + name_len > data.len) return ZipError.CorruptArchive;

            const name_src = data[offset + 46 .. offset + 46 + name_len];
            const name_copy = allocator.dupe(u8, name_src) catch return ZipError.OutOfMemory;
            filenames[i] = name_copy;

            entries[i] = .{
                .filename = name_copy,
                .compressed_size = comp_size,
                .uncompressed_size = uncomp_size,
                .compression_method = method,
                .local_header_offset = local_offset,
            };

            offset += 46 + name_len + extra_len + comment_len;
        }

        return .{
            .entries = entries,
            .data = data,
            .allocator = allocator,
            .filenames = filenames,
        };
    }

    pub fn findEntry(self: *const ZipArchive, name: []const u8) ?*const Entry {
        for (self.entries) |*entry| {
            if (std.mem.eql(u8, entry.filename, name)) return entry;
        }
        return null;
    }

    pub fn extract(self: *const ZipArchive, entry: *const Entry) ZipError![]u8 {
        // Read local file header to find data start
        const lh_offset: usize = entry.local_header_offset;
        if (lh_offset + 30 > self.data.len) return ZipError.CorruptArchive;
        if (readU32(self.data, lh_offset) != LOCAL_SIGNATURE) return ZipError.CorruptArchive;

        const local_name_len = readU16(self.data, lh_offset + 26);
        const local_extra_len = readU16(self.data, lh_offset + 28);
        const data_start = lh_offset + 30 + local_name_len + local_extra_len;
        const data_end = data_start + entry.compressed_size;

        if (data_end > self.data.len) return ZipError.CorruptArchive;

        const compressed = self.data[data_start..data_end];

        if (entry.compression_method == 0) {
            // STORED: just copy
            const result = self.allocator.dupe(u8, compressed) catch return ZipError.OutOfMemory;
            return result;
        } else if (entry.compression_method == 8) {
            // DEFLATED: decompress using std.compress.flate
            return inflate(self.allocator, compressed, entry.uncompressed_size);
        } else {
            return ZipError.UnsupportedCompression;
        }
    }

    pub fn close(self: *ZipArchive) void {
        for (self.filenames) |f| {
            self.allocator.free(f);
        }
        self.allocator.free(self.filenames);
        self.allocator.free(self.entries);
        self.allocator.free(self.data);
    }

    // ========================================================================
    // Internal helpers
    // ========================================================================

    fn findEOCD(data: []const u8) ?usize {
        // EOCD is at least 22 bytes; scan backwards from end
        const min_offset: usize = if (data.len >= 22) data.len - 22 else return null;
        const max_search: usize = if (data.len > 65557) data.len - 65557 else 0;

        var offset: usize = min_offset;
        while (offset >= max_search) {
            if (readU32(data, offset) == EOCD_SIGNATURE) return offset;
            if (offset == 0) break;
            offset -= 1;
        }
        return null;
    }

    fn inflate(allocator: std.mem.Allocator, compressed: []const u8, _: u32) ZipError![]u8 {
        // Create an Io.Reader from compressed data
        var input_reader = std.Io.Reader.fixed(compressed);

        // Window buffer for decompressor
        var window_buf: [std.compress.flate.max_window_len]u8 = undefined;

        // Create raw deflate decompressor
        var decompressor = std.compress.flate.Decompress.init(&input_reader, .raw, &window_buf);

        // Read all decompressed data
        const output = decompressor.reader.allocRemaining(allocator, .unlimited) catch
            return ZipError.DecompressionFailed;
        return output;
    }

    fn readFile(allocator: std.mem.Allocator, path: []const u8) ?[]u8 {
        const path_z = allocator.allocSentinel(u8, path.len, 0) catch return null;
        defer allocator.free(path_z);
        @memcpy(path_z, path);

        const file = std.c.fopen(path_z.ptr, "rb") orelse return null;
        defer _ = std.c.fclose(file);

        // Get file size
        _ = fseek(file, 0, SEEK_END);
        const size_long = ftell(file);
        if (size_long <= 0) return null;
        const size: usize = @intCast(size_long);
        if (size > MAX_FILE_SIZE) return null;

        _ = fseek(file, 0, SEEK_SET);

        const buf = allocator.alloc(u8, size) catch return null;
        const read = std.c.fread(buf.ptr, 1, size, file);
        if (read != size) {
            allocator.free(buf);
            return null;
        }

        return buf;
    }
};

fn readU16(data: []const u8, offset: usize) u16 {
    return @as(u16, data[offset]) | (@as(u16, data[offset + 1]) << 8);
}

fn readU32(data: []const u8, offset: usize) u32 {
    return @as(u32, data[offset]) |
        (@as(u32, data[offset + 1]) << 8) |
        (@as(u32, data[offset + 2]) << 16) |
        (@as(u32, data[offset + 3]) << 24);
}

test "readU16 and readU32" {
    const data = [_]u8{ 0x50, 0x4B, 0x03, 0x04 };
    try std.testing.expectEqual(@as(u16, 0x4B50), readU16(&data, 0));
    try std.testing.expectEqual(@as(u32, 0x04034B50), readU32(&data, 0));
}
