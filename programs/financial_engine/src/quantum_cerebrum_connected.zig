// QUANTUM CEREBRUM CONNECTED - The Real Zig Brain
// This version reads from actual ring buffers created by Go

const std = @import("std");
const builtin = @import("builtin");

// ============================================================================
// C IMPORTS - Using canonical synapse_bridge.h
// ============================================================================

const c = @cImport({
    @cInclude("synapse_bridge.h");
});

// ============================================================================
// QUANTUM CEREBRUM - The Connected Brain
// ============================================================================

pub const QuantumCerebrumConnected = struct {
    allocator: std.mem.Allocator,
    
    // Ring buffers (from Go via environment)
    market_ring: *c.RingBuffer,
    order_ring: *c.RingBuffer,
    
    // Performance metrics
    packets_processed: std.atomic.Value(u64),
    orders_generated: std.atomic.Value(u64),
    total_latency_ns: std.atomic.Value(u64),
    
    // Strategy state
    last_prices: [256]u64,
    positions: [256]i32,
    
    // Control
    should_stop: std.atomic.Value(bool),
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator, market_ring: *c.RingBuffer, order_ring: *c.RingBuffer) Self {
        return .{
            .allocator = allocator,
            .market_ring = market_ring,
            .order_ring = order_ring,
            .packets_processed = std.atomic.Value(u64).init(0),
            .orders_generated = std.atomic.Value(u64).init(0),
            .total_latency_ns = std.atomic.Value(u64).init(0),
            .last_prices = [_]u64{0} ** 256,
            .positions = [_]i32{0} ** 256,
            .should_stop = std.atomic.Value(bool).init(false),
        };
    }
    
    pub fn run(self: *Self) !void {
        std.log.info("⚡ QUANTUM CEREBRUM CONNECTED - REAL NEURAL PATHWAY ACTIVE", .{});
        std.log.info("🎯 Target: <100ns processing latency", .{});
        
        // CPU pinning optimization deferred - prioritizing neural pathway connection
        std.log.info("🎯 CPU pinning skipped - focusing on neural pathway", .{});
        
        var packet: c.MarketPacket = undefined;
        var last_report = std.time.nanoTimestamp();
        
        std.log.info("👂 Listening for packets from Go via ring buffer...", .{});
        
        while (!self.should_stop.load(.acquire)) {
            const start_ns = std.time.nanoTimestamp();
            
            // Read packet from ring buffer using canonical C function
            if (c.synapse_read_packet(self.market_ring, &packet) == 1) {
                // CRITICAL PATH: Process packet at nanosecond speed
                self.processPacket(&packet);
                
                const end_ns = std.time.nanoTimestamp();
                const latency = @as(u64, @intCast(end_ns - start_ns));
                _ = self.total_latency_ns.fetchAdd(latency, .monotonic);
                _ = self.packets_processed.fetchAdd(1, .monotonic);
                
                // Log first thoughts to prove connection
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
                    
                    const price_float = @as(f64, @floatFromInt(packet.price_field)) / 1_000_000.0;
                    
                    if (packet.packet_type == 0) { // Quote
                        const side_str = if (packet.side_field == 0) "BID" else "ASK";
                        std.log.info("🧠 THOUGHT #{}: {s} {s} ${d:.2} x {} [{}ns] FROM GO!", .{
                            count, symbol_name, side_str, price_float, packet.qty_field, latency
                        });
                    } else { // Trade
                        std.log.info("🧠 THOUGHT #{}: {s} TRADE ${d:.2} x {} [{}ns] FROM GO!", .{
                            count, symbol_name, price_float, packet.qty_field, latency
                        });
                    }
                    
                    if (latency < 100) {
                        std.log.info("🔥 SUB-100 NANOSECOND ACHIEVED! SYNAPTIC CONNECTION WORKING! 🔥", .{});
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
    
    fn processPacket(self: *Self, packet: *const c.MarketPacket) void {
        // Ultra-simple strategy: Track price changes
        const symbol_id = packet.symbol_id;
        if (symbol_id >= 256) return;
        
        const old_price = self.last_prices[symbol_id];
        const new_price = packet.price_field;
        
        if (old_price > 0) {
            // Calculate price change
            const change = if (new_price > old_price) 
                new_price - old_price 
            else 
                old_price - new_price;
            
            // If price moved more than $0.10 (100000 in fixed point)
            if (change > 100000) {
                self.generateSignal(packet);
            }
        }
        
        self.last_prices[symbol_id] = new_price;
    }
    
    fn generateSignal(self: *Self, packet: *const c.MarketPacket) void {
        _ = packet; // Will use for order generation
        _ = self.orders_generated.fetchAdd(1, .monotonic);
        
        // In a real system, we would create an Order and write to order_ring
        // var order = c.Order{
        //     .symbol_id = packet.symbol_id,
        //     .side_field = if (packet.side_field == 0) 1 else 0,
        //     .price_field = packet.price_field,
        //     .qty_field = 100,
        //     .timestamp_ns = std.time.nanoTimestamp(),
        //     .strategy_id = 1,
        //     ._padding = undefined,
        // };
        // _ = c.synapse_write_order(self.order_ring, &order);
    }
    
    fn reportStats(self: *Self) void {
        const packets = self.packets_processed.load(.monotonic);
        const orders = self.orders_generated.load(.monotonic);
        const total_latency = self.total_latency_ns.load(.monotonic);
        
        if (packets > 0) {
            const avg_latency = total_latency / packets;
            
            std.log.info("", .{});
            std.log.info("🧠 ZIG CEREBRUM STATS:", .{});
            std.log.info("  Real Packets from Go: {} | Signals: {} | Avg: {} ns", .{
                packets, orders, avg_latency
            });
            
            if (avg_latency < 100) {
                std.log.info("  🔥 NEURAL PATHWAY MAINTAINING SUB-100NS! 🔥", .{});
            }
        }
    }
    
    pub fn stop(self: *Self) void {
        self.should_stop.store(true, .release);
    }
};

// ============================================================================
// MAIN - Connect to Go's ring buffers
// ============================================================================

pub fn main() !void {
    const allocator = std.heap.c_allocator;
    
    std.log.info("", .{});
    std.log.info("╔════════════════════════════════════════════════════╗", .{});
    std.log.info("║        ZIG CEREBRUM - CONNECTED TO GO              ║", .{});
    std.log.info("║           Real Neural Pathway Active               ║", .{});
    std.log.info("╚════════════════════════════════════════════════════╝", .{});
    std.log.info("", .{});
    
    // Get ring buffer pointers from environment (set by Go)
    const market_ring_str = std.process.getEnvVarOwned(allocator, "MARKET_RING_PTR") catch {
        std.log.err("❌ MARKET_RING_PTR not set by Go process", .{});
        return;
    };
    defer allocator.free(market_ring_str);
    
    const order_ring_str = std.process.getEnvVarOwned(allocator, "ORDER_RING_PTR") catch {
        std.log.err("❌ ORDER_RING_PTR not set by Go process", .{});
        return;
    };
    defer allocator.free(order_ring_str);
    
    // Parse pointers (remove 0x prefix if present)
    const market_hex = if (std.mem.startsWith(u8, market_ring_str, "0x")) 
        market_ring_str[2..] else market_ring_str;
    const order_hex = if (std.mem.startsWith(u8, order_ring_str, "0x")) 
        order_ring_str[2..] else order_ring_str;
        
    const market_ptr = std.fmt.parseUnsigned(usize, market_hex, 16) catch {
        std.log.err("❌ Invalid MARKET_RING_PTR format: {s}", .{market_ring_str});
        return;
    };
    
    const order_ptr = std.fmt.parseUnsigned(usize, order_hex, 16) catch {
        std.log.err("❌ Invalid ORDER_RING_PTR format: {s}", .{order_ring_str});
        return;
    };
    
    // Cast to ring buffer pointers
    const market_ring: *c.RingBuffer = @ptrFromInt(market_ptr);
    const order_ring: *c.RingBuffer = @ptrFromInt(order_ptr);
    
    std.log.info("🔗 Connected to Go ring buffers:", .{});
    std.log.info("  Market ring: 0x{x}", .{@as(u64, @intCast(market_ptr))});
    std.log.info("  Order ring:  0x{x}", .{@as(u64, @intCast(order_ptr))});
    
    // Initialize and run cerebrum
    var cerebrum = QuantumCerebrumConnected.init(allocator, market_ring, order_ring);
    
    std.log.info("", .{});
    std.log.info("🔥 NEURAL PATHWAY ESTABLISHED - WAITING FOR DATA FROM GO...", .{});
    std.log.info("", .{});
    
    try cerebrum.run();
}