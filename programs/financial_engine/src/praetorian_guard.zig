// OPERATION PRAETORIAN GUARD
// Master Risk Management and Position Sizing Layer
// The final layer of command and control for the multi-tenant engine

const std = @import("std");
const api = @import("alpaca_trading_api.zig");
const Decimal = @import("decimal.zig").Decimal;

// ============================================================================
// RISK CONFIGURATION
// ============================================================================

/// Per-tenant risk limits. The size/value limits are Decimal (i128 fixed
/// point) — never f64 — so the comparison inside `validateOrder` is
/// overflow-checked and immune to the NaN-bypass case where a corrupted
/// `quote.bid` smuggling NaN through the pipeline would compare false
/// against every limit (NaN `<` anything is false) and slip through the
/// guard. Cures the Mars Climate Orbiter shape of FLOAT-OBSESSION for
/// the order-validation gate.
pub const RiskLimits = struct {
    // Per-tenant limits
    /// Maximum USD per position.
    max_position_size_usd: Decimal = Decimal.fromInt(10_000),
    max_orders_per_minute: u32 = 20,           // Rate limiting
    max_drawdown_percent: f64 = 5.0,           // Maximum drawdown before halt
    /// Total portfolio exposure cap.
    max_total_exposure_usd: Decimal = Decimal.fromInt(50_000),

    // Position limits
    max_positions: u32 = 10,                   // Maximum concurrent positions
    max_concentration_percent: f64 = 20.0,      // Max % in single symbol

    /// Minimum order size — orders below this are rejected.
    min_order_value_usd: Decimal = Decimal.fromInt(100),
    /// Maximum order size — orders above this are rejected.
    max_order_value_usd: Decimal = Decimal.fromInt(25_000),
};

pub const TenantRiskProfile = struct {
    tenant_id: []const u8,
    limits: RiskLimits,

    // Runtime tracking
    current_positions: u32 = 0,
    /// Sum of open-position values. Decimal so the running total never
    /// drifts (the canonical f64 accumulator bug that historically lets
    /// 1000 small orders sneak above a single big limit).
    current_exposure_usd: Decimal = Decimal.zero(),
    orders_this_minute: u32 = 0,
    last_minute_reset: i64 = 0,

    // Performance tracking
    starting_equity: f64 = 0.0,
    current_equity: f64 = 0.0,
    max_equity: f64 = 0.0,

    // Mutex for thread safety
    mutex: std.Thread.Mutex = .{},
};

// ============================================================================
// PRAETORIAN GUARD - MASTER RISK MANAGER
// ============================================================================

pub const PraetorianGuard = struct {
    allocator: std.mem.Allocator,
    api_client_factory: *@import("multi_tenant_engine.zig").ApiClientFactory,
    
    // Global account state
    total_buying_power: f64 = 0.0,
    total_cash: f64 = 0.0,
    total_positions_value: f64 = 0.0,
    last_account_update: i64 = 0,
    account_mutex: std.Thread.Mutex = .{},
    
    // Tenant risk profiles
    tenant_profiles: std.StringHashMap(TenantRiskProfile),
    
    // Capital allocation percentages (tenant_id -> percentage)
    capital_allocations: std.StringHashMap(f64),
    
    // Telemetry
    total_orders_validated: u64 = 0,
    total_orders_rejected: u64 = 0,
    rejection_reasons: std.StringHashMap(u64),
    
    const Self = @This();
    
    pub fn init(
        allocator: std.mem.Allocator,
        api_client_factory: *@import("multi_tenant_engine.zig").ApiClientFactory,
    ) !Self {
        var guard = Self{
            .allocator = allocator,
            .api_client_factory = api_client_factory,
            .tenant_profiles = std.StringHashMap(TenantRiskProfile).init(allocator),
            .capital_allocations = std.StringHashMap(f64).init(allocator),
            .rejection_reasons = std.StringHashMap(u64).init(allocator),
        };
        
        // Initialize rejection reason counters
        try guard.rejection_reasons.put("insufficient_buying_power", 0);
        try guard.rejection_reasons.put("exceeds_position_limit", 0);
        try guard.rejection_reasons.put("exceeds_rate_limit", 0);
        try guard.rejection_reasons.put("exceeds_concentration", 0);
        try guard.rejection_reasons.put("below_minimum_order", 0);
        try guard.rejection_reasons.put("exceeds_maximum_order", 0);
        try guard.rejection_reasons.put("exceeds_drawdown", 0);
        
        return guard;
    }
    
    pub fn deinit(self: *Self) void {
        self.tenant_profiles.deinit();
        self.capital_allocations.deinit();
        self.rejection_reasons.deinit();
    }
    
    // Register a tenant with risk limits and capital allocation
    pub fn registerTenant(
        self: *Self,
        tenant_id: []const u8,
        limits: RiskLimits,
        capital_allocation_percent: f64,
    ) !void {
        const id_copy = try self.allocator.dupe(u8, tenant_id);
        
        const profile = TenantRiskProfile{
            .tenant_id = id_copy,
            .limits = limits,
        };
        
        try self.tenant_profiles.put(id_copy, profile);
        try self.capital_allocations.put(id_copy, capital_allocation_percent);
        
        std.log.info("[PRAETORIAN] Registered tenant {s} with {d:.1}% capital allocation", .{
            tenant_id, capital_allocation_percent
        });
    }
    
    // Update global account state from Alpaca
    pub fn updateAccountState(self: *Self) !void {
        self.account_mutex.lock();
        defer self.account_mutex.unlock();
        
        // Create a temporary API client for account query
        const client = try self.api_client_factory.createClient();
        defer {
            client.deinit();
            self.api_client_factory.allocator.destroy(client);
        }
        
        const account = try client.getAccount();
        
        // Account is already parsed
        self.total_buying_power = try std.fmt.parseFloat(f64, account.buying_power);
        self.total_cash = try std.fmt.parseFloat(f64, account.cash);
        
        const portfolio_value = try std.fmt.parseFloat(f64, account.portfolio_value);
        self.total_positions_value = portfolio_value - self.total_cash;
            
        self.last_account_update = std.time.timestamp();
        
        std.log.info("[PRAETORIAN] Account updated - Buying Power: ${d:.2}, Cash: ${d:.2}, Positions: ${d:.2}", .{
            self.total_buying_power,
            self.total_cash,
            self.total_positions_value,
        });
    }
    
    // Core validation function - THE GUARDIAN
    //
    // `price` is `?Decimal`. Callers that hold an f64 must convert at the
    // boundary via `Decimal.fromFloat` — push the lossy conversion to a
    // single, audited site rather than have it scattered through the
    // guard's comparison logic. A `null` price is a market order; we bill
    // it against a $200/share conservative estimate (the legacy behaviour),
    // now expressed in Decimal so it composes with the other limits.
    pub fn validateOrder(
        self: *Self,
        tenant_id: []const u8,
        symbol: []const u8,
        side: api.AlpacaTradingAPI.OrderSide,
        quantity: u32,
        price: ?Decimal,
    ) !ValidationResult {
        self.total_orders_validated += 1;

        // Get tenant profile
        const profile_entry = self.tenant_profiles.getPtr(tenant_id) orelse {
            return ValidationResult{
                .approved = false,
                .reason = "Tenant not registered",
                .allocated_capital = 0,
            };
        };

        profile_entry.mutex.lock();
        defer profile_entry.mutex.unlock();

        // Calculate order value as a Decimal. Multiplication can overflow
        // on absurd quantity/price inputs; in that case fail-closed by
        // rejecting the order rather than papering over with an `unreachable`.
        const qty_decimal = Decimal.fromInt(@as(i64, quantity));
        const order_value: Decimal = blk: {
            if (price) |p| {
                break :blk p.mul(qty_decimal) catch {
                    try self.incrementRejection("exceeds_maximum_order");
                    return ValidationResult{
                        .approved = false,
                        .reason = "Order value overflow",
                        .allocated_capital = 0,
                    };
                };
            }
            // Market-order estimate: quantity × $200/share conservative buffer.
            break :blk qty_decimal.mul(Decimal.fromInt(200)) catch {
                try self.incrementRejection("exceeds_maximum_order");
                return ValidationResult{
                    .approved = false,
                    .reason = "Order value overflow",
                    .allocated_capital = 0,
                };
            };
        };

        // === VALIDATION CHECKS ===

        // 1. Check minimum order value
        if (order_value.lessThan(profile_entry.limits.min_order_value_usd)) {
            try self.incrementRejection("below_minimum_order");
            return ValidationResult{
                .approved = false,
                .reason = "Order below minimum value",
                .allocated_capital = 0,
            };
        }

        // 2. Check maximum order value
        if (order_value.greaterThan(profile_entry.limits.max_order_value_usd)) {
            try self.incrementRejection("exceeds_maximum_order");
            return ValidationResult{
                .approved = false,
                .reason = "Order exceeds maximum value",
                .allocated_capital = 0,
            };
        }
        
        // 3. Check rate limiting
        const now = std.time.timestamp();
        if (now > profile_entry.last_minute_reset + 60) {
            profile_entry.orders_this_minute = 0;
            profile_entry.last_minute_reset = now;
        }
        
        if (profile_entry.orders_this_minute >= profile_entry.limits.max_orders_per_minute) {
            try self.incrementRejection("exceeds_rate_limit");
            return ValidationResult{
                .approved = false,
                .reason = "Rate limit exceeded",
                .allocated_capital = 0,
            };
        }
        
        // 4. Check position limits
        if (side == .buy and profile_entry.current_positions >= profile_entry.limits.max_positions) {
            try self.incrementRejection("exceeds_position_limit");
            return ValidationResult{
                .approved = false,
                .reason = "Maximum positions reached",
                .allocated_capital = 0,
            };
        }
        
        // 5. Check total exposure
        if (side == .buy) {
            const new_exposure = profile_entry.current_exposure_usd.add(order_value) catch {
                try self.incrementRejection("exceeds_position_limit");
                return ValidationResult{
                    .approved = false,
                    .reason = "Exposure accumulator overflow",
                    .allocated_capital = 0,
                };
            };
            if (new_exposure.greaterThan(profile_entry.limits.max_total_exposure_usd)) {
                try self.incrementRejection("exceeds_position_limit");
                return ValidationResult{
                    .approved = false,
                    .reason = "Would exceed total exposure limit",
                    .allocated_capital = 0,
                };
            }
        }

        // 6. Check capital allocation
        const allocation_percent = self.capital_allocations.get(tenant_id) orelse 33.33;
        const allocated_capital = (self.total_buying_power * allocation_percent) / 100.0;

        if (side == .buy and order_value.toFloat() > allocated_capital) {
            try self.incrementRejection("insufficient_buying_power");
            return ValidationResult{
                .approved = false,
                .reason = "Exceeds allocated capital",
                .allocated_capital = allocated_capital,
            };
        }
        
        // 7. Check drawdown (if we have starting equity)
        if (profile_entry.starting_equity > 0) {
            const drawdown = ((profile_entry.max_equity - profile_entry.current_equity) / profile_entry.max_equity) * 100.0;
            if (drawdown > profile_entry.limits.max_drawdown_percent) {
                try self.incrementRejection("exceeds_drawdown");
                return ValidationResult{
                    .approved = false,
                    .reason = "Maximum drawdown exceeded",
                    .allocated_capital = allocated_capital,
                };
            }
        }
        
        // === ORDER APPROVED ===
        
        // Update tracking
        profile_entry.orders_this_minute += 1;
        if (side == .buy) {
            profile_entry.current_positions += 1;
            // Overflow on the accumulator is impossible here because we
            // already passed the exposure cap check above against the
            // same `new_exposure` value, but re-do the add to keep the
            // mutation local. Discard the error: by construction the
            // value fits.
            profile_entry.current_exposure_usd = profile_entry.current_exposure_usd.add(order_value) catch profile_entry.current_exposure_usd;
        }

        std.log.info("[PRAETORIAN] ✅ Order approved for {s}: {s} {d} {s} @ ${d:.2}", .{
            tenant_id, @tagName(side), quantity, symbol, if (price) |p| p.toFloat() else 0.0
        });
        
        return ValidationResult{
            .approved = true,
            .reason = "All checks passed",
            .allocated_capital = allocated_capital,
        };
    }
    
    fn incrementRejection(self: *Self, reason: []const u8) !void {
        self.total_orders_rejected += 1;
        
        if (self.rejection_reasons.getPtr(reason)) |count| {
            count.* += 1;
        }
        
        std.log.warn("[PRAETORIAN] ❌ Order rejected: {s}", .{reason});
    }
    
    pub fn printReport(self: *Self) void {
        std.log.info(
            \\
            \\╔══════════════════════════════════════════════════════╗
            \\║          PRAETORIAN GUARD RISK REPORT               ║
            \\╚══════════════════════════════════════════════════════╝
            \\
            \\📊 VALIDATION STATISTICS:
            \\   Total Validated: {d}
            \\   Total Approved:  {d}
            \\   Total Rejected:  {d}
            \\   Approval Rate:   {d:.1}%
            \\
            \\❌ REJECTION REASONS:
        , .{
            self.total_orders_validated,
            self.total_orders_validated - self.total_orders_rejected,
            self.total_orders_rejected,
            if (self.total_orders_validated > 0)
                @as(f64, @floatFromInt(self.total_orders_validated - self.total_orders_rejected)) / 
                @as(f64, @floatFromInt(self.total_orders_validated)) * 100.0
            else
                0.0,
        });
        
        var it = self.rejection_reasons.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.* > 0) {
                std.log.info("   {s}: {d}", .{ entry.key_ptr.*, entry.value_ptr.* });
            }
        }
        
        std.log.info(
            \\
            \\💰 ACCOUNT STATE:
            \\   Buying Power: ${d:.2}
            \\   Cash:         ${d:.2}
            \\   Positions:    ${d:.2}
            \\
        , .{
            self.total_buying_power,
            self.total_cash,
            self.total_positions_value,
        });
    }
};

pub const ValidationResult = struct {
    approved: bool,
    reason: []const u8,
    allocated_capital: f64,
};

// ============================================================================
// TESTING
// ============================================================================

test "Praetorian Guard initialization" {
    const allocator = std.testing.allocator;
    
    // Mock factory
    var factory = try @import("multi_tenant_engine.zig").ApiClientFactory.init(
        allocator,
        "test_key",
        "test_secret"
    );
    defer factory.deinit();
    
    var guard = try PraetorianGuard.init(allocator, &factory);
    defer guard.deinit();
    
    // Register test tenant
    try guard.registerTenant("TEST_001", .{}, 33.33);
    
    // Validate test order
    const result = try guard.validateOrder(
        "TEST_001",
        "AAPL",
        .buy,
        10,
        Decimal.fromInt(150),
    );
    
    try std.testing.expect(!result.approved); // Should fail without account state
}