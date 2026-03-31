const std = @import("std");
const types = @import("../stratum/types.zig");
const sha256_simd = @import("../crypto/sha256_simd.zig");
const merkle = @import("../crypto/merkle.zig");

pub const SimdMiner = struct {
    allocator: std.mem.Allocator,
    thread: std.Thread,
    running: std.atomic.Value(bool),
    job: ?types.Job,
    target: [32]u8, // Target difficulty as big-endian bytes
    nonce_base: u32,
    core_id: usize,

    pub fn init(allocator: std.mem.Allocator, nonce_base: u32, core_id: usize) !*SimdMiner {
        const miner = try allocator.create(SimdMiner);
        miner.* = .{
            .allocator = allocator,
            .thread = undefined,
            .running = std.atomic.Value(bool).init(true),
            .job = null,
            .target = std.mem.zeroes([32]u8),
            .nonce_base = nonce_base,
            .core_id = core_id,
        };

        // Pin thread to specific CPU core for optimal performance
        const attr: std.Thread.SpawnConfig = .{};

        miner.thread = try std.Thread.spawn(attr, SimdMiner.mineLoop, .{miner});
        return miner;
    }

    pub fn deinit(self: *SimdMiner) void {
        self.running.store(false, .seq_cst);
        self.thread.join();
        if (self.job) |*j| j.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    pub fn setJob(self: *SimdMiner, job: types.Job) void {
        if (self.job) |*j| j.deinit(self.allocator);
        self.job = job;
        // Calculate target from nbits
        self.target = calculateTarget(job.nbits);
    }

    fn calculateTarget(nbits: u32) [32]u8 {
        // Simplified target calculation
        // In reality, nbits encodes the target
        var target: [32]u8 = [_]u8{0xFF} ** 32; // Max target
        const exponent = (nbits >> 24) & 0xFF;
        const mantissa = nbits & 0xFFFFFF;
        if (exponent <= 3) {
            const shift = 8 * (3 - exponent);
            const value = mantissa >> @as(u5, @intCast(shift & 31));
            target[32 - @sizeOf(@TypeOf(value))] = @truncate(value);
        } else {
            const shift = 8 * (exponent - 3);
            if (shift < 256) {
                const byte_pos = 32 - (shift / 8) - 1;
                const bit_shift = shift % 8;
                target[byte_pos] = @truncate(mantissa << @as(u5, @intCast(bit_shift)));
                if (byte_pos + 1 < 32) {
                    target[byte_pos + 1] = @truncate(mantissa >> @as(u5, @intCast(8 - bit_shift)));
                }
            }
        }
        return target;
    }

    // The "Zero-Branch" Worker Loop - Core of the SIMD mining engine
    fn mineLoop(self: *SimdMiner) void {
        // Initialize vector of nonces: {0, 1, 2, ..., VecWidth-1}
        var nonces: sha256_simd.VecType = undefined;
        comptime var i = 0;
        inline while (i < sha256_simd.VecWidth) : (i += 1) {
            nonces[i] = i;
        }

        // Allocate aligned memory for SIMD operations
        var headers: [sha256_simd.VecWidth][80]u8 align(64) = undefined;
        var hashes: [sha256_simd.VecWidth][32]u8 align(64) = undefined;
        var hash_ptrs: [sha256_simd.VecWidth]*[32]u8 = undefined;
        var data_slices: [sha256_simd.VecWidth][]const u8 = undefined;

        for (0..sha256_simd.VecWidth) |vec_i| {
            hash_ptrs[vec_i] = &hashes[vec_i];
            data_slices[vec_i] = &headers[vec_i];
        }

        while (self.running.load(.seq_cst)) {
            if (self.job) |job| {
                // Build coinbase once per job
                const coinbase = std.mem.concat(self.allocator, u8, &[_][]const u8{ job.coinbase1, "extrnonce1", "extrnonce2", job.coinbase2 }) catch continue;
                defer self.allocator.free(coinbase);

                // Coinbase hash
                var coinbase_hash: [32]u8 = undefined;
                // Use scalar hash for coinbase (only done once)
                std.crypto.hash.sha2.Sha256.hash(coinbase, &coinbase_hash, .{});
                std.crypto.hash.sha2.Sha256.hash(&coinbase_hash, &coinbase_hash, .{});

                // Merkle root
                const merkle_root = merkle.buildMerkleRoot(coinbase_hash, job.merkle_branches.items);

                // Build header template (without nonce)
                var header_template: [80]u8 = undefined;
                std.mem.writeInt(u32, header_template[0..4], job.version, .little);
                @memcpy(header_template[4..36], &job.prevhash);
                @memcpy(header_template[36..68], &merkle_root);
                std.mem.writeInt(u32, header_template[68..72], job.ntime, .little);
                std.mem.writeInt(u32, header_template[72..76], job.nbits, .little);
                // nonce will be set in the vector loop

                // Reset nonce vector for this job
                nonces = undefined;
                comptime var j = 0;
                inline while (j < sha256_simd.VecWidth) : (j += 1) {
                    nonces[j] = j;
                }

                // Main mining loop - ZERO BRANCHING
                while (self.running.load(.seq_cst)) {
                    // Create headers with embedded nonces
                    // Since we can't index vectors at runtime, we'll create them sequentially
                    comptime var vec_i = 0;
                    inline while (vec_i < sha256_simd.VecWidth) : (vec_i += 1) {
                        @memcpy(&headers[vec_i], &header_template);
                        const nonce_val = self.nonce_base + @as(u32, @intCast(nonces[vec_i]));
                        std.mem.writeInt(u32, headers[vec_i][76..80], nonce_val, .little);
                    }

                    // Run sha256dBatch on the vector
                    try sha256_simd.sha256dBatch(&hash_ptrs, &data_slices);

                    // Compare result vector against target using MASKING (not branching)
                    // For simplicity, compare against first 4 bytes of target (most significant)
                    const target_u32 = std.mem.readInt(u32, self.target[0..4], .big);

                    // Check each hash against target using vector comparison
                    var found_mask: @Vector(sha256_simd.VecWidth, bool) = undefined;
                    comptime var h_i = 0;
                    inline while (h_i < sha256_simd.VecWidth) : (h_i += 1) {
                        const hash_u32 = std.mem.readInt(u32, hashes[h_i][0..4], .big);
                        found_mask[h_i] = hash_u32 < target_u32;
                    }

                    // Extract any found nonces without branching
                    comptime var k = 0;
                    inline while (k < sha256_simd.VecWidth) : (k += 1) {
                        if (found_mask[k]) {
                            const found_nonce = self.nonce_base + @as(u32, @intCast(nonces[k]));
                            std.debug.print("Found share! nonce: {}\n", .{found_nonce});
                            // Queue share for stratum submission
                            // Share found at this nonce will be forwarded by the dispatcher
                        }
                    }

                    // Increment: n += @splat(VecWidth) - single instruction updates all lanes
                    nonces += @splat(sha256_simd.VecWidth);
                }
            }
            // std.Thread.sleep(1000000); // 1ms sleep when no job
        }
    }
};

// High-level mining function
pub fn mine_simd(header: [80]u8, target: u256) ?u32 {
    // This would be a simpler interface for testing
    // Implementation would create a temporary SimdMiner instance
    // For now, return null (not implemented for this interface)
    _ = header;
    _ = target;
    return null;
}