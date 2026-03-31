// SPDX-License-Identifier: Dual License - MIT (Non-Commercial) / Commercial License
//
// cognitive_metrics.zig - Cognitive Metrics Aggregation and Analysis
//
// Purpose: Calculate real-time metrics from cognitive event streams
// Architecture: Time-windowed aggregation with rolling statistics
//
// THE METRICS ENGINE - Quantifying Divine Thought

const std = @import("std");
const linux = std.os.linux;
const cognitive_states = @import("cognitive_states.zig");

/// Get current time as nanoseconds since epoch
fn nanoTimestamp() u64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.REALTIME, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

/// Cognitive state as string
pub const CognitiveState = []const u8;
pub const ToolActivity = cognitive_states.ToolActivity;

/// Cognitive metrics over a time window (default: 60 seconds)
pub const CognitiveMetrics = struct {
    current_state: CognitiveState,
    current_activity: ToolActivity,
    confidence: f32,
    tool_rate: f32,              // tools per minute
    state_durations_ns: [84]u64, // nanoseconds in each state
    tool_counts: [13]u32,         // count per tool type
    completion_rate: f32,
    retry_rate: f32,
    uncertainty_events: u32,
    avg_state_duration_ns: u64,
    total_events: u32,
    window_start_ns: u64,
    window_end_ns: u64,
};

/// Single point in cognitive state timeline
pub const StateEvent = struct {
    timestamp_ns: u64,
    state: CognitiveState,
    confidence: f32,
    phi_timestamp: f64, // PHI-synchronized timestamp
};

/// Single tool execution event
pub const ToolEvent = struct {
    timestamp_ns: u64,
    activity: ToolActivity,
    success: bool,
    duration_ns: u64,
    phi_timestamp: f64,
};

/// Metrics aggregator with rolling time window
pub const MetricsAggregator = struct {
    allocator: std.mem.Allocator,
    state_history: std.ArrayList(StateEvent),
    tool_history: std.ArrayList(ToolEvent),
    window_seconds: u64,
    max_events: usize,

    pub fn init(allocator: std.mem.Allocator, window_seconds: u64) !MetricsAggregator {
        return .{
            .allocator = allocator,
            .state_history = std.ArrayList(StateEvent).empty,
            .tool_history = std.ArrayList(ToolEvent).empty,
            .window_seconds = window_seconds,
            .max_events = 10000, // Prevent unbounded growth
        };
    }

    pub fn deinit(self: *MetricsAggregator) void {
        self.state_history.deinit(self.allocator);
        self.tool_history.deinit(self.allocator);
    }

    /// Add a cognitive state event
    pub fn addStateEvent(self: *MetricsAggregator, event: StateEvent) !void {
        try self.state_history.append(self.allocator, event);
        self.pruneOldEvents();
    }

    /// Add a tool execution event
    pub fn addToolEvent(self: *MetricsAggregator, event: ToolEvent) !void {
        try self.tool_history.append(self.allocator, event);
        self.pruneOldEvents();
    }

    /// Remove events older than the time window
    fn pruneOldEvents(self: *MetricsAggregator) void {
        const now_ns = nanoTimestamp();
        const window_ns = self.window_seconds * std.time.ns_per_s;
        const cutoff_ns = now_ns - window_ns;

        // Prune state events
        var i: usize = 0;
        while (i < self.state_history.items.len) {
            if (self.state_history.items[i].timestamp_ns < cutoff_ns) {
                _ = self.state_history.orderedRemove(i);
            } else {
                i += 1;
            }
        }

        // Prune tool events
        i = 0;
        while (i < self.tool_history.items.len) {
            if (self.tool_history.items[i].timestamp_ns < cutoff_ns) {
                _ = self.tool_history.orderedRemove(i);
            } else {
                i += 1;
            }
        }

        // Enforce max_events limit
        while (self.state_history.items.len > self.max_events) {
            _ = self.state_history.orderedRemove(0);
        }
        while (self.tool_history.items.len > self.max_events) {
            _ = self.tool_history.orderedRemove(0);
        }
    }

    /// Compute metrics for current time window
    pub fn compute(self: *MetricsAggregator) !CognitiveMetrics {
        const now_ns = nanoTimestamp();
        const window_ns = self.window_seconds * std.time.ns_per_s;

        // Initialize metrics
        var metrics = CognitiveMetrics{
            .current_state = "unknown",
            .current_activity = .unknown,
            .confidence = 0.0,
            .tool_rate = 0.0,
            .state_durations_ns = [_]u64{0} ** 84,
            .tool_counts = [_]u32{0} ** 13,
            .completion_rate = 0.0,
            .retry_rate = 0.0,
            .uncertainty_events = 0,
            .avg_state_duration_ns = 0,
            .total_events = 0,
            .window_start_ns = now_ns - window_ns,
            .window_end_ns = now_ns,
        };

        if (self.state_history.items.len == 0) {
            return metrics;
        }

        // Current state is the most recent
        const latest_state = self.state_history.items[self.state_history.items.len - 1];
        metrics.current_state = latest_state.state;
        metrics.confidence = latest_state.confidence;

        // Calculate state durations (simplified - just count total time for now)
        for (self.state_history.items, 0..) |event, i| {
            if (i == 0) continue;
            const prev = self.state_history.items[i - 1];
            const duration = event.timestamp_ns - prev.timestamp_ns;
            // Use first slot for all states for now
            metrics.state_durations_ns[0] += duration;
        }

        // Calculate tool counts and success rate
        var successful_tools: u32 = 0;
        for (self.tool_history.items) |tool| {
            const activity_idx = @intFromEnum(tool.activity);
            if (activity_idx < 13) {
                metrics.tool_counts[activity_idx] += 1;
            }
            if (tool.success) successful_tools += 1;
        }

        // Calculate tool rate (per minute)
        if (self.tool_history.items.len > 0) {
            metrics.tool_rate = @as(f32, @floatFromInt(self.tool_history.items.len)) /
                @as(f32, @floatFromInt(self.window_seconds)) * 60.0;
        }

        // Most recent tool activity
        if (self.tool_history.items.len > 0) {
            metrics.current_activity = self.tool_history.items[self.tool_history.items.len - 1].activity;
        }

        // Completion rate
        if (self.tool_history.items.len > 0) {
            metrics.completion_rate = @as(f32, @floatFromInt(successful_tools)) /
                @as(f32, @floatFromInt(self.tool_history.items.len));
            metrics.retry_rate = 1.0 - metrics.completion_rate;
        }

        // Count uncertainty events (confidence < 50%)
        for (self.state_history.items) |event| {
            if (event.confidence < 0.5) {
                metrics.uncertainty_events += 1;
            }
        }

        // Average state duration
        var total_duration: u64 = 0;
        for (metrics.state_durations_ns) |duration| {
            total_duration += duration;
        }
        if (self.state_history.items.len > 1) {
            metrics.avg_state_duration_ns = total_duration / (self.state_history.items.len - 1);
        }

        metrics.total_events = @intCast(self.state_history.items.len + self.tool_history.items.len);

        return metrics;
    }

    /// Get state history within time range
    pub fn getStateHistory(self: *MetricsAggregator, start_ns: u64, end_ns: u64) []const StateEvent {
        var start_idx: usize = 0;
        var end_idx: usize = self.state_history.items.len;

        // Find start index
        for (self.state_history.items, 0..) |event, i| {
            if (event.timestamp_ns >= start_ns) {
                start_idx = i;
                break;
            }
        }

        // Find end index
        for (self.state_history.items[start_idx..], 0..) |event, i| {
            if (event.timestamp_ns > end_ns) {
                end_idx = start_idx + i;
                break;
            }
        }

        return self.state_history.items[start_idx..end_idx];
    }

    /// Get tool history within time range
    pub fn getToolHistory(self: *MetricsAggregator, start_ns: u64, end_ns: u64) []const ToolEvent {
        var start_idx: usize = 0;
        var end_idx: usize = self.tool_history.items.len;

        // Find start index
        for (self.tool_history.items, 0..) |event, i| {
            if (event.timestamp_ns >= start_ns) {
                start_idx = i;
                break;
            }
        }

        // Find end index
        for (self.tool_history.items[start_idx..], 0..) |event, i| {
            if (event.timestamp_ns > end_ns) {
                end_idx = start_idx + i;
                break;
            }
        }

        return self.tool_history.items[start_idx..end_idx];
    }
};

/// Calculate confidence from cognitive state patterns
pub fn calculateConfidence(
    current_state: CognitiveState,
    recent_states: []const CognitiveState,
) f32 {
    // High confidence states
    const high_confidence_states = [_][]const u8{
        "Channelling",
        "Synthesizing",
        "Actualizing",
        "Crafting",
        "Creating",
    };

    // Low confidence states (uncertainty)
    const low_confidence_states = [_][]const u8{
        "Finagling",
        "Combobulating",
        "Puzzling",
        "Wibbling",
        "Discombobulating",
    };

    // Base confidence from current state
    var confidence: f32 = 0.75; // Default medium

    for (high_confidence_states) |state| {
        if (std.mem.eql(u8, current_state, state)) {
            confidence = 0.9;
            break;
        }
    }

    for (low_confidence_states) |state| {
        if (std.mem.eql(u8, current_state, state)) {
            confidence = 0.4;
            break;
        }
    }

    // Adjust based on recent state stability
    if (recent_states.len > 0) {
        var same_state_count: u32 = 0;
        for (recent_states) |state| {
            if (std.mem.eql(u8, state, current_state)) same_state_count += 1;
        }

        // If stuck in same state, reduce confidence
        if (same_state_count > 3) {
            confidence *= 0.8;
        }

        // If rapidly changing states, reduce confidence
        var transitions: u32 = 0;
        for (recent_states, 0..) |state, i| {
            if (i > 0 and !std.mem.eql(u8, state, recent_states[i - 1])) {
                transitions += 1;
            }
        }
        if (transitions > recent_states.len / 2) {
            confidence *= 0.85;
        }
    }

    return std.math.clamp(confidence, 0.0, 1.0);
}

test "MetricsAggregator basic" {
    const allocator = std.testing.allocator;
    var aggregator = try MetricsAggregator.init(allocator, 60);
    defer aggregator.deinit();

    // Add some test events
    try aggregator.addStateEvent(.{
        .timestamp_ns = 1000000000,
        .state = "Channelling",
        .confidence = 0.9,
        .phi_timestamp = 1618033988.0,
    });

    try aggregator.addToolEvent(.{
        .timestamp_ns = 1100000000,
        .activity = .writing_file,
        .success = true,
        .duration_ns = 100000000,
        .phi_timestamp = 1618033989.0,
    });

    const metrics = try aggregator.compute();
    try std.testing.expect(metrics.total_events == 2);
    try std.testing.expect(std.mem.eql(u8, metrics.current_state, "Channelling"));
}
