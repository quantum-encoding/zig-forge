//! NATS Protocol Parser and Encoder
//!
//! Implements the NATS text-based wire protocol (RFC-style).
//! All messages are \r\n delimited. Parser is streaming and zero-allocation
//! for command parsing — only payload bytes are copied.

const std = @import("std");

pub const Opcode = enum {
    info,
    connect,
    pub_msg,
    hpub,
    sub,
    unsub,
    msg,
    hmsg,
    ping,
    pong,
    ok,
    err,
};

pub const Command = union(Opcode) {
    info: InfoPayload,
    connect: ConnectPayload,
    pub_msg: PubPayload,
    hpub: HpubPayload,
    sub: SubPayload,
    unsub: UnsubPayload,
    msg: MsgPayload,
    hmsg: HmsgPayload,
    ping: void,
    pong: void,
    ok: void,
    err: []const u8,
};

pub const InfoPayload = struct {
    json: []const u8, // raw JSON string (not parsed further)
};

pub const ConnectPayload = struct {
    json: []const u8,
};

pub const PubPayload = struct {
    subject: []const u8,
    reply_to: ?[]const u8,
    payload_len: usize,
    payload: []const u8,
};

pub const SubPayload = struct {
    subject: []const u8,
    queue_group: ?[]const u8,
    sid: []const u8,
};

pub const UnsubPayload = struct {
    sid: []const u8,
    max_msgs: ?u64,
};

pub const MsgPayload = struct {
    subject: []const u8,
    sid: []const u8,
    reply_to: ?[]const u8,
    payload_len: usize,
    payload: []const u8,
};

pub const HpubPayload = struct {
    subject: []const u8,
    reply_to: ?[]const u8,
    header_len: usize,
    total_len: usize,
    headers: []const u8,
    payload: []const u8,
};

pub const HmsgPayload = struct {
    subject: []const u8,
    sid: []const u8,
    reply_to: ?[]const u8,
    header_len: usize,
    total_len: usize,
    headers: []const u8,
    payload: []const u8,
};

pub const ParseError = error{
    InvalidCommand,
    IncompleteLine,
    IncompletePayload,
    InvalidPayloadLength,
    MissingField,
};

pub const ParseResult = struct {
    command: Command,
    bytes_consumed: usize,
};

/// Parse a single NATS command from a byte buffer.
/// Returns the parsed command and how many bytes were consumed.
/// Returns IncompleteLine if no full \r\n-terminated line is available.
/// Returns IncompletePayload if the payload for PUB/MSG isn't fully received.
pub fn parse(buf: []const u8) ParseError!ParseResult {
    // Find first \r\n
    const line_end = findCrlf(buf) orelse return ParseError.IncompleteLine;
    const line = buf[0..line_end];

    if (line.len == 0) return ParseError.InvalidCommand;

    // Match command prefix
    if (startsWith(line, "INFO ") or startsWith(line, "INFO\t")) {
        return .{
            .command = .{ .info = .{ .json = line[5..] } },
            .bytes_consumed = line_end + 2,
        };
    }

    if (startsWith(line, "CONNECT ") or startsWith(line, "CONNECT\t")) {
        return .{
            .command = .{ .connect = .{ .json = line[8..] } },
            .bytes_consumed = line_end + 2,
        };
    }

    if (startsWith(line, "HPUB ")) {
        return parseHpub(buf, line[5..], line_end);
    }

    if (startsWith(line, "PUB ")) {
        return parsePub(buf, line[4..], line_end);
    }

    if (startsWith(line, "SUB ")) {
        return parseSub(line[4..], line_end);
    }

    if (startsWith(line, "UNSUB ")) {
        return parseUnsub(line[6..], line_end);
    }

    if (startsWith(line, "HMSG ")) {
        return parseHmsg(buf, line[5..], line_end);
    }

    if (startsWith(line, "MSG ")) {
        return parseMsg(buf, line[4..], line_end);
    }

    if (std.mem.eql(u8, line, "PING")) {
        return .{
            .command = .{ .ping = {} },
            .bytes_consumed = line_end + 2,
        };
    }

    if (std.mem.eql(u8, line, "PONG")) {
        return .{
            .command = .{ .pong = {} },
            .bytes_consumed = line_end + 2,
        };
    }

    if (std.mem.eql(u8, line, "+OK")) {
        return .{
            .command = .{ .ok = {} },
            .bytes_consumed = line_end + 2,
        };
    }

    if (startsWith(line, "-ERR ")) {
        // -ERR 'message' — extract the message (strip quotes if present)
        var msg = line[5..];
        if (msg.len >= 2 and msg[0] == '\'' and msg[msg.len - 1] == '\'') {
            msg = msg[1 .. msg.len - 1];
        }
        return .{
            .command = .{ .err = msg },
            .bytes_consumed = line_end + 2,
        };
    }

    return ParseError.InvalidCommand;
}

/// Parse PUB <subject> [reply-to] <#bytes>\r\n<payload>\r\n
fn parsePub(buf: []const u8, args: []const u8, line_end: usize) ParseError!ParseResult {
    var it = splitSpaces(args);

    const subject = it.next() orelse return ParseError.MissingField;
    const second = it.next() orelse return ParseError.MissingField;
    const third = it.next();

    var reply_to: ?[]const u8 = null;
    var len_str: []const u8 = undefined;

    if (third) |t| {
        reply_to = second;
        len_str = t;
    } else {
        len_str = second;
    }

    const payload_len = std.fmt.parseInt(usize, len_str, 10) catch
        return ParseError.InvalidPayloadLength;

    // Check if full payload + \r\n is available
    const payload_start = line_end + 2;
    const payload_end = payload_start + payload_len;
    const total_end = payload_end + 2; // trailing \r\n

    if (buf.len < total_end) return ParseError.IncompletePayload;

    // Verify trailing \r\n
    if (buf[payload_end] != '\r' or buf[payload_end + 1] != '\n')
        return ParseError.InvalidCommand;

    return .{
        .command = .{ .pub_msg = .{
            .subject = subject,
            .reply_to = reply_to,
            .payload_len = payload_len,
            .payload = buf[payload_start..payload_end],
        } },
        .bytes_consumed = total_end,
    };
}

/// Parse SUB <subject> [queue group] <sid>\r\n
fn parseSub(args: []const u8, line_end: usize) ParseError!ParseResult {
    var it = splitSpaces(args);

    const subject = it.next() orelse return ParseError.MissingField;
    const second = it.next() orelse return ParseError.MissingField;
    const third = it.next();

    var queue_group: ?[]const u8 = null;
    var sid: []const u8 = undefined;

    if (third) |t| {
        queue_group = second;
        sid = t;
    } else {
        sid = second;
    }

    return .{
        .command = .{ .sub = .{
            .subject = subject,
            .queue_group = queue_group,
            .sid = sid,
        } },
        .bytes_consumed = line_end + 2,
    };
}

/// Parse UNSUB <sid> [max_msgs]\r\n
fn parseUnsub(args: []const u8, line_end: usize) ParseError!ParseResult {
    var it = splitSpaces(args);

    const sid = it.next() orelse return ParseError.MissingField;
    const max_str = it.next();

    var max_msgs: ?u64 = null;
    if (max_str) |s| {
        max_msgs = std.fmt.parseInt(u64, s, 10) catch
            return ParseError.InvalidPayloadLength;
    }

    return .{
        .command = .{ .unsub = .{
            .sid = sid,
            .max_msgs = max_msgs,
        } },
        .bytes_consumed = line_end + 2,
    };
}

/// Parse MSG <subject> <sid> [reply-to] <#bytes>\r\n<payload>\r\n
fn parseMsg(buf: []const u8, args: []const u8, line_end: usize) ParseError!ParseResult {
    var it = splitSpaces(args);

    const subject = it.next() orelse return ParseError.MissingField;
    const sid = it.next() orelse return ParseError.MissingField;
    const third = it.next() orelse return ParseError.MissingField;
    const fourth = it.next();

    var reply_to: ?[]const u8 = null;
    var len_str: []const u8 = undefined;

    if (fourth) |f| {
        reply_to = third;
        len_str = f;
    } else {
        len_str = third;
    }

    const payload_len = std.fmt.parseInt(usize, len_str, 10) catch
        return ParseError.InvalidPayloadLength;

    const payload_start = line_end + 2;
    const payload_end = payload_start + payload_len;
    const total_end = payload_end + 2;

    if (buf.len < total_end) return ParseError.IncompletePayload;

    if (buf[payload_end] != '\r' or buf[payload_end + 1] != '\n')
        return ParseError.InvalidCommand;

    return .{
        .command = .{ .msg = .{
            .subject = subject,
            .sid = sid,
            .reply_to = reply_to,
            .payload_len = payload_len,
            .payload = buf[payload_start..payload_end],
        } },
        .bytes_consumed = total_end,
    };
}

/// Parse HPUB <subject> [reply-to] <header_len> <total_len>\r\n<headers+payload>\r\n
fn parseHpub(buf: []const u8, args: []const u8, line_end: usize) ParseError!ParseResult {
    var it = splitSpaces(args);

    const subject = it.next() orelse return ParseError.MissingField;
    const second = it.next() orelse return ParseError.MissingField;
    const third = it.next() orelse return ParseError.MissingField;
    const fourth = it.next();

    var reply_to: ?[]const u8 = null;
    var hdr_len_str: []const u8 = undefined;
    var total_len_str: []const u8 = undefined;

    if (fourth) |f| {
        reply_to = second;
        hdr_len_str = third;
        total_len_str = f;
    } else {
        hdr_len_str = second;
        total_len_str = third;
    }

    const header_len = std.fmt.parseInt(usize, hdr_len_str, 10) catch
        return ParseError.InvalidPayloadLength;
    const total_len = std.fmt.parseInt(usize, total_len_str, 10) catch
        return ParseError.InvalidPayloadLength;

    if (total_len < header_len) return ParseError.InvalidPayloadLength;

    const data_start = line_end + 2;
    const data_end = data_start + total_len;
    const total_end = data_end + 2;

    if (buf.len < total_end) return ParseError.IncompletePayload;
    if (buf[data_end] != '\r' or buf[data_end + 1] != '\n')
        return ParseError.InvalidCommand;

    return .{
        .command = .{ .hpub = .{
            .subject = subject,
            .reply_to = reply_to,
            .header_len = header_len,
            .total_len = total_len,
            .headers = buf[data_start .. data_start + header_len],
            .payload = buf[data_start + header_len .. data_end],
        } },
        .bytes_consumed = total_end,
    };
}

/// Parse HMSG <subject> <sid> [reply-to] <header_len> <total_len>\r\n<headers+payload>\r\n
fn parseHmsg(buf: []const u8, args: []const u8, line_end: usize) ParseError!ParseResult {
    var it = splitSpaces(args);

    const subject = it.next() orelse return ParseError.MissingField;
    const sid = it.next() orelse return ParseError.MissingField;
    const third = it.next() orelse return ParseError.MissingField;
    const fourth = it.next() orelse return ParseError.MissingField;
    const fifth = it.next();

    var reply_to: ?[]const u8 = null;
    var hdr_len_str: []const u8 = undefined;
    var total_len_str: []const u8 = undefined;

    if (fifth) |f| {
        reply_to = third;
        hdr_len_str = fourth;
        total_len_str = f;
    } else {
        hdr_len_str = third;
        total_len_str = fourth;
    }

    const header_len = std.fmt.parseInt(usize, hdr_len_str, 10) catch
        return ParseError.InvalidPayloadLength;
    const total_len = std.fmt.parseInt(usize, total_len_str, 10) catch
        return ParseError.InvalidPayloadLength;

    if (total_len < header_len) return ParseError.InvalidPayloadLength;

    const data_start = line_end + 2;
    const data_end = data_start + total_len;
    const total_end = data_end + 2;

    if (buf.len < total_end) return ParseError.IncompletePayload;
    if (buf[data_end] != '\r' or buf[data_end + 1] != '\n')
        return ParseError.InvalidCommand;

    return .{
        .command = .{ .hmsg = .{
            .subject = subject,
            .sid = sid,
            .reply_to = reply_to,
            .header_len = header_len,
            .total_len = total_len,
            .headers = buf[data_start .. data_start + header_len],
            .payload = buf[data_start + header_len .. data_end],
        } },
        .bytes_consumed = total_end,
    };
}

// --- Encoder ---
// All encode functions write into a provided buffer and return the written slice.

/// Encode INFO message: "INFO {json}\r\n"
pub fn encodeInfo(buf: []u8, json: []const u8) []const u8 {
    var pos: usize = 0;
    @memcpy(buf[pos..][0..5], "INFO ");
    pos += 5;
    @memcpy(buf[pos..][0..json.len], json);
    pos += json.len;
    @memcpy(buf[pos..][0..2], "\r\n");
    pos += 2;
    return buf[0..pos];
}

/// Encode CONNECT message: "CONNECT {json}\r\n"
pub fn encodeConnect(buf: []u8, json: []const u8) []const u8 {
    var pos: usize = 0;
    @memcpy(buf[pos..][0..8], "CONNECT ");
    pos += 8;
    @memcpy(buf[pos..][0..json.len], json);
    pos += json.len;
    @memcpy(buf[pos..][0..2], "\r\n");
    pos += 2;
    return buf[0..pos];
}

/// Encode PUB message: "PUB <subject> [reply] <#bytes>\r\n<payload>\r\n"
pub fn encodePub(buf: []u8, subject: []const u8, reply_to: ?[]const u8, payload: []const u8) []const u8 {
    var pos: usize = 0;
    @memcpy(buf[pos..][0..4], "PUB ");
    pos += 4;
    @memcpy(buf[pos..][0..subject.len], subject);
    pos += subject.len;
    if (reply_to) |reply| {
        buf[pos] = ' ';
        pos += 1;
        @memcpy(buf[pos..][0..reply.len], reply);
        pos += reply.len;
    }
    buf[pos] = ' ';
    pos += 1;
    const len_str = std.fmt.bufPrint(buf[pos..], "{d}", .{payload.len}) catch return buf[0..0];
    pos += len_str.len;
    @memcpy(buf[pos..][0..2], "\r\n");
    pos += 2;
    @memcpy(buf[pos..][0..payload.len], payload);
    pos += payload.len;
    @memcpy(buf[pos..][0..2], "\r\n");
    pos += 2;
    return buf[0..pos];
}

/// Encode SUB message: "SUB <subject> [queue] <sid>\r\n"
pub fn encodeSub(buf: []u8, subject: []const u8, queue_group: ?[]const u8, sid: []const u8) []const u8 {
    var pos: usize = 0;
    @memcpy(buf[pos..][0..4], "SUB ");
    pos += 4;
    @memcpy(buf[pos..][0..subject.len], subject);
    pos += subject.len;
    if (queue_group) |queue| {
        buf[pos] = ' ';
        pos += 1;
        @memcpy(buf[pos..][0..queue.len], queue);
        pos += queue.len;
    }
    buf[pos] = ' ';
    pos += 1;
    @memcpy(buf[pos..][0..sid.len], sid);
    pos += sid.len;
    @memcpy(buf[pos..][0..2], "\r\n");
    pos += 2;
    return buf[0..pos];
}

/// Encode UNSUB message: "UNSUB <sid> [max_msgs]\r\n"
pub fn encodeUnsub(buf: []u8, sid: []const u8, max_msgs: ?u64) []const u8 {
    var pos: usize = 0;
    @memcpy(buf[pos..][0..6], "UNSUB ");
    pos += 6;
    @memcpy(buf[pos..][0..sid.len], sid);
    pos += sid.len;
    if (max_msgs) |max| {
        buf[pos] = ' ';
        pos += 1;
        const len_str = std.fmt.bufPrint(buf[pos..], "{d}", .{max}) catch return buf[0..0];
        pos += len_str.len;
    }
    @memcpy(buf[pos..][0..2], "\r\n");
    pos += 2;
    return buf[0..pos];
}

/// Encode MSG message: "MSG <subject> <sid> [reply] <#bytes>\r\n<payload>\r\n"
pub fn encodeMsg(buf: []u8, subject: []const u8, sid: []const u8, reply_to: ?[]const u8, payload: []const u8) []const u8 {
    var pos: usize = 0;
    @memcpy(buf[pos..][0..4], "MSG ");
    pos += 4;
    @memcpy(buf[pos..][0..subject.len], subject);
    pos += subject.len;
    buf[pos] = ' ';
    pos += 1;
    @memcpy(buf[pos..][0..sid.len], sid);
    pos += sid.len;
    if (reply_to) |reply| {
        buf[pos] = ' ';
        pos += 1;
        @memcpy(buf[pos..][0..reply.len], reply);
        pos += reply.len;
    }
    buf[pos] = ' ';
    pos += 1;
    const len_str = std.fmt.bufPrint(buf[pos..], "{d}", .{payload.len}) catch return buf[0..0];
    pos += len_str.len;
    @memcpy(buf[pos..][0..2], "\r\n");
    pos += 2;
    @memcpy(buf[pos..][0..payload.len], payload);
    pos += payload.len;
    @memcpy(buf[pos..][0..2], "\r\n");
    pos += 2;
    return buf[0..pos];
}

/// Encode HPUB message: "HPUB <subject> [reply] <hdr_len> <total_len>\r\n<headers><payload>\r\n"
pub fn encodeHpub(buf: []u8, subject: []const u8, reply_to: ?[]const u8, headers: []const u8, payload: []const u8) []const u8 {
    var pos: usize = 0;
    @memcpy(buf[pos..][0..5], "HPUB ");
    pos += 5;
    @memcpy(buf[pos..][0..subject.len], subject);
    pos += subject.len;
    if (reply_to) |reply| {
        buf[pos] = ' ';
        pos += 1;
        @memcpy(buf[pos..][0..reply.len], reply);
        pos += reply.len;
    }
    buf[pos] = ' ';
    pos += 1;
    const hdr_str = std.fmt.bufPrint(buf[pos..], "{d}", .{headers.len}) catch return buf[0..0];
    pos += hdr_str.len;
    buf[pos] = ' ';
    pos += 1;
    const total_str = std.fmt.bufPrint(buf[pos..], "{d}", .{headers.len + payload.len}) catch return buf[0..0];
    pos += total_str.len;
    @memcpy(buf[pos..][0..2], "\r\n");
    pos += 2;
    @memcpy(buf[pos..][0..headers.len], headers);
    pos += headers.len;
    @memcpy(buf[pos..][0..payload.len], payload);
    pos += payload.len;
    @memcpy(buf[pos..][0..2], "\r\n");
    pos += 2;
    return buf[0..pos];
}

/// Encode HMSG message: "HMSG <subject> <sid> [reply] <hdr_len> <total_len>\r\n<headers><payload>\r\n"
pub fn encodeHmsg(buf: []u8, subject: []const u8, sid: []const u8, reply_to: ?[]const u8, headers: []const u8, payload: []const u8) []const u8 {
    var pos: usize = 0;
    @memcpy(buf[pos..][0..5], "HMSG ");
    pos += 5;
    @memcpy(buf[pos..][0..subject.len], subject);
    pos += subject.len;
    buf[pos] = ' ';
    pos += 1;
    @memcpy(buf[pos..][0..sid.len], sid);
    pos += sid.len;
    if (reply_to) |reply| {
        buf[pos] = ' ';
        pos += 1;
        @memcpy(buf[pos..][0..reply.len], reply);
        pos += reply.len;
    }
    buf[pos] = ' ';
    pos += 1;
    const hdr_str = std.fmt.bufPrint(buf[pos..], "{d}", .{headers.len}) catch return buf[0..0];
    pos += hdr_str.len;
    buf[pos] = ' ';
    pos += 1;
    const total_str = std.fmt.bufPrint(buf[pos..], "{d}", .{headers.len + payload.len}) catch return buf[0..0];
    pos += total_str.len;
    @memcpy(buf[pos..][0..2], "\r\n");
    pos += 2;
    @memcpy(buf[pos..][0..headers.len], headers);
    pos += headers.len;
    @memcpy(buf[pos..][0..payload.len], payload);
    pos += payload.len;
    @memcpy(buf[pos..][0..2], "\r\n");
    pos += 2;
    return buf[0..pos];
}

/// Encode PING: "PING\r\n"
pub fn encodePing(buf: []u8) []const u8 {
    @memcpy(buf[0..6], "PING\r\n");
    return buf[0..6];
}

/// Encode PONG: "PONG\r\n"
pub fn encodePong(buf: []u8) []const u8 {
    @memcpy(buf[0..6], "PONG\r\n");
    return buf[0..6];
}

/// Encode +OK: "+OK\r\n"
pub fn encodeOk(buf: []u8) []const u8 {
    @memcpy(buf[0..5], "+OK\r\n");
    return buf[0..5];
}

/// Encode -ERR: "-ERR '<message>'\r\n"
pub fn encodeErr(buf: []u8, message: []const u8) []const u8 {
    var pos: usize = 0;
    @memcpy(buf[pos..][0..6], "-ERR '");
    pos += 6;
    @memcpy(buf[pos..][0..message.len], message);
    pos += message.len;
    @memcpy(buf[pos..][0..3], "'\r\n");
    pos += 3;
    return buf[0..pos];
}

// --- JSON helpers ---

/// Extract a string value from a JSON object by key.
/// Simple scanner — no nested object support needed for CONNECT payloads.
/// Returns null if key not found.
pub fn jsonGetString(json: []const u8, key: []const u8) ?[]const u8 {
    // Search for "key":"value"
    var pos: usize = 0;
    while (pos + key.len + 4 < json.len) : (pos += 1) {
        if (json[pos] != '"') continue;
        const key_start = pos + 1;
        if (key_start + key.len >= json.len) break;
        if (!std.mem.eql(u8, json[key_start..][0..key.len], key)) continue;
        if (json[key_start + key.len] != '"') continue;
        // Found key — look for : then "value"
        var scan = key_start + key.len + 1;
        // Skip whitespace and colon
        while (scan < json.len and (json[scan] == ' ' or json[scan] == ':')) : (scan += 1) {}
        if (scan >= json.len or json[scan] != '"') continue;
        const val_start = scan + 1;
        var val_end = val_start;
        while (val_end < json.len and json[val_end] != '"') : (val_end += 1) {}
        if (val_end >= json.len) continue;
        return json[val_start..val_end];
    }
    return null;
}

/// Extract a boolean value from a JSON object by key.
pub fn jsonGetBool(json: []const u8, key: []const u8) ?bool {
    var pos: usize = 0;
    while (pos + key.len + 4 < json.len) : (pos += 1) {
        if (json[pos] != '"') continue;
        const key_start = pos + 1;
        if (key_start + key.len >= json.len) break;
        if (!std.mem.eql(u8, json[key_start..][0..key.len], key)) continue;
        if (json[key_start + key.len] != '"') continue;
        var scan = key_start + key.len + 1;
        while (scan < json.len and (json[scan] == ' ' or json[scan] == ':')) : (scan += 1) {}
        if (scan + 4 <= json.len and std.mem.eql(u8, json[scan..][0..4], "true")) return true;
        if (scan + 5 <= json.len and std.mem.eql(u8, json[scan..][0..5], "false")) return false;
        return null;
    }
    return null;
}

// --- Helpers ---

fn findCrlf(buf: []const u8) ?usize {
    if (buf.len < 2) return null;
    for (0..buf.len - 1) |i| {
        if (buf[i] == '\r' and buf[i + 1] == '\n') return i;
    }
    return null;
}

fn startsWith(haystack: []const u8, prefix: []const u8) bool {
    if (haystack.len < prefix.len) return false;
    return std.mem.eql(u8, haystack[0..prefix.len], prefix);
}

/// Split on spaces, skipping consecutive spaces
fn splitSpaces(s: []const u8) SpaceIterator {
    return .{ .buf = s, .pos = 0 };
}

const SpaceIterator = struct {
    buf: []const u8,
    pos: usize,

    pub fn next(self: *SpaceIterator) ?[]const u8 {
        // Skip leading spaces
        while (self.pos < self.buf.len and self.buf[self.pos] == ' ') {
            self.pos += 1;
        }
        if (self.pos >= self.buf.len) return null;

        const start = self.pos;
        while (self.pos < self.buf.len and self.buf[self.pos] != ' ') {
            self.pos += 1;
        }
        return self.buf[start..self.pos];
    }
};

// --- Tests ---

test "parse PING" {
    const result = try parse("PING\r\n");
    try std.testing.expect(result.command == .ping);
    try std.testing.expectEqual(@as(usize, 6), result.bytes_consumed);
}

test "parse PONG" {
    const result = try parse("PONG\r\n");
    try std.testing.expect(result.command == .pong);
    try std.testing.expectEqual(@as(usize, 6), result.bytes_consumed);
}

test "parse +OK" {
    const result = try parse("+OK\r\n");
    try std.testing.expect(result.command == .ok);
    try std.testing.expectEqual(@as(usize, 5), result.bytes_consumed);
}

test "parse -ERR" {
    const result = try parse("-ERR 'Unknown Protocol Operation'\r\n");
    try std.testing.expect(result.command == .err);
    try std.testing.expectEqualStrings("Unknown Protocol Operation", result.command.err);
}

test "parse INFO" {
    const result = try parse("INFO {\"server_id\":\"test\"}\r\n");
    try std.testing.expect(result.command == .info);
    try std.testing.expectEqualStrings("{\"server_id\":\"test\"}", result.command.info.json);
}

test "parse CONNECT" {
    const result = try parse("CONNECT {\"verbose\":false}\r\n");
    try std.testing.expect(result.command == .connect);
    try std.testing.expectEqualStrings("{\"verbose\":false}", result.command.connect.json);
}

test "parse SUB without queue group" {
    const result = try parse("SUB foo.bar 1\r\n");
    try std.testing.expect(result.command == .sub);
    try std.testing.expectEqualStrings("foo.bar", result.command.sub.subject);
    try std.testing.expect(result.command.sub.queue_group == null);
    try std.testing.expectEqualStrings("1", result.command.sub.sid);
}

test "parse SUB with queue group" {
    const result = try parse("SUB foo.bar workers 5\r\n");
    try std.testing.expect(result.command == .sub);
    try std.testing.expectEqualStrings("foo.bar", result.command.sub.subject);
    try std.testing.expectEqualStrings("workers", result.command.sub.queue_group.?);
    try std.testing.expectEqualStrings("5", result.command.sub.sid);
}

test "parse UNSUB without max" {
    const result = try parse("UNSUB 1\r\n");
    try std.testing.expect(result.command == .unsub);
    try std.testing.expectEqualStrings("1", result.command.unsub.sid);
    try std.testing.expect(result.command.unsub.max_msgs == null);
}

test "parse UNSUB with max" {
    const result = try parse("UNSUB 1 10\r\n");
    try std.testing.expect(result.command == .unsub);
    try std.testing.expectEqualStrings("1", result.command.unsub.sid);
    try std.testing.expectEqual(@as(u64, 10), result.command.unsub.max_msgs.?);
}

test "parse PUB without reply" {
    const result = try parse("PUB foo 5\r\nHello\r\n");
    try std.testing.expect(result.command == .pub_msg);
    try std.testing.expectEqualStrings("foo", result.command.pub_msg.subject);
    try std.testing.expect(result.command.pub_msg.reply_to == null);
    try std.testing.expectEqual(@as(usize, 5), result.command.pub_msg.payload_len);
    try std.testing.expectEqualStrings("Hello", result.command.pub_msg.payload);
}

test "parse PUB with reply" {
    const result = try parse("PUB foo reply.to 5\r\nHello\r\n");
    try std.testing.expect(result.command == .pub_msg);
    try std.testing.expectEqualStrings("foo", result.command.pub_msg.subject);
    try std.testing.expectEqualStrings("reply.to", result.command.pub_msg.reply_to.?);
    try std.testing.expectEqualStrings("Hello", result.command.pub_msg.payload);
}

test "parse PUB incomplete payload" {
    const err = parse("PUB foo 10\r\nHello\r\n");
    try std.testing.expectError(ParseError.IncompletePayload, err);
}

test "parse MSG without reply" {
    const result = try parse("MSG foo 1 5\r\nHello\r\n");
    try std.testing.expect(result.command == .msg);
    try std.testing.expectEqualStrings("foo", result.command.msg.subject);
    try std.testing.expectEqualStrings("1", result.command.msg.sid);
    try std.testing.expect(result.command.msg.reply_to == null);
    try std.testing.expectEqualStrings("Hello", result.command.msg.payload);
}

test "parse MSG with reply" {
    const result = try parse("MSG foo 1 reply.to 5\r\nHello\r\n");
    try std.testing.expect(result.command == .msg);
    try std.testing.expectEqualStrings("reply.to", result.command.msg.reply_to.?);
}

test "parse incomplete line" {
    const err = parse("PING");
    try std.testing.expectError(ParseError.IncompleteLine, err);
}

test "parse invalid command" {
    const err = parse("INVALID\r\n");
    try std.testing.expectError(ParseError.InvalidCommand, err);
}

test "parse PUB zero-length payload" {
    const result = try parse("PUB foo 0\r\n\r\n");
    try std.testing.expect(result.command == .pub_msg);
    try std.testing.expectEqual(@as(usize, 0), result.command.pub_msg.payload_len);
    try std.testing.expectEqualStrings("", result.command.pub_msg.payload);
}

test "encode PUB" {
    var buf: [256]u8 = undefined;
    const encoded = encodePub(&buf, "foo.bar", null, "Hello");
    try std.testing.expectEqualStrings("PUB foo.bar 5\r\nHello\r\n", encoded);
}

test "encode PUB with reply" {
    var buf: [256]u8 = undefined;
    const encoded = encodePub(&buf, "foo", "inbox.123", "Hi");
    try std.testing.expectEqualStrings("PUB foo inbox.123 2\r\nHi\r\n", encoded);
}

test "encode MSG" {
    var buf: [256]u8 = undefined;
    const encoded = encodeMsg(&buf, "foo", "1", null, "Hello");
    try std.testing.expectEqualStrings("MSG foo 1 5\r\nHello\r\n", encoded);
}

test "encode SUB" {
    var buf: [256]u8 = undefined;
    const encoded = encodeSub(&buf, "foo.>", null, "1");
    try std.testing.expectEqualStrings("SUB foo.> 1\r\n", encoded);
}

test "encode SUB with queue" {
    var buf: [256]u8 = undefined;
    const encoded = encodeSub(&buf, "foo.bar", "workers", "5");
    try std.testing.expectEqualStrings("SUB foo.bar workers 5\r\n", encoded);
}

test "encode ERR" {
    var buf: [256]u8 = undefined;
    const encoded = encodeErr(&buf, "Authorization Violation");
    try std.testing.expectEqualStrings("-ERR 'Authorization Violation'\r\n", encoded);
}

test "roundtrip PUB parse-encode" {
    const input = "PUB test.subject reply.inbox 11\r\nHello World\r\n";
    const result = try parse(input);
    const pub_msg = result.command.pub_msg;

    var buf: [256]u8 = undefined;
    const encoded = encodePub(&buf, pub_msg.subject, pub_msg.reply_to, pub_msg.payload);
    try std.testing.expectEqualStrings(input, encoded);
}

test "jsonGetString" {
    const json = "{\"verbose\":false,\"auth_token\":\"secret123\",\"name\":\"test\"}";
    try std.testing.expectEqualStrings("secret123", jsonGetString(json, "auth_token").?);
    try std.testing.expectEqualStrings("test", jsonGetString(json, "name").?);
    try std.testing.expect(jsonGetString(json, "missing") == null);
}

test "jsonGetBool" {
    const json = "{\"verbose\":true,\"pedantic\":false}";
    try std.testing.expectEqual(true, jsonGetBool(json, "verbose").?);
    try std.testing.expectEqual(false, jsonGetBool(json, "pedantic").?);
    try std.testing.expect(jsonGetBool(json, "missing") == null);
}

test "parse HPUB without reply" {
    const input = "HPUB foo 18 23\r\nNATS/1.0\r\nA: B\r\n\r\nHello\r\n";
    const result = try parse(input);
    try std.testing.expect(result.command == .hpub);
    const hpub = result.command.hpub;
    try std.testing.expectEqualStrings("foo", hpub.subject);
    try std.testing.expect(hpub.reply_to == null);
    try std.testing.expectEqual(@as(usize, 18), hpub.header_len);
    try std.testing.expectEqual(@as(usize, 23), hpub.total_len);
    try std.testing.expectEqualStrings("NATS/1.0\r\nA: B\r\n\r\n", hpub.headers);
    try std.testing.expectEqualStrings("Hello", hpub.payload);
}

test "parse HPUB with reply" {
    const input = "HPUB foo reply.to 18 23\r\nNATS/1.0\r\nA: B\r\n\r\nHello\r\n";
    const result = try parse(input);
    try std.testing.expect(result.command == .hpub);
    try std.testing.expectEqualStrings("reply.to", result.command.hpub.reply_to.?);
    try std.testing.expectEqualStrings("Hello", result.command.hpub.payload);
}

test "parse HPUB headers only no payload" {
    const input = "HPUB foo 18 18\r\nNATS/1.0\r\nA: B\r\n\r\n\r\n";
    const result = try parse(input);
    try std.testing.expect(result.command == .hpub);
    try std.testing.expectEqual(@as(usize, 18), result.command.hpub.header_len);
    try std.testing.expectEqual(@as(usize, 18), result.command.hpub.total_len);
    try std.testing.expectEqualStrings("", result.command.hpub.payload);
}

test "parse HPUB incomplete" {
    const err = parse("HPUB foo 18 23\r\nNATS/1.0\r\n");
    try std.testing.expectError(ParseError.IncompletePayload, err);
}

test "parse HMSG without reply" {
    const input = "HMSG foo 1 18 23\r\nNATS/1.0\r\nA: B\r\n\r\nHello\r\n";
    const result = try parse(input);
    try std.testing.expect(result.command == .hmsg);
    const hmsg = result.command.hmsg;
    try std.testing.expectEqualStrings("foo", hmsg.subject);
    try std.testing.expectEqualStrings("1", hmsg.sid);
    try std.testing.expect(hmsg.reply_to == null);
    try std.testing.expectEqual(@as(usize, 18), hmsg.header_len);
    try std.testing.expectEqualStrings("NATS/1.0\r\nA: B\r\n\r\n", hmsg.headers);
    try std.testing.expectEqualStrings("Hello", hmsg.payload);
}

test "parse HMSG with reply" {
    const input = "HMSG foo 1 reply.to 18 23\r\nNATS/1.0\r\nA: B\r\n\r\nHello\r\n";
    const result = try parse(input);
    try std.testing.expect(result.command == .hmsg);
    try std.testing.expectEqualStrings("reply.to", result.command.hmsg.reply_to.?);
}

test "encode HPUB" {
    var buf: [512]u8 = undefined;
    const hdrs = "NATS/1.0\r\nA: B\r\n\r\n";
    const encoded = encodeHpub(&buf, "foo", null, hdrs, "Hello");
    try std.testing.expectEqualStrings("HPUB foo 18 23\r\nNATS/1.0\r\nA: B\r\n\r\nHello\r\n", encoded);
}

test "encode HMSG" {
    var buf: [512]u8 = undefined;
    const hdrs = "NATS/1.0\r\nA: B\r\n\r\n";
    const encoded = encodeHmsg(&buf, "foo", "1", null, hdrs, "Hello");
    try std.testing.expectEqualStrings("HMSG foo 1 18 23\r\nNATS/1.0\r\nA: B\r\n\r\nHello\r\n", encoded);
}
