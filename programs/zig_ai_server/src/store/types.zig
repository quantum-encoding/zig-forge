// Store types — fixed-size structs for accounts, keys, billing
// No heap allocations in hot path. All sizes bounded at compile time.

const std = @import("std");

// ── Account ─────────────────────────────────────────────────

pub const Role = enum(u8) {
    user = 0,
    admin = 1,
    service = 2,

    pub fn toString(self: Role) []const u8 {
        return switch (self) {
            .user => "user",
            .admin => "admin",
            .service => "service",
        };
    }
};

pub const DevTier = enum(u8) {
    free = 0,
    hobby = 1,
    pro = 2,
    enterprise = 3,

    pub fn toString(self: DevTier) []const u8 {
        return switch (self) {
            .free => "free",
            .hobby => "hobby",
            .pro => "pro",
            .enterprise => "enterprise",
        };
    }

    /// Margin multiplier in basis points (1/10000)
    /// e.g., 2500 = 25% markup
    pub fn marginBps(self: DevTier) u32 {
        return switch (self) {
            .free => 3000, // 30%
            .hobby => 2000, // 20%
            .pro => 1000, // 10%
            .enterprise => 500, // 5%
        };
    }
};

pub const Account = struct {
    id: FixedStr32 = .{},
    email: FixedStr256 = .{},
    balance_ticks: i64 = 0,
    role: Role = .user,
    tier: DevTier = .free,
    created_at: i64 = 0,
    updated_at: i64 = 0,
};

// ── API Key ─────────────────────────────────────────────────

pub const KeyScope = struct {
    /// Bitmask of allowed endpoint groups
    /// Bit 0: chat, Bit 1: images, Bit 2: audio, Bit 3: video,
    /// Bit 4: search, Bit 5: agent, Bit 6: embeddings, Bit 7: models
    /// 0 = all endpoints allowed
    endpoints: u64 = 0,
    /// Per-key spend cap in ticks (0 = unlimited)
    spend_cap_ticks: i64 = 0,
    /// Requests per minute (0 = no limit)
    rate_limit_rpm: u32 = 0,
};

pub const ApiKey = struct {
    key_hash: [32]u8 = .{0} ** 32,
    account_id: FixedStr32 = .{},
    name: FixedStr128 = .{},
    prefix: FixedStr16 = .{}, // "qai_k_" + first 8 hex
    scope: KeyScope = .{},
    spent_ticks: i64 = 0,
    revoked: bool = false,
    created_at: i64 = 0,
    expires_at: i64 = 0, // 0 = never
    last_used_at: i64 = 0,
};

// ── Billing ─────────────────────────────────────────────────

pub const Reservation = struct {
    id: u64 = 0,
    account_id: FixedStr32 = .{},
    key_hash: [32]u8 = .{0} ** 32,
    amount_ticks: i64 = 0,
    endpoint: FixedStr64 = .{},
    model: FixedStr128 = .{},
    created_at: i64 = 0,
};

pub const LedgerEntry = struct {
    seq: u64 = 0,
    account_id: FixedStr32 = .{},
    key_prefix: FixedStr16 = .{},
    amount_ticks: i64 = 0, // negative = debit
    margin_ticks: i64 = 0,
    balance_after: i64 = 0,
    endpoint: FixedStr64 = .{},
    model: FixedStr128 = .{},
    input_tokens: u32 = 0,
    output_tokens: u32 = 0,
    latency_ms: u32 = 0,
    timestamp: i64 = 0,
};

// ── WAL Operations ──────────────────────────────────────────

pub const WalOp = enum(u8) {
    create_account = 0x01,
    update_balance = 0x02,
    create_key = 0x03,
    revoke_key = 0x04,
    reserve = 0x05,
    commit_reservation = 0x06,
    rollback_reservation = 0x07,
    update_key_spend = 0x08,
    update_account = 0x09,
};

// ── Fixed-size string types ─────────────────────────────────
// Avoids heap allocation for small strings stored in structs.

pub fn FixedString(comptime max_len: usize) type {
    return struct {
        buf: [max_len]u8 = .{0} ** max_len,
        len: u16 = 0,

        const Self = @This();

        pub fn fromSlice(s: []const u8) Self {
            var result = Self{};
            const copy_len = @min(s.len, max_len);
            @memcpy(result.buf[0..copy_len], s[0..copy_len]);
            result.len = @intCast(copy_len);
            return result;
        }

        pub fn slice(self: *const Self) []const u8 {
            return self.buf[0..self.len];
        }

        pub fn eql(self: *const Self, other: []const u8) bool {
            return std.mem.eql(u8, self.slice(), other);
        }
    };
}

pub const FixedStr16 = FixedString(16);
pub const FixedStr32 = FixedString(32);
pub const FixedStr64 = FixedString(64);
pub const FixedStr128 = FixedString(128);
pub const FixedStr256 = FixedString(256);

// ── Auth Context (returned from auth pipeline) ──────────────

pub const AuthContext = struct {
    account: *Account,
    key: *ApiKey,
    key_hash: [32]u8,
};
