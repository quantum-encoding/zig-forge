const std = @import("std");
const testing = std.testing;
const protocol = @import("stratum/protocol.zig");

// These tests exercise the JSON-arena use-after-free fix in
// `Parser.parseMessage`. `std.testing.allocator` detects leaks and
// double-frees, so a passing run proves the returned ParsedMessage owns the
// arena for the lifetime of the reads AND is released exactly once via
// `ParsedMessage.deinit`.
//
// The inputs are real Stratum V1 wire lines (the canonical slush-pool
// `mining.notify` example from the Stratum protocol documentation, plus a
// standard subscribe response and submit result) — external anchors, not
// round-trips of our own encoder.

const slush_notify =
    "{\"id\":null,\"method\":\"mining.notify\",\"params\":[" ++
    "\"bf\"," ++
    "\"4d16b6f85af6e2198f44ae2a6de67f78487ae5611b77c6c0440b921e00000000\"," ++
    "\"01000000010000000000000000000000000000000000000000000000000000000000000000ffffffff20020862062f503253482f04b8864e5008\"," ++
    "\"072f736c7573682f000000000100f2052a010000001976a914d23fcdf86f7e756a64a7a9688ef9903327048ed988ac00000000\"," ++
    "[]," ++
    "\"00000002\"," ++
    "\"1c2ac4af\"," ++
    "\"504e86b9\"," ++
    "false" ++
    "]}";

test "parseMessage: mining.notify fields survive after arena would have been freed" {
    var parser = protocol.Parser.init(testing.allocator);
    defer parser.deinit();

    const maybe = try parser.parseMessage(slush_notify);
    try testing.expect(maybe != null);
    const msg = maybe.?;
    defer msg.deinit(testing.allocator);

    try testing.expect(msg == .notification);
    const notif = msg.notification;

    // method survives (this one was already duped by the parser).
    try testing.expectEqualStrings("mining.notify", notif.method);

    // params is an array aliasing the arena; reading it after parseMessage
    // returned is exactly the read that used-after-free before the fix.
    const params = notif.params.array.items;
    try testing.expectEqual(@as(usize, 9), params.len);

    // job_id
    try testing.expectEqualStrings("bf", params[0].string);
    // prevhash (hex string)
    try testing.expectEqualStrings(
        "4d16b6f85af6e2198f44ae2a6de67f78487ae5611b77c6c0440b921e00000000",
        params[1].string,
    );
    // empty merkle-branch array
    try testing.expectEqual(@as(usize, 0), params[4].array.items.len);
    // clean_jobs flag
    try testing.expectEqual(false, params[8].bool);
}

test "parseMessage: subscribe response result survives" {
    // Standard mining.subscribe response: [[notify-sub, diff-sub], extranonce1, extranonce2_size]
    const line =
        "{\"id\":1,\"result\":[[[\"mining.set_difficulty\",\"1\"],[\"mining.notify\",\"1\"]],\"08000002\",4],\"error\":null}";

    var parser = protocol.Parser.init(testing.allocator);
    defer parser.deinit();

    const maybe = try parser.parseMessage(line);
    try testing.expect(maybe != null);
    const msg = maybe.?;
    defer msg.deinit(testing.allocator);

    try testing.expect(msg == .response);
    const resp = msg.response;
    try testing.expectEqual(@as(u32, 1), resp.id);
    try testing.expect(resp.@"error" == null);

    const result = resp.result.array.items;
    try testing.expectEqual(@as(usize, 3), result.len);
    // extranonce1
    try testing.expectEqualStrings("08000002", result[1].string);
    // extranonce2_size
    try testing.expectEqual(@as(i64, 4), result[2].integer);
}

test "parseMessage: mining.submit request params survive" {
    const line =
        "{\"id\":4,\"method\":\"mining.submit\",\"params\":[\"worker1\",\"bf\",\"00000001\",\"504e86b9\",\"e9695791\"]}";

    var parser = protocol.Parser.init(testing.allocator);
    defer parser.deinit();

    const maybe = try parser.parseMessage(line);
    try testing.expect(maybe != null);
    const msg = maybe.?;
    defer msg.deinit(testing.allocator);

    try testing.expect(msg == .request);
    const req = msg.request;
    try testing.expectEqual(@as(u32, 4), req.id);
    try testing.expectEqualStrings("mining.submit", req.method);

    const params = req.params.array.items;
    try testing.expectEqual(@as(usize, 5), params.len);
    try testing.expectEqualStrings("worker1", params[0].string);
    try testing.expectEqualStrings("e9695791", params[4].string);
}

test "parseMessage: unrecognized shape returns null and leaks nothing" {
    var parser = protocol.Parser.init(testing.allocator);
    defer parser.deinit();

    // No method+params and no id+result/error: the parser must free the arena
    // itself and return null (testing.allocator would flag a leak otherwise).
    const maybe = try parser.parseMessage("{\"jsonrpc\":\"2.0\"}");
    try testing.expect(maybe == null);
}
