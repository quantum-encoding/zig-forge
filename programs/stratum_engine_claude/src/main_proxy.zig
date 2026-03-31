const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;

const server = @import("proxy/server.zig");
const miner_registry = @import("proxy/miner_registry.zig");
const pool_manager = @import("proxy/pool_manager.zig");
const websocket = @import("proxy/websocket.zig");
const sqlite = @import("storage/sqlite.zig");

const ProxyConfig = struct {
    stratum_port: u16 = 3333,
    websocket_port: u16 = 9999,
    db_path: []const u8 = "sentient_trader.db",
    pool_urls: []const []const u8 = &.{},
    pool_user: []const u8 = "",
    pool_password: []const u8 = "x",
    stats_interval_ms: u64 = 5000,
    health_check_interval_ms: u64 = 30000,
};

const ProxyState = struct {
    allocator: std.mem.Allocator,
    config: ProxyConfig,
    stratum_server: server.StratumServer,
    registry: miner_registry.MinerRegistry,
    pools: pool_manager.PoolManager,
    ws_broadcaster: websocket.WebSocketBroadcaster,
    db: sqlite.Database,
    running: std.atomic.Value(bool),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, config: ProxyConfig) !*Self {
        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);

        // Initialize database
        self.db = try sqlite.Database.init(allocator, config.db_path);
        errdefer self.db.deinit();

        // Initialize miner registry with default config
        self.registry = try miner_registry.MinerRegistry.init(allocator, .{});
        errdefer self.registry.deinit();

        // Initialize pool manager with default config
        self.pools = try pool_manager.PoolManager.init(allocator, .{});
        errdefer self.pools.deinit();

        // Initialize WebSocket broadcaster
        self.ws_broadcaster = try websocket.WebSocketBroadcaster.init(allocator, config.websocket_port);
        errdefer self.ws_broadcaster.deinit();

        // Initialize Stratum server
        self.stratum_server = try server.StratumServer.init(allocator, config.stratum_port);
        errdefer self.stratum_server.deinit();

        self.allocator = allocator;
        self.config = config;
        self.running = std.atomic.Value(bool).init(true);

        return self;
    }

    pub fn deinit(self: *Self) void {
        self.stratum_server.deinit();
        self.ws_broadcaster.deinit();
        self.pools.deinit();
        self.registry.deinit();
        self.db.deinit();
        self.allocator.destroy(self);
    }

    pub fn loadPoolsFromDb(self: *Self) !void {
        const pools = try self.db.loadPools();
        defer self.allocator.free(pools);

        for (pools) |pool_record| {
            const pool_config = pool_manager.PoolConfig{
                .id = pool_record.id,
                .name = pool_record.name,
                .url = pool_record.url,
                .username = pool_record.username,
                .password = pool_record.password,
                .priority = pool_record.priority,
                .enabled = pool_record.enabled,
                .reconnect_delay_s = 5,
                .max_reconnect_attempts = 10,
            };
            try self.pools.addPool(pool_config);
        }
    }
};

fn handleShare(state: *ProxyState, event: server.ShareEvent) void {
    // Update miner stats
    if (state.registry.getMiner(event.miner_id)) |miner| {
        if (event.accepted) {
            miner.shares_accepted += 1;
        } else {
            miner.shares_rejected += 1;
        }
        miner.last_share_time = std.time.timestamp();
        state.registry.addHashrateSample(event.miner_id, estimateHashrate(event.difficulty));
    }

    // Log to database
    if (state.pools.active_pool_id) |pool_id| {
        state.db.logShare(event, pool_id) catch |err| {
            std.log.err("Failed to log share to database: {}", .{err});
        };
    }

    // Broadcast to dashboard
    state.ws_broadcaster.sendShareEvent(event);
}

fn estimateHashrate(difficulty: f64) f64 {
    // Hashrate = difficulty * 2^32 / time_between_shares
    // Simplified estimation based on single share at given difficulty
    return difficulty * 4.295e9 / 10.0; // Assume ~10s between shares
}

fn handlePoolJob(state: *ProxyState, notification: pool_manager.JobNotification) void {
    // Forward new job to all connected miners
    state.stratum_server.broadcastJob(notification.job) catch |err| {
        std.log.err("Failed to broadcast job: {}", .{err});
    };

    // Broadcast pool status to dashboard
    state.ws_broadcaster.sendPoolStatus(notification.pool_id, .active, notification.difficulty);
}

fn statsThread(state: *ProxyState) void {
    const sleep_s = state.config.stats_interval_ms / 1000;
    const sleep_ns = (state.config.stats_interval_ms % 1000) * std.time.ns_per_ms;

    while (state.running.load(.acquire)) {
        var ts: linux.timespec = .{ .sec = @intCast(sleep_s), .nsec = @intCast(sleep_ns) };
        _ = linux.nanosleep(&ts, null);

        if (!state.running.load(.acquire)) break;

        // Calculate fleet stats
        const stats = state.registry.getFleetStats();

        // Broadcast to dashboard
        state.ws_broadcaster.sendStats(stats);

        // Log stats
        std.log.info("Fleet: {d} miners online, {d:.2} TH/s total", .{
            stats.online_miners,
            stats.total_hashrate_th,
        });
    }
}

fn healthCheckThread(state: *ProxyState) void {
    const sleep_s = state.config.health_check_interval_ms / 1000;
    const sleep_ns = (state.config.health_check_interval_ms % 1000) * std.time.ns_per_ms;

    while (state.running.load(.acquire)) {
        var ts: linux.timespec = .{ .sec = @intCast(sleep_s), .nsec = @intCast(sleep_ns) };
        _ = linux.nanosleep(&ts, null);

        if (!state.running.load(.acquire)) break;

        // Check pool health
        state.pools.checkHealth() catch |err| {
            std.log.warn("Pool health check failed: {}", .{err});
        };

        // Check for miner alerts
        const alerts = state.registry.getAlerts(10);
        for (alerts) |alert| {
            state.ws_broadcaster.sendAlert(alert);
            state.db.logAlert(alert) catch {};
        }
    }
}

fn parseArgs(init: std.process.Init) !ProxyConfig {
    var config = ProxyConfig{};

    var args_iter = std.process.Args.Iterator.init(init.minimal.args);

    _ = args_iter.next(); // Skip program name

    while (args_iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "--port") or std.mem.eql(u8, arg, "-p")) {
            if (args_iter.next()) |port_str| {
                config.stratum_port = std.fmt.parseInt(u16, port_str, 10) catch 3333;
            }
        } else if (std.mem.eql(u8, arg, "--ws-port")) {
            if (args_iter.next()) |port_str| {
                config.websocket_port = std.fmt.parseInt(u16, port_str, 10) catch 8080;
            }
        } else if (std.mem.eql(u8, arg, "--db")) {
            if (args_iter.next()) |db_path| {
                config.db_path = db_path;
            }
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printUsage();
            std.process.exit(0);
        }
    }

    return config;
}

fn printUsage() void {
    const usage =
        \\SentientTrader ASIC Proxy Server
        \\
        \\Usage: stratum-proxy [OPTIONS]
        \\
        \\Options:
        \\  -p, --port <PORT>       Stratum server port (default: 3333)
        \\  --ws-port <PORT>        WebSocket dashboard port (default: 9999)
        \\  --db <PATH>             SQLite database path (default: sentient_trader.db)
        \\  -h, --help              Show this help message
        \\
        \\The proxy accepts ASIC miner connections on the Stratum port and
        \\forwards work from configured mining pools. Real-time stats are
        \\broadcast via WebSocket for dashboard integration.
        \\
        \\Pool configuration is managed via the database or REST API.
        \\
    ;
    std.debug.print("{s}\n", .{usage});
}

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.c_allocator;

    const config = try parseArgs(init);

    std.log.info("Starting SentientTrader ASIC Proxy", .{});
    std.log.info("  Stratum port: {d}", .{config.stratum_port});
    std.log.info("  WebSocket port: {d}", .{config.websocket_port});
    std.log.info("  Database: {s}", .{config.db_path});

    const state = try ProxyState.init(allocator, config);
    defer state.deinit();

    // Load pools from database
    state.loadPoolsFromDb() catch |err| {
        std.log.warn("No pools loaded from database: {}", .{err});
    };

    // Setup signal handler for graceful shutdown
    const handler = struct {
        var proxy_state: ?*ProxyState = null;

        fn sigHandler(_: linux.SIG) callconv(.c) void {
            if (proxy_state) |s| {
                s.running.store(false, .release);
            }
        }
    };
    handler.proxy_state = state;

    const sigaction_val = linux.Sigaction{
        .handler = .{ .handler = handler.sigHandler },
        .mask = .{0},
        .flags = 0,
    };
    _ = linux.sigaction(linux.SIG.INT, &sigaction_val, null);
    _ = linux.sigaction(linux.SIG.TERM, &sigaction_val, null);

    // Start background threads
    const stats_thread = try std.Thread.spawn(.{}, statsThread, .{state});
    defer stats_thread.join();

    const health_thread = try std.Thread.spawn(.{}, healthCheckThread, .{state});
    defer health_thread.join();

    // Start WebSocket server in background
    const ws_thread = try std.Thread.spawn(.{}, struct {
        fn run(ws: *websocket.WebSocketBroadcaster) void {
            ws.start() catch |err| {
                std.log.err("WebSocket server error: {}", .{err});
            };
        }
    }.run, .{&state.ws_broadcaster});
    defer ws_thread.join();

    std.log.info("Proxy server started. Press Ctrl+C to stop.", .{});

    // Run Stratum server (main loop)
    state.stratum_server.start() catch |err| {
        std.log.err("Stratum server error: {}", .{err});
    };

    std.log.info("Shutting down...", .{});
}
