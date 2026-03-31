/// Composable packet processing pipeline.
///
/// Pipeline stages are comptime-composed into a single straight-line function.
/// No function pointers, no indirect calls, no branch mispredictions from dispatch.
///
/// Each stage implements:
///   fn process(mbuf: *MBuf) Action
///
/// Actions:
///   .forward  — pass to next stage
///   .drop     — free mbuf, increment drop counter
///   .consume  — mbuf ownership transfers to the stage (e.g., enqueued to app ring)
///
/// Usage:
///   const MyPipeline = Pipeline(&.{
///       EthernetFilter,
///       Ipv4Validate,
///       UdpDemux,
///   });
///   var pipe = MyPipeline.init(&stats);
///   pipe.processBurst(bufs, count);

const std = @import("std");
const mbuf_mod = @import("../core/mbuf.zig");
const stats_mod = @import("../core/stats.zig");
const config = @import("../core/config.zig");

const MBuf = mbuf_mod.MBuf;

/// Result of processing a single packet through one stage.
pub const Action = enum {
    /// Pass the packet to the next stage.
    forward,
    /// Drop the packet. The pipeline frees the mbuf.
    drop,
    /// The stage has consumed the packet (took ownership of the mbuf).
    /// Pipeline does NOT free it.
    consume,
};

/// Pipeline stage interface.
/// Any struct with a `pub fn process(*MBuf) Action` qualifies.
/// Stages may also have:
///   `pub fn init() @This()` — called once at pipeline creation
///   `pub fn deinit(*@This())` — called on pipeline teardown
pub fn isValidStage(comptime S: type) bool {
    return @hasDecl(S, "process");
}

/// Pipeline statistics.
pub const PipelineStats = struct {
    rx_count: u64 = 0,
    tx_count: u64 = 0,
    drop_count: u64 = 0,
    consume_count: u64 = 0,

    pub fn recordRx(self: *PipelineStats, count: u64) void {
        self.rx_count += count;
    }

    pub fn recordTx(self: *PipelineStats, count: u64) void {
        self.tx_count += count;
    }

    pub fn recordDrop(self: *PipelineStats) void {
        self.drop_count += 1;
    }

    pub fn recordConsume(self: *PipelineStats) void {
        self.consume_count += 1;
    }
};

/// Comptime-composed packet processing pipeline.
/// `stages` is a tuple of stage types, each with a `process(*MBuf) Action` method.
pub fn Pipeline(comptime stage_types: []const type) type {
    // Validate all stages at comptime
    inline for (stage_types) |S| {
        if (!isValidStage(S))
            @compileError("Pipeline stage must have a `pub fn process(*MBuf) Action` method");
    }

    return struct {
        const Self = @This();
        const num_stages = stage_types.len;

        stats: PipelineStats,

        pub fn init() Self {
            return .{
                .stats = .{},
            };
        }

        /// Process a single packet through all stages.
        /// Returns the action taken by the last stage (or the first non-forward action).
        pub fn processOne(self: *Self, mbuf: *MBuf) Action {
            inline for (stage_types) |Stage| {
                const action = Stage.process(mbuf);
                switch (action) {
                    .forward => {},
                    .drop => {
                        mbuf.free();
                        self.stats.recordDrop();
                        return .drop;
                    },
                    .consume => {
                        self.stats.recordConsume();
                        return .consume;
                    },
                }
            }
            return .forward;
        }

        /// Process a burst of packets. Returns count of forwarded packets
        /// (still in bufs, compacted). Dropped/consumed packets are removed.
        pub fn processBurst(self: *Self, bufs: []*MBuf, count: u16) u16 {
            self.stats.recordRx(count);
            var out: u16 = 0;

            for (0..count) |i| {
                const action = self.processOne(bufs[i]);
                if (action == .forward) {
                    bufs[out] = bufs[i];
                    out += 1;
                }
            }

            self.stats.recordTx(out);
            return out;
        }

        pub fn getStats(self: *const Self) PipelineStats {
            return self.stats;
        }

        pub fn resetStats(self: *Self) void {
            self.stats = .{};
        }
    };
}

// ── Built-in Stages ──────────────────────────────────────────────────────

const ethernet = @import("../net/ethernet.zig");
const ipv4 = @import("../net/ipv4.zig");

/// Drop non-IP, non-ARP frames.
pub const EthernetFilter = struct {
    pub fn process(mbuf: *MBuf) Action {
        const data = mbuf.dataSlice();
        const result = ethernet.parseFrame(data) orelse return .drop;
        return switch (result.ether_type) {
            .ipv4, .arp, .ipv6 => .forward,
            else => .drop,
        };
    }
};

/// Validate IPv4 header: version, IHL, checksum, TTL > 0.
pub const Ipv4Validate = struct {
    pub fn process(mbuf: *MBuf) Action {
        const data = mbuf.dataSlice();
        const eth_result = ethernet.parseFrame(data) orelse return .drop;
        if (eth_result.ether_type != .ipv4) return .forward; // pass non-IPv4
        const hdr = ipv4.parse(eth_result.payload) orelse return .drop;
        if (hdr.ttl == 0) return .drop;
        if (!hdr.verifyChecksum()) return .drop;
        return .forward;
    }
};

/// Filter by UDP destination port.
pub fn UdpPortFilter(comptime port: u16) type {
    const udp = @import("../net/udp.zig");

    return struct {
        pub fn process(mbuf: *MBuf) Action {
            const data = mbuf.dataSlice();
            const eth_result = ethernet.parseFrame(data) orelse return .drop;
            if (eth_result.ether_type != .ipv4) return .forward;
            const ip_result = ipv4.parsePacket(eth_result.payload) orelse return .drop;
            if (ip_result.header.proto() != .udp) return .forward;
            const udp_hdr = udp.parse(ip_result.payload) orelse return .drop;
            if (udp_hdr.dstPort() != port) return .drop;
            return .forward;
        }
    };
}

/// Pass-through stage (no-op). Useful for testing.
pub const PassThrough = struct {
    pub fn process(_: *MBuf) Action {
        return .forward;
    }
};

/// Drop everything. Useful for testing.
pub const DropAll = struct {
    pub fn process(_: *MBuf) Action {
        return .drop;
    }
};

// ── Tests ────────────────────────────────────────────────────────────────

const testing = std.testing;

test "pipeline: empty pipeline forwards all" {
    const EmptyPipeline = Pipeline(&.{});
    var pipe = EmptyPipeline.init();

    // Create a fake mbuf on the stack
    var slot: [config.mbuf_buf_size]u8 align(64) = undefined;
    const mbuf: *MBuf = @ptrCast(@alignCast(&slot));
    mbuf.* = std.mem.zeroes(MBuf);
    mbuf.data_off = config.mbuf_default_headroom;
    mbuf.pkt_len = 64;

    const action = pipe.processOne(mbuf);
    try testing.expectEqual(Action.forward, action);
}

test "pipeline: single pass-through stage" {
    const TestPipeline = Pipeline(&.{PassThrough});
    var pipe = TestPipeline.init();

    var slot: [config.mbuf_buf_size]u8 align(64) = undefined;
    const mbuf: *MBuf = @ptrCast(@alignCast(&slot));
    mbuf.* = std.mem.zeroes(MBuf);
    mbuf.data_off = config.mbuf_default_headroom;
    mbuf.pkt_len = 64;

    const action = pipe.processOne(mbuf);
    try testing.expectEqual(Action.forward, action);
}

test "pipeline: drop-all stage" {
    const TestPipeline = Pipeline(&.{DropAll});
    var pipe = TestPipeline.init();

    // Need a pool-backed mbuf for free() in drop path
    var pool = try mbuf_mod.MBufPool.create(4, .regular);
    defer pool.destroy();
    pool.populate();

    const mbuf = pool.get().?;
    mbuf.pkt_len = 64;

    const action = pipe.processOne(mbuf);
    try testing.expectEqual(Action.drop, action);
    try testing.expectEqual(@as(u64, 1), pipe.stats.drop_count);
}

test "pipeline: chained stages" {
    const TestPipeline = Pipeline(&.{ PassThrough, PassThrough, PassThrough });
    var pipe = TestPipeline.init();

    var slot: [config.mbuf_buf_size]u8 align(64) = undefined;
    const mbuf: *MBuf = @ptrCast(@alignCast(&slot));
    mbuf.* = std.mem.zeroes(MBuf);
    mbuf.data_off = config.mbuf_default_headroom;
    mbuf.pkt_len = 64;

    try testing.expectEqual(Action.forward, pipe.processOne(mbuf));
}

test "pipeline: drop in middle stage stops processing" {
    const TestPipeline = Pipeline(&.{ PassThrough, DropAll, PassThrough });
    var pipe = TestPipeline.init();

    var pool = try mbuf_mod.MBufPool.create(4, .regular);
    defer pool.destroy();
    pool.populate();

    const mbuf = pool.get().?;
    mbuf.pkt_len = 64;

    try testing.expectEqual(Action.drop, pipe.processOne(mbuf));
    try testing.expectEqual(@as(u64, 1), pipe.stats.drop_count);
}

test "pipeline: processBurst compacts forwarded packets" {
    const TestPipeline = Pipeline(&.{PassThrough});
    var pipe = TestPipeline.init();

    var pool = try mbuf_mod.MBufPool.create(8, .regular);
    defer pool.destroy();
    pool.populate();

    var bufs: [4]*MBuf = undefined;
    for (&bufs) |*b| {
        b.* = pool.get().?;
        b.*.pkt_len = 64;
    }

    const forwarded = pipe.processBurst(&bufs, 4);
    try testing.expectEqual(@as(u16, 4), forwarded);
    try testing.expectEqual(@as(u64, 4), pipe.stats.rx_count);
    try testing.expectEqual(@as(u64, 4), pipe.stats.tx_count);

    // Free them
    for (bufs[0..forwarded]) |b| b.free();
}

test "pipeline: stats tracking" {
    const TestPipeline = Pipeline(&.{PassThrough});
    var pipe = TestPipeline.init();

    try testing.expectEqual(@as(u64, 0), pipe.getStats().rx_count);
    pipe.resetStats();
    try testing.expectEqual(@as(u64, 0), pipe.getStats().drop_count);
}
