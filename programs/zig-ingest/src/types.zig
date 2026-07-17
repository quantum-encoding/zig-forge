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
///
/// The result is used verbatim as the text of a backtick-quoted SurrealDB
/// record id (`code_function:`{s}``), so it must never contain a byte that can
/// break out of that quoting. Every non-`[A-Za-z0-9_]` byte is mapped to `_`;
/// a path component containing a backtick, quote, `;`, etc. can therefore no
/// longer terminate the record id and inject SurrealQL.
pub fn makeQualifiedId(allocator: Allocator, file: []const u8, name: []const u8) ![]u8 {
    var result: std.ArrayList(u8) = .empty;

    for (file) |c| {
        if (std.ascii.isAlphanumeric(c)) {
            try result.append(allocator, c);
        } else {
            try result.append(allocator, '_');
        }
    }

    // Remove trailing _zig if present
    if (result.items.len >= 4 and std.mem.eql(u8, result.items[result.items.len - 4 ..], "_zig")) {
        result.shrinkRetainingCapacity(result.items.len - 4);
    }

    try result.append(allocator, '_');
    for (name) |c| {
        if (std.ascii.isAlphanumeric(c)) {
            try result.append(allocator, c);
        } else {
            try result.append(allocator, '_');
        }
    }

    return result.toOwnedSlice(allocator);
}

/// Restrict a SurrealDB record-id fragment to `[A-Za-z0-9_]`, mapping every
/// other byte to `_`. Applied at every point where a value is interpolated into
/// a backtick-quoted `code_function:`...`` record id, so no id (function
/// qualified_id, call caller_id, or call callee) can escape the quoting and
/// inject SurrealQL. Idempotent over already-sanitized `makeQualifiedId` output.
pub fn sanitizeRecordId(allocator: Allocator, s: []const u8) ![]u8 {
    var result: std.ArrayList(u8) = .empty;
    for (s) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '_') {
            try result.append(allocator, c);
        } else {
            try result.append(allocator, '_');
        }
    }
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
// Tests (adversarial: SurrealQL-injection fixtures for the emitter)
// =============================================================================

test "escapeString neutralizes single quotes, backslashes, and newlines" {
    const a = std.testing.allocator;
    // Raw input: O'Brien \ <newline> end  (the '\\' and '\n' are Zig escapes).
    const out = try escapeString(a, "O'Brien \\ \n end");
    defer a.free(out);
    try std.testing.expectEqualStrings("O\\'Brien \\\\ \\n end", out);
}

test "escapeString defuses a quoted-literal SurrealQL breakout" {
    const a = std.testing.allocator;
    // Attacker-controlled 'file' value trying to close the '...' literal and
    // append a destructive statement. After escaping, the quote is inert.
    const out = try escapeString(a, "x'; DELETE code_function; --");
    defer a.free(out);
    // No raw single-quote may survive except as the escaped \' sequence.
    var j: usize = 0;
    while (j < out.len) : (j += 1) {
        if (out[j] == '\'') {
            try std.testing.expect(j > 0 and out[j - 1] == '\\');
        }
    }
    try std.testing.expectEqualStrings("x\\'; DELETE code_function; --", out);
}

test "makeQualifiedId restricts record-id text to [A-Za-z0-9_]" {
    const a = std.testing.allocator;
    // Malicious path with a backtick breakout and a quote must not survive.
    const out = try makeQualifiedId(a, "evil`; DELETE code_function; --.zig", "init");
    defer a.free(out);
    for (out) |c| {
        try std.testing.expect(std.ascii.isAlphanumeric(c) or c == '_');
    }
    // Trailing "_zig" stripped, name appended after '_'.
    try std.testing.expect(std.mem.endsWith(u8, out, "_init"));
}

test "makeQualifiedId preserves the benign path shape" {
    const a = std.testing.allocator;
    const out = try makeQualifiedId(a, "crypto/aegis.zig", "init");
    defer a.free(out);
    try std.testing.expectEqualStrings("crypto_aegis_init", out);
}

test "sanitizeRecordId maps every non-word byte to underscore" {
    const a = std.testing.allocator;
    const out = try sanitizeRecordId(a, "abc`def'gh->ij");
    defer a.free(out);
    try std.testing.expectEqualStrings("abc_def_gh__ij", out);
}

test "sanitizeRecordId is idempotent over makeQualifiedId output" {
    const a = std.testing.allocator;
    const id = try makeQualifiedId(a, "some/weird`path.zig", "run");
    defer a.free(id);
    const again = try sanitizeRecordId(a, id);
    defer a.free(again);
    try std.testing.expectEqualStrings(id, again);
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
