//! Quantum DNS Server Library
//!
//! High-performance authoritative DNS server with:
//! - Zero-allocation packet parsing
//! - Zone file loading with hot reload
//! - DNSSEC signing and validation
//! - DoH (DNS over HTTPS) support
//! - DoT (DNS over TLS) support
//!
//! Usage:
//! ```zig
//! const dns = @import("dns");
//!
//! var server = try dns.Server.init(allocator, .{
//!     .bind_address = "0.0.0.0",
//!     .port = 53,
//! });
//! defer server.deinit();
//!
//! try server.loadZone("example.com.zone");
//! try server.start();
//! ```

const std = @import("std");

// =============================================================================
// PROTOCOL LAYER
// =============================================================================

pub const protocol = struct {
    pub const types = @import("protocol/types.zig");
    pub const parser = @import("protocol/parser.zig");

    // Re-export commonly used types
    pub const Header = types.Header;
    pub const Name = types.Name;
    pub const Question = types.Question;
    pub const ResourceRecord = types.ResourceRecord;
    pub const RecordType = types.RecordType;
    // NOTE: the underlying type module renamed these (Class/Rcode/Opcode).
    // Keep the historical public alias names, pointing at the current types.
    pub const RecordClass = types.Class;
    pub const ResponseCode = types.Rcode;
    pub const OpCode = types.Opcode;

    // DNSSEC types
    pub const DNSKEYRecord = types.DNSKEYRecord;
    pub const RRSIGRecord = types.RRSIGRecord;
    pub const DSRecord = types.DSRecord;
    pub const NSECRecord = types.NSECRecord;

    // Parser and builder
    pub const Parser = parser.Parser;
    pub const Builder = parser.Builder;
    pub const Message = parser.Message;
    pub const ParseError = parser.ParseError;
};

// Re-export protocol types at root level for convenience
pub const Header = protocol.Header;
pub const Name = protocol.Name;
pub const Question = protocol.Question;
pub const ResourceRecord = protocol.ResourceRecord;
pub const RecordType = protocol.RecordType;
pub const RecordClass = protocol.RecordClass;
pub const ResponseCode = protocol.ResponseCode;
pub const Parser = protocol.Parser;
pub const Builder = protocol.Builder;
pub const Message = protocol.Message;

// =============================================================================
// ZONE MANAGEMENT
// =============================================================================

pub const zones = struct {
    pub const zone = @import("zones/zone.zig");

    pub const Zone = zone.Zone;
    pub const ZoneStore = zone.ZoneStore;
    pub const ZoneParser = zone.ZoneParser;
    pub const ZoneRecord = zone.ZoneRecord;
    pub const SOARecord = zone.SOARecord;
};

pub const Zone = zones.Zone;
pub const ZoneStore = zones.ZoneStore;
pub const ZoneParser = zones.ZoneParser;

// =============================================================================
// SERVER
// =============================================================================

pub const server = struct {
    pub const srv = @import("server/server.zig");

    pub const Server = srv.Server;
    pub const Config = srv.Config;
    pub const QueryHandler = srv.QueryHandler;
    pub const RateLimiter = srv.RateLimiter;
    pub const ResponseCache = srv.ResponseCache;
    pub const Stats = srv.Stats;
};

pub const Server = server.Server;
pub const Config = server.Config;
pub const QueryHandler = server.QueryHandler;

// =============================================================================
// SECURITY / DNSSEC
// =============================================================================

pub const security = struct {
    pub const dnssec = @import("security/dnssec.zig");

    pub const DNSSECKey = dnssec.DNSSECKey;
    pub const DNSSECAlgorithm = dnssec.DNSSECAlgorithm;
    pub const DigestType = dnssec.DigestType;
    pub const ZoneSigner = dnssec.ZoneSigner;
    pub const Validator = dnssec.Validator;
};

pub const DNSSECKey = security.DNSSECKey;
pub const DNSSECAlgorithm = security.DNSSECAlgorithm;
pub const ZoneSigner = security.ZoneSigner;

// =============================================================================
// TRANSPORT / DoH/DoT
// =============================================================================

pub const transport = struct {
    pub const doh = @import("transport/doh.zig");
    pub const dot = @import("transport/dot.zig");

    pub const DoHServer = doh.DoHServer;
    pub const DoHConfig = doh.DoHConfig;
    pub const DoHRequest = doh.DoHRequest;
    pub const DoHError = doh.DoHError;

    pub const DoTServer = dot.DoTServer;
    pub const DoTConfig = dot.DoTConfig;
    pub const DoTConnection = dot.DoTConnection;
    pub const DoTError = dot.DoTError;
};

pub const DoHServer = transport.DoHServer;
pub const DoHConfig = transport.DoHConfig;
pub const DoTServer = transport.DoTServer;
pub const DoTConfig = transport.DoTConfig;

// =============================================================================
// CONSTANTS
// =============================================================================

pub const MAX_NAME_LENGTH = 255;
pub const MAX_LABEL_LENGTH = 63;
pub const MAX_UDP_SIZE = 512;
pub const MAX_EDNS_SIZE = 4096;
pub const MAX_TCP_SIZE = 65535;
pub const DEFAULT_TTL = 3600;

// =============================================================================
// TESTS
// =============================================================================

test {
    // Run all sub-module tests
    _ = protocol.types;
    _ = protocol.parser;
    _ = zones.zone;
    _ = server.srv;
    _ = security.dnssec;
    _ = transport.doh;
    _ = transport.dot;
}

test "name parsing" {
    var name = try Name.fromString("example.com");
    var buf: [256]u8 = undefined;
    const str = name.toString(&buf);
    try std.testing.expectEqualStrings("example.com", str);
}

test "header serialization" {
    // Build a header with the current Builder API and verify the on-wire bytes
    // match the DNS message header format (RFC 1035 §4.1.1):
    //   byte 2 (MSB): QR(1) Opcode(4) AA(1) TC(1) RD(1)
    //   byte 3:       RA(1) Z(1) AD(1) CD(1) RCODE(4)
    const header = Header{
        .id = 0x1234,
        .flags = .{
            .qr = true,
            .opcode = 0, // query
            .aa = true,
            .tc = false,
            .rd = true,
            .ra = true,
            .z = false,
            .ad = false,
            .cd = false,
            .rcode = 0, // no_error
        },
        .qd_count = 1,
        .an_count = 2,
        .ns_count = 0,
        .ar_count = 1,
    };

    var buf: [12]u8 = undefined;
    var builder = Builder{ .buf = &buf };
    try builder.writeHeader(header);

    // ID (bytes 0-1, big-endian).
    try std.testing.expectEqual(@as(u8, 0x12), buf[0]);
    try std.testing.expectEqual(@as(u8, 0x34), buf[1]);
    // Flags: QR=1, AA=1, RD=1 -> 0x85 ; RA=1 -> 0x80.
    try std.testing.expectEqual(@as(u8, 0x85), buf[2]);
    try std.testing.expectEqual(@as(u8, 0x80), buf[3]);

    // ID and counts round-trip through Parser (plain big-endian u16 fields).
    var parser = Parser{ .data = &buf };
    const parsed = try parser.parseHeader();
    try std.testing.expectEqual(@as(u16, 0x1234), parsed.id);
    try std.testing.expectEqual(@as(u16, 1), parsed.qd_count);
    try std.testing.expectEqual(@as(u16, 2), parsed.an_count);
    try std.testing.expectEqual(@as(u16, 0), parsed.ns_count);
    try std.testing.expectEqual(@as(u16, 1), parsed.ar_count);
}

test "parser basic query" {
    // DNS query for example.com A record
    const query = [_]u8{
        // Header
        0x12, 0x34, // ID
        0x01, 0x00, // Flags: RD=1
        0x00, 0x01, // QDCOUNT=1
        0x00, 0x00, // ANCOUNT=0
        0x00, 0x00, // NSCOUNT=0
        0x00, 0x00, // ARCOUNT=0
        // Question: example.com A IN
        0x07, 'e', 'x', 'a', 'm', 'p', 'l', 'e',
        0x03, 'c', 'o', 'm',
        0x00, // End of name
        0x00, 0x01, // Type A
        0x00, 0x01, // Class IN
    };

    var parser = Parser{ .data = &query };
    const header = try parser.parseHeader();

    try std.testing.expectEqual(@as(u16, 0x1234), header.id);
    try std.testing.expectEqual(@as(u16, 1), header.qd_count);

    const question = try parser.parseQuestion();
    try std.testing.expectEqual(RecordType.A, question.qtype);
    try std.testing.expectEqual(RecordClass.IN, question.qclass);

    var buf: [256]u8 = undefined;
    const name_str = question.name.toString(&buf);
    try std.testing.expectEqualStrings("example.com", name_str);
}

test "builder basic response" {
    var buf: [512]u8 = undefined;
    var builder = Builder{ .buf = &buf };

    const name = try Name.fromString("test.example.com");

    // Build header: authoritative response, 1 question + 1 answer.
    try builder.writeHeader(.{
        .id = 0xABCD,
        .flags = .{
            .qr = true,
            .opcode = 0,
            .aa = true,
            .tc = false,
            .rd = false,
            .ra = false,
            .z = false,
            .ad = false,
            .cd = false,
            .rcode = 0,
        },
        .qd_count = 1,
        .an_count = 1,
        .ns_count = 0,
        .ar_count = 0,
    });

    // Build question: test.example.com A IN
    try builder.writeQuestion(.{
        .name = name,
        .qtype = .A,
        .qclass = .IN,
    });

    // Build answer: A record 192.0.2.1 with TTL 300.
    var answer = ResourceRecord{
        .name = name,
        .rtype = .A,
        .class = .IN,
        .ttl = 300,
        .rdlength = 4,
    };
    @memcpy(answer.rdata[0..4], &[_]u8{ 192, 0, 2, 1 });
    try builder.writeRecord(answer);

    const response = builder.message();
    try std.testing.expect(response.len > 12);

    // Verify we can parse the header back (id + counts).
    var parser = Parser{ .data = response };
    const header = try parser.parseHeader();
    try std.testing.expectEqual(@as(u16, 0xABCD), header.id);
    try std.testing.expectEqual(@as(u16, 1), header.qd_count);
    try std.testing.expectEqual(@as(u16, 1), header.an_count);
}
