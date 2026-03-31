//! NATS Message Router
//!
//! Wraps the SubjectTrie with subscription lifecycle management,
//! queue group delivery logic, and message routing.

const std = @import("std");
const trie_mod = @import("trie.zig");
const connection_mod = @import("connection.zig");

pub const Subscription = struct {
    sid: u64,
    subject: []const u8, // owned copy
    queue_group: ?[]const u8, // owned copy
    conn_id: u64,
    max_msgs: ?u64,
    delivered: u64,

    pub fn shouldAutoUnsub(self: *const Subscription) bool {
        if (self.max_msgs) |max| {
            return self.delivered >= max;
        }
        return false;
    }
};

pub const DeliveryTarget = struct {
    sub: *Subscription,
    conn_id: u64,
    sid: u64,
};

pub const Router = struct {
    trie: trie_mod.SubjectTrie(*Subscription),
    subscriptions: std.ArrayListUnmanaged(*Subscription),
    allocator: std.mem.Allocator,

    // Queue group round-robin state: key = "subject:queue_group", value = counter
    queue_rr_counters: std.StringHashMapUnmanaged(u64),

    pub fn init(allocator: std.mem.Allocator) !Router {
        return .{
            .trie = try trie_mod.SubjectTrie(*Subscription).init(allocator),
            .subscriptions = .empty,
            .allocator = allocator,
            .queue_rr_counters = .empty,
        };
    }

    pub fn deinit(self: *Router) void {
        // Free all subscriptions
        for (self.subscriptions.items) |sub| {
            self.allocator.free(sub.subject);
            if (sub.queue_group) |qg| self.allocator.free(qg);
            self.allocator.destroy(sub);
        }
        self.subscriptions.deinit(self.allocator);
        self.trie.deinit();

        // Free queue round-robin keys
        var it = self.queue_rr_counters.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.queue_rr_counters.deinit(self.allocator);
    }

    /// Register a subscription. Returns the subscription pointer.
    pub fn subscribe(self: *Router, conn_id: u64, sid: u64, subject: []const u8, queue_group: ?[]const u8) !*Subscription {
        const sub = try self.allocator.create(Subscription);
        sub.* = .{
            .sid = sid,
            .subject = try self.allocator.dupe(u8, subject),
            .queue_group = if (queue_group) |qg| try self.allocator.dupe(u8, qg) else null,
            .conn_id = conn_id,
            .max_msgs = null,
            .delivered = 0,
        };

        try self.trie.insert(subject, sub);
        try self.subscriptions.append(self.allocator, sub);
        return sub;
    }

    /// Unsubscribe by connection ID and SID.
    pub fn unsubscribe(self: *Router, conn_id: u64, sid: u64) bool {
        // Find the subscription
        for (self.subscriptions.items, 0..) |sub, i| {
            if (sub.conn_id == conn_id and sub.sid == sid) {
                _ = self.trie.remove(sub.subject, sub, &subEql);
                self.allocator.free(sub.subject);
                if (sub.queue_group) |qg| self.allocator.free(qg);
                self.allocator.destroy(sub);
                _ = self.subscriptions.orderedRemove(i);
                return true;
            }
        }
        return false;
    }

    /// Set max_msgs for auto-unsubscribe.
    pub fn setMaxMsgs(self: *Router, conn_id: u64, sid: u64, max_msgs: u64) bool {
        for (self.subscriptions.items) |sub| {
            if (sub.conn_id == conn_id and sub.sid == sid) {
                sub.max_msgs = max_msgs;
                return true;
            }
        }
        return false;
    }

    /// Remove all subscriptions for a connection.
    pub fn removeConnection(self: *Router, conn_id: u64) void {
        var i: usize = 0;
        while (i < self.subscriptions.items.len) {
            const sub = self.subscriptions.items[i];
            if (sub.conn_id == conn_id) {
                _ = self.trie.remove(sub.subject, sub, &subEql);
                self.allocator.free(sub.subject);
                if (sub.queue_group) |qg| self.allocator.free(qg);
                self.allocator.destroy(sub);
                _ = self.subscriptions.orderedRemove(i);
            } else {
                i += 1;
            }
        }
    }

    /// Route a published message to matching subscribers.
    /// Returns a list of delivery targets. Caller must deinit the list.
    /// Handles queue group round-robin: only one member per queue group receives the message.
    pub fn route(self: *Router, subject: []const u8, _: []const u8) !std.ArrayListUnmanaged(DeliveryTarget) {
        var matches: std.ArrayListUnmanaged(*Subscription) = .empty;
        defer matches.deinit(self.allocator);

        try self.trie.match(subject, &matches);

        var targets: std.ArrayListUnmanaged(DeliveryTarget) = .empty;

        // Separate into non-queue and queue-grouped subscriptions
        var queue_groups: std.StringHashMapUnmanaged(std.ArrayListUnmanaged(*Subscription)) = .empty;
        defer {
            var it = queue_groups.iterator();
            while (it.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
                entry.value_ptr.deinit(self.allocator);
            }
            queue_groups.deinit(self.allocator);
        }

        for (matches.items) |sub| {
            if (sub.shouldAutoUnsub()) continue;

            if (sub.queue_group) |qg| {
                // Build key: "subject_pattern:queue_group"
                const key = try std.fmt.allocPrint(self.allocator, "{s}:{s}", .{ sub.subject, qg });
                const result = queue_groups.getPtr(key);
                if (result) |list| {
                    try list.append(self.allocator, sub);
                    self.allocator.free(key);
                } else {
                    var list: std.ArrayListUnmanaged(*Subscription) = .empty;
                    try list.append(self.allocator, sub);
                    try queue_groups.put(self.allocator, key, list);
                }
            } else {
                // Non-queue subscription — always deliver
                sub.delivered += 1;
                try targets.append(self.allocator, .{
                    .sub = sub,
                    .conn_id = sub.conn_id,
                    .sid = sub.sid,
                });
            }
        }

        // For each queue group, pick one member via round-robin
        var qg_it = queue_groups.iterator();
        while (qg_it.next()) |entry| {
            const group_key = entry.key_ptr.*;
            const members = entry.value_ptr.items;
            if (members.len == 0) continue;

            // Get or create round-robin counter
            const counter = self.queue_rr_counters.getPtr(group_key);
            var idx: u64 = 0;
            if (counter) |c| {
                idx = c.*;
                c.* = (idx + 1) % members.len;
            } else {
                const owned_key = try self.allocator.dupe(u8, group_key);
                try self.queue_rr_counters.put(self.allocator, owned_key, 1 % members.len);
            }

            const selected = members[@intCast(idx % members.len)];
            selected.delivered += 1;
            try targets.append(self.allocator, .{
                .sub = selected,
                .conn_id = selected.conn_id,
                .sid = selected.sid,
            });
        }

        return targets;
    }

    /// Get total subscription count.
    pub fn subscriptionCount(self: *const Router) usize {
        return self.subscriptions.items.len;
    }

    fn subEql(a: *Subscription, b: *Subscription) bool {
        return a == b;
    }
};

// --- Tests ---

test "router subscribe and route" {
    const allocator = std.testing.allocator;
    var router = try Router.init(allocator);
    defer router.deinit();

    _ = try router.subscribe(1, 1, "foo.bar", null);
    _ = try router.subscribe(2, 1, "foo.baz", null);

    var targets = try router.route("foo.bar", "hello");
    defer targets.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), targets.items.len);
    try std.testing.expectEqual(@as(u64, 1), targets.items[0].conn_id);
}

test "router wildcard routing" {
    const allocator = std.testing.allocator;
    var router = try Router.init(allocator);
    defer router.deinit();

    _ = try router.subscribe(1, 1, "events.>", null);
    _ = try router.subscribe(2, 1, "events.*", null);

    // "events.login" matches both > and *
    var targets = try router.route("events.login", "data");
    defer targets.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), targets.items.len);

    // "events.login.failed" matches > but not *
    var targets2 = try router.route("events.login.failed", "data");
    defer targets2.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), targets2.items.len);
    try std.testing.expectEqual(@as(u64, 1), targets2.items[0].conn_id);
}

test "router unsubscribe" {
    const allocator = std.testing.allocator;
    var router = try Router.init(allocator);
    defer router.deinit();

    _ = try router.subscribe(1, 1, "foo.bar", null);
    _ = try router.subscribe(1, 2, "foo.baz", null);

    try std.testing.expectEqual(@as(usize, 2), router.subscriptionCount());

    const removed = router.unsubscribe(1, 1);
    try std.testing.expect(removed);
    try std.testing.expectEqual(@as(usize, 1), router.subscriptionCount());

    var targets = try router.route("foo.bar", "data");
    defer targets.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 0), targets.items.len);
}

test "router remove connection" {
    const allocator = std.testing.allocator;
    var router = try Router.init(allocator);
    defer router.deinit();

    _ = try router.subscribe(1, 1, "foo", null);
    _ = try router.subscribe(1, 2, "bar", null);
    _ = try router.subscribe(2, 1, "foo", null);

    try std.testing.expectEqual(@as(usize, 3), router.subscriptionCount());

    router.removeConnection(1);
    try std.testing.expectEqual(@as(usize, 1), router.subscriptionCount());
}

test "router queue group round robin" {
    const allocator = std.testing.allocator;
    var router = try Router.init(allocator);
    defer router.deinit();

    _ = try router.subscribe(1, 1, "work.tasks", "workers");
    _ = try router.subscribe(2, 1, "work.tasks", "workers");
    _ = try router.subscribe(3, 1, "work.tasks", "workers");

    // Each message should go to exactly one worker
    var conn_hits = [_]u32{ 0, 0, 0 };

    var i: usize = 0;
    while (i < 9) : (i += 1) {
        var targets = try router.route("work.tasks", "job");
        defer targets.deinit(allocator);
        try std.testing.expectEqual(@as(usize, 1), targets.items.len);
        conn_hits[@intCast(targets.items[0].conn_id - 1)] += 1;
    }

    // Each worker should get 3 messages (round robin)
    try std.testing.expectEqual(@as(u32, 3), conn_hits[0]);
    try std.testing.expectEqual(@as(u32, 3), conn_hits[1]);
    try std.testing.expectEqual(@as(u32, 3), conn_hits[2]);
}

test "router queue group with non-queue subs" {
    const allocator = std.testing.allocator;
    var router = try Router.init(allocator);
    defer router.deinit();

    // Two queue members + one regular subscriber
    _ = try router.subscribe(1, 1, "events", "group1");
    _ = try router.subscribe(2, 1, "events", "group1");
    _ = try router.subscribe(3, 1, "events", null); // non-queue

    var targets = try router.route("events", "data");
    defer targets.deinit(allocator);

    // Should deliver to exactly 2: one queue member + the non-queue subscriber
    try std.testing.expectEqual(@as(usize, 2), targets.items.len);
}

test "router max_msgs auto unsub" {
    const allocator = std.testing.allocator;
    var router = try Router.init(allocator);
    defer router.deinit();

    _ = try router.subscribe(1, 1, "foo", null);
    _ = router.setMaxMsgs(1, 1, 2);

    // First message — delivered
    var t1 = try router.route("foo", "msg1");
    defer t1.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), t1.items.len);

    // Second message — delivered
    var t2 = try router.route("foo", "msg2");
    defer t2.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), t2.items.len);

    // Third message — auto-unsubbed (delivered count >= max)
    var t3 = try router.route("foo", "msg3");
    defer t3.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 0), t3.items.len);
}
