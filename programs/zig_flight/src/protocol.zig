//! X-Plane 12 WebSocket/REST API protocol handling.
//!
//! Message construction uses stack buffers (zero allocation).
//! Update parsing uses manual scanning (zero allocation in hot path).
//! REST response parsing uses std.json (one-time at startup).

const std = @import("std");

/// A single dataref update: ID mapped to a float value
pub const DatarefUpdate = struct {
    id: u64,
    value: f64,
};

/// Batch of updates from a single WebSocket message
pub const UpdateBatch = struct {
    updates: [MAX_UPDATES_PER_MSG]DatarefUpdate = undefined,
    count: usize = 0,

    pub const MAX_UPDATES_PER_MSG = 128;
};

/// Message types from X-Plane WebSocket API
pub const MessageType = enum {
    result,
    dataref_update_values,
    unknown,
};

/// Result of parsing a REST dataref lookup
pub const DatarefInfo = struct {
    id: u64,
    name: []const u8,
    value_type: []const u8,
};

// ============================================================================
// Message Construction (Client → X-Plane)
// ============================================================================

/// Build a dataref_subscribe_values JSON message.
/// Format: {"req_id":N,"type":"dataref_subscribe_values","params":{"datarefs":[{"id":1},{"id":2}]}}
pub fn buildSubscribeMessage(buf: []u8, req_id: u64, ids: []const u64) ![]const u8 {
    var pos: usize = 0;

    const prefix = std.fmt.bufPrint(buf[pos..], "{{\"req_id\":{d},\"type\":\"dataref_subscribe_values\",\"params\":{{\"datarefs\":[", .{req_id}) catch return error.NoSpaceLeft;
    pos += prefix.len;

    for (ids, 0..) |id, i| {
        if (i > 0) {
            if (pos >= buf.len) return error.NoSpaceLeft;
            buf[pos] = ',';
            pos += 1;
        }
        const entry = std.fmt.bufPrint(buf[pos..], "{{\"id\":{d}}}", .{id}) catch return error.NoSpaceLeft;
        pos += entry.len;
    }

    const suffix = "]}}";
    if (pos + suffix.len > buf.len) return error.NoSpaceLeft;
    @memcpy(buf[pos..][0..suffix.len], suffix);
    pos += suffix.len;

    return buf[0..pos];
}

/// Build an unsubscribe-all message.
/// Format: {"req_id":N,"type":"dataref_unsubscribe_values","params":{"datarefs":"all"}}
pub fn buildUnsubscribeAllMessage(buf: []u8, req_id: u64) ![]const u8 {
    return std.fmt.bufPrint(buf, "{{\"req_id\":{d},\"type\":\"dataref_unsubscribe_values\",\"params\":{{\"datarefs\":\"all\"}}}}", .{req_id}) catch return error.NoSpaceLeft;
}

/// Build a dataref_set_values message.
/// Format: {"req_id":N,"type":"dataref_set_values","params":{"datarefs":[{"id":1,"value":42}]}}
pub fn buildSetValueMessage(buf: []u8, req_id: u64, id: u64, value: f64) ![]const u8 {
    return std.fmt.bufPrint(buf, "{{\"req_id\":{d},\"type\":\"dataref_set_values\",\"params\":{{\"datarefs\":[{{\"id\":{d},\"value\":{d}}}]}}}}", .{ req_id, id, value }) catch return error.NoSpaceLeft;
}

// ============================================================================
// Message Parsing (X-Plane → Client)
// ============================================================================

/// Detect the message type from a raw JSON buffer without full parsing.
pub fn detectMessageType(data: []const u8) MessageType {
    if (findStringValue(data, "\"type\"")) |type_val| {
        if (std.mem.eql(u8, type_val, "dataref_update_values")) return .dataref_update_values;
        if (std.mem.eql(u8, type_val, "result")) return .result;
    }
    return .unknown;
}

/// Parse a dataref_update_values message with zero allocation.
/// Extracts ID→value pairs directly from the JSON buffer.
/// Format: {"type":"dataref_update_values","data":{"88491":0,"3994":5.2}}
pub fn parseUpdateValues(data: []const u8) !UpdateBatch {
    var batch = UpdateBatch{};

    // Find "data":{ in the buffer
    const data_key = "\"data\":{";
    const data_start = std.mem.indexOf(u8, data, data_key) orelse return error.MissingDataField;
    var pos = data_start + data_key.len;

    // Parse key-value pairs: "12345":67.89
    while (pos < data.len and batch.count < UpdateBatch.MAX_UPDATES_PER_MSG) {
        // Skip whitespace
        while (pos < data.len and isWhitespace(data[pos])) : (pos += 1) {}

        if (pos >= data.len) break;

        // Check for closing brace
        if (data[pos] == '}') break;

        // Skip comma between entries
        if (data[pos] == ',') {
            pos += 1;
            continue;
        }

        // Expect opening quote for key
        if (data[pos] != '"') {
            pos += 1;
            continue;
        }
        pos += 1; // skip opening quote

        // Read key (numeric string)
        const key_start = pos;
        while (pos < data.len and data[pos] != '"') : (pos += 1) {}
        if (pos >= data.len) break;
        const key_str = data[key_start..pos];
        pos += 1; // skip closing quote

        // Skip colon
        while (pos < data.len and (isWhitespace(data[pos]) or data[pos] == ':')) : (pos += 1) {}

        // Read value — can be number, array, or null
        const value_start = pos;

        if (pos < data.len and data[pos] == '[') {
            // Array value — skip to matching ]
            // For now, take the first element
            pos += 1; // skip [
            while (pos < data.len and isWhitespace(data[pos])) : (pos += 1) {}
            const arr_val_start = pos;
            while (pos < data.len and data[pos] != ',' and data[pos] != ']') : (pos += 1) {}
            const arr_first = data[arr_val_start..pos];
            // Skip to end of array
            while (pos < data.len and data[pos] != ']') : (pos += 1) {}
            if (pos < data.len) pos += 1; // skip ]

            const id = std.fmt.parseInt(u64, key_str, 10) catch continue;
            const value = std.fmt.parseFloat(f64, arr_first) catch 0.0;
            batch.updates[batch.count] = .{ .id = id, .value = value };
            batch.count += 1;
        } else {
            // Scalar value
            while (pos < data.len and data[pos] != ',' and data[pos] != '}' and !isWhitespace(data[pos])) : (pos += 1) {}
            const value_str = data[value_start..pos];

            const id = std.fmt.parseInt(u64, key_str, 10) catch continue;
            const value = std.fmt.parseFloat(f64, value_str) catch 0.0;
            batch.updates[batch.count] = .{ .id = id, .value = value };
            batch.count += 1;
        }
    }

    return batch;
}

/// Parse a result message to check success/failure.
pub fn parseResult(data: []const u8) bool {
    if (std.mem.indexOf(u8, data, "\"success\":true")) |_| return true;
    if (std.mem.indexOf(u8, data, "\"success\": true")) |_| return true;
    return false;
}

/// Parse a REST API dataref lookup response.
/// Input: {"data":[{"id":9952311,"name":"sim/...","value_type":"float"}]}
pub fn parseDatarefLookup(allocator: std.mem.Allocator, json_data: []const u8) !DatarefInfo {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_data, .{
        .allocate = .alloc_always,
    });
    defer parsed.deinit();

    const root = parsed.value;
    const data_array = switch (root) {
        .object => |obj| obj.get("data") orelse return error.MissingDataField,
        else => return error.InvalidResponse,
    };

    const items = switch (data_array) {
        .array => |arr| arr.items,
        else => return error.InvalidResponse,
    };

    if (items.len == 0) return error.DatarefNotFound;

    const first = switch (items[0]) {
        .object => |obj| obj,
        else => return error.InvalidResponse,
    };

    const id_val = first.get("id") orelse return error.MissingIdField;
    const name_val = first.get("name") orelse return error.MissingNameField;
    const type_val = first.get("value_type") orelse return error.MissingTypeField;

    const id: u64 = switch (id_val) {
        .integer => |v| @intCast(v),
        .float => |v| @intFromFloat(v),
        else => return error.InvalidResponse,
    };

    const name = switch (name_val) {
        .string => |s| try allocator.dupe(u8, s),
        else => return error.InvalidResponse,
    };

    const value_type = switch (type_val) {
        .string => |s| try allocator.dupe(u8, s),
        else => {
            allocator.free(name);
            return error.InvalidResponse;
        },
    };

    return .{
        .id = id,
        .name = name,
        .value_type = value_type,
    };
}

/// Parse a REST dataref value response.
/// The response body is typically just a JSON value (number, string, array).
pub fn parseDatarefValue(data: []const u8) !f64 {
    const trimmed = std.mem.trim(u8, data, &.{ ' ', '\n', '\r', '\t' });
    // Try as bare number first
    if (std.fmt.parseFloat(f64, trimmed)) |v| return v else |_| {}
    // Try stripping quotes
    if (trimmed.len >= 2 and trimmed[0] == '"' and trimmed[trimmed.len - 1] == '"') {
        return std.fmt.parseFloat(f64, trimmed[1 .. trimmed.len - 1]) catch return error.InvalidResponse;
    }
    return error.InvalidResponse;
}

// ============================================================================
// Helpers
// ============================================================================

fn isWhitespace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r';
}

/// Find the string value following a key pattern like "type" in JSON.
/// Returns the unquoted value, or null if not found.
fn findStringValue(data: []const u8, key: []const u8) ?[]const u8 {
    const key_pos = std.mem.indexOf(u8, data, key) orelse return null;
    var pos = key_pos + key.len;

    // Skip whitespace and colon
    while (pos < data.len and (isWhitespace(data[pos]) or data[pos] == ':')) : (pos += 1) {}

    // Expect opening quote
    if (pos >= data.len or data[pos] != '"') return null;
    pos += 1;

    // Read until closing quote
    const value_start = pos;
    while (pos < data.len and data[pos] != '"') : (pos += 1) {}
    if (pos >= data.len) return null;

    return data[value_start..pos];
}

// ============================================================================
// Tests
// ============================================================================

test "buildSubscribeMessage" {
    var buf: [8192]u8 = undefined;
    const ids = [_]u64{ 123, 456, 789 };
    const msg = try buildSubscribeMessage(&buf, 1, &ids);

    try std.testing.expectEqualStrings(
        "{\"req_id\":1,\"type\":\"dataref_subscribe_values\",\"params\":{\"datarefs\":[{\"id\":123},{\"id\":456},{\"id\":789}]}}",
        msg,
    );
}

test "buildSubscribeMessage single id" {
    var buf: [8192]u8 = undefined;
    const ids = [_]u64{42};
    const msg = try buildSubscribeMessage(&buf, 99, &ids);

    try std.testing.expectEqualStrings(
        "{\"req_id\":99,\"type\":\"dataref_subscribe_values\",\"params\":{\"datarefs\":[{\"id\":42}]}}",
        msg,
    );
}

test "buildUnsubscribeAllMessage" {
    var buf: [512]u8 = undefined;
    const msg = try buildUnsubscribeAllMessage(&buf, 5);

    try std.testing.expectEqualStrings(
        "{\"req_id\":5,\"type\":\"dataref_unsubscribe_values\",\"params\":{\"datarefs\":\"all\"}}",
        msg,
    );
}

test "detectMessageType" {
    try std.testing.expectEqual(
        MessageType.dataref_update_values,
        detectMessageType("{\"type\":\"dataref_update_values\",\"data\":{}}"),
    );
    try std.testing.expectEqual(
        MessageType.result,
        detectMessageType("{\"req_id\":1,\"type\":\"result\",\"success\":true}"),
    );
    try std.testing.expectEqual(
        MessageType.unknown,
        detectMessageType("{\"type\":\"something_else\"}"),
    );
    try std.testing.expectEqual(
        MessageType.unknown,
        detectMessageType("not json at all"),
    );
}

test "parseUpdateValues basic" {
    const json = "{\"type\":\"dataref_update_values\",\"data\":{\"88491\":0,\"3994\":5.2,\"199\":100}}";
    const batch = try parseUpdateValues(json);

    try std.testing.expectEqual(@as(usize, 3), batch.count);
    try std.testing.expectEqual(@as(u64, 88491), batch.updates[0].id);
    try std.testing.expectEqual(@as(f64, 0.0), batch.updates[0].value);
    try std.testing.expectEqual(@as(u64, 3994), batch.updates[1].id);
    try std.testing.expectEqual(@as(f64, 5.2), batch.updates[1].value);
    try std.testing.expectEqual(@as(u64, 199), batch.updates[2].id);
    try std.testing.expectEqual(@as(f64, 100.0), batch.updates[2].value);
}

test "parseUpdateValues empty data" {
    const json = "{\"type\":\"dataref_update_values\",\"data\":{}}";
    const batch = try parseUpdateValues(json);
    try std.testing.expectEqual(@as(usize, 0), batch.count);
}

test "parseUpdateValues with array values" {
    const json = "{\"type\":\"dataref_update_values\",\"data\":{\"100\":[1.5,2.5,3.5],\"200\":42}}";
    const batch = try parseUpdateValues(json);

    try std.testing.expectEqual(@as(usize, 2), batch.count);
    // Array datarefs take first element
    try std.testing.expectEqual(@as(u64, 100), batch.updates[0].id);
    try std.testing.expectEqual(@as(f64, 1.5), batch.updates[0].value);
    try std.testing.expectEqual(@as(u64, 200), batch.updates[1].id);
    try std.testing.expectEqual(@as(f64, 42.0), batch.updates[1].value);
}

test "parseUpdateValues negative values" {
    const json = "{\"type\":\"dataref_update_values\",\"data\":{\"50\":-3.14,\"51\":-1000}}";
    const batch = try parseUpdateValues(json);

    try std.testing.expectEqual(@as(usize, 2), batch.count);
    try std.testing.expect(batch.updates[0].value < -3.13 and batch.updates[0].value > -3.15);
    try std.testing.expectEqual(@as(f64, -1000.0), batch.updates[1].value);
}

test "parseResult" {
    try std.testing.expect(parseResult("{\"req_id\":1,\"type\":\"result\",\"success\":true}"));
    try std.testing.expect(!parseResult("{\"req_id\":1,\"type\":\"result\",\"success\":false}"));
    try std.testing.expect(!parseResult("{\"type\":\"result\"}"));
}

test "parseDatarefLookup" {
    const json =
        \\{"data":[{"id":9952311,"name":"sim/cockpit2/gauges/indicators/airspeed_kts_pilot","value_type":"float"}]}
    ;
    const allocator = std.heap.c_allocator;

    const info = try parseDatarefLookup(allocator, json);
    defer allocator.free(info.name);
    defer allocator.free(info.value_type);

    try std.testing.expectEqual(@as(u64, 9952311), info.id);
    try std.testing.expectEqualStrings("sim/cockpit2/gauges/indicators/airspeed_kts_pilot", info.name);
    try std.testing.expectEqualStrings("float", info.value_type);
}

test "parseDatarefLookup empty array" {
    const json = "{\"data\":[]}";
    const result = parseDatarefLookup(std.heap.c_allocator, json);
    try std.testing.expectError(error.DatarefNotFound, result);
}

test "parseDatarefValue" {
    try std.testing.expectEqual(@as(f64, 250.5), try parseDatarefValue("250.5"));
    try std.testing.expectEqual(@as(f64, 0.0), try parseDatarefValue("  0  \n"));
    try std.testing.expectEqual(@as(f64, -15.3), try parseDatarefValue("-15.3"));
}
