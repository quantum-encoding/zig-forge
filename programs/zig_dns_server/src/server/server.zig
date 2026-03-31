//! ═══════════════════════════════════════════════════════════════════════════
//! DNS Server Core
//! ═══════════════════════════════════════════════════════════════════════════
//!
//! High-performance authoritative DNS server supporting:
//! • UDP and TCP transports
//! • Multi-threaded query processing
//! • Rate limiting and DDoS protection
//! • Response caching
//!

const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;
const posix = std.posix;
const types = @import("../protocol/types.zig");
const parser = @import("../protocol/parser.zig");
const zone_mod = @import("../zones/zone.zig");

// Cross-platform socket wrapper functions for Zig 0.16
fn createSocket(sock_type: u32) !posix.fd_t {
    switch (builtin.os.tag) {
        .linux => {
            const result = linux.socket(linux.AF.INET, sock_type, 0);
            if (@as(isize, @bitCast(result)) < 0) return error.SocketCreationFailed;
            return @intCast(result);
        },
        else => {
            // macOS and others use std.c
            const fd = std.c.socket(std.c.AF.INET, sock_type, 0);
            if (fd < 0) return error.SocketCreationFailed;
            return fd;
        },
    }
}

fn bindSocket(sock: posix.fd_t, addr: *const posix.sockaddr.in) !void {
    switch (builtin.os.tag) {
        .linux => {
            const result = linux.bind(@intCast(sock), @ptrCast(addr), @sizeOf(posix.sockaddr.in));
            if (@as(isize, @bitCast(result)) < 0) return error.BindFailed;
        },
        else => {
            if (std.c.bind(sock, @ptrCast(addr), @sizeOf(posix.sockaddr.in)) < 0) return error.BindFailed;
        },
    }
}

fn listenSocket(sock: posix.fd_t, backlog: u31) !void {
    switch (builtin.os.tag) {
        .linux => {
            const result = linux.listen(@intCast(sock), backlog);
            if (@as(isize, @bitCast(result)) < 0) return error.ListenFailed;
        },
        else => {
            if (std.c.listen(sock, backlog) < 0) return error.ListenFailed;
        },
    }
}

fn setsockoptReuseAddr(sock: posix.fd_t) void {
    const enable: c_int = 1;
    switch (builtin.os.tag) {
        .linux => {
            _ = linux.setsockopt(
                @intCast(sock),
                linux.SOL.SOCKET,
                linux.SO.REUSEADDR,
                std.mem.asBytes(&enable),
                @sizeOf(c_int),
            );
        },
        else => {
            _ = std.c.setsockopt(
                sock,
                std.c.SOL.SOCKET,
                std.c.SO.REUSEADDR,
                std.mem.asBytes(&enable),
                @sizeOf(c_int),
            );
        },
    }
}

fn recvFrom(sock: posix.fd_t, buf: []u8, addr: *posix.sockaddr, addr_len: *posix.socklen_t) !usize {
    switch (builtin.os.tag) {
        .linux => {
            const result = linux.recvfrom(@intCast(sock), buf.ptr, buf.len, 0, @ptrCast(@alignCast(addr)), addr_len);
            const n: isize = @bitCast(result);
            if (n < 0) return error.RecvFailed;
            return @intCast(result);
        },
        else => {
            const result = std.c.recvfrom(sock, buf.ptr, buf.len, 0, @ptrCast(addr), addr_len);
            if (result < 0) return error.RecvFailed;
            return @intCast(result);
        },
    }
}

fn sendTo(sock: posix.fd_t, data: []const u8, addr: *const posix.sockaddr, addr_len: posix.socklen_t) !usize {
    switch (builtin.os.tag) {
        .linux => {
            const result = linux.sendto(@intCast(sock), data.ptr, data.len, 0, @ptrCast(@alignCast(addr)), addr_len);
            const n: isize = @bitCast(result);
            if (n < 0) return error.SendFailed;
            return @intCast(result);
        },
        else => {
            const result = std.c.sendto(sock, data.ptr, data.len, 0, @ptrCast(addr), addr_len);
            if (result < 0) return error.SendFailed;
            return @intCast(result);
        },
    }
}

const Header = types.Header;
const Name = types.Name;
const RecordType = types.RecordType;
const Class = types.Class;
const ResourceRecord = types.ResourceRecord;
const Rcode = types.Rcode;
const Message = parser.Message;
const Builder = parser.Builder;
const Zone = zone_mod.Zone;
const ZoneStore = zone_mod.ZoneStore;

// ═══════════════════════════════════════════════════════════════════════════
// Helper Functions
// ═══════════════════════════════════════════════════════════════════════════

fn parseAddr(addr_str: []const u8, port: u16) !std.posix.sockaddr.in {
    var ip: [4]u8 = undefined;
    var iter = std.mem.splitScalar(u8, addr_str, '.');
    var i: usize = 0;

    while (iter.next()) |part| : (i += 1) {
        if (i >= 4) return error.InvalidAddress;
        ip[i] = std.fmt.parseInt(u8, part, 10) catch return error.InvalidAddress;
    }
    if (i != 4) return error.InvalidAddress;

    return std.posix.sockaddr.in{
        .family = std.posix.AF.INET,
        .port = std.mem.nativeToBig(u16, port),
        .addr = std.mem.nativeToBig(u32, @as(u32, ip[0]) << 24 | @as(u32, ip[1]) << 16 | @as(u32, ip[2]) << 8 | @as(u32, ip[3])),
        .zero = .{ 0, 0, 0, 0, 0, 0, 0, 0 },
    };
}

// ═══════════════════════════════════════════════════════════════════════════
// Server Configuration
// ═══════════════════════════════════════════════════════════════════════════

pub const Config = struct {
    /// UDP listen address
    listen_addr: []const u8 = "0.0.0.0",
    /// UDP listen port
    port: u16 = 53,
    /// TCP listen port (0 = disabled)
    tcp_port: u16 = 53,
    /// Number of worker threads
    workers: u16 = 4,
    /// Maximum UDP response size
    max_udp_size: u16 = 512,
    /// Enable EDNS
    edns_enabled: bool = true,
    /// EDNS buffer size
    edns_buffer_size: u16 = 4096,
    /// Enable rate limiting
    rate_limit_enabled: bool = true,
    /// Queries per second limit per IP
    rate_limit_qps: u32 = 100,
    /// Enable response caching
    cache_enabled: bool = true,
    /// Cache size (number of entries)
    cache_size: u32 = 10000,
    /// Hot reload interval (seconds, 0 = disabled)
    reload_interval: u32 = 30,
};

// ═══════════════════════════════════════════════════════════════════════════
// Query Handler
// ═══════════════════════════════════════════════════════════════════════════

pub const QueryHandler = struct {
    zones: *ZoneStore,
    config: Config,

    pub fn init(zones: *ZoneStore, config: Config) QueryHandler {
        return .{
            .zones = zones,
            .config = config,
        };
    }

    /// Handle a DNS query and build response
    pub fn handleQuery(self: *QueryHandler, query_data: []const u8, response_buf: []u8) !usize {
        // Parse query
        const query = Message.parse(query_data) catch {
            return self.buildErrorResponse(response_buf, 0, .format_error);
        };

        if (!query.isQuery()) {
            return self.buildErrorResponse(response_buf, query.header.id, .format_error);
        }

        const question = query.firstQuestion() orelse {
            return self.buildErrorResponse(response_buf, query.header.id, .format_error);
        };

        // Find authoritative zone
        const zone = self.zones.findZone(&question.name) orelse {
            return self.buildErrorResponse(response_buf, query.header.id, .refused);
        };

        // Build response
        var builder = Builder.init(response_buf);

        // Response header
        const response_header = Header{
            .id = query.header.id,
            .flags = .{
                .qr = true, // Response
                .opcode = 0,
                .aa = true, // Authoritative
                .tc = false,
                .rd = query.header.flags.rd,
                .ra = false, // No recursion
                .z = false,
                .ad = false, // Will set if DNSSEC
                .cd = query.header.flags.cd,
                .rcode = 0, // Will update based on results
            },
            .qd_count = 1,
            .an_count = 0, // Will update
            .ns_count = 0, // Will update
            .ar_count = 0, // Will update
        };

        try builder.writeHeader(response_header);

        // Echo question
        try builder.writeQuestion(question.*);

        // Find answers
        var answers: [64]ResourceRecord = undefined;
        const answer_count = zone.findRecords(&question.name, question.qtype, &answers);

        // Handle CNAME chasing for non-CNAME queries
        var final_answers = answers;
        var final_count = answer_count;

        if (answer_count == 0 and question.qtype != .CNAME) {
            // Check for CNAME
            var cname_results: [1]ResourceRecord = undefined;
            const cname_count = zone.findRecords(&question.name, .CNAME, &cname_results);
            if (cname_count > 0) {
                final_answers[0] = cname_results[0];
                final_count = 1;

                // Chase CNAME chain to resolve target records
                // Extract target name from CNAME RDATA (wire-format domain name)
                var target_name = types.Name{};
                const rdlen = cname_results[0].rdlength;
                if (rdlen > 0 and rdlen <= target_name.data.len) {
                    @memcpy(target_name.data[0..rdlen], cname_results[0].rdata[0..rdlen]);
                    target_name.len = @intCast(rdlen);

                    // Look up the original query type at the CNAME target
                    // Follow up to 8 levels of CNAME to prevent loops
                    var chase_name = target_name;
                    var chase_depth: u8 = 0;
                    while (chase_depth < 8) : (chase_depth += 1) {
                        var target_results: [16]ResourceRecord = undefined;
                        const target_count = zone.findRecords(&chase_name, question.qtype, &target_results);
                        if (target_count > 0) {
                            // Found actual records at CNAME target
                            const space = final_answers.len - final_count;
                            const to_copy = @min(target_count, space);
                            for (0..to_copy) |j| {
                                final_answers[final_count] = target_results[j];
                                final_count += 1;
                            }
                            break;
                        }

                        // Check if target is another CNAME
                        var next_cname: [1]ResourceRecord = undefined;
                        const next_count = zone.findRecords(&chase_name, .CNAME, &next_cname);
                        if (next_count == 0) break;

                        // Add intermediate CNAME to answers
                        if (final_count < final_answers.len) {
                            final_answers[final_count] = next_cname[0];
                            final_count += 1;
                        }

                        // Follow to next CNAME target
                        const next_rdlen = next_cname[0].rdlength;
                        if (next_rdlen == 0 or next_rdlen > chase_name.data.len) break;
                        var next_name = types.Name{};
                        @memcpy(next_name.data[0..next_rdlen], next_cname[0].rdata[0..next_rdlen]);
                        next_name.len = @intCast(next_rdlen);
                        chase_name = next_name;
                    }
                }
            }
        }

        // Write answers
        for (final_answers[0..final_count]) |*rr| {
            try builder.writeRecord(rr.*);
        }

        // Get authority section (NS records)
        var ns_records: [8]ResourceRecord = undefined;
        var ns_count: usize = 0;

        if (final_count == 0) {
            // NXDOMAIN or NODATA - include SOA
            if (!zone.nameExists(&question.name)) {
                // NXDOMAIN
                if (zone.getSOA()) |soa| {
                    ns_records[0] = soa;
                    ns_count = 1;
                }
                // Update RCODE to NXDOMAIN
                response_buf[3] = (response_buf[3] & 0xF0) | @intFromEnum(Rcode.name_error);
            } else {
                // NODATA - name exists but no matching type
                if (zone.getSOA()) |soa| {
                    ns_records[0] = soa;
                    ns_count = 1;
                }
            }
        } else {
            // Include NS records
            ns_count = zone.findNS(&ns_records);
        }

        // Write authority
        for (ns_records[0..ns_count]) |*rr| {
            try builder.writeRecord(rr.*);
        }

        // Update counts in header
        // AN count at offset 6-7, NS count at offset 8-9, AR count at offset 10-11
        std.mem.writeInt(u16, response_buf[6..8], @intCast(final_count), .big);
        std.mem.writeInt(u16, response_buf[8..10], @intCast(ns_count), .big);

        return builder.pos;
    }

    fn buildErrorResponse(self: *QueryHandler, buf: []u8, id: u16, rcode: Rcode) usize {
        _ = self;
        var builder = Builder.init(buf);

        const header = Header{
            .id = id,
            .flags = .{
                .qr = true,
                .opcode = 0,
                .aa = false,
                .tc = false,
                .rd = false,
                .ra = false,
                .z = false,
                .ad = false,
                .cd = false,
                .rcode = @intFromEnum(rcode),
            },
            .qd_count = 0,
            .an_count = 0,
            .ns_count = 0,
            .ar_count = 0,
        };

        builder.writeHeader(header) catch return 0;
        return builder.pos;
    }
};

// ═══════════════════════════════════════════════════════════════════════════
// DNS Server
// ═══════════════════════════════════════════════════════════════════════════

pub const Server = struct {
    allocator: std.mem.Allocator,
    config: Config,
    zones: *ZoneStore,
    handler: QueryHandler,

    // Network state
    udp_socket: ?std.posix.socket_t = null,
    tcp_socket: ?std.posix.socket_t = null,
    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    // Statistics
    stats: Stats = .{},

    pub const Stats = struct {
        queries_received: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
        queries_answered: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
        queries_refused: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
        queries_failed: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    };

    pub fn init(allocator: std.mem.Allocator, zones: *ZoneStore, config: Config) Server {
        return .{
            .allocator = allocator,
            .config = config,
            .zones = zones,
            .handler = QueryHandler.init(zones, config),
        };
    }

    pub fn deinit(self: *Server) void {
        self.stop();
        if (self.udp_socket) |sock| {
            _ = std.c.close(sock);
        }
        if (self.tcp_socket) |sock| {
            _ = std.c.close(sock);
        }
    }

    /// Start the DNS server
    pub fn start(self: *Server) !void {
        // Create UDP socket
        const udp_sock = try createSocket(linux.SOCK.DGRAM);
        errdefer _ = std.c.close(udp_sock);

        // Allow address reuse
        setsockoptReuseAddr(udp_sock);

        // Bind UDP
        const addr = parseAddr(self.config.listen_addr, self.config.port) catch return error.InvalidAddress;
        try bindSocket(udp_sock, &addr);

        self.udp_socket = udp_sock;

        // Create TCP socket if enabled
        if (self.config.tcp_port > 0) {
            const tcp_sock = try createSocket(linux.SOCK.STREAM);
            errdefer _ = std.c.close(tcp_sock);

            setsockoptReuseAddr(tcp_sock);

            const tcp_addr = parseAddr(self.config.listen_addr, self.config.tcp_port) catch return error.InvalidAddress;
            try bindSocket(tcp_sock, &tcp_addr);
            try listenSocket(tcp_sock, 128);

            self.tcp_socket = tcp_sock;
        }

        self.running.store(true, .release);
    }

    /// Stop the DNS server
    pub fn stop(self: *Server) void {
        self.running.store(false, .release);
    }

    /// Run the main event loop (blocking)
    pub fn run(self: *Server) !void {
        const udp_sock = self.udp_socket orelse return error.NotStarted;

        var query_buf: [parser.MAX_MESSAGE_SIZE]u8 = undefined;
        var response_buf: [parser.MAX_MESSAGE_SIZE]u8 = undefined;

        while (self.running.load(.acquire)) {
            // Receive UDP query
            var client_addr: posix.sockaddr = undefined;
            var addr_len: posix.socklen_t = @sizeOf(posix.sockaddr);

            const recv_len = recvFrom(udp_sock, &query_buf, &client_addr, &addr_len) catch {
                continue;
            };

            if (recv_len < 12) continue; // Too short for DNS header

            _ = self.stats.queries_received.fetchAdd(1, .monotonic);

            // Handle query
            const response_len = self.handler.handleQuery(query_buf[0..recv_len], &response_buf) catch {
                _ = self.stats.queries_failed.fetchAdd(1, .monotonic);
                continue;
            };

            if (response_len == 0) {
                _ = self.stats.queries_failed.fetchAdd(1, .monotonic);
                continue;
            }

            // Truncate if needed
            var final_response = response_buf[0..response_len];
            if (response_len > self.config.max_udp_size) {
                // Set TC flag
                response_buf[2] |= 0x02;
                final_response = response_buf[0..self.config.max_udp_size];
            }

            // Send response
            _ = sendTo(udp_sock, final_response, &client_addr, addr_len) catch {
                _ = self.stats.queries_failed.fetchAdd(1, .monotonic);
                continue;
            };

            _ = self.stats.queries_answered.fetchAdd(1, .monotonic);
        }
    }

    /// Get server statistics
    pub fn getStats(self: *Server) Stats {
        return .{
            .queries_received = std.atomic.Value(u64).init(self.stats.queries_received.load(.monotonic)),
            .queries_answered = std.atomic.Value(u64).init(self.stats.queries_answered.load(.monotonic)),
            .queries_refused = std.atomic.Value(u64).init(self.stats.queries_refused.load(.monotonic)),
            .queries_failed = std.atomic.Value(u64).init(self.stats.queries_failed.load(.monotonic)),
        };
    }
};

// ═══════════════════════════════════════════════════════════════════════════
// Rate Limiter
// ═══════════════════════════════════════════════════════════════════════════

pub const RateLimiter = struct {
    allocator: std.mem.Allocator,
    limit: u32,
    window_ns: i128,

    // Per-IP counters
    counters: std.AutoHashMap(u32, Counter),
    mutex: std.Thread.Mutex = .{},

    const Counter = struct {
        count: u32,
        window_start: i128,
    };

    pub fn init(allocator: std.mem.Allocator, qps: u32) RateLimiter {
        return .{
            .allocator = allocator,
            .limit = qps,
            .window_ns = std.time.ns_per_s,
            .counters = std.AutoHashMap(u32, Counter).init(allocator),
        };
    }

    pub fn deinit(self: *RateLimiter) void {
        self.counters.deinit();
    }

    /// Check if request should be allowed
    pub fn allow(self: *RateLimiter, ip: u32) bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        const now = std.time.nanoTimestamp();

        const entry = self.counters.getOrPut(ip) catch return true;
        if (!entry.found_existing) {
            entry.value_ptr.* = .{
                .count = 1,
                .window_start = now,
            };
            return true;
        }

        // Check if window expired
        if (now - entry.value_ptr.window_start > self.window_ns) {
            entry.value_ptr.count = 1;
            entry.value_ptr.window_start = now;
            return true;
        }

        // Increment counter
        entry.value_ptr.count += 1;
        return entry.value_ptr.count <= self.limit;
    }

    /// Clear old entries
    pub fn cleanup(self: *RateLimiter) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const now = std.time.nanoTimestamp();
        const expire_threshold = now - self.window_ns * 2;

        var to_remove = std.ArrayList(u32).init(self.allocator);
        defer to_remove.deinit();

        var iter = self.counters.iterator();
        while (iter.next()) |entry| {
            if (entry.value_ptr.window_start < expire_threshold) {
                to_remove.append(entry.key_ptr.*) catch continue;
            }
        }

        for (to_remove.items) |ip| {
            _ = self.counters.remove(ip);
        }
    }
};

// ═══════════════════════════════════════════════════════════════════════════
// Response Cache
// ═══════════════════════════════════════════════════════════════════════════

pub const ResponseCache = struct {
    allocator: std.mem.Allocator,
    entries: std.AutoHashMap(u64, CacheEntry),
    max_entries: u32,
    mutex: std.Thread.Mutex = .{},

    const CacheEntry = struct {
        response: []u8,
        expires: i128,
    };

    pub fn init(allocator: std.mem.Allocator, max_entries: u32) ResponseCache {
        return .{
            .allocator = allocator,
            .entries = std.AutoHashMap(u64, CacheEntry).init(allocator),
            .max_entries = max_entries,
        };
    }

    pub fn deinit(self: *ResponseCache) void {
        var iter = self.entries.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.value_ptr.response);
        }
        self.entries.deinit();
    }

    /// Get cached response
    pub fn get(self: *ResponseCache, key: u64) ?[]const u8 {
        self.mutex.lock();
        defer self.mutex.unlock();

        const entry = self.entries.get(key) orelse return null;
        const now = std.time.nanoTimestamp();

        if (now > entry.expires) {
            // Expired - remove
            if (self.entries.fetchRemove(key)) |kv| {
                self.allocator.free(kv.value.response);
            }
            return null;
        }

        return entry.response;
    }

    /// Cache a response
    pub fn put(self: *ResponseCache, key: u64, response: []const u8, ttl_seconds: u32) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Check capacity
        if (self.entries.count() >= self.max_entries) {
            self.evictOldest();
        }

        const response_copy = try self.allocator.dupe(u8, response);
        errdefer self.allocator.free(response_copy);

        const expires = std.time.nanoTimestamp() + @as(i128, ttl_seconds) * std.time.ns_per_s;

        // Remove old entry if exists
        if (self.entries.fetchRemove(key)) |old| {
            self.allocator.free(old.value.response);
        }

        try self.entries.put(key, .{
            .response = response_copy,
            .expires = expires,
        });
    }

    fn evictOldest(self: *ResponseCache) void {
        var oldest_key: ?u64 = null;
        var oldest_time: i128 = std.math.maxInt(i128);

        var iter = self.entries.iterator();
        while (iter.next()) |entry| {
            if (entry.value_ptr.expires < oldest_time) {
                oldest_time = entry.value_ptr.expires;
                oldest_key = entry.key_ptr.*;
            }
        }

        if (oldest_key) |key| {
            if (self.entries.fetchRemove(key)) |kv| {
                self.allocator.free(kv.value.response);
            }
        }
    }

    /// Generate cache key from query
    pub fn makeKey(name: *const Name, qtype: RecordType, qclass: Class) u64 {
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(name.data[0..name.len]);
        hasher.update(std.mem.asBytes(&@intFromEnum(qtype)));
        hasher.update(std.mem.asBytes(&@intFromEnum(qclass)));
        return hasher.final();
    }
};

// ═══════════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════════

test "QueryHandler basic query" {
    const allocator = std.testing.allocator;

    // Create zone store
    var zones = ZoneStore.init(allocator);
    defer zones.deinit();

    // Create test zone
    const origin = try Name.fromString("example.com");
    var zone = Zone.init(allocator, origin);

    // Add test record
    var record = zone_mod.ZoneRecord{
        .name = try Name.fromString("www.example.com"),
        .rtype = .A,
        .ttl = 3600,
    };
    @memcpy(record.rdata[0..4], &[_]u8{ 192, 168, 1, 1 });
    record.rdlength = 4;
    try zone.addRecord(record);
    try zones.addZone(zone);

    // Create handler
    var handler = QueryHandler.init(&zones, .{});

    // Build query
    var query_buf: [512]u8 = undefined;
    var query_builder = Builder.init(&query_buf);

    try query_builder.writeHeader(.{
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
    });

    const qname = try Name.fromString("www.example.com");
    try query_builder.writeQuestion(.{
        .name = qname,
        .qtype = .A,
        .qclass = .IN,
    });

    // Handle query
    var response_buf: [512]u8 = undefined;
    const response_len = try handler.handleQuery(query_builder.message(), &response_buf);

    try std.testing.expect(response_len > 12);

    // Parse response
    const response = try Message.parse(response_buf[0..response_len]);
    try std.testing.expectEqual(@as(u16, 0x1234), response.header.id);
    try std.testing.expect(response.header.flags.qr); // Is response
    try std.testing.expect(response.header.flags.aa); // Authoritative
}

test "RateLimiter" {
    const allocator = std.testing.allocator;
    var limiter = RateLimiter.init(allocator, 5); // 5 QPS
    defer limiter.deinit();

    const ip: u32 = 0x0A000001; // 10.0.0.1

    // First 5 requests should be allowed
    for (0..5) |_| {
        try std.testing.expect(limiter.allow(ip));
    }

    // 6th should be blocked
    try std.testing.expect(!limiter.allow(ip));
}

test "ResponseCache" {
    const allocator = std.testing.allocator;
    var cache = ResponseCache.init(allocator, 100);
    defer cache.deinit();

    const test_response = "test response data";
    const key: u64 = 12345;

    // Put entry
    try cache.put(key, test_response, 60);

    // Get entry
    const cached = cache.get(key);
    try std.testing.expect(cached != null);
    try std.testing.expectEqualStrings(test_response, cached.?);
}
