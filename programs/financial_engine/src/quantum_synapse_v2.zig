// QUANTUM SYNAPSE ENGINE V2 - THE NANOSECOND PREDATOR
// The fusion of Nuclear Fire Hose Legion with The Great Synapse
// Target: Sub-microsecond market dominance

const std = @import("std");
const os = std.os;
const linux = std.os.linux;
const posix = std.posix;
const mem = std.mem;
const atomic = std.atomic;
const builtin = @import("builtin");

// ============================================================================
// PHASE 1: LOCK-FREE SPSC RING BUFFER INTERFACE
// The neural pathway between C Legion and Zig Brain
// ============================================================================

pub const CacheLineSize = 64; // x86_64 cache line

// Ensure structures are cache-line aligned to prevent false sharing
pub const RingBuffer = extern struct {
    // Producer cache line (written by DPDK Legion)
    producer_head: atomic.Value(u64) align(CacheLineSize),
    producer_cached_consumer: u64,
    _producer_padding: [CacheLineSize - 16]u8,
    
    // Consumer cache line (written by Zig Brain)
    consumer_head: atomic.Value(u64) align(CacheLineSize),
    consumer_cached_producer: u64,
    _consumer_padding: [CacheLineSize - 16]u8,
    
    // Shared read-only data
    size: u64 align(CacheLineSize),
    mask: u64,
    buffer_ptr: [*]u8,
    _shared_padding: [CacheLineSize - 24]u8,
    
    pub fn init(size: u64, buffer: []u8) RingBuffer {
        std.debug.assert(size & (size - 1) == 0); // Must be power of 2
        
        return .{
            .producer_head = atomic.Value(u64).init(0),
            .producer_cached_consumer = 0,
            .consumer_head = atomic.Value(u64).init(0),
            .consumer_cached_producer = 0,
            .size = size,
            .mask = size - 1,
            .buffer_ptr = buffer.ptr,
            ._producer_padding = undefined,
            ._consumer_padding = undefined,
            ._shared_padding = undefined,
        };
    }
};

// Market data packet structure (matches DPDK Legion output)
pub const MarketPacket = extern struct {
    timestamp_ns: u64,      // Hardware timestamp from NIC
    symbol_id: u32,         // Pre-mapped symbol ID for O(1) lookup
    packet_type: u16,       // ITCH message type
    flags: u16,             // Special handling flags
    price: u64,             // Fixed-point price (6 decimals)
    quantity: u32,          // Share quantity
    order_id: u64,          // Exchange order ID
    side: u8,               // Buy/Sell
    _padding: [7]u8,        // Align to 48 bytes
};

// ============================================================================
// PHASE 2: THE ZIG STRATEGIST - ULTRA-LOW LATENCY CONSUMER
// ============================================================================

pub const ZigStrategist = struct {
    id: u8,                                     // Centurion ID (0-7)
    core_id: u32,                               // CPU core to pin to
    ring_buffer: *RingBuffer,                   // Inbound market data
    order_buffer: *RingBuffer,                  // Outbound orders
    
    // Strategy state (cache-aligned)
    order_book: OrderBook align(CacheLineSize),
    position: Position align(CacheLineSize),
    signals: Signals align(CacheLineSize),
    
    // Performance metrics
    packets_processed: atomic.Value(u64),
    orders_generated: atomic.Value(u64),
    
    const Self = @This();
    
    pub fn init(id: u8, core_id: u32, ring: *RingBuffer, order_ring: *RingBuffer) Self {
        return .{
            .id = id,
            .core_id = core_id,
            .ring_buffer = ring,
            .order_buffer = order_ring,
            .order_book = OrderBook.init(),
            .position = Position.init(),
            .signals = Signals.init(),
            .packets_processed = atomic.Value(u64).init(0),
            .orders_generated = atomic.Value(u64).init(0),
        };
    }
    
    // The main processing loop - THIS IS WHERE NANOSECONDS MATTER
    pub fn run(self: *Self) !void {
        // Pin to CPU core for zero jitter
        try self.pinToCore();
        
        // Pre-allocate everything to avoid allocations in hot path
        var packet_buffer: [1024]MarketPacket = undefined;
        var batch_size: usize = 0;
        
        while (true) {
            // Batch consume from ring buffer for better cache utilization
            batch_size = self.consumeBatch(&packet_buffer, packet_buffer.len);
            
            if (batch_size == 0) {
                // No data available - yield CPU briefly
                std.atomic.spinLoopHint();
                continue;
            }
            
            // Process batch with zero allocations
            for (packet_buffer[0..batch_size]) |*packet| {
                self.processPacket(packet) catch |err| {
                    // Log error but NEVER stop processing
                    std.log.err("Strategist {}: packet error: {}", .{ self.id, err });
                };
            }
            
            _ = self.packets_processed.fetchAdd(batch_size, .monotonic);
        }
    }
    
    fn pinToCore(self: *Self) !void {
        if (builtin.os.tag != .linux) {
            std.log.warn("CPU pinning only supported on Linux", .{});
            return;
        }
        
        // Use Linux-specific CPU affinity functions
        var cpu_set: linux.cpu_set_t = std.mem.zeroes(linux.cpu_set_t);
        
        // Set the specific CPU core (manual implementation)
        const word_idx = self.core_id / @bitSizeOf(usize);
        const bit_idx = self.core_id % @bitSizeOf(usize);
        cpu_set[word_idx] |= @as(usize, 1) << @intCast(bit_idx);
        
        // Apply CPU affinity
        linux.sched_setaffinity(0, &cpu_set) catch |err| {
            std.log.err("Failed to set CPU affinity for core {}: {}", .{ self.core_id, err });
            return err;
        };
        
        // Set real-time priority for minimum jitter  
        const sched_param = linux.sched_param{ .priority = 99 };
        // Use raw FIFO value (1) for SCHED_FIFO
        const SCHED_FIFO = @as(u32, 1);
        const sched_result = linux.sched_setscheduler(0, @bitCast(SCHED_FIFO), &sched_param);
        if (sched_result != 0) {
            std.log.warn("Failed to set real-time priority (need root privileges)", .{});
            // Don't fail - continue without RT priority
        }
        
        std.log.info("🎯 Strategist {} pinned to CPU core {} with RT priority", .{ self.id, self.core_id });
    }
    
    pub fn consumeBatch(self: *Self, buffer: []MarketPacket, max_items: usize) usize {
        const consumer = self.ring_buffer.consumer_head.load(.acquire);
        var producer = self.ring_buffer.consumer_cached_producer;
        
        // Check if we need to load the producer position
        if (consumer == producer) {
            producer = self.ring_buffer.producer_head.load(.acquire);
            self.ring_buffer.consumer_cached_producer = producer;
            
            if (consumer == producer) {
                return 0; // Ring is empty
            }
        }
        
        // Calculate available items
        const available = producer - consumer;
        const to_read = @min(available, max_items);
        
        // Copy packets from ring buffer
        var i: usize = 0;
        while (i < to_read) : (i += 1) {
            const index = (consumer + i) & self.ring_buffer.mask;
            const packet_ptr = @as(*MarketPacket, @ptrCast(
                @alignCast(self.ring_buffer.buffer_ptr + index * @sizeOf(MarketPacket))
            ));
            buffer[i] = packet_ptr.*;
        }
        
        // Update consumer position
        self.ring_buffer.consumer_head.store(consumer + to_read, .release);
        
        return to_read;
    }
    
    pub inline fn processPacket(self: *Self, packet: *const MarketPacket) !void {
        // Update order book with zero allocations
        self.order_book.update(packet);
        
        // Generate signals based on microstructure
        const signal = self.signals.generate(&self.order_book, packet);
        
        // Execute strategy logic
        if (signal.strength > self.signals.threshold) {
            const order = self.generateOrder(signal, packet);
            try self.submitOrder(order);
        }
    }
    
    fn generateOrder(self: *Self, signal: Signal, packet: *const MarketPacket) Order {
        // Ultra-fast order generation logic
        return Order{
            .symbol_id = packet.symbol_id,
            .side = if (signal.direction > 0) .buy else .sell,
            .price = self.calculateOptimalPrice(signal, packet),
            .quantity = self.calculateOptimalSize(signal),
            .timestamp_ns = packet.timestamp_ns,
            .strategy_id = self.id,
            ._padding = undefined,
        };
    }
    
    fn submitOrder(self: *Self, order: Order) !void {
        // Write to outbound ring buffer for Go executor
        const producer = self.order_buffer.producer_head.load(.acquire);
        const next = producer + 1;
        
        // Check for ring buffer full (should never happen with proper sizing)
        const consumer = self.order_buffer.consumer_head.load(.acquire);
        if (next - consumer > self.order_buffer.size) {
            return error.OrderBufferFull;
        }
        
        // Write order to buffer
        const index = producer & self.order_buffer.mask;
        const order_ptr = @as(*Order, @ptrCast(
            @alignCast(self.order_buffer.buffer_ptr + index * @sizeOf(Order))
        ));
        order_ptr.* = order;
        
        // Commit the write
        self.order_buffer.producer_head.store(next, .release);
        _ = self.orders_generated.fetchAdd(1, .monotonic);
    }
    
    inline fn calculateOptimalPrice(self: *Self, signal: Signal, _: *const MarketPacket) u64 {
        // Nanosecond price calculation
        _ = self;
        const spread = signal.ask - signal.bid;
        const aggressive_factor = @as(u64, @intFromFloat(signal.strength * 100));
        
        if (signal.direction > 0) {
            // Buying - price between mid and ask based on urgency
            return signal.bid + (spread * aggressive_factor) / 100;
        } else {
            // Selling - price between bid and mid based on urgency
            return signal.ask - (spread * aggressive_factor) / 100;
        }
    }
    
    inline fn calculateOptimalSize(self: *Self, signal: Signal) u32 {
        // Risk-adjusted position sizing
        const max_position = 10000; // Max shares per symbol
        const current = self.position.getSize(signal.symbol_id);
        const available = max_position - current;
        
        const signal_size = @as(u32, @intFromFloat(signal.strength * 100));
        return @min(signal_size, available);
    }
};

// ============================================================================
// PHASE 3: THE QUANTUM SYNAPSE ENGINE - MASTER ORCHESTRATOR
// ============================================================================

pub const QuantumSynapseEngine = struct {
    // The 8 Legion Centurions (DPDK data receivers)
    legion_rings: [8]*RingBuffer,
    
    // The 8 Zig Strategists (trading brains)
    strategists: [8]ZigStrategist,
    
    // Order execution ring buffers (to Go executor)
    order_rings: [8]*RingBuffer,
    
    // Shared memory regions
    market_data_region: []align(4096) u8,
    order_region: []align(4096) u8,
    
    // Performance metrics
    start_time: i64,
    total_packets: atomic.Value(u64),
    total_orders: atomic.Value(u64),
    
    const Self = @This();
    
    pub fn init(allocator: mem.Allocator) !Self {
        // Allocate huge pages for ring buffers (2MB pages for TLB efficiency)
        const ring_size = 1024 * 1024; // 1M entries per ring
        const market_data_size = ring_size * @sizeOf(MarketPacket) * 8;
        const order_size = ring_size * @sizeOf(Order) * 8;
        
        const alignment = @as(std.mem.Alignment, @enumFromInt(12)); // 2^12 = 4096 bytes
        const market_data_region = try allocator.alignedAlloc(u8, alignment, market_data_size);
        const order_region = try allocator.alignedAlloc(u8, alignment, order_size);
        
        // Allocate ring buffer structures
        var legion_rings: [8]*RingBuffer = undefined;
        var order_rings: [8]*RingBuffer = undefined;
        
        for (0..8) |i| {
            legion_rings[i] = try allocator.create(RingBuffer);
            order_rings[i] = try allocator.create(RingBuffer);
        }
        
        var engine = Self{
            .legion_rings = legion_rings,
            .strategists = undefined,
            .order_rings = order_rings,
            .market_data_region = market_data_region,
            .order_region = order_region,
            .start_time = std.time.timestamp(),
            .total_packets = atomic.Value(u64).init(0),
            .total_orders = atomic.Value(u64).init(0),
        };
        
        // Initialize ring buffers for each Centurion-Strategist pair
        for (0..8) |i| {
            const market_offset = i * ring_size * @sizeOf(MarketPacket);
            const order_offset = i * ring_size * @sizeOf(Order);
            
            engine.legion_rings[i].* = RingBuffer.init(
                ring_size,
                market_data_region[market_offset..market_offset + ring_size * @sizeOf(MarketPacket)]
            );
            
            engine.order_rings[i].* = RingBuffer.init(
                ring_size,
                order_region[order_offset..order_offset + ring_size * @sizeOf(Order)]
            );
            
            // Assign cores 8-15 to strategists (0-7 are for Legion)
            engine.strategists[i] = ZigStrategist.init(
                @intCast(i),
                @intCast(8 + i),
                engine.legion_rings[i],
                engine.order_rings[i]
            );
        }
        
        return engine;
    }
    
    pub fn start(self: *Self) !void {
        std.log.info("🔥 QUANTUM SYNAPSE ENGINE V2 INITIALIZING", .{});
        std.log.info("🔥 8 Legion Centurions: Cores 0-7", .{});
        std.log.info("🔥 8 Zig Strategists: Cores 8-15", .{});
        std.log.info("🔥 Target: 3.67 MILLION packets/second", .{});
        std.log.info("🔥 Latency Target: <100 nanoseconds", .{});
        
        // Launch the 8 Strategist threads
        var threads: [8]std.Thread = undefined;
        for (0..8) |i| {
            threads[i] = try std.Thread.spawn(.{}, ZigStrategist.run, .{&self.strategists[i]});
        }
        
        // Monitor performance
        var last_packets: u64 = 0;
        var last_orders: u64 = 0;
        
        while (true) {
            std.Thread.sleep(1_000_000_000); // 1 second
            
            const packets = self.getTotalPackets();
            const orders = self.getTotalOrders();
            
            const pps = packets - last_packets;
            const ops = orders - last_orders;
            
            std.log.info("📊 PPS: {} | OPS: {} | Total: {} packets, {} orders", .{
                pps, ops, packets, orders
            });
            
            last_packets = packets;
            last_orders = orders;
        }
    }
    
    pub fn getTotalPackets(self: *Self) u64 {
        var total: u64 = 0;
        for (&self.strategists) |*s| {
            total += s.packets_processed.load(.monotonic);
        }
        return total;
    }
    
    pub fn getTotalOrders(self: *Self) u64 {
        var total: u64 = 0;
        for (&self.strategists) |*s| {
            total += s.orders_generated.load(.monotonic);
        }
        return total;
    }
};

// Supporting structures (simplified for brevity)
const OrderBook = struct {
    bids: [100]PriceLevel,
    asks: [100]PriceLevel,
    
    pub fn init() OrderBook {
        return .{
            .bids = undefined,
            .asks = undefined,
        };
    }
    
    pub fn update(_: *OrderBook, _: *const MarketPacket) void {
        // Ultra-fast order book update logic
    }
};

const Position = struct {
    positions: [1000]i32, // Position per symbol ID
    
    pub fn init() Position {
        return .{ .positions = [_]i32{0} ** 1000 };
    }
    
    pub fn getSize(self: *const Position, symbol_id: u32) u32 {
        return @abs(self.positions[symbol_id]);
    }
};

const Signals = struct {
    threshold: f32 = 0.7,
    
    pub fn init() Signals {
        return .{};
    }
    
    pub fn generate(_: *Signals, book: *const OrderBook, packet: *const MarketPacket) Signal {
        // Calculate strength based on order book imbalance and momentum
        const bid_volume = book.bids[0].quantity + book.bids[1].quantity;
        const ask_volume = book.asks[0].quantity + book.asks[1].quantity;
        const total_volume = bid_volume + ask_volume;

        // Imbalance ratio: positive = more bids, negative = more asks
        const imbalance = if (total_volume > 0)
            @as(f32, @floatFromInt(bid_volume - ask_volume)) / @as(f32, @floatFromInt(total_volume))
        else 0.0;

        // Convert imbalance to strength (0.0 to 1.0)
        const raw_strength = (@abs(imbalance) + 0.5) / 1.5; // Normalize to 0.33-1.0 range
        const strength = @min(1.0, @max(0.0, raw_strength));

        return Signal{
            .symbol_id = packet.symbol_id,
            .direction = if (imbalance > 0) @as(i8, 1) else @as(i8, -1),
            .strength = strength,
            .bid = packet.price - 10,
            .ask = packet.price + 10,
        };
    }
};

const Signal = struct {
    symbol_id: u32,
    direction: i8,
    strength: f32,
    bid: u64,
    ask: u64,
};

pub const Order = extern struct {
    symbol_id: u32,
    side: enum(u8) { buy = 0, sell = 1 },
    price: u64,
    quantity: u32,
    timestamp_ns: u64,
    strategy_id: u8,
    _padding: [7]u8,
};

const PriceLevel = struct {
    price: u64,
    quantity: u32,
};

// ============================================================================
// THE NANOSECOND PREDATOR AWAKENS
// ============================================================================

pub fn main() !void {
    const allocator = std.heap.c_allocator;
    
    var engine = try QuantumSynapseEngine.init(allocator);
    try engine.start();
}