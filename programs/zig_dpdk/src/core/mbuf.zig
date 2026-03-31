const std = @import("std");
const config = @import("config.zig");
const hugepage = @import("../mem/hugepage.zig");
const physical = @import("../mem/physical.zig");

/// Packet buffer metadata. Exactly one cache line (64 bytes).
///
/// Memory layout of one mbuf slot (2176 bytes total):
///   [0..64)      MBuf struct (this)
///   [64..2112)   Data room (2048 bytes: headroom + packet data)
///   [2112..2176) Tailroom (64 bytes)
///
/// The `phys_addr` field holds the physical address of the data room start
/// (byte 64 of this allocation). For DMA descriptors: phys_addr + data_off.
pub const MBuf = extern struct {
    /// Physical address of the data room start (byte 64 of this allocation).
    phys_addr: u64,

    /// Hardware or software timestamp
    timestamp: u64,

    /// Next mbuf in chain (scatter/gather) or free list
    next: ?*MBuf,

    /// Back-pointer to owning pool (for free). Stored as raw pointer to
    /// avoid extern struct issues with forward references.
    pool_ptr: ?*anyopaque,

    /// RSS hash from NIC hardware
    rss_hash: u32,

    /// Length of packet data starting at data()
    pkt_len: u16,

    /// Offset from data room start to first byte of packet data (headroom)
    data_off: u16,

    /// VLAN tag if stripped by NIC
    vlan_tag: u16,

    /// Port (NIC) ID this packet came from
    port_id: u8,

    /// Segment count for scatter/gather
    nb_segs: u8,

    /// Flags (checksum offload status, etc.)
    flags: u32,

    /// Pad to exactly 64 bytes
    _reserved: [16]u8,

    comptime {
        if (@sizeOf(MBuf) != 64)
            @compileError("MBuf must be exactly 64 bytes (one cache line)");
    }

    // ── Data access ──────────────────────────────────────────────────

    /// Pointer to the first byte of packet data.
    pub inline fn data(self: *MBuf) [*]u8 {
        const base: [*]u8 = @ptrCast(self);
        return base + config.mbuf_metadata_size + self.data_off;
    }

    /// Packet data as a bounded slice.
    pub inline fn dataSlice(self: *MBuf) []u8 {
        return self.data()[0..self.pkt_len];
    }

    /// Pointer to the start of the data room (byte 64 from mbuf start).
    pub inline fn dataRoom(self: *MBuf) [*]u8 {
        const base: [*]u8 = @ptrCast(self);
        return base + config.mbuf_metadata_size;
    }

    /// Writable data room as a full slice (2048 bytes).
    pub inline fn dataRoomSlice(self: *MBuf) []u8 {
        return self.dataRoom()[0..config.mbuf_data_room_size];
    }

    pub inline fn headroom(self: *const MBuf) u16 {
        return self.data_off;
    }

    pub inline fn tailroom(self: *const MBuf) u16 {
        return config.mbuf_data_room_size - self.data_off - self.pkt_len;
    }

    /// Physical address for DMA descriptor programming.
    pub inline fn dmaAddr(self: *const MBuf) u64 {
        return self.phys_addr + self.data_off;
    }

    /// Physical address of the data room start (for RX descriptor pre-fill).
    pub inline fn bufDmaAddr(self: *const MBuf) u64 {
        return self.phys_addr;
    }

    // ── Lifecycle ────────────────────────────────────────────────────

    /// Reset metadata for reuse. Does NOT zero the data room.
    pub fn reset(self: *MBuf) void {
        self.pkt_len = 0;
        self.data_off = config.mbuf_default_headroom;
        self.nb_segs = 1;
        self.next = null;
        self.flags = 0;
        self.rss_hash = 0;
        self.vlan_tag = 0;
        self.timestamp = 0;
        self.port_id = 0;
    }

    /// Return this mbuf to its owning pool.
    pub fn free(self: *MBuf) void {
        if (self.pool_ptr) |p| {
            const owning_pool: *MBufPool = @ptrCast(@alignCast(p));
            owning_pool.put(self);
        }
    }

    /// Prepend `len` bytes (move data_off backwards, extending packet).
    pub fn prepend(self: *MBuf, len: u16) ?[*]u8 {
        if (len > self.data_off) return null;
        self.data_off -= len;
        self.pkt_len += len;
        return self.data();
    }

    /// Append `len` bytes (extend pkt_len into tailroom).
    pub fn append(self: *MBuf, len: u16) ?[*]u8 {
        if (len > self.tailroom()) return null;
        const ptr = self.data() + self.pkt_len;
        self.pkt_len += len;
        return ptr;
    }

    /// Get the owning pool (typed accessor).
    pub fn pool(self: *const MBuf) ?*MBufPool {
        const p = self.pool_ptr orelse return null;
        return @ptrCast(@alignCast(p));
    }
};

/// Pool of fixed-size packet buffers backed by contiguous memory.
/// Free list through MBuf.next pointers for O(1) alloc/free.
///
/// IMPORTANT: After create() or initFromMemory(), you MUST call populate()
/// before use. The pool must be at its final memory location (stack/global)
/// when populate() is called, because each MBuf stores a back-pointer to the pool.
pub const MBufPool = struct {
    /// Base address of the contiguous buffer region.
    base: [*]align(4096) u8,

    /// Total size of the buffer region in bytes.
    total_size: usize,

    /// Physical address of the buffer region base.
    base_phys: u64,

    /// Number of buffers in the pool.
    capacity: u32,

    /// Free list head.
    free_head: ?*MBuf,

    /// Number of available (free) buffers.
    free_count: u32,

    /// Backing hugepage region (for cleanup).
    region: hugepage.Region,

    /// Whether populate() has been called.
    populated: bool,

    /// Size of each buffer slot in bytes.
    /// Standard: 2176 (64 meta + 2048 data + 64 tail).
    /// AF_XDP: 4096 (one page per frame for fast index math).
    buf_size: u32,

    /// Create pool with default buf_size (2176). Call populate() after.
    pub fn create(count: u32, page_size: config.HugepageSize) !MBufPool {
        return createWithBufSize(count, page_size, config.mbuf_buf_size);
    }

    /// Create pool with custom buf_size. Call populate() after.
    pub fn createWithBufSize(count: u32, page_size: config.HugepageSize, buf_size: u32) !MBufPool {
        std.debug.assert(buf_size >= config.mbuf_metadata_size + 128); // metadata + min data
        const total_size = @as(usize, count) * buf_size;
        const region = try hugepage.allocRegion(total_size, page_size);

        return MBufPool{
            .base = region.ptr,
            .total_size = region.size,
            .base_phys = physical.virtToPhys(@intFromPtr(region.ptr)),
            .capacity = count,
            .free_head = null,
            .free_count = 0,
            .region = region,
            .populated = false,
            .buf_size = buf_size,
        };
    }

    /// Create pool over pre-allocated memory. Call populate() after.
    pub fn initFromMemory(memory: [*]align(4096) u8, size: usize, phys_base: u64) MBufPool {
        return initFromMemoryWithBufSize(memory, size, phys_base, config.mbuf_buf_size);
    }

    pub fn initFromMemoryWithBufSize(memory: [*]align(4096) u8, size: usize, phys_base: u64, buf_size: u32) MBufPool {
        const count: u32 = @intCast(size / buf_size);
        return MBufPool{
            .base = memory,
            .total_size = size,
            .base_phys = phys_base,
            .capacity = count,
            .free_head = null,
            .free_count = 0,
            .region = .{
                .ptr = memory,
                .size = size,
                .page_size = .regular,
                .phys_addr = phys_base,
            },
            .populated = false,
            .buf_size = buf_size,
        };
    }

    /// Initialize all mbuf metadata and build the free list.
    /// MUST be called after the MBufPool is at its final memory location.
    pub fn populate(self: *MBufPool) void {
        std.debug.assert(!self.populated);

        // Build free list in reverse so first get() returns buf 0
        var i: u32 = self.capacity;
        while (i > 0) {
            i -= 1;
            const offset = @as(usize, i) * self.buf_size;
            const mbuf: *MBuf = @ptrCast(@alignCast(self.base + offset));

            // Zero metadata then set fields
            mbuf.* = std.mem.zeroes(MBuf);
            mbuf.phys_addr = self.base_phys + offset + config.mbuf_metadata_size;
            mbuf.data_off = config.mbuf_default_headroom;
            mbuf.nb_segs = 1;
            mbuf.pool_ptr = @ptrCast(self);

            // Push onto free list
            mbuf.next = self.free_head;
            self.free_head = mbuf;
            self.free_count += 1;
        }

        self.populated = true;
    }

    /// Allocate one mbuf. Returns null if pool is empty.
    pub fn get(self: *MBufPool) ?*MBuf {
        const mbuf = self.free_head orelse return null;
        self.free_head = mbuf.next;
        mbuf.next = null;
        self.free_count -= 1;
        return mbuf;
    }

    /// Return one mbuf to the pool.
    pub fn put(self: *MBufPool, mbuf: *MBuf) void {
        mbuf.reset();
        mbuf.pool_ptr = @ptrCast(self);
        mbuf.next = self.free_head;
        self.free_head = mbuf;
        self.free_count += 1;
    }

    /// Bulk allocate up to `max_count` mbufs. Returns number actually allocated.
    pub fn getBulk(self: *MBufPool, bufs: []*MBuf, max_count: u32) u32 {
        var n: u32 = 0;
        while (n < max_count) {
            const mbuf = self.free_head orelse break;
            self.free_head = mbuf.next;
            mbuf.next = null;
            self.free_count -= 1;
            bufs[n] = mbuf;
            n += 1;
        }
        return n;
    }

    /// Bulk free mbufs back to pool.
    pub fn putBulk(self: *MBufPool, bufs: []*MBuf, count: u32) void {
        const limit = @min(count, @as(u32, @intCast(bufs.len)));
        for (0..limit) |i| {
            self.put(bufs[i]);
        }
    }

    /// Destroy the pool and free backing memory.
    pub fn destroy(self: *MBufPool) void {
        hugepage.freeRegion(&self.region);
        self.* = undefined;
    }

    pub fn availableCount(self: *const MBufPool) u32 {
        return self.free_count;
    }
};

// ── Tests ────────────────────────────────────────────────────────────────

const testing = std.testing;

test "MBuf: size is exactly 64 bytes" {
    try testing.expectEqual(@as(usize, 64), @sizeOf(MBuf));
}

test "MBuf: data access" {
    // Use a stack buffer to simulate an mbuf slot
    var slot: [config.mbuf_buf_size]u8 align(64) = undefined;
    const mbuf: *MBuf = @ptrCast(@alignCast(&slot));

    mbuf.* = std.mem.zeroes(MBuf);
    mbuf.data_off = config.mbuf_default_headroom;
    mbuf.pkt_len = 100;

    // data() should point to metadata_size + headroom into the slot
    const data_ptr = mbuf.data();
    const expected_offset = config.mbuf_metadata_size + config.mbuf_default_headroom;
    try testing.expectEqual(expected_offset, @as(u16, @intCast(@intFromPtr(data_ptr) - @intFromPtr(mbuf))));

    // dataSlice length should match pkt_len
    try testing.expectEqual(@as(usize, 100), mbuf.dataSlice().len);

    // headroom / tailroom
    try testing.expectEqual(config.mbuf_default_headroom, mbuf.headroom());
    try testing.expectEqual(config.mbuf_data_room_size - config.mbuf_default_headroom - 100, mbuf.tailroom());
}

test "MBuf: prepend and append" {
    var slot: [config.mbuf_buf_size]u8 align(64) = undefined;
    const mbuf: *MBuf = @ptrCast(@alignCast(&slot));

    mbuf.* = std.mem.zeroes(MBuf);
    mbuf.data_off = config.mbuf_default_headroom; // 128
    mbuf.pkt_len = 100;

    // Prepend 14 bytes (Ethernet header)
    const pre = mbuf.prepend(14);
    try testing.expect(pre != null);
    try testing.expectEqual(@as(u16, 114), mbuf.pkt_len);
    try testing.expectEqual(@as(u16, 114), mbuf.data_off);

    // Append 4 bytes (CRC)
    const app = mbuf.append(4);
    try testing.expect(app != null);
    try testing.expectEqual(@as(u16, 118), mbuf.pkt_len);

    // Prepend too much — should fail
    try testing.expect(mbuf.prepend(200) == null);
}

test "MBufPool: create, populate, alloc/free cycle" {
    const count: u32 = 16;
    var pool = try MBufPool.create(count, .regular);
    defer pool.destroy();
    pool.populate();

    try testing.expectEqual(count, pool.availableCount());

    // Allocate all buffers
    var bufs: [16]*MBuf = undefined;
    for (0..count) |i| {
        bufs[i] = pool.get() orelse return error.TestUnexpectedResult;
    }
    try testing.expectEqual(@as(u32, 0), pool.availableCount());
    try testing.expect(pool.get() == null);

    // Verify each buffer has valid metadata
    for (bufs[0..count]) |mbuf| {
        try testing.expectEqual(config.mbuf_default_headroom, mbuf.data_off);
        try testing.expectEqual(@as(u8, 1), mbuf.nb_segs);
        try testing.expect(mbuf.pool() != null);
    }

    // Free all buffers
    for (bufs[0..count]) |mbuf| {
        mbuf.free();
    }
    try testing.expectEqual(count, pool.availableCount());
}

test "MBufPool: bulk operations" {
    const count: u32 = 32;
    var pool = try MBufPool.create(count, .regular);
    defer pool.destroy();
    pool.populate();

    // Bulk allocate 8
    var bufs: [8]*MBuf = undefined;
    const got = pool.getBulk(&bufs, 8);
    try testing.expectEqual(@as(u32, 8), got);
    try testing.expectEqual(count - 8, pool.availableCount());

    // Bulk free
    pool.putBulk(&bufs, 8);
    try testing.expectEqual(count, pool.availableCount());
}

test "MBufPool: data write/read through mbuf" {
    var pool = try MBufPool.create(4, .regular);
    defer pool.destroy();
    pool.populate();

    const mbuf = pool.get().?;
    defer mbuf.free();

    // Write a pattern into the data room
    const payload = "Hello, DPDK!";
    const data_ptr = mbuf.data();
    @memcpy(data_ptr[0..payload.len], payload);
    mbuf.pkt_len = @intCast(payload.len);

    // Read it back
    try testing.expectEqualStrings(payload, mbuf.dataSlice());
}
