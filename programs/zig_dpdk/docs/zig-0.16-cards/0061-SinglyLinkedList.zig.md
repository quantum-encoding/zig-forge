# Migration Card: std.SinglyLinkedList

## 1) Concept

This file implements an intrusive singly-linked list data structure in Zig's standard library. The core concept is a minimal linked list where nodes contain only a `next` pointer, intended to be embedded intrusively within user data structures via `@fieldParentPtr`. The list provides O(1) insertion at head and O(n) removal for arbitrary elements, making it suitable for scenarios requiring pre-allocation, infallible insertion, or homogeneous elements.

Key components include the `SinglyLinkedList` struct managing the list head, and the `Node` struct containing the intrusive linkage. Operations include prepend, remove, popFirst, and various node-level operations like insertAfter, removeNext, and reverse. The design emphasizes minimal overhead through intrusive embedding rather than separate allocation.

## 2) The 0.11 vs 0.16 Diff

**No significant API signature changes detected between 0.11 and 0.16 patterns:**

- **No explicit allocator requirements**: This is an intrusive data structure - nodes are managed by the caller, no allocator injection needed
- **No I/O interface changes**: This is a pure data structure without I/O dependencies
- **No error handling changes**: Functions use simple return types (`void`, `?*Node`) without error sets
- **Consistent API structure**: Uses direct struct operations rather than factory patterns

The API remains stable with:
- Direct struct initialization: `var list: SinglyLinkedList = .{}`
- Pointer-based node management
- No initialization/opening patterns required

## 3) The Golden Snippet

```zig
const std = @import("std");
const SinglyLinkedList = std.SinglyLinkedList;

// User data structure with embedded node
const Item = struct {
    data: u32,
    node: SinglyLinkedList.Node = .{},
};

// Usage
var list: SinglyLinkedList = .{};
var item1: Item = .{ .data = 1 };
var item2: Item = .{ .data = 2 };

list.prepend(&item2.node);
list.prepend(&item1.node);

// Traverse and access data
var it = list.first;
while (it) |node| : (it = node.next) {
    const item: *Item = @fieldParentPtr("node", node);
    std.debug.print("Item data: {}\n", .{item.data});
}
```

## 4) Dependencies

- **std.debug** - Used for assertions and testing
- **std.testing** - Used exclusively in test blocks

The implementation has minimal dependencies, primarily relying on debug utilities for validation and testing infrastructure. No heavy imports like std.mem or std.net are required, making this a lightweight, self-contained data structure module.