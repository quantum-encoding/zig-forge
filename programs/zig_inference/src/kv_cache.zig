const std = @import("std");
const Allocator = std.mem.Allocator;

pub const KVCache = struct {
    allocator: Allocator,

    /// Flat buffer: [n_layers][max_seq_len][n_kv_heads * head_dim]
    key_cache: []f32,
    value_cache: []f32,

    n_layers: u32,
    max_seq_len: u32,
    n_kv_heads: u32,
    head_dim: u32,
    current_pos: u32,

    pub fn init(allocator: Allocator, n_layers: u32, max_seq_len: u32, n_kv_heads: u32, head_dim: u32) !KVCache {
        const kv_dim = n_kv_heads * head_dim;
        const total: usize = @as(usize, n_layers) * max_seq_len * kv_dim;

        const key_cache = try allocator.alloc(f32, total);
        @memset(key_cache, 0.0);
        const value_cache = try allocator.alloc(f32, total);
        @memset(value_cache, 0.0);

        return KVCache{
            .allocator = allocator,
            .key_cache = key_cache,
            .value_cache = value_cache,
            .n_layers = n_layers,
            .max_seq_len = max_seq_len,
            .n_kv_heads = n_kv_heads,
            .head_dim = head_dim,
            .current_pos = 0,
        };
    }

    pub fn deinit(self: *KVCache) void {
        self.allocator.free(self.key_cache);
        self.allocator.free(self.value_cache);
    }

    /// Store K and V vectors for a given layer at the current position
    pub fn store(self: *KVCache, layer: u32, k: []const f32, v: []const f32, pos: u32) void {
        const kv_dim = self.n_kv_heads * self.head_dim;
        const layer_offset: usize = @as(usize, layer) * self.max_seq_len * kv_dim;
        const pos_offset: usize = layer_offset + @as(usize, pos) * kv_dim;

        @memcpy(self.key_cache[pos_offset..][0..kv_dim], k[0..kv_dim]);
        @memcpy(self.value_cache[pos_offset..][0..kv_dim], v[0..kv_dim]);
    }

    /// Get pointer to K cache for layer, from position 0
    /// Returns slice of [max_seq_len * kv_dim] f32s for this layer
    pub fn getKeyPtr(self: *const KVCache, layer: u32) [*]const f32 {
        const kv_dim = self.n_kv_heads * self.head_dim;
        const layer_offset: usize = @as(usize, layer) * self.max_seq_len * kv_dim;
        return self.key_cache.ptr + layer_offset;
    }

    pub fn getValuePtr(self: *const KVCache, layer: u32) [*]const f32 {
        const kv_dim = self.n_kv_heads * self.head_dim;
        const layer_offset: usize = @as(usize, layer) * self.max_seq_len * kv_dim;
        return self.value_cache.ptr + layer_offset;
    }

    /// Get K vector at a specific position for a layer
    pub fn getKeyAt(self: *const KVCache, layer: u32, pos: u32) []const f32 {
        const kv_dim = self.n_kv_heads * self.head_dim;
        const offset: usize = @as(usize, layer) * self.max_seq_len * kv_dim + @as(usize, pos) * kv_dim;
        return self.key_cache[offset..][0..kv_dim];
    }

    pub fn getValueAt(self: *const KVCache, layer: u32, pos: u32) []const f32 {
        const kv_dim = self.n_kv_heads * self.head_dim;
        const offset: usize = @as(usize, layer) * self.max_seq_len * kv_dim + @as(usize, pos) * kv_dim;
        return self.value_cache[offset..][0..kv_dim];
    }

    pub fn reset(self: *KVCache) void {
        self.current_pos = 0;
    }
};
