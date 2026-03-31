// CSV parser for image batch processing
// Parses CSV files into ImageBatchRequest arrays
// Supports both batch mode (prompt only) and per-prompt mode (provider + settings per row)

const std = @import("std");
const types = @import("types.zig");
const media_types = @import("../types.zig");

const ImageProvider = media_types.ImageProvider;
const Quality = media_types.Quality;
const Style = media_types.Style;
const Background = media_types.Background;

pub const ParseError = error{
    InvalidHeader,
    MissingPrompt,
    InvalidProvider,
    EmptyFile,
    NoValidRequests,
    FieldCountMismatch,
    FileOpenFailed,
    FileSizeError,
    FileTooLarge,
    ReadError,
    PathTooLong,
};

/// Column indices parsed from the header
const HeaderMap = struct {
    prompt: ?usize = null,
    provider: ?usize = null,
    size: ?usize = null,
    quality: ?usize = null,
    style: ?usize = null,
    aspect_ratio: ?usize = null,
    template: ?usize = null,
    filename: ?usize = null,
    count: ?usize = null,
    background: ?usize = null,
    // notes column is parsed but ignored
    column_count: usize = 0,

    pub fn isBatchMode(self: HeaderMap) bool {
        return self.provider == null;
    }
};

// Extern C file functions for Zig 0.16 compatibility
const FILE = std.c.FILE;
const SEEK_END: c_int = 2;
const SEEK_SET: c_int = 0;
extern "c" fn fseek(stream: *FILE, offset: c_long, whence: c_int) c_int;
extern "c" fn ftell(stream: *FILE) c_long;
extern "c" fn fread(ptr: [*]u8, size: usize, nmemb: usize, stream: *FILE) usize;

/// Parse a CSV file from disk into ImageBatchRequest array
pub fn parseFile(allocator: std.mem.Allocator, file_path: []const u8) ![]types.ImageBatchRequest {
    // Read file using C stdio (Zig 0.16 compatible)
    var path_buf: [4096]u8 = undefined;
    const path_z = std.fmt.bufPrintZ(&path_buf, "{s}", .{file_path}) catch return error.PathTooLong;

    const file = std.c.fopen(path_z, "rb") orelse return error.FileOpenFailed;
    defer _ = std.c.fclose(file);

    _ = fseek(file, 0, SEEK_END);
    const size_long = ftell(file);
    if (size_long < 0) return error.FileSizeError;
    const size: usize = @intCast(size_long);
    _ = fseek(file, 0, SEEK_SET);

    if (size > 10 * 1024 * 1024) return error.FileTooLarge; // 10MB max
    if (size == 0) return error.EmptyFile;

    const content = try allocator.alloc(u8, size);
    defer allocator.free(content);

    const read_count = fread(content.ptr, 1, size, file);
    if (read_count != size) return error.ReadError;

    return parseContent(allocator, content);
}

/// Parse CSV content string into ImageBatchRequest array
pub fn parseContent(allocator: std.mem.Allocator, content: []const u8) ![]types.ImageBatchRequest {
    var requests: std.ArrayList(types.ImageBatchRequest) = .empty;
    errdefer {
        for (requests.items) |*req| req.deinit();
        requests.deinit(allocator);
    }

    var line_iter = std.mem.splitScalar(u8, content, '\n');

    // Parse header
    const header_line = line_iter.next() orelse return error.EmptyFile;
    const header = try parseHeader(allocator, header_line);

    if (header.prompt == null) {
        std.debug.print("Error: CSV must have a 'prompt' column\n", .{});
        return error.InvalidHeader;
    }

    // Parse data rows
    var id: u32 = 1;
    while (line_iter.next()) |line| {
        if (line.len == 0 or isWhitespace(line)) continue;

        const request = parseRow(allocator, line, header, id) catch |err| {
            std.debug.print("Warning: Skipping row {}: {}\n", .{ id, err });
            id += 1;
            continue;
        };

        try requests.append(allocator, request);
        id += 1;
    }

    if (requests.items.len == 0) {
        std.debug.print("Error: No valid requests found in CSV\n", .{});
        return error.NoValidRequests;
    }

    return requests.toOwnedSlice(allocator);
}

/// Check if the parsed header indicates batch mode (no provider column)
pub fn isBatchMode(content: []const u8) bool {
    var line_iter = std.mem.splitScalar(u8, content, '\n');
    const header_line = line_iter.next() orelse return true;

    // Quick check: does the header contain "provider"?
    var field_iter = std.mem.splitScalar(u8, header_line, ',');
    while (field_iter.next()) |field| {
        const trimmed = std.mem.trim(u8, field, &std.ascii.whitespace);
        const cleaned = std.mem.trim(u8, trimmed, "\"");
        if (std.mem.eql(u8, cleaned, "provider")) return false;
    }
    return true;
}

/// Parse the CSV header row and return column index mapping
fn parseHeader(allocator: std.mem.Allocator, header_line: []const u8) !HeaderMap {
    const fields = try parseFields(allocator, header_line);
    defer {
        for (fields) |field| allocator.free(field);
        allocator.free(fields);
    }

    var header = HeaderMap{};
    header.column_count = fields.len;

    for (fields, 0..) |field, i| {
        const name = std.mem.trim(u8, field, &std.ascii.whitespace);

        if (std.mem.eql(u8, name, "prompt")) {
            header.prompt = i;
        } else if (std.mem.eql(u8, name, "provider")) {
            header.provider = i;
        } else if (std.mem.eql(u8, name, "size")) {
            header.size = i;
        } else if (std.mem.eql(u8, name, "quality")) {
            header.quality = i;
        } else if (std.mem.eql(u8, name, "style")) {
            header.style = i;
        } else if (std.mem.eql(u8, name, "aspect_ratio")) {
            header.aspect_ratio = i;
        } else if (std.mem.eql(u8, name, "template")) {
            header.template = i;
        } else if (std.mem.eql(u8, name, "filename")) {
            header.filename = i;
        } else if (std.mem.eql(u8, name, "count")) {
            header.count = i;
        } else if (std.mem.eql(u8, name, "background")) {
            header.background = i;
        }
        // 'notes' and other columns are silently ignored
    }

    return header;
}

/// Parse a single CSV row into an ImageBatchRequest
fn parseRow(
    allocator: std.mem.Allocator,
    line: []const u8,
    header: HeaderMap,
    id: u32,
) !types.ImageBatchRequest {
    const fields = try parseFields(allocator, line);
    defer {
        for (fields) |field| allocator.free(field);
        allocator.free(fields);
    }

    if (fields.len < header.column_count) {
        // Allow fewer fields (trailing empty columns)
        // but not fewer than the prompt column
        if (header.prompt) |pi| {
            if (fields.len <= pi) return error.FieldCountMismatch;
        }
    }

    var request = types.ImageBatchRequest{
        .id = id,
        .prompt = undefined,
        .allocator = allocator,
    };

    // Extract prompt (required)
    if (header.prompt) |pi| {
        if (pi < fields.len) {
            const value = std.mem.trim(u8, fields[pi], &std.ascii.whitespace);
            if (value.len == 0) return error.MissingPrompt;
            request.prompt = try allocator.dupe(u8, value);
        } else {
            return error.MissingPrompt;
        }
    } else {
        return error.MissingPrompt;
    }
    errdefer allocator.free(request.prompt);

    // Extract optional fields
    if (header.provider) |pi| {
        if (pi < fields.len) {
            const value = std.mem.trim(u8, fields[pi], &std.ascii.whitespace);
            if (value.len > 0) {
                request.provider = ImageProvider.fromString(value);
                if (request.provider == null) {
                    std.debug.print("Warning: Unknown provider '{s}' in row {}\n", .{ value, id });
                }
            }
        }
    }

    if (header.size) |si| {
        if (si < fields.len) {
            const value = std.mem.trim(u8, fields[si], &std.ascii.whitespace);
            if (value.len > 0) {
                request.size = try allocator.dupe(u8, value);
            }
        }
    }

    if (header.quality) |qi| {
        if (qi < fields.len) {
            const value = std.mem.trim(u8, fields[qi], &std.ascii.whitespace);
            if (value.len > 0) {
                request.quality = Quality.fromString(value);
            }
        }
    }

    if (header.style) |si| {
        if (si < fields.len) {
            const value = std.mem.trim(u8, fields[si], &std.ascii.whitespace);
            if (value.len > 0) {
                request.style = Style.fromString(value);
            }
        }
    }

    if (header.aspect_ratio) |ai_idx| {
        if (ai_idx < fields.len) {
            const value = std.mem.trim(u8, fields[ai_idx], &std.ascii.whitespace);
            if (value.len > 0) {
                request.aspect_ratio = try allocator.dupe(u8, value);
            }
        }
    }

    if (header.template) |ti| {
        if (ti < fields.len) {
            const value = std.mem.trim(u8, fields[ti], &std.ascii.whitespace);
            if (value.len > 0) {
                request.template = try allocator.dupe(u8, value);
            }
        }
    }

    if (header.filename) |fi| {
        if (fi < fields.len) {
            const value = std.mem.trim(u8, fields[fi], &std.ascii.whitespace);
            if (value.len > 0) {
                request.filename = try allocator.dupe(u8, value);
            }
        }
    }

    if (header.count) |ci| {
        if (ci < fields.len) {
            const value = std.mem.trim(u8, fields[ci], &std.ascii.whitespace);
            if (value.len > 0) {
                request.count = std.fmt.parseInt(u8, value, 10) catch 1;
            }
        }
    }

    if (header.background) |bi| {
        if (bi < fields.len) {
            const value = std.mem.trim(u8, fields[bi], &std.ascii.whitespace);
            if (value.len > 0) {
                if (std.mem.eql(u8, value, "transparent")) {
                    request.background = .transparent;
                } else if (std.mem.eql(u8, value, "opaque")) {
                    request.background = .@"opaque";
                }
            }
        }
    }

    return request;
}

/// Parse CSV fields, handling quoted strings with escaped quotes
fn parseFields(allocator: std.mem.Allocator, line: []const u8) ![][]const u8 {
    var fields: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (fields.items) |field| allocator.free(field);
        fields.deinit(allocator);
    }

    var field: std.ArrayList(u8) = .empty;
    defer field.deinit(allocator);

    var in_quotes = false;
    var i: usize = 0;

    while (i < line.len) : (i += 1) {
        const c = line[i];

        if (c == '"') {
            if (in_quotes and i + 1 < line.len and line[i + 1] == '"') {
                // Escaped quote
                try field.append(allocator, '"');
                i += 1;
            } else {
                // Toggle quote mode
                in_quotes = !in_quotes;
            }
        } else if (c == ',' and !in_quotes) {
            // End of field
            try fields.append(allocator, try field.toOwnedSlice(allocator));
            field = std.ArrayList(u8).empty;
        } else if (c == '\r') {
            // Skip carriage return (Windows line endings)
            continue;
        } else {
            try field.append(allocator, c);
        }
    }

    // Last field
    try fields.append(allocator, try field.toOwnedSlice(allocator));

    return fields.toOwnedSlice(allocator);
}

/// Check if line is only whitespace
fn isWhitespace(line: []const u8) bool {
    for (line) |c| {
        if (!std.ascii.isWhitespace(c)) return false;
    }
    return true;
}

// ============================================================================
// Tests
// ============================================================================

test "parse minimal batch CSV" {
    const allocator = std.testing.allocator;

    const csv =
        \\prompt
        \\a cosmic duck floating in space
        \\quantum computer visualization
    ;

    const requests = try parseContent(allocator, csv);
    defer {
        for (requests) |*req| req.deinit();
        allocator.free(requests);
    }

    try std.testing.expectEqual(@as(usize, 2), requests.len);
    try std.testing.expectEqualStrings("a cosmic duck floating in space", requests[0].prompt);
    try std.testing.expectEqualStrings("quantum computer visualization", requests[1].prompt);
    try std.testing.expect(requests[0].provider == null);
}

test "parse filename+prompt CSV (harvesting-engine format)" {
    const allocator = std.testing.allocator;

    const csv =
        \\filename,prompt
        \\cosmic-duck,"a cosmic duck floating in space"
        \\quantum-viz,"quantum computer visualization"
    ;

    const requests = try parseContent(allocator, csv);
    defer {
        for (requests) |*req| req.deinit();
        allocator.free(requests);
    }

    try std.testing.expectEqual(@as(usize, 2), requests.len);
    try std.testing.expectEqualStrings("a cosmic duck floating in space", requests[0].prompt);
    try std.testing.expectEqualStrings("cosmic-duck", requests[0].filename.?);
    try std.testing.expect(requests[0].provider == null);
}

test "parse per-prompt CSV with provider" {
    const allocator = std.testing.allocator;

    const csv =
        \\prompt,provider,quality,size
        \\cosmic duck,gpt-image-15,high,1024x1024
        \\quantum viz,dalle3,hd,
    ;

    const requests = try parseContent(allocator, csv);
    defer {
        for (requests) |*req| req.deinit();
        allocator.free(requests);
    }

    try std.testing.expectEqual(@as(usize, 2), requests.len);
    try std.testing.expectEqual(ImageProvider.gpt_image_15, requests[0].provider.?);
    try std.testing.expectEqual(Quality.high, requests[0].quality.?);
    try std.testing.expectEqualStrings("1024x1024", requests[0].size.?);
    try std.testing.expectEqual(ImageProvider.dalle3, requests[1].provider.?);
    try std.testing.expectEqual(Quality.hd, requests[1].quality.?);
    try std.testing.expect(requests[1].size == null);
}

test "isBatchMode detection" {
    try std.testing.expect(isBatchMode("prompt\ntest\n"));
    try std.testing.expect(isBatchMode("filename,prompt\ntest,test\n"));
    try std.testing.expect(!isBatchMode("prompt,provider\ntest,dalle3\n"));
}

test "parse CSV with quoted fields containing commas" {
    const allocator = std.testing.allocator;

    const csv =
        \\prompt,provider
        \\"a duck, flying in space",gpt-image-15
    ;

    const requests = try parseContent(allocator, csv);
    defer {
        for (requests) |*req| req.deinit();
        allocator.free(requests);
    }

    try std.testing.expectEqual(@as(usize, 1), requests.len);
    try std.testing.expectEqualStrings("a duck, flying in space", requests[0].prompt);
}
