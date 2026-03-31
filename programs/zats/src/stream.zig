//! JetStream Stream Engine
//!
//! A stream captures messages from subjects and stores them durably.
//! Supports retention limits, deduplication, and message access by sequence or subject.

const std = @import("std");
const store_mod = @import("store/store.zig");
const memory_store_mod = @import("store/memory_store.zig");
const file_store_mod = @import("store/file_store.zig");
const headers_mod = @import("headers.zig");

pub const RetentionPolicy = enum {
    limits, // Default — discard old when limits exceeded
    interest, // Discard when no consumers have interest
    work_queue, // Discard after acknowledgement
};

pub const DiscardPolicy = enum {
    old, // Discard oldest messages
    new, // Reject new messages
};

pub const StorageType = enum {
    memory,
    file,
};

pub const StreamConfig = struct {
    name: []const u8 = "",
    subjects: []const []const u8 = &.{},
    retention: RetentionPolicy = .limits,
    max_msgs: i64 = -1, // -1 = unlimited
    max_bytes: i64 = -1,
    max_age_ns: i64 = 0, // 0 = unlimited, nanoseconds
    max_msg_size: i32 = -1, // -1 = unlimited
    storage: StorageType = .memory,
    no_ack: bool = false,
    discard: DiscardPolicy = .old,
    duplicate_window_ns: i64 = 120_000_000_000, // 2 minutes in nanoseconds
};

pub const StreamState = struct {
    messages: u64,
    bytes: u64,
    first_seq: u64,
    last_seq: u64,
    first_ts: i64,
    last_ts: i64,
    consumer_count: u64,
};

pub const StreamInfo = struct {
    config: StreamConfig,
    state: StreamState,
    created_ns: i64,
};

pub const PubAck = struct {
    stream: []const u8,
    seq: u64,
    duplicate: bool,
};

const DedupEntry = struct {
    seq: u64,
    timestamp_ns: i64,
};

pub const Stream = struct {
    config: StreamConfig,
    store: store_mod.MessageStore,
    mem_store: ?*memory_store_mod.MemoryStore,
    file_store_ptr: ?*file_store_mod.FileStore,
    next_seq: u64,
    first_seq: u64,
    first_ts: i64,
    last_ts: i64,
    created_ns: i64,
    dedup_map: std.StringHashMapUnmanaged(DedupEntry),
    consumer_count: u32,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, config: StreamConfig) !*Stream {
        return initWithStoreDir(allocator, config, null);
    }

    pub fn initWithStoreDir(allocator: std.mem.Allocator, config: StreamConfig, store_dir: ?[]const u8) !*Stream {
        const s = try allocator.create(Stream);
        errdefer allocator.destroy(s);

        const now_ns = getNowNs();

        if (config.storage == .file) {
            if (store_dir) |dir| {
                // Ensure parent store_dir exists
                ensureDir(dir);

                // Build stream-specific directory: {store_dir}/{stream_name}/
                const stream_dir = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir, config.name });
                defer allocator.free(stream_dir);

                const fs = try file_store_mod.FileStore.init(allocator, stream_dir);

                s.* = .{
                    .config = config,
                    .mem_store = null,
                    .file_store_ptr = fs,
                    .store = fs.messageStore(),
                    .next_seq = 1,
                    .first_seq = 0,
                    .first_ts = 0,
                    .last_ts = 0,
                    .created_ns = now_ns,
                    .dedup_map = .{},
                    .consumer_count = 0,
                    .allocator = allocator,
                };

                // After recovery, sync next_seq/first_seq from store state
                if (fs.msg_count > 0) {
                    s.rebuildSeqState();
                }

                return s;
            }
        }

        // Default: memory store
        const ms = try allocator.create(memory_store_mod.MemoryStore);
        ms.* = memory_store_mod.MemoryStore.init(allocator);

        s.* = .{
            .config = config,
            .mem_store = ms,
            .file_store_ptr = null,
            .store = ms.messageStore(),
            .next_seq = 1,
            .first_seq = 0,
            .first_ts = 0,
            .last_ts = 0,
            .created_ns = now_ns,
            .dedup_map = .{},
            .consumer_count = 0,
            .allocator = allocator,
        };
        return s;
    }

    pub fn deinit(self: *Stream) void {
        // Free dedup keys
        var it = self.dedup_map.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.dedup_map.deinit(self.allocator);

        if (self.file_store_ptr) |fs| {
            fs.deinit();
        }
        if (self.mem_store) |ms| {
            ms.deinit();
            self.allocator.destroy(ms);
        }
        self.allocator.destroy(self);
    }

    /// Rebuild sequence state from file store after recovery.
    fn rebuildSeqState(self: *Stream) void {
        // Scan index to find min/max sequence
        var min_seq: u64 = std.math.maxInt(u64);
        var max_seq: u64 = 0;

        const fs = self.file_store_ptr orelse return;
        var idx_it = fs.index.iterator();
        while (idx_it.next()) |entry| {
            const seq = entry.key_ptr.*;
            if (seq < min_seq) min_seq = seq;
            if (seq > max_seq) max_seq = seq;
        }

        if (max_seq > 0) {
            self.first_seq = min_seq;
            self.next_seq = max_seq + 1;

            // Recover timestamps from first and last messages
            if (self.store.load(min_seq)) |msg| {
                self.first_ts = msg.timestamp_ns;
                self.allocator.free(msg.subject);
                if (msg.headers) |h| self.allocator.free(h);
                self.allocator.free(msg.data);
            }
            if (self.store.load(max_seq)) |msg| {
                self.last_ts = msg.timestamp_ns;
                self.allocator.free(msg.subject);
                if (msg.headers) |h| self.allocator.free(h);
                self.allocator.free(msg.data);
            }
        }
    }

    /// Store a message in the stream. Returns a PubAck.
    pub fn storeMessage(self: *Stream, subject: []const u8, hdrs: ?[]const u8, data: []const u8, msg_id: ?[]const u8) !PubAck {
        const now_ns = getNowNs();

        // Check max_msg_size
        if (self.config.max_msg_size > 0) {
            const total_size = (if (hdrs) |h| h.len else 0) + data.len;
            if (total_size > @as(usize, @intCast(self.config.max_msg_size))) {
                return error.MaxPayloadExceeded;
            }
        }

        // Dedup check
        if (msg_id) |mid| {
            if (self.dedup_map.get(mid)) |entry| {
                // Check if within dedup window
                if (self.config.duplicate_window_ns > 0) {
                    const age = now_ns - entry.timestamp_ns;
                    if (age < self.config.duplicate_window_ns) {
                        return .{
                            .stream = self.config.name,
                            .seq = entry.seq,
                            .duplicate = true,
                        };
                    }
                }
            }
        }

        // Check discard policy for new messages
        if (self.config.discard == .new) {
            if (self.config.max_msgs > 0 and self.store.count() >= @as(u64, @intCast(self.config.max_msgs))) {
                return error.MaxMsgsExceeded;
            }
            if (self.config.max_bytes > 0 and self.store.bytes() + (if (hdrs) |h| h.len else 0) + data.len > @as(u64, @intCast(self.config.max_bytes))) {
                return error.MaxBytesExceeded;
            }
        }

        const seq = self.next_seq;
        self.next_seq += 1;

        try self.store.store(seq, subject, hdrs, data, now_ns);

        if (self.first_seq == 0) {
            self.first_seq = seq;
            self.first_ts = now_ns;
        }
        self.last_ts = now_ns;

        // Record dedup entry
        if (msg_id) |mid| {
            const owned_mid = try self.allocator.dupe(u8, mid);
            // Remove old entry if exists (to replace)
            if (self.dedup_map.fetchRemove(mid)) |old| {
                self.allocator.free(old.key);
            }
            try self.dedup_map.put(self.allocator, owned_mid, .{ .seq = seq, .timestamp_ns = now_ns });
        }

        // Enforce retention limits
        self.enforceRetention();

        return .{
            .stream = self.config.name,
            .seq = seq,
            .duplicate = false,
        };
    }

    /// Get a message by sequence number.
    pub fn getMessage(self: *Stream, seq: u64) ?store_mod.StoredMessage {
        return self.store.load(seq);
    }

    /// Get the last message for a subject.
    pub fn getMessageBySubject(self: *Stream, subject: []const u8) ?store_mod.StoredMessage {
        return self.store.loadBySubject(subject);
    }

    /// Delete a specific message by sequence.
    pub fn deleteMessage(self: *Stream, seq: u64) bool {
        const deleted = self.store.delete(seq);
        if (deleted and seq == self.first_seq) {
            self.advanceFirstSeq();
        }
        return deleted;
    }

    /// Purge messages, optionally filtered by subject.
    pub fn purge(self: *Stream, subject_filter: ?[]const u8) u64 {
        const purged = self.store.purge(subject_filter);
        if (subject_filter == null) {
            // Full purge — reset sequences
            self.first_seq = self.next_seq;
            self.first_ts = 0;
            self.last_ts = 0;
        } else {
            self.advanceFirstSeq();
        }
        return purged;
    }

    /// Get stream info.
    pub fn info(self: *Stream) StreamInfo {
        return .{
            .config = self.config,
            .state = .{
                .messages = self.store.count(),
                .bytes = self.store.bytes(),
                .first_seq = if (self.store.count() > 0) self.first_seq else 0,
                .last_seq = if (self.next_seq > 1) self.next_seq - 1 else 0,
                .first_ts = self.first_ts,
                .last_ts = self.last_ts,
                .consumer_count = self.consumer_count,
            },
            .created_ns = self.created_ns,
        };
    }

    fn enforceRetention(self: *Stream) void {
        // Max messages
        if (self.config.max_msgs > 0) {
            const max: u64 = @intCast(self.config.max_msgs);
            while (self.store.count() > max) {
                if (!self.store.delete(self.first_seq)) break;
                self.advanceFirstSeq();
            }
        }

        // Max bytes
        if (self.config.max_bytes > 0) {
            const max: u64 = @intCast(self.config.max_bytes);
            while (self.store.bytes() > max) {
                if (!self.store.delete(self.first_seq)) break;
                self.advanceFirstSeq();
            }
        }

        // Max age
        if (self.config.max_age_ns > 0) {
            const now_ns = getNowNs();
            const cutoff = now_ns - self.config.max_age_ns;

            while (self.store.count() > 0) {
                const msg = self.store.load(self.first_seq) orelse break;
                const ts = msg.timestamp_ns;
                self.freeLoadedMsg(msg);
                if (ts >= cutoff) break;
                _ = self.store.delete(self.first_seq);
                self.advanceFirstSeq();
            }
        }

        // Dedup cleanup
        self.cleanupDedup();
    }

    /// Remove expired entries from the dedup map.
    pub fn cleanupDedup(self: *Stream) void {
        if (self.config.duplicate_window_ns <= 0) return;

        const now_ns = getNowNs();
        var to_remove: std.ArrayListUnmanaged([]const u8) = .empty;
        defer to_remove.deinit(self.allocator);

        var it = self.dedup_map.iterator();
        while (it.next()) |entry| {
            const age = now_ns - entry.value_ptr.timestamp_ns;
            if (age > self.config.duplicate_window_ns) {
                to_remove.append(self.allocator, entry.key_ptr.*) catch {};
            }
        }

        for (to_remove.items) |key| {
            if (self.dedup_map.fetchRemove(key)) |removed| {
                self.allocator.free(removed.key);
            }
        }
    }

    fn advanceFirstSeq(self: *Stream) void {
        // Find next existing message
        var seq = self.first_seq + 1;
        while (seq < self.next_seq) : (seq += 1) {
            if (self.store.load(seq)) |msg| {
                self.first_seq = seq;
                self.first_ts = msg.timestamp_ns;
                self.freeLoadedMsg(msg);
                return;
            }
        }
        // No more messages
        self.first_seq = self.next_seq;
        self.first_ts = 0;
    }

    /// Free a loaded message if using file store (which returns owned allocations).
    fn freeLoadedMsg(self: *Stream, msg: store_mod.StoredMessage) void {
        if (self.file_store_ptr != null) {
            self.allocator.free(msg.subject);
            if (msg.headers) |h| self.allocator.free(h);
            self.allocator.free(msg.data);
        }
    }
};

extern "c" fn time(t: ?*isize) isize;

fn getNowNs() i64 {
    return @as(i64, time(null)) * 1_000_000_000;
}

fn ensureDir(path: []const u8) void {
    var buf: [4096]u8 = undefined;
    if (path.len >= buf.len) return;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    const pathZ: [*:0]const u8 = buf[0..path.len :0];
    _ = std.c.mkdir(pathZ, 0o755);
}

/// Validate a stream name: no spaces, tabs, dots, wildcards, or dollar signs.
pub fn validateStreamName(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |c| {
        switch (c) {
            ' ', '\t', '.', '*', '>', '$' => return false,
            else => {},
        }
    }
    return true;
}

// --- Tests ---

test "stream create and store message" {
    const allocator = std.testing.allocator;
    const subjects = [_][]const u8{"orders.>"};
    var stream = try Stream.init(allocator, .{
        .name = "ORDERS",
        .subjects = &subjects,
    });
    defer stream.deinit();

    const ack = try stream.storeMessage("orders.new", null, "order1", null);
    try std.testing.expectEqualStrings("ORDERS", ack.stream);
    try std.testing.expectEqual(@as(u64, 1), ack.seq);
    try std.testing.expect(!ack.duplicate);
}

test "stream get message by sequence" {
    const allocator = std.testing.allocator;
    var stream = try Stream.init(allocator, .{ .name = "TEST" });
    defer stream.deinit();

    _ = try stream.storeMessage("foo", null, "data1", null);
    _ = try stream.storeMessage("bar", null, "data2", null);

    const msg = stream.getMessage(1).?;
    try std.testing.expectEqualStrings("foo", msg.subject);
    try std.testing.expectEqualStrings("data1", msg.data);

    const msg2 = stream.getMessage(2).?;
    try std.testing.expectEqualStrings("data2", msg2.data);

    try std.testing.expect(stream.getMessage(99) == null);
}

test "stream get message by subject (last)" {
    const allocator = std.testing.allocator;
    var stream = try Stream.init(allocator, .{ .name = "TEST" });
    defer stream.deinit();

    _ = try stream.storeMessage("foo", null, "first", null);
    _ = try stream.storeMessage("foo", null, "second", null);

    const msg = stream.getMessageBySubject("foo").?;
    try std.testing.expectEqual(@as(u64, 2), msg.sequence);
    try std.testing.expectEqualStrings("second", msg.data);
}

test "stream delete message" {
    const allocator = std.testing.allocator;
    var stream = try Stream.init(allocator, .{ .name = "TEST" });
    defer stream.deinit();

    _ = try stream.storeMessage("foo", null, "data", null);
    try std.testing.expect(stream.deleteMessage(1));
    try std.testing.expect(stream.getMessage(1) == null);
    try std.testing.expect(!stream.deleteMessage(1));
}

test "stream purge all" {
    const allocator = std.testing.allocator;
    var stream = try Stream.init(allocator, .{ .name = "TEST" });
    defer stream.deinit();

    _ = try stream.storeMessage("foo", null, "a", null);
    _ = try stream.storeMessage("bar", null, "b", null);

    const purged = stream.purge(null);
    try std.testing.expectEqual(@as(u64, 2), purged);

    const si = stream.info();
    try std.testing.expectEqual(@as(u64, 0), si.state.messages);
}

test "stream purge by subject" {
    const allocator = std.testing.allocator;
    var stream = try Stream.init(allocator, .{ .name = "TEST" });
    defer stream.deinit();

    _ = try stream.storeMessage("foo", null, "a", null);
    _ = try stream.storeMessage("bar", null, "b", null);
    _ = try stream.storeMessage("foo", null, "c", null);

    const purged = stream.purge("foo");
    try std.testing.expectEqual(@as(u64, 2), purged);
    try std.testing.expectEqual(@as(u64, 1), stream.info().state.messages);
}

test "stream max_msgs retention" {
    const allocator = std.testing.allocator;
    var stream = try Stream.init(allocator, .{
        .name = "TEST",
        .max_msgs = 2,
    });
    defer stream.deinit();

    _ = try stream.storeMessage("foo", null, "a", null);
    _ = try stream.storeMessage("foo", null, "b", null);
    _ = try stream.storeMessage("foo", null, "c", null);

    try std.testing.expectEqual(@as(u64, 2), stream.info().state.messages);
    // First message should be gone
    try std.testing.expect(stream.getMessage(1) == null);
    try std.testing.expect(stream.getMessage(2) != null);
    try std.testing.expect(stream.getMessage(3) != null);
}

test "stream max_bytes retention" {
    const allocator = std.testing.allocator;
    var stream = try Stream.init(allocator, .{
        .name = "TEST",
        .max_bytes = 10,
    });
    defer stream.deinit();

    _ = try stream.storeMessage("foo", null, "12345", null); // 5 bytes
    _ = try stream.storeMessage("foo", null, "67890", null); // 5 bytes, total=10
    _ = try stream.storeMessage("foo", null, "abcde", null); // 5 bytes, over limit

    // Should have evicted first message
    try std.testing.expect(stream.getMessage(1) == null);
    try std.testing.expectEqual(@as(u64, 2), stream.info().state.messages);
}

test "stream deduplication" {
    const allocator = std.testing.allocator;
    var stream = try Stream.init(allocator, .{
        .name = "TEST",
        .duplicate_window_ns = 120_000_000_000,
    });
    defer stream.deinit();

    const ack1 = try stream.storeMessage("foo", null, "data", "msg-1");
    try std.testing.expectEqual(@as(u64, 1), ack1.seq);
    try std.testing.expect(!ack1.duplicate);

    // Same msg_id should be detected as duplicate
    const ack2 = try stream.storeMessage("foo", null, "data", "msg-1");
    try std.testing.expectEqual(@as(u64, 1), ack2.seq);
    try std.testing.expect(ack2.duplicate);

    // Different msg_id should succeed
    const ack3 = try stream.storeMessage("foo", null, "data2", "msg-2");
    try std.testing.expectEqual(@as(u64, 2), ack3.seq);
    try std.testing.expect(!ack3.duplicate);
}

test "stream info" {
    const allocator = std.testing.allocator;
    var stream = try Stream.init(allocator, .{ .name = "TEST" });
    defer stream.deinit();

    _ = try stream.storeMessage("foo", null, "hello", null);
    _ = try stream.storeMessage("bar", null, "world", null);

    const si = stream.info();
    try std.testing.expectEqualStrings("TEST", si.config.name);
    try std.testing.expectEqual(@as(u64, 2), si.state.messages);
    try std.testing.expectEqual(@as(u64, 1), si.state.first_seq);
    try std.testing.expectEqual(@as(u64, 2), si.state.last_seq);
}

test "stream discard new policy" {
    const allocator = std.testing.allocator;
    var stream = try Stream.init(allocator, .{
        .name = "TEST",
        .max_msgs = 2,
        .discard = .new,
    });
    defer stream.deinit();

    _ = try stream.storeMessage("foo", null, "a", null);
    _ = try stream.storeMessage("foo", null, "b", null);

    // Third message should be rejected
    const result = stream.storeMessage("foo", null, "c", null);
    try std.testing.expectError(error.MaxMsgsExceeded, result);
    try std.testing.expectEqual(@as(u64, 2), stream.info().state.messages);
}

test "validate stream name" {
    try std.testing.expect(validateStreamName("ORDERS"));
    try std.testing.expect(validateStreamName("my-stream"));
    try std.testing.expect(validateStreamName("stream_1"));
    try std.testing.expect(!validateStreamName(""));
    try std.testing.expect(!validateStreamName("bad name"));
    try std.testing.expect(!validateStreamName("bad.name"));
    try std.testing.expect(!validateStreamName("$bad"));
    try std.testing.expect(!validateStreamName("bad*"));
    try std.testing.expect(!validateStreamName("bad>"));
}

test "stream dedup cleanup" {
    const allocator = std.testing.allocator;
    var s = try Stream.init(allocator, .{
        .name = "TEST",
        .duplicate_window_ns = 1_000_000_000, // 1 second
    });
    defer s.deinit();

    // Store with msg_id
    const ack1 = try s.storeMessage("foo", null, "data1", "id-1");
    try std.testing.expect(!ack1.duplicate);

    // Duplicate within window should be detected
    const ack2 = try s.storeMessage("foo", null, "data1", "id-1");
    try std.testing.expect(ack2.duplicate);

    // Dedup map should have 1 entry
    try std.testing.expectEqual(@as(u32, 1), s.dedup_map.count());

    // cleanupDedup won't remove it yet (within window)
    s.cleanupDedup();
    try std.testing.expectEqual(@as(u32, 1), s.dedup_map.count());
}

test "stream with file store" {
    const allocator = std.testing.allocator;
    const dir = "/tmp/zats-test-stream-fs";
    // Clean up test dir (stream will create subdirectory)
    const stream_dir = "/tmp/zats-test-stream-fs/TEST";
    defer {
        // Clean up WAL + dirs
        const wal = allocator.dupeZ(u8, stream_dir ++ "/stream.wal") catch unreachable;
        defer allocator.free(wal);
        _ = std.c.unlink(wal.ptr);
        const sdZ = allocator.dupeZ(u8, stream_dir) catch unreachable;
        defer allocator.free(sdZ);
        _ = std.c.rmdir(sdZ.ptr);
        const dZ = allocator.dupeZ(u8, dir) catch unreachable;
        defer allocator.free(dZ);
        _ = std.c.rmdir(dZ.ptr);
    }

    var s = try Stream.initWithStoreDir(allocator, .{
        .name = "TEST",
        .storage = .file,
    }, dir);
    defer s.deinit();

    const ack = try s.storeMessage("orders.new", null, "order1", null);
    try std.testing.expectEqualStrings("TEST", ack.stream);
    try std.testing.expectEqual(@as(u64, 1), ack.seq);
    try std.testing.expect(!ack.duplicate);

    try std.testing.expectEqual(@as(u64, 1), s.info().state.messages);
}
