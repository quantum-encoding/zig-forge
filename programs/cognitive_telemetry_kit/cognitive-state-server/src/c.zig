//! Hand bindings for the subset of sqlite3.h, sys/inotify.h and dbus/dbus.h used
//! by cognitive-state-server. Replaces `@cImport` (removed in Zig 0.17); the
//! prototypes match libsqlite3 / glibc / libdbus-1, so call sites are unchanged.
const std = @import("std");

// ── sqlite3.h ────────────────────────────────────────────────────────────────
pub const sqlite3 = opaque {};
pub const sqlite3_stmt = opaque {};

pub const SQLITE_OK: c_int = 0;
pub const SQLITE_ROW: c_int = 100;
pub const SQLITE_NULL: c_int = 5;
pub const SQLITE_OPEN_READONLY: c_int = 0x00000001;
pub const SQLITE_OPEN_SHAREDCACHE: c_int = 0x00020000;

pub extern "c" fn sqlite3_open_v2(filename: [*c]const u8, ppDb: [*c]?*sqlite3, flags: c_int, zVfs: [*c]const u8) c_int;
pub extern "c" fn sqlite3_close(db: ?*sqlite3) c_int;
pub extern "c" fn sqlite3_busy_timeout(db: ?*sqlite3, ms: c_int) c_int;
pub extern "c" fn sqlite3_prepare_v2(db: ?*sqlite3, zSql: [*c]const u8, nByte: c_int, ppStmt: [*c]?*sqlite3_stmt, pzTail: [*c][*c]const u8) c_int;
pub extern "c" fn sqlite3_step(stmt: ?*sqlite3_stmt) c_int;
pub extern "c" fn sqlite3_finalize(stmt: ?*sqlite3_stmt) c_int;
pub extern "c" fn sqlite3_column_int(stmt: ?*sqlite3_stmt, iCol: c_int) c_int;
pub extern "c" fn sqlite3_column_type(stmt: ?*sqlite3_stmt, iCol: c_int) c_int;
pub extern "c" fn sqlite3_column_text(stmt: ?*sqlite3_stmt, iCol: c_int) [*c]const u8;

// ── sys/inotify.h (glibc; constants per-arch from std) ───────────────────────
pub const inotify_init1 = std.c.inotify_init1;
pub const inotify_add_watch = std.c.inotify_add_watch;
pub const IN_NONBLOCK = std.os.linux.IN.NONBLOCK;
pub const IN_MODIFY = std.os.linux.IN.MODIFY;
pub const IN_CLOSE_WRITE = std.os.linux.IN.CLOSE_WRITE;

// ── dbus/dbus.h ──────────────────────────────────────────────────────────────
pub const dbus_bool_t = u32;
pub const dbus_uint32_t = u32;
pub const DBusConnection = opaque {};
pub const DBusMessage = opaque {};
pub const DBusError = opaque {}; // only ever passed as NULL here
/// Layout of `struct DBusMessageIter` (dbus-message.h); stack-allocated by callers.
pub const DBusMessageIter = extern struct {
    dummy1: ?*anyopaque,
    dummy2: ?*anyopaque,
    dummy3: dbus_uint32_t,
    dummy4: c_int,
    dummy5: c_int,
    dummy6: c_int,
    dummy7: c_int,
    dummy8: c_int,
    dummy9: c_int,
    dummy10: c_int,
    dummy11: c_int,
    pad1: c_int,
    pad2: ?*anyopaque,
    pad3: ?*anyopaque,
};

pub const DBusBusType = c_uint;
pub const DBUS_BUS_SESSION: c_int = 0;
pub const DBUS_NAME_FLAG_REPLACE_EXISTING = 0x2;
pub const DBUS_REQUEST_NAME_REPLY_PRIMARY_OWNER = 1;
pub const DBUS_TYPE_STRING: c_int = 's';

pub extern "c" fn dbus_bus_get(type: DBusBusType, @"error": ?*DBusError) ?*DBusConnection;
pub extern "c" fn dbus_bus_request_name(connection: ?*DBusConnection, name: [*c]const u8, flags: c_uint, @"error": ?*DBusError) c_int;
pub extern "c" fn dbus_connection_read_write_dispatch(connection: ?*DBusConnection, timeout_milliseconds: c_int) dbus_bool_t;
pub extern "c" fn dbus_connection_pop_message(connection: ?*DBusConnection) ?*DBusMessage;
pub extern "c" fn dbus_connection_send(connection: ?*DBusConnection, message: ?*DBusMessage, client_serial: [*c]dbus_uint32_t) dbus_bool_t;
pub extern "c" fn dbus_connection_flush(connection: ?*DBusConnection) void;
pub extern "c" fn dbus_connection_unref(connection: ?*DBusConnection) void;
pub extern "c" fn dbus_message_unref(message: ?*DBusMessage) void;
pub extern "c" fn dbus_message_is_method_call(message: ?*DBusMessage, iface: [*c]const u8, method: [*c]const u8) dbus_bool_t;
pub extern "c" fn dbus_message_new_method_return(method_call: ?*DBusMessage) ?*DBusMessage;
pub extern "c" fn dbus_message_new_error(reply_to: ?*DBusMessage, error_name: [*c]const u8, error_message: [*c]const u8) ?*DBusMessage;
pub extern "c" fn dbus_message_iter_init(message: ?*DBusMessage, iter: [*c]DBusMessageIter) dbus_bool_t;
pub extern "c" fn dbus_message_iter_init_append(message: ?*DBusMessage, iter: [*c]DBusMessageIter) void;
pub extern "c" fn dbus_message_iter_append_basic(iter: [*c]DBusMessageIter, type: c_int, value: ?*const anyopaque) dbus_bool_t;
pub extern "c" fn dbus_message_iter_get_basic(iter: [*c]DBusMessageIter, value: ?*anyopaque) void;
