/// UDP header parsing and construction.
/// Wire-format extern struct for zero-copy casting.
/// Market data feeds (Binance, CME) are typically UDP multicast — this is
/// the primary protocol for the zig_dpdk → market_data_parser path.

const std = @import("std");
const checksum_mod = @import("checksum.zig");

/// UDP header (8 bytes). Matches wire format exactly.
pub const UdpHeader = extern struct {
    src_port: u16, // network order
    dst_port: u16, // network order
    length: u16, // network order (header + payload)
    cksum: u16, // network order (0 = no checksum)

    pub fn srcPort(self: *const UdpHeader) u16 {
        return std.mem.bigToNative(u16, self.src_port);
    }

    pub fn dstPort(self: *const UdpHeader) u16 {
        return std.mem.bigToNative(u16, self.dst_port);
    }

    pub fn dataLen(self: *const UdpHeader) u16 {
        const total = std.mem.bigToNative(u16, self.length);
        return if (total >= 8) total - 8 else 0;
    }

    pub fn totalLen(self: *const UdpHeader) u16 {
        return std.mem.bigToNative(u16, self.length);
    }

    /// Initialize a UDP header.
    pub fn init(self: *UdpHeader, src: u16, dst: u16, payload_len: u16) void {
        self.src_port = std.mem.nativeToBig(u16, src);
        self.dst_port = std.mem.nativeToBig(u16, dst);
        self.length = std.mem.nativeToBig(u16, 8 + payload_len);
        self.cksum = 0; // checksum optional for UDP over IPv4
    }

    /// Verify UDP checksum (including pseudo-header). 0 = no checksum.
    pub fn verifyChecksum(self: *const UdpHeader, src_ip: u32, dst_ip: u32, segment: []const u8) bool {
        if (self.cksum == 0) return true; // no checksum
        const cksum = checksum_mod.transportChecksum(src_ip, dst_ip, 17, segment);
        return cksum == 0;
    }

    comptime {
        if (@sizeOf(UdpHeader) != 8)
            @compileError("UdpHeader must be exactly 8 bytes");
    }
};

/// Parse a UDP header from raw data. Zero-copy.
pub fn parse(data: []u8) ?*UdpHeader {
    if (data.len < @sizeOf(UdpHeader)) return null;
    return @ptrCast(@alignCast(data.ptr));
}

/// Parse result: header + payload.
pub const ParseResult = struct {
    header: *UdpHeader,
    payload: []u8,
};

/// Parse UDP header and return header + payload slice.
pub fn parsePacket(data: []u8) ?ParseResult {
    const hdr = parse(data) orelse return null;
    const hdr_size = @sizeOf(UdpHeader);
    return .{
        .header = hdr,
        .payload = data[hdr_size..@min(data.len, @as(usize, hdr.totalLen()))],
    };
}

// ── Tests ────────────────────────────────────────────────────────────────

const testing = std.testing;

test "udp: header size is 8 bytes" {
    try testing.expectEqual(@as(usize, 8), @sizeOf(UdpHeader));
}

test "udp: parse valid datagram" {
    var pkt: [28]u8 align(8) = std.mem.zeroes([28]u8);
    // src_port = 12345 (0x3039)
    pkt[0] = 0x30;
    pkt[1] = 0x39;
    // dst_port = 9000 (0x2328)
    pkt[2] = 0x23;
    pkt[3] = 0x28;
    // length = 28 (0x001C)
    pkt[4] = 0x00;
    pkt[5] = 0x1C;
    // checksum = 0 (none)
    pkt[6] = 0x00;
    pkt[7] = 0x00;

    const result = parsePacket(&pkt).?;
    try testing.expectEqual(@as(u16, 12345), result.header.srcPort());
    try testing.expectEqual(@as(u16, 9000), result.header.dstPort());
    try testing.expectEqual(@as(u16, 20), result.header.dataLen());
    try testing.expectEqual(@as(usize, 20), result.payload.len);
}

test "udp: parse too short" {
    var pkt: [4]u8 = undefined;
    try testing.expect(parse(&pkt) == null);
}

test "udp: init header" {
    var hdr: UdpHeader = undefined;
    hdr.init(5000, 9000, 100);
    try testing.expectEqual(@as(u16, 5000), hdr.srcPort());
    try testing.expectEqual(@as(u16, 9000), hdr.dstPort());
    try testing.expectEqual(@as(u16, 108), hdr.totalLen());
    try testing.expectEqual(@as(u16, 100), hdr.dataLen());
}

test "udp: zero checksum means no checksum" {
    var hdr: UdpHeader = undefined;
    hdr.init(1000, 2000, 0);
    try testing.expect(hdr.verifyChecksum(0, 0, &[_]u8{}));
}
