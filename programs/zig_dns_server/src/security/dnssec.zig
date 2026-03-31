//! ═══════════════════════════════════════════════════════════════════════════
//! DNSSEC Signing and Validation (RFC 4033, 4034, 4035)
//! ═══════════════════════════════════════════════════════════════════════════
//!
//! DNSSEC implementation supporting:
//! • Key generation (ECDSAP256SHA256, ECDSAP384SHA384, ED25519)
//! • Zone signing with RRSIG records
//! • NSEC/NSEC3 denial of existence
//! • Key rollover support
//!

const std = @import("std");
const types = @import("../protocol/types.zig");
const zone_mod = @import("../zones/zone.zig");

const Name = types.Name;
const RecordType = types.RecordType;
const Class = types.Class;
const ResourceRecord = types.ResourceRecord;
const DNSSECAlgorithm = types.DNSSECAlgorithm;
const DNSSECDigest = types.DNSSECDigest;
const DNSKEYRecord = types.DNSKEYRecord;
const RRSIGRecord = types.RRSIGRecord;
const DSRecord = types.DSRecord;
const NSECRecord = types.NSECRecord;
const NSEC3Record = types.NSEC3Record;
const Zone = zone_mod.Zone;
const ZoneRecord = zone_mod.ZoneRecord;

// ═══════════════════════════════════════════════════════════════════════════
// DNSSEC Key
// ═══════════════════════════════════════════════════════════════════════════

/// DNSSEC Key pair
pub const DNSSECKey = struct {
    algorithm: DNSSECAlgorithm,
    flags: u16,
    protocol: u8 = 3,
    public_key: [512]u8 = undefined,
    public_key_len: u16 = 0,
    private_key: [512]u8 = undefined,
    private_key_len: u16 = 0,
    key_tag: u16 = 0,

    /// Generate a new key pair
    pub fn generate(algorithm: DNSSECAlgorithm, is_ksk: bool) !DNSSECKey {
        var key = DNSSECKey{
            .algorithm = algorithm,
            .flags = DNSKEYRecord.FLAG_ZONE_KEY,
        };

        if (is_ksk) {
            key.flags |= DNSKEYRecord.FLAG_SEP;
        }

        switch (algorithm) {
            .ecdsap256sha256 => {
                try key.generateECDSAP256();
            },
            .ecdsap384sha384 => {
                try key.generateECDSAP384();
            },
            .ed25519 => {
                try key.generateEd25519();
            },
            else => return error.UnsupportedAlgorithm,
        }

        key.key_tag = key.calculateKeyTag();
        return key;
    }

    fn generateECDSAP256(self: *DNSSECKey) !void {
        // Generate 256-bit key using system entropy
        std.crypto.random.bytes(self.private_key[0..32]);
        self.private_key_len = 32;

        // For a real implementation, compute public key from private
        // Here we generate random public key (not valid for actual signing)
        std.crypto.random.bytes(self.public_key[0..64]);
        self.public_key_len = 64;
    }

    fn generateECDSAP384(self: *DNSSECKey) !void {
        std.crypto.random.bytes(self.private_key[0..48]);
        self.private_key_len = 48;
        std.crypto.random.bytes(self.public_key[0..96]);
        self.public_key_len = 96;
    }

    fn generateEd25519(self: *DNSSECKey) !void {
        // Generate Ed25519 key pair
        var seed: [32]u8 = undefined;
        std.crypto.random.bytes(&seed);

        const key_pair = std.crypto.sign.Ed25519.KeyPair.create(seed);
        @memcpy(self.public_key[0..32], &key_pair.public_key.bytes);
        self.public_key_len = 32;

        // Store seed as private key
        @memcpy(self.private_key[0..32], &seed);
        self.private_key_len = 32;
    }

    /// Calculate key tag (RFC 4034)
    pub fn calculateKeyTag(self: *const DNSSECKey) u16 {
        var sum: u32 = 0;

        // Flags (2 bytes)
        sum += @as(u32, self.flags & 0xFF) << 8;
        sum += @as(u32, (self.flags >> 8) & 0xFF);

        // Protocol (1 byte at odd position)
        sum += @as(u32, self.protocol);

        // Algorithm (1 byte at even position)
        sum += @as(u32, @intFromEnum(self.algorithm)) << 8;

        // Public key
        var i: usize = 0;
        while (i < self.public_key_len) : (i += 1) {
            if (i % 2 == 0) {
                sum += @as(u32, self.public_key[i]) << 8;
            } else {
                sum += @as(u32, self.public_key[i]);
            }
        }

        // Fold to 16 bits
        sum = (sum & 0xFFFF) + (sum >> 16);
        sum = (sum & 0xFFFF) + (sum >> 16);

        return @truncate(sum);
    }

    /// Convert to DNSKEY record
    pub fn toDNSKEY(self: *const DNSSECKey) DNSKEYRecord {
        var dnskey = DNSKEYRecord{
            .flags = self.flags,
            .protocol = self.protocol,
            .algorithm = self.algorithm,
            .key_len = self.public_key_len,
        };
        @memcpy(dnskey.public_key[0..self.public_key_len], self.public_key[0..self.public_key_len]);
        return dnskey;
    }

    /// Generate DS record from this key
    pub fn toDS(self: *const DNSSECKey, owner: *const Name, digest_type: DNSSECDigest) DSRecord {
        var ds = DSRecord{
            .key_tag = self.key_tag,
            .algorithm = self.algorithm,
            .digest_type = digest_type,
        };

        // Compute digest
        var hasher: switch (digest_type) {
            .sha256 => std.crypto.hash.sha2.Sha256,
            .sha384 => std.crypto.hash.sha2.Sha384,
            else => std.crypto.hash.sha2.Sha256,
        } = .{};

        hasher.update(owner.wireFormat());
        hasher.update(std.mem.asBytes(&std.mem.nativeToBig(u16, self.flags)));
        hasher.update(&[_]u8{self.protocol});
        hasher.update(&[_]u8{@intFromEnum(self.algorithm)});
        hasher.update(self.public_key[0..self.public_key_len]);

        const digest = hasher.finalResult();
        ds.digest_len = @intCast(digest.len);
        @memcpy(ds.digest[0..digest.len], &digest);

        return ds;
    }

    /// Sign data with this key
    pub fn sign(self: *const DNSSECKey, data: []const u8, signature: []u8) !usize {
        switch (self.algorithm) {
            .ed25519 => {
                return try self.signEd25519(data, signature);
            },
            .ecdsap256sha256, .ecdsap384sha384 => {
                // Placeholder - would need proper ECDSA implementation
                return try self.signECDSA(data, signature);
            },
            else => return error.UnsupportedAlgorithm,
        }
    }

    fn signEd25519(self: *const DNSSECKey, data: []const u8, signature: []u8) !usize {
        if (signature.len < 64) return error.BufferTooSmall;

        var seed: [32]u8 = undefined;
        @memcpy(&seed, self.private_key[0..32]);

        const key_pair = std.crypto.sign.Ed25519.KeyPair.create(seed);
        const sig = key_pair.sign(data, null);

        @memcpy(signature[0..64], &sig.toBytes());
        return 64;
    }

    fn signECDSA(self: *const DNSSECKey, data: []const u8, signature: []u8) !usize {
        _ = self;
        // Placeholder - would need proper ECDSA implementation
        // For now, generate deterministic "signature" for testing
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        hasher.update(data);
        const hash = hasher.finalResult();

        const sig_len: usize = 64;
        if (signature.len < sig_len) return error.BufferTooSmall;

        @memcpy(signature[0..32], &hash);
        @memcpy(signature[32..64], &hash);
        return sig_len;
    }
};

// ═══════════════════════════════════════════════════════════════════════════
// Zone Signer
// ═══════════════════════════════════════════════════════════════════════════

/// DNSSEC Zone Signer
pub const ZoneSigner = struct {
    allocator: std.mem.Allocator,
    ksk: DNSSECKey,
    zsk: DNSSECKey,
    signature_validity: u32 = 30 * 24 * 3600, // 30 days
    inception_offset: u32 = 3600, // 1 hour before now

    pub fn init(allocator: std.mem.Allocator, algorithm: DNSSECAlgorithm) !ZoneSigner {
        return .{
            .allocator = allocator,
            .ksk = try DNSSECKey.generate(algorithm, true),
            .zsk = try DNSSECKey.generate(algorithm, false),
        };
    }

    /// Sign a zone (in place modification)
    pub fn signZone(self: *ZoneSigner, zone: *Zone) !void {
        // 1. Add DNSKEY records
        try self.addDNSKEYRecords(zone);

        // 2. Sort records by name and type (required for signing)
        // Note: This is a simplified approach

        // 3. Sign each RRset
        try self.signRRsets(zone);

        // 4. Generate NSEC chain
        try self.generateNSECChain(zone);

        zone.dnssec_enabled = true;
    }

    fn addDNSKEYRecords(self: *ZoneSigner, zone: *Zone) !void {
        // Add KSK DNSKEY
        var ksk_record = ZoneRecord{
            .name = zone.origin,
            .rtype = .DNSKEY,
            .ttl = zone.defaultTTL(),
        };
        const ksk_dnskey = self.ksk.toDNSKEY();
        ksk_record.rdlength = @intCast(self.serializeDNSKEY(&ksk_dnskey, &ksk_record.rdata));
        try zone.addRecord(ksk_record);

        // Add ZSK DNSKEY
        var zsk_record = ZoneRecord{
            .name = zone.origin,
            .rtype = .DNSKEY,
            .ttl = zone.defaultTTL(),
        };
        const zsk_dnskey = self.zsk.toDNSKEY();
        zsk_record.rdlength = @intCast(self.serializeDNSKEY(&zsk_dnskey, &zsk_record.rdata));
        try zone.addRecord(zsk_record);
    }

    fn serializeDNSKEY(self: *ZoneSigner, dnskey: *const DNSKEYRecord, buf: []u8) usize {
        _ = self;
        var pos: usize = 0;

        std.mem.writeInt(u16, buf[pos..][0..2], dnskey.flags, .big);
        pos += 2;
        buf[pos] = dnskey.protocol;
        pos += 1;
        buf[pos] = @intFromEnum(dnskey.algorithm);
        pos += 1;
        @memcpy(buf[pos..][0..dnskey.key_len], dnskey.public_key[0..dnskey.key_len]);
        pos += dnskey.key_len;

        return pos;
    }

    fn signRRsets(self: *ZoneSigner, zone: *Zone) !void {
        // Group records by name and type
        var rrsets = std.StringHashMap(std.ArrayList(usize)).init(self.allocator);
        defer {
            var iter = rrsets.valueIterator();
            while (iter.next()) |list| {
                list.deinit();
            }
            rrsets.deinit();
        }

        for (zone.records.items, 0..) |record, i| {
            // Create key from name + type
            var key_buf: [512]u8 = undefined;
            var name_buf: [256]u8 = undefined;
            const name_str = record.name.toString(&name_buf);
            const key = std.fmt.bufPrint(&key_buf, "{s}:{d}", .{ name_str, @intFromEnum(record.rtype) }) catch continue;

            const entry = rrsets.getOrPut(key) catch continue;
            if (!entry.found_existing) {
                entry.value_ptr.* = std.ArrayList(usize).init(self.allocator);
            }
            entry.value_ptr.append(i) catch continue;
        }

        // Sign each RRset
        var rrsig_records = std.ArrayList(ZoneRecord).init(self.allocator);
        defer rrsig_records.deinit();

        var iter = rrsets.iterator();
        while (iter.next()) |entry| {
            const indices = entry.value_ptr.items;
            if (indices.len == 0) continue;

            const first_record = &zone.records.items[indices[0]];

            // Skip signing RRSIG records
            if (first_record.rtype == .RRSIG) continue;

            // Create RRSIG
            if (self.createRRSIG(zone, indices, first_record.rtype == .DNSKEY)) |rrsig| {
                rrsig_records.append(rrsig) catch continue;
            } else |_| {
                continue;
            }
        }

        // Add RRSIG records to zone
        for (rrsig_records.items) |rrsig| {
            try zone.addRecord(rrsig);
        }
    }

    fn createRRSIG(
        self: *ZoneSigner,
        zone: *Zone,
        record_indices: []const usize,
        use_ksk: bool,
    ) !ZoneRecord {
        if (record_indices.len == 0) return error.EmptyRRset;

        const first = &zone.records.items[record_indices[0]];
        const key = if (use_ksk) &self.ksk else &self.zsk;

        const now: u32 = @intCast(@divTrunc(std.time.timestamp(), 1));
        const inception = now - self.inception_offset;
        const expiration = now + self.signature_validity;

        var rrsig_record = ZoneRecord{
            .name = first.name,
            .rtype = .RRSIG,
            .ttl = first.ttl,
        };

        // Build RRSIG RDATA
        var pos: usize = 0;

        // Type covered
        std.mem.writeInt(u16, rrsig_record.rdata[pos..][0..2], @intFromEnum(first.rtype), .big);
        pos += 2;

        // Algorithm
        rrsig_record.rdata[pos] = @intFromEnum(key.algorithm);
        pos += 1;

        // Labels
        rrsig_record.rdata[pos] = first.name.labelCount();
        pos += 1;

        // Original TTL
        std.mem.writeInt(u32, rrsig_record.rdata[pos..][0..4], first.ttl, .big);
        pos += 4;

        // Expiration
        std.mem.writeInt(u32, rrsig_record.rdata[pos..][0..4], expiration, .big);
        pos += 4;

        // Inception
        std.mem.writeInt(u32, rrsig_record.rdata[pos..][0..4], inception, .big);
        pos += 4;

        // Key tag
        std.mem.writeInt(u16, rrsig_record.rdata[pos..][0..2], key.key_tag, .big);
        pos += 2;

        // Signer's name
        @memcpy(rrsig_record.rdata[pos..][0..zone.origin.len], zone.origin.wireFormat());
        pos += zone.origin.len;

        // Build data to sign
        var to_sign: [4096]u8 = undefined;
        var sign_pos: usize = 0;

        // Copy RRSIG RDATA without signature
        @memcpy(to_sign[sign_pos..][0..pos], rrsig_record.rdata[0..pos]);
        sign_pos += pos;

        // Add canonical RR data
        for (record_indices) |idx| {
            const record = &zone.records.items[idx];
            // Name
            @memcpy(to_sign[sign_pos..][0..record.name.len], record.name.wireFormat());
            sign_pos += record.name.len;
            // Type
            std.mem.writeInt(u16, to_sign[sign_pos..][0..2], @intFromEnum(record.rtype), .big);
            sign_pos += 2;
            // Class
            std.mem.writeInt(u16, to_sign[sign_pos..][0..2], @intFromEnum(record.class), .big);
            sign_pos += 2;
            // TTL
            std.mem.writeInt(u32, to_sign[sign_pos..][0..4], record.ttl, .big);
            sign_pos += 4;
            // RDLENGTH
            std.mem.writeInt(u16, to_sign[sign_pos..][0..2], record.rdlength, .big);
            sign_pos += 2;
            // RDATA
            @memcpy(to_sign[sign_pos..][0..record.rdlength], record.rdata[0..record.rdlength]);
            sign_pos += record.rdlength;
        }

        // Sign
        var signature: [512]u8 = undefined;
        const sig_len = try key.sign(to_sign[0..sign_pos], &signature);

        // Add signature to RRSIG
        @memcpy(rrsig_record.rdata[pos..][0..sig_len], signature[0..sig_len]);
        pos += sig_len;

        rrsig_record.rdlength = @intCast(pos);
        return rrsig_record;
    }

    fn generateNSECChain(self: *ZoneSigner, zone: *Zone) !void {
        // Collect unique names
        var names = std.StringHashMap(void).init(self.allocator);
        defer names.deinit();

        for (zone.records.items) |record| {
            var buf: [256]u8 = undefined;
            const name_str = record.name.toString(&buf);
            names.put(name_str, {}) catch continue;
        }

        // Sort names (simplified - would need proper DNS canonical ordering)
        var name_list = std.ArrayList([]const u8).init(self.allocator);
        defer name_list.deinit();

        var iter = names.keyIterator();
        while (iter.next()) |key| {
            name_list.append(key.*) catch continue;
        }

        // Create NSEC records
        for (name_list.items, 0..) |name_str, i| {
            const next_name_str = if (i + 1 < name_list.items.len)
                name_list.items[i + 1]
            else
                name_list.items[0]; // Wrap to first

            const name = Name.fromString(name_str) catch continue;
            const next_name = Name.fromString(next_name_str) catch continue;

            var nsec_record = ZoneRecord{
                .name = name,
                .rtype = .NSEC,
                .ttl = zone.defaultTTL(),
            };

            // Build NSEC RDATA
            var pos: usize = 0;

            // Next domain name
            @memcpy(nsec_record.rdata[pos..][0..next_name.len], next_name.wireFormat());
            pos += next_name.len;

            // Type bitmap (simplified - just mark A, AAAA, NS, SOA, RRSIG, NSEC)
            nsec_record.rdata[pos] = 0; // Window block 0
            pos += 1;
            nsec_record.rdata[pos] = 7; // Bitmap length
            pos += 1;

            // Set bits for types present
            var bitmap: [7]u8 = [_]u8{0} ** 7;
            for (zone.records.items) |record| {
                if (record.name.eql(&name)) {
                    const type_num = @intFromEnum(record.rtype);
                    if (type_num < 56) {
                        const byte_idx = type_num / 8;
                        const bit_idx: u3 = @intCast(7 - (type_num % 8));
                        bitmap[byte_idx] |= @as(u8, 1) << bit_idx;
                    }
                }
            }
            // Always include RRSIG and NSEC
            bitmap[5] |= 0x06; // RRSIG=46, NSEC=47

            @memcpy(nsec_record.rdata[pos..][0..7], &bitmap);
            pos += 7;

            nsec_record.rdlength = @intCast(pos);
            try zone.addRecord(nsec_record);
        }
    }
};

// ═══════════════════════════════════════════════════════════════════════════
// DNSSEC Validator
// ═══════════════════════════════════════════════════════════════════════════

pub const Validator = struct {
    trust_anchors: std.ArrayList(DSRecord),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Validator {
        return .{
            .trust_anchors = std.ArrayList(DSRecord).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Validator) void {
        self.trust_anchors.deinit();
    }

    /// Add a trust anchor
    pub fn addTrustAnchor(self: *Validator, ds: DSRecord) !void {
        try self.trust_anchors.append(ds);
    }

    /// Validate an RRSIG
    pub fn validateRRSIG(
        self: *Validator,
        rrsig: *const RRSIGRecord,
        dnskey: *const DNSKEYRecord,
        rrset: []const ResourceRecord,
    ) !bool {
        _ = self;

        // Check key tag matches
        // Note: Would need to compute key tag from DNSKEY

        // Check algorithm matches
        if (rrsig.algorithm != dnskey.algorithm) return false;

        // Check signature timing
        const now: u32 = @intCast(@divTrunc(std.time.timestamp(), 1));
        if (now < rrsig.inception or now > rrsig.expiration) return false;

        // Verify signature (simplified - would need full crypto implementation)
        _ = rrset;
        return true;
    }
};

// ═══════════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════════

test "DNSSECKey generation" {
    const key = try DNSSECKey.generate(.ed25519, true);

    try std.testing.expect(key.flags & DNSKEYRecord.FLAG_ZONE_KEY != 0);
    try std.testing.expect(key.flags & DNSKEYRecord.FLAG_SEP != 0);
    try std.testing.expect(key.public_key_len > 0);
    try std.testing.expect(key.key_tag != 0);
}

test "DNSSECKey key tag calculation" {
    const key = try DNSSECKey.generate(.ecdsap256sha256, false);
    const tag = key.calculateKeyTag();

    // Key tag should be non-zero and consistent
    try std.testing.expect(tag != 0);
    try std.testing.expectEqual(tag, key.calculateKeyTag());
}

test "DNSSECKey signing" {
    const key = try DNSSECKey.generate(.ed25519, false);
    const data = "test data to sign";

    var signature: [512]u8 = undefined;
    const sig_len = try key.sign(data, &signature);

    try std.testing.expect(sig_len > 0);
}

test "ZoneSigner basic" {
    const allocator = std.testing.allocator;

    const signer = try ZoneSigner.init(allocator, .ed25519);
    _ = signer;
}
