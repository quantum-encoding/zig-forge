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


// dbus_bindings.zig - C libdbus bindings for Chronos Daemon
// Purpose: Zig FFI wrapper around libdbus C library
//
// Following Guardian Shield's proven C interop pattern (libbpf, libelf)
//
// D-Bus Service: org.jesternet.Chronos
// Object Path: /org/jesternet/Chronos
// Interface: org.jesternet.Chronos

const std = @import("std");

// Import D-Bus C library
// Note: dbus headers are in /usr/include/dbus-1.0/
// Use -I flag when compiling: zig build-exe -I/usr/include/dbus-1.0 -I/usr/lib/dbus-1.0/include -lc -ldbus-1
pub const c = @cImport({
    @cDefine("DBUS_COMPILATION", "1");
    @cInclude("dbus/dbus.h");
});

/// Manual DBusError definition (Zig @cImport treats it as opaque)
/// Matches struct in /usr/include/dbus-1.0/dbus/dbus-errors.h
pub const DBusError = extern struct {
    name: [*c]const u8,
    message: [*c]const u8,
    flags: c_uint,  // Bitfield flags (dummy1-5)
    padding1: ?*anyopaque,

    pub fn init(self: *DBusError) void {
        self.name = null;
        self.message = null;
        self.flags = 0;
        self.padding1 = null;
    }
};

/// D-Bus connection handle
pub const DBusConnection = struct {
    conn: ?*c.DBusConnection,

    pub fn init(bus_type: c_int) !DBusConnection {
        var err: DBusError = undefined;
        err.init();
        defer c.dbus_error_free(@ptrCast(&err));

        const conn = c.dbus_bus_get(@intCast(bus_type), @ptrCast(&err));
        if (c.dbus_error_is_set(@ptrCast(&err)) != 0) {
            std.debug.print("D-Bus connection error: {s}\n", .{err.message});
            return error.DBusConnectionFailed;
        }

        if (conn == null) {
            return error.DBusConnectionFailed;
        }

        return DBusConnection{ .conn = conn };
    }

    pub fn requestName(self: *DBusConnection, name: [*:0]const u8, flags: c_uint) !void {
        var err: DBusError = undefined;
        err.init();
        defer c.dbus_error_free(@ptrCast(&err));

        const result = c.dbus_bus_request_name(self.conn, name, flags, @ptrCast(&err));
        if (c.dbus_error_is_set(@ptrCast(&err)) != 0) {
            std.debug.print("D-Bus request name error: {s}\n", .{err.message});
            return error.DBusRequestNameFailed;
        }

        if (result != c.DBUS_REQUEST_NAME_REPLY_PRIMARY_OWNER) {
            std.debug.print("D-Bus name request failed: {d}\n", .{result});
            return error.DBusRequestNameFailed;
        }
    }

    pub fn readWriteDispatch(self: *DBusConnection, timeout_ms: c_int) bool {
        return c.dbus_connection_read_write_dispatch(self.conn, timeout_ms) != 0;
    }

    pub fn popMessage(self: *DBusConnection) ?*c.DBusMessage {
        return c.dbus_connection_pop_message(self.conn);
    }

    pub fn send(self: *DBusConnection, msg: *c.DBusMessage) !void {
        if (c.dbus_connection_send(self.conn, msg, null) == 0) {
            return error.DBusSendFailed;
        }
        c.dbus_connection_flush(self.conn);
    }

    pub fn deinit(self: *DBusConnection) void {
        if (self.conn) |conn| {
            c.dbus_connection_unref(conn);
        }
    }
};

/// D-Bus message wrapper
pub const DBusMessage = struct {
    msg: ?*c.DBusMessage,

    pub fn isMethodCall(self: DBusMessage, interface: [*:0]const u8, method: [*:0]const u8) bool {
        if (self.msg) |msg| {
            return c.dbus_message_is_method_call(msg, interface, method) != 0;
        }
        return false;
    }

    pub fn newMethodReturn(self: DBusMessage) ?DBusMessage {
        if (self.msg) |msg| {
            const reply = c.dbus_message_new_method_return(msg);
            return DBusMessage{ .msg = reply };
        }
        return null;
    }

    pub fn newErrorReturn(self: DBusMessage, error_name: [*:0]const u8, error_msg: [*:0]const u8) ?DBusMessage {
        if (self.msg) |msg| {
            const reply = c.dbus_message_new_error(msg, error_name, error_msg);
            return DBusMessage{ .msg = reply };
        }
        return null;
    }

    pub fn appendU64(self: *DBusMessage, value: u64) !void {
        if (self.msg) |msg| {
            var iter: c.DBusMessageIter = undefined;
            c.dbus_message_iter_init_append(msg, &iter);

            const val = value;
            if (c.dbus_message_iter_append_basic(&iter, c.DBUS_TYPE_UINT64, &val) == 0) {
                return error.DBusAppendFailed;
            }
        }
    }

    pub fn appendString(self: *DBusMessage, value: [*:0]const u8) !void {
        if (self.msg) |msg| {
            var iter: c.DBusMessageIter = undefined;
            c.dbus_message_iter_init_append(msg, &iter);

            if (c.dbus_message_iter_append_basic(&iter, c.DBUS_TYPE_STRING, @ptrCast(&value)) == 0) {
                return error.DBusAppendFailed;
            }
        }
    }

    pub fn getString(self: DBusMessage, index: usize) ?[]const u8 {
        if (self.msg) |msg| {
            var iter: c.DBusMessageIter = undefined;
            if (c.dbus_message_iter_init(msg, &iter) == 0) {
                return null;
            }

            var i: usize = 0;
            while (i < index) : (i += 1) {
                if (c.dbus_message_iter_next(&iter) == 0) {
                    return null;
                }
            }

            var str_ptr: [*:0]const u8 = undefined;
            c.dbus_message_iter_get_basic(&iter, @ptrCast(&str_ptr));
            return std.mem.span(str_ptr);
        }
        return null;
    }

    pub fn getU32(self: DBusMessage, index: usize) ?u32 {
        if (self.msg) |msg| {
            var iter: c.DBusMessageIter = undefined;
            if (c.dbus_message_iter_init(msg, &iter) == 0) {
                return null;
            }

            var i: usize = 0;
            while (i < index) : (i += 1) {
                if (c.dbus_message_iter_next(&iter) == 0) {
                    return null;
                }
            }

            var value: u32 = undefined;
            c.dbus_message_iter_get_basic(&iter, &value);
            return value;
        }
        return null;
    }

    pub fn unref(self: *DBusMessage) void {
        if (self.msg) |msg| {
            c.dbus_message_unref(msg);
        }
    }
};

/// D-Bus constants
pub const BusType = struct {
    pub const SYSTEM = c.DBUS_BUS_SYSTEM;
    pub const SESSION = c.DBUS_BUS_SESSION;
};

pub const NameFlags = struct {
    pub const ALLOW_REPLACEMENT = c.DBUS_NAME_FLAG_ALLOW_REPLACEMENT;
    pub const REPLACE_EXISTING = c.DBUS_NAME_FLAG_REPLACE_EXISTING;
    pub const DO_NOT_QUEUE = c.DBUS_NAME_FLAG_DO_NOT_QUEUE;
};

pub const ErrorName = struct {
    pub const FAILED = "org.jesternet.Chronos.Error.Failed";
    pub const INVALID_ARGS = "org.jesternet.Chronos.Error.InvalidArgs";
};
