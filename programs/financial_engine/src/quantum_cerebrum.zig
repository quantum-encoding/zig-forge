// QUANTUM CEREBRUM - The Pure Zig Brain
// This component reads MarketPackets from ring buffers and executes strategies
// NO NETWORKING - Pure computation at <100ns latency

const std = @import("std");
const builtin = @import("builtin");

// ============================================================================
// RING BUFFER C INTERFACE
// ============================================================================

extern fn create_ring_buffer(size: usize) ?*anyopaque;
extern fn destroy_ring_buffer(ring: ?*anyopaque) void;
extern fn read_market_packet(ring: ?*anyopaque, packet: *MarketPacket) c_int;
extern fn write_order(ring: ?*anyopaque, order: *Order) c_int;

// ============================================================================
// DATA STRUCTURES - Must match Go exactly
// ============================================================================

pub const MarketPacket = extern struct {
    timestamp_ns: u64,
    symbol_id: u32,
    packet_type: u8,  // 0=quote, 1=trade
    flags: u8,
    price: u64,       // Fixed point: multiply float by 1,000,000
    quantity: u32,
    order_id: u32,
    side: u8,         // 0=bid, 1=ask, 2=trade
    _padding: [23]u8,
};

pub const Order = extern struct {
    symbol_id: u32,
    side: u8,         // 0=buy, 1=sell
    price: u64,       // Fixed point
    quantity: u32,
    timestamp_ns: u64,
    strategy_id: u8,
    _padding: [7]u8,
};

// ============================================================================
// QUANTUM CEREBRUM - The Pure Strategy Engine
// ============================================================================

pub const QuantumCerebrum = struct {
    allocator: std.mem.Allocator,
    
    // Ring buffers (shared with Go)
    market_data_ring: ?*anyopaque,
    order_ring: ?*anyopaque,
    
    // Performance metrics
    packets_processed: std.atomic.Value(u64),
    orders_generated: std.atomic.Value(u64),
    total_latency_ns: std.atomic.Value(u64),
    
    // Strategy state
    last_prices: [256]u64,  // Last price for each symbol
    positions: [256]i32,    // Current position for each symbol
    
    // Control
    should_stop: std.atomic.Value(bool),
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator) !Self {
        return .{
            .allocator = allocator,
            .market_data_ring = null,
            .order_ring = null,
            .packets_processed = std.atomic.Value(u64).init(0),
            .orders_generated = std.atomic.Value(u64).init(0),
            .total_latency_ns = std.atomic.Value(u64).init(0),
            .last_prices = [_]u64{0} ** 256,
            .positions = [_]i32{0} ** 256,
            .should_stop = std.atomic.Value(bool).init(false),
        };
    }
    
    pub fn connectToRingBuffers(self: *Self, market_ring: ?*anyopaque, order_ring: ?*anyopaque) void {
        self.market_data_ring = market_ring;
        self.order_ring = order_ring;
        std.log.info("🧠 Connected to ring buffers", .{});
    }
    
    pub fn run(self: *Self) !void {
        std.log.info("⚡ QUANTUM CEREBRUM ACTIVATED", .{});
        std.log.info("🎯 Target: <100ns market data to signal", .{});
        
        // Pin to CPU core for optimal performance
        if (builtin.os.tag == .linux) {
            var cpu_set = std.os.linux.cpu_set_t{};
            std.os.linux.CPU_ZERO(&cpu_set);
            std.os.linux.CPU_SET(12, &cpu_set); // Use core 12
            _ = std.os.linux.sched_setaffinity(0, @sizeOf(std.os.linux.cpu_set_t), &cpu_set);
            
            // Set real-time priority
            const sched_param = std.os.linux.sched_param{ .sched_priority = 99 };
            _ = std.os.linux.sched_setscheduler(0, std.os.linux.SCHED.FIFO, &sched_param);
            
            std.log.info("🎯 Pinned to CPU core 12 with RT priority", .{});
        }
        
        var packet: MarketPacket = undefined;
        var last_report = std.time.nanoTimestamp();
        
        while (!self.should_stop.load(.acquire)) {
            const start_ns = std.time.nanoTimestamp();
            
            // Check for market data
            if (read_market_packet(self.market_data_ring, &packet) == 1) {
                // CRITICAL PATH: Process packet at nanosecond speed
                self.processPacket(&packet);
                
                const end_ns = std.time.nanoTimestamp();
                const latency = @as(u64, @intCast(end_ns - start_ns));
                _ = self.total_latency_ns.fetchAdd(latency, .monotonic);
                _ = self.packets_processed.fetchAdd(1, .monotonic);
                
                // Log first few packets to prove it's working
                const count = self.packets_processed.load(.monotonic);
                if (count <= 10) {
                    const symbol_name = switch (packet.symbol_id) {
                        0 => "SPY",
                        1 => "QQQ",
                        2 => "AAPL",
                        3 => "MSFT",
                        4 => "NVDA",
                        5 => "AMD",
                        else => "???",
                    };
                    
                    const price_float = @as(f64, @floatFromInt(packet.price)) / 1_000_000.0;
                    
                    if (packet.packet_type == 0) { // Quote
                        const side_str = if (packet.side == 0) "BID" else "ASK";
                        std.log.info("🧠 THOUGHT #{}: {} {} ${d:.2} x {} [{}ns latency]", .{
                            count, symbol_name, side_str, price_float, packet.quantity, latency
                        });
                    } else { // Trade
                        std.log.info("🧠 THOUGHT #{}: {} TRADE ${d:.2} x {} [{}ns latency]", .{
                            count, symbol_name, price_float, packet.quantity, latency
                        });
                    }
                    
                    if (latency < 100) {
                        std.log.info("🔥 SUB-100 NANOSECOND ACHIEVED! 🔥", .{});
                    }
                }
            } else {
                // No data available, yield briefly
                std.atomic.spinLoopHint();
            }
            
            // Report stats every second
            const now = std.time.nanoTimestamp();
            if (now - last_report > 1_000_000_000) {
                self.reportStats();
                last_report = now;
            }
        }
    }
    
    fn processPacket(self: *Self, packet: *const MarketPacket) void {
        // Ultra-simple strategy: Track price changes
        const symbol_id = packet.symbol_id;
        if (symbol_id >= 256) return;
        
        const old_price = self.last_prices[symbol_id];
        const new_price = packet.price;
        
        if (old_price > 0) {
            // Calculate price change
            const change = if (new_price > old_price) 
                new_price - old_price 
            else 
                old_price - new_price;
            
            // If price moved more than 0.10 (100000 in fixed point)
            if (change > 100000) {
                // Generate a signal (but don't actually send orders yet)
                self.generateSignal(packet);
            }
        }
        
        self.last_prices[symbol_id] = new_price;
    }
    
    fn generateSignal(self: *Self, packet: *const MarketPacket) void {
        _ = packet; // Will use for order generation
        // Signal generation tracking for performance metrics
        _ = self.orders_generated.fetchAdd(1, .monotonic);
        
        // In a real system, we would create an Order and write to order_ring
        // var order = Order{
        //     .symbol_id = packet.symbol_id,
        //     .side = if (packet.side == 0) 1 else 0, // Contrarian
        //     .price = packet.price,
        //     .quantity = 100,
        //     .timestamp_ns = std.time.nanoTimestamp(),
        //     .strategy_id = 1,
        //     ._padding = undefined,
        // };
        // _ = write_order(self.order_ring, &order);
    }
    
    fn reportStats(self: *Self) void {
        const packets = self.packets_processed.load(.monotonic);
        const orders = self.orders_generated.load(.monotonic);
        const total_latency = self.total_latency_ns.load(.monotonic);
        
        if (packets > 0) {
            const avg_latency = total_latency / packets;
            
            std.log.info("", .{});
            std.log.info("⚡ CEREBRUM STATS:", .{});
            std.log.info("  Packets: {} | Signals: {} | Avg Latency: {} ns", .{
                packets, orders, avg_latency
            });
            
            if (avg_latency < 100) {
                std.log.info("  🔥 MAINTAINING SUB-100NS PERFORMANCE! 🔥", .{});
            }
        }
    }
    
    pub fn stop(self: *Self) void {
        self.should_stop.store(true, .release);
    }
};

// ============================================================================
// TEST HARNESS
// ============================================================================

pub fn main() !void {
    const allocator = std.heap.c_allocator;
    
    std.log.info("", .{});
    std.log.info("╔════════════════════════════════════════════════════╗", .{});
    std.log.info("║          QUANTUM CEREBRUM - PURE ZIG BRAIN         ║", .{});
    std.log.info("║            Waiting for Neural Pathway...           ║", .{});
    std.log.info("╚════════════════════════════════════════════════════╝", .{});
    std.log.info("", .{});
    
    const cerebrum = try QuantumCerebrum.init(allocator);
    _ = cerebrum;
    
    // In production, these would be passed from the Go component
    std.log.info("⚠️  This component requires the Go sensory organs to provide ring buffers", .{});
    std.log.info("   Run the unified Trinity launcher to see the full system", .{});
}