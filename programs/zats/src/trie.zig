//! Subject Trie — Pure Data Structure for NATS Subject Matching
//!
//! Trie keyed on dot-separated tokens for O(k) subject lookup.
//! Supports NATS wildcards:
//!   * — matches exactly one token (e.g., foo.* matches foo.bar but not foo.bar.baz)
//!   > — matches one or more tokens (e.g., foo.> matches foo.bar and foo.bar.baz)
//!
//! This module is a pure data structure with no server/connection dependencies.

const std = @import("std");

pub fn SubjectTrie(comptime T: type) type {
    return struct {
        const Self = @This();

        root: *Node,
        allocator: std.mem.Allocator,
        total_entries: usize,

        pub const Node = struct {
            entries: std.ArrayListUnmanaged(T),
            children: std.StringHashMapUnmanaged(*Node),
            /// Entries registered with ">" wildcard at this node
            full_wildcard_entries: std.ArrayListUnmanaged(T),
            allocator: std.mem.Allocator,

            pub fn init(allocator: std.mem.Allocator) !*Node {
                const node = try allocator.create(Node);
                node.* = .{
                    .entries = .empty,
                    .children = .empty,
                    .full_wildcard_entries = .empty,
                    .allocator = allocator,
                };
                return node;
            }

            pub fn deinit(self: *Node) void {
                // Recursively free children
                var it = self.children.iterator();
                while (it.next()) |entry| {
                    // Free the owned key string
                    self.allocator.free(entry.key_ptr.*);
                    entry.value_ptr.*.deinit();
                }
                self.children.deinit(self.allocator);
                self.entries.deinit(self.allocator);
                self.full_wildcard_entries.deinit(self.allocator);
                self.allocator.destroy(self);
            }
        };

        pub fn init(allocator: std.mem.Allocator) !Self {
            return .{
                .root = try Node.init(allocator),
                .allocator = allocator,
                .total_entries = 0,
            };
        }

        pub fn deinit(self: *Self) void {
            self.root.deinit();
        }

        /// Insert an entry at the given subject.
        /// Subject is dot-separated (e.g., "foo.bar.baz", "foo.*", "foo.>").
        pub fn insert(self: *Self, subject: []const u8, entry: T) !void {
            var node = self.root;
            var tokenizer = TokenIterator.init(subject);

            while (tokenizer.next()) |token| {
                if (std.mem.eql(u8, token, ">")) {
                    // Full wildcard — store at this node's wildcard list
                    try node.full_wildcard_entries.append(self.allocator, entry);
                    self.total_entries += 1;
                    return;
                }

                // Get or create child node for this token
                const result = node.children.get(token);
                if (result) |child| {
                    node = child;
                } else {
                    const child = try Node.init(self.allocator);
                    const owned_key = try self.allocator.dupe(u8, token);
                    try node.children.put(self.allocator, owned_key, child);
                    node = child;
                }
            }

            // Exact match — store at the leaf node
            try node.entries.append(self.allocator, entry);
            self.total_entries += 1;
        }

        /// Remove an entry from the given subject.
        /// Uses eql function to find the matching entry.
        pub fn remove(self: *Self, subject: []const u8, entry: T, eql: *const fn (T, T) bool) bool {
            var node = self.root;
            var tokenizer = TokenIterator.init(subject);

            while (tokenizer.next()) |token| {
                if (std.mem.eql(u8, token, ">")) {
                    return removeFromList(&node.full_wildcard_entries, entry, eql, &self.total_entries);
                }

                const child = node.children.get(token) orelse return false;
                node = child;
            }

            return removeFromList(&node.entries, entry, eql, &self.total_entries);
        }

        /// Find all entries matching the given subject (concrete subject, not pattern).
        /// Returns matching entries collected into the provided ArrayList.
        pub fn match(self: *Self, subject: []const u8, results: *std.ArrayListUnmanaged(T)) !void {
            try self.matchRecursive(self.root, subject, 0, results);
        }

        fn matchRecursive(self: *Self, node: *Node, subject: []const u8, offset: usize, results: *std.ArrayListUnmanaged(T)) !void {
            // Collect ">" wildcard entries at this node — they match everything below
            for (node.full_wildcard_entries.items) |entry| {
                try results.append(self.allocator, entry);
            }

            // Find the next token
            var end = offset;
            while (end < subject.len and subject[end] != '.') : (end += 1) {}

            const token = subject[offset..end];
            const is_last = (end >= subject.len);

            // Try exact match child
            if (node.children.get(token)) |child| {
                if (is_last) {
                    // Last token — collect entries at this child
                    for (child.entries.items) |entry| {
                        try results.append(self.allocator, entry);
                    }
                    // Do NOT collect child.full_wildcard_entries here:
                    // ">" requires one or more ADDITIONAL tokens beyond this point.
                    // If this is the last token, there's nothing left for ">" to match.
                } else {
                    try self.matchRecursive(child, subject, end + 1, results);
                }
            }

            // Try "*" wildcard child (matches this single token)
            if (node.children.get("*")) |wildcard_child| {
                if (is_last) {
                    for (wildcard_child.entries.items) |entry| {
                        try results.append(self.allocator, entry);
                    }
                    // Same as above: don't collect ">" entries at wildcard child for last token
                } else {
                    try self.matchRecursive(wildcard_child, subject, end + 1, results);
                }
            }
        }

        /// Count total entries across all subjects.
        pub fn count(self: *const Self) usize {
            return self.total_entries;
        }

        fn removeFromList(list: *std.ArrayListUnmanaged(T), entry: T, eql: *const fn (T, T) bool, total: *usize) bool {
            for (list.items, 0..) |item, i| {
                if (eql(item, entry)) {
                    _ = list.orderedRemove(i);
                    total.* -= 1;
                    return true;
                }
            }
            return false;
        }

        pub const TokenIterator = struct {
            buf: []const u8,
            pos: usize,

            pub fn init(subject: []const u8) TokenIterator {
                return .{ .buf = subject, .pos = 0 };
            }

            pub fn next(self: *TokenIterator) ?[]const u8 {
                if (self.pos >= self.buf.len) return null;
                const start = self.pos;
                while (self.pos < self.buf.len and self.buf[self.pos] != '.') {
                    self.pos += 1;
                }
                const token = self.buf[start..self.pos];
                if (self.pos < self.buf.len) self.pos += 1; // skip dot
                return token;
            }
        };
    };
}

// --- Tests ---

const TestTrie = SubjectTrie(u64);

fn u64Eql(a: u64, b: u64) bool {
    return a == b;
}

test "trie insert and exact match" {
    var trie = try TestTrie.init(std.testing.allocator);
    defer trie.deinit();

    try trie.insert("foo.bar", 1);
    try trie.insert("foo.baz", 2);

    var results: std.ArrayListUnmanaged(u64) = .empty;
    defer results.deinit(std.testing.allocator);

    try trie.match("foo.bar", &results);
    try std.testing.expectEqual(@as(usize, 1), results.items.len);
    try std.testing.expectEqual(@as(u64, 1), results.items[0]);

    results.clearRetainingCapacity();
    try trie.match("foo.baz", &results);
    try std.testing.expectEqual(@as(usize, 1), results.items.len);
    try std.testing.expectEqual(@as(u64, 2), results.items[0]);
}

test "trie no match" {
    var trie = try TestTrie.init(std.testing.allocator);
    defer trie.deinit();

    try trie.insert("foo.bar", 1);

    var results: std.ArrayListUnmanaged(u64) = .empty;
    defer results.deinit(std.testing.allocator);

    try trie.match("foo.baz", &results);
    try std.testing.expectEqual(@as(usize, 0), results.items.len);

    try trie.match("foo.bar.baz", &results);
    try std.testing.expectEqual(@as(usize, 0), results.items.len);
}

test "trie single wildcard *" {
    var trie = try TestTrie.init(std.testing.allocator);
    defer trie.deinit();

    try trie.insert("foo.*", 1);

    var results: std.ArrayListUnmanaged(u64) = .empty;
    defer results.deinit(std.testing.allocator);

    try trie.match("foo.bar", &results);
    try std.testing.expectEqual(@as(usize, 1), results.items.len);
    try std.testing.expectEqual(@as(u64, 1), results.items[0]);

    results.clearRetainingCapacity();
    try trie.match("foo.baz", &results);
    try std.testing.expectEqual(@as(usize, 1), results.items.len);

    // * should NOT match multi-token
    results.clearRetainingCapacity();
    try trie.match("foo.bar.baz", &results);
    try std.testing.expectEqual(@as(usize, 0), results.items.len);
}

test "trie full wildcard >" {
    var trie = try TestTrie.init(std.testing.allocator);
    defer trie.deinit();

    try trie.insert("foo.>", 1);

    var results: std.ArrayListUnmanaged(u64) = .empty;
    defer results.deinit(std.testing.allocator);

    // > matches one token
    try trie.match("foo.bar", &results);
    try std.testing.expectEqual(@as(usize, 1), results.items.len);

    // > matches multiple tokens
    results.clearRetainingCapacity();
    try trie.match("foo.bar.baz", &results);
    try std.testing.expectEqual(@as(usize, 1), results.items.len);

    // > matches deep nesting
    results.clearRetainingCapacity();
    try trie.match("foo.a.b.c.d", &results);
    try std.testing.expectEqual(@as(usize, 1), results.items.len);

    // > should NOT match the parent alone (> matches one or more)
    results.clearRetainingCapacity();
    try trie.match("foo", &results);
    try std.testing.expectEqual(@as(usize, 0), results.items.len);
}

test "trie mixed wildcards and exact" {
    var trie = try TestTrie.init(std.testing.allocator);
    defer trie.deinit();

    try trie.insert("foo.bar", 1);
    try trie.insert("foo.*", 2);
    try trie.insert("foo.>", 3);

    var results: std.ArrayListUnmanaged(u64) = .empty;
    defer results.deinit(std.testing.allocator);

    try trie.match("foo.bar", &results);
    // Should match all three: exact, *, >
    try std.testing.expectEqual(@as(usize, 3), results.items.len);

    // Sort for deterministic comparison
    std.mem.sort(u64, results.items, {}, std.sort.asc(u64));
    try std.testing.expectEqual(@as(u64, 1), results.items[0]);
    try std.testing.expectEqual(@as(u64, 2), results.items[1]);
    try std.testing.expectEqual(@as(u64, 3), results.items[2]);
}

test "trie remove" {
    var trie = try TestTrie.init(std.testing.allocator);
    defer trie.deinit();

    try trie.insert("foo.bar", 1);
    try trie.insert("foo.bar", 2);
    try std.testing.expectEqual(@as(usize, 2), trie.count());

    const removed = trie.remove("foo.bar", 1, &u64Eql);
    try std.testing.expect(removed);
    try std.testing.expectEqual(@as(usize, 1), trie.count());

    var results: std.ArrayListUnmanaged(u64) = .empty;
    defer results.deinit(std.testing.allocator);
    try trie.match("foo.bar", &results);
    try std.testing.expectEqual(@as(usize, 1), results.items.len);
    try std.testing.expectEqual(@as(u64, 2), results.items[0]);
}

test "trie remove nonexistent" {
    var trie = try TestTrie.init(std.testing.allocator);
    defer trie.deinit();

    try trie.insert("foo.bar", 1);
    const removed = trie.remove("foo.bar", 99, &u64Eql);
    try std.testing.expect(!removed);
    try std.testing.expectEqual(@as(usize, 1), trie.count());
}

test "trie deep nesting" {
    var trie = try TestTrie.init(std.testing.allocator);
    defer trie.deinit();

    try trie.insert("a.b.c.d.e.f", 1);

    var results: std.ArrayListUnmanaged(u64) = .empty;
    defer results.deinit(std.testing.allocator);

    try trie.match("a.b.c.d.e.f", &results);
    try std.testing.expectEqual(@as(usize, 1), results.items.len);

    results.clearRetainingCapacity();
    try trie.match("a.b.c.d.e", &results);
    try std.testing.expectEqual(@as(usize, 0), results.items.len);
}

test "trie multiple subscribers same subject" {
    var trie = try TestTrie.init(std.testing.allocator);
    defer trie.deinit();

    try trie.insert("events.user", 1);
    try trie.insert("events.user", 2);
    try trie.insert("events.user", 3);

    var results: std.ArrayListUnmanaged(u64) = .empty;
    defer results.deinit(std.testing.allocator);

    try trie.match("events.user", &results);
    try std.testing.expectEqual(@as(usize, 3), results.items.len);
}

test "trie root wildcard" {
    var trie = try TestTrie.init(std.testing.allocator);
    defer trie.deinit();

    try trie.insert(">", 1);

    var results: std.ArrayListUnmanaged(u64) = .empty;
    defer results.deinit(std.testing.allocator);

    try trie.match("anything", &results);
    try std.testing.expectEqual(@as(usize, 1), results.items.len);

    results.clearRetainingCapacity();
    try trie.match("foo.bar.baz", &results);
    try std.testing.expectEqual(@as(usize, 1), results.items.len);
}

test "trie wildcard mid-path" {
    var trie = try TestTrie.init(std.testing.allocator);
    defer trie.deinit();

    try trie.insert("foo.*.baz", 1);

    var results: std.ArrayListUnmanaged(u64) = .empty;
    defer results.deinit(std.testing.allocator);

    try trie.match("foo.bar.baz", &results);
    try std.testing.expectEqual(@as(usize, 1), results.items.len);

    results.clearRetainingCapacity();
    try trie.match("foo.xxx.baz", &results);
    try std.testing.expectEqual(@as(usize, 1), results.items.len);

    results.clearRetainingCapacity();
    try trie.match("foo.bar.qux", &results);
    try std.testing.expectEqual(@as(usize, 0), results.items.len);
}

test "token iterator" {
    var it = TestTrie.TokenIterator.init("foo.bar.baz");

    try std.testing.expectEqualStrings("foo", it.next().?);
    try std.testing.expectEqualStrings("bar", it.next().?);
    try std.testing.expectEqualStrings("baz", it.next().?);
    try std.testing.expect(it.next() == null);
}

test "token iterator single token" {
    var it = TestTrie.TokenIterator.init("foo");

    try std.testing.expectEqualStrings("foo", it.next().?);
    try std.testing.expect(it.next() == null);
}
