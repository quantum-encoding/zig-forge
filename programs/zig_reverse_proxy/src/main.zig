//! Quantum Edge Proxy - CLI
//!
//! High-performance reverse proxy with WASM edge function support.
//!
//! Usage:
//!   edge-proxy [options]
//!
//! Options:
//!   -c, --config <file>   Configuration file path
//!   -p, --port <port>     Listen port (default: 8080)
//!   -b, --bind <addr>     Bind address (default: 0.0.0.0)
//!   -w, --workers <n>     Worker thread count (0 = auto)
//!   -v, --verbose         Enable verbose logging
//!   -h, --help            Show this help message
//!
//! Configuration file format (JSON):
//! {
//!   "listen": { "addr": "0.0.0.0", "port": 8080 },
//!   "backends": {
//!     "api": [
//!       { "host": "10.0.0.1", "port": 8001, "weight": 100 },
//!       { "host": "10.0.0.2", "port": 8002, "weight": 100 }
//!     ]
//!   },
//!   "routes": [
//!     { "path": "/api/", "backend": "api" },
//!     { "path": "/edge/", "wasm": "functions/handler.wasm" }
//!   ]
//! }

const std = @import("std");
const proxy = @import("proxy");

// =============================================================================
// CLI Configuration
// =============================================================================

const CliConfig = struct {
    config_file: ?[]const u8 = null,
    listen_port: u16 = 8080,
    listen_addr: []const u8 = "0.0.0.0",
    worker_threads: u32 = 0,
    verbose: bool = false,
};

// =============================================================================
// Main Entry Point
// =============================================================================

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    // Parse command line arguments
    const cli = parseArgs(init.minimal.args) catch |err| {
        if (err == error.HelpRequested) {
            return;
        }
        std.log.err("Invalid arguments: {}", .{err});
        printUsage();
        std.process.exit(1);
    };

    // Setup signal handlers
    setupSignalHandlers();

    // Log startup
    std.log.info("Quantum Edge Proxy starting...", .{});
    std.log.info("Listen: {s}:{d}", .{ cli.listen_addr, cli.listen_port });

    // Create server
    var server = proxy.ProxyServer.init(allocator, .{
        .listen_addr = cli.listen_addr,
        .listen_port = cli.listen_port,
        .worker_threads = cli.worker_threads,
        .access_log = cli.verbose,
    });
    defer server.deinit();

    // Store global reference for signal handler
    global_server = &server;

    // Load configuration if provided
    if (cli.config_file) |config_path| {
        loadConfig(&server, config_path) catch |err| {
            std.log.err("Failed to load config: {}", .{err});
            std.process.exit(1);
        };
    } else {
        // Setup default route for testing
        setupDefaultRoutes(&server) catch |err| {
            std.log.err("Failed to setup routes: {}", .{err});
            std.process.exit(1);
        };
    }

    // Print route summary
    printRoutes(&server);

    // Run server
    std.log.info("Server ready, accepting connections...", .{});
    server.run() catch |err| {
        std.log.err("Server error: {}", .{err});
        std.process.exit(1);
    };

    std.log.info("Server shutdown complete", .{});
}

// =============================================================================
// Argument Parsing
// =============================================================================

fn parseArgs(minimal_args: anytype) !CliConfig {
    var config = CliConfig{};
    var args = std.process.Args.Iterator.init(minimal_args);

    // Skip program name
    _ = args.next();

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            printUsage();
            return error.HelpRequested;
        } else if (std.mem.eql(u8, arg, "-c") or std.mem.eql(u8, arg, "--config")) {
            config.config_file = args.next() orelse return error.MissingArgument;
        } else if (std.mem.eql(u8, arg, "-p") or std.mem.eql(u8, arg, "--port")) {
            const port_str = args.next() orelse return error.MissingArgument;
            config.listen_port = std.fmt.parseInt(u16, port_str, 10) catch return error.InvalidPort;
        } else if (std.mem.eql(u8, arg, "-b") or std.mem.eql(u8, arg, "--bind")) {
            config.listen_addr = args.next() orelse return error.MissingArgument;
        } else if (std.mem.eql(u8, arg, "-w") or std.mem.eql(u8, arg, "--workers")) {
            const workers_str = args.next() orelse return error.MissingArgument;
            config.worker_threads = std.fmt.parseInt(u32, workers_str, 10) catch return error.InvalidWorkers;
        } else if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--verbose")) {
            config.verbose = true;
        } else {
            std.log.err("Unknown argument: {s}", .{arg});
            return error.UnknownArgument;
        }
    }

    return config;
}

fn printUsage() void {
    const usage =
        \\Quantum Edge Proxy - High-performance reverse proxy with WASM edge functions
        \\
        \\Usage:
        \\  edge-proxy [options]
        \\
        \\Options:
        \\  -c, --config <file>   Configuration file path (JSON)
        \\  -p, --port <port>     Listen port (default: 8080)
        \\  -b, --bind <addr>     Bind address (default: 0.0.0.0)
        \\  -w, --workers <n>     Worker thread count (0 = auto)
        \\  -v, --verbose         Enable verbose logging
        \\  -h, --help            Show this help message
        \\
        \\Examples:
        \\  edge-proxy -p 80 -c /etc/proxy/config.json
        \\  edge-proxy -b 127.0.0.1 -p 8080 -v
        \\
        \\Configuration file format (JSON):
        \\  {
        \\    "listen": { "addr": "0.0.0.0", "port": 8080 },
        \\    "backends": {
        \\      "api": [{ "host": "10.0.0.1", "port": 8001 }]
        \\    },
        \\    "routes": [
        \\      { "path": "/api/", "backend": "api" },
        \\      { "path": "/edge/", "wasm": "functions/handler.wasm" }
        \\    ]
        \\  }
        \\
    ;
    std.debug.print("{s}", .{usage});
}

// =============================================================================
// Configuration Loading
// =============================================================================

fn loadConfig(server: *proxy.ProxyServer, path: []const u8) !void {
    const io = std.Io.Threaded.global_single_threaded.io();
    const allocator = server.allocator;

    // Use readFileAlloc for simpler file reading (Zig 0.16.1859)
    const data = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, std.Io.Limit.limited(10 * 1024 * 1024));
    defer allocator.free(data);

    // Parse JSON configuration
    try parseJsonConfig(server, data);

    std.log.info("Loaded configuration from: {s}", .{path});
}

fn parseJsonConfig(server: *proxy.ProxyServer, data: []const u8) !void {
    // Simple JSON parser for configuration
    // In production, would use a proper JSON library

    // Find backends section
    if (findJsonSection(data, "backends")) |backends_section| {
        try parseBackendsSection(server, backends_section);
    }

    // Find routes section
    if (findJsonSection(data, "routes")) |routes_section| {
        try parseRoutesSection(server, routes_section);
    }
}

fn findJsonSection(data: []const u8, key: []const u8) ?[]const u8 {
    // Find "key": and return content after it
    var search_buf: [256]u8 = undefined;
    const search_key = std.fmt.bufPrint(&search_buf, "\"{s}\"", .{key}) catch return null;

    if (std.mem.indexOf(u8, data, search_key)) |pos| {
        // Find the colon and opening bracket
        const after_key = data[pos + search_key.len ..];
        if (std.mem.indexOf(u8, after_key, ":")) |colon_pos| {
            return after_key[colon_pos + 1 ..];
        }
    }
    return null;
}

fn parseBackendsSection(server: *proxy.ProxyServer, _: []const u8) !void {
    // Simplified - would parse JSON properly in production
    // For now, create a default pool
    const pool = try server.createPool("default");
    try pool.addBackend(.{
        .host = "127.0.0.1",
        .port = 8081,
    });
}

fn parseRoutesSection(server: *proxy.ProxyServer, _: []const u8) !void {
    // Simplified - would parse JSON properly in production
    // For now, setup default route
    if (server.getPool("default")) |pool| {
        try server.getRouter().addPrefix("/", pool);
    }
}

fn setupDefaultRoutes(server: *proxy.ProxyServer) !void {
    // Create default backend pool
    const pool = try server.createPool("default");
    try pool.addBackend(.{
        .host = "127.0.0.1",
        .port = 8081,
        .health_check_path = "/health",
    });

    // Setup routes
    const router_inst = server.getRouter();

    // Health check endpoint (static response)
    try router_inst.addRoute(.{
        .name = "health",
        .matcher = .{
            .path = .{ .pattern = "/health", .match_type = .exact },
        },
        .target = .{
            .static = .{
                .status = 200,
                .content_type = "application/json",
                .body = "{\"status\":\"healthy\"}",
            },
        },
    });

    // Default route to backend
    router_inst.setDefault(pool);

    std.log.info("Default routes configured:", .{});
    std.log.info("  /health -> static health check", .{});
    std.log.info("  /* -> backend pool (127.0.0.1:8081)", .{});
}

fn printRoutes(server: *proxy.ProxyServer) void {
    const router_inst = server.getRouter();

    std.log.info("Routes configured: {d}", .{router_inst.routes.items.len});

    for (router_inst.routes.items) |route| {
        const target_type: []const u8 = switch (route.target) {
            .backend => "backend",
            .wasm => "wasm",
            .static => "static",
            .redirect => "redirect",
        };
        std.log.info("  {s} -> {s}", .{ route.name, target_type });
    }
}

// =============================================================================
// Signal Handling
// =============================================================================

var global_server: ?*proxy.ProxyServer = null;

fn setupSignalHandlers() void {
    const handler = std.posix.Sigaction{
        .handler = .{ .handler = handleSignal },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };

    std.posix.sigaction(std.posix.SIG.INT, &handler, null);
    std.posix.sigaction(std.posix.SIG.TERM, &handler, null);
}

fn handleSignal(sig: std.posix.SIG) callconv(.c) void {
    _ = sig;
    std.log.info("Received shutdown signal", .{});

    if (global_server) |server| {
        server.stop();
    }
}
