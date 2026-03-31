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


// chronos_client_dbus.zig - Chronos Client using D-Bus IPC
// Purpose: Client library for applications to access Chronos daemon via D-Bus
//
// Replaces Unix socket IPC with D-Bus method calls

const std = @import("std");
const dbus = @import("dbus_bindings.zig");
const dbus_if = @import("dbus_interface.zig");

/// Chronos Client - connects to chronosd via D-Bus
pub const ChronosClient = struct {
    conn: dbus.DBusConnection,
    allocator: std.mem.Allocator,
    bus_type: c_int,

    /// Connect to Chronos daemon via D-Bus
    /// For production: use BusType.SYSTEM
    /// For testing: use BusType.SESSION
    pub fn connect(allocator: std.mem.Allocator, bus_type: c_int) !ChronosClient {
        const conn = try dbus.DBusConnection.init(bus_type);

        return ChronosClient{
            .conn = conn,
            .allocator = allocator,
            .bus_type = bus_type,
        };
    }

    pub fn disconnect(self: *ChronosClient) void {
        self.conn.deinit();
    }

    /// Get current tick (non-destructive read)
    pub fn getTick(self: *ChronosClient) !u64 {
        // Create method call message
        const msg = dbus.c.dbus_message_new_method_call(
            dbus_if.DBUS_SERVICE,
            dbus_if.DBUS_PATH,
            dbus_if.DBUS_INTERFACE,
            "GetTick",
        );
        defer dbus.c.dbus_message_unref(msg);

        // Send and wait for reply
        var err: dbus.DBusError = undefined;
        err.init();
        defer dbus.c.dbus_error_free(@ptrCast(&err));

        const reply = dbus.c.dbus_connection_send_with_reply_and_block(
            self.conn.conn,
            msg,
            -1, // default timeout
            @ptrCast(&err),
        );

        if (dbus.c.dbus_error_is_set(@ptrCast(&err)) != 0) {
            std.debug.print("D-Bus call error: {s}\n", .{err.message});
            return error.DBusCallFailed;
        }

        defer dbus.c.dbus_message_unref(reply);

        // Parse reply
        var iter: dbus.c.DBusMessageIter = undefined;
        if (dbus.c.dbus_message_iter_init(reply, &iter) == 0) {
            return error.DBusParseError;
        }

        var tick: u64 = undefined;
        dbus.c.dbus_message_iter_get_basic(&iter, @ptrCast(&tick));
        return tick;
    }

    /// Increment and return next tick
    pub fn nextTick(self: *ChronosClient) !u64 {
        const msg = dbus.c.dbus_message_new_method_call(
            dbus_if.DBUS_SERVICE,
            dbus_if.DBUS_PATH,
            dbus_if.DBUS_INTERFACE,
            "NextTick",
        );
        defer dbus.c.dbus_message_unref(msg);

        var err: dbus.DBusError = undefined;
        err.init();
        defer dbus.c.dbus_error_free(@ptrCast(&err));

        const reply = dbus.c.dbus_connection_send_with_reply_and_block(
            self.conn.conn,
            msg,
            -1,
            @ptrCast(&err),
        );

        if (dbus.c.dbus_error_is_set(@ptrCast(&err)) != 0) {
            std.debug.print("D-Bus call error: {s}\n", .{err.message});
            return error.DBusCallFailed;
        }

        defer dbus.c.dbus_message_unref(reply);

        var iter: dbus.c.DBusMessageIter = undefined;
        if (dbus.c.dbus_message_iter_init(reply, &iter) == 0) {
            return error.DBusParseError;
        }

        var tick: u64 = undefined;
        dbus.c.dbus_message_iter_get_basic(&iter, @ptrCast(&tick));
        return tick;
    }

    /// Get Phi timestamp for agent
    pub fn getPhiTimestamp(self: *ChronosClient, agent_id: []const u8) ![]u8 {
        const agent_id_z = try self.allocator.dupeZ(u8, agent_id);
        defer self.allocator.free(agent_id_z);

        const msg = dbus.c.dbus_message_new_method_call(
            dbus_if.DBUS_SERVICE,
            dbus_if.DBUS_PATH,
            dbus_if.DBUS_INTERFACE,
            "GetPhiTimestamp",
        );
        defer dbus.c.dbus_message_unref(msg);

        // Append string argument
        var args: dbus.c.DBusMessageIter = undefined;
        dbus.c.dbus_message_iter_init_append(msg, &args);
        const agent_ptr: [*:0]const u8 = agent_id_z.ptr;
        if (dbus.c.dbus_message_iter_append_basic(&args, dbus.c.DBUS_TYPE_STRING, @ptrCast(&agent_ptr)) == 0) {
            return error.DBusAppendFailed;
        }

        var err: dbus.DBusError = undefined;
        err.init();
        defer dbus.c.dbus_error_free(@ptrCast(&err));

        const reply = dbus.c.dbus_connection_send_with_reply_and_block(
            self.conn.conn,
            msg,
            -1,
            @ptrCast(&err),
        );

        if (dbus.c.dbus_error_is_set(@ptrCast(&err)) != 0) {
            std.debug.print("D-Bus call error: {s}\n", .{err.message});
            return error.DBusCallFailed;
        }

        defer dbus.c.dbus_message_unref(reply);

        var iter: dbus.c.DBusMessageIter = undefined;
        if (dbus.c.dbus_message_iter_init(reply, &iter) == 0) {
            return error.DBusParseError;
        }

        var str_ptr: [*:0]const u8 = undefined;
        dbus.c.dbus_message_iter_get_basic(&iter, @ptrCast(&str_ptr));
        
        return try self.allocator.dupe(u8, std.mem.span(str_ptr));
    }

    /// Shutdown daemon
    pub fn shutdown(self: *ChronosClient) !void {
        const msg = dbus.c.dbus_message_new_method_call(
            dbus_if.DBUS_SERVICE,
            dbus_if.DBUS_PATH,
            dbus_if.DBUS_INTERFACE,
            "Shutdown",
        );
        defer dbus.c.dbus_message_unref(msg);

        var err: dbus.DBusError = undefined;
        err.init();
        defer dbus.c.dbus_error_free(@ptrCast(&err));

        const reply = dbus.c.dbus_connection_send_with_reply_and_block(
            self.conn.conn,
            msg,
            -1,
            @ptrCast(&err),
        );

        if (dbus.c.dbus_error_is_set(@ptrCast(&err)) != 0) {
            std.debug.print("D-Bus call error: {s}\n", .{err.message});
            return error.DBusCallFailed;
        }

        if (reply) |r| {
            dbus.c.dbus_message_unref(r);
        }
    }

    /// Ping daemon (health check)
    pub fn ping(self: *ChronosClient) !bool {
        // Try GetTick as a ping - if it works, daemon is alive
        _ = self.getTick() catch return false;
        return true;
    }
};
