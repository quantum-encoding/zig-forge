//! Shared types for zig-code-query library
//!
//! Contains all data structures used across modules: configuration,
//! database records, query results, ingestion types, and C FFI types.

const std = @import("std");

// =============================================================================
// Configuration
// =============================================================================

pub const Config = struct {
    url: []const u8 = "http://127.0.0.1:8000/sql",
    auth: []const u8 = "Basic cm9vdDpyb290",
    ns: []const u8 = "zig",
    db: []const u8 = "stdlib_016",
    function_table: []const u8 = "code_function",
    calls_table: []const u8 = "code_calls",
};

// =============================================================================
// Database Records
// =============================================================================

pub const FunctionRecord = struct {
    name: []const u8 = "",
    file: []const u8 = "",
    line_start: i64 = 0,
    line_end: i64 = 0,
    code: []const u8 = "",
};

pub const CallRecord = struct {
    name: []const u8 = "",
    file: []const u8 = "",
    line_start: i64 = 0,
};

pub const Document = struct {
    id: []const u8 = "",
    path: []const u8 = "",
    name: []const u8 = "",
    extension: []const u8 = "",
    size: i64 = 0,
    content_hash: []const u8 = "",
    ingested_at: []const u8 = "",
};

pub const Chunk = struct {
    document_id: []const u8 = "",
    chunk_index: i64 = 0,
    content: []const u8 = "",
    byte_offset: i64 = 0,
    byte_len: i64 = 0,
};

// =============================================================================
// Result Types
// =============================================================================

pub fn QueryResult(comptime T: type) type {
    return struct {
        items: []T,
        total_count: usize,
        allocator: std.mem.Allocator,

        const Self = @This();

        pub fn deinit(self: *Self) void {
            self.allocator.free(self.items);
        }

        pub fn empty(allocator: std.mem.Allocator) Self {
            return .{
                .items = &.{},
                .total_count = 0,
                .allocator = allocator,
            };
        }
    };
}

pub const ContextResult = struct {
    func: FunctionRecord = .{},
    callers: []CallRecord = &.{},
    callees: []CallRecord = &.{},
    found: bool = false,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *ContextResult) void {
        if (self.callers.len > 0) self.allocator.free(self.callers);
        if (self.callees.len > 0) self.allocator.free(self.callees);
    }
};

pub const StatsResult = struct {
    function_count: i64 = 0,
    edge_count: i64 = 0,
    document_count: i64 = 0,
    chunk_count: i64 = 0,
    ns: []const u8 = "",
    db: []const u8 = "",
};

pub const IngestResult = struct {
    documents_created: usize = 0,
    chunks_created: usize = 0,
    documents_skipped: usize = 0,
    errors: usize = 0,
};

pub const IngestOptions = struct {
    extensions: ?[]const []const u8 = null,
    chunk_size: usize = 4096,
    overlap: usize = 256,
    recursive: bool = true,
};

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

    pub fn toConfig(self: *const CConfig) Config {
        return .{
            .url = if (self.url.len > 0) self.url.toSlice() else "http://127.0.0.1:8000/sql",
            .auth = if (self.auth.len > 0) self.auth.toSlice() else "Basic cm9vdDpyb290",
            .ns = if (self.ns.len > 0) self.ns.toSlice() else "zig",
            .db = if (self.db.len > 0) self.db.toSlice() else "stdlib_016",
        };
    }
};

pub const CIngestOptions = extern struct {
    chunk_size: u32 = 4096,
    overlap: u32 = 256,
    recursive: bool = true,
    extensions: ?[*]const CString = null,
    extensions_count: u32 = 0,

    pub fn toOptions(self: *const CIngestOptions) IngestOptions {
        return .{
            .chunk_size = self.chunk_size,
            .overlap = self.overlap,
            .recursive = self.recursive,
            .extensions = null, // C callers use extensions filter differently
        };
    }
};

pub const CIngestResult = extern struct {
    documents_created: u32 = 0,
    chunks_created: u32 = 0,
    documents_skipped: u32 = 0,
    errors: u32 = 0,
    success: bool = false,
    error_code: i32 = 0,
    error_message: CString = .{},
};

pub const CStatsResult = extern struct {
    function_count: i64 = 0,
    edge_count: i64 = 0,
    document_count: i64 = 0,
    chunk_count: i64 = 0,
    success: bool = false,
    error_code: i32 = 0,
    error_message: CString = .{},
};

pub const CQueryResult = extern struct {
    json_data: CString = .{},
    total_count: u32 = 0,
    success: bool = false,
    error_code: i32 = 0,
    error_message: CString = .{},
};

pub const CDocumentList = extern struct {
    json_data: CString = .{},
    count: u32 = 0,
    success: bool = false,
    error_code: i32 = 0,
    error_message: CString = .{},
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
    pub const NOT_FOUND: i32 = 7;
    pub const UNKNOWN_ERROR: i32 = -1;
};

// Opaque handle for C consumers
pub const CCodeQuery = opaque {};
