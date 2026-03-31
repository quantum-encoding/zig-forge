//! File/Folder Ingestion
//!
//! Reads files, chunks their content, and inserts into SurrealDB
//! knowledge tables for later retrieval by agents.

const std = @import("std");
const types = @import("types.zig");
const surreal = @import("surreal.zig");
const SurrealClient = surreal.SurrealClient;
const IngestResult = types.IngestResult;
const IngestOptions = types.IngestOptions;
const Document = types.Document;

// =============================================================================
// Content Hashing (djb2)
// =============================================================================

fn djb2Hash(data: []const u8) u64 {
    var hash: u64 = 5381;
    for (data) |byte| {
        hash = ((hash << 5) +% hash) +% byte;
    }
    return hash;
}

fn hashToHex(hash: u64, buf: *[16]u8) []const u8 {
    const hex = "0123456789abcdef";
    var h = hash;
    var i: usize = 0;
    while (i < 16) : (i += 1) {
        buf[15 - i] = hex[@intCast(h & 0xF)];
        h >>= 4;
    }
    return buf[0..16];
}

// =============================================================================
// File Reading (C API for Zig 0.16 compat)
// =============================================================================

// C functions not exposed by std.c in Zig 0.16
extern "c" fn fseek(stream: *std.c.FILE, offset: c_long, whence: c_int) c_int;
extern "c" fn ftell(stream: *std.c.FILE) c_long;

fn readFileContents(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    // Null-terminate the path for C
    const c_path = try allocator.alloc(u8, path.len + 1);
    defer allocator.free(c_path);
    @memcpy(c_path[0..path.len], path);
    c_path[path.len] = 0;

    const file = std.c.fopen(@ptrCast(c_path.ptr), "rb") orelse return error.FileNotFound;
    defer _ = std.c.fclose(file);

    // Get file size via fseek/ftell
    _ = fseek(file, 0, 2); // SEEK_END = 2
    const size_long = ftell(file);
    if (size_long < 0) return error.FileNotFound;
    const size: usize = @intCast(size_long);
    _ = fseek(file, 0, 0); // SEEK_SET = 0

    if (size == 0) return try allocator.alloc(u8, 0);

    const buf = try allocator.alloc(u8, size);
    const read = std.c.fread(buf.ptr, 1, size, file);
    if (read != size) {
        allocator.free(buf);
        return error.ReadFailed;
    }

    return buf;
}

// =============================================================================
// Chunking
// =============================================================================

const ChunkInfo = struct {
    content: []const u8,
    byte_offset: usize,
    byte_len: usize,
};

fn chunkContent(allocator: std.mem.Allocator, content: []const u8, chunk_size: usize, overlap: usize) ![]ChunkInfo {
    if (content.len == 0) {
        return try allocator.alloc(ChunkInfo, 0);
    }

    // Estimate number of chunks
    var count: usize = 0;
    var offset: usize = 0;
    while (offset < content.len) {
        count += 1;
        var end = @min(offset + chunk_size, content.len);

        // Snap to line boundary if possible (don't split mid-line)
        if (end < content.len) {
            var snap = end;
            while (snap > offset and content[snap] != '\n') {
                snap -= 1;
            }
            if (snap > offset) {
                end = snap + 1; // include the newline
            }
        }

        if (end >= content.len) break;
        // Next chunk starts at (end - overlap), but at least end to avoid infinite loop
        const next_start = if (end > overlap) end - overlap else end;
        if (next_start <= offset) {
            offset = end;
        } else {
            offset = next_start;
        }
    }

    const chunks = try allocator.alloc(ChunkInfo, count);
    var idx: usize = 0;
    offset = 0;

    while (offset < content.len and idx < count) {
        var end = @min(offset + chunk_size, content.len);

        // Snap to line boundary
        if (end < content.len) {
            var snap = end;
            while (snap > offset and content[snap] != '\n') {
                snap -= 1;
            }
            if (snap > offset) {
                end = snap + 1;
            }
        }

        chunks[idx] = .{
            .content = content[offset..end],
            .byte_offset = offset,
            .byte_len = end - offset,
        };
        idx += 1;

        if (end >= content.len) break;
        const next_start = if (end > overlap) end - overlap else end;
        if (next_start <= offset) {
            offset = end;
        } else {
            offset = next_start;
        }
    }

    return chunks[0..idx];
}

// =============================================================================
// SQL Escaping
// =============================================================================

fn escapeSql(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    // Count characters that need escaping
    var extra: usize = 0;
    for (input) |c| {
        if (c == '\'' or c == '\\') extra += 1;
    }

    const buf = try allocator.alloc(u8, input.len + extra);
    var pos: usize = 0;
    for (input) |c| {
        if (c == '\'') {
            buf[pos] = '\\';
            pos += 1;
            buf[pos] = '\'';
            pos += 1;
        } else if (c == '\\') {
            buf[pos] = '\\';
            pos += 1;
            buf[pos] = '\\';
            pos += 1;
        } else {
            buf[pos] = c;
            pos += 1;
        }
    }
    return buf[0..pos];
}

// =============================================================================
// Path Utilities
// =============================================================================

fn baseName(path: []const u8) []const u8 {
    var i = path.len;
    while (i > 0) {
        i -= 1;
        if (path[i] == '/') return path[i + 1 ..];
    }
    return path;
}

fn extension(path: []const u8) []const u8 {
    const name = baseName(path);
    var i = name.len;
    while (i > 0) {
        i -= 1;
        if (name[i] == '.') return name[i..];
    }
    return "";
}

// =============================================================================
// Schema Setup
// =============================================================================

pub fn ensureSchema(client: *SurrealClient) !void {
    const schema_sql =
        \\DEFINE TABLE IF NOT EXISTS knowledge_document SCHEMAFULL;
        \\DEFINE FIELD IF NOT EXISTS path ON knowledge_document TYPE string;
        \\DEFINE FIELD IF NOT EXISTS name ON knowledge_document TYPE string;
        \\DEFINE FIELD IF NOT EXISTS extension ON knowledge_document TYPE string;
        \\DEFINE FIELD IF NOT EXISTS size ON knowledge_document TYPE int;
        \\DEFINE FIELD IF NOT EXISTS content_hash ON knowledge_document TYPE string;
        \\DEFINE FIELD IF NOT EXISTS ingested_at ON knowledge_document TYPE datetime;
        \\DEFINE INDEX IF NOT EXISTS idx_doc_path ON knowledge_document FIELDS path UNIQUE;
        \\DEFINE TABLE IF NOT EXISTS knowledge_chunk SCHEMAFULL;
        \\DEFINE FIELD IF NOT EXISTS document ON knowledge_chunk TYPE record<knowledge_document>;
        \\DEFINE FIELD IF NOT EXISTS chunk_index ON knowledge_chunk TYPE int;
        \\DEFINE FIELD IF NOT EXISTS content ON knowledge_chunk TYPE string;
        \\DEFINE FIELD IF NOT EXISTS byte_offset ON knowledge_chunk TYPE int;
        \\DEFINE FIELD IF NOT EXISTS byte_len ON knowledge_chunk TYPE int;
        \\DEFINE INDEX IF NOT EXISTS idx_chunk_doc ON knowledge_chunk FIELDS document;
    ;

    const response = try client.executeQuery(schema_sql);
    client.allocator.free(response);
}

// =============================================================================
// Ingestion
// =============================================================================

/// Ingest a single file into SurrealDB.
pub fn ingestFile(client: *SurrealClient, path: []const u8, options: IngestOptions) !IngestResult {
    var result = IngestResult{};
    const allocator = client.allocator;

    // Read file
    const content = readFileContents(allocator, path) catch {
        result.errors += 1;
        return result;
    };
    defer allocator.free(content);

    // Hash content
    const hash = djb2Hash(content);
    var hash_buf: [16]u8 = undefined;
    const hash_hex = hashToHex(hash, &hash_buf);

    // Check if already ingested with same hash
    const escaped_path = try escapeSql(allocator, path);
    defer allocator.free(escaped_path);

    const check_sql = try std.fmt.allocPrint(allocator,
        \\SELECT content_hash FROM knowledge_document WHERE path = '{s}'
    , .{escaped_path});
    defer allocator.free(check_sql);

    const check_response = try client.executeQuery(check_sql);
    defer allocator.free(check_response);

    const check_parsed = std.json.parseFromSlice(std.json.Value, allocator, check_response, .{}) catch null;
    if (check_parsed) |cp| {
        defer cp.deinit();
        if (surreal.extractResult(cp.value)) |items| {
            if (items.len > 0 and items[0] == .object) {
                if (items[0].object.get("content_hash")) |v| {
                    if (v == .string and std.mem.eql(u8, v.string, hash_hex)) {
                        result.documents_skipped += 1;
                        return result;
                    }
                }
            }
        }
    }

    // Delete existing document + chunks if re-ingesting
    const delete_sql = try std.fmt.allocPrint(allocator,
        \\DELETE FROM knowledge_chunk WHERE document IN (SELECT id FROM knowledge_document WHERE path = '{s}');
        \\DELETE FROM knowledge_document WHERE path = '{s}'
    , .{ escaped_path, escaped_path });
    defer allocator.free(delete_sql);

    const del_response = try client.executeQuery(delete_sql);
    allocator.free(del_response);

    // Create document record
    const name = baseName(path);
    const ext = extension(path);
    const escaped_name = try escapeSql(allocator, name);
    defer allocator.free(escaped_name);

    const create_doc_sql = try std.fmt.allocPrint(allocator,
        \\CREATE knowledge_document SET
        \\  path = '{s}',
        \\  name = '{s}',
        \\  extension = '{s}',
        \\  size = {d},
        \\  content_hash = '{s}',
        \\  ingested_at = time::now()
    , .{ escaped_path, escaped_name, ext, content.len, hash_hex });
    defer allocator.free(create_doc_sql);

    const doc_response = try client.executeQuery(create_doc_sql);
    defer allocator.free(doc_response);

    // Get document ID from response
    var doc_id: []const u8 = "";
    const doc_parsed = std.json.parseFromSlice(std.json.Value, allocator, doc_response, .{}) catch null;
    if (doc_parsed) |dp| {
        defer dp.deinit();
        if (surreal.extractResult(dp.value)) |items| {
            if (items.len > 0 and items[0] == .object) {
                if (items[0].object.get("id")) |id_val| {
                    if (id_val == .string) {
                        doc_id = try allocator.dupe(u8, id_val.string);
                    }
                }
            }
        }
    }
    defer if (doc_id.len > 0) allocator.free(doc_id);

    if (doc_id.len == 0) {
        // Try to get it by path
        const get_id_sql = try std.fmt.allocPrint(allocator,
            \\SELECT id FROM knowledge_document WHERE path = '{s}'
        , .{escaped_path});
        defer allocator.free(get_id_sql);

        const id_response = try client.executeQuery(get_id_sql);
        defer allocator.free(id_response);

        const id_parsed = std.json.parseFromSlice(std.json.Value, allocator, id_response, .{}) catch null;
        if (id_parsed) |ip| {
            defer ip.deinit();
            if (surreal.extractResult(ip.value)) |items| {
                if (items.len > 0 and items[0] == .object) {
                    if (items[0].object.get("id")) |id_val| {
                        if (id_val == .string) {
                            doc_id = try allocator.dupe(u8, id_val.string);
                        }
                    }
                }
            }
        }
    }

    result.documents_created += 1;

    // Chunk content and insert
    const chunks = try chunkContent(allocator, content, options.chunk_size, options.overlap);
    defer allocator.free(chunks);

    for (chunks, 0..) |chunk, i| {
        const escaped_content = try escapeSql(allocator, chunk.content);
        defer allocator.free(escaped_content);

        const doc_ref = if (doc_id.len > 0) doc_id else "knowledge_document:unknown";

        const chunk_sql = try std.fmt.allocPrint(allocator,
            \\CREATE knowledge_chunk SET
            \\  document = {s},
            \\  chunk_index = {d},
            \\  content = '{s}',
            \\  byte_offset = {d},
            \\  byte_len = {d}
        , .{ doc_ref, i, escaped_content, chunk.byte_offset, chunk.byte_len });
        defer allocator.free(chunk_sql);

        const chunk_response = client.executeQuery(chunk_sql) catch {
            result.errors += 1;
            continue;
        };
        allocator.free(chunk_response);
        result.chunks_created += 1;
    }

    return result;
}

/// Ingest all files in a folder recursively.
pub fn ingestFolder(client: *SurrealClient, path: []const u8, options: IngestOptions) !IngestResult {
    var result = IngestResult{};
    const allocator = client.allocator;

    // Null-terminate for C
    const c_path = try allocator.alloc(u8, path.len + 1);
    defer allocator.free(c_path);
    @memcpy(c_path[0..path.len], path);
    c_path[path.len] = 0;

    try walkDirectory(client, c_path[0..path.len :0], path, options, &result);
    return result;
}

fn walkDirectory(client: *SurrealClient, c_path: [*:0]const u8, path: []const u8, options: IngestOptions, result: *IngestResult) !void {
    const allocator = client.allocator;

    const dir = std.c.opendir(c_path) orelse return;
    defer _ = std.c.closedir(dir);

    while (std.c.readdir(dir)) |entry| {
        const name_ptr: [*:0]const u8 = @ptrCast(&entry.name);
        const name_len = std.mem.len(name_ptr);
        const name = name_ptr[0..name_len];

        // Skip . and ..
        if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
        // Skip hidden files/dirs
        if (name[0] == '.') continue;

        // Build full path
        const full_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ path, name });
        defer allocator.free(full_path);

        const c_full = try allocator.alloc(u8, full_path.len + 1);
        defer allocator.free(c_full);
        @memcpy(c_full[0..full_path.len], full_path);
        c_full[full_path.len] = 0;

        if (entry.type == std.c.DT.DIR) {
            if (options.recursive) {
                try walkDirectory(client, c_full[0..full_path.len :0], full_path, options, result);
            }
        } else if (entry.type == std.c.DT.REG) {
            // Check extension filter
            if (options.extensions) |exts| {
                const ext = extension(full_path);
                var matched = false;
                for (exts) |allowed_ext| {
                    if (std.mem.eql(u8, ext, allowed_ext)) {
                        matched = true;
                        break;
                    }
                }
                if (!matched) continue;
            }

            const file_result = ingestFile(client, full_path, options) catch {
                result.errors += 1;
                continue;
            };
            result.documents_created += file_result.documents_created;
            result.chunks_created += file_result.chunks_created;
            result.documents_skipped += file_result.documents_skipped;
            result.errors += file_result.errors;
        }
    }
}

/// Remove a document and its chunks by path.
pub fn removeDocument(client: *SurrealClient, path: []const u8) !void {
    const allocator = client.allocator;
    const escaped_path = try escapeSql(allocator, path);
    defer allocator.free(escaped_path);

    const sql = try std.fmt.allocPrint(allocator,
        \\DELETE FROM knowledge_chunk WHERE document IN (SELECT id FROM knowledge_document WHERE path = '{s}');
        \\DELETE FROM knowledge_document WHERE path = '{s}'
    , .{ escaped_path, escaped_path });
    defer allocator.free(sql);

    const response = try client.executeQuery(sql);
    allocator.free(response);
}

/// List all ingested documents.
pub fn listDocuments(client: *SurrealClient) !types.QueryResult(Document) {
    const allocator = client.allocator;
    const sql = "SELECT * FROM knowledge_document ORDER BY path";

    const response = try client.executeQuery(sql);
    defer allocator.free(response);

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, response, .{}) catch {
        return types.QueryResult(Document).empty(allocator);
    };
    defer parsed.deinit();

    const items = surreal.extractResult(parsed.value) orelse {
        return types.QueryResult(Document).empty(allocator);
    };

    if (items.len == 0) {
        return types.QueryResult(Document).empty(allocator);
    }

    const docs = try allocator.alloc(Document, items.len);
    for (items, 0..) |item, i| {
        if (item != .object) {
            docs[i] = .{};
            continue;
        }
        docs[i] = .{
            .path = surreal.getString(item.object, "path"),
            .name = surreal.getString(item.object, "name"),
            .extension = surreal.getString(item.object, "extension"),
            .size = surreal.getInt(item.object, "size"),
            .content_hash = surreal.getString(item.object, "content_hash"),
            .ingested_at = surreal.getString(item.object, "ingested_at"),
        };
    }

    return .{
        .items = docs,
        .total_count = docs.len,
        .allocator = allocator,
    };
}
