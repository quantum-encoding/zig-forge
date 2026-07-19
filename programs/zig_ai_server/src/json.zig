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

/// Serialize the OAuth sign-in success response (shared by apple_auth.zig and
/// google_auth.zig) as JSON. Caller owns the returned slice.
///
/// Every string field — notably the client-supplied `email` and the Apple
/// `display_name` (derived from the request's `name`) — is escaped by
/// std.json.Stringify, so a `"` or `\` can no longer corrupt the response or
/// smuggle a sibling field (JSON-IN-FMT). This replaced two `allocPrint`
/// format-string builders that interpolated those fields raw.
///
/// `credit_usd` is emitted with `print` as a raw JSON number, preserving the
/// exact `<sign><major>.<minor:0>4>` fixed-decimal wire format the Go backend
/// produced (a plain float would not reproduce the zero-padded minor units).
pub fn writeSignInResponse(
    allocator: std.mem.Allocator,
    args: struct {
        raw_key: []const u8,
        email: []const u8,
        is_new: bool,
        account_id: []const u8,
        display_name: []const u8,
        balance_ticks: i64,
    },
) ![]u8 {
    const is_negative = args.balance_ticks < 0;
    const abs_balance = @abs(args.balance_ticks);
    const usd_major = abs_balance / 10_000_000_000;
    const usd_minor = (abs_balance % 10_000_000_000) / 1_000_000;

    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    var jw: std.json.Stringify = .{ .writer = &aw.writer, .options = .{} };

    try jw.beginObject();
    try jw.objectField("token");
    try jw.write(args.raw_key);
    try jw.objectField("session_token");
    try jw.write(args.raw_key);
    try jw.objectField("api_key");
    try jw.write(args.raw_key);
    try jw.objectField("email");
    try jw.write(args.email);
    try jw.objectField("credit_usd");
    try jw.print("{s}{d}.{d:0>4}", .{ if (is_negative) "-" else "", usd_major, usd_minor });
    try jw.objectField("is_new");
    try jw.write(args.is_new);
    try jw.objectField("user");
    try jw.beginObject();
    try jw.objectField("id");
    try jw.write(args.account_id);
    try jw.objectField("email");
    try jw.write(args.email);
    try jw.objectField("display_name");
    try jw.write(args.display_name);
    try jw.objectField("photo_url");
    try jw.write("");
    try jw.objectField("credit_ticks");
    try jw.write(args.balance_ticks);
    try jw.objectField("role");
    try jw.write("user");
    try jw.endObject();
    try jw.endObject();

    return aw.toOwnedSlice();
}

pub const Error = error{
    PayloadTooLarge,
    EmptyBody,
    ReadFailed,
} || std.mem.Allocator.Error;
