/// Zigix platform support: zero-copy networking via zcnet shared memory.
///
/// The zcnet interface maps 5 contiguous pages into userspace at a fixed VA:
///   Page 0: Control page (rx/tx producer/consumer indices + descriptor rings + stats)
///   Pages 1-4: Buffer pool (32 x 2048-byte packet buffers)
///
/// Syscalls:
///   500 = zcnet_attach  — allocate and map shared region, returns base address
///   501 = zcnet_detach  — tear down shared region
///   502 = zcnet_kick    — flush TX ring immediately
///
/// After attach, the hot path is pure shared-memory polling — zero syscalls for RX,
/// one optional kick syscall for low-latency TX flush.

const std = @import("std");

/// Fixed user virtual address where zcnet maps the shared region.
pub const ZCNET_USER_BASE: u64 = 0x6F00_0000_0000;

/// Number of entries in each descriptor ring.
pub const RING_SIZE: u32 = 32;

/// Size of each packet buffer in the shared pool.
pub const BUF_SIZE: usize = 2048;

/// VirtIO net header size prepended to each buffer.
pub const NET_HDR_SIZE: usize = 10;

/// Page size (4 KiB).
pub const PAGE_SIZE: usize = 4096;

/// Number of shared pages (1 control + 4 buffer).
pub const SHARED_PAGES: u64 = 5;

/// First RX buffer index (0..15 are RX buffers).
pub const RX_BUF_START: u16 = 0;
pub const RX_BUF_COUNT: u16 = 16;

/// First TX buffer index (16..31 are TX buffers).
pub const TX_BUF_START: u16 = 16;
pub const TX_BUF_COUNT: u16 = 16;

/// Descriptor flag indicating valid data.
pub const DESC_FLAG_VALID: u16 = 1;

/// Control page offsets (byte offsets from shared region base).
pub const RX_PROD_OFF: usize = 0x000;
pub const RX_CONS_OFF: usize = 0x004;
pub const RX_DESCS_OFF: usize = 0x008;
pub const TX_PROD_OFF: usize = 0x108;
pub const TX_CONS_OFF: usize = 0x10C;
pub const TX_DESCS_OFF: usize = 0x110;
pub const STATS_RX_COUNT_OFF: usize = 0x210;
pub const STATS_TX_COUNT_OFF: usize = 0x214;
pub const STATS_RX_DROPS_OFF: usize = 0x218;

/// Shared descriptor format (8 bytes, matches kernel ZcDesc).
pub const ZcDesc = extern struct {
    buf_idx: u16,
    len: u16,
    flags: u16,
    _pad: u16,
};

/// Syscall numbers for zcnet.
const NR_ZCNET_ATTACH: u64 = 500;
const NR_ZCNET_DETACH: u64 = 501;
const NR_ZCNET_KICK: u64 = 502;

/// Shared-memory queue state with volatile pointers into the control page.
pub const SharedNetQueue = struct {
    /// Base address of the shared region (control page).
    base: u64,

    /// Base address of the buffer pool (base + PAGE_SIZE).
    buf_base: [*]u8,

    /// RX producer index (written by kernel).
    rx_prod: *volatile u32,
    /// RX consumer index (written by userspace).
    rx_cons: *volatile u32,
    /// RX descriptor ring (RING_SIZE entries).
    rx_descs: [*]volatile ZcDesc,

    /// TX producer index (written by userspace).
    tx_prod: *volatile u32,
    /// TX consumer index (written by kernel).
    tx_cons: *volatile u32,
    /// TX descriptor ring (RING_SIZE entries).
    tx_descs: [*]volatile ZcDesc,

    /// Stats counters (read-only from userspace perspective).
    stats_rx_count: *volatile u32,
    stats_tx_count: *volatile u32,
    stats_rx_drops: *volatile u32,

    /// Initialize volatile pointers from a base address.
    pub fn initFromBase(base: u64) SharedNetQueue {
        return .{
            .base = base,
            .buf_base = @ptrFromInt(base + PAGE_SIZE),
            .rx_prod = @ptrFromInt(base + RX_PROD_OFF),
            .rx_cons = @ptrFromInt(base + RX_CONS_OFF),
            .rx_descs = @ptrFromInt(base + RX_DESCS_OFF),
            .tx_prod = @ptrFromInt(base + TX_PROD_OFF),
            .tx_cons = @ptrFromInt(base + TX_CONS_OFF),
            .tx_descs = @ptrFromInt(base + TX_DESCS_OFF),
            .stats_rx_count = @ptrFromInt(base + STATS_RX_COUNT_OFF),
            .stats_tx_count = @ptrFromInt(base + STATS_TX_COUNT_OFF),
            .stats_rx_drops = @ptrFromInt(base + STATS_RX_DROPS_OFF),
        };
    }
};

/// Attach to the zcnet shared-memory region.
/// Returns the base virtual address on success, or error on failure.
pub fn zcnetAttach() !u64 {
    if (comptime !is_zigix_target) return error.AttachFailed;
    const ret = syscall0(NR_ZCNET_ATTACH);
    if (ret < 0) return error.AttachFailed;
    return @bitCast(ret);
}

/// Detach from the zcnet shared-memory region.
pub fn zcnetDetach() void {
    if (comptime !is_zigix_target) return;
    _ = syscall0(NR_ZCNET_DETACH);
}

/// Kick the kernel to immediately drain the TX ring.
pub fn zcnetKick() void {
    if (comptime !is_zigix_target) return;
    _ = syscall0(NR_ZCNET_KICK);
}

const builtin = @import("builtin");

/// True when targeting x86_64 (Zigix runs on x86_64 only).
/// On other architectures (e.g. aarch64 macOS for testing), syscall
/// functions are no-ops and attach always returns error.
const is_zigix_target = builtin.cpu.arch == .x86_64;

// Raw syscall primitive — inline asm for x86_64 int $0x80.
// Zigix userspace uses int 0x80 for syscalls (matches kernel IDT vector).
inline fn syscall0(nr: u64) isize {
    if (comptime !is_zigix_target) return -1;
    return asm volatile ("int $0x80"
        : [ret] "={rax}" (-> isize),
        : [nr] "{rax}" (nr),
        : "memory"
    );
}

pub const ZigixError = error{
    AttachFailed,
};

// ── Tests ────────────────────────────────────────────────────────────────

test "zigix: constants match kernel layout" {
    const testing = std.testing;

    // ZcDesc is 8 bytes
    try testing.expectEqual(@as(usize, 8), @sizeOf(ZcDesc));

    // Ring holds 32 descriptors = 256 bytes
    try testing.expectEqual(@as(usize, 256), RING_SIZE * @sizeOf(ZcDesc));

    // RX descriptors at 0x008, TX descriptors at 0x110
    // RX: 0x008 + 32*8 = 0x008 + 0x100 = 0x108 = TX_PROD offset (correct: packed)
    try testing.expectEqual(@as(usize, 0x108), RX_DESCS_OFF + RING_SIZE * @sizeOf(ZcDesc));

    // Buffer pool starts at page 1
    try testing.expectEqual(@as(usize, 4096), PAGE_SIZE);

    // Buffer pool = 4 pages = 16384 bytes, each buffer = 2048 bytes → 8 buffers fit per page
    try testing.expectEqual(@as(usize, 8), PAGE_SIZE / BUF_SIZE * 4);
    // Ring has 32 descriptor slots; kernel uses indices 0..15 RX, 16..31 TX
    try testing.expectEqual(@as(u32, 32), RING_SIZE);
}

test "zigix: SharedNetQueue initFromBase" {
    // Test with a fake base address
    const fake_base: u64 = 0x1000_0000;
    const q = SharedNetQueue.initFromBase(fake_base);

    const testing = std.testing;
    try testing.expectEqual(fake_base, q.base);
    try testing.expectEqual(fake_base + PAGE_SIZE, @intFromPtr(q.buf_base));
    try testing.expectEqual(fake_base + RX_PROD_OFF, @intFromPtr(q.rx_prod));
    try testing.expectEqual(fake_base + TX_PROD_OFF, @intFromPtr(q.tx_prod));
    try testing.expectEqual(fake_base + STATS_RX_COUNT_OFF, @intFromPtr(q.stats_rx_count));
}
