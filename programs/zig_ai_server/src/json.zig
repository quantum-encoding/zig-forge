// JSON utilities — request body reading and response serialization

const std = @import("std");
const http = std.http;
const Io = std.Io;

const MAX_BODY_SIZE: usize = 10 * 1024 * 1024; // 10 MB

/// Read the request body as bytes. Caller owns the returned slice.
pub fn readBody(
    request: *http.Server.Request,
    allocator: std.mem.Allocator,
    max_size: ?usize,
) ![]u8 {
    const limit = max_size orelse MAX_BODY_SIZE;

    // Get the content length if available
    const content_length = request.head.content_length orelse 0;
    if (content_length > limit) return error.PayloadTooLarge;
    if (content_length == 0 and request.head.transfer_encoding == .none) {
        return allocator.dupe(u8, "");
    }

    // Get a body reader from the request
    var read_buf: [8192]u8 = undefined;
    const body_reader = request.readerExpectNone(&read_buf);

    // Read all remaining body data
    return body_reader.allocRemaining(allocator, .limited(limit)) catch |err| {
        return switch (err) {
            error.StreamTooLong => error.PayloadTooLarge,
            error.OutOfMemory => error.OutOfMemory,
            else => error.ReadFailed,
        };
    };
}

/// Parse a JSON request body into a struct type. Caller owns the parsed result.
pub fn parseBody(
    comptime T: type,
    request: *http.Server.Request,
    allocator: std.mem.Allocator,
) !std.json.Parsed(T) {
    const body = try readBody(request, allocator, null);
    defer allocator.free(body);

    if (body.len == 0) return error.EmptyBody;

    return std.json.parseFromSlice(T, allocator, body, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
}

/// Serialize a value to JSON. Caller owns the returned string.
pub fn stringify(allocator: std.mem.Allocator, value: anytype) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);

    const writer = buf.writer(allocator);
    std.json.stringify(value, .{}, writer) catch |err| {
        return err;
    };

    return buf.toOwnedSlice(allocator);
}

pub const Error = error{
    PayloadTooLarge,
    EmptyBody,
    ReadFailed,
} || std.mem.Allocator.Error;
