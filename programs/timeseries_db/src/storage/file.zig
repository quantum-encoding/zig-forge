//! mmap-based file storage
//! Zero-copy reads via memory mapping
//!
//! Performance: 10M+ reads/second (mmap = memory speed)

const std = @import("std");
const posix = std.posix;
const Io = std.Io;

/// File header (4KB, page-aligned)
pub const FileHeader = extern struct {
    magic: u32,              // 0x54534442 ("TSDB")
    version: u16,            // Format version
    flags: u16,              // Compression flags
    row_count: u64,          // Number of candles
    column_offsets: [6]u64,  // Offset to each column
    index_offset: u64,       // Offset to B-tree index
    checksum: u32,           // CRC32 of header
    _padding: [3968]u8,      // Pad to 4096 bytes

    pub const MAGIC: u32 = 0x54534442; // "TSDB"
    pub const VERSION: u16 = 1;
    pub const SIZE: usize = 4096;

    pub fn init() FileHeader {
        return .{
            .magic = MAGIC,
            .version = VERSION,
            .flags = 0,
            .row_count = 0,
            .column_offsets = [_]u64{0} ** 6,
            .index_offset = 0,
            .checksum = 0,
            ._padding = [_]u8{0} ** 3968,
        };
    }

    pub fn validate(self: *const FileHeader) !void {
        if (self.magic != MAGIC) {
            return error.InvalidMagic;
        }
        if (self.version != VERSION) {
            return error.UnsupportedVersion;
        }
    }
};

/// Column header (64 bytes, cache-line aligned)
pub const ColumnHeader = extern struct {
    column_type: u8,         // 0=timestamp, 1=price, 2=volume
    compression: u8,         // 0=none, 1=delta, 2=delta+bitpack
    base_value: f64,         // Base value for delta encoding
    count: u64,              // Number of values
    compressed_size: u64,    // Size of compressed data
    uncompressed_size: u64,  // Original data size
    _padding: [30]u8,        // Pad to 64 bytes

    pub const SIZE: usize = 64;

    pub fn init(column_type: u8, compression: u8) ColumnHeader {
        return .{
            .column_type = column_type,
            .compression = compression,
            .base_value = 0.0,
            .count = 0,
            .compressed_size = 0,
            .uncompressed_size = 0,
            ._padding = [_]u8{0} ** 30,
        };
    }
};

/// Memory-mapped file storage
pub const FileStorage = struct {
    file: std.Io.File,
    mmap_ptr: [*]align(std.heap.page_size_min) u8,
    mmap_len: usize,
    writable: bool,

    pub fn create(path: []const u8, initial_size: usize) !FileStorage {
        const io = Io.Threaded.global_single_threaded.io();

        // Create new file
        const file = try Io.Dir.cwd().createFile(io, path, .{
            .read = true,
            .truncate = false,
        });
        errdefer file.close(io);

        // Ensure minimum size (header + some data)
        const min_size = std.mem.alignForward(usize, initial_size, std.heap.page_size_min);
        try file.setLength(io, min_size);

        // mmap the file
        const mmap_ptr = try posix.mmap(
            null,
            min_size,
            .{ .READ = true, .WRITE = true },
            .{ .TYPE = .SHARED },
            file.handle,
            0,
        );

        // Write initial header
        const header = FileHeader.init();
        @memcpy(mmap_ptr[0..@sizeOf(FileHeader)], std.mem.asBytes(&header));

        return FileStorage{
            .file = file,
            .mmap_ptr = mmap_ptr.ptr,
            .mmap_len = min_size,
            .writable = true,
        };
    }

    pub fn open(path: []const u8, writable: bool) !FileStorage {
        const io = Io.Threaded.global_single_threaded.io();

        const file = if (writable)
            try Io.Dir.cwd().openFile(io, path, .{ .mode = .read_write })
        else
            try Io.Dir.cwd().openFile(io, path, .{ .mode = .read_only });

        errdefer file.close(io);

        const file_size = (try file.stat(io)).size;
        if (file_size < FileHeader.SIZE) {
            return error.FileTooSmall;
        }

        const prot: posix.PROT = if (writable)
            .{ .READ = true, .WRITE = true }
        else
            .{ .READ = true };

        const mmap_ptr = try posix.mmap(
            null,
            file_size,
            prot,
            .{ .TYPE = .SHARED },
            file.handle,
            0,
        );

        // Validate header
        const header = @as(*const FileHeader, @ptrCast(@alignCast(mmap_ptr.ptr)));
        try header.validate();

        return FileStorage{
            .file = file,
            .mmap_ptr = mmap_ptr.ptr,
            .mmap_len = file_size,
            .writable = writable,
        };
    }

    pub fn deinit(self: *FileStorage) void {
        // Sync changes to disk
        if (self.writable) {
            posix.msync(
                @as([*]align(std.heap.page_size_min) u8, self.mmap_ptr)[0..self.mmap_len],
                posix.MSF.SYNC,
            ) catch {};
        }

        // Unmap
        posix.munmap(
            @as([*]align(std.heap.page_size_min) u8, self.mmap_ptr)[0..self.mmap_len],
        );

        self.file.close(Io.Threaded.global_single_threaded.io());
    }

    /// Get file header
    pub fn getHeader(self: *const FileStorage) *FileHeader {
        return @as(*FileHeader, @ptrCast(@alignCast(self.mmap_ptr)));
    }

    /// Get const file header
    pub fn getHeaderConst(self: *const FileStorage) *const FileHeader {
        return @as(*const FileHeader, @ptrCast(@alignCast(self.mmap_ptr)));
    }

    /// Get slice of mapped memory
    pub fn getSlice(self: *const FileStorage, offset: usize, len: usize) ![]const u8 {
        if (offset + len > self.mmap_len) {
            return error.OffsetOutOfBounds;
        }
        return self.mmap_ptr[offset .. offset + len];
    }

    /// Get mutable slice of mapped memory
    pub fn getSliceMut(self: *FileStorage, offset: usize, len: usize) ![]u8 {
        if (!self.writable) {
            return error.ReadOnly;
        }
        if (offset + len > self.mmap_len) {
            return error.OffsetOutOfBounds;
        }
        return self.mmap_ptr[offset .. offset + len];
    }

    /// Expand file and remap (if needed)
    pub fn expand(self: *FileStorage, new_size: usize) !void {
        if (!self.writable) {
            return error.ReadOnly;
        }

        const aligned_size = std.mem.alignForward(usize, new_size, std.heap.page_size_min);
        if (aligned_size <= self.mmap_len) {
            return; // Already large enough
        }

        // Unmap current mapping
        posix.munmap(
            @as([*]align(std.heap.page_size_min) u8, self.mmap_ptr)[0..self.mmap_len],
        );

        // Expand file
        try self.file.setEndPos(aligned_size);

        // Remap
        const mmap_ptr = try posix.mmap(
            null,
            aligned_size,
            .{ .READ = true, .WRITE = true },
            .{ .TYPE = .SHARED },
            self.file.handle,
            0,
        );

        self.mmap_ptr = mmap_ptr.ptr;
        self.mmap_len = aligned_size;
    }

    /// Flush changes to disk
    pub fn flush(self: *FileStorage) !void {
        if (!self.writable) return;

        try posix.msync(
            @as([*]align(std.heap.page_size_min) u8, self.mmap_ptr)[0..self.mmap_len],
            posix.MSF.SYNC,
        );
    }
};

// ============================================================================
// Tests
// ============================================================================

test "file storage - create and open" {
    const allocator = std.testing.allocator;

    // Create temp file
    const temp_path = "/tmp/test_tsdb_file.bin";
    defer std.Io.Dir.cwd().deleteFile(temp_path) catch {};

    // Create file
    var storage = try FileStorage.create(temp_path, 64 * 1024);
    defer storage.deinit();

    // Verify header
    const header = storage.getHeaderConst();
    try std.testing.expectEqual(FileHeader.MAGIC, header.magic);
    try std.testing.expectEqual(FileHeader.VERSION, header.version);

    // Write some data
    const mut_header = storage.getHeader();
    mut_header.row_count = 100;

    // Flush
    try storage.flush();

    // Close and reopen
    storage.deinit();

    var storage2 = try FileStorage.open(temp_path, false);
    defer storage2.deinit();

    const header2 = storage2.getHeaderConst();
    try std.testing.expectEqual(@as(u64, 100), header2.row_count);

    _ = allocator;
}

test "file storage - expand" {
    const temp_path = "/tmp/test_tsdb_expand.bin";
    defer std.Io.Dir.cwd().deleteFile(temp_path) catch {};

    var storage = try FileStorage.create(temp_path, 4096);
    defer storage.deinit();

    const initial_len = storage.mmap_len;

    // Expand
    try storage.expand(128 * 1024);

    try std.testing.expect(storage.mmap_len > initial_len);
    try std.testing.expect(storage.mmap_len >= 128 * 1024);
}

test "file storage - header validation" {
    const temp_path = "/tmp/test_tsdb_invalid.bin";
    defer std.Io.Dir.cwd().deleteFile(temp_path) catch {};

    var storage = try FileStorage.create(temp_path, 4096);

    // Corrupt header
    const header = storage.getHeader();
    header.magic = 0xDEADBEEF;
    try storage.flush();

    storage.deinit();

    // Should fail to open
    const result = FileStorage.open(temp_path, false);
    try std.testing.expectError(error.InvalidMagic, result);
}
