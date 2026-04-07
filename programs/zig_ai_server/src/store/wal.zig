// Write-Ahead Log — append-only, CRC32-checked entries
// Every mutation is written here before updating in-memory state.
// On crash recovery, replay from last snapshot.
//
// Entry format:
//   [1 byte: op_type] [4 bytes: payload_len LE] [4 bytes: CRC32] [N bytes: payload]

const std = @import("std");
const Io = std.Io;
const Dir = std.Io.Dir;
const types = @import("types.zig");

pub const WAL_MAGIC: u32 = 0x57414C31; // "WAL1"

pub const WalWriter = struct {
    allocator: std.mem.Allocator,
    file_path: []const u8,
    entry_count: u64,

    /// Append a WAL entry. Writes op + payload_len + CRC32 + payload.
    /// Uses std.Io for file operations.
    pub fn append(self: *WalWriter, io: Io, op: types.WalOp, payload: []const u8) !void {
        // Open file in append mode
        var file = Dir.cwd().openFile(io, self.file_path, .{
            .mode = .write_only,
        }) catch {
            // File might not exist yet — create it
            file = try Dir.cwd().createFile(io, self.file_path, .{});
            break :blk;
        };
        _ = &file;

        // Build header: [1 op][4 len][4 crc32]
        var header: [9]u8 = undefined;
        header[0] = @intFromEnum(op);
        std.mem.writeInt(u32, header[1..5], @intCast(payload.len), .little);
        const crc = std.hash.Crc32.hash(payload);
        std.mem.writeInt(u32, header[5..9], crc, .little);

        // Write header + payload
        // Use Dir.writeFile which creates the file and writes atomically
        // For append, we need to open, seek to end, write
        // Simpler: append via a collected buffer
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        defer buf.deinit(self.allocator);

        // Read existing content
        const existing = Dir.cwd().readFileAlloc(io, self.file_path, self.allocator, .unlimited) catch
            try self.allocator.alloc(u8, 0);
        defer self.allocator.free(existing);

        try buf.appendSlice(self.allocator, existing);
        try buf.appendSlice(self.allocator, &header);
        try buf.appendSlice(self.allocator, payload);

        // Write back
        Dir.cwd().writeFile(io, .{
            .sub_path = self.file_path,
            .data = buf.items,
        }) catch |err| {
            return err;
        };

        self.entry_count += 1;
    }

    /// Replay all WAL entries, calling the callback for each valid entry.
    pub fn replay(
        self: *WalWriter,
        io: Io,
        allocator: std.mem.Allocator,
        callback: *const fn (op: types.WalOp, payload: []const u8) void,
    ) !u64 {
        const data = Dir.cwd().readFileAlloc(io, self.file_path, allocator, .unlimited) catch {
            return 0; // No WAL file — fresh start
        };
        defer allocator.free(data);

        var pos: usize = 0;
        var count: u64 = 0;

        while (pos + 9 <= data.len) {
            const op_byte = data[pos];
            const payload_len = std.mem.readInt(u32, data[pos + 1 ..][0..4], .little);
            const stored_crc = std.mem.readInt(u32, data[pos + 5 ..][0..4], .little);
            pos += 9;

            if (pos + payload_len > data.len) break; // Truncated entry

            const payload = data[pos .. pos + payload_len];
            const computed_crc = std.hash.Crc32.hash(payload);

            if (computed_crc != stored_crc) {
                // Corrupted entry — stop replay here (conservative)
                break;
            }

            const op: types.WalOp = @enumFromInt(op_byte);
            callback(op, payload);
            pos += payload_len;
            count += 1;
        }

        self.entry_count = count;
        return count;
    }

    /// Truncate the WAL file (called after snapshot)
    pub fn truncate(self: *WalWriter, io: Io) void {
        Dir.cwd().writeFile(io, .{
            .sub_path = self.file_path,
            .data = "",
        }) catch {};
        self.entry_count = 0;
    }
};
