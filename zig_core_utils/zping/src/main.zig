//! zping - ICMP ping utility in pure Zig
//!
//! Send ICMP echo requests and measure round-trip time.
//! Requires root or CAP_NET_RAW capability.
//!
//! Usage:
//!   zping [options] host
//!
//! Options:
//!   -c, --count N      Stop after N pings (default: infinite)
//!   -i, --interval N   Wait N seconds between pings (default: 1)
//!   -W, --timeout N    Timeout in seconds for each reply (default: 1)
//!   -s, --size N       Payload size in bytes (default: 56)
//!   -q, --quiet        Quiet output, only show summary
//!   -h, --help         Show help

const std = @import("std");
const posix = std.posix;

const c = @cImport({
    @cInclude("netdb.h");
    @cInclude("sys/socket.h");
    @cInclude("netinet/in.h");
    @cInclude("netinet/ip_icmp.h");
    @cInclude("arpa/inet.h");
    @cInclude("unistd.h");
    @cInclude("errno.h");
    @cInclude("poll.h");
    @cInclude("time.h");
});

const VERSION = "1.0.0";

// Zig 0.16 compatible Timer (std.time.Timer was removed)
const Timer = struct {
    start_time: i128,

    pub fn start() !Timer {
        var ts: std.c.timespec = undefined;
        _ = std.c.clock_gettime(.MONOTONIC, &ts);
        return Timer{
            .start_time = @as(i128, ts.sec) * 1_000_000_000 + ts.nsec,
        };
    }

    pub fn read(self: Timer) u64 {
        var ts: std.c.timespec = undefined;
        _ = std.c.clock_gettime(.MONOTONIC, &ts);
        const now = @as(i128, ts.sec) * 1_000_000_000 + ts.nsec;
        return @intCast(now - self.start_time);
    }
};

// ============================================================================
// Writer for Zig 0.16
// ============================================================================

const Writer = struct {
    io: std.Io,
    buffer: *[8192]u8,
    file: std.Io.File,

    pub fn stdout() Writer {
        const io = std.Io.Threaded.global_single_threaded.io();
        const static = struct {
            var buffer: [8192]u8 = undefined;
        };
        return Writer{
            .io = io,
            .buffer = &static.buffer,
            .file = std.Io.File.stdout(),
        };
    }

    pub fn stderr() Writer {
        const io = std.Io.Threaded.global_single_threaded.io();
        const static = struct {
            var buffer: [8192]u8 = undefined;
        };
        return Writer{
            .io = io,
            .buffer = &static.buffer,
            .file = std.Io.File.stderr(),
        };
    }

    pub fn print(self: *Writer, comptime fmt: []const u8, args: anytype) void {
        var writer = self.file.writer(self.io, self.buffer);
        writer.interface.print(fmt, args) catch {};
        writer.interface.flush() catch {};
    }

    pub fn write(self: *Writer, data: []const u8) void {
        var writer = self.file.writer(self.io, self.buffer);
        writer.interface.writeAll(data) catch {};
        writer.interface.flush() catch {};
    }
};

// ============================================================================
// Configuration
// ============================================================================

const Config = struct {
    host: []const u8 = "",
    count: ?u32 = null, // null = infinite
    interval_ms: u32 = 1000,
    timeout_ms: u32 = 1000,
    payload_size: u16 = 56,
    quiet: bool = false,
};

// ============================================================================
// ICMP Header
// ============================================================================

const IcmpHeader = extern struct {
    type: u8,
    code: u8,
    checksum: u16,
    id: u16,
    sequence: u16,
};

const ICMP_ECHO_REQUEST: u8 = 8;
const ICMP_ECHO_REPLY: u8 = 0;

fn icmpChecksum(data: []const u8) u16 {
    var sum: u32 = 0;
    var i: usize = 0;

    // Sum 16-bit words
    while (i + 1 < data.len) : (i += 2) {
        const word: u16 = @as(u16, data[i]) | (@as(u16, data[i + 1]) << 8);
        sum += word;
    }

    // Add odd byte if present
    if (i < data.len) {
        sum += data[i];
    }

    // Fold 32-bit sum to 16 bits
    while (sum >> 16 != 0) {
        sum = (sum & 0xFFFF) + (sum >> 16);
    }

    return @intCast(~sum & 0xFFFF);
}

// ============================================================================
// Statistics
// ============================================================================

const PingStats = struct {
    transmitted: u32 = 0,
    received: u32 = 0,
    rtt_sum: f64 = 0,
    rtt_sum_sq: f64 = 0,
    rtt_min: f64 = std.math.inf(f64),
    rtt_max: f64 = 0,

    fn addRtt(self: *PingStats, rtt: f64) void {
        self.received += 1;
        self.rtt_sum += rtt;
        self.rtt_sum_sq += rtt * rtt;
        if (rtt < self.rtt_min) self.rtt_min = rtt;
        if (rtt > self.rtt_max) self.rtt_max = rtt;
    }

    fn avgRtt(self: *const PingStats) f64 {
        if (self.received == 0) return 0;
        return self.rtt_sum / @as(f64, @floatFromInt(self.received));
    }

    fn mdevRtt(self: *const PingStats) f64 {
        if (self.received == 0) return 0;
        const avg = self.avgRtt();
        const variance = (self.rtt_sum_sq / @as(f64, @floatFromInt(self.received))) - (avg * avg);
        return @sqrt(@max(0, variance));
    }

    fn lossPercent(self: *const PingStats) f64 {
        if (self.transmitted == 0) return 0;
        return 100.0 * @as(f64, @floatFromInt(self.transmitted - self.received)) / @as(f64, @floatFromInt(self.transmitted));
    }
};

// ============================================================================
// DNS Resolution
// ============================================================================

fn resolveHost(host: []const u8, addr_out: *c.struct_sockaddr_in) !void {
    var host_buf: [256]u8 = undefined;
    if (host.len >= host_buf.len) return error.HostTooLong;

    @memcpy(host_buf[0..host.len], host);
    host_buf[host.len] = 0;

    var hints: c.struct_addrinfo = std.mem.zeroes(c.struct_addrinfo);
    hints.ai_family = c.AF_INET;
    hints.ai_socktype = c.SOCK_RAW;

    var result: ?*c.struct_addrinfo = null;
    const gai_ret = c.getaddrinfo(&host_buf, null, &hints, &result);

    if (gai_ret != 0 or result == null) {
        return error.ResolutionFailed;
    }
    defer c.freeaddrinfo(result);

    const sockaddr: *c.struct_sockaddr_in = @ptrCast(@alignCast(result.?.ai_addr));
    addr_out.* = sockaddr.*;
}

fn formatAddr(addr: *const c.struct_sockaddr_in) [16]u8 {
    var buf: [16]u8 = undefined;
    const ip = addr.sin_addr.s_addr;
    const b1: u8 = @truncate(ip);
    const b2: u8 = @truncate(ip >> 8);
    const b3: u8 = @truncate(ip >> 16);
    const b4: u8 = @truncate(ip >> 24);

    const len = std.fmt.bufPrint(&buf, "{d}.{d}.{d}.{d}", .{ b1, b2, b3, b4 }) catch return buf;
    if (len.len < buf.len) {
        @memset(buf[len.len..], 0);
    }
    return buf;
}

// ============================================================================
// Ping Implementation
// ============================================================================

fn ping(config: *const Config) !void {
    var out = Writer.stdout();
    var err_out = Writer.stderr();

    // Resolve host
    var dest_addr: c.struct_sockaddr_in = undefined;
    resolveHost(config.host, &dest_addr) catch {
        err_out.print("zping: {s}: Name or service not known\n", .{config.host});
        std.process.exit(2);
    };

    const ip_str = formatAddr(&dest_addr);
    const ip_slice = std.mem.sliceTo(&ip_str, 0);

    // Create raw socket
    const sock = c.socket(c.AF_INET, c.SOCK_RAW, c.IPPROTO_ICMP);
    if (sock < 0) {
        err_out.write("zping: socket: Operation not permitted\n");
        err_out.write("Try: sudo setcap cap_net_raw+ep ./zping\n");
        std.process.exit(2);
    }
    defer _ = c.close(sock);

    // Set receive timeout
    var tv: c.struct_timeval = .{
        .tv_sec = @intCast(config.timeout_ms / 1000),
        .tv_usec = @intCast((config.timeout_ms % 1000) * 1000),
    };
    _ = c.setsockopt(sock, c.SOL_SOCKET, c.SO_RCVTIMEO, &tv, @sizeOf(@TypeOf(tv)));

    // Print header
    out.print("PING {s} ({s}) {d}({d}) bytes of data.\n", .{
        config.host,
        ip_slice,
        config.payload_size,
        config.payload_size + 28, // IP + ICMP headers
    });

    // Prepare packet buffer (aligned for IcmpHeader)
    const packet_size = @sizeOf(IcmpHeader) + config.payload_size;
    var packet_buf: [65535]u8 align(@alignOf(IcmpHeader)) = undefined;
    var recv_buf: [65535]u8 align(@alignOf(IcmpHeader)) = undefined;

    const icmp_hdr: *IcmpHeader = @ptrCast(&packet_buf);
    const payload = packet_buf[@sizeOf(IcmpHeader)..packet_size];

    // Fill payload with pattern
    for (payload, 0..) |*b, i| {
        b.* = @truncate(i);
    }

    const pid: u16 = @truncate(@as(u32, @bitCast(c.getpid())));
    var seq: u16 = 0;
    var stats = PingStats{};

    // Main ping loop
    while (config.count == null or stats.transmitted < config.count.?) {
        // Build ICMP packet
        icmp_hdr.* = .{
            .type = ICMP_ECHO_REQUEST,
            .code = 0,
            .checksum = 0,
            .id = pid,
            .sequence = std.mem.nativeToBig(u16, seq),
        };
        icmp_hdr.checksum = icmpChecksum(packet_buf[0..packet_size]);

        // Record send time
        var timer = Timer.start() catch {
            std.process.exit(1);
        };

        // Send packet
        const sent = c.sendto(
            sock,
            &packet_buf,
            packet_size,
            0,
            @ptrCast(&dest_addr),
            @sizeOf(c.struct_sockaddr_in),
        );

        if (sent < 0) {
            err_out.write("zping: sendto failed\n");
            stats.transmitted += 1;
            seq +%= 1;
            continue;
        }

        stats.transmitted += 1;

        // Wait for reply with sequence number matching - loop until we get our reply or timeout
        var got_reply = false;
        var remaining_timeout: i32 = @intCast(config.timeout_ms);
        var rtt_ms: f64 = 0;
        var total_elapsed_ns: u64 = 0;

        while (remaining_timeout > 0) {
            var pfd: c.struct_pollfd = .{
                .fd = sock,
                .events = c.POLLIN,
                .revents = 0,
            };

            const poll_ret = c.poll(&pfd, 1, remaining_timeout);

            if (poll_ret <= 0) {
                break; // Timeout
            }

            // Receive reply
            var from_addr: c.struct_sockaddr_in = undefined;
            var from_len: c.socklen_t = @sizeOf(c.struct_sockaddr_in);

            const recv_len = c.recvfrom(
                sock,
                &recv_buf,
                recv_buf.len,
                0,
                @ptrCast(&from_addr),
                &from_len,
            );

            total_elapsed_ns = timer.read();

            if (recv_len < 0) {
                break;
            }

            // Parse IP header to get ICMP
            const ip_hdr_len: usize = (@as(usize, recv_buf[0]) & 0x0F) * 4;
            if (recv_len < ip_hdr_len + @sizeOf(IcmpHeader)) {
                // Update remaining timeout and continue
                const elapsed_ms = total_elapsed_ns / 1_000_000;
                if (elapsed_ms >= remaining_timeout) break;
                remaining_timeout -= @intCast(elapsed_ms);
                continue;
            }

            const reply_icmp: *const IcmpHeader = @ptrCast(@alignCast(&recv_buf[ip_hdr_len]));
            const reply_seq = std.mem.bigToNative(u16, reply_icmp.sequence);

            // Check if this is OUR reply (matching pid AND sequence number)
            if (reply_icmp.type == ICMP_ECHO_REPLY and reply_icmp.id == pid and reply_seq == seq) {
                rtt_ms = @as(f64, @floatFromInt(total_elapsed_ns)) / 1_000_000.0;
                stats.addRtt(rtt_ms);
                got_reply = true;

                if (!config.quiet) {
                    const ttl = recv_buf[8]; // TTL in IP header
                    out.print("{d} bytes from {s}: icmp_seq={d} ttl={d} time={d:.3} ms\n", .{
                        @as(usize, @intCast(recv_len)) - ip_hdr_len,
                        ip_slice,
                        reply_seq,
                        ttl,
                        rtt_ms,
                    });
                }
                break;
            }

            // Not our packet, update remaining timeout and keep waiting
            const elapsed_ms = total_elapsed_ns / 1_000_000;
            if (elapsed_ms >= remaining_timeout) {
                break;
            }
            remaining_timeout -= @intCast(elapsed_ms);
        }

        if (!got_reply and !config.quiet) {
            out.print("Request timeout for icmp_seq {d}\n", .{seq});
        }

        seq +%= 1;

        // Wait for interval (subtract elapsed time)
        if (config.count == null or stats.transmitted < config.count.?) {
            const elapsed_ms = total_elapsed_ns / 1_000_000;
            if (elapsed_ms < config.interval_ms) {
                const sleep_ms = config.interval_ms - @as(u32, @intCast(elapsed_ms));
                var ts: c.struct_timespec = .{
                    .tv_sec = @intCast(sleep_ms / 1000),
                    .tv_nsec = @intCast((sleep_ms % 1000) * 1_000_000),
                };
                _ = c.nanosleep(&ts, null);
            }
        }
    }

    // Print statistics
    out.print("\n--- {s} ping statistics ---\n", .{config.host});
    out.print("{d} packets transmitted, {d} received, {d:.1}% packet loss\n", .{
        stats.transmitted,
        stats.received,
        stats.lossPercent(),
    });

    if (stats.received > 0) {
        out.print("rtt min/avg/max/mdev = {d:.3}/{d:.3}/{d:.3}/{d:.3} ms\n", .{
            stats.rtt_min,
            stats.avgRtt(),
            stats.rtt_max,
            stats.mdevRtt(),
        });
    }

    if (stats.received == 0) {
        std.process.exit(1);
    }
}

// ============================================================================
// Help
// ============================================================================

fn printHelp(writer: *Writer) void {
    writer.write(
        \\zping - ICMP ping utility in pure Zig
        \\
        \\Usage: zping [options] host
        \\
        \\Options:
        \\  -c, --count N      Stop after N pings (default: infinite)
        \\  -i, --interval N   Seconds between pings (default: 1)
        \\  -W, --timeout N    Timeout seconds for reply (default: 1)
        \\  -s, --size N       Payload size in bytes (default: 56)
        \\  -q, --quiet        Only show summary
        \\  -h, --help         Show this help
        \\  --version          Show version
        \\
        \\Note: Requires root or CAP_NET_RAW capability.
        \\      sudo setcap cap_net_raw+ep ./zping
        \\
        \\Examples:
        \\  zping google.com
        \\  zping -c 5 8.8.8.8
        \\  zping -i 0.5 -c 10 localhost
        \\
    );
}

fn printVersion(writer: *Writer) void {
    writer.print("zping {s}\n", .{VERSION});
}

// ============================================================================
// Argument Parsing
// ============================================================================

fn parseArgs(args: []const []const u8) Config {
    var config = Config{};
    var i: usize = 0;

    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            var writer = Writer.stdout();
            printHelp(&writer);
            std.process.exit(0);
        } else if (std.mem.eql(u8, arg, "--version")) {
            var writer = Writer.stdout();
            printVersion(&writer);
            std.process.exit(0);
        } else if (std.mem.eql(u8, arg, "-c") or std.mem.eql(u8, arg, "--count")) {
            i += 1;
            if (i >= args.len) {
                var writer = Writer.stderr();
                writer.write("zping: -c requires an argument\n");
                std.process.exit(1);
            }
            config.count = std.fmt.parseInt(u32, args[i], 10) catch {
                var writer = Writer.stderr();
                writer.print("zping: invalid count '{s}'\n", .{args[i]});
                std.process.exit(1);
            };
        } else if (std.mem.eql(u8, arg, "-i") or std.mem.eql(u8, arg, "--interval")) {
            i += 1;
            if (i >= args.len) {
                var writer = Writer.stderr();
                writer.write("zping: -i requires an argument\n");
                std.process.exit(1);
            }
            const interval_f = std.fmt.parseFloat(f64, args[i]) catch {
                var writer = Writer.stderr();
                writer.print("zping: invalid interval '{s}'\n", .{args[i]});
                std.process.exit(1);
            };
            config.interval_ms = @intFromFloat(interval_f * 1000);
        } else if (std.mem.eql(u8, arg, "-W") or std.mem.eql(u8, arg, "--timeout")) {
            i += 1;
            if (i >= args.len) {
                var writer = Writer.stderr();
                writer.write("zping: -W requires an argument\n");
                std.process.exit(1);
            }
            const timeout_f = std.fmt.parseFloat(f64, args[i]) catch {
                var writer = Writer.stderr();
                writer.print("zping: invalid timeout '{s}'\n", .{args[i]});
                std.process.exit(1);
            };
            config.timeout_ms = @intFromFloat(timeout_f * 1000);
        } else if (std.mem.eql(u8, arg, "-s") or std.mem.eql(u8, arg, "--size")) {
            i += 1;
            if (i >= args.len) {
                var writer = Writer.stderr();
                writer.write("zping: -s requires an argument\n");
                std.process.exit(1);
            }
            config.payload_size = std.fmt.parseInt(u16, args[i], 10) catch {
                var writer = Writer.stderr();
                writer.print("zping: invalid size '{s}'\n", .{args[i]});
                std.process.exit(1);
            };
        } else if (std.mem.eql(u8, arg, "-q") or std.mem.eql(u8, arg, "--quiet")) {
            config.quiet = true;
        } else if (arg.len > 0 and arg[0] == '-') {
            var writer = Writer.stderr();
            writer.print("zping: unknown option '{s}'\n", .{arg});
            std.process.exit(1);
        } else {
            config.host = arg;
        }
    }

    if (config.host.len == 0) {
        var writer = Writer.stderr();
        writer.write("zping: missing host operand\n");
        writer.write("Try 'zping --help' for more information.\n");
        std.process.exit(1);
    }

    return config;
}

// ============================================================================
// Main
// ============================================================================

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    // Collect args into a slice
    var args_list: std.ArrayListUnmanaged([]const u8) = .empty;
    defer args_list.deinit(allocator);
    var args_iter = std.process.Args.Iterator.init(init.minimal.args);
    while (args_iter.next()) |arg| {
        try args_list.append(allocator, arg);
    }
    const args = args_list.items;

    const config = parseArgs(args[1..]);
    try ping(&config);
}
