//! Compression Test Library - Dynamically Loadable Test Function
//!
//! Implements the swarm test interface for lossless compression pipeline testing.
//! Compiled as a shared library (.so) and loaded by workers via dlopen().

const std = @import("std");

// ============================================================================
// Compression Algorithms (copied from compression_bench.zig)
// ============================================================================

const Allocator = std.mem.Allocator;

/// Thread-local allocator for test execution
var tls_allocator: ?std.heap.ArenaAllocator = null;

fn getAllocator() Allocator {
    if (tls_allocator == null) {
        tls_allocator = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    }
    return tls_allocator.?.allocator();
}

fn resetAllocator() void {
    if (tls_allocator) |*arena| {
        _ = arena.reset(.retain_capacity);
    }
}

/// Run-Length Encoding
const RLE = struct {
    pub fn encode(allocator: Allocator, input: []const u8) ![]u8 {
        if (input.len == 0) return try allocator.alloc(u8, 0);

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
        for (1..input.len) |j| {
            output[j] = input[j] -% input[j - 1];
        }
        return output;
    }

    pub fn decode(allocator: Allocator, input: []const u8) ![]u8 {
        if (input.len == 0) return try allocator.alloc(u8, 0);

        var output = try allocator.alloc(u8, input.len);
        output[0] = input[0];
        for (1..input.len) |j| {
            output[j] = output[j - 1] +% input[j];
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
        for (0..256) |j| alphabet[j] = @intCast(j);

        for (input, 0..) |char, idx| {
            var pos: u8 = 0;
            for (alphabet, 0..) |a, k| {
                if (a == char) {
                    pos = @intCast(k);
                    break;
                }
            }
            output[idx] = pos;

            const c = alphabet[pos];
            var m: usize = pos;
            while (m > 0) : (m -= 1) alphabet[m] = alphabet[m - 1];
            alphabet[0] = c;
        }
        return output;
    }

    pub fn decode(allocator: Allocator, input: []const u8) ![]u8 {
        if (input.len == 0) return try allocator.alloc(u8, 0);

        var output = try allocator.alloc(u8, input.len);
        var alphabet: [256]u8 = undefined;
        for (0..256) |j| alphabet[j] = @intCast(j);

        for (input, 0..) |pos, idx| {
            const char = alphabet[pos];
            output[idx] = char;

            var m: usize = pos;
            while (m > 0) : (m -= 1) alphabet[m] = alphabet[m - 1];
            alphabet[0] = char;
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
};

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
        } else {
            return error.UnknownStep;
        }

        count += 1;
        if (count >= 16) break;
    }

    return count;
}

fn executeCompression(
    allocator: Allocator,
    input: []const u8,
    steps: []const CompressionStep,
) !struct { ratio: f64, is_lossless: bool } {
    // Apply each compression step
    var current: []u8 = try allocator.dupe(u8, input);
    var prev: ?[]u8 = null;

    for (steps) |step| {
        const next = switch (step) {
            .rle => try RLE.encode(allocator, current),
            .delta => try Delta.encode(allocator, current),
            .mtf => try MTF.encode(allocator, current),
        };

        if (prev) |p| allocator.free(p);
        prev = current;
        current = next;
    }

    if (prev) |p| allocator.free(p);

    const compressed_size = current.len;

    // Verify lossless by decompressing
    var decompressed: []u8 = try allocator.dupe(u8, current);
    prev = null;

    var i: usize = steps.len;
    while (i > 0) {
        i -= 1;
        const next = switch (steps[i]) {
            .rle => try RLE.decode(allocator, decompressed),
            .delta => try Delta.decode(allocator, decompressed),
            .mtf => try MTF.decode(allocator, decompressed),
        };

        if (prev) |p| allocator.free(p);
        prev = decompressed;
        decompressed = next;
    }

    if (prev) |p| allocator.free(p);

    const is_lossless = decompressed.len == input.len and std.mem.eql(u8, input, decompressed);

    allocator.free(decompressed);
    allocator.free(current);

    return .{
        .ratio = @as(f64, @floatFromInt(compressed_size)) / @as(f64, @floatFromInt(input.len)),
        .is_lossless = is_lossless,
    };
}

// ============================================================================
// Global State
// ============================================================================

var g_input_data: ?[]const u8 = null;
var g_initialized: bool = false;

// ============================================================================
// Exported C ABI Functions
// ============================================================================

/// Initialize the test library
/// config_data contains: [4 bytes input_len][input_data...]
export fn swarm_test_init(config: [*]const u8, config_len: usize) callconv(.c) bool {
    if (config_len < 4) return false;

    const input_len = std.mem.readInt(u32, config[0..4], .little);
    if (config_len < 4 + input_len) return false;

    // Store pointer to input data (owned by caller)
    g_input_data = config[4..][0..input_len];
    g_initialized = true;

    return true;
}

/// Execute test on a task
/// task_data contains the formula string (e.g., "RLE+DELTA+MTF")
/// Returns: >0 = success (result length), 0 = no match, <0 = error
export fn swarm_test_execute(
    task_data: [*]const u8,
    task_len: usize,
    result_buf: [*]u8,
    result_buf_len: usize,
) callconv(.c) i32 {
    if (!g_initialized or g_input_data == null) return -1;
    if (result_buf_len < 24) return -2; // Need space for result struct

    const formula = task_data[0..task_len];
    const input = g_input_data.?;
    const allocator = getAllocator();
    defer resetAllocator();

    var steps: [16]CompressionStep = undefined;
    const step_count = parseFormula(formula, &steps) catch return -3;
    if (step_count == 0) return -4;

    const result = executeCompression(allocator, input, steps[0..step_count]) catch return -5;

    // Write result to buffer
    // Format: [u8 success][padding 7][f64 ratio][u32 orig_len][u32 comp_len]
    result_buf[0] = if (result.is_lossless) 1 else 0;
    @memset(result_buf[1..8], 0); // padding

    const ratio_bytes = std.mem.toBytes(result.ratio);
    @memcpy(result_buf[8..16], &ratio_bytes);

    const orig_len: u32 = @intCast(input.len);
    const comp_len: u32 = @intCast(@as(usize, @intFromFloat(@as(f64, @floatFromInt(input.len)) * result.ratio)));

    @memcpy(result_buf[16..20], &std.mem.toBytes(orig_len));
    @memcpy(result_buf[20..24], &std.mem.toBytes(comp_len));

    // Return success only if lossless
    return if (result.is_lossless) 24 else 0;
}

/// Cleanup resources
export fn swarm_test_cleanup() callconv(.c) void {
    g_input_data = null;
    g_initialized = false;

    if (tls_allocator) |*arena| {
        arena.deinit();
        tls_allocator = null;
    }
}
