/// IPv4 header parsing and construction.
/// Wire-format extern struct — zero-copy cast from packet data.
/// All multi-byte fields are network byte order (big-endian).

const std = @import("std");
const checksum = @import("checksum.zig");

/// IPv4 protocol numbers.
pub const Protocol = enum(u8) {
    icmp = 1,
    tcp = 6,
    udp = 17,
    _,
};

/// IPv4 header (20 bytes minimum, no options).
/// Matches wire format exactly for zero-copy casting.
pub const Ipv4Header = extern struct {
    ver_ihl: u8, // version (4 bits) | IHL (4 bits)
    tos: u8, // DSCP (6) | ECN (2)
    total_len: u16, // network order
    identification: u16, // network order
    flags_frag: u16, // flags (3) | fragment offset (13), network order
    ttl: u8,
    protocol: u8,
    header_checksum: u16, // network order
    src_addr: u32, // network order
    dst_addr: u32, // network order

    /// IP version (should be 4).
    pub fn version(self: *const Ipv4Header) u4 {
        return @intCast(self.ver_ihl >> 4);
    }

    /// Internet Header Length in 32-bit words (min 5 = 20 bytes).
    pub fn ihl(self: *const Ipv4Header) u4 {
        return @intCast(self.ver_ihl & 0x0F);
    }

    /// Header length in bytes.
    pub fn headerLen(self: *const Ipv4Header) u16 {
        return @as(u16, self.ihl()) * 4;
    }

    /// Total packet length in bytes (header + payload).
    pub fn totalLen(self: *const Ipv4Header) u16 {
        return std.mem.bigToNative(u16, self.total_len);
    }

    /// Protocol number.
    pub fn proto(self: *const Ipv4Header) Protocol {
        return @enumFromInt(self.protocol);
    }

    /// Source IP as host-order u32.
    pub fn srcAddr(self: *const Ipv4Header) u32 {
        return std.mem.bigToNative(u32, self.src_addr);
    }

    /// Destination IP as host-order u32.
    pub fn dstAddr(self: *const Ipv4Header) u32 {
        return std.mem.bigToNative(u32, self.dst_addr);
    }

    /// Don't Fragment flag.
    pub fn dontFragment(self: *const Ipv4Header) bool {
        return (std.mem.bigToNative(u16, self.flags_frag) & 0x4000) != 0;
    }

    /// More Fragments flag.
    pub fn moreFragments(self: *const Ipv4Header) bool {
        return (std.mem.bigToNative(u16, self.flags_frag) & 0x2000) != 0;
    }

    /// Fragment offset (in 8-byte units).
    pub fn fragOffset(self: *const Ipv4Header) u13 {
        return @intCast(std.mem.bigToNative(u16, self.flags_frag) & 0x1FFF);
    }

    /// Verify header checksum.
    pub fn verifyChecksum(self: *const Ipv4Header) bool {
        const hdr_bytes: [*]const u8 = @ptrCast(self);
        return checksum.verify(hdr_bytes[0..self.headerLen()]);
    }

    /// Set fields for a basic IPv4 header (no options).
    pub fn init(self: *Ipv4Header, protocol: Protocol, src: u32, dst: u32, payload_len: u16, ttl_val: u8) void {
        self.ver_ihl = 0x45; // version 4, IHL 5 (20 bytes)
        self.tos = 0;
        self.total_len = std.mem.nativeToBig(u16, 20 + payload_len);
        self.identification = 0;
        self.flags_frag = std.mem.nativeToBig(u16, 0x4000); // Don't Fragment
        self.ttl = ttl_val;
        self.protocol = @intFromEnum(protocol);
        self.header_checksum = 0;
        self.src_addr = std.mem.nativeToBig(u32, src);
        self.dst_addr = std.mem.nativeToBig(u32, dst);
        // Compute and set checksum
        const hdr_bytes: [*]const u8 = @ptrCast(self);
        self.header_checksum = std.mem.nativeToBig(u16, checksum.ipv4HeaderChecksum(hdr_bytes[0..20]));
    }

    comptime {
        if (@sizeOf(Ipv4Header) != 20)
            @compileError("Ipv4Header must be exactly 20 bytes");
    }
};

/// Parse an IPv4 header from raw data. Zero-copy. Returns null if invalid.
pub fn parse(data: []u8) ?*Ipv4Header {
    if (data.len < 20) return null;
    const hdr: *Ipv4Header = @ptrCast(@alignCast(data.ptr));
    if (hdr.version() != 4) return null;
    if (hdr.ihl() < 5) return null;
    if (hdr.headerLen() > data.len) return null;
    return hdr;
}

/// Parse result: header pointer + payload slice.
pub const ParseResult = struct {
    header: *Ipv4Header,
    payload: []u8,
};

/// Parse IPv4 header and return header + payload. Validates version and IHL.
pub fn parsePacket(data: []u8) ?ParseResult {
    const hdr = parse(data) orelse return null;
    const hdr_len = hdr.headerLen();
    if (data.len < hdr_len) return null;
    return .{
        .header = hdr,
        .payload = data[hdr_len..],
    };
}

/// Format an IPv4 address as "A.B.C.D" from a host-order u32.
pub fn formatAddr(addr: u32) [15]u8 {
    var buf: [15]u8 = [_]u8{' '} ** 15;
    _ = std.fmt.bufPrint(&buf, "{d}.{d}.{d}.{d}", .{
        @as(u8, @intCast((addr >> 24) & 0xFF)),
        @as(u8, @intCast((addr >> 16) & 0xFF)),
        @as(u8, @intCast((addr >> 8) & 0xFF)),
        @as(u8, @intCast(addr & 0xFF)),
    }) catch {};
    return buf;
}

// ── Tests ────────────────────────────────────────────────────────────────

const testing = std.testing;

test "ipv4: header size is 20 bytes" {
    try testing.expectEqual(@as(usize, 20), @sizeOf(Ipv4Header));
}

test "ipv4: parse valid packet" {
    // Minimal IPv4 packet: version=4, IHL=5, total_len=40, TTL=64, protocol=TCP
    var pkt: [40]u8 align(8) = std.mem.zeroes([40]u8);
    pkt[0] = 0x45; // ver=4, ihl=5
    pkt[1] = 0x00; // tos
    pkt[2] = 0x00;
    pkt[3] = 0x28; // total_len = 40
    pkt[8] = 64; // TTL
    pkt[9] = 6; // TCP
    // src: 192.168.1.1
    pkt[12] = 192;
    pkt[13] = 168;
    pkt[14] = 1;
    pkt[15] = 1;
    // dst: 10.0.0.1
    pkt[16] = 10;
    pkt[17] = 0;
    pkt[18] = 0;
    pkt[19] = 1;

    const result = parsePacket(&pkt).?;
    try testing.expectEqual(@as(u4, 4), result.header.version());
    try testing.expectEqual(@as(u4, 5), result.header.ihl());
    try testing.expectEqual(@as(u16, 40), result.header.totalLen());
    try testing.expectEqual(Protocol.tcp, result.header.proto());
    try testing.expectEqual(@as(u8, 64), result.header.ttl);
    try testing.expectEqual(@as(usize, 20), result.payload.len);
}

test "ipv4: parse too short" {
    var pkt: [10]u8 = undefined;
    try testing.expect(parse(&pkt) == null);
}

test "ipv4: parse wrong version" {
    var pkt: [20]u8 align(8) = std.mem.zeroes([20]u8);
    pkt[0] = 0x65; // version 6 (not IPv4)
    try testing.expect(parse(&pkt) == null);
}

test "ipv4: init and verify checksum" {
    var hdr: Ipv4Header = undefined;
    hdr.init(.tcp, 0xC0A80101, 0x0A000001, 20, 64);
    try testing.expectEqual(@as(u4, 4), hdr.version());
    try testing.expectEqual(@as(u4, 5), hdr.ihl());
    try testing.expectEqual(@as(u16, 40), hdr.totalLen());
    try testing.expect(hdr.verifyChecksum());
    try testing.expect(hdr.dontFragment());
}

test "ipv4: format address" {
    const buf = formatAddr(0xC0A80101); // 192.168.1.1
    // Find the null-terminated or space-padded string
    // Find end of formatted string (trim trailing spaces)
    var end: usize = buf.len;
    while (end > 0 and buf[end - 1] == ' ') end -= 1;
    try testing.expectEqualStrings("192.168.1.1", buf[0..end]);
}
