//! DSP Processing Graph
//!
//! A linked-list based audio processing chain. Audio flows through
//! connected processors sequentially. All processing is done in-place
//! to minimize memory allocations in the audio thread.
//!
//! Design:
//! - Zero allocations during processing
//! - Single-threaded (called from audio thread only)
//! - Processors can be added/removed between processing calls

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Maximum number of audio channels supported
pub const MAX_CHANNELS = 8;

/// Processor interface - implement this for custom DSP effects
pub const Processor = struct {
    /// Pointer to implementation-specific data
    ptr: *anyopaque,

    /// Virtual function table
    vtable: *const VTable,

    pub const VTable = struct {
        /// Process audio buffer in-place
        /// buffer: interleaved samples [L0, R0, L1, R1, ...]
        /// frames: number of frames (buffer.len / channels)
        /// channels: number of audio channels
        process: *const fn (ptr: *anyopaque, buffer: []f32, frames: usize, channels: u8) void,

        /// Reset processor state (e.g., clear delay lines)
        reset: *const fn (ptr: *anyopaque) void,

        /// Get processor name for debugging
        getName: *const fn (ptr: *anyopaque) []const u8,
    };

    /// Process audio through this processor
    pub fn process(self: Processor, buffer: []f32, frames: usize, channels: u8) void {
        self.vtable.process(self.ptr, buffer, frames, channels);
    }

    /// Reset processor state
    pub fn reset(self: Processor) void {
        self.vtable.reset(self.ptr);
    }

    /// Get processor name
    pub fn getName(self: Processor) []const u8 {
        return self.vtable.getName(self.ptr);
    }
};

/// Node in the processing chain
pub const ProcessorNode = struct {
    processor: Processor,
    enabled: bool,
    next: ?*ProcessorNode,

    /// Create a new node wrapping a processor
    pub fn init(processor: Processor) ProcessorNode {
        return .{
            .processor = processor,
            .enabled = true,
            .next = null,
        };
    }
};

/// DSP Processing Graph
pub const DspGraph = struct {
    /// Head of the processor chain
    head: ?*ProcessorNode,

    /// Tail for O(1) append
    tail: ?*ProcessorNode,

    /// Number of processors in chain
    count: usize,

    /// Sample rate (for coefficient calculation)
    sample_rate: f32,

    /// Number of channels
    channels: u8,

    const Self = @This();

    /// Initialize an empty graph
    pub fn init(sample_rate: f32, channels: u8) Self {
        return .{
            .head = null,
            .tail = null,
            .count = 0,
            .sample_rate = sample_rate,
            .channels = channels,
        };
    }

    /// Add a processor to the end of the chain
    pub fn addProcessor(self: *Self, node: *ProcessorNode) void {
        node.next = null;

        if (self.tail) |tail| {
            tail.next = node;
            self.tail = node;
        } else {
            self.head = node;
            self.tail = node;
        }

        self.count += 1;
    }

    /// Insert a processor at the beginning of the chain
    pub fn insertFirst(self: *Self, node: *ProcessorNode) void {
        node.next = self.head;
        self.head = node;

        if (self.tail == null) {
            self.tail = node;
        }

        self.count += 1;
    }

    /// Remove a processor from the chain
    /// Returns true if found and removed
    pub fn removeProcessor(self: *Self, node: *ProcessorNode) bool {
        var prev: ?*ProcessorNode = null;
        var current = self.head;

        while (current) |curr| {
            if (curr == node) {
                // Found it - unlink
                if (prev) |p| {
                    p.next = curr.next;
                } else {
                    self.head = curr.next;
                }

                // Update tail if needed
                if (curr == self.tail) {
                    self.tail = prev;
                }

                curr.next = null;
                self.count -= 1;
                return true;
            }

            prev = curr;
            current = curr.next;
        }

        return false;
    }

    /// Process audio through the entire chain
    /// This is the hot path - called from audio thread
    pub fn process(self: *Self, buffer: []f32) void {
        const frames = buffer.len / self.channels;
        var current = self.head;

        while (current) |node| {
            if (node.enabled) {
                node.processor.process(buffer, frames, self.channels);
            }
            current = node.next;
        }
    }

    /// Reset all processors in the chain
    pub fn reset(self: *Self) void {
        var current = self.head;

        while (current) |node| {
            node.processor.reset();
            current = node.next;
        }
    }

    /// Clear the graph (removes all processors but doesn't free them)
    pub fn clear(self: *Self) void {
        var current = self.head;

        while (current) |node| {
            const next = node.next;
            node.next = null;
            current = next;
        }

        self.head = null;
        self.tail = null;
        self.count = 0;
    }

    /// Get the number of processors in the chain
    pub fn getCount(self: *const Self) usize {
        return self.count;
    }

    /// Check if the graph is empty
    pub fn isEmpty(self: *const Self) bool {
        return self.head == null;
    }

    /// Enable/disable a processor by index
    pub fn setEnabled(self: *Self, index: usize, enabled: bool) bool {
        var current = self.head;
        var i: usize = 0;

        while (current) |node| {
            if (i == index) {
                node.enabled = enabled;
                return true;
            }
            i += 1;
            current = node.next;
        }

        return false;
    }

    /// Get processor names for debugging
    pub fn getProcessorNames(self: *const Self, allocator: Allocator) ![][]const u8 {
        var names = std.ArrayListUnmanaged([]const u8).empty;
        errdefer names.deinit(allocator);

        var current = self.head;
        while (current) |node| {
            try names.append(allocator, node.processor.getName());
            current = node.next;
        }

        return names.toOwnedSlice(allocator);
    }
};

/// Helper to create a Processor from a concrete type
/// The type T must have:
///   - fn process(self: *T, buffer: []f32, frames: usize, channels: u8) void
///   - fn reset(self: *T) void
///   - fn getName(self: *T) []const u8  OR  const name: []const u8
pub fn makeProcessor(comptime T: type, ptr: *T) Processor {
    const gen = struct {
        fn processImpl(p: *anyopaque, buffer: []f32, frames: usize, channels: u8) void {
            const self: *T = @ptrCast(@alignCast(p));
            self.process(buffer, frames, channels);
        }

        fn resetImpl(p: *anyopaque) void {
            const self: *T = @ptrCast(@alignCast(p));
            self.reset();
        }

        fn getNameImpl(p: *anyopaque) []const u8 {
            const self: *T = @ptrCast(@alignCast(p));
            if (@hasDecl(T, "getName")) {
                return self.getName();
            } else if (@hasDecl(T, "name")) {
                return T.name;
            } else {
                return "Unknown";
            }
        }

        const vtable = Processor.VTable{
            .process = processImpl,
            .reset = resetImpl,
            .getName = getNameImpl,
        };
    };

    return .{
        .ptr = ptr,
        .vtable = &gen.vtable,
    };
}

// =============================================================================
// Tests
// =============================================================================

const TestProcessor = struct {
    value: f32,
    process_count: usize,

    const name = "TestProcessor";

    fn process(self: *TestProcessor, buffer: []f32, frames: usize, channels: u8) void {
        _ = frames;
        _ = channels;
        // Add value to all samples
        for (buffer) |*sample| {
            sample.* += self.value;
        }
        self.process_count += 1;
    }

    fn reset(self: *TestProcessor) void {
        self.process_count = 0;
    }
};

test "dsp graph empty" {
    var graph = DspGraph.init(48000, 2);
    try std.testing.expect(graph.isEmpty());
    try std.testing.expectEqual(@as(usize, 0), graph.getCount());
}

test "dsp graph add processor" {
    var graph = DspGraph.init(48000, 2);

    var proc1 = TestProcessor{ .value = 1.0, .process_count = 0 };
    var node1 = ProcessorNode.init(makeProcessor(TestProcessor, &proc1));

    graph.addProcessor(&node1);

    try std.testing.expect(!graph.isEmpty());
    try std.testing.expectEqual(@as(usize, 1), graph.getCount());
}

test "dsp graph process chain" {
    var graph = DspGraph.init(48000, 2);

    var proc1 = TestProcessor{ .value = 1.0, .process_count = 0 };
    var proc2 = TestProcessor{ .value = 2.0, .process_count = 0 };

    var node1 = ProcessorNode.init(makeProcessor(TestProcessor, &proc1));
    var node2 = ProcessorNode.init(makeProcessor(TestProcessor, &proc2));

    graph.addProcessor(&node1);
    graph.addProcessor(&node2);

    // Process some samples
    var buffer = [_]f32{ 0.0, 0.0, 0.0, 0.0 };
    graph.process(&buffer);

    // Each sample should have 1.0 + 2.0 = 3.0 added
    for (buffer) |sample| {
        try std.testing.expectApproxEqAbs(@as(f32, 3.0), sample, 0.001);
    }

    // Both processors should have been called
    try std.testing.expectEqual(@as(usize, 1), proc1.process_count);
    try std.testing.expectEqual(@as(usize, 1), proc2.process_count);
}

test "dsp graph disable processor" {
    var graph = DspGraph.init(48000, 2);

    var proc1 = TestProcessor{ .value = 1.0, .process_count = 0 };
    var node1 = ProcessorNode.init(makeProcessor(TestProcessor, &proc1));

    graph.addProcessor(&node1);

    // Disable the processor
    _ = graph.setEnabled(0, false);

    var buffer = [_]f32{ 0.0, 0.0 };
    graph.process(&buffer);

    // Processor should not have been called
    try std.testing.expectEqual(@as(usize, 0), proc1.process_count);

    // Buffer should be unchanged
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), buffer[0], 0.001);
}

test "dsp graph remove processor" {
    var graph = DspGraph.init(48000, 2);

    var proc1 = TestProcessor{ .value = 1.0, .process_count = 0 };
    var proc2 = TestProcessor{ .value = 2.0, .process_count = 0 };

    var node1 = ProcessorNode.init(makeProcessor(TestProcessor, &proc1));
    var node2 = ProcessorNode.init(makeProcessor(TestProcessor, &proc2));

    graph.addProcessor(&node1);
    graph.addProcessor(&node2);

    try std.testing.expectEqual(@as(usize, 2), graph.getCount());

    // Remove first processor
    try std.testing.expect(graph.removeProcessor(&node1));
    try std.testing.expectEqual(@as(usize, 1), graph.getCount());

    // Process - only proc2 should run
    var buffer = [_]f32{ 0.0, 0.0 };
    graph.process(&buffer);

    try std.testing.expectApproxEqAbs(@as(f32, 2.0), buffer[0], 0.001);
}

test "dsp graph reset" {
    var graph = DspGraph.init(48000, 2);

    var proc1 = TestProcessor{ .value = 1.0, .process_count = 5 };
    var node1 = ProcessorNode.init(makeProcessor(TestProcessor, &proc1));

    graph.addProcessor(&node1);
    graph.reset();

    try std.testing.expectEqual(@as(usize, 0), proc1.process_count);
}
