//! Stratum Protocol Types
//! Based on Stratum V1 specification

const std = @import("std");

/// Mining job received from pool
pub const Job = struct {
    /// Job ID from pool
    job_id: []const u8,

    /// Previous block hash (32 bytes hex)
    prevhash: [32]u8,

    /// Coinbase part 1 (before extranonce)
    coinb1: []const u8,

    /// Coinbase part 2 (after extranonce)
    coinb2: []const u8,

    /// Merkle branches for building merkle root
    merkle_branch: []const []const u8,

    /// Block version
    version: u32,

    /// Network difficulty bits
    nbits: u32,

    /// Network time
    ntime: u32,

    /// Should miner clear current work?
    clean_jobs: bool,

    allocator: std.mem.Allocator,

    pub fn deinit(self: *Job) void {
        self.allocator.free(self.job_id);
        self.allocator.free(self.coinb1);
        self.allocator.free(self.coinb2);
        for (self.merkle_branch) |branch| {
            self.allocator.free(branch);
        }
        self.allocator.free(self.merkle_branch);
    }
};

/// Share submission to pool
pub const Share = struct {
    /// Worker name
    worker_name: []const u8,

    /// Job ID
    job_id: []const u8,

    /// Extranonce2 (hex string)
    extranonce2: []const u8,

    /// Network time
    ntime: u32,

    /// Nonce that produced valid hash
    nonce: u32,
};

/// Stratum method types
pub const Method = enum {
    mining_subscribe,
    mining_authorize,
    mining_set_difficulty,
    mining_notify,
    mining_submit,
    mining_set_extranonce,
    client_reconnect,
    client_get_version,
    unknown,

    pub fn fromString(s: []const u8) Method {
        if (std.mem.eql(u8, s, "mining.subscribe")) return .mining_subscribe;
        if (std.mem.eql(u8, s, "mining.authorize")) return .mining_authorize;
        if (std.mem.eql(u8, s, "mining.set_difficulty")) return .mining_set_difficulty;
        if (std.mem.eql(u8, s, "mining.notify")) return .mining_notify;
        if (std.mem.eql(u8, s, "mining.submit")) return .mining_submit;
        if (std.mem.eql(u8, s, "mining.set_extranonce")) return .mining_set_extranonce;
        if (std.mem.eql(u8, s, "client.reconnect")) return .client_reconnect;
        if (std.mem.eql(u8, s, "client.get_version")) return .client_get_version;
        return .unknown;
    }
};

/// Connection credentials
pub const Credentials = struct {
    /// Mining pool URL (e.g., "stratum+tcp://pool.example.com:3333")
    url: []const u8,

    /// Worker username (usually wallet.workername)
    username: []const u8,

    /// Worker password (often just "x")
    password: []const u8,
};

/// Mining difficulty target
pub const Target = struct {
    /// 256-bit difficulty target (big-endian)
    bits: [32]u8,

    /// Parse from nbits compact representation
    pub fn fromNBits(nbits: u32) Target {
        var target = Target{ .bits = [_]u8{0} ** 32 };

        const exponent: u8 = @intCast((nbits >> 24) & 0xFF);
        const mantissa: u32 = nbits & 0x00FFFFFF;

        // Bitcoin uses big-endian for difficulty target
        if (exponent <= 3) {
            const shift = @as(u5, @intCast(3 - exponent));
            const value = mantissa >> shift;
            target.bits[29] = @intCast((value >> 16) & 0xFF);
            target.bits[30] = @intCast((value >> 8) & 0xFF);
            target.bits[31] = @intCast(value & 0xFF);
        } else {
            const offset = 32 - exponent;
            target.bits[offset] = @intCast((mantissa >> 16) & 0xFF);
            target.bits[offset + 1] = @intCast((mantissa >> 8) & 0xFF);
            target.bits[offset + 2] = @intCast(mantissa & 0xFF);
        }

        return target;
    }

    /// Check if hash meets this target
    pub fn meetsTarget(self: *const Target, hash: *const [32]u8) bool {
        // Compare hash against target (both big-endian)
        var i: usize = 0;
        while (i < 32) : (i += 1) {
            if (hash[i] < self.bits[i]) return true;
            if (hash[i] > self.bits[i]) return false;
        }
        return true; // Equal counts as meeting target
    }
};
