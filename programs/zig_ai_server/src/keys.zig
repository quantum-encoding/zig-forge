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
// JSON payloads are produced via std.json.Stringify.valueAlloc on
// anonymous structs — never via std.fmt.allocPrint + "{s}" interpolation.
// String escaping and UTF-8 correctness are owned by std.json, not by
// hand-rolled escape helpers. See Batch 9 in the audit log.
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

    const now = types.nowMs(io);
    const expires_at: i64 = if (req.expires_in_hours) |hours|
        now + hours * 3600 * 1000
    else
        0;

    const key_record = types.ApiKey{
        .key_hash = key_hash,
        .account_id = types.FixedStr64.fromSlice(target_account_id),
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

    // Return the raw key — shown exactly once. The whole payload goes
    // through std.json.Stringify in buildCreateKeyResponse; every string
    // field is escaped by the standard library, not by hand.
    const response = buildCreateKeyResponse(
        allocator,
        raw_key,
        prefix_buf[0..14],
        req.name,
        target_account_id,
        now,
        expires_at,
    ) catch {
        return .{ .status = .internal_server_error, .body =
            \\{"error":"internal","message":"Key created but failed to format response"}
        };
    };

    return .{ .body = response };
}

fn buildCreateKeyResponse(
    allocator: std.mem.Allocator,
    raw_key: []const u8,
    prefix: []const u8,
    name: []const u8,
    account_id: []const u8,
    created_at: i64,
    expires_at: i64,
) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, .{
        .key = raw_key,
        .prefix = prefix,
        .name = name,
        .account_id = account_id,
        .created_at = created_at,
        .expires_at = expires_at,
    }, .{});
}

/// Append a single key entry as a JSON object to `buf`. The whole record
/// goes through std.json.Stringify on an anonymous struct — there is no
/// hand-rolled escaping; the standard library owns string safety.
fn appendKeyJson(
    allocator: std.mem.Allocator,
    buf: *std.ArrayListUnmanaged(u8),
    key: *const types.ApiKey,
) !void {
    const owned = try std.json.Stringify.valueAlloc(allocator, .{
        .prefix = key.prefix.slice(),
        .name = key.name.slice(),
        .account_id = key.account_id.slice(),
        .spent_ticks = key.spent_ticks,
        .revoked = key.revoked,
        .created_at = key.created_at,
        .expires_at = key.expires_at,
        .spend_cap_ticks = key.scope.spend_cap_ticks,
        .rate_limit_rpm = key.scope.rate_limit_rpm,
    }, .{});
    defer allocator.free(owned);
    try buf.appendSlice(allocator, owned);
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

        // SECURITY (AIS-8): key.name was user-controlled at creation time
        // and is the primary injection vector here. Escape every string
        // field even when the source looks server-derived — defense in
        // depth against upstream validation regressions.
        appendKeyJson(allocator, &buf, key) catch continue;
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
        // `prefix` comes from the URL path — user-controlled. std.json
        // owns the escaping in buildRevokedResponse.
        const response = buildRevokedResponse(allocator, prefix) catch
            \\{"status":"revoked"}
        ;
        return .{ .body = response };
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
    const now = types.nowMs(io);

    const account = types.Account{
        .id = types.FixedStr64.fromSlice(req.id),
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

    // req.id was user-supplied; std.json.Stringify in
    // buildCreateAccountResponse handles all string escaping.
    const response = buildCreateAccountResponse(
        allocator,
        req.id,
        role.toString(),
        tier.toString(),
        account.balance_ticks,
    ) catch
        \\{"status":"created"}
    ;
    return .{ .body = response };
}

fn buildCreateAccountResponse(
    allocator: std.mem.Allocator,
    account_id: []const u8,
    role_str: []const u8,
    tier_str: []const u8,
    balance_ticks: i64,
) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, .{
        .status = "created",
        .account_id = account_id,
        .role = role_str,
        .tier = tier_str,
        .balance_ticks = balance_ticks,
    }, .{});
}

// ── Shared JSON builders ───────────────────────────────────
//
// All responses below use std.json.Stringify.valueAlloc on anonymous
// structs. String escaping and UTF-8 correctness are handled by the
// standard library; we never concatenate JSON byte strings by hand.

/// `{"status":"revoked","prefix":<prefix>}` — revoke confirmation.
/// The original helper took dynamic `(status, key, value)` triples but
/// only the revoke endpoint ever called it; with a fixed shape the
/// schema is type-checked at compile time.
fn buildRevokedResponse(
    allocator: std.mem.Allocator,
    prefix: []const u8,
) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, .{
        .status = "revoked",
        .prefix = prefix,
    }, .{});
}

/// `{"status":"credited","account_id":<id>,"amount_ticks":N,"balance_after":N}`
fn buildCreditedResponse(
    allocator: std.mem.Allocator,
    account_id: []const u8,
    amount_ticks: i64,
    balance_after: i64,
) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, .{
        .status = "credited",
        .account_id = account_id,
        .amount_ticks = amount_ticks,
        .balance_after = balance_after,
    }, .{});
}

/// Append an account-record JSON object to `buf`. The "with-key-counts"
/// shape (handleGetAccount) and the "list" shape (handleListAccounts)
/// share the leading fields; the optional tail is omitted via std.json's
/// `emit_null_optional_fields = false` so the wire format stays identical
/// to the prior hand-rolled serializer.
fn appendAccountJson(
    allocator: std.mem.Allocator,
    buf: *std.ArrayListUnmanaged(u8),
    id: []const u8,
    email: []const u8,
    balance_ticks: i64,
    role_str: []const u8,
    tier_str: []const u8,
    frozen: bool,
    created_at: i64,
    key_count: ?u32,
    total_spent_ticks: ?i64,
) !void {
    const owned = try std.json.Stringify.valueAlloc(allocator, .{
        .id = id,
        .email = email,
        .balance_ticks = balance_ticks,
        .role = role_str,
        .tier = tier_str,
        .frozen = frozen,
        .created_at = created_at,
        .key_count = key_count,
        .total_spent_ticks = total_spent_ticks,
    }, .{ .emit_null_optional_fields = false });
    defer allocator.free(owned);
    try buf.appendSlice(allocator, owned);
}

/// `{"status":"updated","account_id":<id>,"frozen":<bool>}`
fn buildFrozenResponse(
    allocator: std.mem.Allocator,
    account_id: []const u8,
    frozen: bool,
) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, .{
        .status = "updated",
        .account_id = account_id,
        .frozen = frozen,
    }, .{});
}

/// `{"status":"updated","account_id":<id>,"tier":<tier>,"margin_bps":N}`
fn buildTierResponse(
    allocator: std.mem.Allocator,
    account_id: []const u8,
    tier_str: []const u8,
    margin_bps: i64,
) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, .{
        .status = "updated",
        .account_id = account_id,
        .tier = tier_str,
        .margin_bps = margin_bps,
    }, .{});
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

    // SECURITY (AIS-8): account_id comes from the URL path.
    const response = buildCreditedResponse(allocator, account_id, parsed.value.amount_ticks, balance) catch
        \\{"status":"credited"}
    ;
    return .{ .body = response };
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

        // SECURITY (AIS-8): id and email were user-supplied at account
        // creation; escape every string field.
        appendAccountJson(
            allocator,
            &buf,
            acct.id.slice(),
            acct.email.slice(),
            acct.balance_ticks,
            acct.role.toString(),
            acct.tier.toString(),
            acct.frozen,
            acct.created_at,
            null, // no key_count in list shape
            null,
        ) catch continue;
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

    // SECURITY (AIS-8): id and email are user-supplied strings.
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);
    appendAccountJson(
        allocator,
        &buf,
        acct.id.slice(),
        acct.email.slice(),
        acct.balance_ticks,
        acct.role.toString(),
        acct.tier.toString(),
        acct.frozen,
        acct.created_at,
        key_count,
        total_spent,
    ) catch return .{ .status = .internal_server_error, .body =
        \\{"error":"internal"}
    };
    return .{ .body = buf.toOwnedSlice(allocator) catch
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
    io: Io,
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
    acct.updated_at = types.nowMs(io);
    store.dirty_accounts.put(store.allocator, account_id, {}) catch {};
    store.mutex.unlock();

    // SECURITY (AIS-8): account_id from URL path.
    const response = buildFrozenResponse(allocator, account_id, parsed.value.frozen) catch
        \\{"status":"updated"}
    ;
    return .{ .body = response };
}

// ── POST /qai/v1/admin/accounts/{id}/tier — Change tier ────

const TierRequest = struct {
    tier: []const u8,
};

pub fn handleSetTier(
    request: *http.Server.Request,
    allocator: std.mem.Allocator,
    io: Io,
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
    acct.updated_at = types.nowMs(io);
    store.dirty_accounts.put(store.allocator, account_id, {}) catch {};
    store.mutex.unlock();

    // SECURITY (AIS-8): account_id from URL path; tier_str is enum-derived.
    const response = buildTierResponse(allocator, account_id, new_tier.toString(), new_tier.marginBps()) catch
        \\{"status":"updated"}
    ;
    return .{ .body = response };
}
