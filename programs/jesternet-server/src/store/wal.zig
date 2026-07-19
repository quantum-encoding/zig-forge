// Write-Ahead Log — durable + batched append paths.
//
// NOT a literal lift from zig_ai_server/src/store/wal.zig. That impl
// reads the whole file, appends one entry, writes the whole file
// back — O(N) per write, a known scale ceiling. jesternet writes WAL
// on every ref update + every event during pushes; the AI server's
// pattern would die under load. This impl keeps a long-lived
// append-cursor + positional writes + the durability discipline the
// principal architect spelled out.
//
// On-disk format:
//
//   [4 bytes BE: magic "WAL1"]                   ┐ file header (once)
//   [4 bytes LE: version = 1]                    ┘
//   [1 byte: op_code]    ┐
//   [4 bytes LE: paylen] │ entry header (per entry)
//   [4 bytes LE: crc32]  │
//   [paylen bytes: payload]                      ┘
//   ... (repeat)
//
// Each in-memory entry sequence number (`seq`) is the count of
// successfully-appended entries since file inception. It is the
// value the events log writes into EventRow.seq, which becomes the
// SSE `id:` field. The durable-replay canary's `Last-Event-ID`
// reconnect path is satisfied by this — on reconnect with id=N,
// replay() walks from the start and emits entries with seq > N.
//
// Durability discipline (principal architect's #62 note):
//
//   appendDurable(io, op, payload):
//     hold mutex → write entry → fsync(file) → release mutex → return seq.
//     The fsync happens BEFORE the seq is returned, so any caller
//     that subsequently sends 200 OK (e.g. git-receive-pack handler)
//     can trust that the entry survives a crash. Skipping the fsync
//     here would mean a crash between "200 OK" and OS flush could
//     lose an acknowledged push — the ref-update WAL entry isn't on
//     disk, but the client has already deleted its local branch.
//
//   appendBatched(io, op, payload):
//     hold mutex → write entry → release mutex → return seq.
//     No fsync. The OS may buffer; the background sync thread runs
//     fsync periodically. On crash we lose ≤(periodic_interval +
//     OS write-back delay) of batched writes. Caller accepts that
//     for non-durability-critical ops (token_audit, last_used_at,
//     loc updates, event_seen flips).

const std = @import("std");
const types = @import("types.zig");

const Io = std.Io;
const WAL_MAGIC = [4]u8{ 'W', 'A', 'L', '1' };
const WAL_VERSION: u32 = 1;
const HEADER_LEN: u64 = 8; // magic + version

pub const WalWriter = struct {
    allocator: std.mem.Allocator,
    file: Io.File,
    path: []const u8,

    /// Position of next write (== current file size).
    cursor: u64,
    /// Monotonic entry counter. Incremented after each successful
    /// append; returned to callers. Survives restart via replay() at
    /// boot (replay sets next_seq to the highest seen seq + 1).
    next_seq: u64,

    /// Serializes cursor-and-write. Two threads doing positional
    /// writes at the same cursor would interleave bytes. A parking
    /// mutex (`std.Io.Mutex`), NOT a spin loop: `appendInternal` holds
    /// this lock across `file.sync(io)` on the durable path, so a busy
    /// spin would burn a full core per contending thread for the whole
    /// fsync. `appendInternal` already has the request's `io`, so it
    /// parks/wakes through that.
    mutex: Io.Mutex = .init,

    /// Open or create the WAL file at `path`. If the file exists it's
    /// opened in append-without-truncate mode; if it's new, the header
    /// is written. Caller must invoke `replay()` after open to rebuild
    /// the seq counter; see `Store.recover()`.
    pub fn open(allocator: std.mem.Allocator, io: Io, path: []const u8) !WalWriter {
        const dir = Io.Dir.cwd();
        const file = try dir.createFile(io, path, .{ .truncate = false, .read = true });

        const existing_len = try file.length(io);
        var cursor: u64 = existing_len;

        if (existing_len == 0) {
            // Fresh file — write the magic + version header.
            var header: [HEADER_LEN]u8 = undefined;
            @memcpy(header[0..4], &WAL_MAGIC);
            std.mem.writeInt(u32, header[4..8], WAL_VERSION, .little);
            try file.writePositionalAll(io, &header, 0);
            try file.sync(io); // header is durability-critical
            cursor = HEADER_LEN;
        } else if (existing_len < HEADER_LEN) {
            return error.WalCorrupt;
        } else {
            // Verify magic. A short read would leave `hdr_buf` partly
            // undefined and the magic compare could pass on stack
            // garbage — treat anything less than a full header as
            // corruption rather than trusting the leftover bytes.
            var hdr_buf: [HEADER_LEN]u8 = undefined;
            const data: [1][]u8 = .{&hdr_buf};
            const got = try file.readPositional(io, &data, 0);
            if (got < HEADER_LEN) return error.WalCorrupt;
            if (!std.mem.eql(u8, hdr_buf[0..4], &WAL_MAGIC)) return error.WalCorrupt;
        }

        return .{
            .allocator = allocator,
            .file = file,
            .path = path,
            .cursor = cursor,
            .next_seq = 1, // updated by replay()
        };
    }

    pub fn close(self: *WalWriter, io: Io) void {
        const files: [1]Io.File = .{self.file};
        io.vtable.fileClose(io.userdata, &files);
    }

    /// Sync the file. The background flush thread calls this; callers
    /// can also call directly during graceful shutdown.
    pub fn sync(self: *WalWriter, io: Io) !void {
        try self.file.sync(io);
    }

    /// Durable append. Writes entry, fsyncs, returns seq. CRITICAL
    /// for ref updates and commit.pushed events — see the durability
    /// discipline note at the top of this file.
    pub fn appendDurable(
        self: *WalWriter,
        io: Io,
        op: types.WalOp,
        payload: []const u8,
    ) !u64 {
        std.debug.assert(op.isDurable()); // catch caller-side classification mistakes early
        return self.appendInternal(io, op, payload, true);
    }

    /// Batched append. Writes entry, returns seq. No fsync. The
    /// background sync thread (or a manual sync() call) flushes
    /// eventually. Caller accepts a small loss window on crash.
    pub fn appendBatched(
        self: *WalWriter,
        io: Io,
        op: types.WalOp,
        payload: []const u8,
    ) !u64 {
        std.debug.assert(!op.isDurable());
        return self.appendInternal(io, op, payload, false);
    }

    fn appendInternal(
        self: *WalWriter,
        io: Io,
        op: types.WalOp,
        payload: []const u8,
        do_sync: bool,
    ) !u64 {
        if (payload.len > std.math.maxInt(u32)) return error.PayloadTooLarge;

        var header: [9]u8 = undefined;
        header[0] = @intFromEnum(op);
        std.mem.writeInt(u32, header[1..5], @intCast(payload.len), .little);
        const crc = std.hash.Crc32.hash(payload);
        std.mem.writeInt(u32, header[5..9], crc, .little);

        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        const start = self.cursor;

        // Two-part write: header first, then payload. We write the
        // header at `start` and the payload at `start + 9`. A torn
        // write between these is detectable on replay via the CRC32
        // (payload won't match the recorded checksum).
        try self.file.writePositionalAll(io, &header, start);
        if (payload.len > 0) {
            try self.file.writePositionalAll(io, payload, start + header.len);
        }

        if (do_sync) try self.file.sync(io);

        self.cursor = start + header.len + payload.len;
        const seq = self.next_seq;
        self.next_seq += 1;
        return seq;
    }

    /// Replay entries from the start of the file, calling `callback`
    /// for each valid entry in seq order. Used at boot to rebuild
    /// in-memory state. Sets `self.next_seq` to last_seen_seq + 1.
    /// On a corrupted entry (bad CRC or truncated), replay stops at
    /// that point — partial writes from a crash are conservatively
    /// dropped rather than carried forward.
    pub fn replay(
        self: *WalWriter,
        io: Io,
        ctx: ?*anyopaque,
        callback: *const fn (ctx: ?*anyopaque, seq: u64, op: types.WalOp, payload: []const u8) void,
    ) !u64 {
        const total_len = try self.file.length(io);
        if (total_len <= HEADER_LEN) {
            self.next_seq = 1;
            return 0;
        }

        var pos: u64 = HEADER_LEN;
        var seq: u64 = 1;
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        defer buf.deinit(self.allocator);

        while (pos + 9 <= total_len) {
            // Read header. A short read here means the file ends mid-
            // header despite the `pos + 9 <= total_len` guard (a race
            // with a concurrent truncation, or an I/O anomaly) — stop
            // rather than interpret undefined bytes as a payload length.
            var hdr_buf: [9]u8 = undefined;
            const hdr_data: [1][]u8 = .{&hdr_buf};
            const hdr_read = try self.file.readPositional(io, &hdr_data, pos);
            if (hdr_read < hdr_buf.len) break;

            const op_byte = hdr_buf[0];
            const payload_len = std.mem.readInt(u32, hdr_buf[1..5], .little);
            const stored_crc = std.mem.readInt(u32, hdr_buf[5..9], .little);
            const next_pos = pos + 9 + payload_len;
            if (next_pos > total_len) break; // truncated tail

            // Read payload. A short read (fewer than payload_len bytes)
            // means a truncated tail — stop, same as the CRC path below.
            try buf.resize(self.allocator, payload_len);
            const pl_data: [1][]u8 = .{buf.items};
            const pl_read = try self.file.readPositional(io, &pl_data, pos + 9);
            if (pl_read < payload_len) break;

            const computed_crc = std.hash.Crc32.hash(buf.items);
            if (computed_crc != stored_crc) break; // corrupt entry; stop

            const op: types.WalOp = @enumFromInt(op_byte);
            callback(ctx, seq, op, buf.items);

            pos = next_pos;
            seq += 1;
        }

        self.next_seq = seq;
        self.cursor = pos;
        return seq - 1;
    }

    pub fn sizeBytes(self: *const WalWriter) u64 {
        return self.cursor;
    }
};

// ── Tests ──

const testing = std.testing;

fn collectAll(ctx: ?*anyopaque, seq: u64, op: types.WalOp, payload: []const u8) void {
    const list: *std.ArrayListUnmanaged(struct {
        seq: u64,
        op: types.WalOp,
        payload: []u8,
    }) = @alignCast(@ptrCast(ctx orelse return));
    const dup = testing.allocator.dupe(u8, payload) catch return;
    list.append(testing.allocator, .{ .seq = seq, .op = op, .payload = dup }) catch {};
}

test "open creates file with header, sizeBytes reflects it" {
    var io_threaded: Io.Threaded = .init(testing.allocator, .{});
    const io = io_threaded.io();

    const path = "test-wal-fresh.log";
    Io.Dir.cwd().deleteFile(io, path) catch {};
    defer Io.Dir.cwd().deleteFile(io, path) catch {};

    var wal = try WalWriter.open(testing.allocator, io, path);
    defer wal.close(io);
    try testing.expectEqual(@as(u64, HEADER_LEN), wal.sizeBytes());
}

test "appendDurable + replay round-trip" {
    var io_threaded: Io.Threaded = .init(testing.allocator, .{});
    const io = io_threaded.io();

    const path = "test-wal-durable.log";
    Io.Dir.cwd().deleteFile(io, path) catch {};
    defer Io.Dir.cwd().deleteFile(io, path) catch {};

    {
        var wal = try WalWriter.open(testing.allocator, io, path);
        defer wal.close(io);

        const seq1 = try wal.appendDurable(io, .ref_update, "ref-payload-1");
        const seq2 = try wal.appendDurable(io, .event_insert, "event-payload-2");
        try testing.expectEqual(@as(u64, 1), seq1);
        try testing.expectEqual(@as(u64, 2), seq2);
    }

    // Reopen and replay.
    {
        var wal = try WalWriter.open(testing.allocator, io, path);
        defer wal.close(io);

        const Entry = struct {
            seq: u64,
            op: types.WalOp,
            payload: []u8,
        };
        var collected: std.ArrayListUnmanaged(Entry) = .empty;
        defer {
            for (collected.items) |e| testing.allocator.free(e.payload);
            collected.deinit(testing.allocator);
        }

        const last_seq = try wal.replay(io, &collected, collectAll);
        try testing.expectEqual(@as(u64, 2), last_seq);
        try testing.expectEqual(@as(usize, 2), collected.items.len);
        try testing.expectEqual(types.WalOp.ref_update, collected.items[0].op);
        try testing.expectEqualStrings("ref-payload-1", collected.items[0].payload);
        try testing.expectEqual(types.WalOp.event_insert, collected.items[1].op);
        try testing.expectEqualStrings("event-payload-2", collected.items[1].payload);
        // next_seq should be set so subsequent appends continue from 3.
        try testing.expectEqual(@as(u64, 3), wal.next_seq);
    }
}

test "appendBatched works (no fsync, but writes are visible immediately)" {
    var io_threaded: Io.Threaded = .init(testing.allocator, .{});
    const io = io_threaded.io();

    const path = "test-wal-batched.log";
    Io.Dir.cwd().deleteFile(io, path) catch {};
    defer Io.Dir.cwd().deleteFile(io, path) catch {};

    var wal = try WalWriter.open(testing.allocator, io, path);
    defer wal.close(io);

    const seq = try wal.appendBatched(io, .token_audit_insert, "audit-row");
    try testing.expectEqual(@as(u64, 1), seq);
    try testing.expect(wal.sizeBytes() > HEADER_LEN);
}

test "appendDurable rejects batched op codes in debug" {
    // The isDurable assertion is debug-build only, so the test
    // documents the classification rather than panicking. Run-time
    // check: passing a batched op to appendDurable hits the
    // std.debug.assert; passing a durable op to appendBatched hits
    // the same. This guards against the WAL writer being misused
    // (e.g. token_audit accidentally fsync'd on every push, killing
    // throughput).
    try testing.expect(types.WalOp.ref_update.isDurable());
    try testing.expect(!types.WalOp.token_audit_insert.isDurable());
}

test "replay stops at corrupt entry (CRC mismatch)" {
    var io_threaded: Io.Threaded = .init(testing.allocator, .{});
    const io = io_threaded.io();

    const path = "test-wal-corrupt.log";
    Io.Dir.cwd().deleteFile(io, path) catch {};
    defer Io.Dir.cwd().deleteFile(io, path) catch {};

    // Write two good entries, then corrupt the second's payload byte.
    {
        var wal = try WalWriter.open(testing.allocator, io, path);
        defer wal.close(io);
        _ = try wal.appendDurable(io, .ref_update, "good-1");
        _ = try wal.appendDurable(io, .ref_update, "good-2");
    }

    // Flip one byte in the second entry's payload region.
    const dir = Io.Dir.cwd();
    var f = try dir.createFile(io, path, .{ .truncate = false, .read = true });
    defer {
        const arr: [1]Io.File = .{f};
        io.vtable.fileClose(io.userdata, &arr);
    }
    // First entry: header at HEADER_LEN(8), payload at 8+9=17, len 6.
    // Second entry: header at 8+9+6=23, payload at 23+9=32, len 6.
    // Flip byte at offset 32 (start of second payload).
    var byte: [1]u8 = undefined;
    const rd: [1][]u8 = .{&byte};
    _ = try f.readPositional(io, &rd, 32);
    byte[0] ^= 0xff;
    try f.writePositionalAll(io, &byte, 32);
    try f.sync(io);

    // Reopen and replay; expect only 1 entry recovered.
    var wal = try WalWriter.open(testing.allocator, io, path);
    defer wal.close(io);

    const Entry = struct { seq: u64, op: types.WalOp, payload: []u8 };
    var collected: std.ArrayListUnmanaged(Entry) = .empty;
    defer {
        for (collected.items) |e| testing.allocator.free(e.payload);
        collected.deinit(testing.allocator);
    }
    const last_seq = try wal.replay(io, &collected, collectAll);
    try testing.expectEqual(@as(u64, 1), last_seq);
    try testing.expectEqual(@as(usize, 1), collected.items.len);
    try testing.expectEqualStrings("good-1", collected.items[0].payload);
}
