//! Compression Formula Benchmark
//!
//! Actually executes compression algorithms against benchmark data and measures:
//! - Compression ratio (compressed_size / original_size)
//! - Throughput (MB/s)
//! - Lossless verification (decompress and compare)
//! - Per-formula timing
//!
//! Implements the "Core 8" algorithms for real compression testing.

const std = @import("std");
const posix = std.posix;
const Allocator = std.mem.Allocator;

// Darwin nanosleep for polling delays
const timespec = extern struct {
    sec: isize,
    nsec: isize,
};
extern "c" fn nanosleep(req: *const timespec, rem: ?*timespec) c_int;

fn sleepMs(ms: u64) void {
    const ts = timespec{
        .sec = @intCast(ms / 1000),
        .nsec = @intCast((ms % 1000) * 1_000_000),
    };
    _ = nanosleep(&ts, null);
}

// ============================================================================
// Compression Algorithms - Allocator-based (safe for chaining)
// ============================================================================

/// Run-Length Encoding
const RLE = struct {
    pub fn encode(allocator: Allocator, input: []const u8) ![]u8 {
        if (input.len == 0) return try allocator.alloc(u8, 0);

        // Worst case: no runs, every byte gets count prefix = 2x size
        var output = try std.ArrayListUnmanaged(u8).initCapacity(allocator, input.len * 2);
        errdefer output.deinit(allocator);

        var i: usize = 0;
        while (i < input.len) {
            const char = input[i];
            var count: u8 = 1;

            while (i + count < input.len and input[i + count] == char and count < 255) {
                count += 1;
            }

            try output.append(allocator, count);
            try output.append(allocator, char);
            i += count;
        }

        return output.toOwnedSlice(allocator);
    }

    pub fn decode(allocator: Allocator, input: []const u8) ![]u8 {
        if (input.len == 0) return try allocator.alloc(u8, 0);

        // Calculate output size first
        var out_size: usize = 0;
        var i: usize = 0;
        while (i + 1 < input.len) : (i += 2) {
            out_size += input[i];
        }

        var output = try allocator.alloc(u8, out_size);
        var out_idx: usize = 0;

        i = 0;
        while (i + 1 < input.len) : (i += 2) {
            const count = input[i];
            const char = input[i + 1];
            @memset(output[out_idx..][0..count], char);
            out_idx += count;
        }

        return output;
    }
};

/// Delta Encoding
const Delta = struct {
    pub fn encode(allocator: Allocator, input: []const u8) ![]u8 {
        if (input.len == 0) return try allocator.alloc(u8, 0);

        var output = try allocator.alloc(u8, input.len);
        output[0] = input[0];
        for (1..input.len) |i| {
            output[i] = input[i] -% input[i - 1];
        }
        return output;
    }

    pub fn decode(allocator: Allocator, input: []const u8) ![]u8 {
        if (input.len == 0) return try allocator.alloc(u8, 0);

        var output = try allocator.alloc(u8, input.len);
        output[0] = input[0];
        for (1..input.len) |i| {
            output[i] = output[i - 1] +% input[i];
        }
        return output;
    }
};

/// Move-to-Front Transform
const MTF = struct {
    pub fn encode(allocator: Allocator, input: []const u8) ![]u8 {
        if (input.len == 0) return try allocator.alloc(u8, 0);

        var output = try allocator.alloc(u8, input.len);
        var alphabet: [256]u8 = undefined;
        for (0..256) |i| alphabet[i] = @intCast(i);

        for (input, 0..) |char, i| {
            // Find position
            var pos: u8 = 0;
            for (alphabet, 0..) |a, j| {
                if (a == char) {
                    pos = @intCast(j);
                    break;
                }
            }
            output[i] = pos;

            // Move to front
            const c = alphabet[pos];
            var k: usize = pos;
            while (k > 0) : (k -= 1) alphabet[k] = alphabet[k - 1];
            alphabet[0] = c;
        }
        return output;
    }

    pub fn decode(allocator: Allocator, input: []const u8) ![]u8 {
        if (input.len == 0) return try allocator.alloc(u8, 0);

        var output = try allocator.alloc(u8, input.len);
        var alphabet: [256]u8 = undefined;
        for (0..256) |i| alphabet[i] = @intCast(i);

        for (input, 0..) |pos, i| {
            const char = alphabet[pos];
            output[i] = char;

            // Move to front
            var k: usize = pos;
            while (k > 0) : (k -= 1) alphabet[k] = alphabet[k - 1];
            alphabet[0] = char;
        }
        return output;
    }
};

/// Burrows-Wheeler Transform
const BWT = struct {
    const SENTINEL: u8 = 0; // End marker (assumes input doesn't contain 0)

    pub fn encode(allocator: Allocator, input: []const u8) ![]u8 {
        if (input.len == 0) return try allocator.alloc(u8, 0);

        const n = input.len + 1; // Include sentinel

        // Create input with sentinel
        var text = try allocator.alloc(u8, n);
        defer allocator.free(text);
        @memcpy(text[0..input.len], input);
        text[input.len] = SENTINEL;

        // Create rotation indices
        var indices = try allocator.alloc(usize, n);
        defer allocator.free(indices);
        for (0..n) |i| indices[i] = i;

        // Sort rotations lexicographically
        const SortCtx = struct {
            text: []const u8,
            n: usize,

            pub fn lessThan(ctx: @This(), a: usize, b: usize) bool {
                for (0..ctx.n) |i| {
                    const ca = ctx.text[(a + i) % ctx.n];
                    const cb = ctx.text[(b + i) % ctx.n];
                    if (ca != cb) return ca < cb;
                }
                return false;
            }
        };
        std.mem.sort(usize, indices, SortCtx{ .text = text, .n = n }, SortCtx.lessThan);

        // Output: last column of sorted rotations + position of original
        var output = try allocator.alloc(u8, n + 4); // +4 for storing original position
        var orig_pos: u32 = 0;

        for (indices, 0..) |idx, i| {
            output[i] = text[(idx + n - 1) % n]; // Last char of this rotation
            if (idx == 0) orig_pos = @intCast(i);
        }

        // Store original position at end (little-endian)
        output[n] = @truncate(orig_pos);
        output[n + 1] = @truncate(orig_pos >> 8);
        output[n + 2] = @truncate(orig_pos >> 16);
        output[n + 3] = @truncate(orig_pos >> 24);

        return output;
    }

    pub fn decode(allocator: Allocator, input: []const u8) ![]u8 {
        if (input.len < 5) return try allocator.alloc(u8, 0);

        const n = input.len - 4;
        const bwt = input[0..n];

        // Extract original position
        const orig_pos = @as(u32, input[n]) |
            (@as(u32, input[n + 1]) << 8) |
            (@as(u32, input[n + 2]) << 16) |
            (@as(u32, input[n + 3]) << 24);

        // Count occurrences of each character
        var counts: [256]usize = [_]usize{0} ** 256;
        for (bwt) |c| counts[c] += 1;

        // Cumulative counts (first occurrence of each char in sorted first column)
        var first: [256]usize = undefined;
        var sum: usize = 0;
        for (0..256) |i| {
            first[i] = sum;
            sum += counts[i];
        }

        // Build transformation vector
        var transform = try allocator.alloc(usize, n);
        defer allocator.free(transform);

        var occ: [256]usize = [_]usize{0} ** 256;
        for (bwt, 0..) |c, i| {
            transform[i] = first[c] + occ[c];
            occ[c] += 1;
        }

        // Reconstruct original (minus sentinel)
        var output = try allocator.alloc(u8, n - 1);
        var idx: usize = orig_pos;

        // Walk backwards through transform
        var out_idx: usize = n - 1;
        while (out_idx > 0) {
            out_idx -= 1;
            idx = transform[idx];
            if (bwt[idx] != SENTINEL) {
                output[out_idx] = bwt[idx];
            }
        }

        return output;
    }
};

/// Zero Run-Length Encoding (optimized for post-MTF data with many zeros)
const ZeroRLE = struct {
    pub fn encode(allocator: Allocator, input: []const u8) ![]u8 {
        if (input.len == 0) return try allocator.alloc(u8, 0);

        var output = try std.ArrayListUnmanaged(u8).initCapacity(allocator, input.len);
        errdefer output.deinit(allocator);

        var i: usize = 0;
        while (i < input.len) {
            if (input[i] == 0) {
                // Count zeros
                var count: usize = 0;
                while (i + count < input.len and input[i + count] == 0 and count < 255) {
                    count += 1;
                }
                try output.append(allocator, 0); // Zero marker
                try output.append(allocator, @intCast(count)); // Count
                i += count;
            } else {
                try output.append(allocator, input[i]);
                i += 1;
            }
        }

        return output.toOwnedSlice(allocator);
    }

    pub fn decode(allocator: Allocator, input: []const u8) ![]u8 {
        if (input.len == 0) return try allocator.alloc(u8, 0);

        var output = try std.ArrayListUnmanaged(u8).initCapacity(allocator, input.len);
        errdefer output.deinit(allocator);

        var i: usize = 0;
        while (i < input.len) {
            if (input[i] == 0 and i + 1 < input.len) {
                const count = input[i + 1];
                try output.appendNTimes(allocator, 0, count);
                i += 2;
            } else {
                try output.append(allocator, input[i]);
                i += 1;
            }
        }

        return output.toOwnedSlice(allocator);
    }
};

/// LZ77 - Sliding Window Dictionary Compression
const LZ77 = struct {
    const WINDOW_SIZE: usize = 4096;
    const MIN_MATCH: usize = 3;
    const MAX_MATCH: usize = 258;

    pub fn encode(allocator: Allocator, input: []const u8) ![]u8 {
        if (input.len == 0) return try allocator.alloc(u8, 0);

        var output = try std.ArrayListUnmanaged(u8).initCapacity(allocator, input.len);
        errdefer output.deinit(allocator);

        var pos: usize = 0;
        while (pos < input.len) {
            var best_offset: u16 = 0;
            var best_length: u8 = 0;

            // Search for match in window
            const window_start = if (pos > WINDOW_SIZE) pos - WINDOW_SIZE else 0;

            var search_pos = window_start;
            while (search_pos < pos) : (search_pos += 1) {
                var length: usize = 0;
                while (pos + length < input.len and
                    length < MAX_MATCH and
                    input[search_pos + length] == input[pos + length])
                {
                    length += 1;
                }

                if (length >= MIN_MATCH and length > best_length) {
                    best_offset = @intCast(pos - search_pos);
                    best_length = @intCast(length);
                }
            }

            if (best_length >= MIN_MATCH) {
                // Emit back-reference: [0xFF][offset_hi][offset_lo][length]
                try output.append(allocator, 0xFF); // Escape byte
                try output.append(allocator, @truncate(best_offset >> 8));
                try output.append(allocator, @truncate(best_offset));
                try output.append(allocator, best_length);
                pos += best_length;
            } else {
                // Emit literal
                if (input[pos] == 0xFF) {
                    try output.append(allocator, 0xFF);
                    try output.append(allocator, 0); // Zero offset = literal 0xFF
                    try output.append(allocator, 0);
                    try output.append(allocator, 1);
                } else {
                    try output.append(allocator, input[pos]);
                }
                pos += 1;
            }
        }

        return output.toOwnedSlice(allocator);
    }

    pub fn decode(allocator: Allocator, input: []const u8) ![]u8 {
        if (input.len == 0) return try allocator.alloc(u8, 0);

        var output = try std.ArrayListUnmanaged(u8).initCapacity(allocator, input.len * 2);
        errdefer output.deinit(allocator);

        var i: usize = 0;
        while (i < input.len) {
            if (input[i] == 0xFF and i + 3 < input.len) {
                const offset = (@as(u16, input[i + 1]) << 8) | input[i + 2];
                const length = input[i + 3];

                if (offset == 0) {
                    // Escaped literal 0xFF
                    try output.appendNTimes(allocator, 0xFF, length);
                } else {
                    // Back-reference
                    const start = output.items.len - offset;
                    for (0..length) |j| {
                        try output.append(allocator, output.items[start + j]);
                    }
                }
                i += 4;
            } else {
                try output.append(allocator, input[i]);
                i += 1;
            }
        }

        return output.toOwnedSlice(allocator);
    }
};

/// Canonical Huffman Coding with real bit-packing
const Huffman = struct {
    const MAX_SYMBOLS = 256;
    const MAX_CODE_LEN = 15;

    const HuffNode = struct {
        freq: u32,
        symbol: u16, // 256+ means internal node
        left: u16,
        right: u16,
    };

    pub fn encode(allocator: Allocator, input: []const u8) ![]u8 {
        if (input.len == 0) return try allocator.alloc(u8, 0);

        // Count frequencies
        var freq: [MAX_SYMBOLS]u32 = [_]u32{0} ** MAX_SYMBOLS;
        for (input) |c| freq[c] += 1;

        // Count unique symbols
        var n_symbols: u16 = 0;
        for (0..MAX_SYMBOLS) |i| {
            if (freq[i] > 0) n_symbols += 1;
        }

        // Handle edge case: only one unique symbol
        if (n_symbols <= 1) {
            var output = try std.ArrayListUnmanaged(u8).initCapacity(allocator, 266);
            errdefer output.deinit(allocator);

            // Header: code lengths (all zeros except one symbol = 1 bit)
            for (0..256) |i| {
                try output.append(allocator, if (freq[i] > 0) 1 else 0);
            }

            // Original length
            try output.append(allocator, @truncate(input.len));
            try output.append(allocator, @truncate(input.len >> 8));
            try output.append(allocator, @truncate(input.len >> 16));
            try output.append(allocator, @truncate(input.len >> 24));

            // Bit count (all zeros for single symbol - just needs length info)
            const bit_count = input.len;
            try output.append(allocator, @truncate(bit_count));
            try output.append(allocator, @truncate(bit_count >> 8));
            try output.append(allocator, @truncate(bit_count >> 16));
            try output.append(allocator, @truncate(bit_count >> 24));

            // Packed bits (all 0s for single symbol case)
            const byte_count = (bit_count + 7) / 8;
            try output.appendNTimes(allocator, 0, byte_count);

            return output.toOwnedSlice(allocator);
        }

        // Build Huffman tree using min-heap simulation
        var nodes: [MAX_SYMBOLS * 2]HuffNode = undefined;
        var node_count: u16 = 0;

        // Create leaf nodes for symbols with non-zero frequency
        for (0..MAX_SYMBOLS) |i| {
            if (freq[i] > 0) {
                nodes[node_count] = .{
                    .freq = freq[i],
                    .symbol = @intCast(i),
                    .left = 0xFFFF,
                    .right = 0xFFFF,
                };
                node_count += 1;
            }
        }

        // Build tree by combining lowest-frequency nodes
        var active = try allocator.alloc(u16, node_count);
        defer allocator.free(active);
        for (0..node_count) |i| active[i] = @intCast(i);
        var active_count: usize = node_count;

        while (active_count > 1) {
            // Find two lowest frequency nodes
            var min1_idx: usize = 0;
            var min2_idx: usize = 1;

            if (nodes[active[min1_idx]].freq > nodes[active[min2_idx]].freq) {
                const tmp = min1_idx;
                min1_idx = min2_idx;
                min2_idx = tmp;
            }

            for (2..active_count) |i| {
                if (nodes[active[i]].freq < nodes[active[min1_idx]].freq) {
                    min2_idx = min1_idx;
                    min1_idx = i;
                } else if (nodes[active[i]].freq < nodes[active[min2_idx]].freq) {
                    min2_idx = i;
                }
            }

            // Create internal node
            const left_node = active[min1_idx];
            const right_node = active[min2_idx];
            nodes[node_count] = .{
                .freq = nodes[left_node].freq + nodes[right_node].freq,
                .symbol = 0xFFFF, // Internal node marker
                .left = left_node,
                .right = right_node,
            };

            // Replace min1 with new node, remove min2
            active[min1_idx] = node_count;
            active[min2_idx] = active[active_count - 1];
            active_count -= 1;
            node_count += 1;
        }

        const root = active[0];

        // Calculate code lengths via tree traversal
        var code_len: [MAX_SYMBOLS]u8 = [_]u8{0} ** MAX_SYMBOLS;
        var stack: [MAX_CODE_LEN * 2]struct { node: u16, depth: u8 } = undefined;
        var stack_top: usize = 1;
        stack[0] = .{ .node = root, .depth = 0 };

        while (stack_top > 0) {
            stack_top -= 1;
            const item = stack[stack_top];
            const node = nodes[item.node];

            if (node.symbol < 256) {
                // Leaf node
                code_len[node.symbol] = if (item.depth == 0) 1 else item.depth;
            } else {
                // Internal node
                if (node.left != 0xFFFF and item.depth < MAX_CODE_LEN) {
                    stack[stack_top] = .{ .node = node.left, .depth = item.depth + 1 };
                    stack_top += 1;
                }
                if (node.right != 0xFFFF and item.depth < MAX_CODE_LEN) {
                    stack[stack_top] = .{ .node = node.right, .depth = item.depth + 1 };
                    stack_top += 1;
                }
            }
        }

        // Build canonical codes from lengths
        // Count code lengths
        var bl_count: [MAX_CODE_LEN + 1]u16 = [_]u16{0} ** (MAX_CODE_LEN + 1);
        for (0..MAX_SYMBOLS) |i| {
            if (code_len[i] > 0) {
                bl_count[code_len[i]] += 1;
            }
        }

        // Calculate starting codes for each length
        var next_code: [MAX_CODE_LEN + 1]u16 = [_]u16{0} ** (MAX_CODE_LEN + 1);
        var code: u16 = 0;
        for (1..MAX_CODE_LEN + 1) |bits| {
            code = (code + bl_count[bits - 1]) << 1;
            next_code[bits] = code;
        }

        // Assign codes
        var codes: [MAX_SYMBOLS]u16 = [_]u16{0} ** MAX_SYMBOLS;
        for (0..MAX_SYMBOLS) |i| {
            const len = code_len[i];
            if (len > 0) {
                codes[i] = next_code[len];
                next_code[len] += 1;
            }
        }

        // Encode data with bit-packing
        var output = try std.ArrayListUnmanaged(u8).initCapacity(allocator, input.len + 268);
        errdefer output.deinit(allocator);

        // Header: 256 bytes of code lengths
        for (0..256) |i| {
            try output.append(allocator, code_len[i]);
        }

        // Original length (4 bytes)
        try output.append(allocator, @truncate(input.len));
        try output.append(allocator, @truncate(input.len >> 8));
        try output.append(allocator, @truncate(input.len >> 16));
        try output.append(allocator, @truncate(input.len >> 24));

        // Calculate total bits
        var total_bits: usize = 0;
        for (input) |c| {
            total_bits += code_len[c];
        }

        // Bit count (4 bytes)
        try output.append(allocator, @truncate(total_bits));
        try output.append(allocator, @truncate(total_bits >> 8));
        try output.append(allocator, @truncate(total_bits >> 16));
        try output.append(allocator, @truncate(total_bits >> 24));

        // Pack bits into bytes using 64-bit buffer for safety
        var bit_buffer: u64 = 0;
        var bits_in_buffer: u8 = 0;

        for (input) |c| {
            const sym_code = codes[c];
            const sym_len: u8 = code_len[c];

            // Add code bits to buffer (MSB first)
            const shift_amt: u6 = @intCast(64 - bits_in_buffer - sym_len);
            bit_buffer |= @as(u64, sym_code) << shift_amt;
            bits_in_buffer += sym_len;

            // Flush complete bytes
            while (bits_in_buffer >= 8) {
                try output.append(allocator, @truncate(bit_buffer >> 56));
                bit_buffer <<= 8;
                bits_in_buffer -= 8;
            }
        }

        // Flush remaining bits
        if (bits_in_buffer > 0) {
            try output.append(allocator, @truncate(bit_buffer >> 56));
        }

        return output.toOwnedSlice(allocator);
    }

    pub fn decode(allocator: Allocator, input: []const u8) ![]u8 {
        if (input.len < 264) return try allocator.alloc(u8, 0);

        // Read code lengths
        var code_len: [MAX_SYMBOLS]u8 = undefined;
        @memcpy(&code_len, input[0..256]);

        // Read original length
        const orig_len = @as(usize, input[256]) |
            (@as(usize, input[257]) << 8) |
            (@as(usize, input[258]) << 16) |
            (@as(usize, input[259]) << 24);

        // Read bit count
        const bit_count = @as(usize, input[260]) |
            (@as(usize, input[261]) << 8) |
            (@as(usize, input[262]) << 16) |
            (@as(usize, input[263]) << 24);

        if (orig_len == 0) return try allocator.alloc(u8, 0);

        // Build canonical codes (same as encoder)
        var bl_count: [MAX_CODE_LEN + 1]u16 = [_]u16{0} ** (MAX_CODE_LEN + 1);
        for (0..MAX_SYMBOLS) |i| {
            if (code_len[i] > 0) {
                bl_count[code_len[i]] += 1;
            }
        }

        var next_code: [MAX_CODE_LEN + 1]u16 = [_]u16{0} ** (MAX_CODE_LEN + 1);
        var code: u16 = 0;
        for (1..MAX_CODE_LEN + 1) |bits| {
            code = (code + bl_count[bits - 1]) << 1;
            next_code[bits] = code;
        }

        var codes: [MAX_SYMBOLS]u16 = [_]u16{0} ** MAX_SYMBOLS;
        for (0..MAX_SYMBOLS) |i| {
            const len = code_len[i];
            if (len > 0) {
                codes[i] = next_code[len];
                next_code[len] += 1;
            }
        }

        // Build decode table: for each (length, code) -> symbol
        // Using simple linear search for correctness (could optimize with tables)
        var output = try allocator.alloc(u8, orig_len);
        errdefer allocator.free(output);

        const bit_data = input[264..];
        var bit_pos: usize = 0;
        var out_idx: usize = 0;

        while (out_idx < orig_len and bit_pos < bit_count) {
            // Read bits and find matching symbol
            var current_code: u16 = 0;

            for (1..MAX_CODE_LEN + 1) |len| {
                if (bit_pos >= bit_count) break;

                // Read next bit
                const byte_idx = bit_pos / 8;
                const bit_idx: u3 = @intCast(7 - (bit_pos % 8));

                if (byte_idx >= bit_data.len) break;

                const bit: u16 = @as(u16, (bit_data[byte_idx] >> bit_idx) & 1);
                current_code = (current_code << 1) | bit;
                bit_pos += 1;

                // Check if this code matches any symbol with this length
                for (0..MAX_SYMBOLS) |sym| {
                    if (code_len[sym] == len and codes[sym] == current_code) {
                        output[out_idx] = @intCast(sym);
                        out_idx += 1;
                        break;
                    }
                }

                // If we found a symbol, break out of length loop
                if (out_idx > 0 and out_idx == orig_len) break;

                // Check if we just decoded a symbol
                var found = false;
                for (0..MAX_SYMBOLS) |sym| {
                    if (code_len[sym] == len and codes[sym] == current_code) {
                        found = true;
                        break;
                    }
                }
                if (found) break;
            }
        }

        return output;
    }
};

/// Arithmetic Coding - Near-optimal entropy coding
/// Uses 32-bit fixed-point arithmetic with rescaling
const Arithmetic = struct {
    const PRECISION: u32 = 16; // Bits of precision
    const WHOLE: u32 = 1 << PRECISION;
    const HALF: u32 = WHOLE / 2;
    const QUARTER: u32 = WHOLE / 4;

    pub fn encode(allocator: Allocator, input: []const u8) ![]u8 {
        if (input.len == 0) return try allocator.alloc(u8, 0);

        // Count frequencies
        var freq: [256]u32 = [_]u32{0} ** 256;
        for (input) |c| freq[c] += 1;

        // Build cumulative frequency table
        var cum_freq: [257]u32 = undefined;
        cum_freq[0] = 0;
        for (0..256) |i| {
            cum_freq[i + 1] = cum_freq[i] + freq[i];
        }
        const total = cum_freq[256];

        // Output buffer
        var output = try std.ArrayListUnmanaged(u8).initCapacity(allocator, input.len + 1024);
        errdefer output.deinit(allocator);

        // Header: original length (4 bytes)
        try output.append(allocator, @truncate(input.len));
        try output.append(allocator, @truncate(input.len >> 8));
        try output.append(allocator, @truncate(input.len >> 16));
        try output.append(allocator, @truncate(input.len >> 24));

        // Header: frequency table (256 * 4 bytes for simplicity)
        for (0..256) |i| {
            try output.append(allocator, @truncate(freq[i]));
            try output.append(allocator, @truncate(freq[i] >> 8));
            try output.append(allocator, @truncate(freq[i] >> 16));
            try output.append(allocator, @truncate(freq[i] >> 24));
        }

        // Arithmetic encoding
        var low: u32 = 0;
        var high: u32 = WHOLE - 1;
        var pending_bits: u32 = 0;

        var bit_buffer: u8 = 0;
        var bits_in_buffer: u4 = 0;

        const writeBit = struct {
            fn write(
                bit: u1,
                buffer: *u8,
                count: *u4,
                out: *std.ArrayListUnmanaged(u8),
                alloc: Allocator,
            ) !void {
                buffer.* = (buffer.* << 1) | bit;
                count.* += 1;
                if (count.* == 8) {
                    try out.append(alloc, buffer.*);
                    buffer.* = 0;
                    count.* = 0;
                }
            }
        }.write;

        for (input) |sym| {
            const range = high - low + 1;

            // Update range based on symbol probability
            high = low + @as(u32, @truncate((@as(u64, range) * cum_freq[sym + 1]) / total)) - 1;
            low = low + @as(u32, @truncate((@as(u64, range) * cum_freq[sym]) / total));

            // Normalize
            while (true) {
                if (high < HALF) {
                    // Output 0 followed by pending 1s
                    try writeBit(0, &bit_buffer, &bits_in_buffer, &output, allocator);
                    while (pending_bits > 0) : (pending_bits -= 1) {
                        try writeBit(1, &bit_buffer, &bits_in_buffer, &output, allocator);
                    }
                } else if (low >= HALF) {
                    // Output 1 followed by pending 0s
                    try writeBit(1, &bit_buffer, &bits_in_buffer, &output, allocator);
                    while (pending_bits > 0) : (pending_bits -= 1) {
                        try writeBit(0, &bit_buffer, &bits_in_buffer, &output, allocator);
                    }
                    low -= HALF;
                    high -= HALF;
                } else if (low >= QUARTER and high < 3 * QUARTER) {
                    // Pending bit
                    pending_bits += 1;
                    low -= QUARTER;
                    high -= QUARTER;
                } else {
                    break;
                }

                low = low * 2;
                high = high * 2 + 1;
            }
        }

        // Flush remaining bits
        pending_bits += 1;
        if (low < QUARTER) {
            try writeBit(0, &bit_buffer, &bits_in_buffer, &output, allocator);
            while (pending_bits > 0) : (pending_bits -= 1) {
                try writeBit(1, &bit_buffer, &bits_in_buffer, &output, allocator);
            }
        } else {
            try writeBit(1, &bit_buffer, &bits_in_buffer, &output, allocator);
            while (pending_bits > 0) : (pending_bits -= 1) {
                try writeBit(0, &bit_buffer, &bits_in_buffer, &output, allocator);
            }
        }

        // Flush final partial byte
        if (bits_in_buffer > 0) {
            bit_buffer <<= @intCast(8 - bits_in_buffer);
            try output.append(allocator, bit_buffer);
        }

        return output.toOwnedSlice(allocator);
    }

    pub fn decode(allocator: Allocator, input: []const u8) ![]u8 {
        if (input.len < 1028) return try allocator.alloc(u8, 0);

        // Read original length
        const orig_len = @as(usize, input[0]) |
            (@as(usize, input[1]) << 8) |
            (@as(usize, input[2]) << 16) |
            (@as(usize, input[3]) << 24);

        if (orig_len == 0) return try allocator.alloc(u8, 0);

        // Read frequency table
        var freq: [256]u32 = undefined;
        for (0..256) |i| {
            const offset = 4 + i * 4;
            freq[i] = @as(u32, input[offset]) |
                (@as(u32, input[offset + 1]) << 8) |
                (@as(u32, input[offset + 2]) << 16) |
                (@as(u32, input[offset + 3]) << 24);
        }

        // Build cumulative frequency table
        var cum_freq: [257]u32 = undefined;
        cum_freq[0] = 0;
        for (0..256) |i| {
            cum_freq[i + 1] = cum_freq[i] + freq[i];
        }
        const total = cum_freq[256];

        if (total == 0) return try allocator.alloc(u8, 0);

        const bit_data = input[1028..];
        var bit_pos: usize = 0;

        const readBit = struct {
            fn read(data: []const u8, pos: *usize) u1 {
                if (pos.* / 8 >= data.len) return 0;
                const byte_idx = pos.* / 8;
                const bit_idx: u3 = @intCast(7 - (pos.* % 8));
                pos.* += 1;
                return @truncate((data[byte_idx] >> bit_idx) & 1);
            }
        }.read;

        // Initialize decoder
        var low: u32 = 0;
        var high: u32 = WHOLE - 1;
        var value: u32 = 0;

        // Read initial bits
        for (0..PRECISION) |_| {
            value = (value << 1) | readBit(bit_data, &bit_pos);
        }

        var output = try allocator.alloc(u8, orig_len);
        errdefer allocator.free(output);

        for (0..orig_len) |out_idx| {
            const range = high - low + 1;

            // Find symbol
            const scaled = @as(u32, @truncate(((@as(u64, value - low) + 1) * total - 1) / range));

            var sym: usize = 0;
            while (sym < 256 and cum_freq[sym + 1] <= scaled) : (sym += 1) {}

            output[out_idx] = @intCast(sym);

            // Update range
            high = low + @as(u32, @truncate((@as(u64, range) * cum_freq[sym + 1]) / total)) - 1;
            low = low + @as(u32, @truncate((@as(u64, range) * cum_freq[sym]) / total));

            // Normalize
            while (true) {
                if (high < HALF) {
                    // Nothing to do
                } else if (low >= HALF) {
                    low -= HALF;
                    high -= HALF;
                    value -= HALF;
                } else if (low >= QUARTER and high < 3 * QUARTER) {
                    low -= QUARTER;
                    high -= QUARTER;
                    value -= QUARTER;
                } else {
                    break;
                }

                low = low * 2;
                high = high * 2 + 1;
                value = (value << 1) | readBit(bit_data, &bit_pos);
            }
        }

        return output;
    }
};

// ============================================================================
// Pipeline Execution
// ============================================================================

const CompressionStep = enum {
    rle,
    delta,
    mtf,
    bwt,
    zero_rle,
    lz77,
    huffman,
    arithmetic,
};

const CompressionResult = struct {
    compressed_data: []u8,
    original_size: usize,
    compressed_size: usize,
    ratio: f64,
    is_lossless: bool,
    encode_time_ns: i128,
    decode_time_ns: i128,
    throughput_mbps: f64,
};

/// Parse a formula string
fn parseFormula(formula: []const u8, steps: *[16]CompressionStep) !usize {
    var count: usize = 0;
    var iter = std.mem.splitScalar(u8, formula, '+');

    while (iter.next()) |step_name| {
        const trimmed = std.mem.trim(u8, step_name, &std.ascii.whitespace);

        if (std.ascii.eqlIgnoreCase(trimmed, "RLE")) {
            steps[count] = .rle;
        } else if (std.ascii.eqlIgnoreCase(trimmed, "DELTA")) {
            steps[count] = .delta;
        } else if (std.ascii.eqlIgnoreCase(trimmed, "MTF")) {
            steps[count] = .mtf;
        } else if (std.ascii.eqlIgnoreCase(trimmed, "BWT")) {
            steps[count] = .bwt;
        } else if (std.ascii.eqlIgnoreCase(trimmed, "ZERORLE") or std.ascii.eqlIgnoreCase(trimmed, "ZRLE")) {
            steps[count] = .zero_rle;
        } else if (std.ascii.eqlIgnoreCase(trimmed, "LZ77") or std.ascii.eqlIgnoreCase(trimmed, "LZ")) {
            steps[count] = .lz77;
        } else if (std.ascii.eqlIgnoreCase(trimmed, "HUFFMAN") or std.ascii.eqlIgnoreCase(trimmed, "HUF")) {
            steps[count] = .huffman;
        } else if (std.ascii.eqlIgnoreCase(trimmed, "ARITH") or std.ascii.eqlIgnoreCase(trimmed, "ARITHMETIC") or std.ascii.eqlIgnoreCase(trimmed, "AC")) {
            steps[count] = .arithmetic;
        } else {
            return error.UnknownStep;
        }

        count += 1;
        if (count >= 16) break;
    }

    return count;
}

/// Execute a compression pipeline with proper memory management
fn executeCompression(
    allocator: Allocator,
    input: []const u8,
    steps: []const CompressionStep,
) !CompressionResult {
    var start_ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(.MONOTONIC, &start_ts) != 0) return error.TimerFailed;
    const start_time = start_ts;

    // Apply each compression step
    var current: []u8 = try allocator.dupe(u8, input);
    var prev: ?[]u8 = null;

    for (steps) |step| {
        const next = switch (step) {
            .rle => try RLE.encode(allocator, current),
            .delta => try Delta.encode(allocator, current),
            .mtf => try MTF.encode(allocator, current),
            .bwt => try BWT.encode(allocator, current),
            .zero_rle => try ZeroRLE.encode(allocator, current),
            .lz77 => try LZ77.encode(allocator, current),
            .huffman => try Huffman.encode(allocator, current),
            .arithmetic => try Arithmetic.encode(allocator, current),
        };

        // Free previous intermediate buffer
        if (prev) |p| allocator.free(p);
        prev = current;
        current = next;
    }

    // Free last intermediate
    if (prev) |p| allocator.free(p);

    var encode_end_ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(.MONOTONIC, &encode_end_ts) != 0) return error.TimerFailed;
    const encode_end = encode_end_ts;

    const compressed_size = current.len;

    // Verify lossless by decompressing
    var decompressed: []u8 = try allocator.dupe(u8, current);
    prev = null;

    // Apply decompression in reverse order
    var i: usize = steps.len;
    while (i > 0) {
        i -= 1;
        const next = switch (steps[i]) {
            .rle => try RLE.decode(allocator, decompressed),
            .delta => try Delta.decode(allocator, decompressed),
            .mtf => try MTF.decode(allocator, decompressed),
            .bwt => try BWT.decode(allocator, decompressed),
            .zero_rle => try ZeroRLE.decode(allocator, decompressed),
            .lz77 => try LZ77.decode(allocator, decompressed),
            .huffman => try Huffman.decode(allocator, decompressed),
            .arithmetic => try Arithmetic.decode(allocator, decompressed),
        };

        if (prev) |p| allocator.free(p);
        prev = decompressed;
        decompressed = next;
    }

    if (prev) |p| allocator.free(p);

    var decode_end_ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(.MONOTONIC, &decode_end_ts) != 0) return error.TimerFailed;
    const decode_end = decode_end_ts;

    // Verify lossless
    const is_lossless = decompressed.len == input.len and std.mem.eql(u8, input, decompressed);

    allocator.free(decompressed);

    // Calculate timing
    const encode_ns = (@as(i128, encode_end.sec) - @as(i128, start_time.sec)) * 1_000_000_000 +
        (@as(i128, encode_end.nsec) - @as(i128, start_time.nsec));
    const decode_ns = (@as(i128, decode_end.sec) - @as(i128, encode_end.sec)) * 1_000_000_000 +
        (@as(i128, decode_end.nsec) - @as(i128, encode_end.nsec));

    const total_ns = encode_ns + decode_ns;
    const throughput = if (total_ns > 0)
        @as(f64, @floatFromInt(input.len)) / @as(f64, @floatFromInt(total_ns)) * 1000.0
    else
        0.0;

    return CompressionResult{
        .compressed_data = current,
        .original_size = input.len,
        .compressed_size = compressed_size,
        .ratio = @as(f64, @floatFromInt(compressed_size)) / @as(f64, @floatFromInt(input.len)),
        .is_lossless = is_lossless,
        .encode_time_ns = encode_ns,
        .decode_time_ns = decode_ns,
        .throughput_mbps = throughput,
    };
}

// ============================================================================
// Result Tracking
// ============================================================================

const FormulaResult = struct {
    formula: []const u8,
    ratio: f64,
    is_lossless: bool,
    throughput_mbps: f64,
    original_size: usize,
    compressed_size: usize,
    encode_time_ns: i128,

    fn lessThan(_: void, a: FormulaResult, b: FormulaResult) bool {
        if (a.is_lossless and !b.is_lossless) return true;
        if (!a.is_lossless and b.is_lossless) return false;
        return a.ratio < b.ratio;
    }
};

// ============================================================================
// Parallel Worker
// ============================================================================

const WorkItem = struct {
    formula: []const u8,
    steps: [16]CompressionStep,
    step_count: usize,
    index: usize,
};

const WorkResult = struct {
    formula: []const u8,
    ratio: f64,
    is_lossless: bool,
    throughput_mbps: f64,
    original_size: usize,
    compressed_size: usize,
    encode_time_ns: i128,
    success: bool,
    index: usize,
};

fn workerThread(
    work_items: []const WorkItem,
    input_data: []const u8,
    results: []WorkResult,
    completed: *std.atomic.Value(usize),
) void {
    // Each thread gets its own allocator
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const thread_alloc = arena.allocator();

    for (work_items) |item| {
        const result = executeCompression(thread_alloc, input_data, item.steps[0..item.step_count]) catch {
            results[item.index] = .{
                .formula = item.formula,
                .ratio = 999.0,
                .is_lossless = false,
                .throughput_mbps = 0,
                .original_size = input_data.len,
                .compressed_size = 0,
                .encode_time_ns = 0,
                .success = false,
                .index = item.index,
            };
            _ = completed.fetchAdd(1, .monotonic);
            continue;
        };

        // Free compressed data immediately - we only need metrics
        thread_alloc.free(result.compressed_data);

        results[item.index] = .{
            .formula = item.formula,
            .ratio = result.ratio,
            .is_lossless = result.is_lossless,
            .throughput_mbps = result.throughput_mbps,
            .original_size = result.original_size,
            .compressed_size = result.compressed_size,
            .encode_time_ns = result.encode_time_ns,
            .success = true,
            .index = item.index,
        };
        _ = completed.fetchAdd(1, .monotonic);

        // Reset arena periodically to avoid memory bloat
        if (item.index % 100 == 0) {
            _ = arena.reset(.retain_capacity);
        }
    }
}

// ============================================================================
// Main
// ============================================================================

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    // Parse arguments
    var formulas_path: ?[]const u8 = null;
    var input_path: ?[]const u8 = null;
    var output_dir: []const u8 = "./bench_results";
    var top_n: usize = 20;
    var n_threads: usize = 0; // 0 = auto-detect

    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next();

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--formulas")) {
            if (args.next()) |v| formulas_path = v;
        } else if (std.mem.eql(u8, arg, "--input")) {
            if (args.next()) |v| input_path = v;
        } else if (std.mem.eql(u8, arg, "--output")) {
            if (args.next()) |v| output_dir = v;
        } else if (std.mem.eql(u8, arg, "--top")) {
            if (args.next()) |v| top_n = try std.fmt.parseInt(usize, v, 10);
        } else if (std.mem.eql(u8, arg, "--threads") or std.mem.eql(u8, arg, "-j")) {
            if (args.next()) |v| n_threads = try std.fmt.parseInt(usize, v, 10);
        }
    }

    if (formulas_path == null or input_path == null) {
        std.debug.print("Usage: compression-bench --formulas <file> --input <data_file> [--output <dir>] [--top N] [--threads N]\n\n", .{});
        std.debug.print("Supported algorithms:\n", .{});
        std.debug.print("  RLE       - Run-Length Encoding\n", .{});
        std.debug.print("  DELTA     - Delta Encoding\n", .{});
        std.debug.print("  MTF       - Move-to-Front Transform\n", .{});
        std.debug.print("  BWT       - Burrows-Wheeler Transform\n", .{});
        std.debug.print("  ZERORLE   - Zero Run-Length (post-MTF)\n", .{});
        std.debug.print("  LZ77      - Dictionary Compression\n", .{});
        std.debug.print("  HUFFMAN   - Canonical Huffman Coding\n", .{});
        std.debug.print("  ARITH     - Arithmetic Coding (near-optimal entropy)\n", .{});
        std.debug.print("\nOptions:\n", .{});
        std.debug.print("  --threads N  Number of parallel threads (default: auto-detect)\n", .{});
        std.debug.print("\nExample formulas:\n", .{});
        std.debug.print("  RLE\n", .{});
        std.debug.print("  BWT+MTF+ZERORLE\n", .{});
        std.debug.print("  BWT+MTF+ARITH\n", .{});
        return;
    }

    // Auto-detect thread count
    if (n_threads == 0) {
        n_threads = std.Thread.getCpuCount() catch 4;
    }

    // Get io context for file operations
    const io = std.Io.Threaded.global_single_threaded.io();

    // Load input data
    const input_file = try std.Io.Dir.cwd().openFile(io, input_path.?, .{});
    defer input_file.close(io);
    const input_stat = try input_file.stat(io);
    const input_data = try allocator.alloc(u8, input_stat.size);
    defer allocator.free(input_data);
    _ = try input_file.readPositionalAll(io, input_data, 0);

    // Load formulas
    const formulas_file = try std.Io.Dir.cwd().openFile(io, formulas_path.?, .{});
    defer formulas_file.close(io);
    const formulas_stat = try formulas_file.stat(io);
    const formulas_content = try allocator.alloc(u8, formulas_stat.size);
    defer allocator.free(formulas_content);
    _ = try formulas_file.readPositionalAll(io, formulas_content, 0);

    // Parse all formulas into work items
    var work_items: std.ArrayListUnmanaged(WorkItem) = .empty;
    defer work_items.deinit(allocator);

    var line_iter = std.mem.splitScalar(u8, formulas_content, '\n');
    var idx: usize = 0;
    while (line_iter.next()) |line| {
        const formula = std.mem.trim(u8, line, &std.ascii.whitespace);
        if (formula.len == 0) continue;

        var item = WorkItem{
            .formula = formula,
            .steps = undefined,
            .step_count = 0,
            .index = idx,
        };

        item.step_count = parseFormula(formula, &item.steps) catch continue;
        if (item.step_count == 0) continue;

        try work_items.append(allocator, item);
        idx += 1;
    }

    const formula_count = work_items.items.len;

    std.debug.print("\n", .{});
    std.debug.print("╔══════════════════════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║  COMPRESSION FORMULA BENCHMARK (PARALLEL)                            ║\n", .{});
    std.debug.print("╠══════════════════════════════════════════════════════════════════════╣\n", .{});
    std.debug.print("║  Input Size: {} bytes                                                \n", .{input_data.len});
    std.debug.print("║  Formulas: {}                                                        \n", .{formula_count});
    std.debug.print("║  Threads: {}                                                         \n", .{n_threads});
    std.debug.print("╚══════════════════════════════════════════════════════════════════════╝\n", .{});
    std.debug.print("\n", .{});

    // Allocate results array
    const work_results = try allocator.alloc(WorkResult, formula_count);
    defer allocator.free(work_results);

    // Track completion
    var completed = std.atomic.Value(usize).init(0);

    var bench_start_ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(.MONOTONIC, &bench_start_ts) != 0) return error.TimerFailed;
    const bench_start_time = bench_start_ts;

    // Distribute work across threads
    const actual_threads = @min(n_threads, formula_count);
    const items_per_thread = (formula_count + actual_threads - 1) / actual_threads;

    var threads = try allocator.alloc(?std.Thread, actual_threads);
    defer allocator.free(threads);
    @memset(threads, null);

    // Spawn all threads
    var spawned_count: usize = 0;
    for (0..actual_threads) |t| {
        const start_idx = t * items_per_thread;
        const end_idx = @min(start_idx + items_per_thread, formula_count);
        if (start_idx >= formula_count) break;

        threads[t] = try std.Thread.spawn(.{}, workerThread, .{
            work_items.items[start_idx..end_idx],
            input_data,
            work_results,
            &completed,
        });
        spawned_count += 1;
    }

    std.debug.print("  Spawned {} worker threads...\n", .{spawned_count});

    // Progress reporting
    var last_completed: usize = 0;
    while (completed.load(.monotonic) < formula_count) {
        const current = completed.load(.monotonic);
        if (current != last_completed) {
            std.debug.print("\r  Progress: {}/{} formulas ({d:.1}%)   ", .{
                current,
                formula_count,
                @as(f64, @floatFromInt(current)) / @as(f64, @floatFromInt(formula_count)) * 100.0,
            });
            last_completed = current;
        }
        sleepMs(10);
    }
    std.debug.print("\r  Progress: {}/{} formulas (100.0%)   \n", .{ formula_count, formula_count });

    // Wait for all threads
    for (threads) |maybe_t| {
        if (maybe_t) |t| {
            t.join();
        }
    }

    var bench_end_ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(.MONOTONIC, &bench_end_ts) != 0) return error.TimerFailed;
    const bench_end_time = bench_end_ts;
    const elapsed_ns = (@as(i128, bench_end_time.sec) - @as(i128, bench_start_time.sec)) * 1_000_000_000 +
        (@as(i128, bench_end_time.nsec) - @as(i128, bench_start_time.nsec));
    const elapsed_secs = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000_000.0;

    // Collect successful results and compute stats
    var results: std.ArrayListUnmanaged(FormulaResult) = .empty;
    defer results.deinit(allocator);

    var successful: usize = 0;
    var lossless_count: usize = 0;
    var best_ratio: f64 = 999.0;

    for (work_results) |wr| {
        if (wr.success) {
            successful += 1;
            if (wr.is_lossless) {
                lossless_count += 1;
                if (wr.ratio < best_ratio) {
                    best_ratio = wr.ratio;
                }
            }

            try results.append(allocator, .{
                .formula = wr.formula,
                .ratio = wr.ratio,
                .is_lossless = wr.is_lossless,
                .throughput_mbps = wr.throughput_mbps,
                .original_size = wr.original_size,
                .compressed_size = wr.compressed_size,
                .encode_time_ns = wr.encode_time_ns,
            });
        }
    }

    // Sort by compression ratio
    std.mem.sort(FormulaResult, results.items, {}, FormulaResult.lessThan);

    // Print results
    std.debug.print("╔══════════════════════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║  RESULTS                                                             ║\n", .{});
    std.debug.print("╠══════════════════════════════════════════════════════════════════════╣\n", .{});
    std.debug.print("║  Formulas Tested: {} / {}                                            \n", .{ successful, formula_count });
    std.debug.print("║  Lossless: {}                                                        \n", .{lossless_count});
    std.debug.print("║  Best Ratio: {d:.4}                                                  \n", .{best_ratio});
    std.debug.print("║  Total Time: {d:.3}s                                                 \n", .{elapsed_secs});
    std.debug.print("║  Throughput: {d:.1} formulas/sec                                     \n", .{
        @as(f64, @floatFromInt(formula_count)) / elapsed_secs,
    });
    std.debug.print("╠══════════════════════════════════════════════════════════════════════╣\n", .{});
    std.debug.print("║  TOP {} RESULTS                                                      \n", .{top_n});
    std.debug.print("╠══════════════════════════════════════════════════════════════════════╣\n", .{});

    for (results.items[0..@min(top_n, results.items.len)], 0..) |r, i| {
        const lossless_str: []const u8 = if (r.is_lossless) "✓" else "✗";
        std.debug.print("║  {}: {s} ratio={d:.4} {s} {} → {} bytes\n", .{
            i + 1,
            lossless_str,
            r.ratio,
            r.formula,
            r.original_size,
            r.compressed_size,
        });
    }

    std.debug.print("╚══════════════════════════════════════════════════════════════════════╝\n", .{});

    // Save results - get io context for file operations
    const save_io = std.Io.Threaded.global_single_threaded.io();
    // Create output directory using linux syscall
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    if (output_dir.len < dir_buf.len) {
        @memcpy(dir_buf[0..output_dir.len], output_dir);
        dir_buf[output_dir.len] = 0;
        _ = std.os.linux.mkdir(@ptrCast(&dir_buf), 0o755);
    }

    const csv_path = try std.fmt.allocPrint(allocator, "{s}/results.csv", .{output_dir});
    defer allocator.free(csv_path);

    const csv_file = try std.Io.Dir.cwd().createFile(save_io, csv_path, .{});
    defer csv_file.close(save_io);

    var write_buf: [8192]u8 = undefined;
    var writer = csv_file.writer(save_io, &write_buf);
    try writer.interface.writeAll("rank,formula,ratio,lossless,original_bytes,compressed_bytes,throughput_mbps\n");

    for (results.items, 0..) |r, i| {
        var line_buf: [1024]u8 = undefined;
        const csv_line = try std.fmt.bufPrint(&line_buf, "{},{s},{d:.6},{},{},{},{d:.2}\n", .{
            i + 1,
            r.formula,
            r.ratio,
            @as(u8, if (r.is_lossless) 1 else 0),
            r.original_size,
            r.compressed_size,
            r.throughput_mbps,
        });
        try writer.interface.writeAll(csv_line);
    }
    try writer.interface.flush();

    std.debug.print("\nResults saved to: {s}/results.csv\n", .{output_dir});
}
