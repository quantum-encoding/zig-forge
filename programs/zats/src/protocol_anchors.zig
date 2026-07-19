//! Externally-anchored NATS wire-protocol conformance tests.
//!
//! Every frame in this file is copied byte-for-byte from the **published NATS
//! client protocol specification** — https://docs.nats.io/reference/reference-protocols/nats-protocol
//! — including the exact subject/sid/reply-to tokens and, critically, the
//! header_len / total_len byte counts the spec itself prints for its HPUB and
//! HMSG examples. Neither the input frames nor the expected numbers were
//! authored here.
//!
//! This is the anchor the zig-forge CLAUDE.md golden rule §1 requires: `zats`'s
//! entire value proposition is NATS wire compatibility in *both* directions, so
//! each example is asserted twice —
//!   1. `parse(frame)` yields exactly the fields the spec documents, and
//!   2. re-encoding those fields reproduces the spec frame byte-for-byte.
//! A roundtrip alone (encode∘parse) would only prove self-consistency; pinning
//! against the spec's literal bytes/counts is what catches a
//! structurally-wrong-but-self-consistent implementation.
//!
//! Spec convention: `␍␊` in the docs is CRLF; reproduced here as `\r\n`.

const std = @import("std");
const protocol = @import("protocol.zig");

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;

// --- PUB (spec §PUB) --------------------------------------------------------

test "anchor: PUB FOO 11 (spec example 1)" {
    const frame = "PUB FOO 11\r\nHello NATS!\r\n";
    const r = try protocol.parse(frame);
    const p = r.command.pub_msg;
    try expectEqualStrings("FOO", p.subject);
    try expect(p.reply_to == null);
    try expectEqual(@as(usize, 11), p.payload_len);
    try expectEqualStrings("Hello NATS!", p.payload);
    try expectEqual(frame.len, r.bytes_consumed);

    var buf: [64]u8 = undefined;
    try expectEqualStrings(frame, protocol.encodePub(&buf, "FOO", null, "Hello NATS!"));
}

test "anchor: PUB FRONT.DOOR JOKE.22 11 (spec example 2, with reply)" {
    const frame = "PUB FRONT.DOOR JOKE.22 11\r\nKnock Knock\r\n";
    const r = try protocol.parse(frame);
    const p = r.command.pub_msg;
    try expectEqualStrings("FRONT.DOOR", p.subject);
    try expectEqualStrings("JOKE.22", p.reply_to.?);
    try expectEqual(@as(usize, 11), p.payload_len);
    try expectEqualStrings("Knock Knock", p.payload);

    var buf: [64]u8 = undefined;
    try expectEqualStrings(frame, protocol.encodePub(&buf, "FRONT.DOOR", "JOKE.22", "Knock Knock"));
}

test "anchor: PUB NOTIFY 0 (spec example 3, empty payload)" {
    const frame = "PUB NOTIFY 0\r\n\r\n";
    const r = try protocol.parse(frame);
    const p = r.command.pub_msg;
    try expectEqualStrings("NOTIFY", p.subject);
    try expectEqual(@as(usize, 0), p.payload_len);
    try expectEqualStrings("", p.payload);

    var buf: [64]u8 = undefined;
    try expectEqualStrings(frame, protocol.encodePub(&buf, "NOTIFY", null, ""));
}

// --- SUB (spec §SUB) --------------------------------------------------------

test "anchor: SUB FOO 1 (spec example 1)" {
    const frame = "SUB FOO 1\r\n";
    const r = try protocol.parse(frame);
    const s = r.command.sub;
    try expectEqualStrings("FOO", s.subject);
    try expect(s.queue_group == null);
    try expectEqualStrings("1", s.sid);

    var buf: [32]u8 = undefined;
    try expectEqualStrings(frame, protocol.encodeSub(&buf, "FOO", null, "1"));
}

test "anchor: SUB BAR G1 44 (spec example 2, queue group)" {
    const frame = "SUB BAR G1 44\r\n";
    const r = try protocol.parse(frame);
    const s = r.command.sub;
    try expectEqualStrings("BAR", s.subject);
    try expectEqualStrings("G1", s.queue_group.?);
    try expectEqualStrings("44", s.sid);

    var buf: [32]u8 = undefined;
    try expectEqualStrings(frame, protocol.encodeSub(&buf, "BAR", "G1", "44"));
}

// --- UNSUB (spec §UNSUB) ----------------------------------------------------

test "anchor: UNSUB 1 (spec example 1)" {
    const frame = "UNSUB 1\r\n";
    const r = try protocol.parse(frame);
    const u = r.command.unsub;
    try expectEqualStrings("1", u.sid);
    try expect(u.max_msgs == null);

    var buf: [32]u8 = undefined;
    try expectEqualStrings(frame, protocol.encodeUnsub(&buf, "1", null));
}

test "anchor: UNSUB 1 5 (spec example 2, max_msgs)" {
    const frame = "UNSUB 1 5\r\n";
    const r = try protocol.parse(frame);
    const u = r.command.unsub;
    try expectEqualStrings("1", u.sid);
    try expectEqual(@as(u64, 5), u.max_msgs.?);

    var buf: [32]u8 = undefined;
    try expectEqualStrings(frame, protocol.encodeUnsub(&buf, "1", 5));
}

// --- MSG (spec §MSG) --------------------------------------------------------

test "anchor: MSG FOO.BAR 9 11 (spec example 1)" {
    const frame = "MSG FOO.BAR 9 11\r\nHello World\r\n";
    const r = try protocol.parse(frame);
    const m = r.command.msg;
    try expectEqualStrings("FOO.BAR", m.subject);
    try expectEqualStrings("9", m.sid);
    try expect(m.reply_to == null);
    try expectEqual(@as(usize, 11), m.payload_len);
    try expectEqualStrings("Hello World", m.payload);

    var buf: [64]u8 = undefined;
    try expectEqualStrings(frame, protocol.encodeMsg(&buf, "FOO.BAR", "9", null, "Hello World"));
}

test "anchor: MSG FOO.BAR 9 GREETING.34 11 (spec example 2, reply)" {
    const frame = "MSG FOO.BAR 9 GREETING.34 11\r\nHello World\r\n";
    const r = try protocol.parse(frame);
    const m = r.command.msg;
    try expectEqualStrings("FOO.BAR", m.subject);
    try expectEqualStrings("9", m.sid);
    try expectEqualStrings("GREETING.34", m.reply_to.?);
    try expectEqualStrings("Hello World", m.payload);

    var buf: [64]u8 = undefined;
    try expectEqualStrings(frame, protocol.encodeMsg(&buf, "FOO.BAR", "9", "GREETING.34", "Hello World"));
}

// --- HPUB (spec §HPUB) ------------------------------------------------------
// The spec prints the header_len / total_len for each example; assert the
// parser derives exactly those counts and splits headers/payload on the
// documented boundary.

test "anchor: HPUB FOO 22 33 (spec example 1)" {
    const headers = "NATS/1.0\r\nBar: Baz\r\n\r\n"; // 22 bytes per spec
    const payload = "Hello NATS!"; // total 33 per spec
    const frame = "HPUB FOO 22 33\r\n" ++ headers ++ payload ++ "\r\n";
    const r = try protocol.parse(frame);
    const h = r.command.hpub;
    try expectEqualStrings("FOO", h.subject);
    try expect(h.reply_to == null);
    try expectEqual(@as(usize, 22), h.header_len);
    try expectEqual(@as(usize, 33), h.total_len);
    try expectEqualStrings(headers, h.headers);
    try expectEqualStrings(payload, h.payload);

    var buf: [128]u8 = undefined;
    try expectEqualStrings(frame, protocol.encodeHpub(&buf, "FOO", null, headers, payload));
}

test "anchor: HPUB FRONT.DOOR JOKE.22 45 56 (spec example 2, reply + multi-header)" {
    const headers = "NATS/1.0\r\nBREAKFAST: donut\r\nLUNCH: burger\r\n\r\n"; // 45 bytes per spec
    const payload = "Knock Knock"; // total 56 per spec
    const frame = "HPUB FRONT.DOOR JOKE.22 45 56\r\n" ++ headers ++ payload ++ "\r\n";
    const r = try protocol.parse(frame);
    const h = r.command.hpub;
    try expectEqualStrings("FRONT.DOOR", h.subject);
    try expectEqualStrings("JOKE.22", h.reply_to.?);
    try expectEqual(@as(usize, 45), h.header_len);
    try expectEqual(@as(usize, 56), h.total_len);
    try expectEqualStrings(headers, h.headers);
    try expectEqualStrings(payload, h.payload);

    var buf: [128]u8 = undefined;
    try expectEqualStrings(frame, protocol.encodeHpub(&buf, "FRONT.DOOR", "JOKE.22", headers, payload));
}

test "anchor: HPUB NOTIFY 22 22 (spec example 3, headers only, no payload)" {
    const headers = "NATS/1.0\r\nBar: Baz\r\n\r\n"; // 22 bytes; total == header_len
    const frame = "HPUB NOTIFY 22 22\r\n" ++ headers ++ "\r\n";
    const r = try protocol.parse(frame);
    const h = r.command.hpub;
    try expectEqualStrings("NOTIFY", h.subject);
    try expectEqual(@as(usize, 22), h.header_len);
    try expectEqual(@as(usize, 22), h.total_len);
    try expectEqualStrings(headers, h.headers);
    try expectEqualStrings("", h.payload);

    var buf: [128]u8 = undefined;
    try expectEqualStrings(frame, protocol.encodeHpub(&buf, "NOTIFY", null, headers, ""));
}

test "anchor: HPUB MORNING.MENU 47 51 (spec example 4, duplicate header key)" {
    const headers = "NATS/1.0\r\nBREAKFAST: donut\r\nBREAKFAST: eggs\r\n\r\n"; // 47 bytes per spec
    const payload = "Yum!"; // total 51 per spec
    const frame = "HPUB MORNING.MENU 47 51\r\n" ++ headers ++ payload ++ "\r\n";
    const r = try protocol.parse(frame);
    const h = r.command.hpub;
    try expectEqualStrings("MORNING.MENU", h.subject);
    try expectEqual(@as(usize, 47), h.header_len);
    try expectEqual(@as(usize, 51), h.total_len);
    try expectEqualStrings(headers, h.headers);
    try expectEqualStrings(payload, h.payload);

    var buf: [128]u8 = undefined;
    try expectEqualStrings(frame, protocol.encodeHpub(&buf, "MORNING.MENU", null, headers, payload));
}

// --- HMSG (spec §HMSG) ------------------------------------------------------

test "anchor: HMSG FOO.BAR 9 34 45 (spec example 1)" {
    const headers = "NATS/1.0\r\nFoodGroup: vegetable\r\n\r\n"; // 34 bytes per spec
    const payload = "Hello World"; // total 45 per spec
    const frame = "HMSG FOO.BAR 9 34 45\r\n" ++ headers ++ payload ++ "\r\n";
    const r = try protocol.parse(frame);
    const h = r.command.hmsg;
    try expectEqualStrings("FOO.BAR", h.subject);
    try expectEqualStrings("9", h.sid);
    try expect(h.reply_to == null);
    try expectEqual(@as(usize, 34), h.header_len);
    try expectEqual(@as(usize, 45), h.total_len);
    try expectEqualStrings(headers, h.headers);
    try expectEqualStrings(payload, h.payload);

    var buf: [128]u8 = undefined;
    try expectEqualStrings(frame, protocol.encodeHmsg(&buf, "FOO.BAR", "9", null, headers, payload));
}

test "anchor: HMSG FOO.BAR 9 BAZ.69 34 45 (spec example 2, reply)" {
    const headers = "NATS/1.0\r\nFoodGroup: vegetable\r\n\r\n"; // 34 bytes per spec
    const payload = "Hello World"; // total 45 per spec
    const frame = "HMSG FOO.BAR 9 BAZ.69 34 45\r\n" ++ headers ++ payload ++ "\r\n";
    const r = try protocol.parse(frame);
    const h = r.command.hmsg;
    try expectEqualStrings("FOO.BAR", h.subject);
    try expectEqualStrings("9", h.sid);
    try expectEqualStrings("BAZ.69", h.reply_to.?);
    try expectEqual(@as(usize, 34), h.header_len);
    try expectEqual(@as(usize, 45), h.total_len);
    try expectEqualStrings(headers, h.headers);
    try expectEqualStrings(payload, h.payload);

    var buf: [128]u8 = undefined;
    try expectEqualStrings(frame, protocol.encodeHmsg(&buf, "FOO.BAR", "9", "BAZ.69", headers, payload));
}

// --- Control frames (spec §PING/§PONG) --------------------------------------

test "anchor: PING / PONG" {
    try expect((try protocol.parse("PING\r\n")).command == .ping);
    try expect((try protocol.parse("PONG\r\n")).command == .pong);

    var buf: [8]u8 = undefined;
    try expectEqualStrings("PING\r\n", protocol.encodePing(&buf));
    try expectEqualStrings("PONG\r\n", protocol.encodePong(&buf));
}

// --- INFO / CONNECT (spec §INFO, §CONNECT) ----------------------------------
// Anchors the hand-rolled JSON scanner against the exact INFO/CONNECT payloads
// the spec documents: field extraction must pull the documented values.

test "anchor: INFO payload from spec is parsed and its JSON fields readable" {
    const json = "{\"server_id\":\"Zk0GQ3JBSrg3oyxCRRlE09\",\"version\":\"1.2.0\"," ++
        "\"proto\":1,\"go\":\"go1.10.3\",\"host\":\"0.0.0.0\",\"port\":4222," ++
        "\"max_payload\":1048576,\"client_id\":2392}";
    const frame = "INFO " ++ json ++ "\r\n";
    const r = try protocol.parse(frame);
    try expectEqualStrings(json, r.command.info.json);

    // Scanner must extract the documented string/bool fields.
    try expectEqualStrings("Zk0GQ3JBSrg3oyxCRRlE09", protocol.jsonGetString(json, "server_id").?);
    try expectEqualStrings("1.2.0", protocol.jsonGetString(json, "version").?);
    try expectEqualStrings("go1.10.3", protocol.jsonGetString(json, "go").?);
}

test "anchor: CONNECT payload from spec is parsed and its JSON fields readable" {
    const json = "{\"verbose\":false,\"pedantic\":false,\"tls_required\":false," ++
        "\"name\":\"\",\"lang\":\"go\",\"version\":\"1.2.2\",\"protocol\":1}";
    const frame = "CONNECT " ++ json ++ "\r\n";
    const r = try protocol.parse(frame);
    try expectEqualStrings(json, r.command.connect.json);

    try expectEqual(false, protocol.jsonGetBool(json, "verbose").?);
    try expectEqual(false, protocol.jsonGetBool(json, "tls_required").?);
    try expectEqualStrings("go", protocol.jsonGetString(json, "lang").?);
    try expectEqualStrings("1.2.2", protocol.jsonGetString(json, "version").?);
}
