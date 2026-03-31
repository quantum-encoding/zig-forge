//! Shared types for zig-ingest library
//!
//! Contains all data structures used across modules: configuration,
//! function/call records, ingestion results, and C FFI types.

const std = @import("std");
const Allocator = std.mem.Allocator;

// =============================================================================
// Configuration
// =============================================================================

pub const Config = struct {
    source_dir: []const u8 = "",
    url: []const u8 = "http://127.0.0.1:8000/sql",
    auth: []const u8 = "Basic cm9vdDpyb290",
    ns: []const u8 = "zig",
    db: []const u8 = "stdlib_016",
    dry_run: bool = false,
    verbose: bool = false,
};

// =============================================================================
// Data Structures
// =============================================================================

pub const FunctionInfo = struct {
    name: []const u8,
    file: []const u8,
    qualified_id: []const u8,
    line_start: usize,
    line_end: usize,
    code: []const u8,
};

pub const CallEdge = struct {
    caller_id: []const u8,
    caller_name: []const u8,
    callee: []const u8,
};

// =============================================================================
// Result Types
// =============================================================================

pub const IngestStats = struct {
    files_processed: usize = 0,
    functions_found: usize = 0,
    calls_found: usize = 0,
    parse_errors: usize = 0,
    insert_errors: usize = 0,
};

pub const IngestResult = struct {
    stats: IngestStats = .{},
    functions_inserted: usize = 0,
    calls_inserted: usize = 0,
};

pub const ParseResult = struct {
    functions: std.ArrayList(FunctionInfo),
    calls: std.ArrayList(CallEdge),
    allocator: Allocator,

    pub fn deinit(self: *ParseResult) void {
        self.functions.deinit(self.allocator);
        self.calls.deinit(self.allocator);
    }
};

// =============================================================================
// Helpers
// =============================================================================

/// Create a qualified ID from file path and function name.
/// Example: "crypto/aegis.zig" + "init" -> "crypto_aegis_init"
pub fn makeQualifiedId(allocator: Allocator, file: []const u8, name: []const u8) ![]u8 {
    var result: std.ArrayList(u8) = .empty;

    for (file) |c| {
        switch (c) {
            '/', '.', '-' => try result.append(allocator, '_'),
            else => try result.append(allocator, c),
        }
    }

    // Remove trailing _zig if present
    if (result.items.len >= 4 and std.mem.eql(u8, result.items[result.items.len - 4 ..], "_zig")) {
        result.shrinkRetainingCapacity(result.items.len - 4);
    }

    try result.append(allocator, '_');
    try result.appendSlice(allocator, name);

    return result.toOwnedSlice(allocator);
}

/// Escape a string for SurrealQL single-quoted literals.
pub fn escapeString(allocator: Allocator, s: []const u8) ![]u8 {
    var result: std.ArrayList(u8) = .empty;
    for (s) |c| {
        switch (c) {
            '\'' => try result.appendSlice(allocator, "\\'"),
            '\\' => try result.appendSlice(allocator, "\\\\"),
            '\n' => try result.appendSlice(allocator, "\\n"),
            '\r' => try result.appendSlice(allocator, "\\r"),
            '\t' => try result.appendSlice(allocator, "\\t"),
            else => try result.append(allocator, c),
        }
    }
    return result.toOwnedSlice(allocator);
}

// =============================================================================
// C FFI Types
// =============================================================================

pub const CString = extern struct {
    ptr: ?[*:0]const u8 = null,
    len: usize = 0,

    pub fn fromSlice(s: []const u8) CString {
        if (s.len == 0) return .{ .ptr = null, .len = 0 };
        return .{ .ptr = @ptrCast(s.ptr), .len = s.len };
    }

    pub fn toSlice(self: CString) []const u8 {
        if (self.ptr) |p| {
            return p[0..self.len];
        }
        return "";
    }
};

pub const CConfig = extern struct {
    url: CString = .{},
    auth: CString = .{},
    ns: CString = .{},
    db: CString = .{},
    source_dir: CString = .{},
    dry_run: bool = false,
    verbose: bool = false,

    pub fn toConfig(self: *const CConfig) Config {
        return .{
            .url = if (self.url.len > 0) self.url.toSlice() else "http://127.0.0.1:8000/sql",
            .auth = if (self.auth.len > 0) self.auth.toSlice() else "Basic cm9vdDpyb290",
            .ns = if (self.ns.len > 0) self.ns.toSlice() else "zig",
            .db = if (self.db.len > 0) self.db.toSlice() else "stdlib_016",
            .source_dir = if (self.source_dir.len > 0) self.source_dir.toSlice() else "",
            .dry_run = self.dry_run,
            .verbose = self.verbose,
        };
    }
};

pub const CIngestResult = extern struct {
    files_processed: u32 = 0,
    functions_found: u32 = 0,
    calls_found: u32 = 0,
    parse_errors: u32 = 0,
    insert_errors: u32 = 0,
    functions_inserted: u32 = 0,
    calls_inserted: u32 = 0,
    success: bool = false,
    error_code: i32 = 0,
    error_message: CString = .{},
};

pub const CIngestStats = extern struct {
    files_processed: u32 = 0,
    functions_found: u32 = 0,
    calls_found: u32 = 0,
    parse_errors: u32 = 0,
    insert_errors: u32 = 0,
};

pub const CStringResult = extern struct {
    value: CString = .{},
    success: bool = false,
    error_code: i32 = 0,
    error_message: CString = .{},
};

pub const ErrorCode = struct {
    pub const SUCCESS: i32 = 0;
    pub const INVALID_ARGUMENT: i32 = 1;
    pub const OUT_OF_MEMORY: i32 = 2;
    pub const NETWORK_ERROR: i32 = 3;
    pub const QUERY_ERROR: i32 = 4;
    pub const PARSE_ERROR: i32 = 5;
    pub const IO_ERROR: i32 = 6;
    pub const UNKNOWN_ERROR: i32 = -1;
};

// Opaque handle for C consumers
pub const CZigIngest = opaque {};
