//! Quantum DNS Server CLI
//!
//! High-performance authoritative DNS server
//!
//! Usage:
//!   dns-server [options]
//!
//! Options:
//!   -c, --config <file>     Configuration file path
//!   -z, --zone <file>       Zone file to load (can be specified multiple times)
//!   -p, --port <port>       DNS port (default: 53)
//!   -b, --bind <address>    Bind address (default: 0.0.0.0)
//!   --tcp                   Enable TCP listener
//!   --doh                   Enable DNS over HTTPS
//!   --dot                   Enable DNS over TLS
//!   --dnssec                Enable DNSSEC signing
//!   -v, --verbose           Verbose output
//!   -h, --help              Show this help

const std = @import("std");
const dns = @import("dns");

const Server = dns.Server;
const Config = dns.Config;
const ZoneStore = dns.ZoneStore;
const ZoneParser = dns.ZoneParser;

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.c_allocator;

    var args = try parseArgs(allocator, init);
    defer args.deinit();

    if (args.show_help) {
        printHelp();
        return;
    }

    // Initialize zone store
    var zones = ZoneStore.init(allocator);
    defer zones.deinit();

    // Load zone files
    for (args.zone_files.items) |zone_file| {
        loadZoneFile(&zones, zone_file, args.verbose) catch |err| {
            std.debug.print("Error loading zone file '{s}': {}\n", .{ zone_file, err });
            return err;
        };
    }

    if (zones.zones.items.len == 0) {
        std.debug.print("Warning: No zones loaded. Server will respond with REFUSED for all queries.\n", .{});
    }

    // Build server configuration
    var bind_addr_buf: [16]u8 = undefined;
    const bind_addr = std.fmt.bufPrint(&bind_addr_buf, "{d}.{d}.{d}.{d}", .{
        args.bind_address[0],
        args.bind_address[1],
        args.bind_address[2],
        args.bind_address[3],
    }) catch "0.0.0.0";

    const config = Config{
        .listen_addr = bind_addr,
        .port = args.port,
        .tcp_port = if (args.enable_tcp) args.port else 0,
        .rate_limit_enabled = true,
        .rate_limit_qps = 100,
        .cache_enabled = true,
        .cache_size = 10000,
    };

    // Print startup banner
    printBanner(args, &zones);

    // Initialize and start server
    var server = Server.init(allocator, &zones, config);
    defer server.deinit();

    // Set up signal handlers for graceful shutdown
    setupSignalHandlers(&server);

    // Start server
    std.debug.print("Starting DNS server...\n", .{});
    server.start() catch |err| {
        std.debug.print("Server start error: {}\n", .{err});
        return err;
    };

    // Run event loop (blocking)
    server.run() catch |err| {
        std.debug.print("Server run error: {}\n", .{err});
        return err;
    };
}

const Args = struct {
    config_file: ?[]const u8 = null,
    zone_files: std.ArrayListUnmanaged([]const u8) = .empty,
    allocator: std.mem.Allocator = undefined,
    port: u16 = 53,
    bind_address: [4]u8 = .{ 0, 0, 0, 0 },
    enable_tcp: bool = true,
    enable_doh: bool = false,
    enable_dot: bool = false,
    enable_dnssec: bool = false,
    verbose: bool = false,
    show_help: bool = false,

    fn deinit(self: *Args) void {
        self.zone_files.deinit(self.allocator);
    }
};

fn parseArgs(allocator: std.mem.Allocator, init: std.process.Init) !Args {
    var args = Args{
        .zone_files = .empty,
        .allocator = allocator,
    };

    // Collect args into array for indexed access
    var args_list: std.ArrayListUnmanaged([]const u8) = .empty;
    defer args_list.deinit(allocator);
    var args_iter = std.process.Args.Iterator.init(init.minimal.args);
    while (args_iter.next()) |arg| {
        try args_list.append(allocator, arg);
    }
    const argv = args_list.items;

    // Skip program name (start at index 1)
    var i: usize = 1;

    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            args.show_help = true;
            return args;
        } else if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--verbose")) {
            args.verbose = true;
        } else if (std.mem.eql(u8, arg, "--tcp")) {
            args.enable_tcp = true;
        } else if (std.mem.eql(u8, arg, "--doh")) {
            args.enable_doh = true;
        } else if (std.mem.eql(u8, arg, "--dot")) {
            args.enable_dot = true;
        } else if (std.mem.eql(u8, arg, "--dnssec")) {
            args.enable_dnssec = true;
        } else if (std.mem.eql(u8, arg, "-c") or std.mem.eql(u8, arg, "--config")) {
            i += 1;
            if (i < argv.len) args.config_file = argv[i];
        } else if (std.mem.eql(u8, arg, "-z") or std.mem.eql(u8, arg, "--zone")) {
            i += 1;
            if (i < argv.len) {
                try args.zone_files.append(allocator, argv[i]);
            }
        } else if (std.mem.eql(u8, arg, "-p") or std.mem.eql(u8, arg, "--port")) {
            i += 1;
            if (i < argv.len) {
                args.port = std.fmt.parseInt(u16, argv[i], 10) catch 53;
            }
        } else if (std.mem.eql(u8, arg, "-b") or std.mem.eql(u8, arg, "--bind")) {
            i += 1;
            if (i < argv.len) {
                args.bind_address = parseIPv4(argv[i]) catch .{ 0, 0, 0, 0 };
            }
        }
    }

    return args;
}

fn parseIPv4(str: []const u8) ![4]u8 {
    var result: [4]u8 = undefined;
    var iter = std.mem.splitScalar(u8, str, '.');
    var i: usize = 0;

    while (iter.next()) |part| : (i += 1) {
        if (i >= 4) return error.InvalidAddress;
        result[i] = std.fmt.parseInt(u8, part, 10) catch return error.InvalidAddress;
    }

    if (i != 4) return error.InvalidAddress;
    return result;
}

fn loadZoneFile(zones: *ZoneStore, path: []const u8, verbose: bool) !void {
    if (verbose) {
        std.debug.print("Loading zone file: {s}\n", .{path});
    }

    const zone = try zones.loadFromFile(path);

    if (verbose) {
        var buf: [256]u8 = undefined;
        const origin_str = zone.origin.toString(&buf);
        std.debug.print("  Loaded zone: {s} ({d} records)\n", .{ origin_str, zone.records.items.len });
    }
}

fn printBanner(args: Args, zones: *const ZoneStore) void {
    std.debug.print(
        \\
        \\╔══════════════════════════════════════════════════════════════╗
        \\║              QUANTUM DNS SERVER v1.0.0                       ║
        \\║     High-Performance Authoritative DNS Server                ║
        \\╠══════════════════════════════════════════════════════════════╣
        \\
    , .{});

    std.debug.print("║  Bind Address: {d}.{d}.{d}.{d}:{d:<23}║\n", .{
        args.bind_address[0],
        args.bind_address[1],
        args.bind_address[2],
        args.bind_address[3],
        args.port,
    });

    std.debug.print("║  Protocols:    UDP", .{});
    if (args.enable_tcp) std.debug.print(", TCP", .{});
    if (args.enable_doh) std.debug.print(", DoH", .{});
    if (args.enable_dot) std.debug.print(", DoT", .{});
    std.debug.print("{s:<23}║\n", .{""});

    std.debug.print("║  DNSSEC:       {s:<35}║\n", .{
        if (args.enable_dnssec) "Enabled" else "Disabled",
    });

    std.debug.print("║  Zones:        {d:<35}║\n", .{zones.zones.items.len});

    std.debug.print("║  Cache:        10000 entries                      ║\n", .{});
    std.debug.print("║  Rate Limit:   100 qps                            ║\n", .{});

    std.debug.print(
        \\╚══════════════════════════════════════════════════════════════╝
        \\
    , .{});
}

fn printHelp() void {
    std.debug.print(
        \\Quantum DNS Server - High-Performance Authoritative DNS
        \\
        \\USAGE:
        \\    dns-server [OPTIONS]
        \\
        \\OPTIONS:
        \\    -c, --config <file>     Load configuration from file
        \\    -z, --zone <file>       Load zone file (can be repeated)
        \\    -p, --port <port>       DNS port (default: 53)
        \\    -b, --bind <address>    Bind address (default: 0.0.0.0)
        \\    --tcp                   Enable TCP listener (default: on)
        \\    --doh                   Enable DNS over HTTPS (port 443)
        \\    --dot                   Enable DNS over TLS (port 853)
        \\    --dnssec                Enable DNSSEC signing
        \\    -v, --verbose           Verbose output
        \\    -h, --help              Show this help
        \\
        \\EXAMPLES:
        \\    # Start server with zone file
        \\    dns-server -z /etc/dns/example.com.zone
        \\
        \\    # Start with multiple zones
        \\    dns-server -z example.com.zone -z example.org.zone
        \\
        \\    # Enable DoT and DNSSEC
        \\    dns-server --dot --dnssec -z secure.example.zone
        \\
        \\    # Custom port and address
        \\    dns-server -b 127.0.0.1 -p 5353 -z local.zone
        \\
        \\ZONE FILE FORMAT:
        \\    Standard RFC 1035 zone file format:
        \\
        \\    $ORIGIN example.com.
        \\    $TTL 3600
        \\    @       IN SOA  ns1.example.com. admin.example.com. (
        \\                    2024010101 ; serial
        \\                    3600       ; refresh
        \\                    900        ; retry
        \\                    604800     ; expire
        \\                    86400 )    ; minimum
        \\    @       IN NS   ns1.example.com.
        \\    @       IN NS   ns2.example.com.
        \\    @       IN A    192.0.2.1
        \\    www     IN A    192.0.2.2
        \\    mail    IN MX   10 mail.example.com.
        \\
    , .{});
}

fn setupSignalHandlers(server: *Server) void {
    // Store server pointer for signal handler
    signal_server = server;

    // Set up SIGINT and SIGTERM handlers
    const sigint_action = std.posix.Sigaction{
        .handler = .{ .handler = handleSignal },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };

    std.posix.sigaction(std.posix.SIG.INT, &sigint_action, null);
    std.posix.sigaction(std.posix.SIG.TERM, &sigint_action, null);
}

var signal_server: ?*Server = null;

fn handleSignal(sig: std.posix.SIG) callconv(.c) void {
    _ = sig;
    if (signal_server) |server| {
        std.debug.print("\nReceived shutdown signal, stopping server...\n", .{});
        server.stop();
    }
}
