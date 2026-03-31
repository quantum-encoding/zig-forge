//! ═══════════════════════════════════════════════════════════════════════════
//! DNS Protocol Types (RFC 1035, RFC 3596, RFC 4034)
//! ═══════════════════════════════════════════════════════════════════════════
//!
//! Core DNS protocol definitions including:
//! • Record types (A, AAAA, CNAME, MX, NS, SOA, TXT, etc.)
//! • Message structure (header, question, answer, authority, additional)
//! • DNSSEC types (RRSIG, DNSKEY, DS, NSEC, NSEC3)
//!

const std = @import("std");

// ═══════════════════════════════════════════════════════════════════════════
// DNS Header
// ═══════════════════════════════════════════════════════════════════════════

/// DNS Message Header (12 bytes)
pub const Header = packed struct {
    id: u16,
    flags: Flags,
    qd_count: u16, // Question count
    an_count: u16, // Answer count
    ns_count: u16, // Authority count
    ar_count: u16, // Additional count

    pub const Flags = packed struct {
        rd: bool, // Recursion Desired
        tc: bool, // Truncation
        aa: bool, // Authoritative Answer
        opcode: u4, // Operation code
        qr: bool, // Query/Response
        rcode: u4, // Response code
        cd: bool, // Checking Disabled
        ad: bool, // Authenticated Data
        z: bool, // Reserved
        ra: bool, // Recursion Available
    };

    pub fn isQuery(self: Header) bool {
        return !self.flags.qr;
    }

    pub fn isResponse(self: Header) bool {
        return self.flags.qr;
    }
};

/// DNS Operation Codes
pub const Opcode = enum(u4) {
    query = 0,
    iquery = 1, // Inverse Query (obsolete)
    status = 2,
    notify = 4,
    update = 5,
    _,
};

/// DNS Response Codes
pub const Rcode = enum(u4) {
    no_error = 0,
    format_error = 1,
    server_failure = 2,
    name_error = 3, // NXDOMAIN
    not_implemented = 4,
    refused = 5,
    yx_domain = 6, // Name exists when it should not
    yx_rr_set = 7, // RR set exists when it should not
    nx_rr_set = 8, // RR set does not exist
    not_auth = 9, // Not authoritative
    not_zone = 10, // Name not in zone
    _,
};

// ═══════════════════════════════════════════════════════════════════════════
// DNS Record Types
// ═══════════════════════════════════════════════════════════════════════════

/// DNS Record Types (RFC 1035, RFC 3596, RFC 4034, etc.)
pub const RecordType = enum(u16) {
    A = 1, // IPv4 address
    NS = 2, // Nameserver
    MD = 3, // Mail destination (obsolete)
    MF = 4, // Mail forwarder (obsolete)
    CNAME = 5, // Canonical name
    SOA = 6, // Start of authority
    MB = 7, // Mailbox domain name
    MG = 8, // Mail group member
    MR = 9, // Mail rename domain
    NULL = 10, // Null record
    WKS = 11, // Well-known services
    PTR = 12, // Domain name pointer
    HINFO = 13, // Host information
    MINFO = 14, // Mailbox information
    MX = 15, // Mail exchange
    TXT = 16, // Text strings
    RP = 17, // Responsible person
    AFSDB = 18, // AFS database
    X25 = 19, // X.25 PSDN address
    ISDN = 20, // ISDN address
    RT = 21, // Route through
    NSAP = 22, // NSAP address
    NSAP_PTR = 23, // NSAP pointer
    SIG = 24, // Security signature (obsolete)
    KEY = 25, // Security key (obsolete)
    PX = 26, // X.400 mail mapping
    GPOS = 27, // Geographical position
    AAAA = 28, // IPv6 address
    LOC = 29, // Location information
    NXT = 30, // Next domain (obsolete)
    EID = 31, // Endpoint identifier
    NIMLOC = 32, // Nimrod locator
    SRV = 33, // Service locator
    ATMA = 34, // ATM address
    NAPTR = 35, // Naming authority pointer
    KX = 36, // Key exchanger
    CERT = 37, // Certificate
    A6 = 38, // IPv6 address (obsolete)
    DNAME = 39, // Delegation name
    SINK = 40, // Kitchen sink
    OPT = 41, // EDNS option
    APL = 42, // Address prefix list
    DS = 43, // Delegation signer
    SSHFP = 44, // SSH key fingerprint
    IPSECKEY = 45, // IPsec key
    RRSIG = 46, // DNSSEC signature
    NSEC = 47, // Next secure record
    DNSKEY = 48, // DNSSEC key
    DHCID = 49, // DHCP identifier
    NSEC3 = 50, // NSEC3
    NSEC3PARAM = 51, // NSEC3 parameters
    TLSA = 52, // TLSA certificate
    SMIMEA = 53, // S/MIME certificate
    HIP = 55, // Host identity protocol
    NINFO = 56, // Zone status
    RKEY = 57, // RKEY
    TALINK = 58, // Trust anchor link
    CDS = 59, // Child DS
    CDNSKEY = 60, // Child DNSKEY
    OPENPGPKEY = 61, // OpenPGP key
    CSYNC = 62, // Child-to-parent sync
    ZONEMD = 63, // Zone message digest
    SVCB = 64, // Service binding
    HTTPS = 65, // HTTPS binding
    SPF = 99, // SPF (obsolete, use TXT)
    UINFO = 100, // User info
    UID = 101, // User ID
    GID = 102, // Group ID
    UNSPEC = 103, // Unspecified
    NID = 104, // Node identifier
    L32 = 105, // 32-bit locator
    L64 = 106, // 64-bit locator
    LP = 107, // Locator pointer
    EUI48 = 108, // EUI-48 address
    EUI64 = 109, // EUI-64 address
    TKEY = 249, // Transaction key
    TSIG = 250, // Transaction signature
    IXFR = 251, // Incremental zone transfer
    AXFR = 252, // Full zone transfer
    MAILB = 253, // Mailbox records
    MAILA = 254, // Mail agent records
    ANY = 255, // All records
    URI = 256, // URI
    CAA = 257, // Certification authority authorization
    AVC = 258, // Application visibility
    DOA = 259, // Digital object architecture
    AMTRELAY = 260, // AMT relay
    TA = 32768, // Trust anchor
    DLV = 32769, // DNSSEC lookaside validation
    _,

    pub fn toString(self: RecordType) []const u8 {
        return switch (self) {
            .A => "A",
            .NS => "NS",
            .CNAME => "CNAME",
            .SOA => "SOA",
            .PTR => "PTR",
            .MX => "MX",
            .TXT => "TXT",
            .AAAA => "AAAA",
            .SRV => "SRV",
            .DS => "DS",
            .RRSIG => "RRSIG",
            .NSEC => "NSEC",
            .DNSKEY => "DNSKEY",
            .NSEC3 => "NSEC3",
            .NSEC3PARAM => "NSEC3PARAM",
            .CAA => "CAA",
            .ANY => "ANY",
            else => "UNKNOWN",
        };
    }
};

/// DNS Classes
pub const Class = enum(u16) {
    IN = 1, // Internet
    CS = 2, // CSNET (obsolete)
    CH = 3, // Chaos
    HS = 4, // Hesiod
    NONE = 254, // Used in dynamic updates
    ANY = 255, // Any class
    _,

    pub fn toString(self: Class) []const u8 {
        return switch (self) {
            .IN => "IN",
            .CH => "CH",
            .HS => "HS",
            .ANY => "ANY",
            else => "UNKNOWN",
        };
    }
};

// ═══════════════════════════════════════════════════════════════════════════
// DNS Question
// ═══════════════════════════════════════════════════════════════════════════

/// DNS Question structure
pub const Question = struct {
    name: Name,
    qtype: RecordType,
    qclass: Class,
};

// ═══════════════════════════════════════════════════════════════════════════
// DNS Name (Domain Name)
// ═══════════════════════════════════════════════════════════════════════════

/// Maximum DNS name length
pub const MAX_NAME_LENGTH = 255;
/// Maximum DNS label length
pub const MAX_LABEL_LENGTH = 63;

/// DNS Domain Name - stores raw wire format
pub const Name = struct {
    /// Raw name data (wire format with length-prefixed labels)
    data: [MAX_NAME_LENGTH]u8 = undefined,
    /// Length of name in wire format
    len: u8 = 0,

    pub fn init() Name {
        return .{};
    }

    /// Create name from dot-notation string (e.g., "example.com")
    pub fn fromString(str: []const u8) !Name {
        var name = Name{};
        var pos: usize = 0;

        if (str.len == 0 or (str.len == 1 and str[0] == '.')) {
            // Root domain
            name.data[0] = 0;
            name.len = 1;
            return name;
        }

        var start: usize = 0;
        for (str, 0..) |c, i| {
            if (c == '.') {
                const label_len = i - start;
                if (label_len == 0) {
                    start = i + 1;
                    continue;
                }
                if (label_len > MAX_LABEL_LENGTH) return error.LabelTooLong;
                if (pos + 1 + label_len > MAX_NAME_LENGTH) return error.NameTooLong;

                name.data[pos] = @intCast(label_len);
                pos += 1;
                @memcpy(name.data[pos..][0..label_len], str[start..i]);
                pos += label_len;
                start = i + 1;
            }
        }

        // Handle last label (no trailing dot)
        if (start < str.len) {
            const label_len = str.len - start;
            if (label_len > MAX_LABEL_LENGTH) return error.LabelTooLong;
            if (pos + 1 + label_len + 1 > MAX_NAME_LENGTH) return error.NameTooLong;

            name.data[pos] = @intCast(label_len);
            pos += 1;
            @memcpy(name.data[pos..][0..label_len], str[start..]);
            pos += label_len;
        }

        // Null terminator
        name.data[pos] = 0;
        pos += 1;
        name.len = @intCast(pos);

        return name;
    }

    /// Convert to dot-notation string
    pub fn toString(self: *const Name, buf: []u8) []const u8 {
        if (self.len == 0) return "";
        if (self.len == 1 and self.data[0] == 0) return ".";

        var pos: usize = 0;
        var out_pos: usize = 0;

        while (pos < self.len) {
            const label_len = self.data[pos];
            if (label_len == 0) break;

            pos += 1;
            if (pos + label_len > self.len) break;

            if (out_pos + label_len + 1 > buf.len) break;

            @memcpy(buf[out_pos..][0..label_len], self.data[pos..][0..label_len]);
            out_pos += label_len;
            buf[out_pos] = '.';
            out_pos += 1;
            pos += label_len;
        }

        // Remove trailing dot for display
        if (out_pos > 0 and buf[out_pos - 1] == '.') {
            out_pos -= 1;
        }

        return buf[0..out_pos];
    }

    /// Get wire format bytes
    pub fn wireFormat(self: *const Name) []const u8 {
        return self.data[0..self.len];
    }

    /// Check if names are equal (case-insensitive)
    pub fn eql(self: *const Name, other: *const Name) bool {
        if (self.len != other.len) return false;

        for (self.data[0..self.len], other.data[0..other.len]) |a, b| {
            if (std.ascii.toLower(a) != std.ascii.toLower(b)) return false;
        }
        return true;
    }

    /// Check if this name is a subdomain of parent
    pub fn isSubdomainOf(self: *const Name, parent: *const Name) bool {
        if (self.len < parent.len) return false;
        if (parent.len == 1 and parent.data[0] == 0) return true; // Everything is under root

        const offset = self.len - parent.len;
        for (parent.data[0..parent.len], 0..) |b, i| {
            if (std.ascii.toLower(self.data[offset + i]) != std.ascii.toLower(b)) return false;
        }
        return true;
    }

    /// Get number of labels
    pub fn labelCount(self: *const Name) u8 {
        var count: u8 = 0;
        var pos: usize = 0;

        while (pos < self.len) {
            const label_len = self.data[pos];
            if (label_len == 0) break;
            count += 1;
            pos += 1 + label_len;
        }

        return count;
    }
};

// ═══════════════════════════════════════════════════════════════════════════
// Resource Record
// ═══════════════════════════════════════════════════════════════════════════

/// Maximum RDATA length
pub const MAX_RDATA_LENGTH = 65535;
/// Typical RDATA buffer size
pub const RDATA_BUFFER_SIZE = 512;

/// Resource Record
pub const ResourceRecord = struct {
    name: Name,
    rtype: RecordType,
    class: Class,
    ttl: u32,
    rdlength: u16,
    rdata: [RDATA_BUFFER_SIZE]u8 = undefined,

    /// Get RDATA as slice
    pub fn rdataSlice(self: *const ResourceRecord) []const u8 {
        return self.rdata[0..self.rdlength];
    }
};

// ═══════════════════════════════════════════════════════════════════════════
// Specific Record Data Types
// ═══════════════════════════════════════════════════════════════════════════

/// A Record (IPv4 address)
pub const ARecord = struct {
    address: [4]u8,

    pub fn fromRdata(rdata: []const u8) ?ARecord {
        if (rdata.len != 4) return null;
        return .{ .address = rdata[0..4].* };
    }

    pub fn toRdata(self: *const ARecord, buf: []u8) []const u8 {
        if (buf.len < 4) return &.{};
        @memcpy(buf[0..4], &self.address);
        return buf[0..4];
    }

    pub fn format(self: *const ARecord, buf: []u8) []const u8 {
        return std.fmt.bufPrint(buf, "{d}.{d}.{d}.{d}", .{
            self.address[0],
            self.address[1],
            self.address[2],
            self.address[3],
        }) catch "";
    }
};

/// AAAA Record (IPv6 address)
pub const AAAARecord = struct {
    address: [16]u8,

    pub fn fromRdata(rdata: []const u8) ?AAAARecord {
        if (rdata.len != 16) return null;
        return .{ .address = rdata[0..16].* };
    }

    pub fn toRdata(self: *const AAAARecord, buf: []u8) []const u8 {
        if (buf.len < 16) return &.{};
        @memcpy(buf[0..16], &self.address);
        return buf[0..16];
    }
};

/// MX Record (Mail Exchange)
pub const MXRecord = struct {
    preference: u16,
    exchange: Name,

    pub fn fromRdata(rdata: []const u8) ?MXRecord {
        if (rdata.len < 3) return null;
        var mx = MXRecord{
            .preference = std.mem.readInt(u16, rdata[0..2], .big),
            .exchange = Name{},
        };

        // Parse exchange name
        var pos: usize = 2;
        var name_pos: usize = 0;
        while (pos < rdata.len) {
            const label_len = rdata[pos];
            if (label_len == 0) {
                mx.exchange.data[name_pos] = 0;
                mx.exchange.len = @intCast(name_pos + 1);
                break;
            }
            if (pos + 1 + label_len > rdata.len) return null;
            mx.exchange.data[name_pos] = label_len;
            name_pos += 1;
            @memcpy(mx.exchange.data[name_pos..][0..label_len], rdata[pos + 1 ..][0..label_len]);
            name_pos += label_len;
            pos += 1 + label_len;
        }

        return mx;
    }
};

/// SOA Record (Start of Authority)
pub const SOARecord = struct {
    mname: Name, // Primary nameserver
    rname: Name, // Responsible person email
    serial: u32,
    refresh: u32,
    retry: u32,
    expire: u32,
    minimum: u32, // Negative cache TTL

    pub fn defaultTTL(self: *const SOARecord) u32 {
        return self.minimum;
    }
};

/// TXT Record
pub const TXTRecord = struct {
    data: [255]u8 = undefined,
    len: u8 = 0,

    pub fn fromRdata(rdata: []const u8) ?TXTRecord {
        if (rdata.len == 0) return null;
        const txt_len = rdata[0];
        if (rdata.len < 1 + txt_len) return null;

        var txt = TXTRecord{};
        txt.len = txt_len;
        @memcpy(txt.data[0..txt_len], rdata[1..][0..txt_len]);
        return txt;
    }

    pub fn text(self: *const TXTRecord) []const u8 {
        return self.data[0..self.len];
    }
};

/// SRV Record (Service)
pub const SRVRecord = struct {
    priority: u16,
    weight: u16,
    port: u16,
    target: Name,
};

/// CAA Record (Certification Authority Authorization)
pub const CAARecord = struct {
    flags: u8,
    tag: [15]u8 = undefined,
    tag_len: u8 = 0,
    value: [255]u8 = undefined,
    value_len: u8 = 0,

    pub fn isCritical(self: *const CAARecord) bool {
        return (self.flags & 0x80) != 0;
    }
};

// ═══════════════════════════════════════════════════════════════════════════
// DNSSEC Types
// ═══════════════════════════════════════════════════════════════════════════

/// DNSSEC Algorithm Types (RFC 8624)
pub const DNSSECAlgorithm = enum(u8) {
    delete = 0,
    rsamd5 = 1, // Deprecated
    dh = 2, // Deprecated
    dsa = 3, // Deprecated
    rsasha1 = 5, // Deprecated
    dsa_nsec3_sha1 = 6, // Deprecated
    rsasha1_nsec3_sha1 = 7, // Deprecated
    rsasha256 = 8, // Recommended
    rsasha512 = 10, // Recommended
    ecc_gost = 12, // Deprecated
    ecdsap256sha256 = 13, // Recommended
    ecdsap384sha384 = 14, // Recommended
    ed25519 = 15, // Recommended
    ed448 = 16, // Recommended
    indirect = 252,
    privatedns = 253,
    privateoid = 254,
    _,
};

/// DNSSEC Digest Types
pub const DNSSECDigest = enum(u8) {
    sha1 = 1, // Deprecated
    sha256 = 2, // Mandatory
    gost = 3, // Deprecated
    sha384 = 4, // Recommended
    _,
};

/// DNSKEY Record
pub const DNSKEYRecord = struct {
    flags: u16,
    protocol: u8,
    algorithm: DNSSECAlgorithm,
    public_key: [512]u8 = undefined,
    key_len: u16 = 0,

    pub const FLAG_ZONE_KEY = 0x0100;
    pub const FLAG_SEP = 0x0001; // Secure Entry Point (KSK)

    pub fn isZoneKey(self: *const DNSKEYRecord) bool {
        return (self.flags & FLAG_ZONE_KEY) != 0;
    }

    pub fn isKSK(self: *const DNSKEYRecord) bool {
        return (self.flags & FLAG_SEP) != 0;
    }

    pub fn isZSK(self: *const DNSKEYRecord) bool {
        return self.isZoneKey() and !self.isKSK();
    }
};

/// RRSIG Record (Resource Record Signature)
pub const RRSIGRecord = struct {
    type_covered: RecordType,
    algorithm: DNSSECAlgorithm,
    labels: u8,
    original_ttl: u32,
    expiration: u32,
    inception: u32,
    key_tag: u16,
    signer: Name,
    signature: [512]u8 = undefined,
    sig_len: u16 = 0,
};

/// DS Record (Delegation Signer)
pub const DSRecord = struct {
    key_tag: u16,
    algorithm: DNSSECAlgorithm,
    digest_type: DNSSECDigest,
    digest: [64]u8 = undefined,
    digest_len: u8 = 0,
};

/// NSEC Record (Next Secure)
pub const NSECRecord = struct {
    next_domain: Name,
    type_bitmap: [32]u8 = undefined,
    bitmap_len: u8 = 0,

    pub fn coversType(self: *const NSECRecord, rtype: RecordType) bool {
        const type_num = @intFromEnum(rtype);
        const byte_idx = type_num / 8;
        const bit_idx: u3 = @intCast(7 - (type_num % 8));

        if (byte_idx >= self.bitmap_len) return false;
        return (self.type_bitmap[byte_idx] & (@as(u8, 1) << bit_idx)) != 0;
    }
};

/// NSEC3 Record
pub const NSEC3Record = struct {
    hash_algorithm: u8,
    flags: u8,
    iterations: u16,
    salt: [255]u8 = undefined,
    salt_len: u8 = 0,
    next_hashed: [32]u8 = undefined,
    hash_len: u8 = 0,
    type_bitmap: [32]u8 = undefined,
    bitmap_len: u8 = 0,

    pub const FLAG_OPT_OUT = 0x01;

    pub fn isOptOut(self: *const NSEC3Record) bool {
        return (self.flags & FLAG_OPT_OUT) != 0;
    }
};

/// NSEC3PARAM Record
pub const NSEC3PARAMRecord = struct {
    hash_algorithm: u8,
    flags: u8,
    iterations: u16,
    salt: [255]u8 = undefined,
    salt_len: u8 = 0,
};

// ═══════════════════════════════════════════════════════════════════════════
// EDNS (RFC 6891)
// ═══════════════════════════════════════════════════════════════════════════

/// EDNS OPT pseudo-record
pub const OPTRecord = struct {
    udp_size: u16, // Requestor's UDP payload size
    extended_rcode: u8,
    version: u8,
    flags: u16,
    options: [512]u8 = undefined,
    options_len: u16 = 0,

    pub const FLAG_DO = 0x8000; // DNSSEC OK

    pub fn dnssecOK(self: *const OPTRecord) bool {
        return (self.flags & FLAG_DO) != 0;
    }
};

/// EDNS Option Codes
pub const EDNSOptionCode = enum(u16) {
    llq = 1, // Long-lived queries
    ul = 2, // Update lease
    nsid = 3, // Name server identifier
    dau = 5, // DNSSEC algorithm understood
    dhu = 6, // DS hash understood
    n3u = 7, // NSEC3 hash understood
    client_subnet = 8, // Client subnet
    expire = 9, // Expire
    cookie = 10, // DNS cookies
    tcp_keepalive = 11, // TCP keepalive
    padding = 12, // Padding
    chain = 13, // Chain query
    key_tag = 14, // Key tag
    extended_error = 15, // Extended DNS errors
    client_tag = 16, // Client tag
    server_tag = 17, // Server tag
    _,
};

// ═══════════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════════

test "Name.fromString" {
    const name = try Name.fromString("example.com");
    try std.testing.expectEqual(@as(u8, 13), name.len);

    var buf: [256]u8 = undefined;
    const str = name.toString(&buf);
    try std.testing.expectEqualStrings("example.com", str);
}

test "Name.fromString root" {
    const name = try Name.fromString(".");
    try std.testing.expectEqual(@as(u8, 1), name.len);
    try std.testing.expectEqual(@as(u8, 0), name.data[0]);
}

test "Name.eql" {
    const name1 = try Name.fromString("EXAMPLE.COM");
    const name2 = try Name.fromString("example.com");
    try std.testing.expect(name1.eql(&name2));
}

test "Name.isSubdomainOf" {
    const parent = try Name.fromString("example.com");
    const child = try Name.fromString("www.example.com");
    const other = try Name.fromString("example.org");

    try std.testing.expect(child.isSubdomainOf(&parent));
    try std.testing.expect(!other.isSubdomainOf(&parent));
}
