//! Guardian Shield - eBPF-based System Security Framework
//!
//! Copyright (c) 2025 Richard Tune / Quantum Encoding Ltd
//! Author: Richard Tune
//! Contact: info@quantumencoding.io
//! Website: https://quantumencoding.io
//!
//! License: Dual License - MIT (Non-Commercial) / Commercial License
//!
//! NON-COMMERCIAL USE (MIT License):
//! Permission is hereby granted, free of charge, to any person obtaining a copy
//! of this software and associated documentation files (the "Software"), to deal
//! in the Software without restriction for NON-COMMERCIAL purposes, including
//! without limitation the rights to use, copy, modify, merge, publish, distribute,
//! sublicense, and/or sell copies of the Software for non-commercial purposes,
//! and to permit persons to whom the Software is furnished to do so, subject to
//! the following conditions:
//!
//! The above copyright notice and this permission notice shall be included in all
//! copies or substantial portions of the Software.
//!
//! THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//! IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//! FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//! AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//! LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//! OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
//! SOFTWARE.
//!
//! COMMERCIAL USE:
//! Commercial use of this software requires a separate commercial license.
//! Contact info@quantumencoding.io for commercial licensing terms.


// conductor-dbus-bridge.zig - The Conductor's Strategic Intelligence Bridge
// Purpose: Expose behavioral alerts and strategic intelligence over D-Bus
// Doctrine: "From The Conductor's Mind to The Sentinel's Cockpit"
//
// D-Bus Interface:
//   Service: org.jesternet.Conductor
//   Path: /org/jesternet/Conductor
//   Interface: org.jesternet.Conductor.StrategicIntelligence
//
// Signals:
//   BehavioralAlert(rule_id, description, severity, pid, timestamp, details)
//   ProcessChainUpdate(pid, parent_pid, execution_count, suspicious_patterns)
//   SystemStatus(active_rules, events_processed, process_chains_tracked)

const std = @import("std");
const dbus = @import("dbus_interface.zig");
const conductor_daemon = @import("conductor-daemon.zig");

const c = @cImport({
    @cInclude("dbus/dbus.h");
});

/// D-Bus Bridge for The Conductor's Strategic Intelligence
pub const ConductorDBusBridge = struct {
    connection: *c.DBusConnection,
    allocator: std.mem.Allocator,
    conductor: *conductor_daemon.ConductorDaemon,

    pub fn init(allocator: std.mem.Allocator, conductor: *conductor_daemon.ConductorDaemon) !ConductorDBusBridge {
        // DBusError is opaque in cimport, use aligned byte buffer
        var dbus_error_buf: [64]u8 align(@alignOf(usize)) = undefined;
        const dbus_error: *c.DBusError = @ptrCast(&dbus_error_buf);
        c.dbus_error_init(dbus_error);

        // Connect to system bus
        const connection = c.dbus_bus_get(c.DBUS_BUS_SYSTEM, dbus_error) orelse {
            std.debug.print("ℹ️  D-Bus system bus not available\n", .{});
            std.debug.print("   This is optional - conductor-daemon works standalone\n", .{});
            std.debug.print("   To enable: Ensure D-Bus system daemon is running\n", .{});
            c.dbus_error_free(dbus_error);
            return error.DBusConnectionFailed;
        };

        // Request service name
        const ret = c.dbus_bus_request_name(
            connection,
            "org.jesternet.Conductor",
            c.DBUS_NAME_FLAG_REPLACE_EXISTING,
            dbus_error
        );

        if (ret != c.DBUS_REQUEST_NAME_REPLY_PRIMARY_OWNER) {
            std.debug.print("ℹ️  Could not acquire D-Bus name (may already be in use)\n", .{});
            std.debug.print("   This is optional - use conductor-daemon for standalone operation\n", .{});
            c.dbus_error_free(dbus_error);
            c.dbus_connection_unref(connection);
            return error.DBusNameFailed;
        }

        std.debug.print("🔗 Conductor D-Bus Bridge connected to system bus\n", .{});
        std.debug.print("   Service: org.jesternet.Conductor\n", .{});
        std.debug.print("   Path: /org/jesternet/Conductor\n", .{});

        return ConductorDBusBridge{
            .connection = connection,
            .allocator = allocator,
            .conductor = conductor,
        };
    }

    pub fn deinit(self: *ConductorDBusBridge) void {
        c.dbus_connection_unref(self.connection);
        std.debug.print("🔗 Conductor D-Bus Bridge disconnected\n", .{});
    }

    /// Emit behavioral alert signal
    pub fn emitBehavioralAlert(
        self: *ConductorDBusBridge,
        rule_id: []const u8,
        description: []const u8,
        severity: []const u8,
        pid: u32,
        timestamp: []const u8,
        details: []const u8
    ) !void {
        const message: *c.DBusMessage = c.dbus_message_new_signal(
            "/org/jesternet/Conductor",
            "org.jesternet.Conductor.StrategicIntelligence",
            "BehavioralAlert"
        ) orelse return error.MessageCreationFailed;

        // Add parameters: rule_id, description, severity, pid, timestamp, details
        var iter: c.DBusMessageIter = undefined;
        c.dbus_message_iter_init_append(message, &iter);

        // rule_id (string)
        try self.appendString(&iter, rule_id);

        // description (string)
        try self.appendString(&iter, description);

        // severity (string)
        try self.appendString(&iter, severity);

        // pid (uint32)
        var pid_value: u32 = pid;
        if (c.dbus_message_iter_append_basic(&iter, c.DBUS_TYPE_UINT32, &pid_value) == 0) {
            return error.AppendFailed;
        }

        // timestamp (string)
        try self.appendString(&iter, timestamp);

        // details (string)
        try self.appendString(&iter, details);

        // Send the signal
        var serial: c.dbus_uint32_t = undefined;
        if (c.dbus_connection_send(self.connection, message, &serial) == 0) {
            c.dbus_message_unref(message);
            return error.SendFailed;
        }

        c.dbus_connection_flush(self.connection);
        c.dbus_message_unref(message);

        std.debug.print("📡 D-Bus Signal: BehavioralAlert - {s} (PID: {d})\n", .{rule_id, pid});
    }

    /// Emit process chain update signal
    pub fn emitProcessChainUpdate(
        self: *ConductorDBusBridge,
        pid: u32,
        parent_pid: u32,
        execution_count: u32,
        suspicious_patterns: u32
    ) !void {
        const message: *c.DBusMessage = c.dbus_message_new_signal(
            "/org/jesternet/Conductor",
            "org.jesternet.Conductor.StrategicIntelligence",
            "ProcessChainUpdate"
        ) orelse return error.MessageCreationFailed;

        var iter: c.DBusMessageIter = undefined;
        c.dbus_message_iter_init_append(message, &iter);

        // pid (uint32)
        var pid_value: u32 = pid;
        if (c.dbus_message_iter_append_basic(&iter, c.DBUS_TYPE_UINT32, &pid_value) == 0) {
            return error.AppendFailed;
        }

        // parent_pid (uint32)
        var parent_pid_value: u32 = parent_pid;
        if (c.dbus_message_iter_append_basic(&iter, c.DBUS_TYPE_UINT32, &parent_pid_value) == 0) {
            return error.AppendFailed;
        }

        // execution_count (uint32)
        var execution_count_value: u32 = execution_count;
        if (c.dbus_message_iter_append_basic(&iter, c.DBUS_TYPE_UINT32, &execution_count_value) == 0) {
            return error.AppendFailed;
        }

        // suspicious_patterns (uint32)
        var suspicious_patterns_value: u32 = suspicious_patterns;
        if (c.dbus_message_iter_append_basic(&iter, c.DBUS_TYPE_UINT32, &suspicious_patterns_value) == 0) {
            return error.AppendFailed;
        }

        var serial: c.dbus_uint32_t = undefined;
        if (c.dbus_connection_send(self.connection, message, &serial) == 0) {
            c.dbus_message_unref(message);
            return error.SendFailed;
        }

        c.dbus_connection_flush(self.connection);
        c.dbus_message_unref(message);

        std.debug.print("📡 D-Bus Signal: ProcessChainUpdate - PID: {d} (Executions: {d})\n", .{pid, execution_count});
    }

    /// Emit system status signal
    pub fn emitSystemStatus(
        self: *ConductorDBusBridge,
        active_rules: u32,
        events_processed: u32,
        process_chains_tracked: u32
    ) !void {
        const message: *c.DBusMessage = c.dbus_message_new_signal(
            "/org/jesternet/Conductor",
            "org.jesternet.Conductor.StrategicIntelligence",
            "SystemStatus"
        ) orelse return error.MessageCreationFailed;

        var iter: c.DBusMessageIter = undefined;
        c.dbus_message_iter_init_append(message, &iter);

        // active_rules (uint32)
        var active_rules_value: u32 = active_rules;
        if (c.dbus_message_iter_append_basic(&iter, c.DBUS_TYPE_UINT32, &active_rules_value) == 0) {
            return error.AppendFailed;
        }

        // events_processed (uint32)
        var events_processed_value: u32 = events_processed;
        if (c.dbus_message_iter_append_basic(&iter, c.DBUS_TYPE_UINT32, &events_processed_value) == 0) {
            return error.AppendFailed;
        }

        // process_chains_tracked (uint32)
        var process_chains_tracked_value: u32 = process_chains_tracked;
        if (c.dbus_message_iter_append_basic(&iter, c.DBUS_TYPE_UINT32, &process_chains_tracked_value) == 0) {
            return error.AppendFailed;
        }

        var serial: c.dbus_uint32_t = undefined;
        if (c.dbus_connection_send(self.connection, message, &serial) == 0) {
            c.dbus_message_unref(message);
            return error.SendFailed;
        }

        c.dbus_connection_flush(self.connection);
        c.dbus_message_unref(message);

        std.debug.print("📡 D-Bus Signal: SystemStatus - Rules: {d}, Events: {d}, Chains: {d}\n", .{
            active_rules, events_processed, process_chains_tracked
        });
    }

    /// Helper function to append string to D-Bus message
    fn appendString(self: *ConductorDBusBridge, iter: *c.DBusMessageIter, str: []const u8) !void {
        _ = self;
        const c_str = str.ptr;
        if (c.dbus_message_iter_append_basic(iter, c.DBUS_TYPE_STRING, @ptrCast(&c_str)) == 0) {
            return error.AppendFailed;
        }
    }

    /// Process behavioral alert and emit D-Bus signal
    pub fn processBehavioralAlert(
        self: *ConductorDBusBridge,
        rule: conductor_daemon.BehavioralCorrelation.CorrelationRule,
        match_count: u32,
        trigger_event: *conductor_daemon.OracleEvent
    ) !void {
        const timestamp = try self.conductor.logger.stamp();
        defer self.allocator.free(timestamp);

        // Determine severity based on rule type
        const severity = if (std.mem.eql(u8, rule.rule_id, "RAPID_EXECUTION"))
            "CRITICAL"
        else if (std.mem.eql(u8, rule.rule_id, "SENSITIVE_FILE_ACCESS"))
            "HIGH"
        else
            "MEDIUM";

        const details = try std.fmt.allocPrint(self.allocator,
            "Matches: {d}, PID: {d}, Command: '{s}'", .{
                match_count,
                trigger_event.pid,
                std.mem.sliceTo(&trigger_event.comm, 0)
            });
        defer self.allocator.free(details);

        try self.emitBehavioralAlert(
            rule.rule_id,
            rule.description,
            severity,
            trigger_event.pid,
            timestamp,
            details
        );
    }
};

/// Test the D-Bus bridge
pub fn main() !void {
    const allocator = std.heap.c_allocator;

    std.debug.print("🧠 TESTING CONDUCTOR D-BUS BRIDGE\n", .{});
    std.debug.print("=" ** 60 ++ "\n", .{});

    // Initialize conductor daemon
    var conductor = try conductor_daemon.ConductorDaemon.init(allocator);
    defer conductor.deinit();

    // Initialize D-Bus bridge
    var bridge = try ConductorDBusBridge.init(allocator, &conductor);
    defer bridge.deinit();

    // Test signal emission
    std.debug.print("📡 Testing D-Bus signal emission...\n", .{});

    // Test behavioral alert
    try bridge.emitBehavioralAlert(
        "RAPID_EXECUTION",
        "Rapid program execution - potential fork bomb or malware",
        "CRITICAL",
        1234,
        "2025-10-20T10:40:49.895933816Z::conductor-daemon::TICK-0000000024",
        "Matches: 11, PID: 1234, Command: 'test-target'"
    );

    // Test process chain update
    try bridge.emitProcessChainUpdate(1234, 5678, 5, 2);

    // Test system status
    try bridge.emitSystemStatus(4, 19, 14);

    std.debug.print("✅ D-Bus bridge test completed successfully\n", .{});
    std.debug.print("=" ** 60 ++ "\n", .{});
}
