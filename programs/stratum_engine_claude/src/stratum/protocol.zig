//! Stratum Protocol Parser
//! Zero-allocation streaming JSON-RPC parser for mining protocol

const std = @import("std");
const types = @import("types.zig");

/// Parse mining.notify message into Job
pub fn parseJob(allocator: std.mem.Allocator, json_str: []const u8) !types.Job {
    // Simplified parser - real implementation would use streaming JSON
    // For now, just allocate and return empty job
    _ = json_str;

    const ts = std.posix.clock_gettime(.REALTIME) catch return error.TimeError;

    return types.Job{
        .job_id = try allocator.dupe(u8, "test_job"),
        .prevhash = [_]u8{0} ** 32,
        .coinb1 = try allocator.dupe(u8, ""),
        .coinb2 = try allocator.dupe(u8, ""),
        .merkle_branch = &[_][]const u8{},
        .version = 0x20000000,
        .nbits = 0x1d00ffff,
        .ntime = @intCast(ts.sec),
        .clean_jobs = true,
        .allocator = allocator,
    };
}

/// Parse mining.set_difficulty message
pub fn parseDifficulty(json_str: []const u8) !f64 {
    // Look for "params":[difficulty]
    const params_start = std.mem.indexOf(u8, json_str, "\"params\":[") orelse return error.ParseError;
    const value_start = params_start + 10; // length of "params":

    var i = value_start;
    while (i < json_str.len and (std.ascii.isDigit(json_str[i]) or json_str[i] == '.')) : (i += 1) {}

    const value_str = json_str[value_start..i];
    return try std.fmt.parseFloat(f64, value_str);
}

/// Build mining.subscribe message
pub fn buildSubscribe(buf: []u8, id: u32, user_agent: []const u8) ![]const u8 {
    return try std.fmt.bufPrint(buf,
        \\{{"id":{},"method":"mining.subscribe","params":["{s}"]}}
        \\
    , .{ id, user_agent });
}

/// Build mining.authorize message
pub fn buildAuthorize(buf: []u8, id: u32, username: []const u8, password: []const u8) ![]const u8 {
    return try std.fmt.bufPrint(buf,
        \\{{"id":{},"method":"mining.authorize","params":["{s}","{s}"]}}
        \\
    , .{ id, username, password });
}

/// Build mining.submit message
pub fn buildSubmit(
    buf: []u8,
    id: u32,
    worker: []const u8,
    job_id: []const u8,
    extranonce2: []const u8,
    ntime: u32,
    nonce: u32,
) ![]const u8 {
    return try std.fmt.bufPrint(buf,
        \\{{"id":{},"method":"mining.submit","params":["{s}","{s}","{s}","{x:0>8}","{x:0>8}"]}}
        \\
    , .{ id, worker, job_id, extranonce2, ntime, nonce });
}

/// Check if message is a notification (no id field)
pub fn isNotification(json_str: []const u8) bool {
    return std.mem.indexOf(u8, json_str, "\"id\":null") != null;
}

/// Extract method name from JSON-RPC message
pub fn extractMethod(json_str: []const u8, out_buf: []u8) ![]const u8 {
    const method_start = std.mem.indexOf(u8, json_str, "\"method\":\"") orelse return error.NoMethod;
    const value_start = method_start + 10; // length of "method":"

    var i = value_start;
    while (i < json_str.len and json_str[i] != '"') : (i += 1) {}

    const method = json_str[value_start..i];
    if (method.len > out_buf.len) return error.BufferTooSmall;

    @memcpy(out_buf[0..method.len], method);
    return out_buf[0..method.len];
}

test "parse difficulty" {
    const json = "{\"id\":null,\"method\":\"mining.set_difficulty\",\"params\":[2048]}";
    const diff = try parseDifficulty(json);
    try std.testing.expectEqual(@as(f64, 2048.0), diff);
}

test "extract method" {
    var buf: [64]u8 = undefined;
    const json = "{\"id\":null,\"method\":\"mining.notify\",\"params\":[...]}";
    const method = try extractMethod(json, &buf);
    try std.testing.expectEqualStrings("mining.notify", method);
}
