//! Mining Worker Thread
//! Each worker continuously hashes nonces looking for valid shares
//! Uses SIMD batching (AVX2/AVX-512) with midstate optimization for maximum performance

const std = @import("std");
const types = @import("../stratum/types.zig");
const dispatch = @import("../crypto/dispatch.zig");
const Midstate = @import("../crypto/sha256_midstate.zig").Midstate;
const avx512_midstate = @import("../crypto/sha256_avx512_midstate.zig");
const avx2_midstate = @import("../crypto/sha256_avx2_midstate.zig");

/// Minimum leading zero bits to emit a hash event (reduces noise)
/// 16 bits = ~1 in 65536 hashes, good balance for dashboard visualization
const HASH_EVENT_THRESHOLD: u8 = 16;

pub const WorkerStats = struct {
    hashes: std.atomic.Value(u64),
    shares_found: std.atomic.Value(u32),
    shares_accepted: std.atomic.Value(u32),
    shares_rejected: std.atomic.Value(u32),

    pub fn init() WorkerStats {
        return .{
            .hashes = std.atomic.Value(u64).init(0),
            .shares_found = std.atomic.Value(u32).init(0),
            .shares_accepted = std.atomic.Value(u32).init(0),
            .shares_rejected = std.atomic.Value(u32).init(0),
        };
    }

    pub fn recordHash(self: *WorkerStats) void {
        _ = self.hashes.fetchAdd(1, .monotonic);
    }

    pub fn recordHashes(self: *WorkerStats, count: u64) void {
        _ = self.hashes.fetchAdd(count, .monotonic);
    }

    pub fn recordShare(self: *WorkerStats) void {
        _ = self.shares_found.fetchAdd(1, .monotonic);
    }

    pub fn getHashrate(self: *WorkerStats, duration_ns: u64) f64 {
        const hashes = self.hashes.load(.monotonic);
        const duration_s = @as(f64, @floatFromInt(duration_ns)) / 1_000_000_000.0;
        return @as(f64, @floatFromInt(hashes)) / duration_s;
    }
};

pub const ShareSubmission = struct {
    nonce: u32,
    ntime: u32,
    job_id: []const u8,
};

pub const Worker = struct {
    id: u32,
    stats: *WorkerStats,
    job: ?types.Job,
    target: types.Target,
    running: std.atomic.Value(bool),
    hasher: dispatch.Hasher,
    midstate: ?Midstate,
    pending_shares: std.ArrayListUnmanaged(ShareSubmission),
    share_lock: std.atomic.Value(bool),

    const Self = @This();

    pub fn init(id: u32, stats: *WorkerStats) Self {
        return .{
            .id = id,
            .stats = stats,
            .job = null,
            .target = types.Target.fromNBits(0x1d00ffff), // Default difficulty
            .running = std.atomic.Value(bool).init(false),
            .hasher = dispatch.Hasher.init(),
            .midstate = null,
            .pending_shares = .empty,
            .share_lock = std.atomic.Value(bool).init(false),
        };
    }

    /// Main mining loop - runs in dedicated thread with SIMD batching
    /// Uses midstate optimization when a job is active (skips Block 1 computation)
    pub fn run(self: *Self) void {
        self.running.store(true, .release);

        var nonce: u32 = self.id * 1_000_000; // Offset based on worker ID
        const batch_size = self.hasher.getBatchSize();

        while (self.running.load(.acquire)) {
            // Use midstate-optimized path when we have a real job
            if (self.midstate) |*midstate| {
                if (batch_size == 16) {
                    self.runBatch16Midstate(midstate, &nonce);
                } else if (batch_size == 8) {
                    self.runBatch8Midstate(midstate, &nonce);
                } else {
                    self.runBatchScalarMidstate(midstate, &nonce);
                }
            } else {
                // Fallback for demo mode (no job) - uses full header hashing
                if (batch_size == 16) {
                    self.runBatch16(&nonce);
                } else if (batch_size == 8) {
                    self.runBatch8(&nonce);
                } else {
                    self.runBatchScalar(&nonce);
                }
            }

            // Check for new work every batch
            if (nonce % 1_000_000 == 0) {
                std.Thread.yield() catch {};
            }
        }
    }

    /// Process 16 nonces at once (AVX-512)
    fn runBatch16(self: *Self, nonce: *u32) void {
        var headers: [16][80]u8 = undefined;
        var hashes: [16][32]u8 = undefined;

        // Build 16 headers with consecutive nonces
        for (0..16) |i| {
            headers[i] = self.buildHeader(nonce.* +% @as(u32, @intCast(i)));
        }

        // Hash all 16 in parallel
        self.hasher.hash16(&headers, &hashes);
        self.stats.recordHashes(16);

        // Check all 16 results
        for (0..16) |i| {
            self.checkAndEmitHash(&hashes[i], nonce.* +% @as(u32, @intCast(i)));
            if (self.target.meetsTarget(&hashes[i])) {
                self.stats.recordShare();
                self.queueShare(nonce.* +% @as(u32, @intCast(i)));
            }
        }

        nonce.* +%= 16;
    }

    /// Process 8 nonces at once (AVX2)
    fn runBatch8(self: *Self, nonce: *u32) void {
        var headers: [8][80]u8 = undefined;
        var hashes: [8][32]u8 = undefined;

        // Build 8 headers with consecutive nonces
        for (0..8) |i| {
            headers[i] = self.buildHeader(nonce.* +% @as(u32, @intCast(i)));
        }

        // Hash all 8 in parallel
        self.hasher.hash8(&headers, &hashes);
        self.stats.recordHashes(8);

        // Check all 8 results
        for (0..8) |i| {
            self.checkAndEmitHash(&hashes[i], nonce.* +% @as(u32, @intCast(i)));
            if (self.target.meetsTarget(&hashes[i])) {
                self.stats.recordShare();
                self.queueShare(nonce.* +% @as(u32, @intCast(i)));
            }
        }

        nonce.* +%= 8;
    }

    /// Process single nonce (scalar fallback)
    fn runBatchScalar(self: *Self, nonce: *u32) void {
        var header = self.buildHeader(nonce.*);
        var hash: [32]u8 = undefined;

        self.hasher.hashOne(&header, &hash);
        self.stats.recordHash();

        self.checkAndEmitHash(&hash, nonce.*);
        if (self.target.meetsTarget(&hash)) {
            self.stats.recordShare();
            self.queueShare(nonce.*);
        }

        nonce.* +%= 1;
    }

    /// Process 16 nonces at once using midstate optimization (AVX-512)
    /// Skips Block 1 computation - ~33% faster than full header hashing
    fn runBatch16Midstate(self: *Self, midstate: *const Midstate, nonce: *u32) void {
        var hashes: [16][32]u8 = undefined;

        // Hash 16 nonces in parallel, starting from midstate
        avx512_midstate.hashBatchWithMidstate(midstate, nonce.*, &hashes);
        self.stats.recordHashes(16);

        // Check all 16 results
        for (0..16) |i| {
            self.checkAndEmitHash(&hashes[i], nonce.* +% @as(u32, @intCast(i)));
            if (self.target.meetsTarget(&hashes[i])) {
                self.stats.recordShare();
                self.queueShare(nonce.* +% @as(u32, @intCast(i)));
            }
        }

        nonce.* +%= 16;
    }

    /// Process 8 nonces at once using midstate optimization (AVX2)
    /// Skips Block 1 computation - ~33% faster than full header hashing
    fn runBatch8Midstate(self: *Self, midstate: *const Midstate, nonce: *u32) void {
        var hashes: [8][32]u8 = undefined;

        // Hash 8 nonces in parallel, starting from midstate
        avx2_midstate.hashBatchWithMidstate(midstate, nonce.*, &hashes);
        self.stats.recordHashes(8);

        // Check all 8 results
        for (0..8) |i| {
            self.checkAndEmitHash(&hashes[i], nonce.* +% @as(u32, @intCast(i)));
            if (self.target.meetsTarget(&hashes[i])) {
                self.stats.recordShare();
                self.queueShare(nonce.* +% @as(u32, @intCast(i)));
            }
        }

        nonce.* +%= 8;
    }

    /// Process single nonce using midstate optimization (scalar fallback)
    fn runBatchScalarMidstate(self: *Self, midstate: *const Midstate, nonce: *u32) void {
        var hash: [32]u8 = undefined;

        midstate.hash(nonce.*, &hash);
        self.stats.recordHash();

        self.checkAndEmitHash(&hash, nonce.*);
        if (self.target.meetsTarget(&hash)) {
            self.stats.recordShare();
            self.queueShare(nonce.*);
        }

        nonce.* +%= 1;
    }

    /// Count leading zero bits in a hash (Bitcoin hashes are little-endian,
    /// so we count from the END of the byte array)
    fn countLeadingZeroBits(hash: *const [32]u8) u8 {
        var zeros: u8 = 0;
        // Bitcoin hash comparison is little-endian, check from end
        var i: usize = 31;
        while (true) : (i -= 1) {
            if (hash[i] == 0) {
                zeros += 8;
            } else {
                // Count leading zeros in this byte
                zeros += @clz(hash[i]);
                break;
            }
            if (i == 0) break;
        }
        return zeros;
    }

    /// Emit JSON hash event for dashboard visualization
    fn emitHashEvent(hash: *const [32]u8, leading_zeros: u8, nonce: u32, worker_id: u32) void {
        // Format hash as hex (reversed for display - big-endian)
        var hash_hex: [64]u8 = undefined;
        for (0..32) |i| {
            const byte = hash[31 - i]; // Reverse for display
            const hex_chars = "0123456789abcdef";
            hash_hex[i * 2] = hex_chars[byte >> 4];
            hash_hex[i * 2 + 1] = hex_chars[byte & 0x0F];
        }

        std.debug.print(
            \\{{"type":"hash","hash":"{s}","leading_zeros":{},"nonce":{},"worker":{}}}
            \\
        , .{ hash_hex, leading_zeros, nonce, worker_id });
    }

    /// Check hash and emit event if it has significant leading zeros
    fn checkAndEmitHash(self: *Self, hash: *const [32]u8, nonce: u32) void {
        const zeros = countLeadingZeroBits(hash);
        if (zeros >= HASH_EVENT_THRESHOLD) {
            emitHashEvent(hash, zeros, nonce, self.id);
        }
    }

    /// Queue a share for submission to pool (lock-free spinlock)
    fn queueShare(self: *Self, nonce: u32) void {
        const job = self.job orelse return;
        // Spinlock acquire
        while (self.share_lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {}
        defer self.share_lock.store(false, .release);
        self.pending_shares.append(std.heap.page_allocator, .{
            .nonce = nonce,
            .ntime = job.ntime,
            .job_id = job.job_id,
        }) catch {};
    }

    /// Drain pending shares (called by engine/dispatcher)
    pub fn drainShares(self: *Self) []ShareSubmission {
        while (self.share_lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {}
        defer self.share_lock.store(false, .release);
        const items = self.pending_shares.toOwnedSlice(std.heap.page_allocator) catch return &.{};
        return items;
    }

    pub fn stop(self: *Self) void {
        self.running.store(false, .release);
    }

    pub fn updateJob(self: *Self, job: types.Job, target: types.Target) void {
        self.job = job;
        self.target = target;

        // Compute midstate from header template (nonce=0 as placeholder)
        // Block 1 (bytes 0-63) is constant for all nonces in this job
        const header = self.buildHeader(0);
        self.midstate = Midstate.init(&header);
    }

    /// Build 80-byte block header from job and nonce
    fn buildHeader(self: *Self, nonce: u32) [80]u8 {
        var header = [_]u8{0} ** 80;

        // Always apply nonce for demo mode (even without a job)
        header[76] = @intCast(nonce & 0xFF);
        header[77] = @intCast((nonce >> 8) & 0xFF);
        header[78] = @intCast((nonce >> 16) & 0xFF);
        header[79] = @intCast((nonce >> 24) & 0xFF);

        const job = self.job orelse return header;

        // Version (bytes 0-3, little-endian)
        header[0] = @intCast(job.version & 0xFF);
        header[1] = @intCast((job.version >> 8) & 0xFF);
        header[2] = @intCast((job.version >> 16) & 0xFF);
        header[3] = @intCast((job.version >> 24) & 0xFF);

        // Previous block hash (bytes 4-35, already in correct order)
        @memcpy(header[4..36], &job.prevhash);

        // Merkle root (bytes 36-67) - simplified, just zeros for now
        // Real implementation would compute from coinbase + merkle branches

        // Time (bytes 68-71, little-endian)
        header[68] = @intCast(job.ntime & 0xFF);
        header[69] = @intCast((job.ntime >> 8) & 0xFF);
        header[70] = @intCast((job.ntime >> 16) & 0xFF);
        header[71] = @intCast((job.ntime >> 24) & 0xFF);

        // Bits (bytes 72-75, little-endian)
        header[72] = @intCast(job.nbits & 0xFF);
        header[73] = @intCast((job.nbits >> 8) & 0xFF);
        header[74] = @intCast((job.nbits >> 16) & 0xFF);
        header[75] = @intCast((job.nbits >> 24) & 0xFF);

        // Nonce (bytes 76-79, little-endian)
        header[76] = @intCast(nonce & 0xFF);
        header[77] = @intCast((nonce >> 8) & 0xFF);
        header[78] = @intCast((nonce >> 16) & 0xFF);
        header[79] = @intCast((nonce >> 24) & 0xFF);

        return header;
    }
};

test "worker stats" {
    var stats = WorkerStats.init();
    stats.recordHash();
    stats.recordHash();
    stats.recordShare();

    try std.testing.expectEqual(@as(u64, 2), stats.hashes.load(.monotonic));
    try std.testing.expectEqual(@as(u32, 1), stats.shares_found.load(.monotonic));
}
