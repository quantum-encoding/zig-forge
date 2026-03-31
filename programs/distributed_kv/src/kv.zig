//! Key-Value Store State Machine
//!
//! In-memory key-value store that serves as the Raft state machine:
//! - CRUD operations: get, set, delete, compare-and-swap
//! - TTL support for key expiration
//! - Watch/subscribe for key changes
//! - Snapshot support for faster recovery
//!
//! Thread-safe for concurrent reads, serialized through Raft for writes.

const std = @import("std");
const raft = @import("raft.zig");

// Zig 0.16 compatible RwLock using pthreads
const RwLock = struct {
    inner: std.c.pthread_rwlock_t = .{}, // Zero-init is POSIX-compliant

    pub fn lockShared(self: *RwLock) void {
        _ = std.c.pthread_rwlock_rdlock(&self.inner);
    }

    pub fn unlockShared(self: *RwLock) void {
        _ = std.c.pthread_rwlock_unlock(&self.inner);
    }

    pub fn lock(self: *RwLock) void {
        _ = std.c.pthread_rwlock_wrlock(&self.inner);
    }

    pub fn unlock(self: *RwLock) void {
        _ = std.c.pthread_rwlock_unlock(&self.inner);
    }
};

/// Get current time in milliseconds (Zig 0.16 compatible)
fn currentTimeMs() i64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.REALTIME, &ts);
    return @as(i64, ts.sec) * 1000 + @divTrunc(ts.nsec, 1_000_000);
}

// =============================================================================
// Types
// =============================================================================

/// Value entry with metadata
pub const ValueEntry = struct {
    data: []u8,
    version: u64, // Monotonic version for CAS
    created_at: i64, // Unix timestamp ms
    modified_at: i64,
    ttl_ms: ?u64, // Time-to-live in milliseconds (null = no expiry)
    expires_at: ?i64, // Computed expiration timestamp

    pub fn isExpired(self: *const ValueEntry) bool {
        if (self.expires_at) |exp| {
            return currentTimeMs() > exp;
        }
        return false;
    }
};

/// Command payload for Set operation
pub const SetCommand = struct {
    key: []const u8,
    value: []const u8,
    ttl_ms: ?u64,

    pub fn encode(self: *const SetCommand, allocator: std.mem.Allocator) ![]u8 {
        // Format: key_len(4) + key + value_len(4) + value + has_ttl(1) + ttl(8)
        const total = 4 + self.key.len + 4 + self.value.len + 1 + 8;
        var buf = try allocator.alloc(u8, total);

        var offset: usize = 0;
        std.mem.writeInt(u32, buf[offset..][0..4], @intCast(self.key.len), .little);
        offset += 4;
        @memcpy(buf[offset .. offset + self.key.len], self.key);
        offset += self.key.len;

        std.mem.writeInt(u32, buf[offset..][0..4], @intCast(self.value.len), .little);
        offset += 4;
        @memcpy(buf[offset .. offset + self.value.len], self.value);
        offset += self.value.len;

        if (self.ttl_ms) |ttl| {
            buf[offset] = 1;
            offset += 1;
            std.mem.writeInt(u64, buf[offset..][0..8], ttl, .little);
        } else {
            buf[offset] = 0;
            offset += 1;
            std.mem.writeInt(u64, buf[offset..][0..8], 0, .little);
        }

        return buf;
    }

    pub fn decode(allocator: std.mem.Allocator, buf: []const u8) !SetCommand {
        if (buf.len < 9) return error.InvalidCommand;

        var offset: usize = 0;
        const key_len = std.mem.readInt(u32, buf[offset..][0..4], .little);
        offset += 4;

        if (buf.len < offset + key_len + 5) return error.InvalidCommand;
        const key = try allocator.dupe(u8, buf[offset .. offset + key_len]);
        offset += key_len;

        const value_len = std.mem.readInt(u32, buf[offset..][0..4], .little);
        offset += 4;

        if (buf.len < offset + value_len + 9) return error.InvalidCommand;
        const value = try allocator.dupe(u8, buf[offset .. offset + value_len]);
        offset += value_len;

        const has_ttl = buf[offset] != 0;
        offset += 1;
        const ttl = std.mem.readInt(u64, buf[offset..][0..8], .little);

        return SetCommand{
            .key = key,
            .value = value,
            .ttl_ms = if (has_ttl) ttl else null,
        };
    }

    pub fn deinit(self: *SetCommand, allocator: std.mem.Allocator) void {
        allocator.free(self.key);
        allocator.free(self.value);
    }
};

/// Command payload for Delete operation
pub const DeleteCommand = struct {
    key: []const u8,

    pub fn encode(self: *const DeleteCommand, allocator: std.mem.Allocator) ![]u8 {
        var buf = try allocator.alloc(u8, 4 + self.key.len);
        std.mem.writeInt(u32, buf[0..4], @intCast(self.key.len), .little);
        @memcpy(buf[4..], self.key);
        return buf;
    }

    pub fn decode(allocator: std.mem.Allocator, buf: []const u8) !DeleteCommand {
        if (buf.len < 4) return error.InvalidCommand;
        const key_len = std.mem.readInt(u32, buf[0..4], .little);
        if (buf.len < 4 + key_len) return error.InvalidCommand;
        return DeleteCommand{
            .key = try allocator.dupe(u8, buf[4 .. 4 + key_len]),
        };
    }

    pub fn deinit(self: *DeleteCommand, allocator: std.mem.Allocator) void {
        allocator.free(self.key);
    }
};

/// Command payload for Compare-and-Swap operation
pub const CasCommand = struct {
    key: []const u8,
    expected_version: u64,
    new_value: []const u8,
    ttl_ms: ?u64,

    pub fn encode(self: *const CasCommand, allocator: std.mem.Allocator) ![]u8 {
        const total = 4 + self.key.len + 8 + 4 + self.new_value.len + 1 + 8;
        var buf = try allocator.alloc(u8, total);

        var offset: usize = 0;
        std.mem.writeInt(u32, buf[offset..][0..4], @intCast(self.key.len), .little);
        offset += 4;
        @memcpy(buf[offset .. offset + self.key.len], self.key);
        offset += self.key.len;

        std.mem.writeInt(u64, buf[offset..][0..8], self.expected_version, .little);
        offset += 8;

        std.mem.writeInt(u32, buf[offset..][0..4], @intCast(self.new_value.len), .little);
        offset += 4;
        @memcpy(buf[offset .. offset + self.new_value.len], self.new_value);
        offset += self.new_value.len;

        if (self.ttl_ms) |ttl| {
            buf[offset] = 1;
            offset += 1;
            std.mem.writeInt(u64, buf[offset..][0..8], ttl, .little);
        } else {
            buf[offset] = 0;
            offset += 1;
            std.mem.writeInt(u64, buf[offset..][0..8], 0, .little);
        }

        return buf;
    }

    pub fn decode(allocator: std.mem.Allocator, buf: []const u8) !CasCommand {
        if (buf.len < 17) return error.InvalidCommand;

        var offset: usize = 0;
        const key_len = std.mem.readInt(u32, buf[offset..][0..4], .little);
        offset += 4;

        const key = try allocator.dupe(u8, buf[offset .. offset + key_len]);
        offset += key_len;

        const expected_version = std.mem.readInt(u64, buf[offset..][0..8], .little);
        offset += 8;

        const value_len = std.mem.readInt(u32, buf[offset..][0..4], .little);
        offset += 4;

        const new_value = try allocator.dupe(u8, buf[offset .. offset + value_len]);
        offset += value_len;

        const has_ttl = buf[offset] != 0;
        offset += 1;
        const ttl = std.mem.readInt(u64, buf[offset..][0..8], .little);

        return CasCommand{
            .key = key,
            .expected_version = expected_version,
            .new_value = new_value,
            .ttl_ms = if (has_ttl) ttl else null,
        };
    }

    pub fn deinit(self: *CasCommand, allocator: std.mem.Allocator) void {
        allocator.free(self.key);
        allocator.free(self.new_value);
    }
};

/// Watch callback type
pub const WatchCallback = *const fn (key: []const u8, value: ?[]const u8, deleted: bool, ctx: *anyopaque) void;

/// Watch entry
const WatchEntry = struct {
    callback: WatchCallback,
    ctx: *anyopaque,
};

// =============================================================================
// KV Store
// =============================================================================

/// Key-value store state machine
pub const KVStore = struct {
    allocator: std.mem.Allocator,
    data: std.StringHashMapUnmanaged(ValueEntry),
    version_counter: u64,
    watches: std.StringHashMapUnmanaged(std.ArrayListUnmanaged(WatchEntry)),
    mutex: RwLock,

    /// Last applied log index (for idempotency)
    last_applied: raft.LogIndex,

    pub fn init(allocator: std.mem.Allocator) KVStore {
        return KVStore{
            .allocator = allocator,
            .data = .empty,
            .version_counter = 0,
            .watches = .empty,
            .mutex = .{},
            .last_applied = 0,
        };
    }

    pub fn deinit(self: *KVStore) void {
        // Free all values
        var iter = self.data.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.value_ptr.data);
            self.allocator.free(entry.key_ptr.*);
        }
        self.data.deinit(self.allocator);

        // Free watches
        var watch_iter = self.watches.iterator();
        while (watch_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(self.allocator);
        }
        self.watches.deinit(self.allocator);
    }

    // -------------------------------------------------------------------------
    // Read Operations (can be served by any node)
    // -------------------------------------------------------------------------

    /// Get a value by key
    pub fn get(self: *KVStore, key: []const u8) ?[]const u8 {
        self.mutex.lockShared();
        defer self.mutex.unlockShared();

        const entry = self.data.get(key) orelse return null;

        // Check expiration
        if (entry.isExpired()) {
            return null;
        }

        return entry.data;
    }

    /// Get a value with version
    pub fn getWithVersion(self: *KVStore, key: []const u8) ?struct { data: []const u8, version: u64 } {
        self.mutex.lockShared();
        defer self.mutex.unlockShared();

        const entry = self.data.get(key) orelse return null;

        if (entry.isExpired()) {
            return null;
        }

        return .{ .data = entry.data, .version = entry.version };
    }

    /// Check if key exists
    pub fn contains(self: *KVStore, key: []const u8) bool {
        self.mutex.lockShared();
        defer self.mutex.unlockShared();

        const entry = self.data.get(key) orelse return false;
        return !entry.isExpired();
    }

    /// Get number of keys (including potentially expired ones)
    pub fn count(self: *KVStore) usize {
        self.mutex.lockShared();
        defer self.mutex.unlockShared();
        return self.data.count();
    }

    /// List keys matching prefix
    pub fn listKeys(self: *KVStore, prefix: []const u8, limit: usize) ![][]const u8 {
        self.mutex.lockShared();
        defer self.mutex.unlockShared();

        var result: std.ArrayListUnmanaged([]const u8) = .empty;
        errdefer {
            for (result.items) |k| self.allocator.free(k);
            result.deinit(self.allocator);
        }

        var iter = self.data.iterator();
        while (iter.next()) |entry| {
            if (result.items.len >= limit) break;

            if (std.mem.startsWith(u8, entry.key_ptr.*, prefix)) {
                if (!entry.value_ptr.isExpired()) {
                    try result.append(self.allocator, try self.allocator.dupe(u8, entry.key_ptr.*));
                }
            }
        }

        return result.toOwnedSlice(self.allocator);
    }

    // -------------------------------------------------------------------------
    // State Machine Interface (Raft applies commands here)
    // -------------------------------------------------------------------------

    /// Apply a Raft log entry to the state machine
    pub fn apply(self: *KVStore, entry: *const raft.LogEntry) !void {
        // Idempotency check
        if (entry.index <= self.last_applied) {
            return;
        }

        switch (entry.command_type) {
            .noop => {
                // No operation, just advance applied index
            },
            .set => {
                var cmd = try SetCommand.decode(self.allocator, entry.data);
                defer cmd.deinit(self.allocator);
                try self.applySet(cmd.key, cmd.value, cmd.ttl_ms);
            },
            .delete => {
                var cmd = try DeleteCommand.decode(self.allocator, entry.data);
                defer cmd.deinit(self.allocator);
                _ = self.applyDelete(cmd.key);
            },
            .cas => {
                var cmd = try CasCommand.decode(self.allocator, entry.data);
                defer cmd.deinit(self.allocator);
                _ = try self.applyCas(cmd.key, cmd.expected_version, cmd.new_value, cmd.ttl_ms);
            },
            .config_change => {
                // Configuration changes handled elsewhere
            },
        }

        self.last_applied = entry.index;
    }

    /// Apply a Set operation
    pub fn applySet(self: *KVStore, key: []const u8, value: []const u8, ttl_ms: ?u64) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const now = currentTimeMs();
        self.version_counter += 1;

        const new_entry = ValueEntry{
            .data = try self.allocator.dupe(u8, value),
            .version = self.version_counter,
            .created_at = now,
            .modified_at = now,
            .ttl_ms = ttl_ms,
            .expires_at = if (ttl_ms) |t| now + @as(i64, @intCast(t)) else null,
        };

        // Check if key exists
        if (self.data.getPtr(key)) |existing| {
            // Free old value
            self.allocator.free(existing.data);
            existing.* = new_entry;
        } else {
            // Insert new key
            const owned_key = try self.allocator.dupe(u8, key);
            try self.data.put(self.allocator, owned_key, new_entry);
        }

        // Notify watchers
        self.notifyWatchers(key, value, false);
    }

    /// Apply a Delete operation
    pub fn applyDelete(self: *KVStore, key: []const u8) bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.data.fetchRemove(key)) |kv| {
            self.allocator.free(kv.value.data);
            self.allocator.free(kv.key);
            self.notifyWatchers(key, null, true);
            return true;
        }
        return false;
    }

    /// Apply a Compare-and-Swap operation
    pub fn applyCas(self: *KVStore, key: []const u8, expected_version: u64, new_value: []const u8, ttl_ms: ?u64) !bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        const existing = self.data.getPtr(key) orelse return false;

        if (existing.version != expected_version) {
            return false;
        }

        if (existing.isExpired()) {
            return false;
        }

        const now = currentTimeMs();
        self.version_counter += 1;

        // Free old value
        self.allocator.free(existing.data);

        existing.* = ValueEntry{
            .data = try self.allocator.dupe(u8, new_value),
            .version = self.version_counter,
            .created_at = existing.created_at,
            .modified_at = now,
            .ttl_ms = ttl_ms,
            .expires_at = if (ttl_ms) |t| now + @as(i64, @intCast(t)) else null,
        };

        self.notifyWatchers(key, new_value, false);
        return true;
    }

    // -------------------------------------------------------------------------
    // Watch/Subscribe
    // -------------------------------------------------------------------------

    /// Register a watch on a key
    pub fn watch(self: *KVStore, key: []const u8, callback: WatchCallback, ctx: *anyopaque) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const result = try self.watches.getOrPut(self.allocator, key);
        if (!result.found_existing) {
            result.key_ptr.* = try self.allocator.dupe(u8, key);
            result.value_ptr.* = .empty;
        }

        try result.value_ptr.append(self.allocator, WatchEntry{
            .callback = callback,
            .ctx = ctx,
        });
    }

    /// Notify watchers of a key change (must hold lock)
    fn notifyWatchers(self: *KVStore, key: []const u8, value: ?[]const u8, deleted: bool) void {
        if (self.watches.get(key)) |watchers| {
            for (watchers.items) |w| {
                w.callback(key, value, deleted, w.ctx);
            }
        }
    }

    // -------------------------------------------------------------------------
    // Snapshot Support
    // -------------------------------------------------------------------------

    /// Create a snapshot of the current state
    pub fn snapshot(self: *KVStore, allocator: std.mem.Allocator) ![]u8 {
        self.mutex.lockShared();
        defer self.mutex.unlockShared();

        var buf: std.ArrayListUnmanaged(u8) = .empty;
        errdefer buf.deinit(allocator);

        // Write entry count
        var count_buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &count_buf, @intCast(self.data.count()), .little);
        try buf.appendSlice(allocator, &count_buf);

        // Write each entry
        var iter = self.data.iterator();
        while (iter.next()) |entry| {
            const key = entry.key_ptr.*;
            const val = entry.value_ptr.*;

            // Skip expired entries
            if (val.isExpired()) continue;

            // Key length + key
            std.mem.writeInt(u32, &count_buf, @intCast(key.len), .little);
            try buf.appendSlice(allocator, &count_buf);
            try buf.appendSlice(allocator, key);

            // Value length + value
            std.mem.writeInt(u32, &count_buf, @intCast(val.data.len), .little);
            try buf.appendSlice(allocator, &count_buf);
            try buf.appendSlice(allocator, val.data);

            // Version
            var version_buf: [8]u8 = undefined;
            std.mem.writeInt(u64, &version_buf, val.version, .little);
            try buf.appendSlice(allocator, &version_buf);

            // TTL (0 = no TTL)
            var ttl_buf: [8]u8 = undefined;
            std.mem.writeInt(u64, &ttl_buf, val.ttl_ms orelse 0, .little);
            try buf.appendSlice(allocator, &ttl_buf);
        }

        return buf.toOwnedSlice(allocator);
    }

    /// Restore state from a snapshot
    pub fn restore(self: *KVStore, snapshot_data: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Clear existing data
        var iter = self.data.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.value_ptr.data);
            self.allocator.free(entry.key_ptr.*);
        }
        self.data.clearRetainingCapacity();

        if (snapshot_data.len < 4) return;

        var offset: usize = 0;
        const entry_count = std.mem.readInt(u32, snapshot_data[0..4], .little);
        offset += 4;

        for (0..entry_count) |_| {
            if (offset + 4 > snapshot_data.len) break;

            // Read key
            const key_len = std.mem.readInt(u32, snapshot_data[offset..][0..4], .little);
            offset += 4;
            if (offset + key_len > snapshot_data.len) break;
            const key = try self.allocator.dupe(u8, snapshot_data[offset .. offset + key_len]);
            offset += key_len;

            // Read value
            if (offset + 4 > snapshot_data.len) {
                self.allocator.free(key);
                break;
            }
            const val_len = std.mem.readInt(u32, snapshot_data[offset..][0..4], .little);
            offset += 4;
            if (offset + val_len > snapshot_data.len) {
                self.allocator.free(key);
                break;
            }
            const value = try self.allocator.dupe(u8, snapshot_data[offset .. offset + val_len]);
            offset += val_len;

            // Read version
            if (offset + 8 > snapshot_data.len) {
                self.allocator.free(key);
                self.allocator.free(value);
                break;
            }
            const version = std.mem.readInt(u64, snapshot_data[offset..][0..8], .little);
            offset += 8;

            // Read TTL
            if (offset + 8 > snapshot_data.len) {
                self.allocator.free(key);
                self.allocator.free(value);
                break;
            }
            const ttl = std.mem.readInt(u64, snapshot_data[offset..][0..8], .little);
            offset += 8;

            const now = currentTimeMs();
            try self.data.put(self.allocator, key, ValueEntry{
                .data = value,
                .version = version,
                .created_at = now,
                .modified_at = now,
                .ttl_ms = if (ttl > 0) ttl else null,
                .expires_at = if (ttl > 0) now + @as(i64, @intCast(ttl)) else null,
            });

            if (version > self.version_counter) {
                self.version_counter = version;
            }
        }
    }

    // -------------------------------------------------------------------------
    // Raft State Machine Adapter
    // -------------------------------------------------------------------------

    /// Get the Raft state machine interface
    pub fn getStateMachine(self: *KVStore) raft.StateMachine {
        return raft.StateMachine{
            .ctx = self,
            .applyFn = applyWrapper,
        };
    }

    fn applyWrapper(ctx: *anyopaque, entry: *const raft.LogEntry) anyerror!void {
        const self: *KVStore = @ptrCast(@alignCast(ctx));
        try self.apply(entry);
    }
};

// =============================================================================
// Tests
// =============================================================================

test "kv set and get" {
    const allocator = std.testing.allocator;

    var kv = KVStore.init(allocator);
    defer kv.deinit();

    // Use internal apply method for testing
    try kv.applySet("key1", "value1", null);
    try kv.applySet("key2", "value2", null);

    try std.testing.expectEqualStrings("value1", kv.get("key1").?);
    try std.testing.expectEqualStrings("value2", kv.get("key2").?);
    try std.testing.expect(kv.get("key3") == null);
}

test "kv delete" {
    const allocator = std.testing.allocator;

    var kv = KVStore.init(allocator);
    defer kv.deinit();

    try kv.applySet("key1", "value1", null);
    try std.testing.expect(kv.contains("key1"));

    _ = kv.applyDelete("key1");
    try std.testing.expect(!kv.contains("key1"));
}

test "kv compare-and-swap" {
    const allocator = std.testing.allocator;

    var kv = KVStore.init(allocator);
    defer kv.deinit();

    try kv.applySet("key1", "value1", null);

    const info = kv.getWithVersion("key1").?;
    try std.testing.expectEqualStrings("value1", info.data);

    // CAS with correct version should succeed
    const success1 = try kv.applyCas("key1", info.version, "value2", null);
    try std.testing.expect(success1);
    try std.testing.expectEqualStrings("value2", kv.get("key1").?);

    // CAS with old version should fail
    const success2 = try kv.applyCas("key1", info.version, "value3", null);
    try std.testing.expect(!success2);
    try std.testing.expectEqualStrings("value2", kv.get("key1").?);
}

test "kv snapshot and restore" {
    const allocator = std.testing.allocator;

    // Create and populate store
    var kv1 = KVStore.init(allocator);
    defer kv1.deinit();

    try kv1.applySet("key1", "value1", null);
    try kv1.applySet("key2", "value2", null);

    // Take snapshot
    const snapshot_data = try kv1.snapshot(allocator);
    defer allocator.free(snapshot_data);

    // Restore to new store
    var kv2 = KVStore.init(allocator);
    defer kv2.deinit();

    try kv2.restore(snapshot_data);

    try std.testing.expectEqualStrings("value1", kv2.get("key1").?);
    try std.testing.expectEqualStrings("value2", kv2.get("key2").?);
}

test "command encoding" {
    const allocator = std.testing.allocator;

    const set_cmd = SetCommand{
        .key = "test-key",
        .value = "test-value",
        .ttl_ms = 5000,
    };

    const encoded = try set_cmd.encode(allocator);
    defer allocator.free(encoded);

    var decoded = try SetCommand.decode(allocator, encoded);
    defer decoded.deinit(allocator);

    try std.testing.expectEqualStrings("test-key", decoded.key);
    try std.testing.expectEqualStrings("test-value", decoded.value);
    try std.testing.expectEqual(@as(?u64, 5000), decoded.ttl_ms);
}
