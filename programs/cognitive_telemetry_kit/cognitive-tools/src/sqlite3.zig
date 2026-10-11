//! Hand bindings for the subset of sqlite3.h used by cognitive-tools.
//! Replaces `@cImport(@cInclude("sqlite3.h"))` (removed in Zig 0.17); the
//! prototypes match what translate-c produced, so call sites are unchanged.

pub const sqlite3 = opaque {};
pub const sqlite3_stmt = opaque {};
pub const sqlite3_destructor_type = ?*const fn (?*anyopaque) callconv(.c) void;

pub const SQLITE_OK: c_int = 0;
pub const SQLITE_ROW: c_int = 100;
pub const SQLITE_OPEN_READONLY: c_int = 0x00000001;
pub const SQLITE_OPEN_URI: c_int = 0x00000040;
pub const SQLITE_OPEN_SHAREDCACHE: c_int = 0x00020000;

pub extern "c" fn sqlite3_open_v2(filename: [*c]const u8, ppDb: [*c]?*sqlite3, flags: c_int, zVfs: [*c]const u8) c_int;
pub extern "c" fn sqlite3_close(db: ?*sqlite3) c_int;
pub extern "c" fn sqlite3_busy_timeout(db: ?*sqlite3, ms: c_int) c_int;
pub extern "c" fn sqlite3_prepare_v2(db: ?*sqlite3, zSql: [*c]const u8, nByte: c_int, ppStmt: [*c]?*sqlite3_stmt, pzTail: [*c][*c]const u8) c_int;
pub extern "c" fn sqlite3_step(stmt: ?*sqlite3_stmt) c_int;
pub extern "c" fn sqlite3_finalize(stmt: ?*sqlite3_stmt) c_int;
pub extern "c" fn sqlite3_bind_int(stmt: ?*sqlite3_stmt, idx: c_int, value: c_int) c_int;
pub extern "c" fn sqlite3_bind_int64(stmt: ?*sqlite3_stmt, idx: c_int, value: c_longlong) c_int;
pub extern "c" fn sqlite3_bind_text(stmt: ?*sqlite3_stmt, idx: c_int, text: [*c]const u8, n: c_int, destructor: sqlite3_destructor_type) c_int;
pub extern "c" fn sqlite3_column_int(stmt: ?*sqlite3_stmt, iCol: c_int) c_int;
pub extern "c" fn sqlite3_column_int64(stmt: ?*sqlite3_stmt, iCol: c_int) c_longlong;
pub extern "c" fn sqlite3_column_text(stmt: ?*sqlite3_stmt, iCol: c_int) [*c]const u8;
