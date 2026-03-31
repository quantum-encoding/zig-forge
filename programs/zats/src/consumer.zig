//! JetStream Consumer Engine
//!
//! A Consumer tracks message delivery and acknowledgment for a Stream.
//! Supports pull-based consumption, multiple ack policies, redelivery,
//! and configurable delivery options.

const std = @import("std");
const stream_mod = @import("stream.zig");
const store_mod = @import("store/store.zig");

extern "c" fn time(t: ?*isize) isize;

fn getNowNs() i64 {
    return @as(i64, time(null)) * 1_000_000_000;
}

// --- Enums ---

pub const DeliverPolicy = enum {
    all,
    last,
    new,
    by_start_sequence,
    by_start_time,
    last_per_subject,
};

pub const AckPolicy = enum {
    none,
    all,
    explicit,
};

pub const ReplayPolicy = enum {
    instant,
    original,
};

pub const AckType = enum {
    ack,
    nak,
    progress,
    next,
    term,
};

// --- Config ---

pub const ConsumerConfig = struct {
    name: []const u8 = "",
    durable_name: ?[]const u8 = null,
    deliver_subject: ?[]const u8 = null, // Push consumer delivery subject
    deliver_group: ?[]const u8 = null, // Queue group for push delivery
    deliver_policy: DeliverPolicy = .all,
    opt_start_seq: ?u64 = null,
    filter_subject: ?[]const u8 = null,
    ack_policy: AckPolicy = .explicit,
    ack_wait_ns: i64 = 30_000_000_000, // 30 seconds
    max_deliver: i64 = -1, // -1 = unlimited
    max_ack_pending: i64 = 1000,
    max_waiting: i64 = 512,
    description: ?[]const u8 = null,
    headers_only: bool = false,
};

// --- State types ---

pub const SequencePair = struct {
    stream_seq: u64,
    consumer_seq: u64,
};

pub const PendingMessage = struct {
    consumer_seq: u64,
    deliver_count: u32,
    timestamp_ns: i64,
};

pub const ConsumerState = struct {
    delivered: SequencePair,
    ack_floor: SequencePair,
    num_ack_pending: u64,
    num_redelivered: u64,
    num_waiting: u64,
    num_pending: u64,
};

pub const ConsumerInfo = struct {
    stream_name: []const u8,
    name: []const u8,
    config: ConsumerConfig,
    state: ConsumerState,
    created_ns: i64,
};

pub const DeliveredMessage = struct {
    subject: []const u8,
    headers: ?[]const u8,
    data: []const u8,
    sequence: u64,
    ack_reply: []const u8, // owned, caller must free via freeDeliveredMessages
};

pub const AckMetadata = struct {
    stream: []const u8,
    consumer: []const u8,
    deliver_count: u64,
    stream_seq: u64,
    consumer_seq: u64,
    timestamp_ns: i64,
    pending: u64,
};

// --- Public helpers ---

/// Parse an ack payload string into an AckType.
pub fn parseAckPayload(payload: []const u8) AckType {
    if (payload.len == 0) return .ack;
    if (std.mem.eql(u8, payload, "+ACK")) return .ack;
    if (std.mem.eql(u8, payload, "-NAK")) return .nak;
    if (std.mem.eql(u8, payload, "+WPI")) return .progress;
    if (std.mem.eql(u8, payload, "+NXT")) return .next;
    if (std.mem.eql(u8, payload, "+TERM")) return .term;
    return .ack;
}

/// Parse a $JS.ACK.* subject into its components.
/// Format: $JS.ACK.<stream>.<consumer>.<deliver_count>.<stream_seq>.<consumer_seq>.<timestamp>.<pending>
pub fn parseAckSubject(subject: []const u8) ?AckMetadata {
    const prefix = "$JS.ACK.";
    if (subject.len <= prefix.len) return null;
    if (!std.mem.eql(u8, subject[0..prefix.len], prefix)) return null;

    var tokens: [7][]const u8 = undefined;
    var count: usize = 0;
    var it = std.mem.splitScalar(u8, subject[prefix.len..], '.');
    while (it.next()) |tok| {
        if (count >= 7) return null;
        tokens[count] = tok;
        count += 1;
    }
    if (count != 7) return null;

    return .{
        .stream = tokens[0],
        .consumer = tokens[1],
        .deliver_count = std.fmt.parseInt(u64, tokens[2], 10) catch return null,
        .stream_seq = std.fmt.parseInt(u64, tokens[3], 10) catch return null,
        .consumer_seq = std.fmt.parseInt(u64, tokens[4], 10) catch return null,
        .timestamp_ns = std.fmt.parseInt(i64, tokens[5], 10) catch return null,
        .pending = std.fmt.parseInt(u64, tokens[6], 10) catch return null,
    };
}

/// Check if a subject matches a NATS pattern (supports * and > wildcards).
pub fn subjectMatches(pattern: []const u8, subject: []const u8) bool {
    if (std.mem.eql(u8, pattern, ">")) return true;

    var pat_it = std.mem.splitScalar(u8, pattern, '.');
    var sub_it = std.mem.splitScalar(u8, subject, '.');

    while (true) {
        const pat_tok = pat_it.next();
        const sub_tok = sub_it.next();

        if (pat_tok == null and sub_tok == null) return true;
        if (pat_tok == null) return false;

        const pt = pat_tok.?;
        if (std.mem.eql(u8, pt, ">")) return true;
        if (sub_tok == null) return false;
        if (std.mem.eql(u8, pt, "*")) continue;
        if (!std.mem.eql(u8, pt, sub_tok.?)) return false;
    }
}

/// Free all ack_reply allocations in a delivered messages list and deinit the list.
pub fn freeDeliveredMessages(msgs: *std.ArrayListUnmanaged(DeliveredMessage), allocator: std.mem.Allocator) void {
    for (msgs.items) |msg| {
        allocator.free(msg.ack_reply);
    }
    msgs.deinit(allocator);
}

/// Validate a consumer name: no spaces, tabs, dots, wildcards, or dollar signs.
pub fn validateConsumerName(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |c| {
        switch (c) {
            ' ', '\t', '.', '*', '>', '$' => return false,
            else => {},
        }
    }
    return true;
}

// --- Consumer ---

pub const Consumer = struct {
    config: ConsumerConfig,
    name: []const u8, // owned
    stream_name: []const u8, // owned
    stream: *stream_mod.Stream,

    // Delivery tracking
    deliver_seq: u64, // last assigned consumer sequence
    stream_cursor: u64, // next stream sequence to scan
    last_delivered_stream_seq: u64,

    // Ack tracking
    ack_floor_stream: u64,
    ack_floor_consumer: u64,
    pending: std.AutoHashMapUnmanaged(u64, PendingMessage),
    redeliver: std.ArrayListUnmanaged(u64),
    num_redelivered: u64,

    created_ns: i64,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, config: ConsumerConfig, stream: *stream_mod.Stream, stream_name: []const u8) !*Consumer {
        const c = try allocator.create(Consumer);

        const cursor: u64 = switch (config.deliver_policy) {
            .all => if (stream.first_seq > 0) stream.first_seq else 1,
            .last => if (stream.next_seq > 1) stream.next_seq - 1 else 1,
            .new => stream.next_seq,
            .by_start_sequence => config.opt_start_seq orelse 1,
            .by_start_time, .last_per_subject => if (stream.first_seq > 0) stream.first_seq else 1,
        };

        c.* = .{
            .config = config,
            .name = try allocator.dupe(u8, config.name),
            .stream_name = try allocator.dupe(u8, stream_name),
            .stream = stream,
            .deliver_seq = 0,
            .stream_cursor = cursor,
            .last_delivered_stream_seq = 0,
            .ack_floor_stream = 0,
            .ack_floor_consumer = 0,
            .pending = .empty,
            .redeliver = .empty,
            .num_redelivered = 0,
            .created_ns = getNowNs(),
            .allocator = allocator,
        };
        return c;
    }

    pub fn deinit(self: *Consumer) void {
        self.allocator.free(self.name);
        self.allocator.free(self.stream_name);
        self.pending.deinit(self.allocator);
        self.redeliver.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    /// Fetch up to `batch` messages. Caller must call freeDeliveredMessages on the result.
    pub fn fetch(self: *Consumer, batch: u32) !std.ArrayListUnmanaged(DeliveredMessage) {
        var result: std.ArrayListUnmanaged(DeliveredMessage) = .empty;
        errdefer freeDeliveredMessages(&result, self.allocator);
        var delivered: u32 = 0;

        const max_pending_limit: u64 = if (self.config.max_ack_pending > 0)
            @as(u64, @intCast(self.config.max_ack_pending))
        else
            std.math.maxInt(u64);

        // Phase 1: redeliver NAK'd/timed-out messages
        while (self.redeliver.items.len > 0 and delivered < batch) {
            const seq = self.redeliver.items[0];

            if (self.pending.getPtr(seq)) |p| {
                const msg = self.stream.getMessage(seq) orelse {
                    // Message deleted from stream, clean up
                    _ = self.pending.fetchRemove(seq);
                    _ = self.redeliver.orderedRemove(0);
                    continue;
                };

                p.deliver_count += 1;
                p.timestamp_ns = getNowNs();
                self.num_redelivered += 1;

                // Check max_deliver limit
                if (self.config.max_deliver > 0 and p.deliver_count > @as(u32, @intCast(self.config.max_deliver))) {
                    _ = self.pending.fetchRemove(seq);
                    _ = self.redeliver.orderedRemove(0);
                    continue;
                }

                const ack_reply = try self.encodeAckSubject(seq, p.consumer_seq, p.deliver_count);
                try result.append(self.allocator, .{
                    .subject = msg.subject,
                    .headers = msg.headers,
                    .data = msg.data,
                    .sequence = seq,
                    .ack_reply = ack_reply,
                });
                delivered += 1;
                _ = self.redeliver.orderedRemove(0);
            } else {
                // Not in pending (already acked), remove stale entry
                _ = self.redeliver.orderedRemove(0);
            }
        }

        // Phase 2: deliver new messages from stream
        while (delivered < batch) {
            // Check max_ack_pending (only for policies that track acks)
            if (self.config.ack_policy != .none and self.pending.count() >= max_pending_limit) break;

            const msg = self.findNextMessage() orelse break;

            self.deliver_seq += 1;
            const consumer_seq = self.deliver_seq;
            self.last_delivered_stream_seq = msg.sequence;

            if (self.config.ack_policy != .none) {
                try self.pending.put(self.allocator, msg.sequence, .{
                    .consumer_seq = consumer_seq,
                    .deliver_count = 1,
                    .timestamp_ns = getNowNs(),
                });
            }

            const ack_reply = if (self.config.ack_policy != .none)
                try self.encodeAckSubject(msg.sequence, consumer_seq, 1)
            else
                try self.allocator.dupe(u8, "");

            try result.append(self.allocator, .{
                .subject = msg.subject,
                .headers = msg.headers,
                .data = msg.data,
                .sequence = msg.sequence,
                .ack_reply = ack_reply,
            });
            delivered += 1;
        }

        return result;
    }

    /// Process an acknowledgment for a stream sequence.
    pub fn processAck(self: *Consumer, stream_seq: u64, ack_type: AckType) void {
        switch (ack_type) {
            .ack, .next, .term => {
                if (self.config.ack_policy == .all) {
                    self.ackUpTo(stream_seq);
                } else {
                    _ = self.pending.fetchRemove(stream_seq);
                }
                self.advanceAckFloor();
            },
            .nak => {
                if (self.pending.get(stream_seq) != null) {
                    self.redeliver.append(self.allocator, stream_seq) catch {};
                }
            },
            .progress => {
                if (self.pending.getPtr(stream_seq)) |p| {
                    p.timestamp_ns = getNowNs();
                }
            },
        }
    }

    /// Check for ack_wait timeouts and queue expired messages for redelivery.
    pub fn checkAckTimeouts(self: *Consumer, now_ns: i64) void {
        if (self.config.ack_policy == .none) return;
        if (self.config.ack_wait_ns <= 0) return;

        var it = self.pending.iterator();
        while (it.next()) |entry| {
            const deadline = entry.value_ptr.timestamp_ns + self.config.ack_wait_ns;
            if (now_ns >= deadline) {
                // Check if not already in redeliver queue
                var already_queued = false;
                for (self.redeliver.items) |seq| {
                    if (seq == entry.key_ptr.*) {
                        already_queued = true;
                        break;
                    }
                }
                if (!already_queued) {
                    self.redeliver.append(self.allocator, entry.key_ptr.*) catch {};
                }
            }
        }
    }

    /// Get consumer info snapshot.
    /// Returns true if this is a push consumer (has a deliver_subject).
    pub fn isPush(self: *const Consumer) bool {
        return self.config.deliver_subject != null;
    }

    pub fn info(self: *Consumer) ConsumerInfo {
        return .{
            .stream_name = self.stream_name,
            .name = self.name,
            .config = self.config,
            .state = .{
                .delivered = .{
                    .stream_seq = self.last_delivered_stream_seq,
                    .consumer_seq = self.deliver_seq,
                },
                .ack_floor = .{
                    .stream_seq = self.ack_floor_stream,
                    .consumer_seq = self.ack_floor_consumer,
                },
                .num_ack_pending = self.pending.count(),
                .num_redelivered = self.num_redelivered,
                .num_waiting = 0,
                .num_pending = self.numPending(),
            },
            .created_ns = self.created_ns,
        };
    }

    // --- Internal ---

    fn findNextMessage(self: *Consumer) ?store_mod.StoredMessage {
        while (self.stream_cursor < self.stream.next_seq) {
            const seq = self.stream_cursor;
            self.stream_cursor += 1;

            // Skip if already pending ack
            if (self.pending.get(seq) != null) continue;

            const msg = self.stream.getMessage(seq) orelse continue;

            // Apply filter subject
            if (self.config.filter_subject) |filter| {
                if (!subjectMatches(filter, msg.subject)) continue;
            }

            return msg;
        }
        return null;
    }

    fn ackUpTo(self: *Consumer, stream_seq: u64) void {
        // Collect keys to remove (can't modify HashMap during iteration)
        var to_remove: std.ArrayListUnmanaged(u64) = .empty;
        defer to_remove.deinit(self.allocator);

        var it = self.pending.iterator();
        while (it.next()) |entry| {
            if (entry.key_ptr.* <= stream_seq) {
                to_remove.append(self.allocator, entry.key_ptr.*) catch {};
            }
        }

        for (to_remove.items) |seq| {
            _ = self.pending.fetchRemove(seq);
        }
    }

    fn advanceAckFloor(self: *Consumer) void {
        var seq = self.ack_floor_stream + 1;
        while (seq < self.stream_cursor) : (seq += 1) {
            if (self.pending.get(seq) != null) break;
            self.ack_floor_stream = seq;
        }
        // Approximate consumer ack floor
        if (self.deliver_seq >= self.pending.count()) {
            self.ack_floor_consumer = self.deliver_seq - self.pending.count();
        }
    }

    fn numPending(self: *Consumer) u64 {
        if (self.stream_cursor >= self.stream.next_seq) return 0;
        return self.stream.next_seq - self.stream_cursor;
    }

    fn encodeAckSubject(self: *Consumer, stream_seq: u64, consumer_seq: u64, deliver_count: u32) ![]const u8 {
        return std.fmt.allocPrint(
            self.allocator,
            "$JS.ACK.{s}.{s}.{d}.{d}.{d}.{d}.{d}",
            .{
                self.stream_name,
                self.name,
                deliver_count,
                stream_seq,
                consumer_seq,
                getNowNs(),
                self.numPending(),
            },
        );
    }
};

// --- Tests ---

test "consumer create and fetch" {
    const allocator = std.testing.allocator;
    var stream = try stream_mod.Stream.init(allocator, .{ .name = "TEST" });
    defer stream.deinit();

    _ = try stream.storeMessage("foo", null, "msg1", null);
    _ = try stream.storeMessage("foo", null, "msg2", null);
    _ = try stream.storeMessage("foo", null, "msg3", null);

    var consumer = try Consumer.init(allocator, .{ .name = "C1" }, stream, "TEST");
    defer consumer.deinit();

    var msgs = try consumer.fetch(2);
    defer freeDeliveredMessages(&msgs, allocator);

    try std.testing.expectEqual(@as(usize, 2), msgs.items.len);
    try std.testing.expectEqualStrings("msg1", msgs.items[0].data);
    try std.testing.expectEqualStrings("msg2", msgs.items[1].data);
    try std.testing.expectEqual(@as(u64, 1), msgs.items[0].sequence);
    try std.testing.expectEqual(@as(u64, 2), msgs.items[1].sequence);
}

test "consumer fetch all then empty" {
    const allocator = std.testing.allocator;
    var stream = try stream_mod.Stream.init(allocator, .{ .name = "TEST" });
    defer stream.deinit();

    _ = try stream.storeMessage("foo", null, "msg1", null);
    _ = try stream.storeMessage("foo", null, "msg2", null);

    var consumer = try Consumer.init(allocator, .{ .name = "C1" }, stream, "TEST");
    defer consumer.deinit();

    var msgs = try consumer.fetch(10);
    defer freeDeliveredMessages(&msgs, allocator);
    try std.testing.expectEqual(@as(usize, 2), msgs.items.len);

    // No more messages
    var msgs2 = try consumer.fetch(10);
    defer freeDeliveredMessages(&msgs2, allocator);
    try std.testing.expectEqual(@as(usize, 0), msgs2.items.len);
}

test "consumer ack removes from pending" {
    const allocator = std.testing.allocator;
    var stream = try stream_mod.Stream.init(allocator, .{ .name = "TEST" });
    defer stream.deinit();

    _ = try stream.storeMessage("foo", null, "msg1", null);
    _ = try stream.storeMessage("foo", null, "msg2", null);

    var consumer = try Consumer.init(allocator, .{ .name = "C1" }, stream, "TEST");
    defer consumer.deinit();

    var msgs = try consumer.fetch(2);
    defer freeDeliveredMessages(&msgs, allocator);
    try std.testing.expectEqual(@as(u64, 2), consumer.pending.count());

    consumer.processAck(1, .ack);
    try std.testing.expectEqual(@as(u64, 1), consumer.pending.count());
    try std.testing.expectEqual(@as(u64, 1), consumer.ack_floor_stream);

    consumer.processAck(2, .ack);
    try std.testing.expectEqual(@as(u64, 0), consumer.pending.count());
    try std.testing.expectEqual(@as(u64, 2), consumer.ack_floor_stream);
}

test "consumer nak redelivers" {
    const allocator = std.testing.allocator;
    var stream = try stream_mod.Stream.init(allocator, .{ .name = "TEST" });
    defer stream.deinit();

    _ = try stream.storeMessage("foo", null, "msg1", null);

    var consumer = try Consumer.init(allocator, .{ .name = "C1" }, stream, "TEST");
    defer consumer.deinit();

    var msgs1 = try consumer.fetch(1);
    defer freeDeliveredMessages(&msgs1, allocator);
    try std.testing.expectEqual(@as(usize, 1), msgs1.items.len);

    // NAK
    consumer.processAck(1, .nak);

    // Fetch again — should redeliver
    var msgs2 = try consumer.fetch(1);
    defer freeDeliveredMessages(&msgs2, allocator);
    try std.testing.expectEqual(@as(usize, 1), msgs2.items.len);
    try std.testing.expectEqualStrings("msg1", msgs2.items[0].data);
    try std.testing.expectEqual(@as(u64, 1), msgs2.items[0].sequence);
}

test "consumer term ack" {
    const allocator = std.testing.allocator;
    var stream = try stream_mod.Stream.init(allocator, .{ .name = "TEST" });
    defer stream.deinit();

    _ = try stream.storeMessage("foo", null, "msg1", null);

    var consumer = try Consumer.init(allocator, .{ .name = "C1" }, stream, "TEST");
    defer consumer.deinit();

    var msgs = try consumer.fetch(1);
    defer freeDeliveredMessages(&msgs, allocator);

    consumer.processAck(1, .term);
    try std.testing.expectEqual(@as(u64, 0), consumer.pending.count());
}

test "consumer cumulative ack (all policy)" {
    const allocator = std.testing.allocator;
    var stream = try stream_mod.Stream.init(allocator, .{ .name = "TEST" });
    defer stream.deinit();

    _ = try stream.storeMessage("foo", null, "msg1", null);
    _ = try stream.storeMessage("foo", null, "msg2", null);
    _ = try stream.storeMessage("foo", null, "msg3", null);

    var consumer = try Consumer.init(allocator, .{ .name = "C1", .ack_policy = .all }, stream, "TEST");
    defer consumer.deinit();

    var msgs = try consumer.fetch(3);
    defer freeDeliveredMessages(&msgs, allocator);
    try std.testing.expectEqual(@as(u64, 3), consumer.pending.count());

    // Acking seq 2 should ack 1 and 2 (cumulative)
    consumer.processAck(2, .ack);
    try std.testing.expectEqual(@as(u64, 1), consumer.pending.count());
    try std.testing.expect(consumer.pending.get(1) == null);
    try std.testing.expect(consumer.pending.get(2) == null);
    try std.testing.expect(consumer.pending.get(3) != null);
}

test "consumer ack_policy none" {
    const allocator = std.testing.allocator;
    var stream = try stream_mod.Stream.init(allocator, .{ .name = "TEST" });
    defer stream.deinit();

    _ = try stream.storeMessage("foo", null, "msg1", null);

    var consumer = try Consumer.init(allocator, .{ .name = "C1", .ack_policy = .none }, stream, "TEST");
    defer consumer.deinit();

    var msgs = try consumer.fetch(1);
    defer freeDeliveredMessages(&msgs, allocator);
    try std.testing.expectEqual(@as(usize, 1), msgs.items.len);
    // No pending since ack_policy is none
    try std.testing.expectEqual(@as(u64, 0), consumer.pending.count());
}

test "consumer deliver policy new" {
    const allocator = std.testing.allocator;
    var stream = try stream_mod.Stream.init(allocator, .{ .name = "TEST" });
    defer stream.deinit();

    _ = try stream.storeMessage("foo", null, "old", null);
    _ = try stream.storeMessage("foo", null, "old2", null);

    // Consumer with "new" policy — should not see existing messages
    var consumer = try Consumer.init(allocator, .{ .name = "C1", .deliver_policy = .new }, stream, "TEST");
    defer consumer.deinit();

    var msgs = try consumer.fetch(10);
    defer freeDeliveredMessages(&msgs, allocator);
    try std.testing.expectEqual(@as(usize, 0), msgs.items.len);

    // Store a new message
    _ = try stream.storeMessage("foo", null, "new1", null);

    var msgs2 = try consumer.fetch(10);
    defer freeDeliveredMessages(&msgs2, allocator);
    try std.testing.expectEqual(@as(usize, 1), msgs2.items.len);
    try std.testing.expectEqualStrings("new1", msgs2.items[0].data);
}

test "consumer deliver policy by_start_sequence" {
    const allocator = std.testing.allocator;
    var stream = try stream_mod.Stream.init(allocator, .{ .name = "TEST" });
    defer stream.deinit();

    _ = try stream.storeMessage("foo", null, "msg1", null);
    _ = try stream.storeMessage("foo", null, "msg2", null);
    _ = try stream.storeMessage("foo", null, "msg3", null);

    var consumer = try Consumer.init(allocator, .{
        .name = "C1",
        .deliver_policy = .by_start_sequence,
        .opt_start_seq = 2,
    }, stream, "TEST");
    defer consumer.deinit();

    var msgs = try consumer.fetch(10);
    defer freeDeliveredMessages(&msgs, allocator);
    try std.testing.expectEqual(@as(usize, 2), msgs.items.len);
    try std.testing.expectEqualStrings("msg2", msgs.items[0].data);
    try std.testing.expectEqualStrings("msg3", msgs.items[1].data);
}

test "consumer filter subject" {
    const allocator = std.testing.allocator;
    var stream = try stream_mod.Stream.init(allocator, .{ .name = "TEST" });
    defer stream.deinit();

    _ = try stream.storeMessage("orders.new", null, "o1", null);
    _ = try stream.storeMessage("events.login", null, "e1", null);
    _ = try stream.storeMessage("orders.shipped", null, "o2", null);

    var consumer = try Consumer.init(allocator, .{
        .name = "C1",
        .filter_subject = "orders.*",
    }, stream, "TEST");
    defer consumer.deinit();

    var msgs = try consumer.fetch(10);
    defer freeDeliveredMessages(&msgs, allocator);
    try std.testing.expectEqual(@as(usize, 2), msgs.items.len);
    try std.testing.expectEqualStrings("o1", msgs.items[0].data);
    try std.testing.expectEqualStrings("o2", msgs.items[1].data);
}

test "consumer max_ack_pending" {
    const allocator = std.testing.allocator;
    var stream = try stream_mod.Stream.init(allocator, .{ .name = "TEST" });
    defer stream.deinit();

    _ = try stream.storeMessage("foo", null, "a", null);
    _ = try stream.storeMessage("foo", null, "b", null);
    _ = try stream.storeMessage("foo", null, "c", null);

    var consumer = try Consumer.init(allocator, .{
        .name = "C1",
        .max_ack_pending = 2,
    }, stream, "TEST");
    defer consumer.deinit();

    // Should only deliver 2 (max_ack_pending)
    var msgs = try consumer.fetch(10);
    defer freeDeliveredMessages(&msgs, allocator);
    try std.testing.expectEqual(@as(usize, 2), msgs.items.len);

    // Ack one, then fetch more
    consumer.processAck(1, .ack);

    var msgs2 = try consumer.fetch(10);
    defer freeDeliveredMessages(&msgs2, allocator);
    try std.testing.expectEqual(@as(usize, 1), msgs2.items.len);
    try std.testing.expectEqualStrings("c", msgs2.items[0].data);
}

test "consumer info" {
    const allocator = std.testing.allocator;
    var stream = try stream_mod.Stream.init(allocator, .{ .name = "TEST" });
    defer stream.deinit();

    _ = try stream.storeMessage("foo", null, "msg1", null);

    var consumer = try Consumer.init(allocator, .{ .name = "C1" }, stream, "TEST");
    defer consumer.deinit();

    var msgs = try consumer.fetch(1);
    defer freeDeliveredMessages(&msgs, allocator);

    const ci = consumer.info();
    try std.testing.expectEqualStrings("TEST", ci.stream_name);
    try std.testing.expectEqualStrings("C1", ci.name);
    try std.testing.expectEqual(@as(u64, 1), ci.state.delivered.consumer_seq);
    try std.testing.expectEqual(@as(u64, 1), ci.state.num_ack_pending);
}

test "parse ack subject" {
    const meta = parseAckSubject("$JS.ACK.ORDERS.processor.1.42.17.1708632000000000000.5").?;
    try std.testing.expectEqualStrings("ORDERS", meta.stream);
    try std.testing.expectEqualStrings("processor", meta.consumer);
    try std.testing.expectEqual(@as(u64, 1), meta.deliver_count);
    try std.testing.expectEqual(@as(u64, 42), meta.stream_seq);
    try std.testing.expectEqual(@as(u64, 17), meta.consumer_seq);
    try std.testing.expectEqual(@as(u64, 5), meta.pending);
}

test "parse ack subject invalid" {
    try std.testing.expect(parseAckSubject("not.an.ack") == null);
    try std.testing.expect(parseAckSubject("$JS.ACK.too.few.fields") == null);
    try std.testing.expect(parseAckSubject("") == null);
}

test "parse ack payload" {
    try std.testing.expectEqual(AckType.ack, parseAckPayload(""));
    try std.testing.expectEqual(AckType.ack, parseAckPayload("+ACK"));
    try std.testing.expectEqual(AckType.nak, parseAckPayload("-NAK"));
    try std.testing.expectEqual(AckType.progress, parseAckPayload("+WPI"));
    try std.testing.expectEqual(AckType.next, parseAckPayload("+NXT"));
    try std.testing.expectEqual(AckType.term, parseAckPayload("+TERM"));
}

test "subject matches" {
    try std.testing.expect(subjectMatches("foo.bar", "foo.bar"));
    try std.testing.expect(!subjectMatches("foo.bar", "foo.baz"));
    try std.testing.expect(subjectMatches("foo.*", "foo.bar"));
    try std.testing.expect(subjectMatches("foo.*", "foo.baz"));
    try std.testing.expect(!subjectMatches("foo.*", "foo.bar.baz"));
    try std.testing.expect(subjectMatches("foo.>", "foo.bar"));
    try std.testing.expect(subjectMatches("foo.>", "foo.bar.baz"));
    try std.testing.expect(!subjectMatches("foo.>", "bar.baz"));
    try std.testing.expect(subjectMatches(">", "anything.here"));
}

test "validate consumer name" {
    try std.testing.expect(validateConsumerName("processor"));
    try std.testing.expect(validateConsumerName("my-consumer"));
    try std.testing.expect(!validateConsumerName(""));
    try std.testing.expect(!validateConsumerName("bad name"));
    try std.testing.expect(!validateConsumerName("bad.name"));
}

test "consumer isPush" {
    const allocator = std.testing.allocator;
    const subjects = [_][]const u8{"foo"};
    var stream = try stream_mod.Stream.init(allocator, .{
        .name = "TEST",
        .subjects = &subjects,
    });
    defer stream.deinit();

    // Pull consumer (no deliver_subject)
    var pull = try Consumer.init(allocator, .{ .name = "pull1" }, stream, "TEST");
    defer pull.deinit();
    try std.testing.expect(!pull.isPush());

    // Push consumer (has deliver_subject)
    var push = try Consumer.init(allocator, .{ .name = "push1", .deliver_subject = "my.delivery" }, stream, "TEST");
    defer push.deinit();
    try std.testing.expect(push.isPush());
}
