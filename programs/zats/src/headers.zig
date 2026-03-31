//! NATS Headers Parser and Encoder
//!
//! Zero-allocation parsing — all slices reference original buffer.
//! NATS headers follow HTTP/1.1 header format:
//!   NATS/1.0 [status] [description]\r\n
//!   Key: Value\r\n
//!   ...\r\n
//!   \r\n

const std = @import("std");

pub const Status = struct {
    code: u16,
    description: []const u8,
};

pub const HeaderEntry = struct {
    name: []const u8,
    value: []const u8,
};

pub const Headers = struct {
    raw: []const u8,

    /// Parse the status line (first line). Returns null if no status code present.
    pub fn status(self: *const Headers) ?Status {
        // First line: "NATS/1.0 [code] [description]\r\n"
        const line_end = findCrlf(self.raw) orelse return null;
        const line = self.raw[0..line_end];

        // Must start with "NATS/1.0"
        if (!startsWith(line, "NATS/1.0")) return null;

        if (line.len <= 8) return null; // just "NATS/1.0"

        // Skip "NATS/1.0 "
        var pos: usize = 8;
        while (pos < line.len and line[pos] == ' ') : (pos += 1) {}
        if (pos >= line.len) return null;

        // Parse status code (3 digits)
        var code_end = pos;
        while (code_end < line.len and line[code_end] >= '0' and line[code_end] <= '9') : (code_end += 1) {}
        if (code_end == pos) return null;

        const code = std.fmt.parseInt(u16, line[pos..code_end], 10) catch return null;

        // Rest is description (skip leading space)
        var desc_start = code_end;
        while (desc_start < line.len and line[desc_start] == ' ') : (desc_start += 1) {}
        const description = if (desc_start < line.len) line[desc_start..] else "";

        return .{ .code = code, .description = description };
    }

    /// Get a header value by name (case-insensitive).
    pub fn get(self: *const Headers, name: []const u8) ?[]const u8 {
        var iter = self.iterator();
        while (iter.next()) |entry| {
            if (eqlIgnoreCase(entry.name, name)) {
                return entry.value;
            }
        }
        return null;
    }

    /// Iterate over all header key-value pairs (skips the status line).
    pub fn iterator(self: *const Headers) Iterator {
        // Skip past first line (status line)
        const first_end = findCrlf(self.raw) orelse return .{ .raw = self.raw, .pos = self.raw.len };
        return .{ .raw = self.raw, .pos = first_end + 2 };
    }

    pub const Iterator = struct {
        raw: []const u8,
        pos: usize,

        pub fn next(self: *Iterator) ?HeaderEntry {
            while (self.pos < self.raw.len) {
                const remaining = self.raw[self.pos..];

                // Check for terminal \r\n (empty line = end of headers)
                if (remaining.len >= 2 and remaining[0] == '\r' and remaining[1] == '\n') {
                    self.pos = self.raw.len; // done
                    return null;
                }

                const line_end = findCrlf(remaining) orelse {
                    self.pos = self.raw.len;
                    return null;
                };

                const line = remaining[0..line_end];
                self.pos += line_end + 2;

                // Find the colon separator
                const colon_pos = std.mem.indexOfScalar(u8, line, ':') orelse continue;
                const name = line[0..colon_pos];

                // Value: skip leading whitespace after colon
                var val_start = colon_pos + 1;
                while (val_start < line.len and line[val_start] == ' ') : (val_start += 1) {}
                const value = line[val_start..];

                return .{ .name = name, .value = value };
            }
            return null;
        }
    };
};

/// Encode headers into a buffer.
/// Returns the number of bytes written.
pub fn encode(buf: []u8, status_code: ?u16, status_desc: ?[]const u8, kvs: []const HeaderEntry) usize {
    var pos: usize = 0;

    // Status line
    @memcpy(buf[pos..][0..8], "NATS/1.0");
    pos += 8;

    if (status_code) |code| {
        buf[pos] = ' ';
        pos += 1;
        const code_str = std.fmt.bufPrint(buf[pos..], "{d}", .{code}) catch return 0;
        pos += code_str.len;
        if (status_desc) |desc| {
            if (desc.len > 0) {
                buf[pos] = ' ';
                pos += 1;
                @memcpy(buf[pos..][0..desc.len], desc);
                pos += desc.len;
            }
        }
    }
    @memcpy(buf[pos..][0..2], "\r\n");
    pos += 2;

    // Key-value pairs
    for (kvs) |kv| {
        @memcpy(buf[pos..][0..kv.name.len], kv.name);
        pos += kv.name.len;
        @memcpy(buf[pos..][0..2], ": ");
        pos += 2;
        @memcpy(buf[pos..][0..kv.value.len], kv.value);
        pos += kv.value.len;
        @memcpy(buf[pos..][0..2], "\r\n");
        pos += 2;
    }

    // Terminal \r\n
    @memcpy(buf[pos..][0..2], "\r\n");
    pos += 2;

    return pos;
}

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

fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        if (toLower(ca) != toLower(cb)) return false;
    }
    return true;
}

fn toLower(c: u8) u8 {
    if (c >= 'A' and c <= 'Z') return c + 32;
    return c;
}

// --- Tests ---

test "headers parse status line" {
    const raw = "NATS/1.0 503 No Responders\r\n\r\n";
    const hdrs = Headers{ .raw = raw };
    const s = hdrs.status().?;
    try std.testing.expectEqual(@as(u16, 503), s.code);
    try std.testing.expectEqualStrings("No Responders", s.description);
}

test "headers parse status line no description" {
    const raw = "NATS/1.0 100\r\n\r\n";
    const hdrs = Headers{ .raw = raw };
    const s = hdrs.status().?;
    try std.testing.expectEqual(@as(u16, 100), s.code);
    try std.testing.expectEqualStrings("", s.description);
}

test "headers no status code" {
    const raw = "NATS/1.0\r\nFoo: bar\r\n\r\n";
    const hdrs = Headers{ .raw = raw };
    try std.testing.expect(hdrs.status() == null);
}

test "headers get by name" {
    const raw = "NATS/1.0\r\nNats-Msg-Id: abc123\r\nX-Custom: hello world\r\n\r\n";
    const hdrs = Headers{ .raw = raw };
    try std.testing.expectEqualStrings("abc123", hdrs.get("Nats-Msg-Id").?);
    try std.testing.expectEqualStrings("hello world", hdrs.get("X-Custom").?);
    try std.testing.expect(hdrs.get("Missing") == null);
}

test "headers get case-insensitive" {
    const raw = "NATS/1.0\r\nNats-Msg-Id: dedup1\r\n\r\n";
    const hdrs = Headers{ .raw = raw };
    try std.testing.expectEqualStrings("dedup1", hdrs.get("nats-msg-id").?);
    try std.testing.expectEqualStrings("dedup1", hdrs.get("NATS-MSG-ID").?);
}

test "headers iterator" {
    const raw = "NATS/1.0\r\nA: 1\r\nB: 2\r\nC: 3\r\n\r\n";
    const hdrs = Headers{ .raw = raw };
    var iter = hdrs.iterator();

    const e1 = iter.next().?;
    try std.testing.expectEqualStrings("A", e1.name);
    try std.testing.expectEqualStrings("1", e1.value);

    const e2 = iter.next().?;
    try std.testing.expectEqualStrings("B", e2.name);
    try std.testing.expectEqualStrings("2", e2.value);

    const e3 = iter.next().?;
    try std.testing.expectEqualStrings("C", e3.name);
    try std.testing.expectEqualStrings("3", e3.value);

    try std.testing.expect(iter.next() == null);
}

test "headers encode" {
    var buf: [512]u8 = undefined;
    const kvs = [_]HeaderEntry{
        .{ .name = "Nats-Msg-Id", .value = "msg1" },
        .{ .name = "X-Custom", .value = "val" },
    };
    const n = encode(&buf, null, null, &kvs);
    try std.testing.expectEqualStrings("NATS/1.0\r\nNats-Msg-Id: msg1\r\nX-Custom: val\r\n\r\n", buf[0..n]);
}

test "headers encode with status" {
    var buf: [512]u8 = undefined;
    const kvs = [_]HeaderEntry{};
    const n = encode(&buf, 503, "No Responders", &kvs);
    try std.testing.expectEqualStrings("NATS/1.0 503 No Responders\r\n\r\n", buf[0..n]);
}

test "headers roundtrip" {
    var buf: [512]u8 = undefined;
    const kvs = [_]HeaderEntry{
        .{ .name = "Nats-Msg-Id", .value = "rt1" },
        .{ .name = "X-Foo", .value = "bar" },
    };
    const n = encode(&buf, null, null, &kvs);
    const hdrs = Headers{ .raw = buf[0..n] };

    try std.testing.expectEqualStrings("rt1", hdrs.get("Nats-Msg-Id").?);
    try std.testing.expectEqualStrings("bar", hdrs.get("X-Foo").?);
}

test "headers empty" {
    var buf: [512]u8 = undefined;
    const kvs = [_]HeaderEntry{};
    const n = encode(&buf, null, null, &kvs);
    try std.testing.expectEqualStrings("NATS/1.0\r\n\r\n", buf[0..n]);
}
