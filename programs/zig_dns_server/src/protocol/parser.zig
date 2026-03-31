//! ═══════════════════════════════════════════════════════════════════════════
//! Zero-Allocation DNS Packet Parser
//! ═══════════════════════════════════════════════════════════════════════════
//!
//! High-performance DNS packet parsing without heap allocations.
//! Uses fixed-size buffers and operates directly on wire format.
//!
//! Features:
//! • Zero heap allocations during parsing
//! • Name compression support (RFC 1035 section 4.1.4)
//! • Bounds checking for security
//! • Support for all standard record types
//!

const std = @import("std");
const types = @import("types.zig");

const Header = types.Header;
const Name = types.Name;
const Question = types.Question;
const ResourceRecord = types.ResourceRecord;
const RecordType = types.RecordType;
const Class = types.Class;

/// Maximum DNS message size
pub const MAX_MESSAGE_SIZE = 65535;
/// Maximum UDP message size (without EDNS)
pub const MAX_UDP_SIZE = 512;
/// Maximum compressed name pointer depth
const MAX_COMPRESSION_DEPTH = 16;

/// Parse errors
pub const ParseError = error{
    MessageTooShort,
    InvalidHeader,
    InvalidName,
    InvalidQuestion,
    InvalidRecord,
    CompressionLoop,
    NameTooLong,
    BufferTooSmall,
    InvalidRdata,
};

/// DNS Message Parser - zero allocation
pub const Parser = struct {
    data: []const u8,
    pos: usize = 0,

    pub fn init(data: []const u8) Parser {
        return .{ .data = data };
    }

    /// Parse the DNS header
    pub fn parseHeader(self: *Parser) ParseError!Header {
        if (self.data.len < 12) return error.MessageTooShort;

        const header = Header{
            .id = self.readU16BE(),
            .flags = @bitCast(self.readU16BE()),
            .qd_count = self.readU16BE(),
            .an_count = self.readU16BE(),
            .ns_count = self.readU16BE(),
            .ar_count = self.readU16BE(),
        };

        return header;
    }

    /// Parse a DNS question
    pub fn parseQuestion(self: *Parser) ParseError!Question {
        const name = try self.parseName();
        if (self.pos + 4 > self.data.len) return error.InvalidQuestion;

        return Question{
            .name = name,
            .qtype = @enumFromInt(self.readU16BE()),
            .qclass = @enumFromInt(self.readU16BE()),
        };
    }

    /// Parse a resource record
    pub fn parseRecord(self: *Parser) ParseError!ResourceRecord {
        const name = try self.parseName();
        if (self.pos + 10 > self.data.len) return error.InvalidRecord;

        const rtype: RecordType = @enumFromInt(self.readU16BE());
        const class: Class = @enumFromInt(self.readU16BE());
        const ttl = self.readU32BE();
        const rdlength = self.readU16BE();

        if (self.pos + rdlength > self.data.len) return error.InvalidRecord;

        var rr = ResourceRecord{
            .name = name,
            .rtype = rtype,
            .class = class,
            .ttl = ttl,
            .rdlength = rdlength,
        };

        // Copy RDATA, handling name compression if needed
        if (rdlength > types.RDATA_BUFFER_SIZE) return error.BufferTooSmall;

        switch (rtype) {
            .NS, .CNAME, .PTR, .DNAME => {
                // These contain compressed names - decompress
                const start_pos = self.pos;
                const decompressed = try self.parseName();
                rr.rdlength = decompressed.len;
                @memcpy(rr.rdata[0..decompressed.len], decompressed.wireFormat());
                // Advance past the compressed name in the wire format
                self.pos = start_pos + rdlength;
            },
            .MX => {
                // Preference + compressed name
                if (rdlength < 3) return error.InvalidRdata;
                rr.rdata[0] = self.data[self.pos];
                rr.rdata[1] = self.data[self.pos + 1];
                self.pos += 2;

                const start_pos = self.pos;
                const exchange = try self.parseName();
                const total_len = 2 + exchange.len;
                if (total_len > types.RDATA_BUFFER_SIZE) return error.BufferTooSmall;
                @memcpy(rr.rdata[2..][0..exchange.len], exchange.wireFormat());
                rr.rdlength = @intCast(total_len);
                self.pos = start_pos + (rdlength - 2);
            },
            .SOA => {
                // MNAME + RNAME + 5x u32
                const start_pos = self.pos;
                var rdata_pos: usize = 0;

                const mname = try self.parseName();
                @memcpy(rr.rdata[rdata_pos..][0..mname.len], mname.wireFormat());
                rdata_pos += mname.len;

                const rname = try self.parseName();
                @memcpy(rr.rdata[rdata_pos..][0..rname.len], rname.wireFormat());
                rdata_pos += rname.len;

                // Copy the 5 u32 values (serial, refresh, retry, expire, minimum)
                const soa_remaining = start_pos + rdlength - self.pos;
                if (soa_remaining != 20) return error.InvalidRdata;
                @memcpy(rr.rdata[rdata_pos..][0..20], self.data[self.pos..][0..20]);
                rdata_pos += 20;
                rr.rdlength = @intCast(rdata_pos);
                self.pos = start_pos + rdlength;
            },
            else => {
                // Raw copy for other types
                @memcpy(rr.rdata[0..rdlength], self.data[self.pos..][0..rdlength]);
                self.pos += rdlength;
            },
        }

        return rr;
    }

    /// Parse a DNS name with compression support
    pub fn parseName(self: *Parser) ParseError!Name {
        var name = Name{};
        var name_pos: usize = 0;
        var depth: u8 = 0;
        var jumped = false;
        var saved_pos: usize = 0;

        while (true) {
            if (self.pos >= self.data.len) return error.InvalidName;
            if (depth >= MAX_COMPRESSION_DEPTH) return error.CompressionLoop;

            const label_len = self.data[self.pos];

            // Check for compression pointer (top 2 bits set)
            if ((label_len & 0xC0) == 0xC0) {
                if (self.pos + 1 >= self.data.len) return error.InvalidName;

                // Save position for after we finish following pointers
                if (!jumped) {
                    saved_pos = self.pos + 2;
                    jumped = true;
                }

                // Get offset from pointer
                const offset = (@as(u16, label_len & 0x3F) << 8) | self.data[self.pos + 1];
                if (offset >= self.data.len) return error.InvalidName;

                self.pos = offset;
                depth += 1;
                continue;
            }

            // Regular label
            if (label_len == 0) {
                // End of name
                if (name_pos >= types.MAX_NAME_LENGTH) return error.NameTooLong;
                name.data[name_pos] = 0;
                name_pos += 1;
                self.pos += 1;
                break;
            }

            if (label_len > types.MAX_LABEL_LENGTH) return error.InvalidName;
            if (self.pos + 1 + label_len > self.data.len) return error.InvalidName;
            if (name_pos + 1 + label_len > types.MAX_NAME_LENGTH) return error.NameTooLong;

            // Copy label
            name.data[name_pos] = label_len;
            name_pos += 1;
            @memcpy(name.data[name_pos..][0..label_len], self.data[self.pos + 1 ..][0..label_len]);
            name_pos += label_len;
            self.pos += 1 + label_len;
        }

        // Restore position if we jumped
        if (jumped) {
            self.pos = saved_pos;
        }

        name.len = @intCast(name_pos);
        return name;
    }

    /// Skip a name (for efficiency when we don't need to parse it)
    pub fn skipName(self: *Parser) ParseError!void {
        while (true) {
            if (self.pos >= self.data.len) return error.InvalidName;

            const label_len = self.data[self.pos];

            if ((label_len & 0xC0) == 0xC0) {
                // Compression pointer - skip 2 bytes and done
                self.pos += 2;
                return;
            }

            if (label_len == 0) {
                self.pos += 1;
                return;
            }

            if (label_len > types.MAX_LABEL_LENGTH) return error.InvalidName;
            self.pos += 1 + label_len;
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Helper Functions
    // ═══════════════════════════════════════════════════════════════════════

    fn readU16BE(self: *Parser) u16 {
        const val = std.mem.readInt(u16, self.data[self.pos..][0..2], .big);
        self.pos += 2;
        return val;
    }

    fn readU32BE(self: *Parser) u32 {
        const val = std.mem.readInt(u32, self.data[self.pos..][0..4], .big);
        self.pos += 4;
        return val;
    }

    /// Get remaining bytes
    pub fn remaining(self: *const Parser) usize {
        return if (self.pos < self.data.len) self.data.len - self.pos else 0;
    }
};

// ═══════════════════════════════════════════════════════════════════════════
// DNS Message Builder (Zero-Allocation)
// ═══════════════════════════════════════════════════════════════════════════

/// DNS Message Builder - writes directly to buffer
pub const Builder = struct {
    buf: []u8,
    pos: usize = 0,

    /// Name compression table
    compression: struct {
        names: [64]struct {
            name: Name,
            offset: u16,
        } = undefined,
        count: usize = 0,
    } = .{},

    pub fn init(buf: []u8) Builder {
        return .{ .buf = buf };
    }

    /// Write header
    pub fn writeHeader(self: *Builder, header: Header) !void {
        if (self.pos + 12 > self.buf.len) return error.BufferTooSmall;

        self.writeU16BE(header.id);

        // Construct flags in DNS wire format:
        // Byte 1: QR(1) OPCODE(4) AA(1) TC(1) RD(1)
        // Byte 2: RA(1) Z(1) AD(1) CD(1) RCODE(4)
        const flags_u16: u16 = (@as(u16, @intFromBool(header.flags.qr)) << 15) |
            (@as(u16, header.flags.opcode) << 11) |
            (@as(u16, @intFromBool(header.flags.aa)) << 10) |
            (@as(u16, @intFromBool(header.flags.tc)) << 9) |
            (@as(u16, @intFromBool(header.flags.rd)) << 8) |
            (@as(u16, @intFromBool(header.flags.ra)) << 7) |
            (@as(u16, @intFromBool(header.flags.z)) << 6) |
            (@as(u16, @intFromBool(header.flags.ad)) << 5) |
            (@as(u16, @intFromBool(header.flags.cd)) << 4) |
            @as(u16, header.flags.rcode);
        self.writeU16BE(flags_u16);

        self.writeU16BE(header.qd_count);
        self.writeU16BE(header.an_count);
        self.writeU16BE(header.ns_count);
        self.writeU16BE(header.ar_count);
    }

    /// Write question
    pub fn writeQuestion(self: *Builder, q: Question) !void {
        try self.writeName(&q.name);
        if (self.pos + 4 > self.buf.len) return error.BufferTooSmall;
        self.writeU16BE(@intFromEnum(q.qtype));
        self.writeU16BE(@intFromEnum(q.qclass));
    }

    /// Write resource record
    pub fn writeRecord(self: *Builder, rr: ResourceRecord) !void {
        try self.writeName(&rr.name);
        if (self.pos + 10 + rr.rdlength > self.buf.len) return error.BufferTooSmall;

        self.writeU16BE(@intFromEnum(rr.rtype));
        self.writeU16BE(@intFromEnum(rr.class));
        self.writeU32BE(rr.ttl);
        self.writeU16BE(rr.rdlength);
        @memcpy(self.buf[self.pos..][0..rr.rdlength], rr.rdata[0..rr.rdlength]);
        self.pos += rr.rdlength;
    }

    /// Write a name with compression
    pub fn writeName(self: *Builder, name: *const Name) !void {
        // Check compression table for this name
        for (self.compression.names[0..self.compression.count]) |entry| {
            if (entry.name.eql(name)) {
                // Use compression pointer
                if (self.pos + 2 > self.buf.len) return error.BufferTooSmall;
                const pointer: u16 = 0xC000 | entry.offset;
                self.writeU16BE(pointer);
                return;
            }
        }

        // Add to compression table if space
        if (self.compression.count < 64 and self.pos < 0x3FFF) {
            self.compression.names[self.compression.count] = .{
                .name = name.*,
                .offset = @intCast(self.pos),
            };
            self.compression.count += 1;
        }

        // Write name directly
        if (self.pos + name.len > self.buf.len) return error.BufferTooSmall;
        @memcpy(self.buf[self.pos..][0..name.len], name.data[0..name.len]);
        self.pos += name.len;
    }

    /// Write raw bytes
    pub fn writeBytes(self: *Builder, data: []const u8) !void {
        if (self.pos + data.len > self.buf.len) return error.BufferTooSmall;
        @memcpy(self.buf[self.pos..][0..data.len], data);
        self.pos += data.len;
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Helper Functions
    // ═══════════════════════════════════════════════════════════════════════

    fn writeU16BE(self: *Builder, val: u16) void {
        std.mem.writeInt(u16, self.buf[self.pos..][0..2], val, .big);
        self.pos += 2;
    }

    fn writeU32BE(self: *Builder, val: u32) void {
        std.mem.writeInt(u32, self.buf[self.pos..][0..4], val, .big);
        self.pos += 4;
    }

    /// Get the built message
    pub fn message(self: *const Builder) []const u8 {
        return self.buf[0..self.pos];
    }

    /// Get remaining capacity
    pub fn remaining(self: *const Builder) usize {
        return if (self.pos < self.buf.len) self.buf.len - self.pos else 0;
    }
};

// ═══════════════════════════════════════════════════════════════════════════
// Full Message Parser
// ═══════════════════════════════════════════════════════════════════════════

/// Parsed DNS Message with pre-allocated storage
pub const Message = struct {
    header: Header = undefined,
    questions: [16]Question = undefined,
    question_count: u8 = 0,
    answers: [64]ResourceRecord = undefined,
    answer_count: u8 = 0,
    authority: [16]ResourceRecord = undefined,
    authority_count: u8 = 0,
    additional: [16]ResourceRecord = undefined,
    additional_count: u8 = 0,

    /// Parse a complete DNS message
    pub fn parse(data: []const u8) ParseError!Message {
        var msg = Message{};
        var parser = Parser.init(data);

        msg.header = try parser.parseHeader();

        // Parse questions
        var i: u16 = 0;
        while (i < msg.header.qd_count and msg.question_count < 16) : (i += 1) {
            msg.questions[msg.question_count] = try parser.parseQuestion();
            msg.question_count += 1;
        }

        // Parse answers
        i = 0;
        while (i < msg.header.an_count and msg.answer_count < 64) : (i += 1) {
            msg.answers[msg.answer_count] = try parser.parseRecord();
            msg.answer_count += 1;
        }

        // Parse authority
        i = 0;
        while (i < msg.header.ns_count and msg.authority_count < 16) : (i += 1) {
            msg.authority[msg.authority_count] = try parser.parseRecord();
            msg.authority_count += 1;
        }

        // Parse additional
        i = 0;
        while (i < msg.header.ar_count and msg.additional_count < 16) : (i += 1) {
            msg.additional[msg.additional_count] = try parser.parseRecord();
            msg.additional_count += 1;
        }

        return msg;
    }

    /// Check if this is a query
    pub fn isQuery(self: *const Message) bool {
        return self.header.isQuery();
    }

    /// Get the first question (most common case)
    pub fn firstQuestion(self: *const Message) ?*const Question {
        if (self.question_count == 0) return null;
        return &self.questions[0];
    }
};

// ═══════════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════════

test "Parser.parseHeader" {
    // DNS query for example.com A record
    const data = [_]u8{
        0x12, 0x34, // ID
        0x01, 0x00, // Flags: standard query, RD
        0x00, 0x01, // QDCOUNT
        0x00, 0x00, // ANCOUNT
        0x00, 0x00, // NSCOUNT
        0x00, 0x00, // ARCOUNT
    };

    var parser = Parser.init(&data);
    const header = try parser.parseHeader();

    try std.testing.expectEqual(@as(u16, 0x1234), header.id);
    try std.testing.expectEqual(@as(u16, 1), header.qd_count);
    try std.testing.expect(header.flags.rd);
    try std.testing.expect(!header.flags.qr);
}

test "Parser.parseName with compression" {
    // Message with compressed name
    const data = [_]u8{
        // Header (12 bytes)
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        // Name: example.com
        0x07, 'e', 'x', 'a', 'm', 'p', 'l', 'e',
        0x03, 'c', 'o', 'm',
        0x00,
        // Another name with compression pointer to offset 12
        0x03, 'w', 'w', 'w',
        0xC0, 0x0C, // Pointer to "example.com" at offset 12
    };

    var parser = Parser.init(&data);
    parser.pos = 12; // Skip header

    const name1 = try parser.parseName();
    var buf1: [256]u8 = undefined;
    try std.testing.expectEqualStrings("example.com", name1.toString(&buf1));

    const name2 = try parser.parseName();
    var buf2: [256]u8 = undefined;
    try std.testing.expectEqualStrings("www.example.com", name2.toString(&buf2));
}

test "Builder basic message" {
    var buf: [512]u8 = undefined;
    var builder = Builder.init(&buf);

    const header = Header{
        .id = 0x1234,
        .flags = .{
            .qr = false,
            .opcode = 0,
            .aa = false,
            .tc = false,
            .rd = true,
            .ra = false,
            .z = false,
            .ad = false,
            .cd = false,
            .rcode = 0,
        },
        .qd_count = 1,
        .an_count = 0,
        .ns_count = 0,
        .ar_count = 0,
    };

    try builder.writeHeader(header);
    try std.testing.expectEqual(@as(usize, 12), builder.pos);

    const name = try Name.fromString("example.com");
    const question = Question{
        .name = name,
        .qtype = .A,
        .qclass = .IN,
    };

    try builder.writeQuestion(question);

    // Verify we can parse what we built
    const msg = try Message.parse(builder.message());
    try std.testing.expectEqual(@as(u16, 0x1234), msg.header.id);
    try std.testing.expectEqual(@as(u8, 1), msg.question_count);
}

test "Message.parse full query" {
    // Real DNS query packet for google.com A record
    const data = [_]u8{
        // Header
        0xAB, 0xCD, // ID
        0x01, 0x00, // Flags
        0x00, 0x01, // QDCOUNT
        0x00, 0x00, // ANCOUNT
        0x00, 0x00, // NSCOUNT
        0x00, 0x00, // ARCOUNT
        // Question: google.com A IN
        0x06, 'g', 'o', 'o', 'g', 'l', 'e',
        0x03, 'c', 'o', 'm',
        0x00,
        0x00, 0x01, // A
        0x00, 0x01, // IN
    };

    const msg = try Message.parse(&data);
    try std.testing.expectEqual(@as(u16, 0xABCD), msg.header.id);
    try std.testing.expectEqual(@as(u8, 1), msg.question_count);

    const q = msg.firstQuestion().?;
    try std.testing.expectEqual(RecordType.A, q.qtype);
    try std.testing.expectEqual(Class.IN, q.qclass);

    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings("google.com", q.name.toString(&buf));
}
