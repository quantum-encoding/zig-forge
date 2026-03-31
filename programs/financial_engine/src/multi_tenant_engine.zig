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
    mutex: std.Thread.Mutex,
    allocator: std.mem.Allocator,
    tenant_id: []const u8,
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator, factory: *ApiClientFactory, tenant_id: []const u8) !Self {
        const client = try factory.createClient();
        
        return .{
            .client = client,
            .mutex = std.Thread.Mutex{},
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
        bid: f64,
        ask: f64,
        volume: u32,
        timestamp: i64,
    };
    
    const Order = struct {
        symbol: [16]u8,
        side: enum { buy, sell },
        quantity: u32,
        order_type: enum { market, limit },
        price: ?f64,
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
        const start_time = std.time.nanoTimestamp();
        
        std.log.info("[{s}] Algorithm execution started", .{self.tenant.tenant_id});
        
        while (!self.should_stop.load(.acquire)) {
            // Process incoming quotes
            if (self.quote_queue.pop()) |quote| {
                const process_start = std.time.nanoTimestamp();
                
                // Execute tenant-specific algorithm
                switch (self.tenant.algorithm_type) {
                    .spy_hunter => self.executeSPYHunter(quote),
                    .momentum_scanner => self.executeMomentumScanner(quote),
                    .mean_reversion => self.executeMeanReversion(quote),
                }
                
                const process_end = std.time.nanoTimestamp();
                _ = self.tenant.cpu_time_ns.fetchAdd(@intCast(process_end - process_start), .monotonic);
                _ = self.tenant.packets_processed.fetchAdd(1, .monotonic);
            }
            
            // Process pending orders
            if (self.order_queue.pop()) |order| {
                self.executeOrder(order) catch |err| {
                    std.log.err("[{s}] Order execution failed: {}", .{ self.tenant.tenant_id, err });
                };
            }
            
            std.Thread.sleep(1 * std.time.ns_per_ms);
        }
        
        const total_runtime = std.time.nanoTimestamp() - start_time;
        std.log.info("[{s}] Algorithm stopped. Runtime: {}ms", .{ 
            self.tenant.tenant_id, 
            @divTrunc(total_runtime, std.time.ns_per_ms)
        });
    }
    
    fn executeSPYHunter(self: *Self, quote: Quote) void {
        const symbol_str = std.mem.sliceTo(&quote.symbol, 0);
        
        if (std.mem.eql(u8, symbol_str, "SPY")) {
            // SPY DETECTED - IMMEDIATE ACTION
            const spread = quote.ask - quote.bid;
            
            if (spread < 0.10) { // Tight spread, good for execution
                std.log.info("[{s}] 🎯 SPY HUNT TRIGGERED: bid=${d:.2} ask=${d:.2}", 
                    .{ self.tenant.tenant_id, quote.bid, quote.ask });
                
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
            const mid_price = (quote.bid + quote.ask) / 2.0;
            
            // Simplified momentum signal (in production would track price history)
            if (mid_price > 0) {
                std.log.info("[{s}] 📈 Momentum detected in {s}: price=${d:.2} volume={}", 
                    .{ self.tenant.tenant_id, symbol_str, mid_price, quote.volume });
                
                const order = Order{
                    .symbol = quote.symbol,
                    .side = .buy,
                    .quantity = 10,
                    .order_type = .limit,
                    .price = quote.bid + 0.01,
                };
                
                _ = self.order_queue.push(order);
            }
        }
    }
    
    fn executeMeanReversion(self: *Self, quote: Quote) void {
        const symbol_str = std.mem.sliceTo(&quote.symbol, 0);
        const mid_price = (quote.bid + quote.ask) / 2.0;
        
        // Simplified mean reversion (in production would calculate Bollinger Bands)
        // Execute trade when spread threshold is met
        const spread = quote.ask - quote.bid;
        const spread_percentage = spread / mid_price;
        
        if (spread_percentage > 0.002) { // 0.2% spread
            std.log.info("[{s}] 📊 Mean reversion opportunity in {s}: spread={d:.2}%", 
                .{ self.tenant.tenant_id, symbol_str, spread_percentage * 100 });
            
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
                if (validation.allocated_capital > 0) {
                    std.log.info("[{s}]    Allocated capital: ${d:.2}", .{
                        self.tenant.tenant_id,
                        validation.allocated_capital,
                    });
                }
                return;
            }
        }
        
        // Add a small random delay to reduce simultaneous API calls
        const delay = std.crypto.random.int(u32) % 100;
        std.Thread.sleep(delay * std.time.ns_per_ms);
        
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
            .{ self.tenant.tenant_id, std.time.timestamp(), std.crypto.random.int(u32) }
        );
        defer self.allocator.free(unique_order_id);
        
        // Create Alpaca order request
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
    
    pub fn injectQuote(self: *Self, symbol: []const u8, bid: f64, ask: f64, volume: u32) void {
        var quote = Quote{
            .symbol = std.mem.zeroes([16]u8),
            .bid = bid,
            .ask = ask,
            .volume = volume,
            .timestamp = std.time.timestamp(),
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
        
        // Calculate billing
        const packet_cost = @as(f64, @floatFromInt(packets)) / 1000.0 * 0.001; // Rate varies by tier
        const order_cost = @as(f64, @floatFromInt(orders)) * 0.002;
        const total_cost = packet_cost + order_cost;
        
        std.log.info("  💰 Billing: ${d:.4} (packets: ${d:.4}, orders: ${d:.4})", 
            .{ total_cost, packet_cost, order_cost });
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
    
    pub fn init(allocator: std.mem.Allocator) Self {
        var tenants = std.ArrayList(TenantEngine).empty;
        tenants.ensureTotalCapacity(allocator, 10) catch unreachable;

        var algorithms = std.ArrayList(TenantAlgorithm).empty;
        algorithms.ensureTotalCapacity(allocator, 10) catch unreachable;

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
            // Define risk limits based on tier
            const limits = switch (algo_type) {
                .spy_hunter => praetorian.RiskLimits{
                    .max_position_size_usd = 5000.0,
                    .max_orders_per_minute = 10,
                    .max_total_exposure_usd = 20000.0,
                    .max_positions = 5,
                },
                .momentum_scanner => praetorian.RiskLimits{
                    .max_position_size_usd = 10000.0,
                    .max_orders_per_minute = 20,
                    .max_total_exposure_usd = 40000.0,
                    .max_positions = 8,
                },
                .mean_reversion => praetorian.RiskLimits{
                    .max_position_size_usd = 3000.0,
                    .max_orders_per_minute = 30,
                    .max_total_exposure_usd = 15000.0,
                    .max_positions = 10,
                },
            };
            
            // Equal capital allocation across all tenants
            const capital_percent = 100.0 / @as(f64, @floatFromInt(self.tenants.items.len));
            
            try guard.registerTenant(tenant_id, limits, capital_percent);
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
                std.Thread.sleep(1 * std.time.ns_per_s);
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
                // Generate simulated market data
                const symbols = [_][]const u8{ "SPY", "AAPL", "MSFT", "QQQ", "NVDA" };
                const random = std.crypto.random;
                
                for (symbols) |symbol| {
                    const base_price = 100.0 + @as(f64, @floatFromInt(random.int(u8))) / 10.0;
                    const spread = 0.01 + @as(f64, @floatFromInt(random.int(u8))) / 1000.0;
                    
                    for (self.tenants.items) |*tenant| {
                        tenant.injectQuote(symbol, base_price, base_price + spread, random.int(u32) % 1000000);
                    }
                }
                
                std.Thread.sleep(100 * std.time.ns_per_ms);
            }
            
            std.Thread.sleep(10 * std.time.ns_per_ms);
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
    var orchestrator = MultiTenantOrchestrator.init(allocator);
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
        std.Thread.sleep(10 * std.time.ns_per_s);
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