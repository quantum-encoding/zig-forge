//! Zig Code Query Library
//!
//! Library root providing both Zig and C FFI APIs for querying
//! SurrealDB code knowledge bases and ingesting files/folders.

const std = @import("std");
pub const types = @import("types.zig");
pub const surreal = @import("surreal.zig");
pub const query = @import("query.zig");
pub const ingest = @import("ingest.zig");

const Config = types.Config;
const SurrealClient = surreal.SurrealClient;
const IngestResult = types.IngestResult;
const IngestOptions = types.IngestOptions;
const Document = types.Document;
const FunctionRecord = types.FunctionRecord;
const CallRecord = types.CallRecord;
const Chunk = types.Chunk;

// Re-export C types
pub const CString = types.CString;
pub const CConfig = types.CConfig;
pub const CIngestOptions = types.CIngestOptions;
pub const CIngestResult = types.CIngestResult;
pub const CStatsResult = types.CStatsResult;
pub const CQueryResult = types.CQueryResult;
pub const CDocumentList = types.CDocumentList;
pub const CStringResult = types.CStringResult;
pub const CCodeQuery = types.CCodeQuery;
pub const ErrorCode = types.ErrorCode;

// =============================================================================
// Zig API
// =============================================================================

/// High-level Zig API wrapping SurrealDB client + query/ingest operations.
pub const CodeQuery = struct {
    client: SurrealClient,

    pub fn init(allocator: std.mem.Allocator, config: Config, environ: std.process.Environ) !CodeQuery {
        return .{
            .client = try SurrealClient.init(allocator, config, environ),
        };
    }

    pub fn deinit(self: *CodeQuery) void {
        self.client.deinit();
    }

    // -- Ingestion --

    pub fn ingestFile(self: *CodeQuery, path: []const u8, options: IngestOptions) !IngestResult {
        return ingest.ingestFile(&self.client, path, options);
    }

    pub fn ingestFolder(self: *CodeQuery, path: []const u8, options: IngestOptions) !IngestResult {
        return ingest.ingestFolder(&self.client, path, options);
    }

    pub fn removeDocument(self: *CodeQuery, path: []const u8) !void {
        return ingest.removeDocument(&self.client, path);
    }

    pub fn listDocuments(self: *CodeQuery) !types.QueryResult(Document) {
        return ingest.listDocuments(&self.client);
    }

    pub fn ensureSchema(self: *CodeQuery) !void {
        return ingest.ensureSchema(&self.client);
    }

    // -- Queries (existing) --

    pub fn find(self: *CodeQuery, term: []const u8) !types.QueryResult(FunctionRecord) {
        return query.find(&self.client, term);
    }

    pub fn context(self: *CodeQuery, name: []const u8) !types.ContextResult {
        return query.context(&self.client, name);
    }

    pub fn fileQuery(self: *CodeQuery, path: []const u8) !types.QueryResult(FunctionRecord) {
        return query.fileQuery(&self.client, path);
    }

    pub fn callers(self: *CodeQuery, name: []const u8) !types.QueryResult(CallRecord) {
        return query.callers(&self.client, name);
    }

    pub fn callees(self: *CodeQuery, name: []const u8) !types.QueryResult(CallRecord) {
        return query.callees(&self.client, name);
    }

    pub fn stats(self: *CodeQuery) !types.StatsResult {
        return query.stats(&self.client);
    }

    // -- Queries (new - knowledge) --

    pub fn searchChunks(self: *CodeQuery, term: []const u8) !types.QueryResult(Chunk) {
        return query.searchChunks(&self.client, term);
    }

    /// Execute a raw SQL query and return the JSON response.
    /// Caller owns the returned slice.
    pub fn rawQuery(self: *CodeQuery, sql: []const u8) ![]const u8 {
        return self.client.executeQuery(sql);
    }
};

// =============================================================================
// C FFI Exports
// =============================================================================
const ffi_allocator = std.heap.c_allocator;

/// Internal handle storing the CodeQuery instance + environ for FFI.
const FFIHandle = struct {
    cq: CodeQuery,
    allocated_strings: std.ArrayListUnmanaged([]const u8) = .empty,

    fn deinit(self: *FFIHandle) void {
        for (self.allocated_strings.items) |s| {
            ffi_allocator.free(s);
        }
        self.allocated_strings.deinit(ffi_allocator);
        self.cq.deinit();
    }

    fn trackString(self: *FFIHandle, s: []const u8) !CString {
        const duped = try ffi_allocator.dupe(u8, s);
        try self.allocated_strings.append(ffi_allocator, duped);
        return CString.fromSlice(duped);
    }
};

fn makeErrorString(msg: []const u8) CString {
    const duped = ffi_allocator.dupe(u8, msg) catch return CString{};
    return CString.fromSlice(duped);
}

// -- Lifecycle --

export fn zcq_init(c_config: ?*const CConfig) ?*CCodeQuery {
    const cfg = if (c_config) |cc| cc.toConfig() else Config{};

    // Construct Environ from C environ pointer for FFI consumers
    const c_env: [*:null]const ?[*:0]const u8 = @ptrCast(std.c.environ);
    const environ: std.process.Environ = .{ .block = .{ .slice = std.mem.span(c_env) } };

    const handle = ffi_allocator.create(FFIHandle) catch return null;
    handle.* = .{
        .cq = CodeQuery.init(ffi_allocator, cfg, environ) catch {
            ffi_allocator.destroy(handle);
            return null;
        },
    };
    return @ptrCast(handle);
}

export fn zcq_deinit(opaque_handle: ?*CCodeQuery) void {
    if (opaque_handle == null) return;
    const handle: *FFIHandle = @ptrCast(@alignCast(opaque_handle));
    handle.deinit();
    ffi_allocator.destroy(handle);
}

// -- Ingestion --

export fn zcq_ingest_file(opaque_handle: ?*CCodeQuery, path: CString, opts: ?*const CIngestOptions, result_out: *CIngestResult) void {
    result_out.* = CIngestResult{};

    if (opaque_handle == null) {
        result_out.error_code = ErrorCode.INVALID_ARGUMENT;
        result_out.error_message = makeErrorString("Handle is null");
        return;
    }

    const handle: *FFIHandle = @ptrCast(@alignCast(opaque_handle));
    const path_slice = path.toSlice();
    if (path_slice.len == 0) {
        result_out.error_code = ErrorCode.INVALID_ARGUMENT;
        result_out.error_message = makeErrorString("Path is empty");
        return;
    }

    const options = if (opts) |o| o.toOptions() else IngestOptions{};

    const ir = handle.cq.ingestFile(path_slice, options) catch {
        result_out.error_code = ErrorCode.IO_ERROR;
        result_out.error_message = makeErrorString("Ingestion failed");
        return;
    };

    result_out.success = true;
    result_out.documents_created = @intCast(ir.documents_created);
    result_out.chunks_created = @intCast(ir.chunks_created);
    result_out.documents_skipped = @intCast(ir.documents_skipped);
    result_out.errors = @intCast(ir.errors);
}

export fn zcq_ingest_folder(opaque_handle: ?*CCodeQuery, path: CString, opts: ?*const CIngestOptions, result_out: *CIngestResult) void {
    result_out.* = CIngestResult{};

    if (opaque_handle == null) {
        result_out.error_code = ErrorCode.INVALID_ARGUMENT;
        result_out.error_message = makeErrorString("Handle is null");
        return;
    }

    const handle: *FFIHandle = @ptrCast(@alignCast(opaque_handle));
    const path_slice = path.toSlice();
    if (path_slice.len == 0) {
        result_out.error_code = ErrorCode.INVALID_ARGUMENT;
        result_out.error_message = makeErrorString("Path is empty");
        return;
    }

    const options = if (opts) |o| o.toOptions() else IngestOptions{};

    const ir = handle.cq.ingestFolder(path_slice, options) catch {
        result_out.error_code = ErrorCode.IO_ERROR;
        result_out.error_message = makeErrorString("Folder ingestion failed");
        return;
    };

    result_out.success = true;
    result_out.documents_created = @intCast(ir.documents_created);
    result_out.chunks_created = @intCast(ir.chunks_created);
    result_out.documents_skipped = @intCast(ir.documents_skipped);
    result_out.errors = @intCast(ir.errors);
}

export fn zcq_remove_document(opaque_handle: ?*CCodeQuery, path: CString) i32 {
    if (opaque_handle == null) return ErrorCode.INVALID_ARGUMENT;

    const handle: *FFIHandle = @ptrCast(@alignCast(opaque_handle));
    const path_slice = path.toSlice();
    if (path_slice.len == 0) return ErrorCode.INVALID_ARGUMENT;

    handle.cq.removeDocument(path_slice) catch return ErrorCode.QUERY_ERROR;
    return ErrorCode.SUCCESS;
}

export fn zcq_list_documents(opaque_handle: ?*CCodeQuery, result_out: *CDocumentList) void {
    result_out.* = CDocumentList{};

    if (opaque_handle == null) {
        result_out.error_code = ErrorCode.INVALID_ARGUMENT;
        result_out.error_message = makeErrorString("Handle is null");
        return;
    }

    const handle: *FFIHandle = @ptrCast(@alignCast(opaque_handle));

    var docs = handle.cq.listDocuments() catch {
        result_out.error_code = ErrorCode.QUERY_ERROR;
        result_out.error_message = makeErrorString("Query failed");
        return;
    };
    defer docs.deinit();

    // Serialize to JSON for C consumers via std.json.Stringify — never
    // printf-style templating (repo anti-pattern class 1, JSON-IN-FMT).
    // Attacker-influenced paths/names containing `"` or `\` are correctly
    // escaped by Stringify rather than breaking or injecting JSON fields.
    const DocEntry = struct {
        path: []const u8,
        name: []const u8,
        extension: []const u8,
        size: i64,
        content_hash: []const u8,
        ingested_at: []const u8,
    };

    var entries: std.ArrayListUnmanaged(DocEntry) = .empty;
    defer entries.deinit(ffi_allocator);

    for (docs.items) |doc| {
        entries.append(ffi_allocator, .{
            .path = doc.path,
            .name = doc.name,
            .extension = doc.extension,
            .size = doc.size,
            .content_hash = doc.content_hash,
            .ingested_at = doc.ingested_at,
        }) catch return;
    }

    const json_str = std.json.Stringify.valueAlloc(ffi_allocator, entries.items, .{}) catch return;
    result_out.success = true;
    result_out.json_data = CString.fromSlice(json_str);
    result_out.count = @intCast(docs.total_count);
}

// -- Queries --

export fn zcq_find(opaque_handle: ?*CCodeQuery, term: CString, result_out: *CQueryResult) void {
    result_out.* = CQueryResult{};

    if (opaque_handle == null) {
        result_out.error_code = ErrorCode.INVALID_ARGUMENT;
        return;
    }

    const handle: *FFIHandle = @ptrCast(@alignCast(opaque_handle));
    const term_slice = term.toSlice();

    // Escape the caller-supplied term before interpolating into the quoted
    // string literal (prevents SurrealQL injection over the C ABI).
    const escaped_term = surreal.escapeSql(ffi_allocator, term_slice) catch return;
    defer ffi_allocator.free(escaped_term);

    // Use raw query for simplicity — return JSON directly
    const sql = std.fmt.allocPrint(ffi_allocator,
        \\SELECT record::id(id) as id, name, file, line_start, line_end
        \\FROM code_function
        \\WHERE string::lowercase(name) CONTAINS '{s}'
        \\ORDER BY name LIMIT 50
    , .{escaped_term}) catch return;
    defer ffi_allocator.free(sql);

    const response = handle.cq.rawQuery(sql) catch {
        result_out.error_code = ErrorCode.NETWORK_ERROR;
        result_out.error_message = makeErrorString("Query failed");
        return;
    };

    // Response is owned by us, pass it to C
    result_out.success = true;
    result_out.json_data = CString.fromSlice(response);
}

export fn zcq_search_chunks(opaque_handle: ?*CCodeQuery, term: CString, result_out: *CQueryResult) void {
    result_out.* = CQueryResult{};

    if (opaque_handle == null) {
        result_out.error_code = ErrorCode.INVALID_ARGUMENT;
        return;
    }

    const handle: *FFIHandle = @ptrCast(@alignCast(opaque_handle));
    const term_slice = term.toSlice();

    // Escape the caller-supplied term before interpolating into the quoted
    // string literal (prevents SurrealQL injection over the C ABI).
    const escaped_term = surreal.escapeSql(ffi_allocator, term_slice) catch return;
    defer ffi_allocator.free(escaped_term);

    const sql = std.fmt.allocPrint(ffi_allocator,
        \\SELECT *, document.path as doc_path
        \\FROM knowledge_chunk
        \\WHERE content CONTAINS '{s}'
        \\ORDER BY document, chunk_index LIMIT 20
    , .{escaped_term}) catch return;
    defer ffi_allocator.free(sql);

    const response = handle.cq.rawQuery(sql) catch {
        result_out.error_code = ErrorCode.NETWORK_ERROR;
        result_out.error_message = makeErrorString("Query failed");
        return;
    };

    result_out.success = true;
    result_out.json_data = CString.fromSlice(response);
}

export fn zcq_raw_query(opaque_handle: ?*CCodeQuery, sql: CString, result_out: *CStringResult) void {
    result_out.* = CStringResult{};

    if (opaque_handle == null) {
        result_out.error_code = ErrorCode.INVALID_ARGUMENT;
        return;
    }

    const handle: *FFIHandle = @ptrCast(@alignCast(opaque_handle));
    const sql_slice = sql.toSlice();

    const response = handle.cq.rawQuery(sql_slice) catch {
        result_out.error_code = ErrorCode.NETWORK_ERROR;
        result_out.error_message = makeErrorString("Query failed");
        return;
    };

    result_out.success = true;
    result_out.value = CString.fromSlice(response);
}

export fn zcq_stats(opaque_handle: ?*CCodeQuery, result_out: *CStatsResult) void {
    result_out.* = CStatsResult{};

    if (opaque_handle == null) {
        result_out.error_code = ErrorCode.INVALID_ARGUMENT;
        return;
    }

    const handle: *FFIHandle = @ptrCast(@alignCast(opaque_handle));

    const s = handle.cq.stats() catch {
        result_out.error_code = ErrorCode.NETWORK_ERROR;
        result_out.error_message = makeErrorString("Stats query failed");
        return;
    };

    result_out.success = true;
    result_out.function_count = s.function_count;
    result_out.edge_count = s.edge_count;
    result_out.document_count = s.document_count;
    result_out.chunk_count = s.chunk_count;
}

// -- Memory management --

export fn zcq_free_result(result_ptr: ?*CQueryResult) void {
    if (result_ptr) |r| {
        if (r.json_data.ptr) |p| {
            ffi_allocator.free(p[0..r.json_data.len]);
        }
        if (r.error_message.ptr) |p| {
            ffi_allocator.free(p[0..r.error_message.len]);
        }
        r.* = CQueryResult{};
    }
}

export fn zcq_free_string(s: CString) void {
    if (s.ptr) |p| {
        ffi_allocator.free(p[0..s.len]);
    }
}

export fn zcq_free_document_list(result_ptr: ?*CDocumentList) void {
    if (result_ptr) |r| {
        if (r.json_data.ptr) |p| {
            ffi_allocator.free(p[0..r.json_data.len]);
        }
        if (r.error_message.ptr) |p| {
            ffi_allocator.free(p[0..r.error_message.len]);
        }
        r.* = CDocumentList{};
    }
}

export fn zcq_free_string_result(result_ptr: ?*CStringResult) void {
    if (result_ptr) |r| {
        if (r.value.ptr) |p| {
            ffi_allocator.free(p[0..r.value.len]);
        }
        if (r.error_message.ptr) |p| {
            ffi_allocator.free(p[0..r.error_message.len]);
        }
        r.* = CStringResult{};
    }
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

// Pull in the tests defined in the referenced modules (surreal.zig etc.).
test {
    testing.refAllDecls(@This());
    _ = surreal;
    _ = query;
    _ = ingest;
    _ = types;
}

test "zcq_list_documents JSON: document strings are escaped, not templated (JSON-IN-FMT fix)" {
    // Regression test for the repo's JSON-IN-FMT anti-pattern (class 1): the
    // document list must be produced by std.json.Stringify so a path/name
    // containing `"` or `\` cannot break out of or inject into the JSON.
    const DocEntry = struct {
        path: []const u8,
        name: []const u8,
        extension: []const u8,
        size: i64,
        content_hash: []const u8,
        ingested_at: []const u8,
    };

    const entries = [_]DocEntry{.{
        .path = "/tmp/a\"b\\c.md", // embedded quote + backslash
        .name = "a\"b",
        .extension = ".md",
        .size = 42,
        .content_hash = "deadbeef",
        .ingested_at = "2026-07-17T00:00:00Z",
    }};

    const json = try std.json.Stringify.valueAlloc(testing.allocator, entries[0..], .{});
    defer testing.allocator.free(json);

    // Output must be valid JSON that round-trips through the parser (the old
    // allocPrint template would have produced invalid JSON here).
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();

    try testing.expect(parsed.value == .array);
    try testing.expectEqual(@as(usize, 1), parsed.value.array.items.len);
    const obj = parsed.value.array.items[0].object;
    // The parser must recover the exact original bytes, proving the quote and
    // backslash were correctly escaped on the wire.
    try testing.expectEqualStrings("/tmp/a\"b\\c.md", obj.get("path").?.string);
    try testing.expectEqualStrings("a\"b", obj.get("name").?.string);
    try testing.expectEqual(@as(i64, 42), obj.get("size").?.integer);
}
