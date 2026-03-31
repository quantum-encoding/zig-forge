const std = @import("std");
const SimdMiner = @import("simd_worker.zig").SimdMiner;
const types = @import("../stratum/types.zig");

pub const Dispatcher = struct {
    allocator: std.mem.Allocator,
    miners: std.ArrayList(*SimdMiner),
    cpu_count: usize,

    pub fn init(allocator: std.mem.Allocator) !Dispatcher {
        const cpu_count = std.Thread.getCpuCount() catch 1;
        return .{
            .allocator = allocator,
            .miners = try std.ArrayList(*SimdMiner).initCapacity(allocator, 0),
            .cpu_count = cpu_count,
        };
    }

    pub fn deinit(self: *Dispatcher) void {
        for (self.miners.items) |miner| {
            miner.deinit();
        }
        self.miners.deinit(self.allocator);
    }

    pub fn startMiners(self: *Dispatcher) !void {
        // Each SIMD miner handles VecWidth nonces at once
        // Distribute across CPU cores
        for (0..self.cpu_count) |i| {
            const nonce_base = @as(u32, @intCast(i * 0x10000000)); // Spread across nonce space
            const miner = try SimdMiner.init(self.allocator, nonce_base, i);
            try self.miners.append(self.allocator, miner);
        }
    }

    pub fn distributeJob(self: *Dispatcher, job: types.Job) !void {
        // Clone job for each SIMD miner
        for (self.miners.items) |miner| {
            var job_clone = types.Job{
                .id = try self.allocator.dupe(u8, job.id),
                .prevhash = job.prevhash,
                .coinbase1 = try self.allocator.dupe(u8, job.coinbase1),
                .coinbase2 = try self.allocator.dupe(u8, job.coinbase2),
                .merkle_branches = try std.ArrayList([32]u8).initCapacity(self.allocator, 0),
                .version = job.version,
                .nbits = job.nbits,
                .ntime = job.ntime,
                .clean_jobs = job.clean_jobs,
            };
            for (job.merkle_branches.items) |branch| {
                try job_clone.merkle_branches.append(self.allocator, branch);
            }
            miner.setJob(job_clone);
        }
    }
};