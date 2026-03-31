//! Query Functions
//!
//! Extracted command logic from main.zig. These functions return data
//! structs instead of printing directly, enabling library consumers
//! to use the data programmatically.

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

    const sql = try std.fmt.allocPrint(allocator,
        \\SELECT record::id(id) as id, name, file, line_start, line_end
        \\FROM code_function
        \\WHERE string::lowercase(name) CONTAINS '{s}'
        \\ORDER BY name
        \\LIMIT 50
    , .{term});
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

    const records = try allocator.alloc(FunctionRecord, items.len);
    for (items, 0..) |item, i| {
        if (item != .object) {
            records[i] = .{};
            continue;
        }
        records[i] = .{
            .name = surreal.getString(item.object, "name"),
            .file = surreal.getString(item.object, "file"),
            .line_start = surreal.getInt(item.object, "line_start"),
            .line_end = surreal.getInt(item.object, "line_end"),
        };
    }

    return .{
        .items = records,
        .total_count = records.len,
        .allocator = allocator,
    };
}

/// Get full context for a function: details + callers + callees.
pub fn context(client: *SurrealClient, name: []const u8) !types.ContextResult {
    const allocator = client.allocator;
    var result = types.ContextResult{ .allocator = allocator };

    // Query function details
    const func_sql = try std.fmt.allocPrint(allocator,
        \\SELECT record::id(id) as id, name, file, line_start, line_end, code
        \\FROM code_function
        \\WHERE name = '{s}'
        \\LIMIT 1
    , .{name});
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

    const func_obj = func_items[0].object;
    result.func = .{
        .name = surreal.getString(func_obj, "name"),
        .file = surreal.getString(func_obj, "file"),
        .line_start = surreal.getInt(func_obj, "line_start"),
        .line_end = surreal.getInt(func_obj, "line_end"),
        .code = surreal.getString(func_obj, "code"),
    };
    result.found = true;

    // Query callees
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
        if (surreal.extractResult(cp.value)) |items| {
            if (items.len > 0) {
                result.callees = try parseCallRecords(allocator, items);
            }
        }
    }

    // Query callers
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
        if (surreal.extractResult(cp.value)) |items| {
            if (items.len > 0) {
                result.callers = try parseCallRecords(allocator, items);
            }
        }
    }

    return result;
}

/// List functions in a module (file path contains match).
pub fn fileQuery(client: *SurrealClient, path: []const u8) !types.QueryResult(FunctionRecord) {
    const allocator = client.allocator;

    const sql = try std.fmt.allocPrint(allocator,
        \\SELECT record::id(id) as id, name, file, line_start, line_end
        \\FROM code_function
        \\WHERE file CONTAINS '{s}'
        \\ORDER BY file, line_start
        \\LIMIT 100
    , .{path});
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

    const records = try allocator.alloc(FunctionRecord, items.len);
    for (items, 0..) |item, i| {
        if (item != .object) {
            records[i] = .{};
            continue;
        }
        records[i] = .{
            .name = surreal.getString(item.object, "name"),
            .file = surreal.getString(item.object, "file"),
            .line_start = surreal.getInt(item.object, "line_start"),
            .line_end = surreal.getInt(item.object, "line_end"),
        };
    }

    return .{
        .items = records,
        .total_count = records.len,
        .allocator = allocator,
    };
}

/// Find all callers of a function.
pub fn callers(client: *SurrealClient, name: []const u8) !types.QueryResult(CallRecord) {
    const allocator = client.allocator;

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

    const records = try parseCallRecords(allocator, items);
    return .{
        .items = records,
        .total_count = records.len,
        .allocator = allocator,
    };
}

/// Find all callees of a function.
pub fn callees(client: *SurrealClient, name: []const u8) !types.QueryResult(CallRecord) {
    const allocator = client.allocator;

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

    const records = try parseCallRecords(allocator, items);
    return .{
        .items = records,
        .total_count = records.len,
        .allocator = allocator,
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

    const sql = try std.fmt.allocPrint(allocator,
        \\SELECT *, document.path as doc_path
        \\FROM knowledge_chunk
        \\WHERE content CONTAINS '{s}'
        \\ORDER BY document, chunk_index
        \\LIMIT 20
    , .{term});
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

    const records = try allocator.alloc(Chunk, items.len);
    for (items, 0..) |item, i| {
        if (item != .object) {
            records[i] = .{};
            continue;
        }
        records[i] = .{
            .document_id = surreal.getString(item.object, "doc_path"),
            .chunk_index = surreal.getInt(item.object, "chunk_index"),
            .content = surreal.getString(item.object, "content"),
            .byte_offset = surreal.getInt(item.object, "byte_offset"),
            .byte_len = surreal.getInt(item.object, "byte_len"),
        };
    }

    return .{
        .items = records,
        .total_count = records.len,
        .allocator = allocator,
    };
}

// =============================================================================
// Helpers
// =============================================================================

fn parseCallRecords(allocator: std.mem.Allocator, items: []std.json.Value) ![]CallRecord {
    const records = try allocator.alloc(CallRecord, items.len);
    for (items, 0..) |item, i| {
        if (item != .object) {
            records[i] = .{};
            continue;
        }
        records[i] = .{
            .name = surreal.getString(item.object, "name"),
            .file = surreal.getString(item.object, "file"),
            .line_start = surreal.getInt(item.object, "line_start"),
        };
    }
    return records;
}
