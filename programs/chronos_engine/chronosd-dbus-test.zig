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


// chronosd-dbus-test.zig - Session bus test version
// Uses SESSION bus instead of SYSTEM for sandbox testing

const std = @import("std");
const chronos = @import("chronos.zig");
const phi = @import("phi_timestamp.zig");
const dbus_if = @import("dbus_interface.zig");
const dbus = @import("dbus_bindings.zig");

const VERSION = "2.0.0-dbus-test";

pub const ChronosDaemon = struct {
    clock: chronos.ChronosClock,
    allocator: std.mem.Allocator,
    running: std.atomic.Value(bool),
    dbus_conn: dbus.DBusConnection,

    pub fn init(allocator: std.mem.Allocator) !ChronosDaemon {
        const clock = try chronos.ChronosClock.init(allocator, "/tmp/chronos-tick.dat");

        // Use SESSION bus for testing (no root required)
        var dbus_conn = try dbus.DBusConnection.init(dbus.BusType.SESSION);
        errdefer dbus_conn.deinit();

        try dbus_conn.requestName(
            dbus_if.DBUS_SERVICE,
            dbus.NameFlags.ALLOW_REPLACEMENT | dbus.NameFlags.REPLACE_EXISTING,
        );

        std.debug.print("🕐 Chronos Daemon v{s} starting (TEST MODE)\n", .{VERSION});
        std.debug.print("   D-Bus: SESSION bus\n", .{});
        std.debug.print("   Service: {s}\n", .{dbus_if.DBUS_SERVICE});
        std.debug.print("   Current tick: {d}\n\n", .{clock.getTick()});

        return ChronosDaemon{
            .clock = clock,
            .allocator = allocator,
            .running = std.atomic.Value(bool).init(true),
            .dbus_conn = dbus_conn,
        };
    }

    pub fn deinit(self: *ChronosDaemon) void {
        self.clock.deinit();
        self.dbus_conn.deinit();
        std.debug.print("🕐 Chronos Daemon shutdown complete\n", .{});
    }

    pub fn run(self: *ChronosDaemon) !void {
        std.debug.print("🕐 Ready for D-Bus method calls\n\n", .{});

        while (self.running.load(.acquire)) {
            if (!self.dbus_conn.readWriteDispatch(1000)) {
                std.debug.print("⚠️  D-Bus connection lost\n", .{});
                break;
            }

            while (self.dbus_conn.popMessage()) |raw_msg| {
                var msg = dbus.DBusMessage{ .msg = raw_msg };
                defer msg.unref();
                try self.handleMessage(&msg);
            }
        }
    }

    fn handleMessage(self: *ChronosDaemon, msg: *dbus.DBusMessage) !void {
        const interface = dbus_if.DBUS_INTERFACE;

        if (msg.isMethodCall(interface, "GetTick")) {
            const tick = self.clock.getTick();
            std.debug.print("📞 GetTick() -> {d}\n", .{tick});

            var reply = msg.newMethodReturn() orelse return error.DBusReplyFailed;
            defer reply.unref();

            try reply.appendU64(tick);
            try self.dbus_conn.send(reply.msg.?);
            return;
        }

        if (msg.isMethodCall(interface, "NextTick")) {
            const tick = try self.clock.nextTick();
            std.debug.print("📞 NextTick() -> {d}\n", .{tick});

            var reply = msg.newMethodReturn() orelse return error.DBusReplyFailed;
            defer reply.unref();

            try reply.appendU64(tick);
            try self.dbus_conn.send(reply.msg.?);
            return;
        }

        if (msg.isMethodCall(interface, "GetPhiTimestamp")) {
            const agent_id = msg.getString(0) orelse {
                var err_reply = msg.newErrorReturn(dbus.ErrorName.INVALID_ARGS, "Missing agent_id") orelse return;
                defer err_reply.unref();
                try self.dbus_conn.send(err_reply.msg.?);
                return;
            };

            var gen = phi.PhiGenerator.init(self.allocator, &self.clock, agent_id);
            const timestamp = try gen.next();
            const formatted = try timestamp.format(self.allocator);
            defer self.allocator.free(formatted);

            std.debug.print("📞 GetPhiTimestamp({s}) -> {s}\n", .{agent_id, formatted});

            const formatted_z = try self.allocator.dupeZ(u8, formatted);
            defer self.allocator.free(formatted_z);

            var reply = msg.newMethodReturn() orelse return error.DBusReplyFailed;
            defer reply.unref();

            try reply.appendString(formatted_z.ptr);
            try self.dbus_conn.send(reply.msg.?);
            return;
        }

        if (msg.isMethodCall(interface, "Shutdown")) {
            std.debug.print("📞 Shutdown()\n", .{});

            var reply = msg.newMethodReturn() orelse return error.DBusReplyFailed;
            try self.dbus_conn.send(reply.msg.?);
            reply.unref();

            self.shutdown();
            return;
        }

        if (msg.isMethodCall("org.freedesktop.DBus.Introspectable", "Introspect")) {
            const introspect_z = try self.allocator.dupeZ(u8, dbus_if.INTROSPECTION_XML);
            defer self.allocator.free(introspect_z);

            var reply = msg.newMethodReturn() orelse return error.DBusReplyFailed;
            defer reply.unref();

            try reply.appendString(introspect_z.ptr);
            try self.dbus_conn.send(reply.msg.?);
            return;
        }
    }

    pub fn shutdown(self: *ChronosDaemon) void {
        self.running.store(false, .release);
    }
};

pub fn main() !void {
    const allocator = std.heap.c_allocator;

    var daemon = try ChronosDaemon.init(allocator);
    defer daemon.deinit();

    try daemon.run();
}
