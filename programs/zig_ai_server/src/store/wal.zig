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
    ///
    /// Audit H4: open with `createFile(.truncate=false)` so the file is
    /// created if absent, otherwise re-opened in write mode without
    /// dropping its contents. The new entry is written at the current
    /// end-of-file via `writePositionalAll(len)` — no read of the
    /// existing WAL into memory. The previous implementation read the
    /// entire WAL, appended bytes in a heap buffer, and wrote it back
    /// in full, which is O(file_size) per append and turns a hot
    /// billing path into a disk-I/O DoS as the WAL grows.
    pub fn append(self: *WalWriter, io: Io, op: types.WalOp, payload: []const u8) !void {
        // Guard against payloads > 4GB (u32 length field)
        if (payload.len > std.math.maxInt(u32)) return error.PayloadTooLarge;

        // Build header: [1 op][4 len][4 crc32]
        var header: [9]u8 = undefined;
        header[0] = @intFromEnum(op);
        std.mem.writeInt(u32, header[1..5], @intCast(payload.len), .little);
        const crc = std.hash.Crc32.hash(payload);
        std.mem.writeInt(u32, header[5..9], crc, .little);

        var file = try Dir.cwd().createFile(io, self.file_path, .{ .truncate = false });
        defer file.close(io);

        const end = try file.length(io);
        // Write header then payload at the file's end. We do two
        // positional writes (rather than splatting through writer
        // buffers) so we never allocate a heap copy of the WAL or the
        // entry. Header + payload are < 4GB by the guard above.
        try file.writePositionalAll(io, &header, end);
        if (payload.len > 0) {
            try file.writePositionalAll(io, payload, end + header.len);
        }

        self.entry_count += 1;
    }

    /// Replay all WAL entries, calling the callback for each valid entry.
    /// The callback receives a user-provided context pointer so it can mutate state.
    pub fn replay(
        self: *WalWriter,
        io: Io,
        allocator: std.mem.Allocator,
        context: ?*anyopaque,
        callback: *const fn (ctx: ?*anyopaque, op: types.WalOp, payload: []const u8) void,
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
            callback(context, op, payload);
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

    /// Current size of the WAL file in bytes. Returns 0 if the file doesn't exist.
    /// Audit H4: stat the file via length() instead of reading the full
    /// contents into a heap buffer — the background flush thread calls
    /// this every 60s, so the old implementation read the entire WAL
    /// each minute just to compare against a 10MB rotation threshold.
    pub fn sizeBytes(self: *const WalWriter, io: Io) usize {
        var file = Dir.cwd().openFile(io, self.file_path, .{ .mode = .read_only }) catch return 0;
        defer file.close(io);
        const len = file.length(io) catch return 0;
        return @intCast(@min(len, std.math.maxInt(usize)));
    }
};
