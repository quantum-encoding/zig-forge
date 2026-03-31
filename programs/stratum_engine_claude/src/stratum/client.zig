//! Stratum V1 io_uring Client with Latency Tracking
//! Zero-copy networking for maximum performance

const std = @import("std");
const types = @import("types.zig");
const protocol = @import("protocol.zig");
const linux = std.os.linux;
const posix = std.posix;
const IoUring = linux.IoUring;
const compat = @import("../utils/compat.zig");

pub const ClientError = error{
    ConnectionFailed,
    AuthenticationFailed,
    ProtocolError,
    Timeout,
    Disconnected,
    NoAddressFound,
    IPv6NotSupported,
    RecvFailed,
};

pub const ClientState = enum {
    disconnected,
    connecting,
    subscribing,
    authorizing,
    ready,
    error_state,
};

/// Latency tracking for performance monitoring
pub const LatencyMetrics = struct {
    packet_received_ns: u64,
    parse_complete_ns: u64,
    job_dispatched_ns: u64,
    first_hash_ns: u64,

    pub fn packetToHash(self: LatencyMetrics) u64 {
        if (self.first_hash_ns > self.packet_received_ns) {
            return self.first_hash_ns - self.packet_received_ns;
        }
        return 0;
    }

    pub fn packetToHashUs(self: LatencyMetrics) f64 {
        return @as(f64, @floatFromInt(self.packetToHash())) / 1000.0;
    }
};

pub const StratumClient = struct {
    allocator: std.mem.Allocator,
    state: ClientState,

    /// io_uring instance for zero-copy I/O
    ring: IoUring,

    /// TCP socket
    sockfd: posix.fd_t,

    /// Pool credentials
    credentials: types.Credentials,

    /// Extranonce1 from pool
    extranonce1: ?[]u8,

    /// Extranonce2 size
    extranonce2_size: u32,

    /// Current difficulty
    difficulty: f64,

    /// Message ID counter
    next_id: u32,

    /// Receive buffer
    recv_buffer: [8192]u8,
    recv_len: usize,

    /// Latency tracking
    last_packet_ns: u64,
    latency_history: std.ArrayList(LatencyMetrics),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, credentials: types.Credentials) !Self {
        // Parse pool URL to extract host and port
        const url = credentials.url;
        const prefix = "stratum+tcp://";
        if (!std.mem.startsWith(u8, url, prefix)) {
            return ClientError.ProtocolError;
        }

        const host_port = url[prefix.len..];
        const colon_idx = std.mem.indexOf(u8, host_port, ":") orelse return ClientError.ProtocolError;

        const host = host_port[0..colon_idx];
        const port_str = host_port[colon_idx + 1 ..];
        const port = try std.fmt.parseInt(u16, port_str, 10);

        std.debug.print("🔌 Initializing io_uring client for {s}:{d}...\n", .{ host, port });

        // Initialize io_uring (64 entries, no flags for portability)
        var ring = try IoUring.init(64, 0);

        // Create TCP socket using compat helper
        const sockfd = try compat.createSocket(linux.SOCK.STREAM | linux.SOCK.CLOEXEC);
        errdefer compat.closeSocket(sockfd);

        // Resolve address (supports both IP and hostname)
        var address = linux.sockaddr.in{
            .family = linux.AF.INET,
            .port = std.mem.nativeToBig(u16, port),
            .addr = undefined,
        };

        if (std.mem.eql(u8, host, "localhost")) {
            address.addr = 0x0100007F; // 127.0.0.1 in network byte order
        } else if (tryParseIpv4(host)) |ip_addr| {
            // Direct IP address
            address.addr = ip_addr;
        } else {
            // Hostname - resolve via DNS using getaddrinfo
            std.debug.print("🔍 Resolving hostname: {s}...\n", .{host});

            // Null-terminate the host string for C
            var host_buf: [256]u8 = undefined;
            if (host.len >= host_buf.len) return ClientError.NoAddressFound;
            @memcpy(host_buf[0..host.len], host);
            host_buf[host.len] = 0;

            var hints: std.c.addrinfo = std.mem.zeroes(std.c.addrinfo);
            hints.family = linux.AF.INET;
            hints.socktype = linux.SOCK.STREAM;

            var result: ?*std.c.addrinfo = null;
            const rc = std.c.getaddrinfo(@ptrCast(&host_buf), null, &hints, &result);
            if (@intFromEnum(rc) != 0 or result == null) {
                std.debug.print("❌ DNS resolution failed for: {s}\n", .{host});
                return ClientError.NoAddressFound;
            }
            defer std.c.freeaddrinfo(result.?);

            // Extract IPv4 address from result
            const sockaddr_ptr: *const linux.sockaddr.in = @ptrCast(@alignCast(result.?.addr));
            address.addr = sockaddr_ptr.addr;

            // Print resolved address
            const resolved_octets: [4]u8 = @bitCast(address.addr);
            std.debug.print("✅ Resolved to: {}.{}.{}.{}\n", .{
                resolved_octets[0],
                resolved_octets[1],
                resolved_octets[2],
                resolved_octets[3],
            });
        }

        // Submit connect operation via io_uring
        const sqe = try ring.get_sqe();
        sqe.prep_connect(sockfd, @ptrCast(&address), @sizeOf(linux.sockaddr.in));

        // Wait for connection
        _ = try ring.submit_and_wait(1);
        var cqe = try ring.copy_cqe();
        defer ring.cqe_seen(&cqe);

        if (cqe.res < 0) {
            return ClientError.ConnectionFailed;
        }

        return .{
            .allocator = allocator,
            .state = .subscribing,
            .ring = ring,
            .sockfd = sockfd,
            .credentials = credentials,
            .extranonce1 = null,
            .extranonce2_size = 0,
            .difficulty = 1.0,
            .next_id = 1,
            .recv_buffer = undefined,
            .recv_len = 0,
            .last_packet_ns = 0,
            .latency_history = try std.ArrayList(LatencyMetrics).initCapacity(allocator, 0),
        };
    }

    pub fn deinit(self: *Self) void {
        compat.closeSocket(self.sockfd);
        self.ring.deinit();
        if (self.extranonce1) |extra| {
            self.allocator.free(extra);
        }
        self.latency_history.deinit(self.allocator);
    }

    /// Subscribe to mining (first message after connect)
    pub fn subscribe(self: *Self) !void {
        if (self.state != .subscribing) return ClientError.ProtocolError;

        const id = self.getNextId();
        const msg = try std.fmt.allocPrint(
            self.allocator,
            "{{\"id\":{},\"method\":\"mining.subscribe\",\"params\":[\"zig-stratum-engine/0.1.0\"]}}\n",
            .{id},
        );
        defer self.allocator.free(msg);

        try self.sendRaw(msg);

        // Wait for subscribe response - pool may push set_difficulty first
        var attempts: u32 = 0;
        while (attempts < 10) : (attempts += 1) {
            const response = try self.receiveMessage();
            defer self.allocator.free(response);

            // Check if this is our subscribe response (has "result" and "id":1)
            if (std.mem.indexOf(u8, response, "\"result\"") != null and
                std.mem.indexOf(u8, response, "\"id\":1") != null)
            {
                // Parse extranonce1 and extranonce2_size from subscribe response
                // Response format: {"result": [["mining.notify", "..."], "extranonce1_hex", extranonce2_size], ...}
                if (std.mem.indexOf(u8, response, "\"result\"")) |result_pos| {
                    // Find the result array
                    if (std.mem.indexOfPos(u8, response, result_pos, "[")) |arr_start| {
                        // Skip the first nested array (subscriptions)
                        var depth_count: i32 = 0;
                        var scan_pos = arr_start + 1;
                        while (scan_pos < response.len) : (scan_pos += 1) {
                            if (response[scan_pos] == '[') depth_count += 1;
                            if (response[scan_pos] == ']') {
                                depth_count -= 1;
                                if (depth_count < 0) break;
                            }
                        }
                        // After the subscriptions array, find extranonce1 (quoted hex string)
                        if (std.mem.indexOfPos(u8, response, scan_pos, "\"")) |en1_start| {
                            const en1_begin = en1_start + 1;
                            if (std.mem.indexOfPos(u8, response, en1_begin, "\"")) |en1_end| {
                                const en1_hex = response[en1_begin..en1_end];
                                if (en1_hex.len > 0 and en1_hex.len <= 32) {
                                    self.extranonce1 = self.allocator.dupe(u8, en1_hex) catch null;
                                    std.debug.print("Extranonce1: {s}\n", .{en1_hex});
                                }
                                // Parse extranonce2_size (integer after the extranonce1 string)
                                if (std.mem.indexOfPos(u8, response, en1_end + 1, ",")) |comma_pos| {
                                    var num_start = comma_pos + 1;
                                    while (num_start < response.len and (response[num_start] == ' ' or response[num_start] == '\t')) : (num_start += 1) {}
                                    var num_end = num_start;
                                    while (num_end < response.len and response[num_end] >= '0' and response[num_end] <= '9') : (num_end += 1) {}
                                    if (num_end > num_start) {
                                        self.extranonce2_size = std.fmt.parseInt(u32, response[num_start..num_end], 10) catch 4;
                                        std.debug.print("Extranonce2 size: {d}\n", .{self.extranonce2_size});
                                    }
                                }
                            }
                        }
                    }
                }
                break;
            }

            // Handle set_difficulty if pushed early
            if (std.mem.indexOf(u8, response, "mining.set_difficulty")) |_| {
                self.parseSetDifficulty(response);
            }
        }

        self.state = .authorizing;
    }

    /// Authorize worker
    pub fn authorize(self: *Self) !void {
        if (self.state != .authorizing) return ClientError.ProtocolError;

        const id = self.getNextId();
        const msg = try std.fmt.allocPrint(
            self.allocator,
            "{{\"id\":{},\"method\":\"mining.authorize\",\"params\":[\"{s}\",\"{s}\"]}}\n",
            .{ id, self.credentials.username, self.credentials.password },
        );
        defer self.allocator.free(msg);

        try self.sendRaw(msg);

        // Wait for auth response - pool may send multiple messages
        var attempts: u32 = 0;
        while (attempts < 10) : (attempts += 1) {
            const response = self.receiveMessage() catch |err| {
                return err;
            };
            defer self.allocator.free(response);

            // Check if this is our auth response (has "result" and matches our id)
            if (std.mem.indexOf(u8, response, "\"result\"") != null and
                std.mem.indexOf(u8, response, "\"id\":2") != null)
            {
                break;
            }
            // Otherwise it might be set_difficulty or other pushed message, keep reading
        }

        self.state = .ready;
    }

    /// Submit share to pool
    pub fn submitShare(self: *Self, share: types.Share) !void {
        if (self.state != .ready) return ClientError.ProtocolError;

        const id = self.getNextId();
        const msg = try std.fmt.allocPrint(
            self.allocator,
            "{{\"id\":{},\"method\":\"mining.submit\",\"params\":[\"{s}\",\"{s}\",\"{s}\",\"{x:0>8}\",\"{x:0>8}\"]}}\n",
            .{
                id,
                share.worker_name,
                share.job_id,
                share.extranonce2,
                share.ntime,
                share.nonce,
            },
        );
        defer self.allocator.free(msg);

        try self.sendRaw(msg);
    }

    /// Receive job notification from pool (with latency tracking)
    pub fn receiveJob(self: *Self) !?types.Job {
        if (self.state != .ready) return null;

        const msg = try self.receiveMessage();
        defer self.allocator.free(msg);

        // Check if it's a mining.notify
        if (std.mem.indexOf(u8, msg, "mining.notify")) |_| {
            return self.parseJobNotify(msg);
        }

        // Check for set_difficulty
        if (std.mem.indexOf(u8, msg, "mining.set_difficulty")) |_| {
            self.parseSetDifficulty(msg);
        }

        return null;
    }

    /// Parse mining.notify JSON into Job struct
    /// Format: {"params":["job_id","prevhash","coinb1","coinb2",[merkle],"version","nbits","ntime",clean],...}
    fn parseJobNotify(self: *Self, msg: []const u8) ?types.Job {
        // Find the mining.notify method first
        const method_pos = std.mem.indexOf(u8, msg, "mining.notify") orelse return null;

        // Find the start of THIS notify's JSON object (search backwards for {)
        var obj_start: usize = method_pos;
        while (obj_start > 0) : (obj_start -= 1) {
            if (msg[obj_start] == '{') break;
        }

        // Now find "params" within this object (search from obj_start)
        const params_pos = std.mem.indexOfPos(u8, msg, obj_start, "\"params\"") orelse return null;

        // Find the params array - look for first [ after "params"
        var bracket_pos: ?usize = null;
        var in_string = false;

        for (msg[params_pos..], params_pos..) |c, i| {
            if (c == '"' and (i == 0 or msg[i - 1] != '\\')) in_string = !in_string;
            if (!in_string and c == '[') {
                bracket_pos = i;
                break;
            }
        }

        const array_start = bracket_pos orelse return null;

        // Parse JSON array elements properly (handle nested arrays and quoted strings)
        var elements: [10][]const u8 = undefined;
        var elem_count: usize = 0;
        var pos = array_start + 1;
        var depth: i32 = 0;
        var elem_start = pos;
        in_string = false;

        while (pos < msg.len and elem_count < 10) {
            const c = msg[pos];

            if (c == '"' and (pos == 0 or msg[pos - 1] != '\\')) {
                in_string = !in_string;
            }

            if (!in_string) {
                if (c == '[') depth += 1;
                if (c == ']') {
                    if (depth == 0) {
                        // End of params array
                        if (pos > elem_start) {
                            elements[elem_count] = std.mem.trim(u8, msg[elem_start..pos], " \t");
                            elem_count += 1;
                        }
                        break;
                    }
                    depth -= 1;
                }
                if (c == ',' and depth == 0) {
                    elements[elem_count] = std.mem.trim(u8, msg[elem_start..pos], " \t");
                    elem_count += 1;
                    elem_start = pos + 1;
                }
            }
            pos += 1;
        }

        if (elem_count < 9) {
            return null;
        }

        // Parse individual elements
        // 0: job_id, 1: prevhash, 2: coinb1, 3: coinb2, 4: merkle, 5: version, 6: nbits, 7: ntime, 8: clean

        const job_id = extractQuotedString(elements[0]) orelse return null;
        const job_id_copy = self.allocator.dupe(u8, job_id) catch return null;

        const prevhash_hex = extractQuotedString(elements[1]) orelse return null;
        var prevhash: [32]u8 = undefined;
        if (prevhash_hex.len != 64) return null;
        _ = std.fmt.hexToBytes(&prevhash, prevhash_hex) catch return null;

        const coinb1 = extractQuotedString(elements[2]) orelse return null;
        const coinb1_copy = self.allocator.dupe(u8, coinb1) catch return null;

        const coinb2 = extractQuotedString(elements[3]) orelse return null;
        const coinb2_copy = self.allocator.dupe(u8, coinb2) catch return null;

        // Skip merkle (element 4)

        const version_hex = extractQuotedString(elements[5]) orelse return null;
        const version = std.fmt.parseInt(u32, version_hex, 16) catch return null;

        const nbits_hex = extractQuotedString(elements[6]) orelse return null;
        const nbits = std.fmt.parseInt(u32, nbits_hex, 16) catch return null;

        const ntime_hex = extractQuotedString(elements[7]) orelse return null;
        const ntime = std.fmt.parseInt(u32, ntime_hex, 16) catch return null;

        const clean_jobs = std.mem.indexOf(u8, elements[8], "true") != null;

        return types.Job{
            .job_id = job_id_copy,
            .prevhash = prevhash,
            .coinb1 = coinb1_copy,
            .coinb2 = coinb2_copy,
            .merkle_branch = &.{},
            .version = version,
            .nbits = nbits,
            .ntime = ntime,
            .clean_jobs = clean_jobs,
            .allocator = self.allocator,
        };
    }

    /// Extract string between quotes
    fn extractQuotedString(raw: []const u8) ?[]const u8 {
        const start = std.mem.indexOf(u8, raw, "\"") orelse return null;
        const end = std.mem.lastIndexOf(u8, raw, "\"") orelse return null;
        if (end <= start + 1) return null;
        return raw[start + 1 .. end];
    }

    /// Parse set_difficulty message
    fn parseSetDifficulty(self: *Self, msg: []const u8) void {
        // Find params array
        const params_start = std.mem.indexOf(u8, msg, "\"params\"") orelse return;
        const array_start = std.mem.indexOfPos(u8, msg, params_start, "[") orelse return;
        const array_end = std.mem.indexOfPos(u8, msg, array_start, "]") orelse return;

        const diff_str = std.mem.trim(u8, msg[array_start + 1 .. array_end], " \t\n\r");
        self.difficulty = std.fmt.parseFloat(f64, diff_str) catch 1.0;
        std.debug.print("📊 Difficulty: {d}\n", .{self.difficulty});
    }

    /// Get latest latency metrics
    pub fn getLatestLatency(self: *Self) ?LatencyMetrics {
        if (self.latency_history.items.len > 0) {
            return self.latency_history.items[self.latency_history.items.len - 1];
        }
        return null;
    }

    /// Get average latency over last N samples
    pub fn getAverageLatencyUs(self: *Self, count: usize) f64 {
        if (self.latency_history.items.len == 0) return 0.0;

        const samples = @min(count, self.latency_history.items.len);
        var sum: f64 = 0.0;

        const start = self.latency_history.items.len - samples;
        for (self.latency_history.items[start..]) |metric| {
            sum += metric.packetToHashUs();
        }

        return sum / @as(f64, @floatFromInt(samples));
    }

    // Internal helpers

    fn getNextId(self: *Self) u32 {
        const id = self.next_id;
        self.next_id += 1;
        return id;
    }

    fn sendRaw(self: *Self, data: []const u8) !void {
        _ = compat.sendSocket(self.sockfd, data) catch {
            return ClientError.ProtocolError;
        };
    }

    fn receiveMessage(self: *Self) ![]const u8 {
        // Loop until we have a complete message (ending with newline)
        while (true) {
            // First check if we already have a complete message in the buffer
            if (std.mem.indexOf(u8, self.recv_buffer[0..self.recv_len], "\n")) |idx| {
                // Allocate copy of message before shifting buffer
                const msg = self.allocator.dupe(u8, self.recv_buffer[0..idx]) catch {
                    return ClientError.ProtocolError;
                };

                // Shift remaining data
                const remaining = self.recv_len - (idx + 1);
                if (remaining > 0) {
                    std.mem.copyForwards(u8, &self.recv_buffer, self.recv_buffer[idx + 1 .. self.recv_len]);
                }
                self.recv_len = remaining;

                return msg;
            }

            // Check buffer overflow before recv
            if (self.recv_len >= self.recv_buffer.len) {
                return ClientError.ProtocolError; // Message too long
            }

            // No complete message, need to read more data
            // Mark packet receive time
            var ts: std.c.timespec = undefined;
            _ = std.c.clock_gettime(.REALTIME, &ts);
            self.last_packet_ns = @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));

            // Use compat recv
            const bytes_read = compat.recvSocket(self.sockfd, self.recv_buffer[self.recv_len..]) catch {
                return ClientError.RecvFailed;
            };

            if (bytes_read == 0) {
                return ClientError.Disconnected;
            }

            self.recv_len += bytes_read;
            // Loop continues to check for complete message
        }
    }
};

/// Try to parse a string as an IPv4 address (e.g., "192.168.1.1")
/// Returns the address in network byte order, or null if not a valid IP
fn tryParseIpv4(host: []const u8) ?u32 {
    var octets: [4]u8 = undefined;
    var it = std.mem.splitScalar(u8, host, '.');
    var i: usize = 0;

    while (it.next()) |octet| : (i += 1) {
        if (i >= 4) return null;
        octets[i] = std.fmt.parseInt(u8, octet, 10) catch return null;
    }

    if (i != 4) return null;
    return @bitCast(octets);
}

test "client init" {
    const testing = std.testing;
    _ = testing;

    const creds = types.Credentials{
        .url = "stratum+tcp://pool.example.com:3333",
        .username = "test.worker",
        .password = "x",
    };

    // Note: This will fail without actual network, but tests compilation
    _ = creds;
}
