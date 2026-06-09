// Account / credits / admin read endpoints — store- and static-backed.
//
//   GET /qai/v1/credits/balance   live account balance (auth)
//   GET /qai/v1/credits/packs     purchasable credit-pack catalog (public)
//   GET /qai/v1/credits/tiers     developer-tier catalog (public)
//   GET /admin/system/health      store + backend health (admin)
//
// These are the read endpoints that the Zig gateway can serve from its own
// in-memory store + static catalogs. The richer history endpoints
// (account/usage → per-user Firestore ledger, usage/summary + stats/* +
// admin/analytics/* → BigQuery) read from data stores the Zig server doesn't
// maintain locally and remain stubs (see FEATURE_PARITY.md).
//
// `admin/users` reuses keys.handleListAccounts (same store iteration as
// admin/accounts), wired directly in the router.

const std = @import("std");
const http = std.http;
const router = @import("router.zig");
const store_mod = @import("store/store.zig");
const types = @import("store/types.zig");
const gcp = @import("gcp.zig");
const Response = router.Response;

const TICKS_PER_USD: i64 = 10_000_000_000;

// ── GET /qai/v1/credits/balance ──────────────────────────────────────

pub fn handleCreditsBalance(
    allocator: std.mem.Allocator,
    store: *store_mod.Store,
    auth: *const types.AuthContext,
) Response {
    // Live balance from the store (auth.account is a snapshot at auth time).
    const balance = if (store.getAccountLocked(auth.account.id.slice())) |a| a.balance_ticks else auth.account.balance_ticks;

    const out = std.json.Stringify.valueAlloc(allocator, .{
        .balance_ticks = balance,
        .balance_usd = @as(f64, @floatFromInt(balance)) / @as(f64, TICKS_PER_USD),
        // pending_ticks: per-user reservation aggregation isn't tracked at the
        // account level (reservations are keyed by id) — placeholder 0, same
        // as the Go gateway.
        .pending_ticks = @as(i64, 0),
    }, .{}) catch {
        return errResp(.internal_server_error);
    };
    return .{ .body = out };
}

// ── GET /qai/v1/credits/packs ────────────────────────────────────────

const CreditPack = struct {
    id: []const u8,
    label: []const u8,
    amount_usd: i64,
    ticks: i64,
    popular: bool = false,
};

/// Static credit-pack catalog — mirrors the Go gateway's `creditPacks`. The
/// Stripe checkout itself isn't wired here (payments are a deferred category),
/// but the catalog the client renders is identical so a UI can list packs.
pub fn handleCreditsPacks(allocator: std.mem.Allocator) Response {
    const packs = [_]CreditPack{
        .{ .id = "pack_5", .label = "£5 Starter", .amount_usd = 5, .ticks = 5 * TICKS_PER_USD },
        .{ .id = "pack_10", .label = "£10 Creator", .amount_usd = 10, .ticks = 10 * TICKS_PER_USD },
        .{ .id = "pack_25", .label = "£25 Builder", .amount_usd = 25, .ticks = 25 * TICKS_PER_USD, .popular = true },
        .{ .id = "pack_50", .label = "£50 Pro", .amount_usd = 50, .ticks = 50 * TICKS_PER_USD },
        .{ .id = "pack_100", .label = "£100 Team", .amount_usd = 100, .ticks = 100 * TICKS_PER_USD },
    };
    const out = std.json.Stringify.valueAlloc(allocator, .{ .packs = packs }, .{}) catch {
        return errResp(.internal_server_error);
    };
    return .{ .body = out };
}

// ── GET /qai/v1/credits/tiers ────────────────────────────────────────

const TierInfo = struct {
    id: []const u8,
    name: []const u8,
    margin_bps: u32,
    /// Display convenience: cost multiplier above provider price.
    margin_multiplier: f64,
};

/// Developer-tier catalog, built from the in-tree DevTier margin table
/// (types.DevTier.marginBps). Mirrors the Go gateway's `billing.AllTiers`.
pub fn handleDevTiers(allocator: std.mem.Allocator) Response {
    const tiers = blk: {
        const all = [_]types.DevTier{ .free, .hobby, .pro, .enterprise };
        var arr: [4]TierInfo = undefined;
        for (all, 0..) |t, i| {
            const bps = t.marginBps();
            arr[i] = .{
                .id = t.toString(),
                .name = t.toString(),
                .margin_bps = bps,
                .margin_multiplier = (10000.0 + @as(f64, @floatFromInt(bps))) / 10000.0,
            };
        }
        break :blk arr;
    };
    const out = std.json.Stringify.valueAlloc(allocator, .{ .tiers = tiers }, .{}) catch {
        return errResp(.internal_server_error);
    };
    return .{ .body = out };
}

// ── GET /admin/system/health ─────────────────────────────────────────

pub fn handleAdminSystemHealth(
    allocator: std.mem.Allocator,
    store: *store_mod.Store,
    auth: *const types.AuthContext,
    gcp_ctx: ?*gcp.GcpContext,
) Response {
    if (auth.account.role != .admin) {
        return .{ .status = .forbidden, .body =
            \\{"error":"forbidden","message":"Admin role required"}
        };
    }

    store.mutex.lock();
    const account_count = store.accounts.count();
    const key_count = store.keys.count();
    const reservation_count = store.reservations.count();
    store.mutex.unlock();

    const out = std.json.Stringify.valueAlloc(allocator, .{
        .status = "ok",
        .services = .{
            .store = .{
                .status = "ok",
                .accounts = account_count,
                .keys = key_count,
                .active_reservations = reservation_count,
            },
            .firestore = .{
                .status = if (gcp_ctx != null) "ok" else "unavailable",
                .available = gcp_ctx != null,
            },
        },
    }, .{}) catch {
        return errResp(.internal_server_error);
    };
    return .{ .body = out };
}

fn errResp(status: http.Status) Response {
    return .{ .status = status, .body = "{\"error\":\"internal\",\"message\":\"request failed\"}" };
}
