/// Ethernet frame parsing and construction.
/// All headers are extern structs for zero-copy casting from packet data.
/// Fields are network byte order (big-endian).

const std = @import("std");
const pmd = @import("../drivers/pmd.zig");

/// Common EtherType values (network byte order constants for fast comparison).
pub const EtherType = enum(u16) {
    ipv4 = 0x0800,
    arp = 0x0806,
    vlan = 0x8100,
    ipv6 = 0x86DD,
    _,

    /// Convert from network byte order u16.
    pub fn fromNetBytes(val: u16) EtherType {
        return @enumFromInt(std.mem.bigToNative(u16, val));
    }

    /// Convert to network byte order u16.
    pub fn toNetBytes(self: EtherType) u16 {
        return std.mem.nativeToBig(u16, @intFromEnum(self));
    }
};

/// Ethernet header (14 bytes). No padding — matches wire format exactly.
pub const EthernetHeader = extern struct {
    dst: pmd.MacAddr,
    src: pmd.MacAddr,
    ether_type: u16, // network byte order

    pub fn etherType(self: *const EthernetHeader) EtherType {
        return EtherType.fromNetBytes(self.ether_type);
    }

    pub fn setEtherType(self: *EthernetHeader, et: EtherType) void {
        self.ether_type = et.toNetBytes();
    }

    comptime {
        if (@sizeOf(EthernetHeader) != 14)
            @compileError("EthernetHeader must be exactly 14 bytes");
    }
};

/// 802.1Q VLAN header (4 bytes, inserted between src MAC and EtherType).
pub const VlanHeader = extern struct {
    tpid: u16, // 0x8100 (network order)
    tci: u16, // PCP(3) | DEI(1) | VID(12), network order

    pub fn vlanId(self: *const VlanHeader) u12 {
        return @intCast(std.mem.bigToNative(u16, self.tci) & 0x0FFF);
    }

    pub fn priority(self: *const VlanHeader) u3 {
        return @intCast(std.mem.bigToNative(u16, self.tci) >> 13);
    }

    comptime {
        if (@sizeOf(VlanHeader) != 4)
            @compileError("VlanHeader must be exactly 4 bytes");
    }
};

/// Ethernet + optional VLAN header (18 bytes max).
pub const EthernetVlanHeader = extern struct {
    dst: pmd.MacAddr,
    src: pmd.MacAddr,
    tpid: u16,
    tci: u16,
    ether_type: u16, // real EtherType after VLAN tag

    comptime {
        if (@sizeOf(EthernetVlanHeader) != 18)
            @compileError("EthernetVlanHeader must be exactly 18 bytes");
    }
};

/// Parse an Ethernet header from raw packet data. Zero-copy: returns a pointer
/// into the packet buffer. Returns null if packet is too short.
pub fn parse(data: []u8) ?*EthernetHeader {
    if (data.len < @sizeOf(EthernetHeader)) return null;
    return @ptrCast(@alignCast(data.ptr));
}

/// Parse and return the payload (data after Ethernet header).
/// Handles VLAN tagging: if EtherType is 0x8100, skips the 4-byte VLAN tag.
/// Returns {header_size, ethertype, payload_slice} or null if too short.
pub const ParseResult = struct {
    header_len: u16,
    ether_type: EtherType,
    payload: []u8,
};

pub fn parseFrame(data: []u8) ?ParseResult {
    if (data.len < @sizeOf(EthernetHeader)) return null;
    const hdr: *const EthernetHeader = @ptrCast(@alignCast(data.ptr));

    if (hdr.etherType() == .vlan) {
        // 802.1Q tagged frame: 14 + 4 = 18 byte header
        const vlan_hdr_size = @sizeOf(EthernetVlanHeader);
        if (data.len < vlan_hdr_size) return null;
        const vhdr: *const EthernetVlanHeader = @ptrCast(@alignCast(data.ptr));
        return .{
            .header_len = vlan_hdr_size,
            .ether_type = EtherType.fromNetBytes(vhdr.ether_type),
            .payload = data[vlan_hdr_size..],
        };
    }

    return .{
        .header_len = @sizeOf(EthernetHeader),
        .ether_type = hdr.etherType(),
        .payload = data[@sizeOf(EthernetHeader)..],
    };
}

/// Construct an Ethernet header at the start of a buffer.
pub fn writeHeader(buf: []u8, dst: pmd.MacAddr, src: pmd.MacAddr, ether_type: EtherType) ?*EthernetHeader {
    if (buf.len < @sizeOf(EthernetHeader)) return null;
    const hdr: *EthernetHeader = @ptrCast(@alignCast(buf.ptr));
    hdr.dst = dst;
    hdr.src = src;
    hdr.setEtherType(ether_type);
    return hdr;
}

/// Broadcast MAC address (FF:FF:FF:FF:FF:FF).
pub const BROADCAST_MAC = pmd.MacAddr{ .bytes = .{ 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF } };

/// Check if a MAC address is broadcast.
pub fn isBroadcast(mac: pmd.MacAddr) bool {
    return std.mem.eql(u8, &mac.bytes, &BROADCAST_MAC.bytes);
}

/// Check if a MAC address is multicast (bit 0 of first byte set).
pub fn isMulticast(mac: pmd.MacAddr) bool {
    return (mac.bytes[0] & 1) != 0;
}

// ── Tests ────────────────────────────────────────────────────────────────

const testing = std.testing;

test "ethernet: header size is 14 bytes" {
    try testing.expectEqual(@as(usize, 14), @sizeOf(EthernetHeader));
}

test "ethernet: VLAN header size is 4 bytes" {
    try testing.expectEqual(@as(usize, 4), @sizeOf(VlanHeader));
}

test "ethernet: parse valid frame" {
    // Construct a minimal Ethernet frame with IPv4 EtherType
    var frame: [64]u8 align(8) = std.mem.zeroes([64]u8);
    // dst MAC
    frame[0] = 0xFF;
    frame[1] = 0xFF;
    frame[2] = 0xFF;
    frame[3] = 0xFF;
    frame[4] = 0xFF;
    frame[5] = 0xFF;
    // src MAC
    frame[6] = 0x00;
    frame[7] = 0x11;
    frame[8] = 0x22;
    frame[9] = 0x33;
    frame[10] = 0x44;
    frame[11] = 0x55;
    // EtherType: IPv4 (0x0800) in network order
    frame[12] = 0x08;
    frame[13] = 0x00;

    const result = parseFrame(&frame).?;
    try testing.expectEqual(@as(u16, 14), result.header_len);
    try testing.expectEqual(EtherType.ipv4, result.ether_type);
    try testing.expectEqual(@as(usize, 50), result.payload.len);
}

test "ethernet: parse too-short packet" {
    var frame: [10]u8 = undefined;
    try testing.expect(parseFrame(&frame) == null);
}

test "ethernet: write header" {
    var buf: [64]u8 align(8) = std.mem.zeroes([64]u8);
    const src = pmd.MacAddr{ .bytes = .{ 0x00, 0x11, 0x22, 0x33, 0x44, 0x55 } };
    const dst = BROADCAST_MAC;
    const hdr = writeHeader(&buf, dst, src, .arp).?;
    try testing.expectEqual(EtherType.arp, hdr.etherType());
    try testing.expect(isBroadcast(hdr.dst));
}

test "ethernet: EtherType byte order" {
    try testing.expectEqual(@as(u16, 0x0008), EtherType.ipv4.toNetBytes()); // 0x0800 swapped
    try testing.expectEqual(EtherType.ipv4, EtherType.fromNetBytes(0x0008));
}

test "ethernet: multicast detection" {
    const unicast = pmd.MacAddr{ .bytes = .{ 0x00, 0x11, 0x22, 0x33, 0x44, 0x55 } };
    const multicast = pmd.MacAddr{ .bytes = .{ 0x01, 0x00, 0x5E, 0x00, 0x00, 0x01 } };
    try testing.expect(!isMulticast(unicast));
    try testing.expect(isMulticast(multicast));
    try testing.expect(isMulticast(BROADCAST_MAC));
}
