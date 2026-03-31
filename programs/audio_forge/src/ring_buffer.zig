//! Lock-Free Audio Ring Buffer
//!
//! Single-Producer Single-Consumer (SPSC) ring buffer optimized for
//! real-time audio with sub-100ns read/write operations.
//!
//! Design:
//! - Power-of-2 capacity for efficient modulo via bitwise AND
//! - Cache-line padding between read/write positions to prevent false sharing
//! - Acquire/release memory ordering for thread safety without locks
//! - Interleaved sample format for SIMD-friendly processing

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Cache line size for padding (64 bytes on x86-64)
const CACHE_LINE_SIZE = 64;

/// Lock-free SPSC audio ring buffer
pub const AudioRingBuffer = struct {
    /// Audio sample buffer (interleaved: [L0, R0, L1, R1, ...])
    buffer: []f32,

    /// Buffer capacity in frames (always power of 2)
    capacity_frames: usize,

    /// Capacity mask for efficient modulo (capacity - 1)
    capacity_mask: usize,

    /// Number of audio channels
    channels: u8,

    /// Write position in frames (updated by producer)
    /// Padded to its own cache line
    write_pos: std.atomic.Value(usize) align(CACHE_LINE_SIZE),

    /// Padding to separate write_pos and read_pos cache lines
    _padding: [CACHE_LINE_SIZE - @sizeOf(std.atomic.Value(usize))]u8 = undefined,

    /// Read position in frames (updated by consumer)
    read_pos: std.atomic.Value(usize) align(CACHE_LINE_SIZE),

    const Self = @This();

    /// Initialize ring buffer with given capacity (rounded up to power of 2)
    pub fn init(allocator: Allocator, capacity_frames: usize, channels: u8) !Self {
        // Round up to next power of 2
        const actual_capacity = std.math.ceilPowerOfTwo(usize, capacity_frames) catch {
            return error.CapacityTooLarge;
        };

        const total_samples = actual_capacity * channels;
        const buffer = try allocator.alloc(f32, total_samples);
        @memset(buffer, 0);

        return Self{
            .buffer = buffer,
            .capacity_frames = actual_capacity,
            .capacity_mask = actual_capacity - 1,
            .channels = channels,
            .write_pos = std.atomic.Value(usize).init(0),
            .read_pos = std.atomic.Value(usize).init(0),
        };
    }

    /// Free ring buffer memory
    pub fn deinit(self: *Self, allocator: Allocator) void {
        allocator.free(self.buffer);
        self.buffer = &.{};
    }

    /// Number of frames available for reading
    pub fn availableRead(self: *const Self) usize {
        const write_idx = self.write_pos.load(.acquire);
        const read_idx = self.read_pos.load(.monotonic);
        return write_idx -% read_idx;
    }

    /// Number of frames available for writing
    pub fn availableWrite(self: *const Self) usize {
        const write_idx = self.write_pos.load(.monotonic);
        const read_idx = self.read_pos.load(.acquire);
        return self.capacity_frames - (write_idx -% read_idx);
    }

    /// Write frames to the buffer (producer side)
    /// Returns number of frames actually written
    pub fn write(self: *Self, frames: []const f32) usize {
        const channels: usize = self.channels;
        const frame_count = frames.len / channels;

        const available = self.availableWrite();
        const to_write = @min(frame_count, available);

        if (to_write == 0) return 0;

        const write_idx = self.write_pos.load(.monotonic);
        const samples_to_write = to_write * channels;

        // Calculate buffer positions
        const start_sample = (write_idx & self.capacity_mask) * channels;
        const end_sample = start_sample + samples_to_write;

        if (end_sample <= self.buffer.len) {
            // Contiguous write
            @memcpy(self.buffer[start_sample..][0..samples_to_write], frames[0..samples_to_write]);
        } else {
            // Wrap-around write
            const first_part = self.buffer.len - start_sample;
            const second_part = samples_to_write - first_part;

            @memcpy(self.buffer[start_sample..], frames[0..first_part]);
            @memcpy(self.buffer[0..second_part], frames[first_part..samples_to_write]);
        }

        // Release barrier: ensure written data is visible before updating position
        self.write_pos.store(write_idx +% to_write, .release);

        return to_write;
    }

    /// Read frames from the buffer (consumer side)
    /// Returns number of frames actually read
    pub fn read(self: *Self, out: []f32) usize {
        const channels: usize = self.channels;
        const frame_count = out.len / channels;

        const available = self.availableRead();
        const to_read = @min(frame_count, available);

        if (to_read == 0) return 0;

        const read_idx = self.read_pos.load(.monotonic);
        const samples_to_read = to_read * channels;

        // Calculate buffer positions
        const start_sample = (read_idx & self.capacity_mask) * channels;
        const end_sample = start_sample + samples_to_read;

        if (end_sample <= self.buffer.len) {
            // Contiguous read
            @memcpy(out[0..samples_to_read], self.buffer[start_sample..][0..samples_to_read]);
        } else {
            // Wrap-around read
            const first_part = self.buffer.len - start_sample;
            const second_part = samples_to_read - first_part;

            @memcpy(out[0..first_part], self.buffer[start_sample..]);
            @memcpy(out[first_part..samples_to_read], self.buffer[0..second_part]);
        }

        // Release barrier: ensure reads complete before updating position
        self.read_pos.store(read_idx +% to_read, .release);

        return to_read;
    }

    /// Write frames without blocking - returns immediately if buffer full
    /// Useful for real-time threads that cannot wait
    pub fn tryWrite(self: *Self, frames: []const f32) ?usize {
        const channels: usize = self.channels;
        const frame_count = frames.len / channels;

        if (self.availableWrite() < frame_count) {
            return null;
        }

        return self.write(frames);
    }

    /// Read frames without blocking - returns immediately if insufficient data
    /// Useful for real-time threads that cannot wait
    pub fn tryRead(self: *Self, out: []f32) ?usize {
        const channels: usize = self.channels;
        const frame_count = out.len / channels;

        if (self.availableRead() < frame_count) {
            return null;
        }

        return self.read(out);
    }

    /// Reset buffer to empty state (not thread-safe, call only when idle)
    pub fn reset(self: *Self) void {
        self.write_pos.store(0, .monotonic);
        self.read_pos.store(0, .monotonic);
        @memset(self.buffer, 0);
    }

    /// Check if buffer is empty
    pub fn isEmpty(self: *const Self) bool {
        return self.availableRead() == 0;
    }

    /// Check if buffer is full
    pub fn isFull(self: *const Self) bool {
        return self.availableWrite() == 0;
    }
};

// =============================================================================
// Tests
// =============================================================================

test "ring buffer init and deinit" {
    const allocator = std.testing.allocator;

    var rb = try AudioRingBuffer.init(allocator, 1024, 2);
    defer rb.deinit(allocator);

    // Should be rounded to power of 2
    try std.testing.expectEqual(@as(usize, 1024), rb.capacity_frames);
    try std.testing.expectEqual(@as(usize, 1023), rb.capacity_mask);
    try std.testing.expectEqual(@as(u8, 2), rb.channels);

    // Should start empty
    try std.testing.expectEqual(@as(usize, 0), rb.availableRead());
    try std.testing.expectEqual(@as(usize, 1024), rb.availableWrite());
    try std.testing.expect(rb.isEmpty());
    try std.testing.expect(!rb.isFull());
}

test "ring buffer non-power-of-2 rounding" {
    const allocator = std.testing.allocator;

    var rb = try AudioRingBuffer.init(allocator, 1000, 2);
    defer rb.deinit(allocator);

    // Should be rounded up to 1024
    try std.testing.expectEqual(@as(usize, 1024), rb.capacity_frames);
}

test "ring buffer write and read" {
    const allocator = std.testing.allocator;

    var rb = try AudioRingBuffer.init(allocator, 256, 2);
    defer rb.deinit(allocator);

    // Write some frames (stereo: 2 samples per frame)
    const write_data = [_]f32{ 0.1, -0.1, 0.2, -0.2, 0.3, -0.3, 0.4, -0.4 };
    const written = rb.write(&write_data);

    try std.testing.expectEqual(@as(usize, 4), written); // 4 frames
    try std.testing.expectEqual(@as(usize, 4), rb.availableRead());
    try std.testing.expectEqual(@as(usize, 252), rb.availableWrite());

    // Read back
    var read_data: [8]f32 = undefined;
    const read_frames = rb.read(&read_data);

    try std.testing.expectEqual(@as(usize, 4), read_frames);
    try std.testing.expectEqualSlices(f32, &write_data, &read_data);

    // Should be empty again
    try std.testing.expectEqual(@as(usize, 0), rb.availableRead());
    try std.testing.expect(rb.isEmpty());
}

test "ring buffer wrap-around" {
    const allocator = std.testing.allocator;

    var rb = try AudioRingBuffer.init(allocator, 8, 2); // Small buffer for testing wrap
    defer rb.deinit(allocator);

    // Fill most of buffer (6 frames = 12 samples)
    const data1 = [_]f32{ 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6 };
    _ = rb.write(&data1);

    // Read 4 frames to advance read pointer
    var trash: [8]f32 = undefined;
    _ = rb.read(&trash);

    // Now write 4 more frames - this should wrap around
    const data2 = [_]f32{ 7, 7, 8, 8, 9, 9, 10, 10 };
    const written = rb.write(&data2);
    try std.testing.expectEqual(@as(usize, 4), written);

    // Read all remaining data (2 + 4 = 6 frames)
    var output: [12]f32 = undefined;
    const read_count = rb.read(&output);

    try std.testing.expectEqual(@as(usize, 6), read_count);

    // Verify data integrity
    const expected = [_]f32{ 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10 };
    try std.testing.expectEqualSlices(f32, &expected, &output);
}

test "ring buffer tryWrite and tryRead" {
    const allocator = std.testing.allocator;

    var rb = try AudioRingBuffer.init(allocator, 4, 2);
    defer rb.deinit(allocator);

    // Fill buffer completely
    const data = [_]f32{ 1, 1, 2, 2, 3, 3, 4, 4 };
    _ = rb.write(&data);

    // tryWrite should fail when full
    const more_data = [_]f32{ 5, 5 };
    try std.testing.expectEqual(@as(?usize, null), rb.tryWrite(&more_data));

    // tryRead should succeed
    var out: [2]f32 = undefined;
    try std.testing.expectEqual(@as(?usize, 1), rb.tryRead(&out));

    // After reading, tryRead for more than available should fail
    var big_out: [10]f32 = undefined;
    try std.testing.expectEqual(@as(?usize, null), rb.tryRead(&big_out));
}

test "ring buffer reset" {
    const allocator = std.testing.allocator;

    var rb = try AudioRingBuffer.init(allocator, 256, 2);
    defer rb.deinit(allocator);

    // Write some data
    const data = [_]f32{ 1, 2, 3, 4, 5, 6, 7, 8 };
    _ = rb.write(&data);

    try std.testing.expect(!rb.isEmpty());

    // Reset
    rb.reset();

    try std.testing.expect(rb.isEmpty());
    try std.testing.expectEqual(@as(usize, 0), rb.availableRead());
    try std.testing.expectEqual(@as(usize, 256), rb.availableWrite());
}

test "ring buffer mono channel" {
    const allocator = std.testing.allocator;

    var rb = try AudioRingBuffer.init(allocator, 256, 1);
    defer rb.deinit(allocator);

    const data = [_]f32{ 0.1, 0.2, 0.3, 0.4 };
    const written = rb.write(&data);

    try std.testing.expectEqual(@as(usize, 4), written);

    var out: [4]f32 = undefined;
    const read_count = rb.read(&out);

    try std.testing.expectEqual(@as(usize, 4), read_count);
    try std.testing.expectEqualSlices(f32, &data, &out);
}

test "ring buffer partial write when full" {
    const allocator = std.testing.allocator;

    var rb = try AudioRingBuffer.init(allocator, 4, 2);
    defer rb.deinit(allocator);

    // Write 3 frames
    const data1 = [_]f32{ 1, 1, 2, 2, 3, 3 };
    _ = rb.write(&data1);

    // Try to write 3 more frames - only 1 should fit
    const data2 = [_]f32{ 4, 4, 5, 5, 6, 6 };
    const written = rb.write(&data2);

    try std.testing.expectEqual(@as(usize, 1), written);
    try std.testing.expect(rb.isFull());
}

test "ring buffer multiple small writes then large read" {
    const allocator = std.testing.allocator;

    var rb = try AudioRingBuffer.init(allocator, 256, 2);
    defer rb.deinit(allocator);

    // Write multiple small chunks
    const chunk1 = [_]f32{ 0.1, 0.1, 0.2, 0.2 };
    const chunk2 = [_]f32{ 0.3, 0.3, 0.4, 0.4 };
    const chunk3 = [_]f32{ 0.5, 0.5, 0.6, 0.6 };

    _ = rb.write(&chunk1);
    _ = rb.write(&chunk2);
    _ = rb.write(&chunk3);

    try std.testing.expectEqual(@as(usize, 6), rb.availableRead()); // 6 samples

    // Read all in one go
    var output: [6]f32 = undefined;
    const read_frames = rb.read(&output);

    try std.testing.expectEqual(@as(usize, 3), read_frames);

    const expected = [_]f32{ 0.1, 0.1, 0.2, 0.2, 0.3, 0.3 };
    try std.testing.expectEqualSlices(f32, &expected, &output);
}

test "ring buffer fill and drain cycle" {
    const allocator = std.testing.allocator;

    var rb = try AudioRingBuffer.init(allocator, 16, 1);
    defer rb.deinit(allocator);

    // Fill completely
    const full_data = [_]f32{ 1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0, 10.0, 11.0, 12.0, 13.0, 14.0, 15.0, 16.0 };
    const written = rb.write(&full_data);
    try std.testing.expectEqual(@as(usize, 16), written);
    try std.testing.expect(rb.isFull());

    // Drain completely
    var output: [16]f32 = undefined;
    const read_frames = rb.read(&output);
    try std.testing.expectEqual(@as(usize, 16), read_frames);
    try std.testing.expect(rb.isEmpty());

    try std.testing.expectEqualSlices(f32, &full_data, &output);
}

test "ring buffer available counts accuracy" {
    const allocator = std.testing.allocator;

    var rb = try AudioRingBuffer.init(allocator, 8, 2);
    defer rb.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 0), rb.availableRead());
    try std.testing.expectEqual(@as(usize, 8), rb.availableWrite());

    // Write 2 frames (4 samples)
    const data = [_]f32{ 1, 1, 2, 2 };
    _ = rb.write(&data);

    try std.testing.expectEqual(@as(usize, 2), rb.availableRead());
    try std.testing.expectEqual(@as(usize, 6), rb.availableWrite());

    // Read 1 frame
    var out: [2]f32 = undefined;
    _ = rb.read(&out);

    try std.testing.expectEqual(@as(usize, 1), rb.availableRead());
    try std.testing.expectEqual(@as(usize, 7), rb.availableWrite());
}

test "ring buffer empty read returns zero" {
    const allocator = std.testing.allocator;

    var rb = try AudioRingBuffer.init(allocator, 256, 2);
    defer rb.deinit(allocator);

    var out: [4]f32 = undefined;
    const read_frames = rb.read(&out);

    try std.testing.expectEqual(@as(usize, 0), read_frames);
}

test "ring buffer power of 2 rounding" {
    const allocator = std.testing.allocator;

    var rb = try AudioRingBuffer.init(allocator, 100, 2);
    defer rb.deinit(allocator);

    // Should round up to 128
    try std.testing.expectEqual(@as(usize, 128), rb.capacity_frames);
    try std.testing.expectEqual(@as(usize, 127), rb.capacity_mask);
}

test "ring buffer large capacity allocation" {
    const allocator = std.testing.allocator;

    // Try a reasonably large capacity
    var rb = try AudioRingBuffer.init(allocator, 65536, 2);
    defer rb.deinit(allocator);

    // Should have rounded to next power of 2
    try std.testing.expectEqual(@as(usize, 65536), rb.capacity_frames);
}
