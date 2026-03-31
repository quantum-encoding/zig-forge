# Migration Card: std.DoublyLinkedList

## 1) Concept

This file implements an intrusive doubly-linked list data structure in Zig's standard library. An intrusive list means that the list node structure is embedded directly within the data structure being linked, rather than having the list allocate wrapper nodes. The core components are the `DoublyLinkedList` struct (which holds optional first/last pointers) and the `Node` struct (which contains prev/next pointers that get embedded in user data structures).

The key characteristic is that operations like removal, insertion before/after elements, and end operations can be done in O(1) constant time without traversal. Users access their data through `@fieldParentPtr` to convert from a Node pointer back to their containing structure.

## 2) The 0.11 vs 0.16 Diff

**No significant API signature changes detected.** This doubly-linked list implementation follows consistent patterns across Zig versions:

- **No allocator requirements**: This is an intrusive data structure where the caller manages node allocation
- **No I/O interface changes**: The API operates purely on node pointers without I/O dependencies
- **No error handling changes**: All operations are infallible (return `void` or optional nodes)
- **Consistent API structure**: Functions like `append`, `prepend`, `remove`, `pop`, `insertBefore/After` maintain the same signatures

The primary migration consideration is that users must continue using the intrusive pattern with `@fieldParentPtr` to access their data from node pointers.

## 3) The Golden Snippet

```zig
const std = @import("std");
const DoublyLinkedList = std.DoublyLinkedList;

const Data = struct {
    value: u32,
    node: DoublyLinkedList.Node = .{},
};

var list: DoublyLinkedList = .{};

var item1 = Data{ .value = 10 };
var item2 = Data{ .value = 20 };
var item3 = Data{ .value = 30 };

// Append items to the list
list.append(&item1.node);
list.append(&item2.node);
list.prepend(&item3.node); // List becomes: 30, 10, 20

// Traverse and access data
var current = list.first;
while (current) |node| {
    const data: *Data = @fieldParentPtr("node", node);
    std.debug.print("Value: {}\n", .{data.value});
    current = node.next;
}

// Remove an item
list.remove(&item1.node);

// Pop from front
if (list.popFirst()) |node| {
    const data: *Data = @fieldParentPtr("node", node);
    std.debug.print("Popped: {}\n", .{data.value});
}
```

## 4) Dependencies

- `std` - Primary standard library import
- `std.debug` - Used for assertions
- `std.testing` - Used exclusively for test code

**Note**: This is a self-contained data structure with minimal dependencies, making it stable across Zig version changes.