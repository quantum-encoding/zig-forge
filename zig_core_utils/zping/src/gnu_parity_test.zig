//! Externally-anchored tests for zping.
//!
//! No GNU/iputils `ping` binary is installed on this host (only BSD `/sbin/ping`,
//! which uses different output wording), so parity is anchored to *documented*
//! iputils behaviour and to published spec vectors, with the expected bytes
//! written literally below. Each anchor cites its source. There are NO
//! roundtrip-only tests (per zig-forge/CLAUDE.md golden rule §1).
//!
//! Sources used:
//!   - RFC 1071 §3 "Numerical Examples" — Internet checksum known-answer vector.
//!   - RFC 792 — ICMP Echo checksum verification property (sum incl. checksum = 0).
//!   - iputils ping.c — the "PING host (ip) N(M) bytes of data." header format
//!     and the `-s` max-payload cap (65507 = 65535 - 20 IP - 8 ICMP).
//!   - iputils ping man page — `-i` interval is expressed in (fractional) seconds.

const std = @import("std");
const testing = std.testing;
const zping = @import("main.zig");

// ============================================================================
// icmpChecksum — anchored to RFC 1071 §3 "Numerical Examples"
// ============================================================================
//
// RFC 1071 §3 works the checksum for the four 16-bit words
//   00 01  f2 03  f4 f5  f6 f7
// and gives the resulting checksum as 0x220D (on-wire, network byte order).
//
// zping sums in little-endian word order, so it returns the byte-swapped u16
// 0x0D22; when that u16 is written to memory (native little-endian) the bytes on
// the wire are {0x22, 0x0D} — exactly RFC 1071's 0x220D. We assert the on-wire
// bytes, which is what an external receiver actually validates.
test "icmpChecksum matches RFC 1071 section 3 worked example (0x220D on the wire)" {
    const data = [_]u8{ 0x00, 0x01, 0xf2, 0x03, 0xf4, 0xf5, 0xf6, 0xf7 };
    const sum = zping.icmpChecksum(&data);

    // Native-endian memory representation == on-wire bytes.
    const wire = std.mem.toBytes(sum);
    try testing.expectEqual(@as(u8, 0x22), wire[0]);
    try testing.expectEqual(@as(u8, 0x0D), wire[1]);
}

// RFC 792 / RFC 1071: a receiver that sums every 16-bit word of the datagram
// *including* the checksum field gets a one's-complement result of zero. This is
// the spec's own verification rule, applied to an arbitrary ICMP echo packet.
test "icmpChecksum: RFC 792 receiver verification property (sum incl. checksum = 0)" {
    // A plausible echo-request: type=8, code=0, checksum=0, id, seq, + payload.
    var packet = [_]u8{
        0x08, 0x00, 0x00, 0x00, // type, code, checksum(placeholder)
        0x12, 0x34, 0x00, 0x2a, // id=0x1234, seq=42
        0xde, 0xad, 0xbe, 0xef, // payload
    };
    const csum = zping.icmpChecksum(&packet);
    // Insert the checksum into the field (native/little-endian, as zping does).
    std.mem.writeInt(u16, packet[2..4], csum, .little);

    // Receiver re-checksums the whole packet -> must be 0.
    try testing.expectEqual(@as(u16, 0), zping.icmpChecksum(&packet));
}

// ============================================================================
// -s payload size — anchored to iputils' documented 65507 cap
// ============================================================================
//
// iputils ping: `ping -s 65508` errors "packet size 65508 is too large.
// Maximum is 65507". 65507 must be accepted; 65508 must be rejected (not panic,
// which is the OOB finding this fixes).
test "parsePayloadSize: iputils max payload is exactly 65507" {
    try testing.expectEqual(@as(u16, 65507), try zping.parsePayloadSize("65507"));
    try testing.expectError(error.OutOfRange, zping.parsePayloadSize("65508"));
    // u16 max still exceeds the cap -> rejected, never overflows.
    try testing.expectError(error.OutOfRange, zping.parsePayloadSize("65535"));
    // Default and small sizes accepted.
    try testing.expectEqual(@as(u16, 56), try zping.parsePayloadSize("56"));
    try testing.expectEqual(@as(u16, 0), try zping.parsePayloadSize("0"));
    // Non-numeric rejected.
    try testing.expectError(error.Invalid, zping.parsePayloadSize("abc"));
}

// headerTotalBytes must not overflow near the 65507 cap. The old code did
// `payload + 28` in u16, which overflows for payload >= 65508. 65507 + 28 =
// 65535 fits u16, but the widened u32 arithmetic is verified here for the cap.
test "headerTotalBytes: no overflow at the 65507 cap" {
    try testing.expectEqual(@as(u32, 84), zping.headerTotalBytes(56));
    try testing.expectEqual(@as(u32, 65535), zping.headerTotalBytes(65507));
    // Well past where the old u16 add wrapped: still correct.
    try testing.expectEqual(@as(u32, 65563), zping.headerTotalBytes(65535));
}

// ============================================================================
// PING header line — anchored to iputils ping.c output format
// ============================================================================
//
// iputils prints, for the default 56-byte payload:
//   "PING 8.8.8.8 (8.8.8.8) 56(84) bytes of data."
// where 84 = 56 payload + 8 ICMP + 20 IP.
test "formatHeaderLine matches iputils 'PING host (ip) N(M) bytes of data.' format" {
    var buf: [256]u8 = undefined;
    const line = try zping.formatHeaderLine(&buf, "8.8.8.8", "8.8.8.8", 56);
    try testing.expectEqualStrings("PING 8.8.8.8 (8.8.8.8) 56(84) bytes of data.\n", line);

    // Named host with distinct resolved IP, a non-default size.
    const line2 = try zping.formatHeaderLine(&buf, "example.com", "93.184.216.34", 100);
    try testing.expectEqualStrings("PING example.com (93.184.216.34) 100(128) bytes of data.\n", line2);
}

// ============================================================================
// -i / -W seconds->ms — anchored to iputils (seconds, fractional) + the
// @intFromFloat panic hardening from the audit.
// ============================================================================
//
// iputils `-i` takes an interval in seconds and accepts fractional values
// (e.g. `-i 0.2`). These assert the documented conversion AND that the audit's
// crash inputs (`-i -1`, `-i nan`, `-i 1e12`) are rejected as errors, not
// @intFromFloat panics.
test "parseSecondsToMs: documented seconds->ms conversion" {
    try testing.expectEqual(@as(u32, 1000), try zping.parseSecondsToMs("1"));
    try testing.expectEqual(@as(u32, 500), try zping.parseSecondsToMs("0.5"));
    try testing.expectEqual(@as(u32, 200), try zping.parseSecondsToMs("0.2"));
    try testing.expectEqual(@as(u32, 0), try zping.parseSecondsToMs("0"));
    try testing.expectEqual(@as(u32, 5000), try zping.parseSecondsToMs("5"));
}

test "parseSecondsToMs: audit crash inputs are rejected, not panicked" {
    // -i -1 : negative -> panicked @intFromFloat before the fix.
    try testing.expectError(error.OutOfRange, zping.parseSecondsToMs("-1"));
    // -i 1e12 : out of u32 ms range -> panicked before the fix.
    try testing.expectError(error.OutOfRange, zping.parseSecondsToMs("1e12"));
    // -i nan : slipped through @intFromFloat as garbage before the fix.
    try testing.expectError(error.Invalid, zping.parseSecondsToMs("nan"));
    // +inf is out of the accepted range (NaN is the only "Invalid" float here).
    try testing.expectError(error.OutOfRange, zping.parseSecondsToMs("inf"));
    try testing.expectError(error.OutOfRange, zping.parseSecondsToMs("-inf"));
    // Non-numeric.
    try testing.expectError(error.Invalid, zping.parseSecondsToMs("abc"));
}

test "parseSecondsToMs: boundary just inside the accepted range" {
    // 4_000_000 s = 4e9 ms, the documented cap: accepted, no overflow/panic.
    try testing.expectEqual(@as(u32, 4_000_000_000), try zping.parseSecondsToMs("4000000"));
    // Just over the cap -> rejected.
    try testing.expectError(error.OutOfRange, zping.parseSecondsToMs("4000001"));
}
