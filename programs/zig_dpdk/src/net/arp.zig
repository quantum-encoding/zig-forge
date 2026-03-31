/// ARP (Address Resolution Protocol) for IPv4 over Ethernet.
/// Wire-format extern struct for zero-copy parsing and construction.
///
/// An ARP responder is essential for any network stack — without it,
/// no host on the LAN can resolve our MAC address and send us packets.

const std = @import("std");
const pmd = @import("../drivers/pmd.zig");
const ethernet = @import("ethernet.zig");

/// ARP opcodes.
pub const Opcode = enum(u16) {
    request = 1,
    reply = 2,
    _,
};

/// ARP header for IPv4-over-Ethernet (28 bytes).
/// IP addresses stored as [4]u8 to avoid C alignment padding after 6-byte MACs.
pub const ArpHeader = extern struct {
    hw_type: u16, // network order (1 = Ethernet)
    proto_type: u16, // network order (0x0800 = IPv4)
    hw_len: u8, // 6 for Ethernet
    proto_len: u8, // 4 for IPv4
    opcode: u16, // network order
    sender_mac: pmd.MacAddr, // 6 bytes
    sender_ip: [4]u8, // network order, [4]u8 avoids alignment padding
    target_mac: pmd.MacAddr, // 6 bytes
    target_ip: [4]u8, // network order

    pub fn op(self: *const ArpHeader) Opcode {
        return @enumFromInt(std.mem.bigToNative(u16, self.opcode));
    }

    pub fn senderIpAddr(self: *const ArpHeader) u32 {
        return std.mem.readInt(u32, &self.sender_ip, .big);
    }

    pub fn targetIpAddr(self: *const ArpHeader) u32 {
        return std.mem.readInt(u32, &self.target_ip, .big);
    }

    fn ipToBytes(ip: u32) [4]u8 {
        var b: [4]u8 = undefined;
        std.mem.writeInt(u32, &b, ip, .big);
        return b;
    }

    /// Check if this is a valid IPv4-over-Ethernet ARP packet.
    pub fn isValid(self: *const ArpHeader) bool {
        return std.mem.bigToNative(u16, self.hw_type) == 1 and
            std.mem.bigToNative(u16, self.proto_type) == 0x0800 and
            self.hw_len == 6 and
            self.proto_len == 4;
    }

    /// Initialize an ARP request.
    pub fn initRequest(self: *ArpHeader, sender_mac_addr: pmd.MacAddr, sender_ip_addr: u32, target_ip_addr: u32) void {
        self.hw_type = std.mem.nativeToBig(u16, 1);
        self.proto_type = std.mem.nativeToBig(u16, 0x0800);
        self.hw_len = 6;
        self.proto_len = 4;
        self.opcode = std.mem.nativeToBig(u16, @intFromEnum(Opcode.request));
        self.sender_mac = sender_mac_addr;
        self.sender_ip = ipToBytes(sender_ip_addr);
        self.target_mac = .{}; // zero — unknown
        self.target_ip = ipToBytes(target_ip_addr);
    }

    /// Initialize an ARP reply from a request.
    pub fn initReply(self: *ArpHeader, our_mac: pmd.MacAddr, request: *const ArpHeader) void {
        self.hw_type = request.hw_type;
        self.proto_type = request.proto_type;
        self.hw_len = request.hw_len;
        self.proto_len = request.proto_len;
        self.opcode = std.mem.nativeToBig(u16, @intFromEnum(Opcode.reply));
        self.sender_mac = our_mac;
        self.sender_ip = request.target_ip;
        self.target_mac = request.sender_mac;
        self.target_ip = request.sender_ip;
    }

    comptime {
        if (@sizeOf(ArpHeader) != 28)
            @compileError("ArpHeader must be exactly 28 bytes");
    }
};

/// Parse an ARP header from raw data (after Ethernet header). Zero-copy.
pub fn parse(data: []u8) ?*ArpHeader {
    if (data.len < @sizeOf(ArpHeader)) return null;
    const hdr: *ArpHeader = @ptrCast(@alignCast(data.ptr));
    if (!hdr.isValid()) return null;
    return hdr;
}

/// Build a complete ARP request frame in a buffer.
/// Returns total frame size (Ethernet header + ARP = 42 bytes).
pub fn buildRequest(buf: []u8, sender_mac: pmd.MacAddr, sender_ip: u32, target_ip: u32) ?u16 {
    const frame_size = @sizeOf(ethernet.EthernetHeader) + @sizeOf(ArpHeader);
    if (buf.len < frame_size) return null;

    _ = ethernet.writeHeader(buf, ethernet.BROADCAST_MAC, sender_mac, .arp);

    const arp: *ArpHeader = @ptrCast(@alignCast(buf.ptr + @sizeOf(ethernet.EthernetHeader)));
    arp.initRequest(sender_mac, sender_ip, target_ip);

    return frame_size;
}

/// Build a complete ARP reply frame in a buffer, responding to a request.
/// Returns total frame size (42 bytes).
pub fn buildReply(buf: []u8, our_mac: pmd.MacAddr, request: *const ArpHeader) ?u16 {
    const frame_size = @sizeOf(ethernet.EthernetHeader) + @sizeOf(ArpHeader);
    if (buf.len < frame_size) return null;

    _ = ethernet.writeHeader(buf, request.sender_mac, our_mac, .arp);

    const arp: *ArpHeader = @ptrCast(@alignCast(buf.ptr + @sizeOf(ethernet.EthernetHeader)));
    arp.initReply(our_mac, request);

    return frame_size;
}

// ── Tests ────────────────────────────────────────────────────────────────

const testing = std.testing;

test "arp: header size is 28 bytes" {
    try testing.expectEqual(@as(usize, 28), @sizeOf(ArpHeader));
}

test "arp: build and parse request" {
    var buf: [64]u8 align(8) = std.mem.zeroes([64]u8);
    const mac = pmd.MacAddr{ .bytes = .{ 0x00, 0x11, 0x22, 0x33, 0x44, 0x55 } };
    const frame_size = buildRequest(&buf, mac, 0xC0A80101, 0xC0A80102).?;
    try testing.expectEqual(@as(u16, 42), frame_size);

    // Parse the Ethernet header
    const eth_result = ethernet.parseFrame(&buf).?;
    try testing.expectEqual(ethernet.EtherType.arp, eth_result.ether_type);

    // Parse the ARP header
    const arp_hdr = parse(eth_result.payload).?;
    try testing.expectEqual(Opcode.request, arp_hdr.op());
    try testing.expectEqual(@as(u32, 0xC0A80101), arp_hdr.senderIpAddr());
    try testing.expectEqual(@as(u32, 0xC0A80102), arp_hdr.targetIpAddr());
}

test "arp: build reply from request" {
    var req_buf: [64]u8 align(8) = std.mem.zeroes([64]u8);
    const requester_mac = pmd.MacAddr{ .bytes = .{ 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF } };
    _ = buildRequest(&req_buf, requester_mac, 0x0A000001, 0x0A000002);
    const eth_result = ethernet.parseFrame(&req_buf).?;
    const request = parse(eth_result.payload).?;

    // Build reply
    var reply_buf: [64]u8 align(8) = std.mem.zeroes([64]u8);
    const our_mac = pmd.MacAddr{ .bytes = .{ 0x00, 0x11, 0x22, 0x33, 0x44, 0x55 } };
    const reply_size = buildReply(&reply_buf, our_mac, request).?;
    try testing.expectEqual(@as(u16, 42), reply_size);

    const reply_eth = ethernet.parseFrame(&reply_buf).?;
    const reply_arp = parse(reply_eth.payload).?;
    try testing.expectEqual(Opcode.reply, reply_arp.op());
    try testing.expectEqual(@as(u32, 0x0A000002), reply_arp.senderIpAddr());
    try testing.expectEqual(@as(u32, 0x0A000001), reply_arp.targetIpAddr());
}

test "arp: parse invalid" {
    var buf: [28]u8 align(8) = std.mem.zeroes([28]u8);
    buf[0] = 0x00;
    buf[1] = 0x02; // hw_type = 2, not Ethernet
    try testing.expect(parse(&buf) == null);
}
