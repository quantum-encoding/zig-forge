//! B-tree index for timestamp → row offset mapping
//! Provides O(log N) time-range queries
//!
//! Performance: ~100ns lookups

const std = @import("std");

/// B-tree order (number of children per node)
const ORDER = 64; // Cache-friendly size
const MIN_KEYS = ORDER / 2 - 1;
const MAX_KEYS = ORDER - 1;

/// B-tree entry (timestamp → row offset)
pub const Entry = struct {
    key: i64,   // Timestamp
    value: u64, // Row offset in file
};

/// B-tree node
pub const Node = struct {
    is_leaf: bool,
    num_keys: usize,
    keys: [MAX_KEYS]i64,
    values: [MAX_KEYS]u64,     // For leaf nodes
    children: [ORDER]?*Node,    // For internal nodes
    parent: ?*Node,

    pub fn init(allocator: std.mem.Allocator, is_leaf: bool) !*Node {
        const node = try allocator.create(Node);
        node.* = .{
            .is_leaf = is_leaf,
            .num_keys = 0,
            .keys = [_]i64{0} ** MAX_KEYS,
            .values = [_]u64{0} ** MAX_KEYS,
            .children = [_]?*Node{null} ** ORDER,
            .parent = null,
        };
        return node;
    }

    pub fn deinit(self: *Node, allocator: std.mem.Allocator) void {
        if (!self.is_leaf) {
            for (self.children[0 .. self.num_keys + 1]) |child_opt| {
                if (child_opt) |child| {
                    child.deinit(allocator);
                }
            }
        }
        allocator.destroy(self);
    }

    /// Binary search for key position
    fn searchKey(self: *const Node, key: i64) usize {
        var left: usize = 0;
        var right: usize = self.num_keys;

        while (left < right) {
            const mid = left + (right - left) / 2;
            if (self.keys[mid] < key) {
                left = mid + 1;
            } else {
                right = mid;
            }
        }

        return left;
    }
};

/// B-tree index
pub const BTree = struct {
    allocator: std.mem.Allocator,
    root: ?*Node,
    size: usize,

    pub fn init(allocator: std.mem.Allocator) !BTree {
        return .{
            .allocator = allocator,
            .root = null,
            .size = 0,
        };
    }

    pub fn deinit(self: *BTree) void {
        if (self.root) |root| {
            root.deinit(self.allocator);
        }
    }

    /// Insert key-value pair
    pub fn insert(self: *BTree, key: i64, value: u64) !void {
        // Create root if needed
        if (self.root == null) {
            self.root = try Node.init(self.allocator, true);
        }

        const root = self.root.?;

        // If root is full, split it
        if (root.num_keys == MAX_KEYS) {
            const new_root = try Node.init(self.allocator, false);
            new_root.children[0] = root;
            root.parent = new_root;
            try self.splitChild(new_root, 0);
            self.root = new_root;
        }

        try self.insertNonFull(self.root.?, key, value);
        self.size += 1;
    }

    /// Insert into non-full node
    fn insertNonFull(self: *BTree, node: *Node, key: i64, value: u64) !void {
        var idx = node.searchKey(key);

        if (node.is_leaf) {
            // Shift keys and values to make space
            var i = node.num_keys;
            while (i > idx) : (i -= 1) {
                node.keys[i] = node.keys[i - 1];
                node.values[i] = node.values[i - 1];
            }

            // Insert new key-value
            node.keys[idx] = key;
            node.values[idx] = value;
            node.num_keys += 1;
        } else {
            // Internal node - recurse to child
            var child = node.children[idx].?;

            // Split child if full
            if (child.num_keys == MAX_KEYS) {
                try self.splitChild(node, idx);
                if (key > node.keys[idx]) {
                    idx += 1;
                    child = node.children[idx].?;
                }
            }

            try self.insertNonFull(child, key, value);
        }
    }

    /// Split full child node
    fn splitChild(self: *BTree, parent: *Node, idx: usize) !void {
        const full_child = parent.children[idx].?;
        const new_child = try Node.init(self.allocator, full_child.is_leaf);
        new_child.parent = parent;

        const mid = MIN_KEYS;

        // Copy upper half of keys AND their values to the new node. Every node
        // (leaf or internal) carries a value for each of its keys, so the value
        // must always be copied — copying it only for leaves is what silently
        // dropped the promoted key's value on every split.
        new_child.num_keys = MIN_KEYS;
        for (0..MIN_KEYS) |i| {
            new_child.keys[i] = full_child.keys[mid + 1 + i];
            new_child.values[i] = full_child.values[mid + 1 + i];
        }

        // Copy children if internal node
        if (!full_child.is_leaf) {
            for (0..MIN_KEYS + 1) |i| {
                new_child.children[i] = full_child.children[mid + 1 + i];
                if (new_child.children[i]) |child| {
                    child.parent = new_child;
                }
            }
        }

        full_child.num_keys = MIN_KEYS;

        // Shift parent's children to make space
        var i = parent.num_keys;
        while (i > idx) : (i -= 1) {
            parent.children[i + 1] = parent.children[i];
        }
        parent.children[idx + 1] = new_child;

        // Shift parent's keys AND values to make space
        i = parent.num_keys;
        while (i > idx) : (i -= 1) {
            parent.keys[i] = parent.keys[i - 1];
            parent.values[i] = parent.values[i - 1];
        }

        // Move the middle key AND its value up to the parent, so the promoted
        // separator keeps its row offset (internal nodes are searchable).
        parent.keys[idx] = full_child.keys[mid];
        parent.values[idx] = full_child.values[mid];
        parent.num_keys += 1;
    }

    /// Search for exact key
    pub fn search(self: *const BTree, key: i64) ?u64 {
        if (self.root == null) return null;
        return self.searchNode(self.root.?, key);
    }

    fn searchNode(self: *const BTree, node: *Node, key: i64) ?u64 {
        const idx = node.searchKey(key);

        // Every node stores the value alongside its own key, so an exact hit
        // returns directly whether the node is a leaf or an internal node.
        if (idx < node.num_keys and node.keys[idx] == key) {
            return node.values[idx];
        }

        if (node.is_leaf) {
            return null;
        }

        // Descend into children[idx], which holds keys strictly less than
        // keys[idx] (and greater than keys[idx-1]).
        return self.searchNode(node.children[idx].?, key);
    }

    /// Range query: find all entries between start and end (inclusive)
    pub fn rangeQuery(self: *const BTree, start: i64, end: i64, allocator: std.mem.Allocator) ![]Entry {
        var results: std.ArrayList(Entry) = .empty;
        errdefer results.deinit(allocator);

        if (self.root) |root| {
            try self.rangeQueryNode(root, start, end, &results, allocator);
        }

        return results.toOwnedSlice(allocator);
    }

    fn rangeQueryNode(self: *const BTree, node: *Node, start: i64, end: i64, results: *std.ArrayList(Entry), allocator: std.mem.Allocator) !void {
        // In-order traversal: for each key, first descend the left subtree, then
        // emit the key itself if it falls in range. Internal keys carry their own
        // value now, so promoted separators are no longer skipped. Results come
        // out sorted ascending by key. Subtrees provably outside [start, end] are
        // pruned: children[i] holds keys < keys[i], so it is skipped when
        // keys[i] <= start, and once keys[i] > end nothing further can match.
        var i: usize = 0;
        while (i < node.num_keys) : (i += 1) {
            if (!node.is_leaf and node.keys[i] > start) {
                try self.rangeQueryNode(node.children[i].?, start, end, results, allocator);
            }

            const k = node.keys[i];
            if (k > end) {
                // This key and every key/subtree to its right are out of range.
                return;
            }
            if (k >= start) {
                try results.append(allocator, .{ .key = k, .value = node.values[i] });
            }
        }

        // Rightmost child holds keys greater than the last separator. Reached
        // only when every key was <= end, so it may still contain matches.
        if (!node.is_leaf) {
            try self.rangeQueryNode(node.children[node.num_keys].?, start, end, results, allocator);
        }
    }

    /// Get minimum key
    pub fn getMin(self: *const BTree) ?i64 {
        if (self.root == null) return null;

        var node = self.root.?;
        while (!node.is_leaf) {
            node = node.children[0].?;
        }

        return if (node.num_keys > 0) node.keys[0] else null;
    }

    /// Get maximum key
    pub fn getMax(self: *const BTree) ?i64 {
        if (self.root == null) return null;

        var node = self.root.?;
        while (!node.is_leaf) {
            node = node.children[node.num_keys].?;
        }

        return if (node.num_keys > 0) node.keys[node.num_keys - 1] else null;
    }

    /// Get number of entries
    pub fn getSize(self: *const BTree) usize {
        return self.size;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "btree - insert and search" {
    const allocator = std.testing.allocator;

    var tree = try BTree.init(allocator);
    defer tree.deinit();

    // Insert some entries
    try tree.insert(1000, 0);
    try tree.insert(2000, 1);
    try tree.insert(1500, 2);
    try tree.insert(500, 3);

    // Search
    try std.testing.expectEqual(@as(?u64, 0), tree.search(1000));
    try std.testing.expectEqual(@as(?u64, 1), tree.search(2000));
    try std.testing.expectEqual(@as(?u64, 2), tree.search(1500));
    try std.testing.expectEqual(@as(?u64, 3), tree.search(500));
    try std.testing.expectEqual(@as(?u64, null), tree.search(9999));
}

test "btree - min and max" {
    const allocator = std.testing.allocator;

    var tree = try BTree.init(allocator);
    defer tree.deinit();

    try tree.insert(1000, 0);
    try tree.insert(2000, 1);
    try tree.insert(1500, 2);
    try tree.insert(500, 3);

    try std.testing.expectEqual(@as(?i64, 500), tree.getMin());
    try std.testing.expectEqual(@as(?i64, 2000), tree.getMax());
}

test "btree - range query" {
    const allocator = std.testing.allocator;

    var tree = try BTree.init(allocator);
    defer tree.deinit();

    // Insert timestamps
    try tree.insert(1000, 0);
    try tree.insert(2000, 1);
    try tree.insert(3000, 2);
    try tree.insert(4000, 3);
    try tree.insert(5000, 4);

    // Query range [2000, 4000]
    const results = try tree.rangeQuery(2000, 4000, allocator);
    defer allocator.free(results);

    try std.testing.expect(results.len >= 3); // Should find 2000, 3000, 4000
}

test "btree - large dataset" {
    const allocator = std.testing.allocator;

    var tree = try BTree.init(allocator);
    defer tree.deinit();

    // Insert 1000 entries
    var i: i64 = 0;
    while (i < 1000) : (i += 1) {
        try tree.insert(i * 100, @intCast(i));
    }

    try std.testing.expectEqual(@as(usize, 1000), tree.getSize());
    try std.testing.expectEqual(@as(?i64, 0), tree.getMin());
    try std.testing.expectEqual(@as(?i64, 99900), tree.getMax());

    // Search some values
    try std.testing.expectEqual(@as(?u64, 0), tree.search(0));
    try std.testing.expectEqual(@as(?u64, 500), tree.search(50000));
    try std.testing.expectEqual(@as(?u64, 999), tree.search(99900));
}

test "btree - splits preserve every key's value (regression: promoted-key value loss)" {
    const allocator = std.testing.allocator;

    var tree = try BTree.init(allocator);
    defer tree.deinit();

    // Insert well past MAX_KEYS (63) so multiple leaf/internal splits occur and
    // keys get promoted into internal nodes. Before the split fix, every
    // promoted separator lost its value (search returned a neighbouring row's
    // value and range queries silently dropped the promoted keys).
    const N: i64 = 500;
    var i: i64 = 0;
    while (i < N) : (i += 1) {
        try tree.insert(i * 100, @intCast(i)); // key = i*100, value = i
    }

    try std.testing.expectEqual(@as(usize, @intCast(N)), tree.getSize());

    // EXACT search for every single key must return its own row index — not a
    // predecessor's — for all keys including the ones promoted on split.
    i = 0;
    while (i < N) : (i += 1) {
        const got = tree.search(i * 100);
        try std.testing.expectEqual(@as(?u64, @intCast(i)), got);
    }

    // A range query must return the exact contiguous set with no gaps at the
    // promoted-key boundaries, in ascending key order.
    const results = try tree.rangeQuery(100 * 100, 400 * 100, allocator);
    defer allocator.free(results);

    try std.testing.expectEqual(@as(usize, 301), results.len); // keys 100..400 inclusive
    for (results, 0..) |entry, k| {
        const expected_i: i64 = 100 + @as(i64, @intCast(k));
        try std.testing.expectEqual(expected_i * 100, entry.key);
        try std.testing.expectEqual(@as(u64, @intCast(expected_i)), entry.value);
    }
}
