// Copyright (c) 2025 QUANTUM ENCODING LTD
// Licensed under the MIT License.

//! An allocator for `std.testing.checkAllAllocationFailures` runs that never
//! grows or shrinks a block in place, so every growth is a fresh allocation.
//!
//! The checker runs the code once to count its allocations, then once per
//! allocation with that one failing, and requires every run to make the same
//! allocations. Whether a backing allocator can resize a block in place
//! depends on what earlier runs left behind, so with in-place resizes the
//! count can differ from run to run for reasons that have nothing to do with
//! the code under test. Refusing them makes the count a property of the code.

const std = @import("std");

pub const NoInPlace = struct {
    child: std.mem.Allocator,

    pub fn allocator(self: *NoInPlace) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: std.mem.Allocator.VTable = .{
        .alloc = alloc,
        .resize = std.mem.Allocator.noResize,
        .remap = std.mem.Allocator.noRemap,
        .free = free,
    };

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *NoInPlace = @ptrCast(@alignCast(ctx));
        return self.child.rawAlloc(len, alignment, ret_addr);
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *NoInPlace = @ptrCast(@alignCast(ctx));
        self.child.rawFree(memory, alignment, ret_addr);
    }
};

test "growth goes through alloc, so the child sees every block" {
    var counting = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var no_in_place: NoInPlace = .{ .child = counting.allocator() };
    const a = no_in_place.allocator();
    var list: std.ArrayListUnmanaged(u64) = .empty;
    defer list.deinit(a);
    for (0..64) |i| try list.append(a, i);
    // Each capacity step is its own allocation; none is a resize.
    try std.testing.expect(counting.allocations > 1);
    try std.testing.expectEqual(@as(usize, 0), counting.resize_index);
}
