// QUANTUM SYNAPSE ENGINE V1.0
// Multi-Tenant Financial Trading Service
// Production-grade algorithmic trading platform with risk management

const std = @import("std");
const qse = @import("quantum_synapse_v2.zig");
const alpaca = @import("alpaca_websocket.zig");
const alpaca_real = @import("alpaca_websocket_real.zig");
const api = @import("alpaca_trading_api.zig");
const praetorian = @import("praetorian_guard.zig");
const config = @import("config.zig");
const Decimal = @import("decimal.zig").Decimal;
const sync = @import("sync.zig");

// ============================================================================
// TENANT ALGORITHM DEFINITIONS
// ============================================================================

pub const TenantAlgorithm = struct {
    tenant_id: []const u8,
    name: []const u8,
    tier: []const u8,
    allocated_cores: []const u8,
    memory_limit_mb: u32,
    
    // Algorithm-specific parameters
    algorithm_type: AlgorithmType,
    symbols: []const []const u8,
    
    // Performance metrics
    packets_processed: std.atomic.Value(u64),
    orders_executed: std.atomic.Value(u64),
    pnl: std.atomic.Value(i64),
    
    // Resource tracking for billing
    cpu_time_ns: std.atomic.Value(u64),
    api_calls: std.atomic.Value(u64),
    
    const AlgorithmType = enum {
        spy_hunter,
        momentum_scanner,
        mean_reversion,
    };
};

// ============================================================================
// API CLIENT FACTORY (CREATES ISOLATED CLIENTS PER TENANT)
// ============================================================================

pub const ApiClientFactory = struct {
    api_key: []const u8,
    api_secret: []const u8,
    allocator: std.mem.Allocator,
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator, api_key: []const u8, api_secret: []const u8) !Self {
        // Store copies of the credentials
        const key_copy = try allocator.dupe(u8, api_key);
        const secret_copy = try allocator.dupe(u8, api_secret);
        
        return .{
            .api_key = key_copy,
            .api_secret = secret_copy,
            .allocator = allocator,
        };
    }
    
    pub fn createClient(self: *Self) !*api.AlpacaTradingAPI {
        const client = try self.allocator.create(api.AlpacaTradingAPI);
        client.* = api.AlpacaTradingAPI.init(
            self.allocator,
            self.api_key,
            self.api_secret,
            true // paper trading
        );
        return client;
    }
    
    pub fn deinit(self: *Self) void {
        self.allocator.free(self.api_key);
        self.allocator.free(self.api_secret);
    }
};

// ============================================================================
// TENANT-SPECIFIC API CLIENT WITH INTERNAL MUTEX
// ============================================================================

pub const TenantApiClient = struct {
    client: *api.AlpacaTradingAPI,
    mutex: sync.SpinLock,
    allocator: std.mem.Allocator,
    tenant_id: []const u8,
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator, factory: *ApiClientFactory, tenant_id: []const u8) !Self {
        const client = try factory.createClient();
        
        return .{
            .client = client,
            .mutex = .{},
            .allocator = allocator,
            .tenant_id = tenant_id,
        };
    }
    
    pub fn placeOrder(self: *Self, order_request: api.AlpacaTradingAPI.OrderRequest) !api.AlpacaTradingAPI.OrderResponse {
        // Each tenant has its own client, but still use mutex for safety
        self.mutex.lock();
        defer self.mutex.unlock();
        
        std.log.debug("[{s}] Placing order for {s}", .{
            self.tenant_id,
            order_request.symbol,
        });
        
        const result = self.client.placeOrder(order_request) catch |err| {
            std.log.err("[{s}] API order placement failed: {}", .{ self.tenant_id, err });
            return err;
        };
        
        return result;
    }
    
    pub fn deinit(self: *Self) void {
        self.client.deinit();
        self.allocator.destroy(self.client);
    }
};

// ============================================================================
// TENANT ISOLATION ENGINE
// ============================================================================

pub const TenantEngine = struct {
    allocator: std.mem.Allocator,
    tenant: *TenantAlgorithm,
    api_client: TenantApiClient,
    praetorian_guard: ?*praetorian.PraetorianGuard,
    
    // Isolated queues for this tenant
    quote_queue: LockFreeQueue(Quote, 1024),
    order_queue: LockFreeQueue(Order, 256),
    
    // Thread handle for isolated execution
    execution_thread: ?std.Thread,
    should_stop: std.atomic.Value(bool),
    
    const Self = @This();
    
    const Quote = struct {
        symbol: [16]u8,
        bid: Decimal,
        ask: Decimal,
        volume: u32,
        timestamp: i64,
    };
    
    const Order = struct {
        symbol: [16]u8,
        side: enum { buy, sell },
        quantity: u32,
        order_type: enum { market, limit },
        price: ?Decimal,
    };
    
    // Simple lock-free queue for tenant isolation
    fn LockFreeQueue(comptime T: type, comptime size: usize) type {
        return struct {
            buffer: [size]T,
            head: std.atomic.Value(usize),
            tail: std.atomic.Value(usize),
            
            pub fn init() @This() {
                return .{
                    .buffer = undefined,
                    .head = std.atomic.Value(usize).init(0),
                    .tail = std.atomic.Value(usize).init(0),
                };
            }
            
            pub fn push(self: *@This(), item: T) bool {
                const current_head = self.head.load(.acquire);
                const next_head = (current_head + 1) % size;
                const current_tail = self.tail.load(.acquire);
                
                if (next_head == current_tail) return false;
                
                self.buffer[current_head] = item;
                self.head.store(next_head, .release);
                return true;
            }
            
            pub fn pop(self: *@This()) ?T {
                const current_tail = self.tail.load(.acquire);
                const current_head = self.head.load(.acquire);
                
                if (current_tail == current_head) return null;
                
                const item = self.buffer[current_tail];
                self.tail.store((current_tail + 1) % size, .release);
                return item;
            }
        };
    }
    
    pub fn init(allocator: std.mem.Allocator, tenant: *TenantAlgorithm, factory: *ApiClientFactory, guard: *?praetorian.PraetorianGuard) !Self {
        const api_client = try TenantApiClient.init(allocator, factory, tenant.tenant_id);
        
        return .{
            .allocator = allocator,
            .tenant = tenant,
            .api_client = api_client,
            .praetorian_guard = if (guard.*) |*g| g else null,
            .quote_queue = LockFreeQueue(Quote, 1024).init(),
            .order_queue = LockFreeQueue(Order, 256).init(),
            .execution_thread = null,
            .should_stop = std.atomic.Value(bool).init(false),
        };
    }
    
    pub fn start(self: *Self) !void {
        std.log.info("[{s}] Starting tenant engine - Tier: {s}", .{ self.tenant.tenant_id, self.tenant.tier });
        self.should_stop.store(false, .release);
        self.execution_thread = try std.Thread.spawn(.{}, executionLoop, .{self});
    }
    
    fn executionLoop(self: *Self) !void {
        const start_time = sync.nowNanos();
        
        std.log.info("[{s}] Algorithm execution started", .{self.tenant.tenant_id});
        
        while (!self.should_stop.load(.acquire)) {
            // Process incoming quotes
            if (self.quote_queue.pop()) |quote| {
                const process_start = sync.nowNanos();
                
                // Execute tenant-specific algorithm
                switch (self.tenant.algorithm_type) {
                    .spy_hunter => self.executeSPYHunter(quote),
                    .momentum_scanner => self.executeMomentumScanner(quote),
                    .mean_reversion => self.executeMeanReversion(quote),
                }
                
                const process_end = sync.nowNanos();
                _ = self.tenant.cpu_time_ns.fetchAdd(@intCast(process_end - process_start), .monotonic);
                _ = self.tenant.packets_processed.fetchAdd(1, .monotonic);
            }
            
            // Process pending orders
            if (self.order_queue.pop()) |order| {
                self.executeOrder(order) catch |err| {
                    std.log.err("[{s}] Order execution failed: {}", .{ self.tenant.tenant_id, err });
                };
            }
            
            sync.sleepNs(1 * std.time.ns_per_ms);
        }
        
        const total_runtime = sync.nowNanos() - start_time;
        std.log.info("[{s}] Algorithm stopped. Runtime: {}ms", .{ 
            self.tenant.tenant_id, 
            @divTrunc(total_runtime, std.time.ns_per_ms)
        });
    }
    
    fn executeSPYHunter(self: *Self, quote: Quote) void {
        const symbol_str = std.mem.sliceTo(&quote.symbol, 0);
        
        if (std.mem.eql(u8, symbol_str, "SPY")) {
            // SPY DETECTED - IMMEDIATE ACTION
            const spread = quote.ask.sub(quote.bid) catch Decimal.zero();
            
            if (spread.lessThan(Decimal{ .value = 100_000_000 })) { // Tight spread, good for execution ($0.10 = 100M n_ticks)
                const bid_major = @divTrunc(quote.bid.value, 1_000_000_000);
                const bid_minor = @divTrunc(@mod(quote.bid.value, 1_000_000_000), 10_000_000);
                const ask_major = @divTrunc(quote.ask.value, 1_000_000_000);
                const ask_minor = @divTrunc(@mod(quote.ask.value, 1_000_000_000), 10_000_000);
                std.log.info("[{s}] 🎯 SPY HUNT TRIGGERED: bid=${d}.{d:0>2} ask=${d}.{d:0>2}", 
                    .{ self.tenant.tenant_id, bid_major, bid_minor, ask_major, ask_minor });
                
                const order = Order{
                    .symbol = quote.symbol,
                    .side = .buy,
                    .quantity = 1,
                    .order_type = .market,
                    .price = null,
                };
                
                if (!self.order_queue.push(order)) {
                    std.log.warn("[{s}] Order queue full", .{self.tenant.tenant_id});
                }
            }
        }
    }
    
    fn executeMomentumScanner(self: *Self, quote: Quote) void {
        const symbol_str = std.mem.sliceTo(&quote.symbol, 0);
        
        // Simple momentum detection: large volume with price movement
        if (quote.volume > 100000) {
            const mid_price = Decimal{ .value = @divTrunc(quote.bid.value + quote.ask.value, 2) };
            
            // Simplified momentum signal (in production would track price history)
            if (mid_price.value > 0) {
                const mid_major = @divTrunc(mid_price.value, 1_000_000_000);
                const mid_minor = @divTrunc(@mod(mid_price.value, 1_000_000_000), 10_000_000);
                std.log.info("[{s}] 📈 Momentum detected in {s}: price=${d}.{d:0>2} volume={}", 
                    .{ self.tenant.tenant_id, symbol_str, mid_major, mid_minor, quote.volume });
                
                const order = Order{
                    .symbol = quote.symbol,
                    .side = .buy,
                    .quantity = 10,
                    .order_type = .limit,
                    .price = quote.bid.add(Decimal{ .value = 10_000_000 }) catch quote.bid, // bid + 0.01
                };
                
                _ = self.order_queue.push(order);
            }
        }
    }
    
    fn executeMeanReversion(self: *Self, quote: Quote) void {
        const symbol_str = std.mem.sliceTo(&quote.symbol, 0);
        const mid_price = Decimal{ .value = @divTrunc(quote.bid.value + quote.ask.value, 2) };
        
        // Simplified mean reversion (in production would calculate Bollinger Bands)
        // Execute trade when spread threshold is met
        const spread = quote.ask.sub(quote.bid) catch Decimal.zero();
        
        if (mid_price.value > 0 and spread.value * 1000 > mid_price.value * 2) { // 0.2% spread
            const spread_pct_val = @divTrunc(spread.value * 10000, mid_price.value);
            const pct_major = @divTrunc(spread_pct_val, 100);
            const pct_minor = @mod(spread_pct_val, 100);
            std.log.info("[{s}] 📊 Mean reversion opportunity in {s}: spread={d}.{d:0>2}%", 
                .{ self.tenant.tenant_id, symbol_str, pct_major, pct_minor });
            
            // Buy at bid, sell at ask for mean reversion
            const order = Order{
                .symbol = quote.symbol,
                .side = .buy,
                .quantity = 5,
                .order_type = .limit,
                .price = quote.bid,
            };
            
            _ = self.order_queue.push(order);
        }
    }
    
    fn executeOrder(self: *Self, order: Order) !void {
        const symbol_str = std.mem.sliceTo(&order.symbol, 0);
        
        // === PRAETORIAN GUARD VALIDATION ===
        if (self.praetorian_guard) |guard| {
            const side = if (order.side == .buy) api.AlpacaTradingAPI.OrderSide.buy else api.AlpacaTradingAPI.OrderSide.sell;
            const validation = try guard.validateOrder(
                self.tenant.tenant_id,
                symbol_str,
                side,
                order.quantity,
                order.price,
            );
            
            if (!validation.approved) {
                std.log.warn("[{s}] 🛡️ Order rejected by Praetorian Guard: {s}", .{
                    self.tenant.tenant_id,
                    validation.reason,
                });
                if (validation.allocated_capital.greaterThan(Decimal.zero())) {
                    std.log.info("[{s}]    Allocated capital: ${d:.2}", .{
                        self.tenant.tenant_id,
                        validation.allocated_capital.toFloat(),
                    });
                }
                return;
            }
        }
        
        // Add a small random delay to reduce simultaneous API calls
        const delay = sync.nonce32() % 100;
        sync.sleepNs(delay * std.time.ns_per_ms);
        
        std.log.info("[{s}] 📤 Placing order: {} {} {s} @ {s}", .{
            self.tenant.tenant_id,
            order.side,
            order.quantity,
            symbol_str,
            @tagName(order.order_type),
        });
        
        // Create unique order ID with tenant prefix
        const unique_order_id = try std.fmt.allocPrint(
            self.allocator,
            "{s}_{d}_{d}",
            .{ self.tenant.tenant_id, sync.nowSeconds(), sync.nonce32() }
        );
        defer self.allocator.free(unique_order_id);
        
        const order_request = api.AlpacaTradingAPI.OrderRequest{
            .symbol = symbol_str,
            .qty = order.quantity,
            .side = if (order.side == .buy) .buy else .sell,
            .type = if (order.order_type == .market) .market else .limit,
            .time_in_force = .day,
            .limit_price = order.price,
            .client_order_id = unique_order_id,
            .extended_hours = false,
        };
        
        const response = self.api_client.placeOrder(order_request) catch |err| {
            std.log.err("[{s}] ❌ Order failed: {}", .{ self.tenant.tenant_id, err });
            return;
        };
        
        std.log.info("[{s}] ✅ Order placed: ID={s} Status={s}", .{
            self.tenant.tenant_id,
            response.id,
            response.status,
        });
        _ = self.tenant.orders_executed.fetchAdd(1, .monotonic);
        _ = self.tenant.api_calls.fetchAdd(1, .monotonic);
    }
    
    pub fn injectQuote(self: *Self, symbol: []const u8, bid: Decimal, ask: Decimal, volume: u32) void {
        var quote = Quote{
            .symbol = std.mem.zeroes([16]u8),
            .bid = bid,
            .ask = ask,
            .volume = volume,
            .timestamp = sync.nowSeconds(),
        };
        
        const copy_len = @min(symbol.len, quote.symbol.len - 1);
        @memcpy(quote.symbol[0..copy_len], symbol[0..copy_len]);
        
        _ = self.quote_queue.push(quote);
    }
    
    pub fn stop(self: *Self) void {
        std.log.info("[{s}] Stopping tenant engine", .{self.tenant.tenant_id});
        self.should_stop.store(true, .release);
        
        if (self.execution_thread) |thread| {
            thread.join();
            self.execution_thread = null;
        }
    }
    
    pub fn reportMetrics(self: *Self) void {
        const packets = self.tenant.packets_processed.load(.monotonic);
        const orders = self.tenant.orders_executed.load(.monotonic);
        const cpu_ns = self.tenant.cpu_time_ns.load(.monotonic);
        const api_calls = self.tenant.api_calls.load(.monotonic);
        
        std.log.info("", .{});
        std.log.info("📊 [{s}] TENANT METRICS", .{self.tenant.tenant_id});
        std.log.info("  Tier: {s}", .{self.tenant.tier});
        std.log.info("  Packets Processed: {}", .{packets});
        std.log.info("  Orders Executed: {}", .{orders});
        std.log.info("  CPU Time: {}ms", .{cpu_ns / std.time.ns_per_ms});
        std.log.info("  API Calls: {}", .{api_calls});
        
        // Calculate billing using exact fixed-point Decimal
        const packet_cost_dec = Decimal{ .value = @as(i128, packets) * 1000 };
        const order_cost_dec = Decimal{ .value = @as(i128, orders) * 2_000_000 };
        const total_cost_dec = packet_cost_dec.add(order_cost_dec) catch packet_cost_dec;
        
        const tc_major = @divTrunc(total_cost_dec.value, 1_000_000_000);
        const tc_minor = @divTrunc(@mod(total_cost_dec.value, 1_000_000_000), 100_000); // 4 decimal places
        const pc_major = @divTrunc(packet_cost_dec.value, 1_000_000_000);
        const pc_minor = @divTrunc(@mod(packet_cost_dec.value, 1_000_000_000), 100_000); // 4 decimal places
        const oc_major = @divTrunc(order_cost_dec.value, 1_000_000_000);
        const oc_minor = @divTrunc(@mod(order_cost_dec.value, 1_000_000_000), 100_000); // 4 decimal places
        
        std.log.info("  💰 Billing: ${d}.{d:0>4} (packets: ${d}.{d:0>4}, orders: ${d}.{d:0>4})", 
            .{ tc_major, tc_minor, pc_major, pc_minor, oc_major, oc_minor });
    }
    
    pub fn deinit(self: *Self) void {
        self.stop();
        // Each tenant owns its API client, clean it up
        self.api_client.deinit();
    }
};

// ============================================================================
// MULTI-TENANT ORCHESTRATOR
// ============================================================================

pub const MultiTenantOrchestrator = struct {
    allocator: std.mem.Allocator,
    tenants: std.ArrayList(TenantEngine),
    algorithms: std.ArrayList(TenantAlgorithm),
    api_factory: ?ApiClientFactory,
    ws_client: ?*alpaca_real.AlpacaWebSocketReal,
    praetorian_guard: ?praetorian.PraetorianGuard,
    
    // Global metrics
    total_packets: std.atomic.Value(u64),
    total_orders: std.atomic.Value(u64),
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator) !Self {
        var tenants = std.ArrayList(TenantEngine).empty;
        try tenants.ensureTotalCapacity(allocator, 10);

        var algorithms = std.ArrayList(TenantAlgorithm).empty;
        try algorithms.ensureTotalCapacity(allocator, 10);

        return .{
            .allocator = allocator,
            .tenants = tenants,
            .algorithms = algorithms,
            .api_factory = null,
            .ws_client = null,
            .praetorian_guard = null,
            .total_packets = std.atomic.Value(u64).init(0),
            .total_orders = std.atomic.Value(u64).init(0),
        };
    }
    
    pub fn initializeApiFactory(self: *Self) !void {
        const api_key = std.process.getEnvVarOwned(self.allocator, "APCA_API_KEY_ID") catch {
            std.log.err("Missing APCA_API_KEY_ID", .{});
            return error.MissingCredentials;
        };
        defer self.allocator.free(api_key);
        
        const api_secret = std.process.getEnvVarOwned(self.allocator, "APCA_API_SECRET_KEY") catch {
            std.log.err("Missing APCA_API_SECRET_KEY", .{});
            return error.MissingCredentials;
        };
        defer self.allocator.free(api_secret);
        
        self.api_factory = try ApiClientFactory.init(self.allocator, api_key, api_secret);
        std.log.info("✅ API client factory initialized (creates isolated clients per tenant)", .{});
        
        // Initialize Praetorian Guard risk manager
        if (self.api_factory) |*factory| {
            self.praetorian_guard = try praetorian.PraetorianGuard.init(self.allocator, factory);
            std.log.info("🛡️ PRAETORIAN GUARD initialized - Risk management active", .{});
            
            // Update account state on initialization
            if (self.praetorian_guard) |*guard| {
                guard.updateAccountState() catch |err| {
                    std.log.warn("Failed to update account state: {}", .{err});
                };
            }
        }
    }
    
    pub fn addTenant(self: *Self, tenant_id: []const u8, name: []const u8, tier: []const u8, algo_type: TenantAlgorithm.AlgorithmType, symbols: []const []const u8) !void {
        const algorithm = TenantAlgorithm{
            .tenant_id = tenant_id,
            .name = name,
            .tier = tier,
            .allocated_cores = &[_]u8{},
            .memory_limit_mb = 256,
            .algorithm_type = algo_type,
            .symbols = symbols,
            .packets_processed = std.atomic.Value(u64).init(0),
            .orders_executed = std.atomic.Value(u64).init(0),
            .pnl = std.atomic.Value(i64).init(0),
            .cpu_time_ns = std.atomic.Value(u64).init(0),
            .api_calls = std.atomic.Value(u64).init(0),
        };
        
        try self.algorithms.append(self.allocator, algorithm);
        
        // Ensure API factory is initialized
        if (self.api_factory == null) {
            return error.ApiFactoryNotInitialized;
        }
        
        const engine = try TenantEngine.init(
            self.allocator,
            &self.algorithms.items[self.algorithms.items.len - 1],
            &self.api_factory.?,
            &self.praetorian_guard
        );
        
        try self.tenants.append(self.allocator, engine);
        
        // Register tenant with Praetorian Guard
        if (self.praetorian_guard) |*guard| {
            // Define risk limits based on tier. Decimal literals — never
            // f64 — so the guard's overflow-checked integer math operates
            // on bit-identical values across every tenant tier.
            const DecimalT = @import("decimal.zig").Decimal;
            const limits = switch (algo_type) {
                .spy_hunter => praetorian.RiskLimits{
                    .max_position_size_usd = DecimalT.fromInt(5_000),
                    .max_orders_per_minute = 10,
                    .max_total_exposure_usd = DecimalT.fromInt(20_000),
                    .max_positions = 5,
                },
                .momentum_scanner => praetorian.RiskLimits{
                    .max_position_size_usd = DecimalT.fromInt(10_000),
                    .max_orders_per_minute = 20,
                    .max_total_exposure_usd = DecimalT.fromInt(40_000),
                    .max_positions = 8,
                },
                .mean_reversion => praetorian.RiskLimits{
                    .max_position_size_usd = DecimalT.fromInt(3_000),
                    .max_orders_per_minute = 30,
                    .max_total_exposure_usd = DecimalT.fromInt(15_000),
                    .max_positions = 10,
                },
            };
            
            // Equal capital allocation across all tenants, in basis points
            // (10000 = 100.00%). Strict integer division — no f64 in routing.
            // Guard div-by-zero (the enclosing loop implies len >= 1).
            const tenant_count = self.tenants.items.len;
            const capital_bps: u32 = if (tenant_count == 0) 10000 else @intCast(10000 / tenant_count);

            try guard.registerTenant(tenant_id, limits, capital_bps);
        }
    }
    
    pub fn connectMarketData(self: *Self, use_real_data: bool) !void {
        const api_key = std.process.getEnvVarOwned(self.allocator, "APCA_API_KEY_ID") catch {
            std.log.err("Missing APCA_API_KEY_ID", .{});
            return error.MissingCredentials;
        };
        defer self.allocator.free(api_key);
        
        const api_secret = std.process.getEnvVarOwned(self.allocator, "APCA_API_SECRET_KEY") catch {
            std.log.err("Missing APCA_API_SECRET_KEY", .{});
            return error.MissingCredentials;
        };
        defer self.allocator.free(api_secret);
        
        if (use_real_data) {
            std.log.info("🌐 Connecting to REAL market data for multi-tenant system", .{});
            
            self.ws_client = try self.allocator.create(alpaca_real.AlpacaWebSocketReal);
            self.ws_client.?.* = try alpaca_real.AlpacaWebSocketReal.init(
                self.allocator,
                api_key,
                api_secret,
                true // paper trading
            );
            
            try self.ws_client.?.connect();
            
            // Subscribe to all tenant symbols
            const all_symbols = [_][]const u8{
                "SPY", "QQQ", "AAPL", "MSFT", "NVDA", "TSLA", "AMD", "META", "IWM", "DIA"
            };
            try self.ws_client.?.subscribe(&all_symbols);
        } else {
            std.log.info("📊 Market data: SIMULATION MODE", .{});
        }
    }
    
    pub fn start(self: *Self) !void {
        std.log.info("", .{});
        std.log.info("╔══════════════════════════════════════════════════════╗", .{});
        std.log.info("║        QUANTUM SYNAPSE ENGINE - PRODUCTION          ║", .{});
        std.log.info("║            {} Tenants Running in Parallel            ║", .{self.tenants.items.len});
        std.log.info("╚══════════════════════════════════════════════════════╝", .{});
        std.log.info("", .{});
        
        // STAGGERED DEPLOYMENT: Launch tenants one by one with delay
        std.log.info("🚀 INITIATING STAGGERED TENANT DEPLOYMENT", .{});
        for (self.tenants.items, 0..) |*tenant, idx| {
            std.log.info("🔄 [{}/{}] Launching tenant: {s}...", .{
                idx + 1,
                self.tenants.items.len,
                tenant.tenant.tenant_id,
            });
            
            try tenant.start();
            
            std.log.info("✅ [{}/{}] Tenant {s} launched successfully", .{
                idx + 1,
                self.tenants.items.len,
                tenant.tenant.tenant_id,
            });
            
            // 1 second delay between tenant launches for stability
            if (idx < self.tenants.items.len - 1) {
                std.log.info("⏳ Waiting 1 second before next tenant...", .{});
                sync.sleepNs(1 * std.time.ns_per_s);
            }
        }
        
        std.log.info("🎯 ALL TENANTS DEPLOYED SUCCESSFULLY", .{});
        
        // Start market data distribution thread
        std.log.info("📡 Starting market data distributor...", .{});
        _ = try std.Thread.spawn(.{}, marketDataDistributor, .{self});
    }
    
    fn marketDataDistributor(self: *Self) !void {
        std.log.info("📡 Market data distributor started", .{});
        
        while (true) {
            if (self.ws_client) |client| {
                // Get real market data
                if (client.quote_queue.pop()) |quote| {
                    std.log.info("WebSocket: Received 1 packet", .{});
                    
                    // Distribute to all relevant tenants
                    std.log.info("Distributor: Looping over {} tenants", .{self.tenants.items.len});
                    for (self.tenants.items) |*tenant| {
                        const symbol_str = std.mem.sliceTo(&quote.symbol, 0);
                        
                        // Check if this tenant is interested in this symbol
                        for (tenant.tenant.symbols) |tenant_symbol| {
                            if (std.mem.eql(u8, symbol_str, tenant_symbol)) {
                                std.log.info("Distributor: Pushing packet to tenant {s} for symbol {s}", .{ tenant.tenant.tenant_id, symbol_str });
                                tenant.injectQuote(symbol_str, quote.bid_price, quote.ask_price, quote.bid_size);
                                _ = self.total_packets.fetchAdd(1, .monotonic);
                                break;
                            }
                        }
                    }
                } else {
                    // No data available - add debug info
                    std.log.info("Distributor: No quotes available in queue", .{});
                }
            } else {
                // Generate simulated market data (non-crypto PRNG — fake data,
                // not security-sensitive; std.crypto.random was removed in 0.16).
                const symbols = [_][]const u8{ "SPY", "AAPL", "MSFT", "QQQ", "NVDA" };
                var prng = std.Random.DefaultPrng.init(@truncate(@as(u128, @bitCast(sync.nowNanos()))));
                const random = prng.random();
                
                for (symbols) |symbol| {
                    const base_price = Decimal{ .value = 100_000_000_000 + @as(i128, random.int(u8)) * 100_000_000 };
                    const spread = Decimal{ .value = 10_000_000 + @as(i128, random.int(u8)) * 1_000_000 };
                    const ask_price = base_price.add(spread) catch base_price;
                    
                    for (self.tenants.items) |*tenant| {
                        tenant.injectQuote(symbol, base_price, ask_price, random.int(u32) % 1000000);
                    }
                }
                
                sync.sleepNs(100 * std.time.ns_per_ms);
            }
            
            sync.sleepNs(10 * std.time.ns_per_ms);
        }
    }
    
    pub fn reportGlobalMetrics(self: *Self) void {
        std.log.info("", .{});
        std.log.info("═══════════════════════════════════════════════════════", .{});
        std.log.info("           🏢 MULTI-TENANT ENGINE METRICS", .{});
        std.log.info("═══════════════════════════════════════════════════════", .{});
        
        var total_packets: u64 = 0;
        var total_orders: u64 = 0;
        const total_revenue: f64 = 0;
        
        for (self.tenants.items) |*tenant| {
            tenant.reportMetrics();
            total_packets += tenant.tenant.packets_processed.load(.monotonic);
            total_orders += tenant.tenant.orders_executed.load(.monotonic);
        }
        
        std.log.info("", .{});
        std.log.info("📈 GLOBAL TOTALS:", .{});
        std.log.info("  Total Tenants: {}", .{self.tenants.items.len});
        std.log.info("  Total Packets: {}", .{total_packets});
        std.log.info("  Total Orders: {}", .{total_orders});
        std.log.info("  💰 Total Platform Revenue: ${d:.2}", .{total_revenue});
        std.log.info("═══════════════════════════════════════════════════════", .{});
    }
    
    pub fn deinit(self: *Self) void {
        for (self.tenants.items) |*tenant| {
            tenant.deinit();
        }
        
        if (self.praetorian_guard) |*guard| {
            guard.printReport();
            guard.deinit();
        }
        
        if (self.api_factory) |*factory| {
            factory.deinit();
        }
        
        if (self.ws_client) |client| {
            client.deinit();
            self.allocator.destroy(client);
        }
        
        self.tenants.deinit(self.allocator);
        self.algorithms.deinit(self.allocator);
    }
};

// ============================================================================
// SERVICE ENTRYPOINT
// ============================================================================

pub fn main() !void {
    const allocator = std.heap.c_allocator;
    
    // Load configuration from file
    const config_path = std.process.getEnvVarOwned(allocator, "QSE_CONFIG_PATH") catch 
        try allocator.dupe(u8, "/app/config/production.json");
    defer allocator.free(config_path);
    
    var cfg_loader = config.ConfigLoader.init(allocator);
    
    var service_config = try cfg_loader.loadFromFile(config_path);
    defer service_config.deinit(allocator);
    
    // Initialize JSON logger
    var json_logger = config.JsonLogger.init(allocator);
    
    // Log startup with structured JSON
    try json_logger.log("info", "service_startup", .{
        .service = service_config.service.name,
        .version = service_config.service.version,
        .environment = service_config.service.environment,
        .node_id = service_config.service.node_id,
    });
    
    // Create orchestrator with configuration
    var orchestrator = try MultiTenantOrchestrator.init(allocator);
    defer orchestrator.deinit();
    
    // Initialize the API factory FIRST (creates isolated clients)
    try orchestrator.initializeApiFactory();
    
    // Initialize configured tenants from config
    for (service_config.tenants) |tenant| {
        const algorithm_type = std.meta.stringToEnum(TenantAlgorithm.AlgorithmType, tenant.algorithm.type) orelse .spy_hunter;

        // Use tenant-specific symbols if defined, otherwise use global market data symbols
        const symbols = tenant.symbols orelse service_config.market_data.symbols;

        try orchestrator.addTenant(
            tenant.id,
            tenant.name,
            tenant.tier,
            algorithm_type,
            symbols
        );
        
        try json_logger.log("info", "tenant_initialized", .{
            .tenant_id = tenant.id,
            .name = tenant.name,
            .tier = tenant.tier,
            .algorithm = tenant.algorithm.type,
        });
    }
    
    // Connect to market data source based on config
    const use_real_data = std.mem.eql(u8, service_config.market_data.mode, "realtime");
    try orchestrator.connectMarketData(use_real_data);
    
    // Start all engines
    try orchestrator.start();
    
    // Run service with configured timeout
    const runtime_seconds = service_config.service.shutdown_timeout_seconds;
    try json_logger.log("info", "service_running", .{
        .runtime_seconds = runtime_seconds,
        .market_mode = service_config.market_data.mode,
    });
    
    var elapsed: u64 = 0;
    while (elapsed < runtime_seconds) {
        sync.sleepNs(10 * std.time.ns_per_s);
        elapsed += 10;
        
        // Report metrics every 10 seconds with structured logging
        orchestrator.reportGlobalMetrics();
        
        try json_logger.log("info", "heartbeat", .{
            .elapsed_seconds = elapsed,
            .remaining_seconds = runtime_seconds - elapsed,
        });
    }
    
    // Stop all engines (graceful shutdown)
    // orchestrator.stop(); // Not implemented yet
    
    try json_logger.log("info", "service_shutdown", .{
        .runtime_seconds = elapsed,
        .clean_shutdown = true,
    });
    
    orchestrator.reportGlobalMetrics();
}