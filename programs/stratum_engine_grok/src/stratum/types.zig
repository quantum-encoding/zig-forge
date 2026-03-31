const std = @import("std");

pub const Job = struct {
    id: []const u8,
    prevhash: [32]u8,
    coinbase1: []const u8,
    coinbase2: []const u8,
    merkle_branches: std.ArrayList([32]u8),
    version: u32,
    nbits: u32,
    ntime: u32,
    clean_jobs: bool,

    pub fn deinit(self: *Job, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.coinbase1);
        allocator.free(self.coinbase2);
        self.merkle_branches.deinit(allocator);
    }
};

pub const Share = struct {
    job_id: []const u8,
    extranonce2: [8]u8,
    ntime: u32,
    nonce: u32,

    pub fn deinit(self: *Share, allocator: std.mem.Allocator) void {
        allocator.free(self.job_id);
    }
};