const std = @import("std");
// Zig 0.16 Breaking Change: std.net moved/replaced by std.Io.net
const Io = std.Io;
const IpAddress = Io.net.IpAddress;
const posix = std.posix;

// Zig 0.16 Breaking Change: std.Thread.Mutex was removed
// Using pthread mutex directly with libc linkage
const Mutex = struct {
    inner: std.c.pthread_mutex_t = std.c.PTHREAD_MUTEX_INITIALIZER,

    pub fn lock(self: *Mutex) void {
        _ = std.c.pthread_mutex_lock(&self.inner);
    }

    pub fn unlock(self: *Mutex) void {
        _ = std.c.pthread_mutex_unlock(&self.inner);
    }
};

const VERSION = "5.0.0"; // Using native Zig 0.16 networking API with timeout support - Community example
const MAX_PORTS = 65535;
const DEFAULT_TIMEOUT_MS = 1000;
const MAX_THREADS = 100;

// Error types for better error handling
pub const ScannerError = error{
    NoHost,
    InvalidPortRange,
    ResolutionFailed,
    ScanFailed,
};

pub const PortStatus = enum {
    open,
    closed,
    filtered,
    unknown,

    pub fn toString(self: PortStatus) []const u8 {
        return switch (self) {
            .open => "open",
            .closed => "closed",
            .filtered => "filtered",
            .unknown => "unknown",
        };
    }
};

const PortResult = struct {
    port: u16,
    status: PortStatus,
    service: []const u8,

    fn init(port: u16, status: PortStatus, allocator: std.mem.Allocator) !PortResult {
        const service = try allocator.dupe(u8, getServiceName(port));
        return .{
            .port = port,
            .status = status,
            .service = service,
        };
    }

    fn deinit(self: *PortResult, allocator: std.mem.Allocator) void {
        allocator.free(self.service);
    }
};

const ScanConfig = struct {
    host: []const u8,
    ports: std.ArrayList(u16),
    timeout_ms: u32,
    thread_count: usize,
    verbose: bool,
    show_closed: bool,
    allocator: std.mem.Allocator,
    results: std.ArrayList(PortResult),
    result_mutex: Mutex,

    fn init(allocator: std.mem.Allocator, host: []const u8) !ScanConfig {
        const ports: std.ArrayList(u16) = .empty;
        const results: std.ArrayList(PortResult) = .empty;

        return .{
            .host = try allocator.dupe(u8, host),
            .ports = ports,
            .timeout_ms = DEFAULT_TIMEOUT_MS,
            .thread_count = 10,
            .verbose = false,
            .show_closed = false,
            .allocator = allocator,
            .results = results,
            .result_mutex = .{},
        };
    }

    fn deinit(self: *ScanConfig) void {
        for (self.results.items) |*result| {
            result.deinit(self.allocator);
        }
        self.results.deinit(self.allocator);
        self.ports.deinit(self.allocator);
        self.allocator.free(self.host);
    }
};

const ThreadData = struct {
    config: *ScanConfig,
    thread_id: usize,
    port_start_idx: usize,
    port_end_idx: usize,
    target_addr: IpAddress, // Updated from net.Address
};

var running: std.atomic.Value(bool) = std.atomic.Value(bool).init(true);

pub fn getServiceName(port: u16) []const u8 {
    return switch (port) {
        21 => "ftp",
        22 => "ssh",
        23 => "telnet",
        25 => "smtp",
        53 => "dns",
        80 => "http",
        110 => "pop3",
        143 => "imap",
        443 => "https",
        445 => "smb",
        3306 => "mysql",
        3389 => "rdp",
        5432 => "postgresql",
        6379 => "redis",
        8080 => "http-alt",
        8443 => "https-alt",
        27017 => "mongodb",
        else => "",
    };
}

/// Scan a port using native Zig networking API with timeout support
pub fn scanPort(io: Io, addr: IpAddress, timeout_ms: u32) !PortStatus {
    // Use Zig's native networking API with our newly implemented timeout support
    const timeout_ns: i96 = @intCast(@as(u64, timeout_ms) * std.time.ns_per_ms);

    const stream = addr.connect(io, .{
        .mode = .stream, // TCP connection
        .timeout = .{ .duration = .{
            .raw = .{ .nanoseconds = timeout_ns },
            .clock = .awake,
        } },
    }) catch |err| {
        return switch (err) {
            error.ConnectionRefused => .closed,
            error.Timeout => .filtered,
            error.HostUnreachable,
            error.NetworkUnreachable,
            => .filtered,
            else => .unknown,
        };
    };

    // Connection successful - port is open
    defer stream.close(io);
    return .open;
}

fn addResult(config: *ScanConfig, port: u16, status: PortStatus) !void {
    config.result_mutex.lock();
    defer config.result_mutex.unlock();

    const result = try PortResult.init(port, status, config.allocator);
    try config.results.append(config.allocator, result);
}

fn scanThread(data: *ThreadData) !void {
    var threaded = Io.Threaded.init_single_threaded;
    const io = threaded.io();

    var idx = data.port_start_idx;
    while (idx < data.port_end_idx and running.load(.seq_cst)) : (idx += 1) {
        const port = data.config.ports.items[idx];

        // Create new address with port (workaround for stdlib setPort bug in dev.1303)
        const target = switch (data.target_addr) {
            .ip4 => |ip4| IpAddress{ .ip4 = .{ .bytes = ip4.bytes, .port = port } },
            .ip6 => |ip6| IpAddress{ .ip6 = .{ .port = port, .bytes = ip6.bytes, .flow = ip6.flow, .interface = ip6.interface } },
        };

        const status = scanPort(io, target, data.config.timeout_ms) catch .unknown;

        if (status == .open or (data.config.show_closed and status == .closed)) {
            try addResult(data.config, port, status);

            if (data.config.verbose) {
                const service = getServiceName(port);
                std.debug.print("Port {d:>5}: {s:<8} {s}\n",
                    .{ port, status.toString(), service });
            }
        }
    }
}

fn compareResults(_: void, a: PortResult, b: PortResult) bool {
    return a.port < b.port;
}

fn printResults(config: *ScanConfig) !void {
    std.mem.sort(PortResult, config.results.items, {}, compareResults);

    std.debug.print("\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n", .{});
    std.debug.print("Scan Results for {s}:\n", .{config.host});
    std.debug.print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n\n", .{});
    std.debug.print("{s:<10} {s:<10} {s}\n", .{ "PORT", "STATE", "SERVICE" });
    std.debug.print("{s}\n", .{"─" ** 40});

    for (config.results.items) |result| {
        std.debug.print("{d:<10} {s:<10} {s}\n",
            .{ result.port, result.status.toString(), result.service });
    }

    var open_count: usize = 0;
    for (config.results.items) |result| {
        if (result.status == .open) {
            open_count += 1;
        }
    }

    std.debug.print("\nSummary: {d} open port(s) found\n", .{open_count});
}

/// DNS resolution using getaddrinfo() - same approach as Zig stdlib's HostName.lookup()
/// Note: Zig stdlib's IpAddress.resolve() only parses IPv6 scope, doesn't do DNS!
/// For async DNS with full HostName API, use HostName.lookup() with Io.Queue
pub fn resolveHost(io: Io, hostname: []const u8) !IpAddress {
    _ = io; // DNS resolution doesn't require Io for this synchronous approach

    // 1. Try to parse as IP address literal first (fast path, no DNS needed)
    if (IpAddress.parse(hostname, 0)) |addr| {
        return addr;
    } else |_| {}

    // 2. Perform actual DNS resolution using getaddrinfo()
    // This is the same backend that Zig's HostName.lookup() uses on libc platforms

    // Prepare hints for getaddrinfo
    const hints: std.c.addrinfo = .{
        .flags = .{ .NUMERICSERV = true }, // Port will be numeric (not a service name)
        .family = posix.AF.UNSPEC, // Accept both IPv4 and IPv6
        .socktype = posix.SOCK.STREAM, // TCP
        .protocol = posix.IPPROTO.TCP,
        .addrlen = 0,
        .canonname = null,
        .addr = null,
        .next = null,
    };

    // Call getaddrinfo - need null-terminated hostname
    var hostname_buf: [256:0]u8 = undefined;
    if (hostname.len >= hostname_buf.len) return ScannerError.ResolutionFailed;
    @memcpy(hostname_buf[0..hostname.len], hostname);
    hostname_buf[hostname.len] = 0;

    var result: ?*std.c.addrinfo = null;
    const rc = std.c.getaddrinfo(
        @ptrCast(&hostname_buf),
        null, // service/port (we'll set port later)
        &hints,
        &result,
    );

    if (@intFromEnum(rc) != 0 or result == null) {
        std.debug.print("❌ DNS resolution failed for '{s}': {}\n", .{ hostname, rc });
        return ScannerError.ResolutionFailed;
    }

    defer std.c.freeaddrinfo(result.?);

    // Extract first result and convert to IpAddress
    const addr_info = result.?;
    const addr_ptr = addr_info.addr orelse return ScannerError.ResolutionFailed;

    const addr = switch (@as(posix.sa_family_t, @intCast(addr_info.family))) {
        posix.AF.INET => blk: {
            const sockaddr_ptr: *align(1) const posix.sockaddr.in = @ptrCast(addr_ptr);
            const bytes: [4]u8 = @bitCast(sockaddr_ptr.addr);
            break :blk IpAddress{ .ip4 = .{
                .bytes = bytes,
                .port = 0, // Will be set per-port in scanner
            } };
        },
        posix.AF.INET6 => blk: {
            const sockaddr_ptr: *align(1) const posix.sockaddr.in6 = @ptrCast(addr_ptr);
            break :blk IpAddress{ .ip6 = .{
                .port = 0,
                .bytes = sockaddr_ptr.addr,
                .flow = sockaddr_ptr.flowinfo,
                .interface = .{ .index = sockaddr_ptr.scope_id },
            } };
        },
        else => {
            std.debug.print("❌ Unsupported address family from DNS: {d}\n", .{addr_info.family});
            return ScannerError.ResolutionFailed;
        },
    };

    return addr;
}

fn printUsage(prog_name: []const u8) void {
    std.debug.print("\n", .{});
    std.debug.print("🔍 zig-port-scanner v{s}\n", .{VERSION});
    std.debug.print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n", .{});
    std.debug.print("\nUsage: {s} [OPTIONS] HOST\n\n", .{prog_name});
    // ... (rest of printUsage is string literals, largely unchanged)
    std.debug.print("Options:\n", .{});
    std.debug.print("  -p=SPEC, --ports=SPEC      Port specification (e.g., 80, 1-1000)\n", .{});
    std.debug.print("  -t=MS, --timeout=MS        Connection timeout in ms (default: 1000)\n", .{});
    std.debug.print("  -j=N, --threads=N          Number of threads (default: 10, max: 100)\n", .{});
    std.debug.print("  -v, --verbose              Show results as found\n", .{});
    std.debug.print("  -c, --closed               Show closed ports\n", .{});
    std.debug.print("\nPart of zig_forge - AI Safety Security System\n\n", .{});
}

pub fn parsePortSpec(spec: []const u8, ports: *std.ArrayList(u16), allocator: std.mem.Allocator) !void {
    var it = std.mem.splitScalar(u8, spec, ',');
    while (it.next()) |part| {
        const trimmed = std.mem.trim(u8, part, " \t");
        if (std.mem.indexOf(u8, trimmed, "-")) |dash_pos| {
            const start_str = trimmed[0..dash_pos];
            const end_str = trimmed[dash_pos + 1..];
            const start = std.fmt.parseInt(u16, start_str, 10) catch return ScannerError.InvalidPortRange;
            const end = std.fmt.parseInt(u16, end_str, 10) catch return ScannerError.InvalidPortRange;
            if (start > end or start == 0) return ScannerError.InvalidPortRange;
            var port = start;
            while (port <= end) : (port += 1) try ports.append(allocator, port);
        } else {
            const port = std.fmt.parseInt(u16, trimmed, 10) catch return ScannerError.InvalidPortRange;
            if (port == 0) return ScannerError.InvalidPortRange;
            try ports.append(allocator, port);
        }
    }
}

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.c_allocator;

    var threaded = Io.Threaded.init_single_threaded;
    const main_io = threaded.io();

    // Collect args into array for indexed access
    var args_list: std.ArrayListUnmanaged([]const u8) = .empty;
    defer args_list.deinit(allocator);
    var args_iter = std.process.Args.Iterator.init(init.minimal.args);
    while (args_iter.next()) |arg| {
        try args_list.append(allocator, arg);
    }
    const args = args_list.items;

    if (args.len < 2) {
        printUsage(args[0]);
        return;
    }

    // Argument Parsing (simplified for brevity, mostly same as original)
    var parsed_config = struct {
        host: ?[]const u8 = null,
        port_spec: ?[]const u8 = null,
        timeout_ms: u32 = DEFAULT_TIMEOUT_MS,
        thread_count: usize = 10,
        verbose: bool = false,
        show_closed: bool = false,
    }{};

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--version")) { std.debug.print("v{s}\n", .{VERSION}); return; }
        else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) { printUsage(args[0]); return; }
        else if (std.mem.startsWith(u8, arg, "-p=")) { parsed_config.port_spec = arg[std.mem.indexOf(u8, arg, "=").? + 1 ..]; }
        else if (std.mem.startsWith(u8, arg, "-t=")) { parsed_config.timeout_ms = try std.fmt.parseInt(u32, arg[std.mem.indexOf(u8, arg, "=").? + 1 ..], 10); }
        else if (std.mem.startsWith(u8, arg, "-j=")) { parsed_config.thread_count = try std.fmt.parseInt(usize, arg[std.mem.indexOf(u8, arg, "=").? + 1 ..], 10); }
        else if (std.mem.eql(u8, arg, "-v")) { parsed_config.verbose = true; }
        else if (std.mem.eql(u8, arg, "-c")) { parsed_config.show_closed = true; }
        else if (!std.mem.startsWith(u8, arg, "-")) { parsed_config.host = arg; }
    }

    const host = parsed_config.host orelse { printUsage(args[0]); return error.NoHost; };
    var config = try ScanConfig.init(allocator, host);
    defer config.deinit();

    const port_spec = parsed_config.port_spec orelse "1-1000";
    try parsePortSpec(port_spec, &config.ports, allocator);
    if (config.ports.items.len == 0) return ScannerError.InvalidPortRange;

    config.timeout_ms = parsed_config.timeout_ms;
    config.thread_count = @min(parsed_config.thread_count, MAX_THREADS);
    config.verbose = parsed_config.verbose;
    config.show_closed = parsed_config.show_closed;

    const target_addr = try resolveHost(main_io, config.host);

    std.debug.print("\n🔍 zig-port-scanner v{s}\n", .{VERSION});
    std.debug.print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n", .{});
    std.debug.print("Target: {s}\n", .{config.host});
    std.debug.print("Scanning {d} ports with {d} threads\n", .{ config.ports.items.len, config.thread_count });
    std.debug.print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n\n", .{});

    // Setup signal handler
    const act = posix.Sigaction{
        .handler = .{ .handler = handleSignal },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(posix.SIG.INT, &act, null);

    // Threading Setup
    const total_ports = config.ports.items.len;
    const ports_per_thread = total_ports / config.thread_count;
    var threads = try allocator.alloc(std.Thread, config.thread_count);
    defer allocator.free(threads);
    var thread_data = try allocator.alloc(ThreadData, config.thread_count);
    defer allocator.free(thread_data);

    for (0..config.thread_count) |tid| {
        const start_idx = tid * ports_per_thread;
        const end_idx = if (tid == config.thread_count - 1) total_ports else (tid + 1) * ports_per_thread;

        thread_data[tid] = .{
            .config = &config,
            .thread_id = tid,
            .port_start_idx = start_idx,
            .port_end_idx = end_idx,
            .target_addr = target_addr,
        };
        threads[tid] = try std.Thread.spawn(.{}, scanThread, .{&thread_data[tid]});
    }

    for (threads) |thread| thread.join();
    try printResults(&config);
    std.debug.print("\n✅ Scan complete\n\n", .{});
}

fn handleSignal(_: posix.SIG) callconv(.c) void {
    running.store(false, .seq_cst);
}
