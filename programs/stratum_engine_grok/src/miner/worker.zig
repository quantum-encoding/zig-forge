const std = @import("std");
const types = @import("../stratum/types.zig");
const sha256d = @import("../crypto/sha256d.zig");
const merkle = @import("../crypto/merkle.zig");

pub const Worker = struct {
    allocator: std.mem.Allocator,
    thread: std.Thread,
    running: std.atomic.Value(bool),
    job: ?types.Job,
    target: [32]u8, // Target difficulty as big-endian bytes
    nonce_start: u32,
    nonce_end: u32,

    pub fn init(allocator: std.mem.Allocator, nonce_range: struct { start: u32, end: u32 }) !*Worker {
        const worker = try allocator.create(Worker);
        worker.* = .{
            .allocator = allocator,
            .thread = undefined,
            .running = std.atomic.Value(bool).init(true),
            .job = null,
            .target = std.mem.zeroes([32]u8),
            .nonce_start = nonce_range.start,
            .nonce_end = nonce_range.end,
        };
        worker.thread = try std.Thread.spawn(.{}, Worker.run, .{worker});
        return worker;
    }

    pub fn deinit(self: *Worker) void {
        self.running.store(false, .seq_cst);
        self.thread.join();
        if (self.job) |*j| j.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    pub fn setJob(self: *Worker, job: types.Job) void {
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

    fn run(self: *Worker) void {
        while (self.running.load(.seq_cst)) {
            if (self.job) |job| {
                // Build coinbase
                const coinbase = std.mem.concat(self.allocator, u8, &[_][]const u8{ job.coinbase1, "extrnonce1", "extrnonce2", job.coinbase2 }) catch continue;
                defer self.allocator.free(coinbase);

                // Coinbase hash
                var coinbase_hash: [32]u8 = undefined;
                sha256d.sha256d(&coinbase_hash, coinbase);

                // Merkle root
                const merkle_root = merkle.buildMerkleRoot(coinbase_hash, job.merkle_branches.items);

                // Build header template
                var header: [80]u8 = undefined;
                std.mem.writeInt(u32, header[0..4], job.version, .little);
                @memcpy(header[4..36], &job.prevhash);
                @memcpy(header[36..68], &merkle_root);
                std.mem.writeInt(u32, header[68..72], job.ntime, .little);
                std.mem.writeInt(u32, header[72..76], job.nbits, .little);
                // nonce at 76..80

                for (self.nonce_start..self.nonce_end) |nonce| {
                    std.mem.writeInt(u32, header[76..80], @as(u32, @intCast(nonce)), .little);
                    var hash: [32]u8 = undefined;
                    sha256d.sha256d(&hash, &header);

                    // Check if hash < target (big-endian comparison)
                    if (std.mem.order(u8, &hash, &self.target) == .lt) {
                        // Found share!
                        // Queue share for stratum submission via dispatcher
                        std.debug.print("Found share! nonce: {}\n", .{nonce});
                    }
                }
            }
            // std.time.sleep(1000000); // 1ms
        }
    }
};