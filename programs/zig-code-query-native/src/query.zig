//! Query Functions
//!
//! Extracted command logic from main.zig. These functions return data
//! structs instead of printing directly, enabling library consumers
//! to use the data programmatically.
//!
//! Security invariants:
//!  - Every value interpolated inside a single-quoted SurrealQL string is
//!    passed through `surreal.escapeSql` first.
//!  - Every value interpolated as a record-id fragment (`code_function:{s}`)
//!    is allow-listed with `surreal.validRecordId`; non-conforming names are
//!    refused (empty result) rather than escaped, because record-id positions
//!    cannot be made safe by string escaping.
//!  - Returned records never alias the transient JSON parse arena: each string
//!    field is copied into a result-owned arena that lives until `deinit`.

const std = @import("std");
const types = @import("types.zig");
const surreal = @import("surreal.zig");
const SurrealClient = surreal.SurrealClient;
const FunctionRecord = types.FunctionRecord;
const CallRecord = types.CallRecord;
const Chunk = types.Chunk;

/// Search functions by name (case-insensitive contains).
pub fn find(client: *SurrealClient, term: []const u8) !types.QueryResult(FunctionRecord) {
    const allocator = client.allocator;

    const escaped_term = try surreal.escapeSql(allocator, term);
    defer allocator.free(escaped_term);

    const sql = try std.fmt.allocPrint(allocator,
        \\SELECT record::id(id) as id, name, file, line_start, line_end
        \\FROM code_function
        \\WHERE string::lowercase(name) CONTAINS '{s}'
        \\ORDER BY name
        \\LIMIT 50
    , .{escaped_term});
    defer allocator.free(sql);

    const response = try client.executeQuery(sql);
    defer allocator.free(response);

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, response, .{}) catch {
        return types.QueryResult(FunctionRecord).empty(allocator);
    };
    defer parsed.deinit();

    const items = surreal.extractResult(parsed.value) orelse {
        return types.QueryResult(FunctionRecord).empty(allocator);
    };

    if (items.len == 0) {
        return types.QueryResult(FunctionRecord).empty(allocator);
    }

    const arena = try allocator.create(std.heap.ArenaAllocator);
    errdefer allocator.destroy(arena);
    arena.* = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const aa = arena.allocator();

    const records = try aa.alloc(FunctionRecord, items.len);
    for (items, 0..) |item, i| {
        if (item != .object) {
            records[i] = .{};
            continue;
        }
        records[i] = .{
            .name = try aa.dupe(u8, surreal.getString(item.object, "name")),
            .file = try aa.dupe(u8, surreal.getString(item.object, "file")),
            .line_start = surreal.getInt(item.object, "line_start"),
            .line_end = surreal.getInt(item.object, "line_end"),
        };
    }

    return .{
        .items = records,
        .total_count = records.len,
        .allocator = allocator,
        .arena = arena,
    };
}

/// Get full context for a function: details + callers + callees.
pub fn context(client: *SurrealClient, name: []const u8) !types.ContextResult {
    const allocator = client.allocator;
    var result = types.ContextResult{ .allocator = allocator };

    // The function-details query uses `name` inside a quoted string literal —
    // escape it. The callers/callees queries use `name` as a record-id
    // fragment (`code_function:{name}`) which cannot be string-escaped, so
    // those are only issued when the name passes the record-id allow-list.
    const escaped_name = try surreal.escapeSql(allocator, name);
    defer allocator.free(escaped_name);
    const name_is_record_id = surreal.validRecordId(name);

    // Query function details
    const func_sql = try std.fmt.allocPrint(allocator,
        \\SELECT record::id(id) as id, name, file, line_start, line_end, code
        \\FROM code_function
        \\WHERE name = '{s}'
        \\LIMIT 1
    , .{escaped_name});
    defer allocator.free(func_sql);

    const func_response = try client.executeQuery(func_sql);
    defer allocator.free(func_response);

    const func_parsed = std.json.parseFromSlice(std.json.Value, allocator, func_response, .{}) catch {
        return result;
    };
    defer func_parsed.deinit();

    const func_items = surreal.extractResult(func_parsed.value) orelse return result;
    if (func_items.len == 0) return result;
    if (func_items[0] != .object) return result;

    // Everything returned from here on owns its strings via this arena.
    const arena = try allocator.create(std.heap.ArenaAllocator);
    errdefer allocator.destroy(arena);
    arena.* = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const aa = arena.allocator();

    const func_obj = func_items[0].object;
    result.func = .{
        .name = try aa.dupe(u8, surreal.getString(func_obj, "name")),
        .file = try aa.dupe(u8, surreal.getString(func_obj, "file")),
        .line_start = surreal.getInt(func_obj, "line_start"),
        .line_end = surreal.getInt(func_obj, "line_end"),
        .code = try aa.dupe(u8, surreal.getString(func_obj, "code")),
    };
    result.found = true;
    result.arena = arena;

    // Query callees (record-id position — only if the name is allow-listed).
    if (name_is_record_id) {
        const callees_sql = try std.fmt.allocPrint(allocator,
            \\SELECT out.name as name, out.file as file, out.line_start as line_start
            \\FROM code_calls
            \\WHERE in = code_function:{s}
            \\LIMIT 50
        , .{name});
        defer allocator.free(callees_sql);

        const callees_response = try client.executeQuery(callees_sql);
        defer allocator.free(callees_response);

        const callees_parsed = std.json.parseFromSlice(std.json.Value, allocator, callees_response, .{}) catch null;
        if (callees_parsed) |cp| {
            defer cp.deinit();
            if (surreal.extractResult(cp.value)) |cp_items| {
                if (cp_items.len > 0) {
                    result.callees = try parseCallRecords(aa, cp_items);
                }
            }
        }

        // Query callers.
        const callers_sql = try std.fmt.allocPrint(allocator,
            \\SELECT in.name as name, in.file as file, in.line_start as line_start
            \\FROM code_calls
            \\WHERE out = code_function:{s}
            \\LIMIT 30
        , .{name});
        defer allocator.free(callers_sql);

        const callers_response = try client.executeQuery(callers_sql);
        defer allocator.free(callers_response);

        const callers_parsed = std.json.parseFromSlice(std.json.Value, allocator, callers_response, .{}) catch null;
        if (callers_parsed) |cp| {
            defer cp.deinit();
            if (surreal.extractResult(cp.value)) |cp_items| {
                if (cp_items.len > 0) {
                    result.callers = try parseCallRecords(aa, cp_items);
                }
            }
        }
    }

    return result;
}

/// List functions in a module (file path contains match).
pub fn fileQuery(client: *SurrealClient, path: []const u8) !types.QueryResult(FunctionRecord) {
    const allocator = client.allocator;

    const escaped_path = try surreal.escapeSql(allocator, path);
    defer allocator.free(escaped_path);

    const sql = try std.fmt.allocPrint(allocator,
        \\SELECT record::id(id) as id, name, file, line_start, line_end
        \\FROM code_function
        \\WHERE file CONTAINS '{s}'
        \\ORDER BY file, line_start
        \\LIMIT 100
    , .{escaped_path});
    defer allocator.free(sql);

    const response = try client.executeQuery(sql);
    defer allocator.free(response);

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, response, .{}) catch {
        return types.QueryResult(FunctionRecord).empty(allocator);
    };
    defer parsed.deinit();

    const items = surreal.extractResult(parsed.value) orelse {
        return types.QueryResult(FunctionRecord).empty(allocator);
    };

    if (items.len == 0) {
        return types.QueryResult(FunctionRecord).empty(allocator);
    }

    const arena = try allocator.create(std.heap.ArenaAllocator);
    errdefer allocator.destroy(arena);
    arena.* = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const aa = arena.allocator();

    const records = try aa.alloc(FunctionRecord, items.len);
    for (items, 0..) |item, i| {
        if (item != .object) {
            records[i] = .{};
            continue;
        }
        records[i] = .{
            .name = try aa.dupe(u8, surreal.getString(item.object, "name")),
            .file = try aa.dupe(u8, surreal.getString(item.object, "file")),
            .line_start = surreal.getInt(item.object, "line_start"),
            .line_end = surreal.getInt(item.object, "line_end"),
        };
    }

    return .{
        .items = records,
        .total_count = records.len,
        .allocator = allocator,
        .arena = arena,
    };
}

/// Find all callers of a function.
pub fn callers(client: *SurrealClient, name: []const u8) !types.QueryResult(CallRecord) {
    const allocator = client.allocator;

    // `name` is interpolated as a record-id fragment; refuse anything outside
    // the allow-list rather than attempt to escape it.
    if (!surreal.validRecordId(name)) {
        return types.QueryResult(CallRecord).empty(allocator);
    }

    const sql = try std.fmt.allocPrint(allocator,
        \\SELECT in.name as name, in.file as file, in.line_start as line_start
        \\FROM code_calls
        \\WHERE out = code_function:{s}
        \\ORDER BY in.name
        \\LIMIT 50
    , .{name});
    defer allocator.free(sql);

    const response = try client.executeQuery(sql);
    defer allocator.free(response);

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, response, .{}) catch {
        return types.QueryResult(CallRecord).empty(allocator);
    };
    defer parsed.deinit();

    const items = surreal.extractResult(parsed.value) orelse {
        return types.QueryResult(CallRecord).empty(allocator);
    };

    if (items.len == 0) {
        return types.QueryResult(CallRecord).empty(allocator);
    }

    const arena = try allocator.create(std.heap.ArenaAllocator);
    errdefer allocator.destroy(arena);
    arena.* = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const aa = arena.allocator();

    const records = try parseCallRecords(aa, items);
    return .{
        .items = records,
        .total_count = records.len,
        .allocator = allocator,
        .arena = arena,
    };
}

/// Find all callees of a function.
pub fn callees(client: *SurrealClient, name: []const u8) !types.QueryResult(CallRecord) {
    const allocator = client.allocator;

    // `name` is interpolated as a record-id fragment; refuse anything outside
    // the allow-list rather than attempt to escape it.
    if (!surreal.validRecordId(name)) {
        return types.QueryResult(CallRecord).empty(allocator);
    }

    const sql = try std.fmt.allocPrint(allocator,
        \\SELECT out.name as name, out.file as file, out.line_start as line_start
        \\FROM code_calls
        \\WHERE in = code_function:{s}
        \\LIMIT 50
    , .{name});
    defer allocator.free(sql);

    const response = try client.executeQuery(sql);
    defer allocator.free(response);

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, response, .{}) catch {
        return types.QueryResult(CallRecord).empty(allocator);
    };
    defer parsed.deinit();

    const items = surreal.extractResult(parsed.value) orelse {
        return types.QueryResult(CallRecord).empty(allocator);
    };

    if (items.len == 0) {
        return types.QueryResult(CallRecord).empty(allocator);
    }

    const arena = try allocator.create(std.heap.ArenaAllocator);
    errdefer allocator.destroy(arena);
    arena.* = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const aa = arena.allocator();

    const records = try parseCallRecords(aa, items);
    return .{
        .items = records,
        .total_count = records.len,
        .allocator = allocator,
        .arena = arena,
    };
}

/// Get database statistics.
pub fn stats(client: *SurrealClient) !types.StatsResult {
    const allocator = client.allocator;
    var result = types.StatsResult{
        .ns = client.config.ns,
        .db = client.config.db,
    };

    // Function count
    const func_response = try client.executeQuery("SELECT count() as count FROM code_function GROUP ALL");
    defer allocator.free(func_response);

    const func_parsed = std.json.parseFromSlice(std.json.Value, allocator, func_response, .{}) catch null;
    if (func_parsed) |fp| {
        defer fp.deinit();
        result.function_count = surreal.extractCount(fp.value);
    }

    // Edge count
    const edge_response = try client.executeQuery("SELECT count() as count FROM code_calls GROUP ALL");
    defer allocator.free(edge_response);

    const edge_parsed = std.json.parseFromSlice(std.json.Value, allocator, edge_response, .{}) catch null;
    if (edge_parsed) |ep| {
        defer ep.deinit();
        result.edge_count = surreal.extractCount(ep.value);
    }

    // Document count
    const doc_response = try client.executeQuery("SELECT count() as count FROM knowledge_document GROUP ALL");
    defer allocator.free(doc_response);

    const doc_parsed = std.json.parseFromSlice(std.json.Value, allocator, doc_response, .{}) catch null;
    if (doc_parsed) |dp| {
        defer dp.deinit();
        result.document_count = surreal.extractCount(dp.value);
    }

    // Chunk count
    const chunk_response = try client.executeQuery("SELECT count() as count FROM knowledge_chunk GROUP ALL");
    defer allocator.free(chunk_response);

    const chunk_parsed = std.json.parseFromSlice(std.json.Value, allocator, chunk_response, .{}) catch null;
    if (chunk_parsed) |ckp| {
        defer ckp.deinit();
        result.chunk_count = surreal.extractCount(ckp.value);
    }

    return result;
}

/// Search across ingested knowledge chunks.
pub fn searchChunks(client: *SurrealClient, term: []const u8) !types.QueryResult(Chunk) {
    const allocator = client.allocator;

    const escaped_term = try surreal.escapeSql(allocator, term);
    defer allocator.free(escaped_term);

    const sql = try std.fmt.allocPrint(allocator,
        \\SELECT *, document.path as doc_path
        \\FROM knowledge_chunk
        \\WHERE content CONTAINS '{s}'
        \\ORDER BY document, chunk_index
        \\LIMIT 20
    , .{escaped_term});
    defer allocator.free(sql);

    const response = try client.executeQuery(sql);
    defer allocator.free(response);

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, response, .{}) catch {
        return types.QueryResult(Chunk).empty(allocator);
    };
    defer parsed.deinit();

    const items = surreal.extractResult(parsed.value) orelse {
        return types.QueryResult(Chunk).empty(allocator);
    };

    if (items.len == 0) {
        return types.QueryResult(Chunk).empty(allocator);
    }

    const arena = try allocator.create(std.heap.ArenaAllocator);
    errdefer allocator.destroy(arena);
    arena.* = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const aa = arena.allocator();

    const records = try aa.alloc(Chunk, items.len);
    for (items, 0..) |item, i| {
        if (item != .object) {
            records[i] = .{};
            continue;
        }
        records[i] = .{
            .document_id = try aa.dupe(u8, surreal.getString(item.object, "doc_path")),
            .chunk_index = surreal.getInt(item.object, "chunk_index"),
            .content = try aa.dupe(u8, surreal.getString(item.object, "content")),
            .byte_offset = surreal.getInt(item.object, "byte_offset"),
            .byte_len = surreal.getInt(item.object, "byte_len"),
        };
    }

    return .{
        .items = records,
        .total_count = records.len,
        .allocator = allocator,
        .arena = arena,
    };
}

// =============================================================================
// Helpers
// =============================================================================

/// Parse call records, copying every string field into `aa` (the caller's
/// result-owned arena) so nothing aliases the transient JSON parse arena.
fn parseCallRecords(aa: std.mem.Allocator, items: []std.json.Value) ![]CallRecord {
    const records = try aa.alloc(CallRecord, items.len);
    for (items, 0..) |item, i| {
        if (item != .object) {
            records[i] = .{};
            continue;
        }
        records[i] = .{
            .name = try aa.dupe(u8, surreal.getString(item.object, "name")),
            .file = try aa.dupe(u8, surreal.getString(item.object, "file")),
            .line_start = surreal.getInt(item.object, "line_start"),
        };
    }
    return records;
}
