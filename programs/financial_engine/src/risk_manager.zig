const std = @import("std");
const Decimal = @import("decimal.zig").Decimal;

/// Get current Unix timestamp in seconds (Zig 0.16 compatible)
fn getCurrentTimestamp() i64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.REALTIME, &ts);
    return ts.sec;
}

/// Risk metrics for a position
pub const RiskMetrics = struct {
    position_size: Decimal,
    entry_price: Decimal,
    current_price: Decimal,
    unrealized_pnl: Decimal,
    realized_pnl: Decimal,
    max_drawdown: Decimal,
    sharpe_ratio: f64,
    var_95: Decimal,  // Value at Risk (95% confidence)
    margin_used: Decimal,
    leverage: Decimal,
};

/// Risk limits configuration
pub const RiskLimits = struct {
    max_position_size: Decimal,
    max_leverage: Decimal,
    max_drawdown: Decimal,
    daily_loss_limit: Decimal,
    position_limit_per_symbol: Decimal,
    total_exposure_limit: Decimal,
    margin_call_level: Decimal,
    liquidation_level: Decimal,
};

/// Position tracking
pub const Position = struct {
    symbol: []const u8,
    side: enum { long, short },
    quantity: Decimal,
    entry_price: Decimal,
    current_price: Decimal,
    stop_loss: ?Decimal,
    take_profit: ?Decimal,
    opened_at: i64,
    updated_at: i64,
    
    pub fn unrealizedPnl(self: Position) Decimal {
        const price_diff = self.current_price.sub(self.entry_price) catch return Decimal.zero();
        const pnl = price_diff.mul(self.quantity) catch return Decimal.zero();
        
        return switch (self.side) {
            .long => pnl,
            .short => pnl.negate(),
        };
    }
    
    pub fn percentReturn(self: Position) Decimal {
        const pnl = self.unrealizedPnl();
        const cost = self.entry_price.mul(self.quantity) catch return Decimal.zero();
        if (cost.isZero()) return Decimal.zero();
        
        const hundred = Decimal.fromInt(100);
        return pnl.mul(hundred).div(cost) catch Decimal.zero();
    }
};

/// Risk Manager for portfolio
pub const RiskManager = struct {
    const Self = @This();
    
    positions: std.StringHashMap(Position),
    limits: RiskLimits,
    account_balance: Decimal,
    available_margin: Decimal,
    used_margin: Decimal,
    daily_pnl: Decimal,
    total_pnl: Decimal,
    pnl_history: std.ArrayList(Decimal),
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator, initial_balance: Decimal, limits: RiskLimits) Self {
        return .{
            .positions = std.StringHashMap(Position).init(allocator),
            .limits = limits,
            .account_balance = initial_balance,
            .available_margin = initial_balance,
            .used_margin = Decimal.zero(),
            .daily_pnl = Decimal.zero(),
            .total_pnl = Decimal.zero(),
            .pnl_history = .{ .items = &.{}, .capacity = 0 },
            .allocator = allocator,
        };
    }
    
    pub fn deinit(self: *Self) void {
        self.positions.deinit();
        self.pnl_history.deinit(self.allocator);
    }
    
    /// Check if a new position can be opened
    pub fn canOpenPosition(self: Self, symbol: []const u8, quantity: Decimal, price: Decimal) bool {
        const required_margin = self.calculateMargin(quantity, price);
        
        // Check margin availability
        if (required_margin.greaterThan(self.available_margin)) {
            return false;
        }
        
        // Check position size limit
        if (quantity.greaterThan(self.limits.max_position_size)) {
            return false;
        }
        
        // Check symbol position limit
        if (self.positions.get(symbol)) |existing| {
            const total = existing.quantity.add(quantity) catch return false;
            if (total.greaterThan(self.limits.position_limit_per_symbol)) {
                return false;
            }
        }
        
        // Check leverage limit
        const position_value = quantity.mul(price) catch return false;
        const total_exposure = self.getTotalExposure().add(position_value) catch return false;
        const leverage = total_exposure.div(self.account_balance) catch return false;
        
        if (leverage.greaterThan(self.limits.max_leverage)) {
            return false;
        }
        
        // Check daily loss limit
        if (self.daily_pnl.lessThan(self.limits.daily_loss_limit.negate())) {
            return false;
        }
        
        return true;
    }
    
    /// Open a new position
    pub fn openPosition(self: *Self, symbol: []const u8, side: @TypeOf(@as(Position, undefined).side), quantity: Decimal, price: Decimal) !void {
        if (!self.canOpenPosition(symbol, quantity, price)) {
            return error.RiskLimitExceeded;
        }
        
        const position = Position{
            .symbol = symbol,
            .side = side,
            .quantity = quantity,
            .entry_price = price,
            .current_price = price,
            .stop_loss = null,
            .take_profit = null,
            .opened_at = getCurrentTimestamp(),
            .updated_at = getCurrentTimestamp(),
        };
        
        try self.positions.put(symbol, position);
        
        const margin = self.calculateMargin(quantity, price);
        self.used_margin = try self.used_margin.add(margin);
        self.available_margin = try self.available_margin.sub(margin);
    }
    
    /// Close a position
    pub fn closePosition(self: *Self, symbol: []const u8, price: Decimal) !Decimal {
        const position = self.positions.get(symbol) orelse return error.PositionNotFound;
        
        // Calculate PnL
        const pnl = blk: {
            const price_diff = price.sub(position.entry_price) catch break :blk Decimal.zero();
            const raw_pnl = price_diff.mul(position.quantity) catch break :blk Decimal.zero();
            
            break :blk switch (position.side) {
                .long => raw_pnl,
                .short => raw_pnl.negate(),
            };
        };
        
        // Update balances
        self.account_balance = try self.account_balance.add(pnl);
        self.total_pnl = try self.total_pnl.add(pnl);
        self.daily_pnl = try self.daily_pnl.add(pnl);
        try self.pnl_history.append(self.allocator, pnl);
        
        // Release margin
        const margin = self.calculateMargin(position.quantity, position.entry_price);
        self.used_margin = self.used_margin.sub(margin) catch Decimal.zero();
        self.available_margin = try self.available_margin.add(margin);
        
        _ = self.positions.remove(symbol);
        
        return pnl;
    }
    
    /// Update position prices
    pub fn updatePrice(self: *Self, symbol: []const u8, price: Decimal) void {
        if (self.positions.getPtr(symbol)) |position| {
            position.current_price = price;
            position.updated_at = getCurrentTimestamp();
            
            // Check stop loss
            if (position.stop_loss) |sl| {
                const should_close = switch (position.side) {
                    .long => price.lessThan(sl),
                    .short => price.greaterThan(sl),
                };
                
                if (should_close) {
                    _ = self.closePosition(symbol, price) catch {};
                }
            }
            
            // Check take profit
            if (position.take_profit) |tp| {
                const should_close = switch (position.side) {
                    .long => price.greaterThan(tp),
                    .short => price.lessThan(tp),
                };
                
                if (should_close) {
                    _ = self.closePosition(symbol, price) catch {};
                }
            }
        }
    }
    
    /// Set stop loss for position
    pub fn setStopLoss(self: *Self, symbol: []const u8, stop_price: Decimal) bool {
        if (self.positions.getPtr(symbol)) |position| {
            position.stop_loss = stop_price;
            return true;
        }
        return false;
    }
    
    /// Set take profit for position
    pub fn setTakeProfit(self: *Self, symbol: []const u8, tp_price: Decimal) bool {
        if (self.positions.getPtr(symbol)) |position| {
            position.take_profit = tp_price;
            return true;
        }
        return false;
    }
    
    /// Calculate required margin
    fn calculateMargin(_: Self, quantity: Decimal, price: Decimal) Decimal {
        const position_value = quantity.mul(price) catch return Decimal.zero();
        const margin_ratio = Decimal.fromFloat(0.1); // 10% margin requirement
        return position_value.mul(margin_ratio) catch return Decimal.zero();
    }
    
    /// Get total exposure across all positions
    pub fn getTotalExposure(self: Self) Decimal {
        var total = Decimal.zero();
        
        var iter = self.positions.iterator();
        while (iter.next()) |entry| {
            const position = entry.value_ptr.*;
            const value = position.quantity.mul(position.current_price) catch continue;
            total = total.add(value) catch return total;
        }
        
        return total;
    }
    
    /// Get total unrealized PnL
    pub fn getUnrealizedPnl(self: Self) Decimal {
        var total = Decimal.zero();
        
        var iter = self.positions.iterator();
        while (iter.next()) |entry| {
            const pnl = entry.value_ptr.unrealizedPnl();
            total = total.add(pnl) catch return total;
        }
        
        return total;
    }
    
    /// Calculate Value at Risk (VaR) at 95% confidence
    pub fn calculateVaR(self: Self) !Decimal {
        if (self.pnl_history.items.len < 20) {
            return Decimal.zero(); // Not enough data
        }
        
        // Simple historical VaR calculation
        const sorted = try self.allocator.alloc(Decimal, self.pnl_history.items.len);
        defer self.allocator.free(sorted);
        
        @memcpy(sorted, self.pnl_history.items);
        
        // Sort PnL history
        std.mem.sort(Decimal, sorted, {}, struct {
            fn lessThan(_: void, a: Decimal, b: Decimal) bool {
                return a.lessThan(b);
            }
        }.lessThan);
        
        // Get 5th percentile
        const idx = sorted.len / 20; // 5% of data
        return sorted[idx];
    }
    
    /// Calculate Sharpe ratio
    pub fn calculateSharpeRatio(self: Self) f64 {
        if (self.pnl_history.items.len < 2) return 0.0;
        
        // Calculate mean return
        var sum = Decimal.zero();
        for (self.pnl_history.items) |pnl| {
            sum = sum.add(pnl) catch return 0.0;
        }
        
        const count = Decimal.fromInt(@intCast(self.pnl_history.items.len));
        const mean = sum.div(count) catch return 0.0;
        
        // Calculate standard deviation
        var variance_sum = Decimal.zero();
        for (self.pnl_history.items) |pnl| {
            const diff = pnl.sub(mean) catch continue;
            const squared = diff.mul(diff) catch continue;
            variance_sum = variance_sum.add(squared) catch continue;
        }
        
        const variance = variance_sum.div(count) catch return 0.0;
        const std_dev = std.math.sqrt(variance.toFloat());
        
        if (std_dev == 0.0) return 0.0;
        
        // Sharpe ratio (assuming risk-free rate = 0)
        return mean.toFloat() / std_dev;
    }
    
    /// Check margin call conditions
    pub fn isMarginCall(self: Self) bool {
        const equity = self.account_balance.add(self.getUnrealizedPnl()) catch return true;
        const margin_level = equity.div(self.used_margin) catch return true;
        
        return margin_level.lessThan(self.limits.margin_call_level);
    }
    
    /// Check liquidation conditions
    pub fn isLiquidation(self: Self) bool {
        const equity = self.account_balance.add(self.getUnrealizedPnl()) catch return true;
        const margin_level = equity.div(self.used_margin) catch return true;
        
        return margin_level.lessThan(self.limits.liquidation_level);
    }
    
    /// Reset daily PnL (call at day end)
    pub fn resetDaily(self: *Self) void {
        self.daily_pnl = Decimal.zero();
    }
    
    /// Get risk report
    pub fn getRiskReport(self: Self) RiskMetrics {
        const total_exposure = self.getTotalExposure();
        const unrealized_pnl = self.getUnrealizedPnl();
        const leverage = total_exposure.div(self.account_balance) catch Decimal.zero();
        const var_95 = self.calculateVaR() catch Decimal.zero();
        const sharpe = self.calculateSharpeRatio();
        
        // Calculate max drawdown
        var max_balance = self.account_balance;
        var max_dd = Decimal.zero();
        
        for (self.pnl_history.items) |pnl| {
            const balance = max_balance.add(pnl) catch continue;
            
            if (balance.greaterThan(max_balance)) {
                max_balance = balance;
            } else {
                const dd = max_balance.sub(balance) catch continue;
                if (dd.greaterThan(max_dd)) {
                    max_dd = dd;
                }
            }
        }
        
        return RiskMetrics{
            .position_size = total_exposure,
            .entry_price = Decimal.zero(), // Aggregate, not meaningful
            .current_price = Decimal.zero(), // Aggregate, not meaningful
            .unrealized_pnl = unrealized_pnl,
            .realized_pnl = self.total_pnl,
            .max_drawdown = max_dd,
            .sharpe_ratio = sharpe,
            .var_95 = var_95,
            .margin_used = self.used_margin,
            .leverage = leverage,
        };
    }
};