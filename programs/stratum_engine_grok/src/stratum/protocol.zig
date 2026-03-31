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

pub const StratumRequest = struct {
    id: u32,
    method: []const u8,
    params: std.json.Value,
};

pub const StratumResponse = struct {
    id: u32,
    result: std.json.Value,
    @"error": ?std.json.Value,
};

pub const StratumNotification = struct {
    method: []const u8,
    params: std.json.Value,
};

pub const ParsedMessage = union(enum) {
    request: StratumRequest,
    response: StratumResponse,
    notification: StratumNotification,
};

// Simple streaming parser - assumes complete JSON messages separated by newlines
pub const Parser = struct {
    allocator: std.mem.Allocator,
    buffer: std.ArrayList(u8),

    pub fn init(allocator: std.mem.Allocator) Parser {
        return .{
            .allocator = allocator,
            .buffer = std.ArrayList(u8).initCapacity(allocator, 0) catch unreachable,
        };
    }

    pub fn deinit(self: *Parser) void {
        self.buffer.deinit(self.allocator);
    }

    pub fn parseMessage(self: *Parser, data: []const u8) !?ParsedMessage {
        // For simplicity, assume data is a complete JSON message
        const parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, data, .{});
        defer parsed.deinit();

        const obj = parsed.value.object;

        const id_val = obj.get("id");
        const method = obj.get("method");
        const params = obj.get("params");
        const result = obj.get("result");
        const err = obj.get("error");

        if (method != null and params != null) {
            if (id_val != null) {
                // Request
                const id = @as(u32, @intCast(id_val.?.integer));
                const method_str = method.?.string;
                return ParsedMessage{ .request = .{
                    .id = id,
                    .method = try self.allocator.dupe(u8, method_str),
                    .params = params.?,
                }};
            } else {
                // Notification
                const method_str = method.?.string;
                return ParsedMessage{ .notification = .{
                    .method = try self.allocator.dupe(u8, method_str),
                    .params = params.?,
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
            }};
        }

        return null;
    }
};