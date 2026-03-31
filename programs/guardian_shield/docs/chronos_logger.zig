// chronos_logger.zig - Simple Chronos Integration for Agents
// Purpose: One-line function calls to timestamp agent activities

const std = @import("std");
const client = @import("chronos_client_dbus.zig");
const dbus = @import("dbus_bindings.zig");

/// Simple Chronos logger for agents
pub const ChronosLogger = struct {
    client: client.ChronosClient,
    agent_id: []const u8,
    allocator: std.mem.Allocator,

    /// Connect and identify agent
    pub fn init(allocator: std.mem.Allocator, agent_id: []const u8) !ChronosLogger {
        const chronos = try client.ChronosClient.connect(allocator, dbus.BusType.SYSTEM);
        
        return ChronosLogger{
            .client = chronos,
            .agent_id = agent_id,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ChronosLogger) void {
        self.client.disconnect();
    }

    /// Generate a Phi timestamp (UTC::AGENT::TICK)
    pub fn stamp(self: *ChronosLogger) ![]u8 {
        return try self.client.getPhiTimestamp(self.agent_id);
    }

    /// Log an event with automatic Phi timestamp
    /// Returns: Phi timestamp
    pub fn log(self: *ChronosLogger, action: []const u8, status: []const u8, details: []const u8) ![]u8 {
        const timestamp = try self.stamp();
        errdefer self.allocator.free(timestamp);

        // Print to stderr for immediate visibility
        std.debug.print("[{s}] {s}: {s} - {s}\n", .{ timestamp, self.agent_id, action, status });
        
        return timestamp;
    }

    /// Simple success log
    pub fn success(self: *ChronosLogger, action: []const u8) ![]u8 {
        return try self.log(action, "SUCCESS", "");
    }

    /// Simple failure log
    pub fn failure(self: *ChronosLogger, action: []const u8, error_msg: []const u8) ![]u8 {
        return try self.log(action, "FAILURE", error_msg);
    }

    /// Start activity (returns start timestamp)
    pub fn start(self: *ChronosLogger, activity: []const u8) ![]u8 {
        return try self.log(activity, "START", "");
    }

    /// Complete activity (returns completion timestamp)
    pub fn complete(self: *ChronosLogger, activity: []const u8) ![]u8 {
        return try self.log(activity, "COMPLETE", "");
    }
};

/// Convenience function: One-line timestamp generation
pub fn stamp(agent_id: []const u8) ![]u8 {
    const allocator = std.heap.c_allocator;

    var logger = try ChronosLogger.init(allocator, agent_id);
    defer logger.deinit();

    return try logger.stamp();
}

/// Convenience function: One-line event logging
pub fn log(agent_id: []const u8, action: []const u8, status: []const u8) !void {
    const allocator = std.heap.c_allocator;

    var logger = try ChronosLogger.init(allocator, agent_id);
    defer logger.deinit();

    const timestamp = try logger.log(action, status, "");
    defer allocator.free(timestamp);
}
