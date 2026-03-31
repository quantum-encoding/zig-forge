/// Runtime configuration for zig_dpdk.
/// Constants are comptime-known. Config struct holds per-instance startup parameters.

/// Default number of RX/TX descriptors per queue
pub const default_rx_ring_size: u32 = 1024;
pub const default_tx_ring_size: u32 = 1024;

/// Default number of mbufs in the buffer pool
pub const default_pool_size: u32 = 8192;

/// MBuf layout constants (bytes)
pub const mbuf_metadata_size: u16 = 64;
pub const mbuf_data_room_size: u16 = 2048;
pub const mbuf_tailroom_size: u16 = 64;
pub const mbuf_buf_size: u32 = @as(u32, mbuf_metadata_size) + mbuf_data_room_size + mbuf_tailroom_size; // 2176
pub const mbuf_default_headroom: u16 = 128;

/// Maximum number of ports (NICs)
pub const max_ports: u8 = 16;

/// Maximum number of queues per port
pub const max_queues_per_port: u8 = 16;

/// Maximum burst size for RX/TX operations
pub const max_burst_size: u16 = 64;
pub const default_burst_size: u16 = 32;

/// Cache line size (x86_64)
pub const cache_line_size: usize = 64;

/// Page sizes
pub const page_size_4k: usize = 4096;
pub const page_size_2m: usize = 2 * 1024 * 1024;
pub const page_size_1g: usize = 1024 * 1024 * 1024;

/// Hugepage size selection
pub const HugepageSize = enum {
    regular,
    huge_2m,
    huge_1g,

    pub fn bytes(self: HugepageSize) usize {
        return switch (self) {
            .regular => page_size_4k,
            .huge_2m => page_size_2m,
            .huge_1g => page_size_1g,
        };
    }
};

/// Runtime configuration passed at startup
pub const Config = struct {
    num_rx_queues: u8 = 1,
    num_tx_queues: u8 = 1,
    rx_ring_size: u32 = default_rx_ring_size,
    tx_ring_size: u32 = default_tx_ring_size,
    pool_size: u32 = default_pool_size,
    burst_size: u16 = default_burst_size,
    numa_node: i8 = -1, // -1 = auto-detect
    hugepage_size: HugepageSize = .huge_2m,
};
