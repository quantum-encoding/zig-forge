//! In-Memory Message Storage for JetStream
//!
//! Stores messages in hash maps indexed by sequence number.
//! Tracks per-subject last sequence and total byte count.

const std = @import("std");
const store = @import("store.zig");

const StoredMessage = store.StoredMessage;
const MessageStore = store.MessageStore;
const StoreError = store.StoreError;

const InternalMessage = struct {
    sequence: u64,
    subject: []u8,
    headers: ?[]u8,
    data: []u8,
    timestamp_ns: i64,
    raw_size: usize,

    fn toStored(self: *const InternalMessage) StoredMessage {
        return .{
            .sequence = self.sequence,
            .subject = self.subject,
            .headers = self.headers,
            .data = self.data,
            .timestamp_ns = self.timestamp_ns,
            .raw_size = self.raw_size,
        };
    }

    fn deinit(self: *InternalMessage, allocator: std.mem.Allocator) void {
        allocator.free(self.subject);
        if (self.headers) |h| allocator.free(h);
        allocator.free(self.data);
    }
};

pub const MemoryStore = struct {
    messages: std.AutoHashMapUnmanaged(u64, InternalMessage),
    subject_last_seq: std.StringHashMapUnmanaged(u64),
    total_bytes: u64,
    msg_count: u64,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) MemoryStore {
        return .{
            .messages = .{},
            .subject_last_seq = .{},
            .total_bytes = 0,
            .msg_count = 0,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *MemoryStore) void {
        var it = self.messages.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
        }
        self.messages.deinit(self.allocator);

        var sit = self.subject_last_seq.iterator();
        while (sit.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.subject_last_seq.deinit(self.allocator);
    }

    pub fn messageStore(self: *MemoryStore) MessageStore {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
        };
    }

    fn storeImpl(ptr: *anyopaque, seq: u64, subject: []const u8, headers: ?[]const u8, data: []const u8, timestamp_ns: i64) StoreError!void {
        const self: *MemoryStore = @ptrCast(@alignCast(ptr));
        const raw_size = (if (headers) |h| h.len else 0) + data.len;

        const msg = InternalMessage{
            .sequence = seq,
            .subject = self.allocator.dupe(u8, subject) catch return StoreError.OutOfMemory,
            .headers = if (headers) |h| (self.allocator.dupe(u8, h) catch return StoreError.OutOfMemory) else null,
            .data = self.allocator.dupe(u8, data) catch return StoreError.OutOfMemory,
            .timestamp_ns = timestamp_ns,
            .raw_size = raw_size,
        };

        self.messages.put(self.allocator, seq, msg) catch return StoreError.OutOfMemory;
        self.total_bytes += raw_size;
        self.msg_count += 1;

        // Update subject_last_seq
        const existing = self.subject_last_seq.get(subject);
        if (existing == null) {
            const owned_subj = self.allocator.dupe(u8, subject) catch return StoreError.OutOfMemory;
            self.subject_last_seq.put(self.allocator, owned_subj, seq) catch return StoreError.OutOfMemory;
        } else {
            self.subject_last_seq.getPtr(subject).?.* = seq;
        }
    }

    fn loadImpl(ptr: *anyopaque, seq: u64) ?StoredMessage {
        const self: *MemoryStore = @ptrCast(@alignCast(ptr));
        const msg = self.messages.get(seq) orelse return null;
        return msg.toStored();
    }

    fn deleteImpl(ptr: *anyopaque, seq: u64) bool {
        const self: *MemoryStore = @ptrCast(@alignCast(ptr));
        if (self.messages.fetchRemove(seq)) |entry| {
            self.total_bytes -= entry.value.raw_size;
            self.msg_count -= 1;
            var msg = entry.value;
            msg.deinit(self.allocator);
            return true;
        }
        return false;
    }

    fn purgeImpl(ptr: *anyopaque, subject_filter: ?[]const u8) u64 {
        const self: *MemoryStore = @ptrCast(@alignCast(ptr));
        var purged: u64 = 0;

        // Collect keys to remove
        var to_remove: std.ArrayListUnmanaged(u64) = .empty;
        defer to_remove.deinit(self.allocator);

        var it = self.messages.iterator();
        while (it.next()) |entry| {
            const keep = if (subject_filter) |filter|
                !std.mem.eql(u8, entry.value_ptr.subject, filter)
            else
                false;

            if (!keep) {
                to_remove.append(self.allocator, entry.key_ptr.*) catch continue;
            }
        }

        for (to_remove.items) |seq| {
            if (self.messages.fetchRemove(seq)) |entry| {
                self.total_bytes -= entry.value.raw_size;
                self.msg_count -= 1;
                var msg = entry.value;
                msg.deinit(self.allocator);
                purged += 1;
            }
        }

        // Clear subject_last_seq for purged subjects
        if (subject_filter) |filter| {
            if (self.subject_last_seq.fetchRemove(filter)) |entry| {
                self.allocator.free(entry.key);
            }
        } else {
            var sit = self.subject_last_seq.iterator();
            while (sit.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
            }
            self.subject_last_seq.clearRetainingCapacity();
        }

        return purged;
    }

    fn loadBySubjectImpl(ptr: *anyopaque, subject: []const u8) ?StoredMessage {
        const self: *MemoryStore = @ptrCast(@alignCast(ptr));
        const seq = self.subject_last_seq.get(subject) orelse return null;
        return loadImpl(ptr, seq);
    }

    fn bytesImpl(ptr: *anyopaque) u64 {
        const self: *MemoryStore = @ptrCast(@alignCast(ptr));
        return self.total_bytes;
    }

    fn countImpl(ptr: *anyopaque) u64 {
        const self: *MemoryStore = @ptrCast(@alignCast(ptr));
        return self.msg_count;
    }

    const vtable = MessageStore.VTable{
        .store = &storeImpl,
        .load = &loadImpl,
        .delete = &deleteImpl,
        .purge = &purgeImpl,
        .loadBySubject = &loadBySubjectImpl,
        .bytes = &bytesImpl,
        .count = &countImpl,
    };
};

// --- Tests ---

test "memory store and load" {
    var ms = MemoryStore.init(std.testing.allocator);
    defer ms.deinit();
    var s = ms.messageStore();

    try s.store(1, "foo.bar", null, "hello", 1000);
    try std.testing.expectEqual(@as(u64, 1), s.count());
    try std.testing.expectEqual(@as(u64, 5), s.bytes());

    const msg = s.load(1).?;
    try std.testing.expectEqual(@as(u64, 1), msg.sequence);
    try std.testing.expectEqualStrings("foo.bar", msg.subject);
    try std.testing.expectEqualStrings("hello", msg.data);
    try std.testing.expect(msg.headers == null);
}

test "memory store with headers" {
    var ms = MemoryStore.init(std.testing.allocator);
    defer ms.deinit();
    var s = ms.messageStore();

    try s.store(1, "foo", "NATS/1.0\r\n\r\n", "data", 1000);
    const msg = s.load(1).?;
    try std.testing.expectEqualStrings("NATS/1.0\r\n\r\n", msg.headers.?);
    try std.testing.expectEqual(@as(u64, 16), s.bytes()); // 12 headers + 4 data
}

test "memory store load not found" {
    var ms = MemoryStore.init(std.testing.allocator);
    defer ms.deinit();
    var s = ms.messageStore();

    try std.testing.expect(s.load(999) == null);
}

test "memory store delete" {
    var ms = MemoryStore.init(std.testing.allocator);
    defer ms.deinit();
    var s = ms.messageStore();

    try s.store(1, "foo", null, "hello", 1000);
    try std.testing.expectEqual(@as(u64, 1), s.count());

    try std.testing.expect(s.delete(1));
    try std.testing.expectEqual(@as(u64, 0), s.count());
    try std.testing.expectEqual(@as(u64, 0), s.bytes());
    try std.testing.expect(s.load(1) == null);
}

test "memory store delete not found" {
    var ms = MemoryStore.init(std.testing.allocator);
    defer ms.deinit();
    var s = ms.messageStore();

    try std.testing.expect(!s.delete(999));
}

test "memory store purge all" {
    var ms = MemoryStore.init(std.testing.allocator);
    defer ms.deinit();
    var s = ms.messageStore();

    try s.store(1, "foo", null, "a", 1000);
    try s.store(2, "bar", null, "b", 2000);
    try s.store(3, "foo", null, "c", 3000);

    const purged = s.purge(null);
    try std.testing.expectEqual(@as(u64, 3), purged);
    try std.testing.expectEqual(@as(u64, 0), s.count());
    try std.testing.expectEqual(@as(u64, 0), s.bytes());
}

test "memory store purge by subject" {
    var ms = MemoryStore.init(std.testing.allocator);
    defer ms.deinit();
    var s = ms.messageStore();

    try s.store(1, "foo", null, "a", 1000);
    try s.store(2, "bar", null, "b", 2000);
    try s.store(3, "foo", null, "c", 3000);

    const purged = s.purge("foo");
    try std.testing.expectEqual(@as(u64, 2), purged);
    try std.testing.expectEqual(@as(u64, 1), s.count());

    // bar should still exist
    const msg = s.load(2).?;
    try std.testing.expectEqualStrings("bar", msg.subject);
}

test "memory store load by subject (last message)" {
    var ms = MemoryStore.init(std.testing.allocator);
    defer ms.deinit();
    var s = ms.messageStore();

    try s.store(1, "foo", null, "first", 1000);
    try s.store(2, "foo", null, "second", 2000);
    try s.store(3, "bar", null, "other", 3000);

    const msg = s.loadBySubject("foo").?;
    try std.testing.expectEqual(@as(u64, 2), msg.sequence);
    try std.testing.expectEqualStrings("second", msg.data);

    try std.testing.expect(s.loadBySubject("missing") == null);
}
