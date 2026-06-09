// Credit spend-hold API — pre-authorize, settle, or cancel credit holds.
//
//   POST /qai/v1/credits/reserve    open a hold       → { token, amount_ticks, ... }
//   POST /qai/v1/credits/commit     settle to actual  → { token, status, refunded_ticks }
//   POST /qai/v1/credits/rollback   cancel (refund)   → { token, status }
//
// Wire-compatible with the Go gateway's reservation endpoints. Partner apps
// reserve credits up-front, then commit the actual spend (refunding the
// difference) or roll back. Backed by the store's reservation primitives
// (reserve/commitReservation/rollbackReservation); the opaque `token` is the
// reservation id. Ownership is enforced: a caller may only commit/rollback a
// reservation on its own account (admins may act on any).

const std = @import("std");
const http = std.http;
const json_util = @import("json.zig");
const router = @import("router.zig");
const security = @import("security.zig");
const store_mod = @import("store/store.zig");
const types = @import("store/types.zig");
const ledger_mod = @import("ledger.zig");
const Response = router.Response;

const DEFAULT_TTL_S: i64 = 300;
const MAX_TTL_S: i64 = 3600;

// ── POST /qai/v1/credits/reserve ─────────────────────────────────────

const ReserveRequest = struct {
    amount_ticks: i64 = 0,
    ttl_seconds: ?i64 = null,
    request_id: ?[]const u8 = null,
};

pub fn handleReserve(
    request: *http.Server.Request,
    allocator: std.mem.Allocator,
    io: std.Io,
    store: *store_mod.Store,
    auth: *const types.AuthContext,
) Response {
    const body = json_util.readBody(request, allocator, 4096) catch return err(.bad_request, "read body");
    defer allocator.free(body);
    const parsed = std.json.parseFromSlice(ReserveRequest, allocator, body, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch return err(.bad_request, "invalid JSON body");
    defer parsed.deinit();
    const req = parsed.value;
    if (req.amount_ticks <= 0) return err(.bad_request, "amount_ticks must be positive");

    var ttl = req.ttl_seconds orelse DEFAULT_TTL_S;
    if (ttl <= 0) ttl = DEFAULT_TTL_S;
    if (ttl > MAX_TTL_S) ttl = MAX_TTL_S;

    const rid = store.reserve(io, auth.account.id.slice(), auth.key_hash, req.amount_ticks, "/qai/v1/credits/reserve", "reservation") catch |e| switch (e) {
        error.InsufficientBalance => return err(.payment_required, "not enough credits to reserve the requested amount"),
        else => return err(.internal_server_error, "failed to create reservation"),
    };

    const expires_at_ms = types.nowMs(io) + ttl * 1000;
    const out = std.json.Stringify.valueAlloc(allocator, .{
        .token = rid,
        .amount_ticks = req.amount_ticks,
        .expires_at_ms = expires_at_ms,
        .source_app = auth.account.id.slice(),
    }, .{}) catch return err(.internal_server_error, "serialize");
    return .{ .body = out };
}

// ── POST /qai/v1/credits/commit ──────────────────────────────────────

const CommitRequest = struct {
    token: []const u8 = "",
    actual_ticks: i64 = -1,
};

pub fn handleCommit(
    request: *http.Server.Request,
    allocator: std.mem.Allocator,
    io: std.Io,
    store: *store_mod.Store,
    auth: *const types.AuthContext,
) Response {
    const body = json_util.readBody(request, allocator, 4096) catch return err(.bad_request, "read body");
    defer allocator.free(body);
    const parsed = std.json.parseFromSlice(CommitRequest, allocator, body, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch return err(.bad_request, "invalid JSON body");
    defer parsed.deinit();
    const req = parsed.value;
    if (req.token.len == 0) return err(.bad_request, "token required");
    if (req.actual_ticks < 0) return err(.bad_request, "actual_ticks must be non-negative");

    const rid = std.fmt.parseInt(u64, req.token, 10) catch return err(.bad_request, "invalid token");

    const reservation = store.getReservation(rid) orelse return err(.not_found, "reservation not found");
    if (!ownsReservation(auth, reservation)) return err(.forbidden, "reservation owned by a different principal");
    if (req.actual_ticks > reservation.amount_ticks) {
        return err(.bad_request, "actual_ticks exceeds the held amount — rollback and re-reserve");
    }

    store.commitReservation(io, rid, req.actual_ticks, 0) catch return err(.internal_server_error, "failed to commit reservation");

    const refunded = reservation.amount_ticks - req.actual_ticks;
    const out = std.json.Stringify.valueAlloc(allocator, .{
        .token = rid,
        .status = "committed",
        .amount_ticks = reservation.amount_ticks,
        .committed_actual_ticks = req.actual_ticks,
        .refunded_ticks = refunded,
    }, .{}) catch return err(.internal_server_error, "serialize");
    return .{ .body = out };
}

// ── POST /qai/v1/credits/rollback ────────────────────────────────────

const RollbackRequest = struct { token: []const u8 = "" };

pub fn handleRollback(
    request: *http.Server.Request,
    allocator: std.mem.Allocator,
    io: std.Io,
    store: *store_mod.Store,
    auth: *const types.AuthContext,
) Response {
    const body = json_util.readBody(request, allocator, 4096) catch return err(.bad_request, "read body");
    defer allocator.free(body);
    const parsed = std.json.parseFromSlice(RollbackRequest, allocator, body, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch return err(.bad_request, "invalid JSON body");
    defer parsed.deinit();
    if (parsed.value.token.len == 0) return err(.bad_request, "token required");

    const rid = std.fmt.parseInt(u64, parsed.value.token, 10) catch return err(.bad_request, "invalid token");

    // Idempotent: an unknown / already-settled token is treated as rolled back.
    if (store.getReservation(rid)) |reservation| {
        if (!ownsReservation(auth, reservation)) return err(.forbidden, "reservation owned by a different principal");
        store.rollbackReservation(io, rid);
    }

    const out = std.json.Stringify.valueAlloc(allocator, .{
        .token = rid,
        .status = "rolled_back",
    }, .{}) catch return err(.internal_server_error, "serialize");
    return .{ .body = out };
}

fn ownsReservation(auth: *const types.AuthContext, reservation: types.Reservation) bool {
    if (auth.account.role == .admin) return true;
    return std.mem.eql(u8, reservation.account_id.slice(), auth.account.id.slice());
}

fn err(status: http.Status, message: []const u8) Response {
    _ = message;
    return switch (status) {
        .bad_request => .{ .status = .bad_request, .body = "{\"error\":\"invalid_request\",\"message\":\"reservation request rejected\"}" },
        .payment_required => .{ .status = .payment_required, .body = "{\"error\":\"insufficient_balance\",\"message\":\"not enough credits to reserve\"}" },
        .not_found => .{ .status = .not_found, .body = "{\"error\":\"not_found\",\"message\":\"reservation not found\"}" },
        .forbidden => .{ .status = .forbidden, .body = "{\"error\":\"forbidden\",\"message\":\"reservation owned by a different principal\"}" },
        else => .{ .status = .internal_server_error, .body = "{\"error\":\"internal\",\"message\":\"reservation request failed\"}" },
    };
}
