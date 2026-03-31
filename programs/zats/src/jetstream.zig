//! JetStream Coordinator
//!
//! Top-level coordinator for JetStream functionality. Manages streams
//! and consumers, intercepts publishes for message persistence, routes
//! acks to consumers, and provides account info.

const std = @import("std");
const stream_mod = @import("stream.zig");
const trie_mod = @import("trie.zig");
const headers_mod = @import("headers.zig");
const consumer_mod = @import("consumer.zig");

pub const JetStreamConfig = struct {
    domain: ?[]const u8 = null, // optional domain for multi-tenancy
    store_dir: ?[]const u8 = null, // directory for file-backed streams
    max_memory: i64 = -1, // -1 = unlimited
    max_streams: i32 = -1,
};

pub const AccountInfo = struct {
    memory: u64,
    storage: u64,
    streams: u32,
    consumers: u32,
    api_total: u64,
    api_errors: u64,
};

pub const PushDelivery = struct {
    deliver_subject: []const u8,
    deliver_group: ?[]const u8,
    messages: std.ArrayListUnmanaged(consumer_mod.DeliveredMessage),
};

pub const JetStream = struct {
    streams: std.StringHashMapUnmanaged(*stream_mod.Stream),
    consumers: std.StringHashMapUnmanaged(*consumer_mod.Consumer), // key: "stream.consumer"
    subject_trie: trie_mod.SubjectTrie(*stream_mod.Stream),
    config: JetStreamConfig,
    api_total: u64,
    api_errors: u64,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, config: JetStreamConfig) !*JetStream {
        const js = try allocator.create(JetStream);
        js.* = .{
            .streams = .{},
            .consumers = .{},
            .subject_trie = try trie_mod.SubjectTrie(*stream_mod.Stream).init(allocator),
            .config = config,
            .api_total = 0,
            .api_errors = 0,
            .allocator = allocator,
        };
        return js;
    }

    pub fn deinit(self: *JetStream) void {
        // Free consumers first (they reference streams)
        var con_it = self.consumers.iterator();
        while (con_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.*.deinit();
        }
        self.consumers.deinit(self.allocator);

        // Then free streams
        var it = self.streams.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.*.deinit();
        }
        self.streams.deinit(self.allocator);
        self.subject_trie.deinit();
        self.allocator.destroy(self);
    }

    /// Create a new stream.
    pub fn createStream(self: *JetStream, config: stream_mod.StreamConfig) !*stream_mod.Stream {
        // Validate name
        if (!stream_mod.validateStreamName(config.name)) {
            return error.InvalidStreamName;
        }

        // Check for duplicate
        if (self.streams.get(config.name) != null) {
            return error.StreamNameExists;
        }

        // Check max streams
        if (self.config.max_streams > 0 and self.streams.count() >= @as(u32, @intCast(self.config.max_streams))) {
            return error.MaxStreamsExceeded;
        }

        const stream = try stream_mod.Stream.initWithStoreDir(self.allocator, config, self.config.store_dir);

        // Register in streams map
        const owned_name = try self.allocator.dupe(u8, config.name);
        try self.streams.put(self.allocator, owned_name, stream);

        // Register subject patterns in trie
        for (config.subjects) |subject| {
            try self.subject_trie.insert(subject, stream);
        }

        return stream;
    }

    /// Delete a stream by name. Also removes all consumers for the stream.
    pub fn deleteStream(self: *JetStream, name: []const u8) bool {
        const entry = self.streams.fetchRemove(name) orelse return false;
        const stream = entry.value;

        // Remove all consumers for this stream
        self.removeConsumersForStream(name);

        // Remove from subject trie
        for (stream.config.subjects) |subject| {
            _ = self.subject_trie.remove(subject, stream, &streamEql);
        }

        self.allocator.free(entry.key);
        stream.deinit();
        return true;
    }

    /// Get a stream by name.
    pub fn getStream(self: *JetStream, name: []const u8) ?*stream_mod.Stream {
        return self.streams.get(name);
    }

    // --- Consumer management ---

    /// Add a consumer to a stream. Returns the consumer pointer.
    pub fn addConsumer(self: *JetStream, stream_name: []const u8, config: consumer_mod.ConsumerConfig) !*consumer_mod.Consumer {
        const stream = self.getStream(stream_name) orelse return error.StreamNotFound;

        if (!consumer_mod.validateConsumerName(config.name)) {
            return error.InvalidConsumerName;
        }

        // Build composite key: "stream.consumer"
        const key = try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ stream_name, config.name });

        if (self.consumers.get(key) != null) {
            self.allocator.free(key);
            return error.ConsumerNameExists;
        }

        const consumer = try consumer_mod.Consumer.init(self.allocator, config, stream, stream_name);
        try self.consumers.put(self.allocator, key, consumer);
        stream.consumer_count += 1;
        return consumer;
    }

    /// Delete a consumer by stream and consumer name.
    pub fn deleteConsumer(self: *JetStream, stream_name: []const u8, consumer_name: []const u8) bool {
        var key_buf: [512]u8 = undefined;
        const key = std.fmt.bufPrint(&key_buf, "{s}.{s}", .{ stream_name, consumer_name }) catch return false;

        const removed = self.consumers.fetchRemove(key) orelse return false;
        self.allocator.free(removed.key);
        removed.value.deinit();

        // Decrement stream's consumer count
        if (self.getStream(stream_name)) |stream| {
            if (stream.consumer_count > 0) stream.consumer_count -= 1;
        }
        return true;
    }

    /// Get a consumer by stream and consumer name.
    pub fn getConsumer(self: *JetStream, stream_name: []const u8, consumer_name: []const u8) ?*consumer_mod.Consumer {
        var key_buf: [512]u8 = undefined;
        const key = std.fmt.bufPrint(&key_buf, "{s}.{s}", .{ stream_name, consumer_name }) catch return null;
        return self.consumers.get(key);
    }

    /// Intercept a publish and store in matching streams.
    /// Returns PubAck JSON if the message was captured by a stream, null otherwise.
    pub fn interceptPublish(self: *JetStream, subject: []const u8, reply_to: ?[]const u8, hdrs: ?[]const u8, data: []const u8) ?[]const u8 {
        _ = reply_to;

        // Find matching streams
        var matches: std.ArrayListUnmanaged(*stream_mod.Stream) = .empty;
        defer matches.deinit(self.allocator);

        self.subject_trie.match(subject, &matches) catch return null;
        if (matches.items.len == 0) return null;

        // Extract Nats-Msg-Id from headers for dedup
        var msg_id: ?[]const u8 = null;
        if (hdrs) |h| {
            const parsed = headers_mod.Headers{ .raw = h };
            msg_id = parsed.get("Nats-Msg-Id");
        }

        // Store in first matching stream
        const stream = matches.items[0];
        const ack = stream.storeMessage(subject, hdrs, data, msg_id) catch return null;

        // Format PubAck as JSON
        var buf: [256]u8 = undefined;
        const json = std.fmt.bufPrint(&buf, "{{\"stream\":\"{s}\",\"seq\":{d}{s}}}", .{
            ack.stream,
            ack.seq,
            if (ack.duplicate) ",\"duplicate\":true" else "",
        }) catch return null;

        // Return owned copy
        return self.allocator.dupe(u8, json) catch null;
    }

    /// Intercept an ack publish ($JS.ACK.*) and route to the appropriate consumer.
    /// Returns true if the ack was processed.
    pub fn interceptAck(self: *JetStream, subject: []const u8, payload: []const u8) bool {
        const meta = consumer_mod.parseAckSubject(subject) orelse return false;

        const consumer = self.getConsumer(meta.stream, meta.consumer) orelse return false;
        const ack_type = consumer_mod.parseAckPayload(payload);
        consumer.processAck(meta.stream_seq, ack_type);
        return true;
    }

    /// Get push consumers that should receive a newly stored message.
    /// Returns a list of PushDelivery items. Caller must free the list and each delivery's messages.
    pub fn getPushDeliveries(self: *JetStream, stream_name: []const u8, subject: []const u8) std.ArrayListUnmanaged(PushDelivery) {
        var deliveries: std.ArrayListUnmanaged(PushDelivery) = .empty;

        // Iterate consumers to find push consumers for this stream
        var it = self.consumers.iterator();
        while (it.next()) |entry| {
            const consumer = entry.value_ptr.*;
            if (!consumer.isPush()) continue;
            if (!std.mem.eql(u8, consumer.stream_name, stream_name)) continue;

            // Check filter subject
            if (consumer.config.filter_subject) |filter| {
                if (!consumer_mod.subjectMatches(filter, subject)) continue;
            }

            // Fetch one message for this push consumer
            var msgs = consumer.fetch(1) catch continue;
            if (msgs.items.len == 0) {
                msgs.deinit(self.allocator);
                continue;
            }

            deliveries.append(self.allocator, .{
                .deliver_subject = consumer.config.deliver_subject.?,
                .deliver_group = consumer.config.deliver_group,
                .messages = msgs,
            }) catch {
                consumer_mod.freeDeliveredMessages(&msgs, self.allocator);
                continue;
            };
        }

        return deliveries;
    }

    /// Periodic maintenance tick. Called from server's poll loop.
    /// Runs ack timeout checks on consumers and dedup cleanup on streams.
    pub fn tick(self: *JetStream, now_ns: i64) void {
        // Check ack timeouts on all consumers
        var con_it = self.consumers.iterator();
        while (con_it.next()) |entry| {
            entry.value_ptr.*.checkAckTimeouts(now_ns);
        }

        // Run retention enforcement + dedup cleanup on all streams
        var stream_it = self.streams.iterator();
        while (stream_it.next()) |entry| {
            entry.value_ptr.*.cleanupDedup();
        }
    }

    /// Get account-level info.
    pub fn accountInfo(self: *JetStream) AccountInfo {
        var total_memory: u64 = 0;
        var total_storage: u64 = 0;
        var it = self.streams.iterator();
        while (it.next()) |entry| {
            const s = entry.value_ptr.*;
            if (s.config.storage == .file) {
                total_storage += s.store.bytes();
            } else {
                total_memory += s.store.bytes();
            }
        }

        return .{
            .memory = total_memory,
            .storage = total_storage,
            .streams = self.streams.count(),
            .consumers = self.consumers.count(),
            .api_total = self.api_total,
            .api_errors = self.api_errors,
        };
    }

    /// Get the API prefix based on domain config.
    pub fn apiPrefix(self: *const JetStream) []const u8 {
        _ = self;
        return "$JS.API";
    }

    // --- Internal ---

    fn removeConsumersForStream(self: *JetStream, stream_name: []const u8) void {
        // Build prefix: "stream_name."
        var prefix_buf: [256]u8 = undefined;
        const prefix = std.fmt.bufPrint(&prefix_buf, "{s}.", .{stream_name}) catch return;

        // Collect keys to remove
        var to_remove: std.ArrayListUnmanaged([]const u8) = .empty;
        defer to_remove.deinit(self.allocator);

        var it = self.consumers.iterator();
        while (it.next()) |entry| {
            if (entry.key_ptr.*.len >= prefix.len and std.mem.eql(u8, entry.key_ptr.*[0..prefix.len], prefix)) {
                to_remove.append(self.allocator, entry.key_ptr.*) catch {};
            }
        }

        for (to_remove.items) |key| {
            if (self.consumers.fetchRemove(key)) |removed| {
                self.allocator.free(removed.key);
                removed.value.deinit();
            }
        }
    }

    fn streamEql(a: *stream_mod.Stream, b: *stream_mod.Stream) bool {
        return a == b;
    }
};

// --- Tests ---

test "jetstream create stream" {
    const allocator = std.testing.allocator;
    var js = try JetStream.init(allocator, .{});
    defer js.deinit();

    const subjects = [_][]const u8{"orders.>"};
    const stream = try js.createStream(.{
        .name = "ORDERS",
        .subjects = &subjects,
    });
    try std.testing.expectEqualStrings("ORDERS", stream.config.name);
    try std.testing.expectEqual(@as(u32, 1), js.streams.count());
}

test "jetstream create duplicate stream" {
    const allocator = std.testing.allocator;
    var js = try JetStream.init(allocator, .{});
    defer js.deinit();

    _ = try js.createStream(.{ .name = "TEST" });
    const result = js.createStream(.{ .name = "TEST" });
    try std.testing.expectError(error.StreamNameExists, result);
}

test "jetstream create stream invalid name" {
    const allocator = std.testing.allocator;
    var js = try JetStream.init(allocator, .{});
    defer js.deinit();

    const result = js.createStream(.{ .name = "bad name" });
    try std.testing.expectError(error.InvalidStreamName, result);
}

test "jetstream delete stream" {
    const allocator = std.testing.allocator;
    var js = try JetStream.init(allocator, .{});
    defer js.deinit();

    _ = try js.createStream(.{ .name = "TEST" });
    try std.testing.expect(js.deleteStream("TEST"));
    try std.testing.expectEqual(@as(u32, 0), js.streams.count());
    try std.testing.expect(!js.deleteStream("TEST"));
}

test "jetstream get stream" {
    const allocator = std.testing.allocator;
    var js = try JetStream.init(allocator, .{});
    defer js.deinit();

    _ = try js.createStream(.{ .name = "TEST" });
    const stream = js.getStream("TEST").?;
    try std.testing.expectEqualStrings("TEST", stream.config.name);
    try std.testing.expect(js.getStream("MISSING") == null);
}

test "jetstream intercept publish" {
    const allocator = std.testing.allocator;
    var js = try JetStream.init(allocator, .{});
    defer js.deinit();

    const subjects = [_][]const u8{"events.>"};
    _ = try js.createStream(.{
        .name = "EVENTS",
        .subjects = &subjects,
    });

    // Publish to matching subject
    const ack_json = js.interceptPublish("events.login", null, null, "user1");
    try std.testing.expect(ack_json != null);
    defer allocator.free(ack_json.?);

    // Should contain stream name and seq
    try std.testing.expect(std.mem.indexOf(u8, ack_json.?, "EVENTS") != null);
    try std.testing.expect(std.mem.indexOf(u8, ack_json.?, "\"seq\":1") != null);

    // Publish to non-matching subject
    const no_ack = js.interceptPublish("orders.new", null, null, "data");
    try std.testing.expect(no_ack == null);
}

test "jetstream account info" {
    const allocator = std.testing.allocator;
    var js = try JetStream.init(allocator, .{});
    defer js.deinit();

    const subjects = [_][]const u8{"foo"};
    const stream = try js.createStream(.{
        .name = "TEST",
        .subjects = &subjects,
    });

    _ = try stream.storeMessage("foo", null, "hello", null);

    const info = js.accountInfo();
    try std.testing.expectEqual(@as(u32, 1), info.streams);
    try std.testing.expect(info.memory > 0);
}

test "jetstream intercept with dedup" {
    const allocator = std.testing.allocator;
    var js = try JetStream.init(allocator, .{});
    defer js.deinit();

    const subjects = [_][]const u8{"foo"};
    _ = try js.createStream(.{
        .name = "TEST",
        .subjects = &subjects,
    });

    const headers = "NATS/1.0\r\nNats-Msg-Id: dedup1\r\n\r\n";

    const ack1 = js.interceptPublish("foo", null, headers, "data");
    try std.testing.expect(ack1 != null);
    defer allocator.free(ack1.?);
    try std.testing.expect(std.mem.indexOf(u8, ack1.?, "duplicate") == null);

    const ack2 = js.interceptPublish("foo", null, headers, "data");
    try std.testing.expect(ack2 != null);
    defer allocator.free(ack2.?);
    try std.testing.expect(std.mem.indexOf(u8, ack2.?, "\"duplicate\":true") != null);
}

test "jetstream add consumer" {
    const allocator = std.testing.allocator;
    var js = try JetStream.init(allocator, .{});
    defer js.deinit();

    const subjects = [_][]const u8{"orders.>"};
    _ = try js.createStream(.{
        .name = "ORDERS",
        .subjects = &subjects,
    });

    const consumer = try js.addConsumer("ORDERS", .{ .name = "processor" });
    try std.testing.expectEqualStrings("processor", consumer.name);
    try std.testing.expectEqual(@as(u32, 1), js.consumers.count());

    // Verify stream has consumer count
    const stream = js.getStream("ORDERS").?;
    try std.testing.expectEqual(@as(u32, 1), stream.consumer_count);
}

test "jetstream add consumer duplicate" {
    const allocator = std.testing.allocator;
    var js = try JetStream.init(allocator, .{});
    defer js.deinit();

    _ = try js.createStream(.{ .name = "TEST" });
    _ = try js.addConsumer("TEST", .{ .name = "C1" });

    const result = js.addConsumer("TEST", .{ .name = "C1" });
    try std.testing.expectError(error.ConsumerNameExists, result);
}

test "jetstream delete consumer" {
    const allocator = std.testing.allocator;
    var js = try JetStream.init(allocator, .{});
    defer js.deinit();

    _ = try js.createStream(.{ .name = "TEST" });
    _ = try js.addConsumer("TEST", .{ .name = "C1" });

    try std.testing.expect(js.deleteConsumer("TEST", "C1"));
    try std.testing.expectEqual(@as(u32, 0), js.consumers.count());
    try std.testing.expect(!js.deleteConsumer("TEST", "C1"));

    const stream = js.getStream("TEST").?;
    try std.testing.expectEqual(@as(u32, 0), stream.consumer_count);
}

test "jetstream delete stream removes consumers" {
    const allocator = std.testing.allocator;
    var js = try JetStream.init(allocator, .{});
    defer js.deinit();

    _ = try js.createStream(.{ .name = "TEST" });
    _ = try js.addConsumer("TEST", .{ .name = "C1" });
    _ = try js.addConsumer("TEST", .{ .name = "C2" });
    try std.testing.expectEqual(@as(u32, 2), js.consumers.count());

    try std.testing.expect(js.deleteStream("TEST"));
    try std.testing.expectEqual(@as(u32, 0), js.consumers.count());
}

test "jetstream intercept ack" {
    const allocator = std.testing.allocator;
    var js = try JetStream.init(allocator, .{});
    defer js.deinit();

    const subjects = [_][]const u8{"foo"};
    const stream = try js.createStream(.{
        .name = "TEST",
        .subjects = &subjects,
    });
    _ = try stream.storeMessage("foo", null, "data1", null);

    const consumer = try js.addConsumer("TEST", .{ .name = "C1" });

    // Fetch a message
    var msgs = try consumer.fetch(1);
    defer consumer_mod.freeDeliveredMessages(&msgs, allocator);
    try std.testing.expectEqual(@as(usize, 1), msgs.items.len);
    try std.testing.expectEqual(@as(u64, 1), consumer.pending.count());

    // Intercept ack
    const ack_subject = msgs.items[0].ack_reply;
    try std.testing.expect(js.interceptAck(ack_subject, "+ACK"));
    try std.testing.expectEqual(@as(u64, 0), consumer.pending.count());
}

test "jetstream account info with consumers" {
    const allocator = std.testing.allocator;
    var js = try JetStream.init(allocator, .{});
    defer js.deinit();

    _ = try js.createStream(.{ .name = "TEST" });
    _ = try js.addConsumer("TEST", .{ .name = "C1" });
    _ = try js.addConsumer("TEST", .{ .name = "C2" });

    const info = js.accountInfo();
    try std.testing.expectEqual(@as(u32, 1), info.streams);
    try std.testing.expectEqual(@as(u32, 2), info.consumers);
}

test "jetstream push consumer delivery" {
    const allocator = std.testing.allocator;
    var js = try JetStream.init(allocator, .{});
    defer js.deinit();

    const subjects = [_][]const u8{"orders.>"};
    const stream = try js.createStream(.{
        .name = "ORDERS",
        .subjects = &subjects,
    });

    // Create a push consumer
    _ = try js.addConsumer("ORDERS", .{
        .name = "pusher",
        .deliver_subject = "my.delivery",
        .ack_policy = .explicit,
    });

    // Store a message
    _ = try stream.storeMessage("orders.new", null, "data1", null);

    // Get push deliveries
    var deliveries = js.getPushDeliveries("ORDERS", "orders.new");
    defer {
        for (deliveries.items) |*d| {
            consumer_mod.freeDeliveredMessages(&d.messages, allocator);
        }
        deliveries.deinit(allocator);
    }

    try std.testing.expectEqual(@as(usize, 1), deliveries.items.len);
    try std.testing.expectEqualStrings("my.delivery", deliveries.items[0].deliver_subject);
    try std.testing.expectEqual(@as(usize, 1), deliveries.items[0].messages.items.len);
}

test "jetstream tick ack timeout" {
    const allocator = std.testing.allocator;
    var js = try JetStream.init(allocator, .{});
    defer js.deinit();

    const subjects = [_][]const u8{"foo"};
    const stream = try js.createStream(.{
        .name = "TEST",
        .subjects = &subjects,
    });
    _ = try stream.storeMessage("foo", null, "data", null);

    const consumer = try js.addConsumer("TEST", .{
        .name = "C1",
        .ack_wait_ns = 1, // 1 nanosecond — will expire immediately
    });

    // Fetch a message
    var msgs = try consumer.fetch(1);
    consumer_mod.freeDeliveredMessages(&msgs, allocator);
    try std.testing.expectEqual(@as(u64, 1), consumer.pending.count());

    // Tick should detect ack timeout and queue redelivery
    js.tick(std.math.maxInt(i64));
    try std.testing.expect(consumer.redeliver.items.len > 0);
}

test "jetstream store_dir propagation" {
    const allocator = std.testing.allocator;
    var js = try JetStream.init(allocator, .{ .store_dir = "/tmp/zats-test-js-sd" });
    defer js.deinit();

    // Create a file-backed stream — should use store_dir
    const stream = try js.createStream(.{
        .name = "FSTREAM",
        .storage = .file,
    });
    try std.testing.expect(stream.file_store_ptr != null);

    // Clean up
    defer {
        const dir = "/tmp/zats-test-js-sd/FSTREAM";
        const wal = allocator.dupeZ(u8, dir ++ "/stream.wal") catch unreachable;
        defer allocator.free(wal);
        _ = std.c.unlink(wal.ptr);
        const sdZ = allocator.dupeZ(u8, dir) catch unreachable;
        defer allocator.free(sdZ);
        _ = std.c.rmdir(sdZ.ptr);
        const pZ = allocator.dupeZ(u8, "/tmp/zats-test-js-sd") catch unreachable;
        defer allocator.free(pZ);
        _ = std.c.rmdir(pZ.ptr);
    }
}

test "jetstream account info with storage" {
    const allocator = std.testing.allocator;
    var js = try JetStream.init(allocator, .{ .store_dir = "/tmp/zats-test-js-acct" });
    defer js.deinit();

    // Memory stream
    const mem_subj = [_][]const u8{"mem"};
    const mem_stream = try js.createStream(.{
        .name = "MEM",
        .subjects = &mem_subj,
    });
    _ = try mem_stream.storeMessage("mem", null, "hello", null);

    // File stream
    const file_subj = [_][]const u8{"file"};
    const file_stream = try js.createStream(.{
        .name = "FILE",
        .subjects = &file_subj,
        .storage = .file,
    });
    _ = try file_stream.storeMessage("file", null, "world", null);

    defer {
        const dir = "/tmp/zats-test-js-acct/FILE";
        const wal = allocator.dupeZ(u8, dir ++ "/stream.wal") catch unreachable;
        defer allocator.free(wal);
        _ = std.c.unlink(wal.ptr);
        const sdZ = allocator.dupeZ(u8, dir) catch unreachable;
        defer allocator.free(sdZ);
        _ = std.c.rmdir(sdZ.ptr);
        const pZ = allocator.dupeZ(u8, "/tmp/zats-test-js-acct") catch unreachable;
        defer allocator.free(pZ);
        _ = std.c.rmdir(pZ.ptr);
    }

    const info = js.accountInfo();
    try std.testing.expect(info.memory > 0);
    try std.testing.expect(info.storage > 0);
}
