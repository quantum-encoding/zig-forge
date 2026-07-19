// Copyright (c) 2025 QUANTUM ENCODING LTD
//
//! Multi-format input ingestion for quantum-curl.
//!
//! Auto-detects and converts CSV, TSV, JSON array, and JSONL into RequestManifest.
//! As long as the user provides the right fields (url required, rest optional),
//! quantum-curl handles the transformation.
//!
//! ## Supported Formats
//!
//! **JSONL** (default): One JSON object per line
//! ```
//! {"id":"1","method":"POST","url":"https://api.example.com","body":"..."}
//! ```
//!
//! **JSON Array**: Array of request objects
//! ```json
//! [{"id":"1","url":"https://example.com"}, {"id":"2","url":"https://example.com/other"}]
//! ```
//!
//! **CSV**: Header row + data rows (comma-separated)
//! ```
//! id,method,url,body
//! 1,POST,https://api.example.com,{"key":"value"}
//! 2,GET,https://api.example.com/health,
//! ```
//!
//! **TSV**: Header row + data rows (tab-separated)
//!
//! ## Field Mapping
//!
//! | Field        | Required | Default | Description                    |
//! |-------------|----------|---------|--------------------------------|
//! | url         | YES      | -       | Full URL with scheme           |
//! | id          | no       | auto    | Auto-generated: row-1, row-2   |
//! | method      | no       | GET     | HTTP method                    |
//! | body        | no       | null    | Request body                   |
//! | headers     | no       | null    | JSON object string in CSV      |
//! | timeout_ms  | no       | null    | Per-request timeout override   |
//! | max_retries | no       | null    | Per-request retry override     |

const std = @import("std");
const manifest = @import("manifest.zig");
const fail_log = @import("fail_log.zig");

pub const InputFormat = enum {
    jsonl,
    json_array,
    csv,
    tsv,
};

/// Detect the input format from file extension and/or content.
pub fn detectFormat(file_path: ?[]const u8, content: []const u8) InputFormat {
    // Check file extension first
    if (file_path) |path| {
        if (endsWith(path, ".csv")) return .csv;
        if (endsWith(path, ".tsv")) return .tsv;
        if (endsWith(path, ".json")) return .json_array;
        if (endsWith(path, ".jsonl") or endsWith(path, ".ndjson")) return .jsonl;
    }

    // Content sniffing — look at the first non-whitespace character
    const trimmed = std.mem.trim(u8, content[0..@min(content.len, 256)], &std.ascii.whitespace);
    if (trimmed.len == 0) return .jsonl;

    if (trimmed[0] == '[') return .json_array;
    if (trimmed[0] == '{') return .jsonl;

    // Not JSON — check for tabs (TSV) or commas (CSV) in first line
    const first_line_end = std.mem.indexOfScalar(u8, trimmed, '\n') orelse trimmed.len;
    const first_line = trimmed[0..first_line_end];

    if (std.mem.indexOfScalar(u8, first_line, '\t') != null) return .tsv;
    return .csv; // Default to CSV for non-JSON tabular data
}

/// Parse input content in any supported format into RequestManifests.
/// If fail_logger is provided, parse errors are logged to it.
pub fn parseInput(
    allocator: std.mem.Allocator,
    content: []const u8,
    file_path: ?[]const u8,
    requests: *std.ArrayList(manifest.RequestManifest),
    fail_logger: ?*fail_log.FailLogger,
) !void {
    const format = detectFormat(file_path, content);

    switch (format) {
        .jsonl => try parseJsonLines(allocator, content, requests, fail_logger),
        .json_array => try parseJsonArray(allocator, content, requests),
        .csv => try parseDelimited(allocator, content, ',', requests),
        .tsv => try parseDelimited(allocator, content, '\t', requests),
    }

    std.debug.print("[quantum-curl] Ingested {} requests from {s} format\n", .{
        requests.items.len,
        @tagName(format),
    });
}

// ── JSONL parser ─────────────────────────────────────────────────────────────

fn parseJsonLines(
    allocator: std.mem.Allocator,
    content: []const u8,
    requests: *std.ArrayList(manifest.RequestManifest),
    fail_logger: ?*fail_log.FailLogger,
) !void {
    var line_iter = std.mem.splitScalar(u8, content, '\n');
    var line_num: u32 = 0;

    while (line_iter.next()) |line| {
        line_num += 1;
        const trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);
        if (trimmed.len == 0) continue;

        var request = manifest.parseRequestManifest(allocator, trimmed) catch |err| {
            std.debug.print("[ingest] Error parsing JSONL line {}: {}\n", .{ line_num, err });
            if (fail_logger) |fl| {
                fl.logParseError(trimmed, line_num, @errorName(err));
            }
            continue;
        };

        // Capture the original raw line for failure replay.
        // We dupe it because the outer `content` buffer is freed after parsing.
        request.raw_line = allocator.dupe(u8, trimmed) catch null;
        request.source_line = line_num;

        try requests.append(allocator, request);
    }
}

// ── JSON Array parser ────────────────────────────────────────────────────────

fn parseJsonArray(
    allocator: std.mem.Allocator,
    content: []const u8,
    requests: *std.ArrayList(manifest.RequestManifest),
) !void {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, content, .{}) catch {
        std.debug.print("[ingest] Error: invalid JSON array\n", .{});
        return;
    };
    defer parsed.deinit();

    if (parsed.value != .array) {
        std.debug.print("[ingest] Error: expected JSON array, got {s}\n", .{@tagName(parsed.value)});
        return;
    }

    for (parsed.value.array.items, 0..) |item, i| {
        if (item != .object) continue;
        const obj = item.object;

        var id_buf: [32]u8 = undefined;
        const gen_id = std.fmt.bufPrint(&id_buf, "row-{}", .{i + 1}) catch "row-?";

        // Use existing id if present, otherwise auto-generate. A non-string id
        // used to panic on `.string`; fall back to the generated id instead.
        const id_str = blk: {
            const id_val = obj.get("id") orelse break :blk gen_id;
            if (id_val != .string) {
                std.debug.print("[ingest] Warning: element {} has non-string id, using {s}\n", .{ i + 1, gen_id });
                break :blk gen_id;
            }
            break :blk id_val.string;
        };

        addRequestFromObj(allocator, obj, id_str, requests) catch |err| {
            std.debug.print("[ingest] Error parsing JSON array element {}: {}\n", .{ i + 1, err });
            continue;
        };
    }
}

// ── CSV/TSV parser ───────────────────────────────────────────────────────────

fn parseDelimited(
    allocator: std.mem.Allocator,
    content: []const u8,
    delimiter: u8,
    requests: *std.ArrayList(manifest.RequestManifest),
) !void {
    var line_iter = std.mem.splitScalar(u8, content, '\n');

    // First line is the header
    const header_line = line_iter.next() orelse return;
    const header = std.mem.trim(u8, header_line, &std.ascii.whitespace);
    if (header.len == 0) return;

    // Parse header columns
    var col_names: [32][]const u8 = undefined;
    var num_cols: usize = 0;
    var header_iter = std.mem.splitScalar(u8, header, delimiter);
    while (header_iter.next()) |col| {
        if (num_cols >= 32) break;
        col_names[num_cols] = std.mem.trim(u8, col, &std.ascii.whitespace);
        num_cols += 1;
    }

    // Find column indices for known fields
    const url_col = findCol(col_names[0..num_cols], "url") orelse {
        std.debug.print("[ingest] Error: CSV must have a 'url' column\n", .{});
        return;
    };
    const id_col = findCol(col_names[0..num_cols], "id");
    const method_col = findCol(col_names[0..num_cols], "method");
    const body_col = findCol(col_names[0..num_cols], "body");
    const headers_col = findCol(col_names[0..num_cols], "headers");
    const timeout_col = findCol(col_names[0..num_cols], "timeout_ms");
    const retries_col = findCol(col_names[0..num_cols], "max_retries");

    // Parse data rows
    var row_num: usize = 0;
    while (line_iter.next()) |line| {
        row_num += 1;
        const trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);
        if (trimmed.len == 0) continue;

        // Split row into fields
        var fields: [32][]const u8 = undefined;
        var num_fields: usize = 0;

        // CSV-aware splitting: handle quoted fields containing the delimiter
        var field_iter = CsvFieldIterator.init(trimmed, delimiter);
        while (field_iter.next()) |field| {
            if (num_fields >= 32) break;
            fields[num_fields] = field;
            num_fields += 1;
        }

        // Extract URL (required)
        if (url_col >= num_fields) continue;
        const url_raw = fields[url_col];
        if (url_raw.len == 0) continue;
        const url = try allocator.dupe(u8, url_raw);
        errdefer allocator.free(url);

        // Extract ID (optional, auto-generate)
        const id = if (id_col != null and id_col.? < num_fields and fields[id_col.?].len > 0)
            try allocator.dupe(u8, fields[id_col.?])
        else blk: {
            var id_buf: [32]u8 = undefined;
            const auto_id = std.fmt.bufPrint(&id_buf, "row-{}", .{row_num}) catch "row-?";
            break :blk try allocator.dupe(u8, auto_id);
        };
        errdefer allocator.free(id);

        // Extract method (optional, default GET)
        const method_str = if (method_col != null and method_col.? < num_fields and fields[method_col.?].len > 0)
            fields[method_col.?]
        else
            "GET";
        const method = manifest.Method.fromString(method_str) orelse .GET;

        // Extract body (optional)
        var body: ?[]u8 = null;
        if (body_col != null and body_col.? < num_fields and fields[body_col.?].len > 0) {
            body = try allocator.dupe(u8, fields[body_col.?]);
        }

        // Extract headers (optional — JSON object string in CSV)
        var headers: ?std.json.ArrayHashMap([]const u8) = null;
        if (headers_col != null and headers_col.? < num_fields and fields[headers_col.?].len > 0) {
            const hdr_str = fields[headers_col.?];
            if (hdr_str.len > 2 and hdr_str[0] == '{') {
                headers = parseHeadersString(allocator, hdr_str) catch null;
            }
        }

        // Extract timeout_ms (optional)
        var timeout_ms: ?u64 = null;
        if (timeout_col != null and timeout_col.? < num_fields and fields[timeout_col.?].len > 0) {
            timeout_ms = std.fmt.parseInt(u64, fields[timeout_col.?], 10) catch null;
        }

        // Extract max_retries (optional)
        var max_retries: ?u32 = null;
        if (retries_col != null and retries_col.? < num_fields and fields[retries_col.?].len > 0) {
            max_retries = std.fmt.parseInt(u32, fields[retries_col.?], 10) catch null;
        }

        try requests.append(allocator, .{
            .id = id,
            .method = method,
            .url = url,
            .headers = headers,
            .body = body,
            .timeout_ms = timeout_ms,
            .max_retries = max_retries,
            .allocator = allocator,
        });
    }
}

// ── CSV field iterator (handles quoted fields) ───────────────────────────────

/// RFC 4180 field splitter for a *single* record.
///
/// Known deviation from RFC 4180 §2 rule 6: a newline inside a quoted field is
/// NOT supported, because `parseDelimited` splits the document on `\n` before
/// this iterator ever sees a record. Escaped quotes (`""`, rule 7) are returned
/// verbatim rather than unescaped — callers get the raw inner bytes. Both are
/// asserted in `src/tier1_anchors.zig` so the limitation is a tested contract
/// rather than a silent surprise.
pub const CsvFieldIterator = struct {
    data: []const u8,
    pos: usize,
    delimiter: u8,

    /// Is another field available? A record always has at least one field, and
    /// exactly one more after every delimiter consumed. Without this flag the
    /// iterator appended a phantom empty field to every record that did not end
    /// in a delimiter — `a,b,c` yielded four fields instead of RFC 4180's three,
    /// which shifted every column index past a short row.
    pending: bool,

    pub fn init(data: []const u8, delimiter: u8) CsvFieldIterator {
        return .{ .data = data, .pos = 0, .delimiter = delimiter, .pending = true };
    }

    pub fn next(self: *CsvFieldIterator) ?[]const u8 {
        if (!self.pending) return null;

        if (self.pos >= self.data.len) {
            self.pending = false;
            return ""; // trailing delimiter promised one final, empty field
        }

        if (self.data[self.pos] == '"') {
            // Quoted field — find the matching close quote, skipping `""` pairs.
            const start = self.pos + 1;
            var end = start;
            while (end < self.data.len) {
                if (self.data[end] == '"') {
                    if (end + 1 < self.data.len and self.data[end + 1] == '"') {
                        end += 2; // Escaped quote "" (returned verbatim)
                        continue;
                    }
                    break; // End of quoted field
                }
                end += 1;
            }

            var p = end;
            if (p < self.data.len and self.data[p] == '"') p += 1; // past close quote
            self.advancePast(p);
            return self.data[start..end];
        }

        // Unquoted field — find next delimiter
        const start = self.pos;
        var p = self.pos;
        while (p < self.data.len and self.data[p] != self.delimiter) p += 1;
        const field = self.data[start..p];
        self.advancePast(p);
        return field;
    }

    /// Position after a field body: consume one delimiter if present (another
    /// field follows), otherwise the record is exhausted.
    fn advancePast(self: *CsvFieldIterator, p: usize) void {
        // Tolerate stray bytes between a closing quote and the delimiter
        // (`"a"junk,b`) by discarding them rather than dropping the rest of
        // the record.
        var i = p;
        while (i < self.data.len and self.data[i] != self.delimiter) i += 1;

        if (i < self.data.len) {
            self.pos = i + 1; // consume the delimiter; another field follows
            self.pending = true;
        } else {
            self.pos = self.data.len;
            self.pending = false;
        }
    }
};

// ── Helpers ──────────────────────────────────────────────────────────────────

fn findCol(names: []const []const u8, target: []const u8) ?usize {
    for (names, 0..) |name, i| {
        if (eqlInsensitive(name, target)) return i;
    }
    return null;
}

fn eqlInsensitive(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        if (toLower(ca) != toLower(cb)) return false;
    }
    return true;
}

fn toLower(c: u8) u8 {
    return if (c >= 'A' and c <= 'Z') c + 32 else c;
}

fn endsWith(haystack: []const u8, suffix: []const u8) bool {
    if (haystack.len < suffix.len) return false;
    return std.mem.eql(u8, haystack[haystack.len - suffix.len ..], suffix);
}

fn addRequestFromObj(
    allocator: std.mem.Allocator,
    obj: std.json.ObjectMap,
    gen_id: []const u8,
    requests: *std.ArrayList(manifest.RequestManifest),
) !void {
    const id = try allocator.dupe(u8, gen_id);
    errdefer allocator.free(id);

    // Every access below is typed-checked: a JSON array element with a wrong-
    // shaped field returns an error the caller logs and skips, rather than
    // panicking the whole batch (see manifest.ParseError).
    const method_str = blk: {
        const m = obj.get("method") orelse break :blk "GET";
        if (m != .string) return error.InvalidType;
        break :blk m.string;
    };
    const method = manifest.Method.fromString(method_str) orelse .GET;

    const url_val = obj.get("url") orelse return error.MissingUrl;
    if (url_val != .string) return error.InvalidType;
    const url = try allocator.dupe(u8, url_val.string);
    errdefer allocator.free(url);

    var body: ?[]u8 = null;
    errdefer if (body) |b| allocator.free(b);
    if (obj.get("body")) |b| {
        if (b == .string) body = try allocator.dupe(u8, b.string);
    }

    const timeout_ms = try manifest.optionalUnsigned(u64, obj, "timeout_ms");
    const max_retries = try manifest.optionalUnsigned(u32, obj, "max_retries");

    try requests.append(allocator, .{
        .id = id,
        .method = method,
        .url = url,
        .body = body,
        .timeout_ms = timeout_ms,
        .max_retries = max_retries,
        .allocator = allocator,
    });
}

fn parseHeadersString(allocator: std.mem.Allocator, json_str: []const u8) !std.json.ArrayHashMap([]const u8) {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_str, .{});
    defer parsed.deinit();

    if (parsed.value != .object) return error.InvalidHeaders;

    var headers = std.json.ArrayHashMap([]const u8){};
    var it = parsed.value.object.iterator();
    while (it.next()) |entry| {
        // Non-string header value used to panic on `.string`.
        if (entry.value_ptr.* != .string) return error.InvalidHeaders;
        const key = try allocator.dupe(u8, entry.key_ptr.*);
        errdefer allocator.free(key);
        const val = try allocator.dupe(u8, entry.value_ptr.*.string);
        errdefer allocator.free(val);
        try headers.map.put(allocator, key, val);
    }
    return headers;
}
