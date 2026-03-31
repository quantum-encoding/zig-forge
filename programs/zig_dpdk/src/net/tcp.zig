/// TCP header parsing and construction.
/// Wire-format extern struct for zero-copy casting.
/// Used for order submission in the trading pipeline and general TCP support.

const std = @import("std");
const checksum_mod = @import("checksum.zig");

/// TCP flags.
pub const Flags = struct {
    pub const FIN: u8 = 0x01;
    pub const SYN: u8 = 0x02;
    pub const RST: u8 = 0x04;
    pub const PSH: u8 = 0x08;
    pub const ACK: u8 = 0x10;
    pub const URG: u8 = 0x20;
    pub const ECE: u8 = 0x40;
    pub const CWR: u8 = 0x80;
};

/// TCP header (20 bytes minimum, no options).
pub const TcpHeader = extern struct {
    src_port: u16, // network order
    dst_port: u16, // network order
    seq_num: u32, // network order
    ack_num: u32, // network order
    data_off_flags: u16, // data offset (4 bits) | reserved (3) | flags (9), network order
    window: u16, // network order
    cksum: u16, // network order
    urgent_ptr: u16, // network order

    pub fn srcPort(self: *const TcpHeader) u16 {
        return std.mem.bigToNative(u16, self.src_port);
    }

    pub fn dstPort(self: *const TcpHeader) u16 {
        return std.mem.bigToNative(u16, self.dst_port);
    }

    pub fn seqNum(self: *const TcpHeader) u32 {
        return std.mem.bigToNative(u32, self.seq_num);
    }

    pub fn ackNum(self: *const TcpHeader) u32 {
        return std.mem.bigToNative(u32, self.ack_num);
    }

    /// Data offset in 32-bit words (min 5 = 20 bytes).
    pub fn dataOffset(self: *const TcpHeader) u4 {
        return @intCast(std.mem.bigToNative(u16, self.data_off_flags) >> 12);
    }

    /// Header length in bytes.
    pub fn headerLen(self: *const TcpHeader) u16 {
        return @as(u16, self.dataOffset()) * 4;
    }

    /// TCP flags byte.
    pub fn flags(self: *const TcpHeader) u8 {
        return @intCast(std.mem.bigToNative(u16, self.data_off_flags) & 0x1FF);
    }

    pub fn isSyn(self: *const TcpHeader) bool {
        return (self.flags() & Flags.SYN) != 0;
    }

    pub fn isAck(self: *const TcpHeader) bool {
        return (self.flags() & Flags.ACK) != 0;
    }

    pub fn isFin(self: *const TcpHeader) bool {
        return (self.flags() & Flags.FIN) != 0;
    }

    pub fn isRst(self: *const TcpHeader) bool {
        return (self.flags() & Flags.RST) != 0;
    }

    pub fn isPsh(self: *const TcpHeader) bool {
        return (self.flags() & Flags.PSH) != 0;
    }

    pub fn windowSize(self: *const TcpHeader) u16 {
        return std.mem.bigToNative(u16, self.window);
    }

    /// Initialize a basic TCP header (no options).
    pub fn init(self: *TcpHeader, src: u16, dst: u16, seq: u32, ack: u32, tcp_flags: u8, win: u16) void {
        self.src_port = std.mem.nativeToBig(u16, src);
        self.dst_port = std.mem.nativeToBig(u16, dst);
        self.seq_num = std.mem.nativeToBig(u32, seq);
        self.ack_num = std.mem.nativeToBig(u32, ack);
        // data offset = 5 (20 bytes), flags in lower 9 bits
        self.data_off_flags = std.mem.nativeToBig(u16, (@as(u16, 5) << 12) | tcp_flags);
        self.window = std.mem.nativeToBig(u16, win);
        self.cksum = 0;
        self.urgent_ptr = 0;
    }

    /// Compute and set the TCP checksum (pseudo-header + segment).
    pub fn computeChecksum(self: *TcpHeader, src_ip: u32, dst_ip: u32, segment: []const u8) void {
        self.cksum = 0;
        self.cksum = std.mem.nativeToBig(u16, checksum_mod.transportChecksum(src_ip, dst_ip, 6, segment));
    }

    /// Verify TCP checksum.
    pub fn verifyChecksum(_: *const TcpHeader, src_ip: u32, dst_ip: u32, segment: []const u8) bool {
        const cksum = checksum_mod.transportChecksum(src_ip, dst_ip, 6, segment);
        return cksum == 0;
    }

    comptime {
        if (@sizeOf(TcpHeader) != 20)
            @compileError("TcpHeader must be exactly 20 bytes");
    }
};

/// Parse a TCP header from raw data. Zero-copy.
pub fn parse(data: []u8) ?*TcpHeader {
    if (data.len < 20) return null;
    const hdr: *TcpHeader = @ptrCast(@alignCast(data.ptr));
    if (hdr.dataOffset() < 5) return null;
    if (hdr.headerLen() > data.len) return null;
    return hdr;
}

/// Parse result: header + payload.
pub const ParseResult = struct {
    header: *TcpHeader,
    payload: []u8,
};

/// Parse TCP header and return header + payload.
pub fn parsePacket(data: []u8) ?ParseResult {
    const hdr = parse(data) orelse return null;
    const hdr_len = hdr.headerLen();
    return .{
        .header = hdr,
        .payload = data[hdr_len..],
    };
}

// ── Tests ────────────────────────────────────────────────────────────────

const testing = std.testing;

test "tcp: header size is 20 bytes" {
    try testing.expectEqual(@as(usize, 20), @sizeOf(TcpHeader));
}

test "tcp: parse valid segment" {
    var pkt: [40]u8 align(8) = std.mem.zeroes([40]u8);
    // src_port = 443 (0x01BB)
    pkt[0] = 0x01;
    pkt[1] = 0xBB;
    // dst_port = 54321 (0xD431)
    pkt[2] = 0xD4;
    pkt[3] = 0x31;
    // seq = 1000
    pkt[4] = 0x00;
    pkt[5] = 0x00;
    pkt[6] = 0x03;
    pkt[7] = 0xE8;
    // ack = 2000
    pkt[8] = 0x00;
    pkt[9] = 0x00;
    pkt[10] = 0x07;
    pkt[11] = 0xD0;
    // data offset = 5, flags = ACK|PSH (0x18)
    pkt[12] = 0x50;
    pkt[13] = 0x18;
    // window = 65535
    pkt[14] = 0xFF;
    pkt[15] = 0xFF;

    const result = parsePacket(&pkt).?;
    try testing.expectEqual(@as(u16, 443), result.header.srcPort());
    try testing.expectEqual(@as(u16, 54321), result.header.dstPort());
    try testing.expectEqual(@as(u32, 1000), result.header.seqNum());
    try testing.expectEqual(@as(u32, 2000), result.header.ackNum());
    try testing.expectEqual(@as(u4, 5), result.header.dataOffset());
    try testing.expect(result.header.isAck());
    try testing.expect(result.header.isPsh());
    try testing.expect(!result.header.isSyn());
    try testing.expect(!result.header.isFin());
    try testing.expectEqual(@as(u16, 65535), result.header.windowSize());
    try testing.expectEqual(@as(usize, 20), result.payload.len);
}

test "tcp: parse too short" {
    var pkt: [10]u8 = undefined;
    try testing.expect(parse(&pkt) == null);
}

test "tcp: init header" {
    var hdr: TcpHeader = undefined;
    hdr.init(8080, 443, 100, 200, Flags.SYN | Flags.ACK, 32768);
    try testing.expectEqual(@as(u16, 8080), hdr.srcPort());
    try testing.expectEqual(@as(u16, 443), hdr.dstPort());
    try testing.expectEqual(@as(u32, 100), hdr.seqNum());
    try testing.expectEqual(@as(u32, 200), hdr.ackNum());
    try testing.expect(hdr.isSyn());
    try testing.expect(hdr.isAck());
    try testing.expectEqual(@as(u16, 32768), hdr.windowSize());
}

test "tcp: flags detection" {
    var hdr: TcpHeader = undefined;
    hdr.init(1000, 2000, 0, 0, Flags.FIN | Flags.ACK, 1024);
    try testing.expect(hdr.isFin());
    try testing.expect(hdr.isAck());
    try testing.expect(!hdr.isSyn());
    try testing.expect(!hdr.isRst());
}
