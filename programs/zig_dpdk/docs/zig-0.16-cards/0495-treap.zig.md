# Migration Card: std/treap.zig

## 1) Concept

This file implements a **Treap** data structure - a balanced binary search tree that combines BST properties with heap priorities. A Treap maintains the BST invariant (left child < parent < right child) while also maintaining a heap property on randomly assigned priorities. This provides expected O(log n) performance for insertions, deletions, and lookups.

Key components:
- **Treap type**: Generic container that takes a Key type and comparison function
- **Node structure**: Contains key, priority, parent, and children references
- **Entry system**: Provides a slot-based API for inserting/replacing/removing nodes
- **Iterator support**: In-order traversal of keys
- **Internal PRNG**: Custom pseudo-random generator for node priorities

## 2) The 0.11 vs 0.16 Diff

**No significant migration changes detected** - this data structure follows consistent patterns:

- **No allocator requirements**: The treap manages node relationships but doesn't allocate memory. Users provide pre-allocated nodes.
- **No I/O changes**: Pure data structure without I/O dependencies
- **Error handling**: Uses standard Zig error handling with assertions for invariants
- **API structure**: Consistent entry-based pattern for operations

The public API remains stable:
- Factory function `Treap(Key, compareFn)` returns the treap type
- Methods like `getEntryFor()`, `getMin()`, `getMax()` follow consistent patterns
- Entry-based modification via `entry.set(node)` pattern

## 3) The Golden Snippet

```zig
const std = @import("std");
const Treap = std.Treap;

// Define a treap for u64 keys using standard ordering
const MyTreap = Treap(u64, std.math.order);

// Create and use the treap
var treap = MyTreap{};
var node: MyTreap.Node = undefined;

// Insert a node with key 42
var entry = treap.getEntryFor(42);
entry.set(&node);

// Iterate through all nodes in order
var iter = treap.inorderIterator();
while (iter.next()) |current_node| {
    std.debug.print("Key: {}\n", .{current_node.key});
}

// Remove the node
entry.set(null);
```

## 4) Dependencies

- `std.math` - For `Order` enum and comparison functions
- `std.debug` - For `assert` statements
- `std.testing` - For test framework (test-only)

**Note**: This is a self-contained data structure with minimal dependencies, making it highly portable across Zig versions.