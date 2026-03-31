const std = @import("std");

/// Simplified high-performance memory pool
pub fn SimplePool(comptime T: type) type {
    return struct {
        const Self = @This();
        
        memory: []u8,
        free_list: []bool,
        capacity: usize,
        used: usize,
        allocator: std.mem.Allocator,
        
        pub fn init(allocator: std.mem.Allocator, capacity: usize) !Self {
            const size = @max(@sizeOf(T), @sizeOf(usize));
            const alignment = @max(@alignOf(T), @alignOf(usize));
            
            const memory = try allocator.alignedAlloc(
                u8,
                @enumFromInt(std.math.log2_int(usize, alignment)),
                capacity * size
            );
            
            const free_list = try allocator.alloc(bool, capacity);
            @memset(free_list, false);
            
            return Self{
                .memory = memory,
                .free_list = free_list,
                .capacity = capacity,
                .used = 0,
                .allocator = allocator,
            };
        }
        
        pub fn deinit(self: *Self) void {
            self.allocator.free(self.free_list);
            self.allocator.free(self.memory);
        }
        
        pub fn create(self: *Self) !*T {
            if (self.used >= self.capacity) {
                return error.PoolExhausted;
            }
            
            // Find free slot
            for (self.free_list, 0..) |is_used, i| {
                if (!is_used) {
                    self.free_list[i] = true;
                    self.used += 1;
                    
                    const size = @max(@sizeOf(T), @sizeOf(usize));
                    const ptr = @as([*]u8, @ptrCast(&self.memory[i * size]));
                    return @as(*T, @ptrCast(@alignCast(ptr)));
                }
            }
            
            return error.PoolExhausted;
        }
        
        pub fn destroy(self: *Self, ptr: *T) void {
            const addr = @intFromPtr(ptr);
            const base = @intFromPtr(self.memory.ptr);
            const size = @max(@sizeOf(T), @sizeOf(usize));
            const index = (addr - base) / size;
            
            if (index < self.capacity) {
                self.free_list[index] = false;
                self.used -= 1;
            }
        }
        
        pub fn reset(self: *Self) void {
            @memset(self.free_list, false);
            self.used = 0;
        }
    };
}