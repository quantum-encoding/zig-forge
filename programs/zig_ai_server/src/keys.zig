// Key Management — POST/GET/DELETE /qai/v1/keys
// Admin-only endpoints for API key lifecycle.
// Raw key is shown exactly once on creation, then only the hash is stored.

const std = @import("std");
const http = std.http;
const Io = std.Io;
const store_mod = @import("store/store.zig");
const types = @import("store/types.zig");
const auth_pipeline = @import("auth_pipeline.zig");
const json_util = @import("json.zig");
const ledger_mod = @import("ledger.zig");
const router = @import("router.zig");
const Response = router.Response;

// ── Request types ───────────────────────────────────────────

const CreateKeyRequest = struct {
    name: []const u8 = "default",
    account_id: ?[]const u8 = null, // if null, uses the admin's own account
    spend_cap_ticks: ?i64 = null,
    rate_limit_rpm: ?u32 = null,
    endpoints: ?u64 = null,
    expires_in_hours: ?i64 = null,
};

const CreateAccountRequest = struct {
    id: []const u8,
    email: []const u8 = "",
    role: []const u8 = "user",
    tier: []const u8 = "free",
    initial_credit_ticks: ?i64 = null,
};

const CreditRequest = struct {
    amount_ticks: i64,
};

// ── POST /qai/v1/keys — Create API key ─────────────────────

pub fn handleCreateKey(
    request: *http.Server.Request,
    allocator: std.mem.Allocator,
    io: Io,
    store: *store_mod.Store,
    auth: *const types.AuthContext,
) Response {
    // Admin only
    if (auth.account.role != .admin) {
        return .{ .status = .forbidden, .body =
            \\{"error":"forbidden","message":"Admin role required to create API keys"}
        };
    }

    const parsed = json_util.parseBody(CreateKeyRequest, request, allocator) catch {
        return .{ .status = .bad_request, .body =
            \\{"error":"invalid_json","message":"Failed to parse request body"}
        };
    };
    defer parsed.deinit();
    const req = parsed.value;

    // Target account: specified or admin's own
    const target_account_id = req.account_id orelse auth.account.id.slice();

    // Verify target account exists
    {
        store.mutex.lock();
        defer store.mutex.unlock();
        if (store.accounts.get(target_account_id) == null) {
            return .{ .status = .not_found, .body =
                \\{"error":"not_found","message":"Target account does not exist"}
            };
        }
    }

    // Generate raw key: 32 random bytes → 64 hex chars → prepend "qai_k_"
    var random_bytes: [32]u8 = undefined;
    io.random(&random_bytes);

    var hex_buf: [64]u8 = undefined;
    types.hexEncode(&random_bytes, &hex_buf);

    const raw_key = std.fmt.allocPrint(allocator, "qai_k_{s}", .{&hex_buf}) catch {
        return .{ .status = .internal_server_error, .body =
            \\{"error":"internal","message":"Failed to generate key"}
        };
    };
    defer allocator.free(raw_key);

    // SHA-256 hash for storage
    var key_hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(raw_key, &key_hash, .{});

    // Build prefix for display: "qai_k_" + first 8 hex
    var prefix_buf: [14]u8 = undefined;
    @memcpy(prefix_buf[0..6], "qai_k_");
    @memcpy(prefix_buf[6..14], hex_buf[0..8]);

    const now = types.nowMs();
    const expires_at: i64 = if (req.expires_in_hours) |hours|
        now + hours * 3600 * 1000
    else
        0;

    const key_record = types.ApiKey{
        .key_hash = key_hash,
        .account_id = types.FixedStr32.fromSlice(target_account_id),
        .name = types.FixedStr128.fromSlice(req.name),
        .prefix = types.FixedStr16.fromSlice(&prefix_buf),
        .scope = .{
            .spend_cap_ticks = req.spend_cap_ticks orelse 0,
            .rate_limit_rpm = req.rate_limit_rpm orelse 0,
            .endpoints = req.endpoints orelse 0,
        },
        .created_at = now,
        .expires_at = expires_at,
    };

    store.createKey(io, key_record) catch {
        return .{ .status = .internal_server_error, .body =
            \\{"error":"internal","message":"Failed to persist key"}
        };
    };

    // Return the raw key — shown exactly once
    const response = std.fmt.allocPrint(allocator,
        \\{{"key":"{s}","prefix":"{s}","name":"{s}","account_id":"{s}","created_at":{d},"expires_at":{d}}}
    , .{
        raw_key,
        prefix_buf[0..14],
        req.name,
        target_account_id,
        now,
        expires_at,
    }) catch {
        return .{ .status = .internal_server_error, .body =
            \\{"error":"internal","message":"Key created but failed to format response"}
        };
    };

    return .{ .body = response };
}

// ── GET /qai/v1/keys — List keys ───────────────────────────

pub fn handleListKeys(
    _: *http.Server.Request,
    allocator: std.mem.Allocator,
    store: *store_mod.Store,
    auth: *const types.AuthContext,
) Response {
    if (auth.account.role != .admin) {
        return .{ .status = .forbidden, .body =
            \\{"error":"forbidden","message":"Admin role required"}
        };
    }

    store.mutex.lock();
    defer store.mutex.unlock();

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);

    buf.appendSlice(allocator, "{\"keys\":[") catch return .{ .status = .internal_server_error, .body = "{}" };

    var first = true;
    var iter = store.keys.iterator();
    while (iter.next()) |entry| {
        const key = entry.value_ptr;
        if (!first) buf.append(allocator, ',') catch continue;
        first = false;

        const json = std.fmt.allocPrint(allocator,
            \\{{"prefix":"{s}","name":"{s}","account_id":"{s}","spent_ticks":{d},"revoked":{s},"created_at":{d},"expires_at":{d},"spend_cap_ticks":{d},"rate_limit_rpm":{d}}}
        , .{
            key.prefix.slice(),
            key.name.slice(),
            key.account_id.slice(),
            key.spent_ticks,
            if (key.revoked) "true" else "false",
            key.created_at,
            key.expires_at,
            key.scope.spend_cap_ticks,
            key.scope.rate_limit_rpm,
        }) catch continue;
        defer allocator.free(json);
        buf.appendSlice(allocator, json) catch continue;
    }

    buf.appendSlice(allocator, "]}") catch {};
    const result = buf.toOwnedSlice(allocator) catch return .{ .status = .internal_server_error, .body = "{}" };
    return .{ .body = result };
}

// ── DELETE /qai/v1/keys/{prefix} — Revoke key ──────────────

pub fn handleRevokeKey(
    _: *http.Server.Request,
    allocator: std.mem.Allocator,
    io: Io,
    store: *store_mod.Store,
    auth: *const types.AuthContext,
    prefix: []const u8,
) Response {
    if (auth.account.role != .admin) {
        return .{ .status = .forbidden, .body =
            \\{"error":"forbidden","message":"Admin role required"}
        };
    }

    // Find key by prefix
    store.mutex.lock();
    var found_hash: ?[32]u8 = null;
    var key_iter = store.keys.iterator();
    while (key_iter.next()) |entry| {
        if (std.mem.eql(u8, entry.value_ptr.prefix.slice(), prefix)) {
            found_hash = entry.key_ptr.*;
            break;
        }
    }
    store.mutex.unlock();

    if (found_hash) |hash| {
        store.revokeKey(io, hash) catch {};
        return .{ .body = std.fmt.allocPrint(allocator,
            \\{{"status":"revoked","prefix":"{s}"}}
        , .{prefix}) catch
            \\{"status":"revoked"}
        };
    }

    return .{ .status = .not_found, .body =
        \\{"error":"not_found","message":"No key found with that prefix"}
    };
}

// ── POST /qai/v1/admin/accounts — Create account ───────────

pub fn handleCreateAccount(
    request: *http.Server.Request,
    allocator: std.mem.Allocator,
    io: Io,
    store: *store_mod.Store,
    auth: *const types.AuthContext,
) Response {
    if (auth.account.role != .admin) {
        return .{ .status = .forbidden, .body =
            \\{"error":"forbidden","message":"Admin role required"}
        };
    }

    const parsed = json_util.parseBody(CreateAccountRequest, request, allocator) catch {
        return .{ .status = .bad_request, .body =
            \\{"error":"invalid_json","message":"Failed to parse. Required: id, optional: email, role, tier, initial_credit_ticks"}
        };
    };
    defer parsed.deinit();
    const req = parsed.value;

    if (req.id.len == 0 or req.id.len > 32) {
        return .{ .status = .bad_request, .body =
            \\{"error":"invalid_request","message":"Account ID must be 1-32 characters"}
        };
    }

    const role = std.meta.stringToEnum(types.Role, req.role) orelse .user;
    const tier = std.meta.stringToEnum(types.DevTier, req.tier) orelse .free;
    const now = types.nowMs();

    const account = types.Account{
        .id = types.FixedStr32.fromSlice(req.id),
        .email = types.FixedStr256.fromSlice(req.email),
        .balance_ticks = req.initial_credit_ticks orelse 0,
        .role = role,
        .tier = tier,
        .created_at = now,
        .updated_at = now,
    };

    store.createAccount(io, account) catch {
        return .{ .status = .internal_server_error, .body =
            \\{"error":"internal","message":"Failed to create account"}
        };
    };

    return .{ .body = std.fmt.allocPrint(allocator,
        \\{{"status":"created","account_id":"{s}","role":"{s}","tier":"{s}","balance_ticks":{d}}}
    , .{ req.id, role.toString(), tier.toString(), account.balance_ticks }) catch
        \\{"status":"created"}
    };
}

// ── POST /qai/v1/admin/accounts/{id}/credit — Add credit ───

pub fn handleCreditAccount(
    request: *http.Server.Request,
    allocator: std.mem.Allocator,
    io: Io,
    store: *store_mod.Store,
    auth: *const types.AuthContext,
    account_id: []const u8,
    ledger: ?*ledger_mod.Ledger,
) Response {
    if (auth.account.role != .admin) {
        return .{ .status = .forbidden, .body =
            \\{"error":"forbidden","message":"Admin role required"}
        };
    }

    const parsed = json_util.parseBody(CreditRequest, request, allocator) catch {
        return .{ .status = .bad_request, .body =
            \\{"error":"invalid_json","message":"Required: amount_ticks (positive integer)"}
        };
    };
    defer parsed.deinit();

    if (parsed.value.amount_ticks <= 0) {
        return .{ .status = .bad_request, .body =
            \\{"error":"invalid_request","message":"amount_ticks must be positive"}
        };
    }

    store.creditAccount(io, account_id, parsed.value.amount_ticks) catch |err| {
        return switch (err) {
            error.AccountNotFound => .{ .status = .not_found, .body =
                \\{"error":"not_found","message":"Account not found"}
            },
            else => .{ .status = .internal_server_error, .body =
                \\{"error":"internal","message":"Failed to credit account"}
            },
        };
    };

    // Read updated balance and log to ledger
    const balance = if (store.getAccountLocked(account_id)) |acct| acct.balance_ticks else 0;
    if (ledger) |l| {
        l.recordCredit(io, account_id, parsed.value.amount_ticks, balance, auth.key.prefix.slice());
    }

    return .{ .body = std.fmt.allocPrint(allocator,
        \\{{"status":"credited","account_id":"{s}","amount_ticks":{d},"balance_after":{d}}}
    , .{ account_id, parsed.value.amount_ticks, balance }) catch
        \\{"status":"credited"}
    };
}

// ── GET /qai/v1/admin/accounts — List all accounts ─────────

pub fn handleListAccounts(
    _: *http.Server.Request,
    allocator: std.mem.Allocator,
    store: *store_mod.Store,
    auth: *const types.AuthContext,
) Response {
    if (auth.account.role != .admin) {
        return .{ .status = .forbidden, .body =
            \\{"error":"forbidden","message":"Admin role required"}
        };
    }

    store.mutex.lock();
    defer store.mutex.unlock();

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);

    buf.appendSlice(allocator, "{\"accounts\":[") catch return .{ .status = .internal_server_error, .body = "{}" };

    var first = true;
    var iter = store.accounts.iterator();
    while (iter.next()) |entry| {
        const acct = entry.value_ptr;
        if (!first) buf.append(allocator, ',') catch continue;
        first = false;

        const json = std.fmt.allocPrint(allocator,
            \\{{"id":"{s}","email":"{s}","balance_ticks":{d},"role":"{s}","tier":"{s}","frozen":{s},"created_at":{d}}}
        , .{
            acct.id.slice(), acct.email.slice(), acct.balance_ticks,
            acct.role.toString(), acct.tier.toString(),
            if (acct.frozen) "true" else "false", acct.created_at,
        }) catch continue;
        defer allocator.free(json);
        buf.appendSlice(allocator, json) catch continue;
    }

    buf.appendSlice(allocator, "]}") catch {};
    return .{ .body = buf.toOwnedSlice(allocator) catch "{}" };
}

// ── GET /qai/v1/admin/accounts/{id} — Get single account ───

pub fn handleGetAccount(
    _: *http.Server.Request,
    allocator: std.mem.Allocator,
    store: *store_mod.Store,
    auth: *const types.AuthContext,
    account_id: []const u8,
) Response {
    if (auth.account.role != .admin) {
        return .{ .status = .forbidden, .body =
            \\{"error":"forbidden","message":"Admin role required"}
        };
    }

    const acct = store.getAccountLocked(account_id) orelse {
        return .{ .status = .not_found, .body =
            \\{"error":"not_found","message":"Account not found"}
        };
    };

    // Count keys for this account
    var key_count: u32 = 0;
    var total_spent: i64 = 0;
    store.mutex.lock();
    var key_iter = store.keys.iterator();
    while (key_iter.next()) |entry| {
        if (entry.value_ptr.account_id.eql(account_id)) {
            key_count += 1;
            total_spent += entry.value_ptr.spent_ticks;
        }
    }
    store.mutex.unlock();

    return .{ .body = std.fmt.allocPrint(allocator,
        \\{{"id":"{s}","email":"{s}","balance_ticks":{d},"role":"{s}","tier":"{s}","frozen":{s},"created_at":{d},"key_count":{d},"total_spent_ticks":{d}}}
    , .{
        acct.id.slice(), acct.email.slice(), acct.balance_ticks,
        acct.role.toString(), acct.tier.toString(),
        if (acct.frozen) "true" else "false", acct.created_at,
        key_count, total_spent,
    }) catch
        \\{"error":"internal"}
    };
}

// ── POST /qai/v1/admin/accounts/{id}/freeze — Freeze/unfreeze ──

const FreezeRequest = struct {
    frozen: bool,
    reason: ?[]const u8 = null,
};

pub fn handleFreezeAccount(
    request: *http.Server.Request,
    allocator: std.mem.Allocator,
    store: *store_mod.Store,
    auth: *const types.AuthContext,
    account_id: []const u8,
) Response {
    if (auth.account.role != .admin) {
        return .{ .status = .forbidden, .body =
            \\{"error":"forbidden","message":"Admin role required"}
        };
    }

    const parsed = json_util.parseBody(FreezeRequest, request, allocator) catch {
        return .{ .status = .bad_request, .body =
            \\{"error":"invalid_json","message":"Required: frozen (bool)"}
        };
    };
    defer parsed.deinit();

    store.mutex.lock();
    const acct = store.accounts.getPtr(account_id) orelse {
        store.mutex.unlock();
        return .{ .status = .not_found, .body =
            \\{"error":"not_found","message":"Account not found"}
        };
    };
    acct.frozen = parsed.value.frozen;
    acct.updated_at = types.nowMs();
    store.dirty_accounts.put(store.allocator, account_id, {}) catch {};
    store.mutex.unlock();

    return .{ .body = std.fmt.allocPrint(allocator,
        \\{{"status":"updated","account_id":"{s}","frozen":{s}}}
    , .{ account_id, if (parsed.value.frozen) "true" else "false" }) catch
        \\{"status":"updated"}
    };
}

// ── POST /qai/v1/admin/accounts/{id}/tier — Change tier ────

const TierRequest = struct {
    tier: []const u8,
};

pub fn handleSetTier(
    request: *http.Server.Request,
    allocator: std.mem.Allocator,
    store: *store_mod.Store,
    auth: *const types.AuthContext,
    account_id: []const u8,
) Response {
    if (auth.account.role != .admin) {
        return .{ .status = .forbidden, .body =
            \\{"error":"forbidden","message":"Admin role required"}
        };
    }

    const parsed = json_util.parseBody(TierRequest, request, allocator) catch {
        return .{ .status = .bad_request, .body =
            \\{"error":"invalid_json","message":"Required: tier (free|hobby|pro|enterprise)"}
        };
    };
    defer parsed.deinit();

    const new_tier = std.meta.stringToEnum(types.DevTier, parsed.value.tier) orelse {
        return .{ .status = .bad_request, .body =
            \\{"error":"invalid_request","message":"tier must be: free, hobby, pro, or enterprise"}
        };
    };

    store.mutex.lock();
    const acct = store.accounts.getPtr(account_id) orelse {
        store.mutex.unlock();
        return .{ .status = .not_found, .body =
            \\{"error":"not_found","message":"Account not found"}
        };
    };
    acct.tier = new_tier;
    acct.updated_at = types.nowMs();
    store.dirty_accounts.put(store.allocator, account_id, {}) catch {};
    store.mutex.unlock();

    return .{ .body = std.fmt.allocPrint(allocator,
        \\{{"status":"updated","account_id":"{s}","tier":"{s}","margin_bps":{d}}}
    , .{ account_id, new_tier.toString(), new_tier.marginBps() }) catch
        \\{"status":"updated"}
    };
}
