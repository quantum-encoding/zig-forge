//! zig_doom/src/zone.zig
//!
//! Zone memory allocator — Zig allocator interface.
//! Translated from: linuxdoom-1.10/z_zone.c, z_zone.h
//! Original: Copyright (C) 1993-1996 id Software, Inc. GPL-2.0
//!
//! DOOM's zone allocator manages a single memory pool with tagged allocations
//! and purge levels. For the Zig translation, we implement std.mem.Allocator
//! backed by the page allocator. This gives us:
//! - Standard allocator interface (works with ArrayList, etc.)
//! - Leak detection in tests via std.testing.allocator
//! - Drop-in replacement path to a real zone allocator later if needed

const std = @import("std");

/// Zone allocator wrapping Zig's page allocator.
/// In tests, use std.testing.allocator instead for leak detection.
pub const ZoneAllocator = struct {
    backing: std.mem.Allocator,
    total_allocated: usize = 0,

    pub fn init() ZoneAllocator {
        return .{ .backing = std.heap.page_allocator };
    }

    pub fn initWith(backing: std.mem.Allocator) ZoneAllocator {
        return .{ .backing = backing };
    }

    pub fn allocator(self: *ZoneAllocator) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &vtable,
        };
    }

    const vtable = std.mem.Allocator.VTable{
        .alloc = zoneAlloc,
        .resize = zoneResize,
        .remap = zoneRemap,
        .free = zoneFree,
    };

    fn zoneAlloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *ZoneAllocator = @ptrCast(@alignCast(ctx));
        const result = self.backing.rawAlloc(len, alignment, ret_addr);
        if (result != null) {
            self.total_allocated += len;
        }
        return result;
    }

    fn zoneResize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *ZoneAllocator = @ptrCast(@alignCast(ctx));
        const result = self.backing.rawResize(memory, alignment, new_len, ret_addr);
        if (result) {
            self.total_allocated = self.total_allocated - memory.len + new_len;
        }
        return result;
    }

    fn zoneRemap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *ZoneAllocator = @ptrCast(@alignCast(ctx));
        const result = self.backing.rawRemap(memory, alignment, new_len, ret_addr);
        if (result != null) {
            self.total_allocated = self.total_allocated - memory.len + new_len;
        }
        return result;
    }

    fn zoneFree(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *ZoneAllocator = @ptrCast(@alignCast(ctx));
        self.total_allocated -= memory.len;
        self.backing.rawFree(memory, alignment, ret_addr);
    }
};

test "zone allocator basic" {
    var zone = ZoneAllocator.initWith(std.testing.allocator);
    const alloc = zone.allocator();

    const data = try alloc.alloc(u8, 1024);
    try std.testing.expectEqual(@as(usize, 1024), zone.total_allocated);

    alloc.free(data);
    try std.testing.expectEqual(@as(usize, 0), zone.total_allocated);
}
