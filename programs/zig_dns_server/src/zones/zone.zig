//! ═══════════════════════════════════════════════════════════════════════════
//! DNS Zone Management
//! ═══════════════════════════════════════════════════════════════════════════
//!
//! Zone storage and lookup with support for:
//! • RFC 1035 zone file format parsing
//! • Hot reload via file watching
//! • DNSSEC signing integration
//! • Wildcard record support
//!

const std = @import("std");
const types = @import("../protocol/types.zig");

/// Simple mutex wrapper using pthread (Mutex removed in Zig 0.16)
const Mutex = struct {
    inner: std.c.pthread_mutex_t = std.c.PTHREAD_MUTEX_INITIALIZER,

    pub fn lock(self: *Mutex) void {
        _ = std.c.pthread_mutex_lock(&self.inner);
    }

    pub fn unlock(self: *Mutex) void {
        _ = std.c.pthread_mutex_unlock(&self.inner);
    }
};

const Name = types.Name;
const RecordType = types.RecordType;
const Class = types.Class;
const ResourceRecord = types.ResourceRecord;
const SOARecord = types.SOARecord;

/// Maximum records per zone
pub const MAX_RECORDS_PER_ZONE = 65536;
/// Maximum zones
pub const MAX_ZONES = 256;

// ═══════════════════════════════════════════════════════════════════════════
// Zone Record Entry
// ═══════════════════════════════════════════════════════════════════════════

/// A DNS record entry in a zone
pub const ZoneRecord = struct {
    name: Name,
    rtype: RecordType,
    class: Class = .IN,
    ttl: u32,
    rdata: [types.RDATA_BUFFER_SIZE]u8 = undefined,
    rdlength: u16 = 0,

    /// Convert to ResourceRecord for response
    pub fn toResourceRecord(self: *const ZoneRecord) ResourceRecord {
        var rr = ResourceRecord{
            .name = self.name,
            .rtype = self.rtype,
            .class = self.class,
            .ttl = self.ttl,
            .rdlength = self.rdlength,
        };
        @memcpy(rr.rdata[0..self.rdlength], self.rdata[0..self.rdlength]);
        return rr;
    }
};

// ═══════════════════════════════════════════════════════════════════════════
// Zone
// ═══════════════════════════════════════════════════════════════════════════

/// DNS Zone
pub const Zone = struct {
    allocator: std.mem.Allocator,

    /// Zone origin (e.g., "example.com")
    origin: Name,

    /// SOA record
    soa: ?SOARecord = null,

    /// All records in the zone
    records: std.ArrayListUnmanaged(ZoneRecord) = .empty,

    /// Zone file path for hot reload
    file_path: ?[]const u8 = null,

    /// Last modification time
    last_modified: i128 = 0,

    /// DNSSEC enabled
    dnssec_enabled: bool = false,

    pub fn init(allocator: std.mem.Allocator, origin: Name) Zone {
        return .{
            .allocator = allocator,
            .origin = origin,
            .records = .empty,
        };
    }

    pub fn deinit(self: *Zone) void {
        self.records.deinit(self.allocator);
        if (self.file_path) |path| {
            self.allocator.free(path);
        }
    }

    /// Add a record to the zone
    pub fn addRecord(self: *Zone, record: ZoneRecord) !void {
        try self.records.append(self.allocator, record);

        // Extract SOA if this is one
        if (record.rtype == .SOA) {
            self.soa = parseSOAFromRdata(record.rdata[0..record.rdlength]);
        }
    }

    /// Find records matching name and type
    pub fn findRecords(
        self: *const Zone,
        name: *const Name,
        rtype: RecordType,
        results: []ResourceRecord,
    ) usize {
        var count: usize = 0;

        for (self.records.items) |*record| {
            if (count >= results.len) break;

            // Check type match (ANY matches all)
            const type_match = (rtype == .ANY or record.rtype == rtype);
            if (!type_match) continue;

            // Check name match (exact or wildcard)
            if (record.name.eql(name)) {
                results[count] = record.toResourceRecord();
                count += 1;
            } else if (self.isWildcardMatch(record, name)) {
                var rr = record.toResourceRecord();
                rr.name = name.*; // Replace wildcard with queried name
                results[count] = rr;
                count += 1;
            }
        }

        return count;
    }

    /// Find NS records for the zone
    pub fn findNS(self: *const Zone, results: []ResourceRecord) usize {
        return self.findRecords(&self.origin, .NS, results);
    }

    /// Check if a name exists in the zone
    pub fn nameExists(self: *const Zone, name: *const Name) bool {
        for (self.records.items) |*record| {
            if (record.name.eql(name)) return true;
        }
        return false;
    }

    /// Check for wildcard match
    fn isWildcardMatch(self: *const Zone, record: *const ZoneRecord, name: *const Name) bool {
        _ = self;

        // Wildcard records start with "*."
        if (record.name.len < 2) return false;
        if (record.name.data[0] != 1 or record.name.data[1] != '*') return false;

        // Get the parent domain from the wildcard (skip "*.")
        const wildcard_parent_start: usize = 2;
        const wildcard_parent = record.name.data[wildcard_parent_start..record.name.len];

        // Check if queried name ends with the wildcard parent
        if (name.len < wildcard_parent.len) return false;
        const name_suffix_start = name.len - wildcard_parent.len;

        for (wildcard_parent, 0..) |b, i| {
            if (std.ascii.toLower(name.data[name_suffix_start + i]) != std.ascii.toLower(b)) {
                return false;
            }
        }

        return true;
    }

    /// Get the SOA record
    pub fn getSOA(self: *const Zone) ?ResourceRecord {
        for (self.records.items) |*record| {
            if (record.rtype == .SOA and record.name.eql(&self.origin)) {
                return record.toResourceRecord();
            }
        }
        return null;
    }

    /// Get default TTL from SOA
    pub fn defaultTTL(self: *const Zone) u32 {
        if (self.soa) |soa| {
            return soa.minimum;
        }
        return 3600; // 1 hour default
    }
};

// ═══════════════════════════════════════════════════════════════════════════
// Zone File Parser
// ═══════════════════════════════════════════════════════════════════════════

pub const ZoneParser = struct {
    allocator: std.mem.Allocator,
    origin: Name,
    default_ttl: u32 = 3600,
    current_name: Name = Name{},

    pub fn init(allocator: std.mem.Allocator, origin: Name) ZoneParser {
        return .{
            .allocator = allocator,
            .origin = origin,
            .current_name = origin,
        };
    }

    /// Parse a zone file
    pub fn parseFile(self: *ZoneParser, path: []const u8) !Zone {
        var io_impl = std.Io.Threaded.init(self.allocator, .{
            .environ = .{ .block = .{ .slice = @ptrCast(std.mem.span(std.c.environ)) } },
        });
        defer io_impl.deinit();
        const io = io_impl.io();

        const content = try std.Io.Dir.cwd().readFileAlloc(io, path, self.allocator, .limited(10 * 1024 * 1024));
        defer self.allocator.free(content);

        var zone = Zone.init(self.allocator, self.origin);
        zone.file_path = try self.allocator.dupe(u8, path);

        try self.parseContent(content, &zone);

        return zone;
    }

    /// Parse zone file content
    pub fn parseContent(self: *ZoneParser, content: []const u8, zone: *Zone) !void {
        var lines = std.mem.splitScalar(u8, content, '\n');

        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");

            // Skip empty lines and comments
            if (trimmed.len == 0) continue;
            if (trimmed[0] == ';') continue;

            // Handle directives
            if (trimmed[0] == '$') {
                try self.parseDirective(trimmed, zone);
                continue;
            }

            // Parse record
            if (self.parseRecord(trimmed)) |record| {
                try zone.addRecord(record);
            } else |_| {
                // Log parse error but continue
                continue;
            }
        }
    }

    fn parseDirective(self: *ZoneParser, line: []const u8, zone: *Zone) !void {
        var tokens = std.mem.tokenizeAny(u8, line, " \t");

        const directive = tokens.next() orelse return;

        if (std.mem.eql(u8, directive, "$ORIGIN")) {
            if (tokens.next()) |origin_str| {
                self.origin = try Name.fromString(origin_str);
                self.current_name = self.origin;
                // Update zone origin
                zone.origin = self.origin;
            }
        } else if (std.mem.eql(u8, directive, "$TTL")) {
            if (tokens.next()) |ttl_str| {
                self.default_ttl = try parseTTL(ttl_str);
            }
        }
        // $INCLUDE not supported in this basic implementation
    }

    fn parseRecord(self: *ZoneParser, line: []const u8) !ZoneRecord {
        var tokens = std.mem.tokenizeAny(u8, line, " \t");

        // First token could be name, TTL, or class
        const first = tokens.next() orelse return error.InvalidRecord;

        var record = ZoneRecord{
            .name = self.current_name,
            .rtype = .A,
            .ttl = self.default_ttl,
        };

        var token_idx: usize = 0;
        var current_token = first;

        while (true) {
            // Try to parse as TTL
            if (parseTTL(current_token)) |ttl| {
                record.ttl = ttl;
            } else |_| {
                // Try to parse as class
                if (parseClass(current_token)) |class| {
                    record.class = class;
                } else |_| {
                    // Try to parse as record type
                    if (parseRecordType(current_token)) |rtype| {
                        record.rtype = rtype;
                        // Rest is RDATA
                        break;
                    } else |_| {
                        // Must be a name (only valid for first token)
                        if (token_idx == 0) {
                            record.name = try self.resolveName(current_token);
                            self.current_name = record.name;
                        } else {
                            return error.InvalidRecord;
                        }
                    }
                }
            }

            token_idx += 1;
            current_token = tokens.next() orelse return error.InvalidRecord;
        }

        // Parse RDATA based on record type
        const rdata_start = tokens.index;
        const remaining = if (rdata_start < line.len) line[rdata_start..] else "";

        try self.parseRdata(record.rtype, std.mem.trim(u8, remaining, " \t"), &record);

        return record;
    }

    fn resolveName(self: *ZoneParser, name_str: []const u8) !Name {
        if (name_str.len == 1 and name_str[0] == '@') {
            return self.origin;
        }

        // Check if FQDN (ends with .)
        if (name_str.len > 0 and name_str[name_str.len - 1] == '.') {
            return Name.fromString(name_str);
        }

        // Relative name - append origin
        var buf: [types.MAX_NAME_LENGTH * 2]u8 = undefined;
        var name_buf: [256]u8 = undefined;
        const origin_str = self.origin.toString(&name_buf);

        const full_name = std.fmt.bufPrint(&buf, "{s}.{s}", .{ name_str, origin_str }) catch return error.NameTooLong;
        return Name.fromString(full_name);
    }

    fn parseRdata(self: *ZoneParser, rtype: RecordType, rdata_str: []const u8, record: *ZoneRecord) !void {
        switch (rtype) {
            .A => {
                const addr = try parseIPv4(rdata_str);
                @memcpy(record.rdata[0..4], &addr);
                record.rdlength = 4;
            },
            .AAAA => {
                const addr = try parseIPv6(rdata_str);
                @memcpy(record.rdata[0..16], &addr);
                record.rdlength = 16;
            },
            .NS, .CNAME, .PTR => {
                const name = try self.resolveName(rdata_str);
                @memcpy(record.rdata[0..name.len], name.wireFormat());
                record.rdlength = name.len;
            },
            .MX => {
                var parts = std.mem.tokenizeAny(u8, rdata_str, " \t");
                const pref_str = parts.next() orelse return error.InvalidRdata;
                const exchange_str = parts.next() orelse return error.InvalidRdata;

                const preference = std.fmt.parseInt(u16, pref_str, 10) catch return error.InvalidRdata;
                const exchange = try self.resolveName(exchange_str);

                std.mem.writeInt(u16, record.rdata[0..2], preference, .big);
                @memcpy(record.rdata[2..][0..exchange.len], exchange.wireFormat());
                record.rdlength = @intCast(2 + exchange.len);
            },
            .TXT => {
                // Remove quotes if present
                var text = rdata_str;
                if (text.len >= 2 and text[0] == '"' and text[text.len - 1] == '"') {
                    text = text[1 .. text.len - 1];
                }

                if (text.len > 255) return error.InvalidRdata;
                record.rdata[0] = @intCast(text.len);
                @memcpy(record.rdata[1..][0..text.len], text);
                record.rdlength = @intCast(1 + text.len);
            },
            .SOA => {
                try self.parseSOA(rdata_str, record);
            },
            .SRV => {
                try self.parseSRV(rdata_str, record);
            },
            .CAA => {
                try self.parseCAA(rdata_str, record);
            },
            else => {
                // Unknown type - store raw
                if (rdata_str.len > types.RDATA_BUFFER_SIZE) return error.InvalidRdata;
                @memcpy(record.rdata[0..rdata_str.len], rdata_str);
                record.rdlength = @intCast(rdata_str.len);
            },
        }
    }

    fn parseSOA(self: *ZoneParser, rdata_str: []const u8, record: *ZoneRecord) !void {
        var parts = std.mem.tokenizeAny(u8, rdata_str, " \t");

        const mname_str = parts.next() orelse return error.InvalidRdata;
        const rname_str = parts.next() orelse return error.InvalidRdata;
        const serial_str = parts.next() orelse return error.InvalidRdata;
        const refresh_str = parts.next() orelse return error.InvalidRdata;
        const retry_str = parts.next() orelse return error.InvalidRdata;
        const expire_str = parts.next() orelse return error.InvalidRdata;
        const minimum_str = parts.next() orelse return error.InvalidRdata;

        const mname = try self.resolveName(mname_str);
        const rname = try self.resolveName(rname_str);

        var pos: usize = 0;
        @memcpy(record.rdata[pos..][0..mname.len], mname.wireFormat());
        pos += mname.len;
        @memcpy(record.rdata[pos..][0..rname.len], rname.wireFormat());
        pos += rname.len;

        std.mem.writeInt(u32, record.rdata[pos..][0..4], std.fmt.parseInt(u32, serial_str, 10) catch return error.InvalidRdata, .big);
        pos += 4;
        std.mem.writeInt(u32, record.rdata[pos..][0..4], try parseTTL(refresh_str), .big);
        pos += 4;
        std.mem.writeInt(u32, record.rdata[pos..][0..4], try parseTTL(retry_str), .big);
        pos += 4;
        std.mem.writeInt(u32, record.rdata[pos..][0..4], try parseTTL(expire_str), .big);
        pos += 4;
        std.mem.writeInt(u32, record.rdata[pos..][0..4], try parseTTL(minimum_str), .big);
        pos += 4;

        record.rdlength = @intCast(pos);
    }

    fn parseSRV(self: *ZoneParser, rdata_str: []const u8, record: *ZoneRecord) !void {
        var parts = std.mem.tokenizeAny(u8, rdata_str, " \t");

        const priority_str = parts.next() orelse return error.InvalidRdata;
        const weight_str = parts.next() orelse return error.InvalidRdata;
        const port_str = parts.next() orelse return error.InvalidRdata;
        const target_str = parts.next() orelse return error.InvalidRdata;

        const target = try self.resolveName(target_str);

        var pos: usize = 0;
        std.mem.writeInt(u16, record.rdata[pos..][0..2], std.fmt.parseInt(u16, priority_str, 10) catch return error.InvalidRdata, .big);
        pos += 2;
        std.mem.writeInt(u16, record.rdata[pos..][0..2], std.fmt.parseInt(u16, weight_str, 10) catch return error.InvalidRdata, .big);
        pos += 2;
        std.mem.writeInt(u16, record.rdata[pos..][0..2], std.fmt.parseInt(u16, port_str, 10) catch return error.InvalidRdata, .big);
        pos += 2;
        @memcpy(record.rdata[pos..][0..target.len], target.wireFormat());
        pos += target.len;

        record.rdlength = @intCast(pos);
    }

    fn parseCAA(self: *ZoneParser, rdata_str: []const u8, record: *ZoneRecord) !void {
        _ = self;
        var parts = std.mem.tokenizeAny(u8, rdata_str, " \t");

        const flags_str = parts.next() orelse return error.InvalidRdata;
        const tag = parts.next() orelse return error.InvalidRdata;
        const value_part = parts.rest();

        var value = value_part;
        if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"') {
            value = value[1 .. value.len - 1];
        }

        var pos: usize = 0;
        record.rdata[pos] = std.fmt.parseInt(u8, flags_str, 10) catch return error.InvalidRdata;
        pos += 1;
        record.rdata[pos] = @intCast(tag.len);
        pos += 1;
        @memcpy(record.rdata[pos..][0..tag.len], tag);
        pos += tag.len;
        @memcpy(record.rdata[pos..][0..value.len], value);
        pos += value.len;

        record.rdlength = @intCast(pos);
    }
};

// ═══════════════════════════════════════════════════════════════════════════
// Zone Store (Multi-Zone Management)
// ═══════════════════════════════════════════════════════════════════════════

/// Store for multiple zones
pub const ZoneStore = struct {
    allocator: std.mem.Allocator,
    zones: std.ArrayListUnmanaged(Zone) = .empty,
    mutex: Mutex = .{},

    pub fn init(allocator: std.mem.Allocator) ZoneStore {
        return .{
            .allocator = allocator,
            .zones = .empty,
        };
    }

    pub fn deinit(self: *ZoneStore) void {
        for (self.zones.items) |*zone| {
            zone.deinit();
        }
        self.zones.deinit(self.allocator);
    }

    /// Add a zone
    pub fn addZone(self: *ZoneStore, zone: Zone) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.zones.append(self.allocator, zone);
    }

    /// Load a zone from file
    pub fn loadFromFile(self: *ZoneStore, path: []const u8) !*Zone {
        var parser = ZoneParser.init(self.allocator, Name{});
        const zone = try parser.parseFile(path);
        try self.addZone(zone);
        return &self.zones.items[self.zones.items.len - 1];
    }

    /// Load a zone from file with explicit origin
    pub fn loadZone(self: *ZoneStore, path: []const u8, origin: Name) !void {
        var parser = ZoneParser.init(self.allocator, origin);
        const zone = try parser.parseFile(path);
        try self.addZone(zone);
    }

    /// Find the best matching zone for a name
    pub fn findZone(self: *ZoneStore, name: *const Name) ?*Zone {
        self.mutex.lock();
        defer self.mutex.unlock();

        var best_match: ?*Zone = null;
        var best_match_labels: u8 = 0;

        for (self.zones.items) |*zone| {
            if (name.isSubdomainOf(&zone.origin)) {
                const labels = zone.origin.labelCount();
                if (labels > best_match_labels) {
                    best_match = zone;
                    best_match_labels = labels;
                }
            }
        }

        return best_match;
    }

    /// Reload zones that have changed
    pub fn reloadChanged(self: *ZoneStore) !usize {
        self.mutex.lock();
        defer self.mutex.unlock();

        var reloaded: usize = 0;

        for (self.zones.items) |*zone| {
            if (zone.file_path) |path| {
                const stat = std.Io.Dir.cwd().statFile(path) catch continue;
                const mtime = stat.mtime;

                if (mtime > zone.last_modified) {
                    // Reload zone
                    var parser = ZoneParser.init(self.allocator, zone.origin);
                    var new_zone = parser.parseFile(path) catch continue;
                    new_zone.last_modified = mtime;

                    // Swap zones
                    zone.deinit();
                    zone.* = new_zone;
                    reloaded += 1;
                }
            }
        }

        return reloaded;
    }
};

// ═══════════════════════════════════════════════════════════════════════════
// Helper Functions
// ═══════════════════════════════════════════════════════════════════════════

fn parseTTL(s: []const u8) !u32 {
    if (s.len == 0) return error.InvalidTTL;

    var value: u32 = 0;
    var num_start: usize = 0;

    for (s, 0..) |c, i| {
        switch (c) {
            '0'...'9' => {},
            's', 'S' => {
                const num = std.fmt.parseInt(u32, s[num_start..i], 10) catch return error.InvalidTTL;
                value += num;
                num_start = i + 1;
            },
            'm', 'M' => {
                const num = std.fmt.parseInt(u32, s[num_start..i], 10) catch return error.InvalidTTL;
                value += num * 60;
                num_start = i + 1;
            },
            'h', 'H' => {
                const num = std.fmt.parseInt(u32, s[num_start..i], 10) catch return error.InvalidTTL;
                value += num * 3600;
                num_start = i + 1;
            },
            'd', 'D' => {
                const num = std.fmt.parseInt(u32, s[num_start..i], 10) catch return error.InvalidTTL;
                value += num * 86400;
                num_start = i + 1;
            },
            'w', 'W' => {
                const num = std.fmt.parseInt(u32, s[num_start..i], 10) catch return error.InvalidTTL;
                value += num * 604800;
                num_start = i + 1;
            },
            else => return error.InvalidTTL,
        }
    }

    // Parse remaining number
    if (num_start < s.len) {
        value += std.fmt.parseInt(u32, s[num_start..], 10) catch return error.InvalidTTL;
    }

    return value;
}

fn parseClass(s: []const u8) !Class {
    if (std.ascii.eqlIgnoreCase(s, "IN")) return .IN;
    if (std.ascii.eqlIgnoreCase(s, "CH")) return .CH;
    if (std.ascii.eqlIgnoreCase(s, "HS")) return .HS;
    return error.InvalidClass;
}

fn parseRecordType(s: []const u8) !RecordType {
    if (std.ascii.eqlIgnoreCase(s, "A")) return .A;
    if (std.ascii.eqlIgnoreCase(s, "AAAA")) return .AAAA;
    if (std.ascii.eqlIgnoreCase(s, "NS")) return .NS;
    if (std.ascii.eqlIgnoreCase(s, "CNAME")) return .CNAME;
    if (std.ascii.eqlIgnoreCase(s, "SOA")) return .SOA;
    if (std.ascii.eqlIgnoreCase(s, "PTR")) return .PTR;
    if (std.ascii.eqlIgnoreCase(s, "MX")) return .MX;
    if (std.ascii.eqlIgnoreCase(s, "TXT")) return .TXT;
    if (std.ascii.eqlIgnoreCase(s, "SRV")) return .SRV;
    if (std.ascii.eqlIgnoreCase(s, "CAA")) return .CAA;
    if (std.ascii.eqlIgnoreCase(s, "DNSKEY")) return .DNSKEY;
    if (std.ascii.eqlIgnoreCase(s, "DS")) return .DS;
    if (std.ascii.eqlIgnoreCase(s, "RRSIG")) return .RRSIG;
    if (std.ascii.eqlIgnoreCase(s, "NSEC")) return .NSEC;
    if (std.ascii.eqlIgnoreCase(s, "NSEC3")) return .NSEC3;
    if (std.ascii.eqlIgnoreCase(s, "NSEC3PARAM")) return .NSEC3PARAM;
    return error.InvalidRecordType;
}

fn parseIPv4(s: []const u8) ![4]u8 {
    var result: [4]u8 = undefined;
    var parts = std.mem.splitScalar(u8, s, '.');
    var i: usize = 0;

    while (parts.next()) |part| {
        if (i >= 4) return error.InvalidIPv4;
        result[i] = std.fmt.parseInt(u8, part, 10) catch return error.InvalidIPv4;
        i += 1;
    }

    if (i != 4) return error.InvalidIPv4;
    return result;
}

fn parseIPv6(s: []const u8) ![16]u8 {
    var result: [16]u8 = [_]u8{0} ** 16;

    // Handle :: expansion
    if (std.mem.indexOf(u8, s, "::")) |double_colon| {
        // Parse before ::
        var pos: usize = 0;
        if (double_colon > 0) {
            var before = std.mem.splitScalar(u8, s[0..double_colon], ':');
            while (before.next()) |part| {
                if (pos >= 14) return error.InvalidIPv6;
                const val = std.fmt.parseInt(u16, part, 16) catch return error.InvalidIPv6;
                result[pos] = @truncate(val >> 8);
                result[pos + 1] = @truncate(val);
                pos += 2;
            }
        }

        // Parse after ::
        var after_parts: [8][]const u8 = undefined;
        var after_count: usize = 0;
        if (double_colon + 2 < s.len) {
            var after = std.mem.splitScalar(u8, s[double_colon + 2 ..], ':');
            while (after.next()) |part| {
                if (after_count >= 8) return error.InvalidIPv6;
                after_parts[after_count] = part;
                after_count += 1;
            }
        }

        // Fill from end
        var end_pos: usize = 16;
        var i: usize = after_count;
        while (i > 0) {
            i -= 1;
            if (end_pos < 2) return error.InvalidIPv6;
            end_pos -= 2;
            const val = std.fmt.parseInt(u16, after_parts[i], 16) catch return error.InvalidIPv6;
            result[end_pos] = @truncate(val >> 8);
            result[end_pos + 1] = @truncate(val);
        }
    } else {
        // No ::, parse all 8 groups
        var parts = std.mem.splitScalar(u8, s, ':');
        var pos: usize = 0;

        while (parts.next()) |part| {
            if (pos >= 16) return error.InvalidIPv6;
            const val = std.fmt.parseInt(u16, part, 16) catch return error.InvalidIPv6;
            result[pos] = @truncate(val >> 8);
            result[pos + 1] = @truncate(val);
            pos += 2;
        }

        if (pos != 16) return error.InvalidIPv6;
    }

    return result;
}

fn parseSOAFromRdata(rdata: []const u8) ?SOARecord {
    var pos: usize = 0;

    // Parse MNAME
    const mname = parseName(rdata, &pos) orelse return null;
    // Parse RNAME
    const rname = parseName(rdata, &pos) orelse return null;

    // Need 20 bytes for 5 x u32
    if (pos + 20 > rdata.len) return null;

    const serial = std.mem.readInt(u32, rdata[pos..][0..4], .big);
    pos += 4;
    const refresh = std.mem.readInt(u32, rdata[pos..][0..4], .big);
    pos += 4;
    const retry = std.mem.readInt(u32, rdata[pos..][0..4], .big);
    pos += 4;
    const expire = std.mem.readInt(u32, rdata[pos..][0..4], .big);
    pos += 4;
    const minimum = std.mem.readInt(u32, rdata[pos..][0..4], .big);

    return SOARecord{
        .mname = mname,
        .rname = rname,
        .serial = serial,
        .refresh = refresh,
        .retry = retry,
        .expire = expire,
        .minimum = minimum,
    };
}

/// Parse a DNS wire-format name from RDATA at the given position.
/// Wire format: sequence of (length, label_bytes...) terminated by 0 byte.
fn parseName(data: []const u8, pos: *usize) ?Name {
    var name = Name{};
    var name_pos: usize = 0;

    while (pos.* < data.len) {
        const label_len = data[pos.*];
        pos.* += 1;

        if (label_len == 0) {
            // End of name
            if (name_pos < name.data.len) {
                name.data[name_pos] = 0;
                name_pos += 1;
            }
            name.len = @intCast(name_pos);
            return name;
        }

        // Check bounds
        if (pos.* + label_len > data.len) return null;
        if (name_pos + 1 + label_len > name.data.len) return null;

        // Copy label (length prefix + label bytes)
        name.data[name_pos] = label_len;
        name_pos += 1;
        @memcpy(name.data[name_pos..][0..label_len], data[pos.*..][0..label_len]);
        name_pos += label_len;
        pos.* += label_len;
    }

    return null; // Ran out of data before finding terminator
}

// ═══════════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════════

test "parseTTL" {
    try std.testing.expectEqual(@as(u32, 3600), try parseTTL("3600"));
    try std.testing.expectEqual(@as(u32, 3600), try parseTTL("1h"));
    try std.testing.expectEqual(@as(u32, 86400), try parseTTL("1d"));
    try std.testing.expectEqual(@as(u32, 604800), try parseTTL("1w"));
    try std.testing.expectEqual(@as(u32, 90061), try parseTTL("1d1h1m1s"));
}

test "parseIPv4" {
    const addr = try parseIPv4("192.168.1.1");
    try std.testing.expectEqual([_]u8{ 192, 168, 1, 1 }, addr);
}

test "parseIPv6" {
    const addr1 = try parseIPv6("2001:db8::1");
    try std.testing.expectEqual(@as(u8, 0x20), addr1[0]);
    try std.testing.expectEqual(@as(u8, 0x01), addr1[1]);
    try std.testing.expectEqual(@as(u8, 0x01), addr1[15]);

    const addr2 = try parseIPv6("::1");
    try std.testing.expectEqual(@as(u8, 0x01), addr2[15]);
}

test "Zone basic operations" {
    const allocator = std.testing.allocator;
    const origin = try Name.fromString("example.com");

    var zone = Zone.init(allocator, origin);
    defer zone.deinit();

    // Add A record
    var record = ZoneRecord{
        .name = try Name.fromString("www.example.com"),
        .rtype = .A,
        .ttl = 3600,
    };
    @memcpy(record.rdata[0..4], &[_]u8{ 192, 168, 1, 1 });
    record.rdlength = 4;

    try zone.addRecord(record);

    // Find record
    var results: [16]ResourceRecord = undefined;
    const name = try Name.fromString("www.example.com");
    const count = zone.findRecords(&name, .A, &results);

    try std.testing.expectEqual(@as(usize, 1), count);
}
