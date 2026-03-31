//! Write-Ahead Log (WAL) Implementation
//!
//! Provides durable storage for Raft log entries with crash recovery:
//! - Append-only log file with CRC32 checksums
//! - Vote persistence for leader election
//! - Segment-based rotation for efficient truncation
//! - Recovery on startup from persisted state
//!
//! File format:
//!   Header: magic(4) + version(2) + node_id(8) = 14 bytes
//!   Record: type(1) + len(4) + crc32(4) + data(len)
//!
//! Record types:
//!   0x01 = Log entry
//!   0x02 = Vote record
//!   0x03 = Snapshot marker
//!   0x04 = Term update

const std = @import("std");
const raft = @import("raft.zig");
const posix = std.posix;
const linux = std.os.linux;

// =============================================================================
// Constants
// =============================================================================

/// WAL file magic number: "DKWL" (Distributed KV WAL)
const WAL_MAGIC: [4]u8 = .{ 'D', 'K', 'W', 'L' };

/// Current WAL format version
const WAL_VERSION: u16 = 1;

/// Maximum segment size before rotation (64MB)
const MAX_SEGMENT_SIZE: u64 = 64 * 1024 * 1024;

/// Record type markers
const RecordType = enum(u8) {
    log_entry = 0x01,
    vote = 0x02,
    snapshot_marker = 0x03,
    term_update = 0x04,
};

/// Header size
const HEADER_SIZE: usize = 14;

/// Record header size: type(1) + len(4) + crc32(4)
const RECORD_HEADER_SIZE: usize = 9;

// =============================================================================
// Errors
// =============================================================================

pub const WalError = error{
    InvalidMagic,
    UnsupportedVersion,
    CorruptedRecord,
    ChecksumMismatch,
    UnexpectedEof,
    SegmentFull,
    FileNotFound,
    PermissionDenied,
    IoError,
    OutOfMemory,
};

// =============================================================================
// Helper Functions
// =============================================================================

/// Create a null-terminated path buffer
fn makePathZ(path: []const u8, buf: []u8) ?[:0]const u8 {
    if (path.len >= buf.len) return null;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    return buf[0..path.len :0];
}

/// Create directory with mkdir, ignoring if exists
fn ensureDir(path: []const u8) !void {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const pathZ = makePathZ(path, &buf) orelse return error.NameTooLong;
    const result = std.c.mkdir(pathZ.ptr, 0o755);
    if (result < 0) {
        const err = posix.errno(result);
        if (err != .EXIST) return WalError.IoError;
    }
}

/// Delete file
fn unlinkFile(path: []const u8) void {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const pathZ = makePathZ(path, &buf) orelse return;
    _ = std.c.unlink(pathZ.ptr);
}

/// Open file for reading
fn openRead(path: []const u8) !posix.fd_t {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const pathZ = makePathZ(path, &buf) orelse return WalError.IoError;
    return posix.openatZ(posix.AT.FDCWD, pathZ, .{ .ACCMODE = .RDONLY }, 0) catch return WalError.FileNotFound;
}

/// Open file for read-write
fn openReadWrite(path: []const u8) !posix.fd_t {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const pathZ = makePathZ(path, &buf) orelse return WalError.IoError;
    return posix.openatZ(posix.AT.FDCWD, pathZ, .{ .ACCMODE = .RDWR }, 0) catch return WalError.FileNotFound;
}

/// Create file for writing
fn createFile(path: []const u8) !posix.fd_t {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const pathZ = makePathZ(path, &buf) orelse return WalError.IoError;
    return posix.openatZ(posix.AT.FDCWD, pathZ, .{
        .ACCMODE = .RDWR,
        .CREAT = true,
        .TRUNC = true,
    }, 0o644) catch return WalError.IoError;
}

/// Write all bytes to fd
fn writeAll(fd: posix.fd_t, data: []const u8) !void {
    var written: usize = 0;
    while (written < data.len) {
        const result = linux.write(@intCast(fd), data[written..].ptr, data.len - written);
        const n: isize = @bitCast(result);
        if (n <= 0) return WalError.IoError;
        written += @intCast(result);
    }
}

/// Read bytes from fd
fn readBytes(fd: posix.fd_t, buf: []u8) !usize {
    const result = linux.read(@intCast(fd), buf.ptr, buf.len);
    const n: isize = @bitCast(result);
    if (n < 0) return WalError.IoError;
    return @intCast(result);
}

/// Sync file to disk
fn syncFile(fd: posix.fd_t) void {
    _ = std.c.fsync(fd);
}

/// Get file size via lseek
fn getFileSize(fd: posix.fd_t) !u64 {
    const end = std.c.lseek(fd, 0, std.c.SEEK.END);
    if (end < 0) return WalError.IoError;
    return @intCast(end);
}

/// Seek to position
fn seekTo(fd: posix.fd_t, pos: u64) !void {
    const result = std.c.lseek(fd, @intCast(pos), std.c.SEEK.SET);
    if (result < 0) return WalError.IoError;
}

// =============================================================================
// WAL Writer
// =============================================================================

/// Write-ahead log writer for durably persisting Raft state
pub const WalWriter = struct {
    allocator: std.mem.Allocator,
    dir_path: []const u8,
    node_id: raft.NodeId,
    current_fd: ?posix.fd_t,
    segment_index: u32,
    bytes_written: u64,

    pub fn init(allocator: std.mem.Allocator, dir_path: []const u8, node_id: raft.NodeId) !WalWriter {
        // Ensure directory exists
        ensureDir(dir_path) catch {};

        var writer = WalWriter{
            .allocator = allocator,
            .dir_path = try allocator.dupe(u8, dir_path),
            .node_id = node_id,
            .current_fd = null,
            .segment_index = 0,
            .bytes_written = 0,
        };

        // Find latest segment or create new one
        try writer.openOrCreateSegment();

        return writer;
    }

    pub fn deinit(self: *WalWriter) void {
        if (self.current_fd) |fd| {
            _ = std.c.close(fd);
        }
        self.allocator.free(self.dir_path);
    }

    /// Write a log entry to the WAL
    pub fn writeEntry(self: *WalWriter, entry_data: []const u8) !void {
        try self.writeRecord(.log_entry, entry_data);
    }

    /// Write a vote record to the WAL
    pub fn writeVote(self: *WalWriter, term: raft.Term, voted_for: raft.NodeId) !void {
        var buf: [16]u8 = undefined;
        std.mem.writeInt(u64, buf[0..8], term, .little);
        std.mem.writeInt(u64, buf[8..16], voted_for, .little);
        try self.writeRecord(.vote, &buf);
    }

    /// Write a term update
    pub fn writeTerm(self: *WalWriter, term: raft.Term) !void {
        var buf: [8]u8 = undefined;
        std.mem.writeInt(u64, buf[0..8], term, .little);
        try self.writeRecord(.term_update, &buf);
    }

    /// Sync WAL to disk
    pub fn sync(self: *WalWriter) !void {
        if (self.current_fd) |fd| {
            syncFile(fd);
        }
    }

    /// Write a record with checksum
    fn writeRecord(self: *WalWriter, record_type: RecordType, data: []const u8) !void {
        // Check if rotation needed
        if (self.bytes_written + RECORD_HEADER_SIZE + data.len > MAX_SEGMENT_SIZE) {
            try self.rotateSegment();
        }

        const fd = self.current_fd orelse return WalError.IoError;

        // Compute CRC32
        const crc = std.hash.Crc32.hash(data);

        // Write record header
        var header: [RECORD_HEADER_SIZE]u8 = undefined;
        header[0] = @intFromEnum(record_type);
        std.mem.writeInt(u32, header[1..5], @intCast(data.len), .little);
        std.mem.writeInt(u32, header[5..9], crc, .little);

        try writeAll(fd, &header);
        try writeAll(fd, data);

        self.bytes_written += RECORD_HEADER_SIZE + data.len;
    }

    /// Open existing segment or create new one
    fn openOrCreateSegment(self: *WalWriter) !void {
        // Find highest segment index by trying to open files
        var highest: u32 = 0;
        var found = false;

        // Try opening segment files to find the latest
        var idx: u32 = 0;
        while (idx < 1000) : (idx += 1) {
            const path = self.segmentPath(idx) catch break;
            defer self.allocator.free(path);

            const fd = openRead(path) catch {
                break; // No more segments
            };
            _ = std.c.close(fd);
            highest = idx;
            found = true;
        }

        if (found) {
            // Open existing segment
            try self.openSegment(highest);
        } else {
            // Create first segment
            try self.createNewSegment(0);
        }
    }

    /// Create a new segment file
    fn createNewSegment(self: *WalWriter, index: u32) !void {
        const path = try self.segmentPath(index);
        defer self.allocator.free(path);

        const fd = try createFile(path);
        errdefer _ = std.c.close(fd);

        // Write header
        var header: [HEADER_SIZE]u8 = undefined;
        @memcpy(header[0..4], &WAL_MAGIC);
        std.mem.writeInt(u16, header[4..6], WAL_VERSION, .little);
        std.mem.writeInt(u64, header[6..14], self.node_id, .little);

        writeAll(fd, &header) catch {
            _ = std.c.close(fd);
            return WalError.IoError;
        };

        self.current_fd = fd;
        self.segment_index = index;
        self.bytes_written = HEADER_SIZE;
    }

    /// Open existing segment file
    fn openSegment(self: *WalWriter, index: u32) !void {
        const path = try self.segmentPath(index);
        defer self.allocator.free(path);

        const fd = try openReadWrite(path);
        errdefer _ = std.c.close(fd);

        // Verify header
        var header: [HEADER_SIZE]u8 = undefined;
        const bytes_read = readBytes(fd, &header) catch {
            _ = std.c.close(fd);
            return WalError.IoError;
        };

        if (bytes_read < HEADER_SIZE) {
            _ = std.c.close(fd);
            return WalError.UnexpectedEof;
        }

        if (!std.mem.eql(u8, header[0..4], &WAL_MAGIC)) {
            _ = std.c.close(fd);
            return WalError.InvalidMagic;
        }

        const version = std.mem.readInt(u16, header[4..6], .little);
        if (version > WAL_VERSION) {
            _ = std.c.close(fd);
            return WalError.UnsupportedVersion;
        }

        // Seek to end for appending
        const size = getFileSize(fd) catch {
            _ = std.c.close(fd);
            return WalError.IoError;
        };
        seekTo(fd, size) catch {
            _ = std.c.close(fd);
            return WalError.IoError;
        };

        self.current_fd = fd;
        self.segment_index = index;
        self.bytes_written = size;
    }

    /// Rotate to a new segment
    fn rotateSegment(self: *WalWriter) !void {
        // Close current segment
        if (self.current_fd) |fd| {
            syncFile(fd);
            _ = std.c.close(fd);
        }

        // Create new segment
        try self.createNewSegment(self.segment_index + 1);
    }

    /// Generate segment file path
    fn segmentPath(self: *WalWriter, index: u32) ![]u8 {
        return std.fmt.allocPrint(self.allocator, "{s}/wal-{x:0>8}.log", .{ self.dir_path, index });
    }
};

// =============================================================================
// WAL Reader
// =============================================================================

/// Record read from WAL
pub const WalRecord = struct {
    record_type: RecordType,
    data: []u8,

    pub fn deinit(self: *const WalRecord, allocator: std.mem.Allocator) void {
        allocator.free(self.data);
    }
};

/// WAL reader for crash recovery
pub const WalReader = struct {
    allocator: std.mem.Allocator,
    dir_path: []const u8,
    segments: std.ArrayListUnmanaged(u32),
    current_segment_idx: usize,
    current_fd: ?posix.fd_t,

    pub fn init(allocator: std.mem.Allocator, dir_path: []const u8) !WalReader {
        var reader = WalReader{
            .allocator = allocator,
            .dir_path = try allocator.dupe(u8, dir_path),
            .segments = .empty,
            .current_segment_idx = 0,
            .current_fd = null,
        };

        // Discover all segments
        try reader.discoverSegments();

        return reader;
    }

    pub fn deinit(self: *WalReader) void {
        if (self.current_fd) |fd| {
            _ = std.c.close(fd);
        }
        self.segments.deinit(self.allocator);
        self.allocator.free(self.dir_path);
    }

    /// Read next record from WAL
    pub fn readNext(self: *WalReader) !?WalRecord {
        while (true) {
            // Open next segment if needed
            if (self.current_fd == null) {
                if (self.current_segment_idx >= self.segments.items.len) {
                    return null; // No more segments
                }
                try self.openSegmentForRead(self.segments.items[self.current_segment_idx]);
            }

            const fd = self.current_fd.?;

            // Read record header
            var header: [RECORD_HEADER_SIZE]u8 = undefined;
            const bytes_read = readBytes(fd, &header) catch return WalError.IoError;

            if (bytes_read == 0) {
                // End of segment, move to next
                _ = std.c.close(fd);
                self.current_fd = null;
                self.current_segment_idx += 1;
                continue;
            }

            if (bytes_read < RECORD_HEADER_SIZE) {
                return WalError.UnexpectedEof;
            }

            const record_type_byte = header[0];
            const record_type: RecordType = switch (record_type_byte) {
                0x01 => .log_entry,
                0x02 => .vote,
                0x03 => .snapshot_marker,
                0x04 => .term_update,
                else => return WalError.CorruptedRecord,
            };

            const data_len = std.mem.readInt(u32, header[1..5], .little);
            const expected_crc = std.mem.readInt(u32, header[5..9], .little);

            // Read data
            const data = try self.allocator.alloc(u8, data_len);
            errdefer self.allocator.free(data);

            var total_read: usize = 0;
            while (total_read < data_len) {
                const n = readBytes(fd, data[total_read..]) catch return WalError.IoError;
                if (n == 0) return WalError.UnexpectedEof;
                total_read += n;
            }

            // Verify checksum
            const actual_crc = std.hash.Crc32.hash(data);
            if (actual_crc != expected_crc) {
                self.allocator.free(data);
                return WalError.ChecksumMismatch;
            }

            return WalRecord{
                .record_type = record_type,
                .data = data,
            };
        }
    }

    /// Discover all WAL segments in directory
    fn discoverSegments(self: *WalReader) !void {
        // Try opening segment files to discover which exist
        var idx: u32 = 0;
        while (idx < 10000) : (idx += 1) {
            const path = std.fmt.allocPrint(self.allocator, "{s}/wal-{x:0>8}.log", .{ self.dir_path, idx }) catch break;
            defer self.allocator.free(path);

            const fd = openRead(path) catch {
                // If we hit a gap after finding segments, stop
                if (self.segments.items.len > 0 and idx > self.segments.items[self.segments.items.len - 1] + 10) {
                    break;
                }
                continue;
            };
            _ = std.c.close(fd);
            try self.segments.append(self.allocator, idx);
        }

        // Sort segments by index
        std.mem.sort(u32, self.segments.items, {}, std.sort.asc(u32));
    }

    /// Open a segment for reading
    fn openSegmentForRead(self: *WalReader, index: u32) !void {
        const path = try std.fmt.allocPrint(self.allocator, "{s}/wal-{x:0>8}.log", .{ self.dir_path, index });
        defer self.allocator.free(path);

        const fd = try openRead(path);
        errdefer _ = std.c.close(fd);

        // Read and verify header
        var header: [HEADER_SIZE]u8 = undefined;
        const bytes_read = readBytes(fd, &header) catch {
            _ = std.c.close(fd);
            return WalError.IoError;
        };

        if (bytes_read < HEADER_SIZE) {
            _ = std.c.close(fd);
            return WalError.UnexpectedEof;
        }

        if (!std.mem.eql(u8, header[0..4], &WAL_MAGIC)) {
            _ = std.c.close(fd);
            return WalError.InvalidMagic;
        }

        self.current_fd = fd;
    }
};

// =============================================================================
// Recovery
// =============================================================================

/// Recovered state from WAL
pub const RecoveredState = struct {
    current_term: raft.Term,
    voted_for: ?raft.NodeId,
    log_entries: std.ArrayListUnmanaged(raft.LogEntry),

    pub fn deinit(self: *RecoveredState, allocator: std.mem.Allocator) void {
        for (self.log_entries.items) |*entry| {
            entry.deinit(allocator);
        }
        self.log_entries.deinit(allocator);
    }
};

/// Recover Raft state from WAL
pub fn recover(allocator: std.mem.Allocator, dir_path: []const u8) !RecoveredState {
    var state = RecoveredState{
        .current_term = 0,
        .voted_for = null,
        .log_entries = .empty,
    };

    var reader = WalReader.init(allocator, dir_path) catch |err| {
        if (err == WalError.FileNotFound or err == error.FileNotFound) {
            return state; // No WAL exists, return empty state
        }
        return err;
    };
    defer reader.deinit();

    // Replay all records
    while (try reader.readNext()) |*record| {
        defer record.deinit(allocator);

        switch (record.record_type) {
            .log_entry => {
                const entry = try raft.LogEntry.decode(allocator, record.data);
                try state.log_entries.append(allocator, entry);
            },
            .vote => {
                if (record.data.len >= 16) {
                    state.current_term = std.mem.readInt(u64, record.data[0..8], .little);
                    state.voted_for = std.mem.readInt(u64, record.data[8..16], .little);
                }
            },
            .term_update => {
                if (record.data.len >= 8) {
                    state.current_term = std.mem.readInt(u64, record.data[0..8], .little);
                    state.voted_for = null; // Vote resets on term change
                }
            },
            .snapshot_marker => {
                // Snapshot captures all state up to a point — discard replayed entries
                // that preceded it, as they're already reflected in the snapshot state.
                for (state.log_entries.items) |*entry| {
                    entry.deinit(allocator);
                }
                state.log_entries.clearRetainingCapacity();

                // Extract snapshot metadata if present
                if (record.data.len >= 16) {
                    const snapshot_term = std.mem.readInt(u64, record.data[0..8], .little);
                    const snapshot_index = std.mem.readInt(u64, record.data[8..16], .little);
                    _ = snapshot_index; // Index is for the state machine, not WAL recovery

                    // Update term if snapshot is more recent
                    if (snapshot_term > state.current_term) {
                        state.current_term = snapshot_term;
                    }
                }
                // Vote resets after snapshot restore
                state.voted_for = null;
            },
        }
    }

    return state;
}

// =============================================================================
// Utility for deleting WAL directory (for tests)
// =============================================================================

fn deleteTree(path: []const u8, allocator: std.mem.Allocator) void {
    // Delete all wal files first
    var idx: u32 = 0;
    while (idx < 1000) : (idx += 1) {
        const file_path = std.fmt.allocPrint(allocator, "{s}/wal-{x:0>8}.log", .{ path, idx }) catch break;
        defer allocator.free(file_path);
        unlinkFile(file_path);
    }
    // Then delete the directory
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    if (makePathZ(path, &buf)) |pathZ| {
        _ = std.c.rmdir(pathZ.ptr);
    }
}

// =============================================================================
// Tests
// =============================================================================

test "wal write and read" {
    const allocator = std.testing.allocator;

    // Create temp directory
    const dir = "/tmp/test-wal-1";
    defer deleteTree(dir, allocator);

    // Write records
    {
        var writer = try WalWriter.init(allocator, dir, 1);
        defer writer.deinit();

        try writer.writeEntry("entry1");
        try writer.writeEntry("entry2");
        try writer.writeVote(5, 2);
        try writer.sync();
    }

    // Read records back
    {
        var reader = try WalReader.init(allocator, dir);
        defer reader.deinit();

        var record1 = (try reader.readNext()).?;
        defer record1.deinit(allocator);
        try std.testing.expectEqual(RecordType.log_entry, record1.record_type);
        try std.testing.expectEqualStrings("entry1", record1.data);

        var record2 = (try reader.readNext()).?;
        defer record2.deinit(allocator);
        try std.testing.expectEqual(RecordType.log_entry, record2.record_type);
        try std.testing.expectEqualStrings("entry2", record2.data);

        var record3 = (try reader.readNext()).?;
        defer record3.deinit(allocator);
        try std.testing.expectEqual(RecordType.vote, record3.record_type);

        const record4 = try reader.readNext();
        try std.testing.expect(record4 == null);
    }
}

test "wal checksum verification" {
    const data = "test data";
    const crc = std.hash.Crc32.hash(data);
    try std.testing.expect(crc != 0);
}

test "wal recovery" {
    const allocator = std.testing.allocator;

    const dir = "/tmp/test-wal-recovery";
    defer deleteTree(dir, allocator);

    // Write some state
    {
        var writer = try WalWriter.init(allocator, dir, 1);
        defer writer.deinit();

        // Write a log entry
        const entry = raft.LogEntry{
            .term = 3,
            .index = 1,
            .command_type = .set,
            .data = "key=value",
        };
        const encoded = try entry.encode(allocator);
        defer allocator.free(encoded);

        try writer.writeEntry(encoded);
        try writer.writeVote(3, 2);
        try writer.sync();
    }

    // Recover state
    {
        var state = try recover(allocator, dir);
        defer state.deinit(allocator);

        try std.testing.expectEqual(@as(raft.Term, 3), state.current_term);
        try std.testing.expectEqual(@as(?raft.NodeId, 2), state.voted_for);
        try std.testing.expectEqual(@as(usize, 1), state.log_entries.items.len);
    }
}
