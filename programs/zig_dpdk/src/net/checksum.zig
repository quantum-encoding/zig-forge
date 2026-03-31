/// IP/TCP/UDP checksum computation.
///
/// The Internet checksum is the one's complement of the one's complement sum
/// of all 16-bit words. Used by IPv4, TCP, UDP, and ICMP.
///
/// For NIC offload: most 10GbE+ NICs compute checksums in hardware.
/// This module is used for software fallback and verification.

const std = @import("std");

/// Compute the Internet checksum over a byte slice.
/// Returns the 16-bit checksum in host byte order.
pub fn internetChecksum(data: []const u8) u16 {
    return finish(sum(data, 0));
}

/// Accumulate checksum over a byte slice, starting from a partial sum.
/// This allows computing checksums over non-contiguous data (e.g., pseudo-header + payload).
pub fn sum(data: []const u8, initial: u32) u32 {
    var s: u32 = initial;
    var i: usize = 0;

    // Process 16-bit words
    while (i + 1 < data.len) : (i += 2) {
        s += @as(u32, data[i]) << 8 | @as(u32, data[i + 1]);
    }

    // Handle odd byte
    if (i < data.len) {
        s += @as(u32, data[i]) << 8;
    }

    return s;
}

/// Fold a 32-bit accumulated sum into a 16-bit one's complement checksum.
pub fn finish(s: u32) u16 {
    var folded = s;
    while (folded > 0xFFFF) {
        folded = (folded & 0xFFFF) + (folded >> 16);
    }
    return @intCast(~folded & 0xFFFF);
}

/// Verify a checksum: the checksum of data including the checksum field should be 0.
pub fn verify(data: []const u8) bool {
    return internetChecksum(data) == 0;
}

/// Compute IPv4 header checksum. The header checksum field must be zero before calling.
pub fn ipv4HeaderChecksum(header: []const u8) u16 {
    return internetChecksum(header);
}

/// Compute TCP/UDP pseudo-header checksum contribution.
/// Fields: src_ip, dst_ip, zero, protocol, tcp/udp_length (all in network byte order).
pub fn pseudoHeaderSum(src_ip: u32, dst_ip: u32, protocol: u8, transport_len: u16) u32 {
    var s: u32 = 0;
    // Source IP (2 x 16-bit words)
    s += src_ip >> 16;
    s += src_ip & 0xFFFF;
    // Dest IP
    s += dst_ip >> 16;
    s += dst_ip & 0xFFFF;
    // Zero + Protocol
    s += @as(u32, protocol);
    // Transport length
    s += transport_len;
    return s;
}

/// Compute TCP or UDP checksum over pseudo-header + transport segment.
pub fn transportChecksum(src_ip: u32, dst_ip: u32, protocol: u8, transport_data: []const u8) u16 {
    const psum = pseudoHeaderSum(src_ip, dst_ip, protocol, @intCast(transport_data.len));
    return finish(sum(transport_data, psum));
}

// ── Tests ────────────────────────────────────────────────────────────────

const testing = std.testing;

test "checksum: RFC 1071 example" {
    // Example from RFC 1071: 0x0001 + 0x00F2 + ... = checksum
    const data = [_]u8{ 0x00, 0x01, 0xF2, 0x03, 0xF4, 0xF5, 0xF6, 0xF7 };
    const cksum = internetChecksum(&data);
    // Verify: sum of data + checksum should fold to 0xFFFF
    var s = sum(&data, 0);
    s += cksum;
    while (s > 0xFFFF) {
        s = (s & 0xFFFF) + (s >> 16);
    }
    try testing.expectEqual(@as(u32, 0xFFFF), s);
}

test "checksum: zero data" {
    const data = [_]u8{ 0, 0, 0, 0 };
    try testing.expectEqual(@as(u16, 0xFFFF), internetChecksum(&data));
}

test "checksum: all ones" {
    const data = [_]u8{ 0xFF, 0xFF, 0xFF, 0xFF };
    try testing.expectEqual(@as(u16, 0), internetChecksum(&data));
}

test "checksum: odd length" {
    const data = [_]u8{ 0x00, 0x01, 0xF2 };
    // Should handle trailing byte correctly
    const cksum = internetChecksum(&data);
    try testing.expect(cksum != 0);
}

test "checksum: verify valid" {
    // Create data, compute checksum, insert it, verify
    var pkt = [_]u8{ 0x45, 0x00, 0x00, 0x3c, 0x1c, 0x46, 0x40, 0x00, 0x40, 0x06, 0x00, 0x00, 0xac, 0x10, 0x0a, 0x63, 0xac, 0x10, 0x0a, 0x0c };
    // Compute checksum with field zeroed
    const cksum = ipv4HeaderChecksum(&pkt);
    pkt[10] = @intCast(cksum >> 8);
    pkt[11] = @intCast(cksum & 0xFF);
    // Now verify
    try testing.expect(verify(&pkt));
}

test "checksum: incremental sum" {
    const part1 = [_]u8{ 0x00, 0x01, 0xF2, 0x03 };
    const part2 = [_]u8{ 0xF4, 0xF5, 0xF6, 0xF7 };
    const full = [_]u8{ 0x00, 0x01, 0xF2, 0x03, 0xF4, 0xF5, 0xF6, 0xF7 };

    const cksum_full = internetChecksum(&full);
    const cksum_incremental = finish(sum(&part2, sum(&part1, 0)));
    try testing.expectEqual(cksum_full, cksum_incremental);
}
