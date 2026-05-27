const std = @import("std");
const proto = @import("proto.zig");

const posix = std.posix;
const ArrayList = std.ArrayList;

const Message = proto.Message;

pub const allocator = std.testing.allocator;

pub fn expectEqual(expected: anytype, actual: anytype) !void {
    try std.testing.expectEqual(@as(@TypeOf(actual), expected), actual);
}

pub const expectError = std.testing.expectError;
pub const expectString = std.testing.expectEqualStrings;
pub const expectSlice = std.testing.expectEqualSlices;

pub fn getRandom() !std.Random.DefaultPrng {
    var seed: u64 = undefined;
    try std.posix.getrandom(std.mem.asBytes(&seed));
    return std.Random.DefaultPrng.init(seed);
}

pub var arena = std.heap.ArenaAllocator.init(allocator);
pub fn reset() void {
    _ = arena.reset(.free_all);
}

pub const Writer = struct {
    pos: usize,
    buf: std.ArrayList(u8),
    random: std.Random.DefaultPrng,

    pub fn init() !Writer {
        return .{
            .pos = 0,
            .buf = .empty,
            .random = try getRandom(),
        };
    }

    pub fn deinit(self: *Writer) void {
        self.buf.deinit(allocator);
    }

    pub fn ping(self: *Writer) !void {
        return self.pingPayload("");
    }

    pub fn pong(self: *Writer) !void {
        return self.frame(true, 10, "", 0);
    }

    pub fn pingPayload(self: *Writer, payload: []const u8) !void {
        return self.frame(true, 9, payload, 0);
    }

    pub fn textFrame(self: *Writer, fin: bool, payload: []const u8) !void {
        return self.frame(fin, 1, payload, 0);
    }

    pub fn cont(self: *Writer, fin: bool, payload: []const u8) !void {
        return self.frame(fin, 0, payload, 0);
    }

    pub fn frame(self: *Writer, fin: bool, op_code: u8, payload: []const u8, reserved: u8) !void {
        var buf = &self.buf;

        const l = payload.len;
        var length_of_length: usize = 0;

        if (l > 125) {
            if (l < 65536) {
                length_of_length = 2;
            } else {
                length_of_length = 8;
            }
        }

        // Pre-allocate the full frame in one shot (2 byte header +
        // length_of_length + mask + payload). The safe append calls
        // below check capacity each time — the ensureUnusedCapacity
        // up front just avoids gradual reallocations.
        const needed = 2 + length_of_length + 4 + l;
        try buf.ensureUnusedCapacity(allocator, needed);

        if (fin) {
            try buf.append(allocator, 128 | op_code | reserved);
        } else {
            try buf.append(allocator, op_code | reserved);
        }

        if (length_of_length == 0) {
            try buf.append(allocator, 128 | @as(u8, @intCast(l)));
        } else if (length_of_length == 2) {
            try buf.append(allocator, 128 | 126);
            try buf.append(allocator, @intCast((l >> 8) & 0xFF));
            try buf.append(allocator, @intCast(l & 0xFF));
        } else {
            try buf.append(allocator, 128 | 127);
            try buf.append(allocator, @intCast((l >> 56) & 0xFF));
            try buf.append(allocator, @intCast((l >> 48) & 0xFF));
            try buf.append(allocator, @intCast((l >> 40) & 0xFF));
            try buf.append(allocator, @intCast((l >> 32) & 0xFF));
            try buf.append(allocator, @intCast((l >> 24) & 0xFF));
            try buf.append(allocator, @intCast((l >> 16) & 0xFF));
            try buf.append(allocator, @intCast((l >> 8) & 0xFF));
            try buf.append(allocator, @intCast(l & 0xFF));
        }

        var mask: [4]u8 = undefined;
        self.random.random().bytes(&mask);

        try buf.appendSlice(allocator, &mask);
        for (payload, 0..) |b, i| {
            try buf.append(allocator, b ^ mask[i & 3]);
        }
    }

    pub fn bytes(self: *const Writer) []const u8 {
        return self.buf.items;
    }

    pub fn clear(self: *Writer) void {
        self.pos = 0;
        self.buf.clearRetainingCapacity();
    }

    pub fn read(
        self: *Writer,
        buf: []u8,
    ) !usize {
        const data = self.buf.items[self.pos..];

        if (data.len == 0 or buf.len == 0) {
            return 0;
        }

        // randomly fragment the data
        const to_read = self.random.random().intRangeAtMost(usize, 1, @min(data.len, buf.len));
        @memcpy(buf[0..to_read], data[0..to_read]);
        self.pos += to_read;
        return to_read;
    }
};

pub const SocketPair = struct {
    writer: Writer,
    client: std.net.Stream,
    server: std.net.Stream,

    const Opts = struct {
        port: ?u16 = null,
    };

    pub fn init(opts: Opts) !SocketPair {
        var address = try std.net.Address.parseIp("127.0.0.1", opts.port orelse 0);
        var address_len = address.getOsSockLen();

        const listener = try posix.socket(address.any.family, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, posix.IPPROTO.TCP);
        defer _ = std.c.close(listener);

        {
            // setup our listener
            try posix.bind(listener, &address.any, address_len);
            try posix.listen(listener, 1);
            try posix.getsockname(listener, &address.any, &address_len);
        }

        const client = try posix.socket(address.any.family, posix.SOCK.STREAM, posix.IPPROTO.TCP);
        {
            // connect the client
            const flags = try posix.fcntl(client, posix.F.GETFL, 0);
            _ = try posix.fcntl(client, posix.F.SETFL, flags | posix.SOCK.NONBLOCK);
            posix.connect(client, &address.any, address_len) catch |err| switch (err) {
                error.WouldBlock => {},
                else => return err,
            };
            _ = try posix.fcntl(client, posix.F.SETFL, flags);
        }

        const server = try posix.accept(listener, &address.any, &address_len, posix.SOCK.CLOEXEC);

        return .{
            .client = .{ .handle = client },
            .server = .{ .handle = server },
            .writer = try Writer.init(),
        };
    }

    pub fn deinit(self: *SocketPair) void {
        self.writer.deinit();
        // assume test closes self.server
        self.client.close();
    }

    pub fn pingPayload(self: *SocketPair, payload: []const u8) !void {
        try self.writer.pingPayload(payload);
    }

    pub fn textFrame(self: *SocketPair, fin: bool, payload: []const u8) !void {
        try self.writer.textFrame(fin, payload);
    }

    pub fn cont(self: *SocketPair, fin: bool, payload: []const u8) !void {
        try self.writer.cont(fin, payload);
    }

    pub fn sendBuf(self: *SocketPair) !void {
        try self.client.writeAll(self.writer.bytes());
        self.writer.clear();
    }
};
