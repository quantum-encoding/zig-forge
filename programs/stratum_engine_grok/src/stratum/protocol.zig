const std = @import("std");
const types = @import("types.zig");

pub const MessageType = enum {
    request,
    response,
    notification,
};

pub const JsonRpcMessage = struct {
    jsonrpc: []const u8 = "2.0",
    id: ?std.json.Value = null,
    method: ?[]const u8 = null,
    params: ?std.json.Value = null,
    result: ?std.json.Value = null,
    @"error": ?std.json.Value = null,
};

// The `params` / `result` / `error` values below alias memory owned by the
// `parsed` arena. That arena MUST outlive the message, otherwise every read of
// those std.json.Value fields (strings, arrays, object maps) is a
// use-after-free. `parsed` keeps the arena alive; the owner calls
// `ParsedMessage.deinit` once the message has been consumed.
pub const StratumRequest = struct {
    id: u32,
    method: []const u8,
    params: std.json.Value,
    parsed: std.json.Parsed(std.json.Value),
};

pub const StratumResponse = struct {
    id: u32,
    result: std.json.Value,
    @"error": ?std.json.Value,
    parsed: std.json.Parsed(std.json.Value),
};

pub const StratumNotification = struct {
    method: []const u8,
    params: std.json.Value,
    parsed: std.json.Parsed(std.json.Value),
};

pub const ParsedMessage = union(enum) {
    request: StratumRequest,
    response: StratumResponse,
    notification: StratumNotification,

    /// Release the message: frees the duped `method` string (request /
    /// notification) and the JSON arena backing all the std.json.Value fields.
    /// Must be called exactly once, after the caller is done reading the
    /// message. `allocator` must be the same allocator passed to the Parser.
    pub fn deinit(self: ParsedMessage, allocator: std.mem.Allocator) void {
        switch (self) {
            .request => |r| {
                allocator.free(r.method);
                r.parsed.deinit();
            },
            .notification => |n| {
                allocator.free(n.method);
                n.parsed.deinit();
            },
            .response => |r| {
                r.parsed.deinit();
            },
        }
    }
};

// Simple streaming parser - assumes complete JSON messages separated by newlines
pub const Parser = struct {
    allocator: std.mem.Allocator,
    buffer: std.ArrayList(u8),

    pub fn init(allocator: std.mem.Allocator) Parser {
        return .{
            .allocator = allocator,
            .buffer = .empty,
        };
    }

    pub fn deinit(self: *Parser) void {
        self.buffer.deinit(self.allocator);
    }

    pub fn parseMessage(self: *Parser, data: []const u8) !?ParsedMessage {
        // For simplicity, assume data is a complete JSON message.
        //
        // Ownership: the returned ParsedMessage takes ownership of `parsed` and
        // is responsible for calling `parsed.deinit()` (via ParsedMessage.deinit).
        // Previously this used `defer parsed.deinit()`, which freed the arena
        // before the caller read any of the returned std.json.Value fields — a
        // use-after-free driven by pool-controlled input. On any path that does
        // NOT return the arena (parse of an unrecognized shape, or a dupe
        // failure) we free it here via errdefer / an explicit deinit.
        const parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, data, .{});
        errdefer parsed.deinit();

        const obj = parsed.value.object;

        const method = obj.get("method");
        const params = obj.get("params");
        const result = obj.get("result");

        // A JSON `null` value is present-but-null in std.json (an optional
        // wrapping `Value{ .null }`), not an absent key. Stratum sends
        // notifications with `"id":null` and success responses with
        // `"error":null`, so normalize JSON-null to "absent" for both — else a
        // real `mining.notify` gets misclassified as a request (and panics on
        // `.integer`), and a successful response looks like it carries an error.
        const id_val: ?std.json.Value = if (obj.get("id")) |v|
            (if (v == .null) null else v)
        else
            null;
        const err: ?std.json.Value = if (obj.get("error")) |v|
            (if (v == .null) null else v)
        else
            null;

        if (method != null and params != null) {
            if (id_val != null) {
                // Request
                const id = @as(u32, @intCast(id_val.?.integer));
                const method_str = method.?.string;
                return ParsedMessage{ .request = .{
                    .id = id,
                    .method = try self.allocator.dupe(u8, method_str),
                    .params = params.?,
                    .parsed = parsed,
                }};
            } else {
                // Notification
                const method_str = method.?.string;
                return ParsedMessage{ .notification = .{
                    .method = try self.allocator.dupe(u8, method_str),
                    .params = params.?,
                    .parsed = parsed,
                }};
            }
        } else if (id_val != null and (result != null or err != null)) {
            // Response
            const id = @as(u32, @intCast(id_val.?.integer));
            const res = if (result) |r| r else null;
            const error_val = if (err) |e| e else null;
            return ParsedMessage{ .response = .{
                .id = id,
                .result = res.?,
                .@"error" = error_val,
                .parsed = parsed,
            }};
        }

        // Unrecognized message shape: nothing takes ownership of the arena.
        parsed.deinit();
        return null;
    }
};