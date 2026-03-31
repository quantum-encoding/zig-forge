//! SQLite Storage Layer
//!
//! Persists:
//! - Share history (accepted, rejected, stale)
//! - Miner sessions and uptime
//! - Earnings tracking (per miner, per pool)
//! - Pool configurations
//! - Alert history
//!
//! Uses SQLite3 via C FFI for maximum compatibility.

const std = @import("std");
const server = @import("../proxy/server.zig");
const miner_registry = @import("../proxy/miner_registry.zig");

// SQLite3 C bindings
const c = @cImport({
    @cInclude("sqlite3.h");
});

pub const StorageError = error{
    OpenFailed,
    InitFailed,
    QueryFailed,
    BindFailed,
    StepFailed,
    NotFound,
};

/// Share record for persistence
pub const ShareRecord = struct {
    id: i64,
    timestamp: i64,
    miner_id: u64,
    miner_name: []const u8,
    pool_id: []const u8,
    job_id: []const u8,
    status: server.ShareEvent.ShareStatus,
    difficulty: f64,
    latency_ms: u32,
    reason: ?[]const u8,
};

/// Miner session record
pub const MinerSession = struct {
    id: i64,
    miner_id: u64,
    worker_name: []const u8,
    ip_address: []const u8,
    connected_at: i64,
    disconnected_at: ?i64,
    shares_accepted: u64,
    shares_rejected: u64,
    shares_stale: u64,
    avg_hashrate_th: f64,
};

/// Earnings record
pub const EarningsRecord = struct {
    date: i64, // Unix timestamp at midnight
    miner_id: u64,
    pool_id: []const u8,
    btc_earned: f64,
    shares_submitted: u64,
    power_cost_gbp: f64,
};

/// Pool configuration record
pub const PoolRecord = struct {
    id: []const u8,
    name: []const u8,
    url: []const u8,
    username: []const u8,
    password: []const u8,
    priority: u8,
    enabled: bool,
    created_at: i64,
};

/// SQLite Database wrapper
pub const Database = struct {
    allocator: std.mem.Allocator,
    db: *c.sqlite3,
    path: []const u8,

    // Prepared statements
    stmt_insert_share: ?*c.sqlite3_stmt,
    stmt_insert_session: ?*c.sqlite3_stmt,
    stmt_update_session: ?*c.sqlite3_stmt,
    stmt_insert_earnings: ?*c.sqlite3_stmt,

    const Self = @This();

    /// Open or create the database
    pub fn init(allocator: std.mem.Allocator, path: []const u8) !Self {
        var db: ?*c.sqlite3 = null;

        // Null-terminate the path for C
        const c_path = try allocator.dupeZ(u8, path);
        defer allocator.free(c_path);

        const result = c.sqlite3_open(c_path.ptr, &db);
        if (result != c.SQLITE_OK or db == null) {
            std.debug.print("❌ Failed to open database: {s}\n", .{
                c.sqlite3_errmsg(db),
            });
            return StorageError.OpenFailed;
        }

        var self = Self{
            .allocator = allocator,
            .db = db.?,
            .path = try allocator.dupe(u8, path),
            .stmt_insert_share = null,
            .stmt_insert_session = null,
            .stmt_update_session = null,
            .stmt_insert_earnings = null,
        };

        // Initialize schema
        try self.initSchema();

        // Prepare common statements
        try self.prepareStatements();

        std.debug.print("✅ Database initialized: {s}\n", .{path});

        return self;
    }

    pub fn deinit(self: *Self) void {
        // Finalize prepared statements
        if (self.stmt_insert_share) |stmt| _ = c.sqlite3_finalize(stmt);
        if (self.stmt_insert_session) |stmt| _ = c.sqlite3_finalize(stmt);
        if (self.stmt_update_session) |stmt| _ = c.sqlite3_finalize(stmt);
        if (self.stmt_insert_earnings) |stmt| _ = c.sqlite3_finalize(stmt);

        _ = c.sqlite3_close(self.db);
        self.allocator.free(self.path);
    }

    /// Initialize database schema
    fn initSchema(self: *Self) !void {
        const schema =
            \\-- Shares table
            \\CREATE TABLE IF NOT EXISTS shares (
            \\    id INTEGER PRIMARY KEY AUTOINCREMENT,
            \\    timestamp INTEGER NOT NULL,
            \\    miner_id INTEGER NOT NULL,
            \\    miner_name TEXT NOT NULL,
            \\    pool_id TEXT NOT NULL,
            \\    job_id TEXT NOT NULL,
            \\    status TEXT NOT NULL,
            \\    difficulty REAL NOT NULL,
            \\    latency_ms INTEGER NOT NULL,
            \\    reason TEXT
            \\);
            \\
            \\-- Index for time-based queries
            \\CREATE INDEX IF NOT EXISTS idx_shares_timestamp ON shares(timestamp);
            \\CREATE INDEX IF NOT EXISTS idx_shares_miner ON shares(miner_id, timestamp);
            \\
            \\-- Miner sessions table
            \\CREATE TABLE IF NOT EXISTS miner_sessions (
            \\    id INTEGER PRIMARY KEY AUTOINCREMENT,
            \\    miner_id INTEGER NOT NULL,
            \\    worker_name TEXT NOT NULL,
            \\    ip_address TEXT,
            \\    connected_at INTEGER NOT NULL,
            \\    disconnected_at INTEGER,
            \\    shares_accepted INTEGER DEFAULT 0,
            \\    shares_rejected INTEGER DEFAULT 0,
            \\    shares_stale INTEGER DEFAULT 0,
            \\    avg_hashrate_th REAL DEFAULT 0
            \\);
            \\
            \\CREATE INDEX IF NOT EXISTS idx_sessions_miner ON miner_sessions(miner_id);
            \\
            \\-- Daily earnings table
            \\CREATE TABLE IF NOT EXISTS earnings (
            \\    id INTEGER PRIMARY KEY AUTOINCREMENT,
            \\    date INTEGER NOT NULL,
            \\    miner_id INTEGER NOT NULL,
            \\    pool_id TEXT NOT NULL,
            \\    btc_earned REAL NOT NULL,
            \\    shares_submitted INTEGER NOT NULL,
            \\    power_cost_gbp REAL DEFAULT 0,
            \\    UNIQUE(date, miner_id, pool_id)
            \\);
            \\
            \\CREATE INDEX IF NOT EXISTS idx_earnings_date ON earnings(date);
            \\
            \\-- Pool configurations table
            \\CREATE TABLE IF NOT EXISTS pools (
            \\    id TEXT PRIMARY KEY,
            \\    name TEXT NOT NULL,
            \\    url TEXT NOT NULL,
            \\    username TEXT NOT NULL,
            \\    password TEXT NOT NULL,
            \\    priority INTEGER DEFAULT 0,
            \\    enabled INTEGER DEFAULT 1,
            \\    created_at INTEGER NOT NULL
            \\);
            \\
            \\-- Alerts table
            \\CREATE TABLE IF NOT EXISTS alerts (
            \\    id INTEGER PRIMARY KEY AUTOINCREMENT,
            \\    timestamp INTEGER NOT NULL,
            \\    severity TEXT NOT NULL,
            \\    miner_id INTEGER,
            \\    message TEXT NOT NULL,
            \\    acknowledged INTEGER DEFAULT 0
            \\);
            \\
            \\CREATE INDEX IF NOT EXISTS idx_alerts_timestamp ON alerts(timestamp);
            \\
            \\-- Settings table (key-value store)
            \\CREATE TABLE IF NOT EXISTS settings (
            \\    key TEXT PRIMARY KEY,
            \\    value TEXT NOT NULL,
            \\    updated_at INTEGER NOT NULL
            \\);
        ;

        try self.exec(schema);
    }

    fn prepareStatements(self: *Self) !void {
        // Insert share
        self.stmt_insert_share = try self.prepare(
            \\INSERT INTO shares (timestamp, miner_id, miner_name, pool_id, job_id, status, difficulty, latency_ms, reason)
            \\VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        );

        // Insert session
        self.stmt_insert_session = try self.prepare(
            \\INSERT INTO miner_sessions (miner_id, worker_name, ip_address, connected_at)
            \\VALUES (?, ?, ?, ?)
        );

        // Update session on disconnect
        self.stmt_update_session = try self.prepare(
            \\UPDATE miner_sessions SET
            \\    disconnected_at = ?,
            \\    shares_accepted = ?,
            \\    shares_rejected = ?,
            \\    shares_stale = ?,
            \\    avg_hashrate_th = ?
            \\WHERE id = ?
        );

        // Insert/update earnings (upsert)
        self.stmt_insert_earnings = try self.prepare(
            \\INSERT INTO earnings (date, miner_id, pool_id, btc_earned, shares_submitted, power_cost_gbp)
            \\VALUES (?, ?, ?, ?, ?, ?)
            \\ON CONFLICT(date, miner_id, pool_id) DO UPDATE SET
            \\    btc_earned = btc_earned + excluded.btc_earned,
            \\    shares_submitted = shares_submitted + excluded.shares_submitted,
            \\    power_cost_gbp = power_cost_gbp + excluded.power_cost_gbp
        );
    }

    // ==================== Share Operations ====================

    /// Log a share submission
    pub fn logShare(self: *Self, event: server.ShareEvent, pool_id: []const u8) !void {
        const stmt = self.stmt_insert_share orelse return StorageError.QueryFailed;

        _ = c.sqlite3_reset(stmt);

        try self.bindInt(stmt, 1, event.timestamp);
        try self.bindInt(stmt, 2, @intCast(event.miner_id));
        try self.bindText(stmt, 3, event.miner_name);
        try self.bindText(stmt, 4, pool_id);
        try self.bindText(stmt, 5, event.job_id);
        try self.bindText(stmt, 6, @tagName(event.status));
        try self.bindDouble(stmt, 7, event.difficulty);
        try self.bindInt(stmt, 8, @intCast(event.latency_ms));

        if (event.reason) |reason| {
            try self.bindText(stmt, 9, reason);
        } else {
            _ = c.sqlite3_bind_null(stmt, 9);
        }

        try self.step(stmt);
    }

    /// Get share count for time range
    pub fn getShareCount(self: *Self, start_time: i64, end_time: i64) !struct { accepted: u64, rejected: u64, stale: u64 } {
        const query =
            \\SELECT status, COUNT(*) FROM shares
            \\WHERE timestamp >= ? AND timestamp < ?
            \\GROUP BY status
        ;

        const stmt = try self.prepare(query);
        defer _ = c.sqlite3_finalize(stmt);

        try self.bindInt(stmt, 1, start_time);
        try self.bindInt(stmt, 2, end_time);

        var result: struct { accepted: u64 = 0, rejected: u64 = 0, stale: u64 = 0 } = .{};

        while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            const status_ptr = c.sqlite3_column_text(stmt, 0);
            const count: u64 = @intCast(c.sqlite3_column_int64(stmt, 1));

            if (status_ptr != null) {
                const status = std.mem.span(status_ptr);
                if (std.mem.eql(u8, status, "accepted")) {
                    result.accepted = count;
                } else if (std.mem.eql(u8, status, "rejected")) {
                    result.rejected = count;
                } else if (std.mem.eql(u8, status, "stale")) {
                    result.stale = count;
                }
            }
        }

        return result;
    }

    // ==================== Session Operations ====================

    /// Start a new miner session
    pub fn startSession(self: *Self, miner_id: u64, worker_name: []const u8, ip_address: []const u8) !i64 {
        const stmt = self.stmt_insert_session orelse return StorageError.QueryFailed;

        _ = c.sqlite3_reset(stmt);

        try self.bindInt(stmt, 1, @intCast(miner_id));
        try self.bindText(stmt, 2, worker_name);
        try self.bindText(stmt, 3, ip_address);
        try self.bindInt(stmt, 4, std.time.timestamp());

        try self.step(stmt);

        return c.sqlite3_last_insert_rowid(self.db);
    }

    /// End a miner session
    pub fn endSession(self: *Self, session_id: i64, shares: struct { accepted: u64, rejected: u64, stale: u64 }, avg_hashrate: f64) !void {
        const stmt = self.stmt_update_session orelse return StorageError.QueryFailed;

        _ = c.sqlite3_reset(stmt);

        try self.bindInt(stmt, 1, std.time.timestamp());
        try self.bindInt(stmt, 2, @intCast(shares.accepted));
        try self.bindInt(stmt, 3, @intCast(shares.rejected));
        try self.bindInt(stmt, 4, @intCast(shares.stale));
        try self.bindDouble(stmt, 5, avg_hashrate);
        try self.bindInt(stmt, 6, session_id);

        try self.step(stmt);
    }

    // ==================== Earnings Operations ====================

    /// Record earnings for a day
    pub fn recordEarnings(self: *Self, date: i64, miner_id: u64, pool_id: []const u8, btc: f64, shares: u64, power_cost: f64) !void {
        const stmt = self.stmt_insert_earnings orelse return StorageError.QueryFailed;

        _ = c.sqlite3_reset(stmt);

        try self.bindInt(stmt, 1, date);
        try self.bindInt(stmt, 2, @intCast(miner_id));
        try self.bindText(stmt, 3, pool_id);
        try self.bindDouble(stmt, 4, btc);
        try self.bindInt(stmt, 5, @intCast(shares));
        try self.bindDouble(stmt, 6, power_cost);

        try self.step(stmt);
    }

    /// Get total earnings for time range
    pub fn getTotalEarnings(self: *Self, start_date: i64, end_date: i64) !f64 {
        const query =
            \\SELECT COALESCE(SUM(btc_earned), 0) FROM earnings
            \\WHERE date >= ? AND date < ?
        ;

        const stmt = try self.prepare(query);
        defer _ = c.sqlite3_finalize(stmt);

        try self.bindInt(stmt, 1, start_date);
        try self.bindInt(stmt, 2, end_date);

        if (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            return c.sqlite3_column_double(stmt, 0);
        }

        return 0;
    }

    // ==================== Pool Operations ====================

    /// Save pool configuration
    pub fn savePool(self: *Self, pool: PoolRecord) !void {
        const query =
            \\INSERT INTO pools (id, name, url, username, password, priority, enabled, created_at)
            \\VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            \\ON CONFLICT(id) DO UPDATE SET
            \\    name = excluded.name,
            \\    url = excluded.url,
            \\    username = excluded.username,
            \\    password = excluded.password,
            \\    priority = excluded.priority,
            \\    enabled = excluded.enabled
        ;

        const stmt = try self.prepare(query);
        defer _ = c.sqlite3_finalize(stmt);

        try self.bindText(stmt, 1, pool.id);
        try self.bindText(stmt, 2, pool.name);
        try self.bindText(stmt, 3, pool.url);
        try self.bindText(stmt, 4, pool.username);
        try self.bindText(stmt, 5, pool.password);
        try self.bindInt(stmt, 6, pool.priority);
        try self.bindInt(stmt, 7, if (pool.enabled) 1 else 0);
        try self.bindInt(stmt, 8, pool.created_at);

        try self.step(stmt);
    }

    /// Load all pool configurations
    pub fn loadPools(self: *Self) ![]PoolRecord {
        const query = "SELECT id, name, url, username, password, priority, enabled, created_at FROM pools ORDER BY priority";

        const stmt = try self.prepare(query);
        defer _ = c.sqlite3_finalize(stmt);

        var pools = try std.ArrayList(PoolRecord).initCapacity(self.allocator, 8);
        errdefer pools.deinit(self.allocator);

        while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            const pool = PoolRecord{
                .id = try self.allocator.dupe(u8, self.columnText(stmt, 0)),
                .name = try self.allocator.dupe(u8, self.columnText(stmt, 1)),
                .url = try self.allocator.dupe(u8, self.columnText(stmt, 2)),
                .username = try self.allocator.dupe(u8, self.columnText(stmt, 3)),
                .password = try self.allocator.dupe(u8, self.columnText(stmt, 4)),
                .priority = @intCast(c.sqlite3_column_int(stmt, 5)),
                .enabled = c.sqlite3_column_int(stmt, 6) != 0,
                .created_at = c.sqlite3_column_int64(stmt, 7),
            };
            try pools.append(self.allocator, pool);
        }

        return try pools.toOwnedSlice(self.allocator);
    }

    // ==================== Settings Operations ====================

    /// Get a setting value
    pub fn getSetting(self: *Self, key: []const u8) !?[]const u8 {
        const query = "SELECT value FROM settings WHERE key = ?";

        const stmt = try self.prepare(query);
        defer _ = c.sqlite3_finalize(stmt);

        try self.bindText(stmt, 1, key);

        if (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            return try self.allocator.dupe(u8, self.columnText(stmt, 0));
        }

        return null;
    }

    /// Set a setting value
    pub fn setSetting(self: *Self, key: []const u8, value: []const u8) !void {
        const query =
            \\INSERT INTO settings (key, value, updated_at)
            \\VALUES (?, ?, ?)
            \\ON CONFLICT(key) DO UPDATE SET value = excluded.value, updated_at = excluded.updated_at
        ;

        const stmt = try self.prepare(query);
        defer _ = c.sqlite3_finalize(stmt);

        try self.bindText(stmt, 1, key);
        try self.bindText(stmt, 2, value);
        try self.bindInt(stmt, 3, std.time.timestamp());

        try self.step(stmt);
    }

    // ==================== Alert Operations ====================

    /// Log an alert
    pub fn logAlert(self: *Self, alert: miner_registry.Alert) !void {
        const query =
            \\INSERT INTO alerts (timestamp, severity, miner_id, message)
            \\VALUES (?, ?, ?, ?)
        ;

        const stmt = try self.prepare(query);
        defer _ = c.sqlite3_finalize(stmt);

        try self.bindInt(stmt, 1, alert.timestamp);
        try self.bindText(stmt, 2, @tagName(alert.severity));

        if (alert.miner_id) |id| {
            try self.bindInt(stmt, 3, @intCast(id));
        } else {
            _ = c.sqlite3_bind_null(stmt, 3);
        }

        try self.bindText(stmt, 4, alert.message);

        try self.step(stmt);
    }

    // ==================== Helper Methods ====================

    fn exec(self: *Self, sql: []const u8) !void {
        const c_sql = try self.allocator.dupeZ(u8, sql);
        defer self.allocator.free(c_sql);

        var err_msg: [*c]u8 = null;
        const result = c.sqlite3_exec(self.db, c_sql.ptr, null, null, &err_msg);

        if (result != c.SQLITE_OK) {
            if (err_msg != null) {
                std.debug.print("❌ SQL error: {s}\n", .{err_msg});
                c.sqlite3_free(err_msg);
            }
            return StorageError.QueryFailed;
        }
    }

    fn prepare(self: *Self, sql: []const u8) !*c.sqlite3_stmt {
        const c_sql = try self.allocator.dupeZ(u8, sql);
        defer self.allocator.free(c_sql);

        var stmt: ?*c.sqlite3_stmt = null;
        const result = c.sqlite3_prepare_v2(self.db, c_sql.ptr, -1, &stmt, null);

        if (result != c.SQLITE_OK or stmt == null) {
            return StorageError.QueryFailed;
        }

        return stmt.?;
    }

    fn step(self: *Self, stmt: *c.sqlite3_stmt) !void {
        _ = self;
        const result = c.sqlite3_step(stmt);
        if (result != c.SQLITE_DONE and result != c.SQLITE_ROW) {
            return StorageError.StepFailed;
        }
    }

    fn bindInt(self: *Self, stmt: *c.sqlite3_stmt, index: c_int, value: i64) !void {
        _ = self;
        if (c.sqlite3_bind_int64(stmt, index, value) != c.SQLITE_OK) {
            return StorageError.BindFailed;
        }
    }

    fn bindDouble(self: *Self, stmt: *c.sqlite3_stmt, index: c_int, value: f64) !void {
        _ = self;
        if (c.sqlite3_bind_double(stmt, index, value) != c.SQLITE_OK) {
            return StorageError.BindFailed;
        }
    }

    fn bindText(self: *Self, stmt: *c.sqlite3_stmt, index: c_int, text: []const u8) !void {
        const c_text = try self.allocator.dupeZ(u8, text);
        // Note: SQLITE_TRANSIENT means SQLite will copy the string
        if (c.sqlite3_bind_text(stmt, index, c_text.ptr, @intCast(text.len), c.SQLITE_TRANSIENT) != c.SQLITE_OK) {
            self.allocator.free(c_text);
            return StorageError.BindFailed;
        }
        self.allocator.free(c_text);
    }

    fn columnText(self: *Self, stmt: *c.sqlite3_stmt, index: c_int) []const u8 {
        _ = self;
        const ptr = c.sqlite3_column_text(stmt, index);
        if (ptr == null) return "";
        return std.mem.span(ptr);
    }
};

// ==================== Tests ====================

test "database schema init" {
    // Just tests compilation - actual DB test would need file system access
    _ = Database;
}
