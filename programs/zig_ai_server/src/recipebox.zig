// Kitchen Share (recipe-box app) gateway routes.
//
//   GET /qai/v1/kitchenshare/packs               purchasable catalog (static)
//   GET /qai/v1/kitchenshare/payment-success     Stripe redirect landing page
//   GET /qai/v1/kitchenshare/payment-cancelled   Stripe redirect landing page
//
// Only the static/stateless routes are ported. The stateful Kitchen Share
// surface (checkout, access-state trial computation, reviewer trial gates,
// purchase-history, IAP verify) reads/writes the Go backend's `users`
// collection + per-user subcollections keyed by the Firebase uid — a
// DIFFERENT identity space than the gateway's `zig_accounts` (qai account id).
// Porting those needs an identity-reconciliation decision (see
// FEATURE_PARITY.md §6), so they are intentionally not wired here.
//
// Catalog values mirror routes_recipebox.go exactly.

const std = @import("std");
const http = std.http;
const gcp = @import("gcp.zig");
const json_util = @import("json.zig");
const types = @import("store/types.zig");
const stripe = @import("stripe.zig");
const store_mod = @import("store/store.zig");
const ledger_mod = @import("ledger.zig");
const router = @import("router.zig");
const Response = router.Response;

const TICKS_PER_USD: i64 = 10_000_000_000;
const TRIAL_DAYS: i64 = 10; // rbTrialDays
const MS_PER_DAY: i64 = 86_400_000;

const Pack = struct {
    id: []const u8,
    label: []const u8,
    amount_gbp: f64,
    ticks: i64,
};

const PACKS = [_]Pack{
    .{ .id = "pack_5", .label = "£5 Top-up", .amount_gbp = 5, .ticks = 5 * TICKS_PER_USD },
    .{ .id = "pack_10", .label = "£10 Top-up", .amount_gbp = 10, .ticks = 10 * TICKS_PER_USD },
    .{ .id = "pack_20", .label = "£20 Top-up", .amount_gbp = 20, .ticks = 20 * TICKS_PER_USD },
};

/// GET /qai/v1/kitchenshare/packs
pub fn handlePacks(allocator: std.mem.Allocator) Response {
    const out = std.json.Stringify.valueAlloc(allocator, .{
        .packs = PACKS,
        .custom = .{
            .min_usd_cents = @as(i64, 500),
            .max_usd_cents = @as(i64, 2500),
            .default_usd_cents = @as(i64, 500),
        },
        .app_unlock = .{
            .id = "app_unlock",
            .label = "Kitchen Share — Lifetime Unlock",
            .amount_gbp = 4.99,
            .description = "Lifetime unlock after the free trial. One-time, no subscription.",
        },
    }, .{}) catch return .{ .status = .internal_server_error, .body = "{\"error\":\"internal\"}" };
    return .{ .body = out };
}

// ── GET /qai/v1/kitchenshare/access-state ────────────────────────────
//
// 10-day free trial, computed over a Zig-OWNED collection keyed by the qai
// account id (`kitchenshare_state/{account_id}`) — the replacement server owns
// its own trial state in its own identity space rather than dual-writing the
// Go backend's `users` collection. First call stamps the trial start; later
// calls compute days-remaining. Mirrors routes_recipebox.go's logic
// (rbTrialDays = 10) over the gateway's own store.

pub fn handleAccessState(
    allocator: std.mem.Allocator,
    io: std.Io,
    gcp_ctx: ?*gcp.GcpContext,
    auth: *const types.AuthContext,
) Response {
    const ctx = gcp_ctx orelse return .{ .status = .service_unavailable, .body = "{\"error\":\"unavailable\",\"message\":\"storage backend not available\"}" };

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const url = std.fmt.allocPrint(a, "https://firestore.googleapis.com/v1/projects/{s}/databases/(default)/documents/kitchenshare_state/{s}", .{ ctx.project_id, auth.account.id.slice() }) catch
        return errPage();

    // Read existing trial start (stored as integerValue epoch-ms).
    var trial_started_ms: i64 = 0;
    var unlocked = false;
    {
        var resp = ctx.get(url) catch return errPage();
        defer resp.deinit();
        if (resp.status == .ok) {
            const Doc = struct {
                fields: ?struct {
                    recipebox_trial_started_at_ms: ?struct { integerValue: []const u8 = "" } = null,
                    recipebox_unlocked: ?struct { booleanValue: bool = false } = null,
                } = null,
            };
            if (std.json.parseFromSliceLeaky(Doc, a, resp.body, .{ .ignore_unknown_fields = true, .allocate = .alloc_always })) |doc| {
                if (doc.fields) |f| {
                    if (f.recipebox_trial_started_at_ms) |t| trial_started_ms = std.fmt.parseInt(i64, t.integerValue, 10) catch 0;
                    if (f.recipebox_unlocked) |u| unlocked = u.booleanValue;
                }
            } else |_| {}
        }
    }

    const now = types.nowMs(io);
    // First call → stamp the trial start.
    if (trial_started_ms == 0) {
        trial_started_ms = now;
        const stamp = buildStamp(a, now, auth.account.id.slice()) catch return errPage();
        var presp = ctx.patchFresh(url, stamp) catch return errPage();
        presp.deinit();
    }

    const expires_ms = trial_started_ms + TRIAL_DAYS * MS_PER_DAY;
    const trial_active = now < expires_ms;
    var days_remaining: i64 = 0;
    if (trial_active) {
        days_remaining = @divTrunc(expires_ms - now, MS_PER_DAY) + 1;
        if (days_remaining > TRIAL_DAYS) days_remaining = TRIAL_DAYS;
    }
    const has_access = unlocked or trial_active;

    const out = std.json.Stringify.valueAlloc(allocator, .{
        .trial_days_remaining = days_remaining,
        .trial_active = trial_active,
        .trial_started_at_ms = trial_started_ms,
        .unlocked = unlocked,
        .has_access = has_access,
    }, .{}) catch return errPage();
    return .{ .status = .ok, .body = out };
}

// ── reviewer fast-forward endpoints (option-C state in kitchenshare_state) ──
//
// Mirror the Go reviewer flow: fast-forward a reviewer's own trial to the
// paywall, or grant trial credits — without waiting the real 10 days. Writes
// the gateway-owned `kitchenshare_state/{account_id}` doc.

/// POST /qai/v1/kitchenshare/reviewer/expire-trial — stamp trial start 30 days
/// in the past so the next access-state read shows the trial expired.
pub fn handleExpireTrial(allocator: std.mem.Allocator, io: std.Io, gcp_ctx: ?*gcp.GcpContext, auth: *const types.AuthContext) Response {
    const ctx = gcp_ctx orelse return jsonErr(.service_unavailable);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const url = std.fmt.allocPrint(a, "https://firestore.googleapis.com/v1/projects/{s}/databases/(default)/documents/kitchenshare_state/{s}", .{ ctx.project_id, auth.account.id.slice() }) catch return jsonErr(.internal_server_error);
    const thirty_days_ago = types.nowMs(io) - 30 * MS_PER_DAY;
    const stamp = buildStamp(a, thirty_days_ago, auth.account.id.slice()) catch return jsonErr(.internal_server_error);
    var resp = ctx.patchFresh(url, stamp) catch return jsonErr(.bad_gateway);
    defer resp.deinit();
    if (@intFromEnum(resp.status) >= 300) return jsonErr(.bad_gateway);
    return .{ .body = "{\"status\":\"trial_expired\"}" };
}

/// POST /qai/v1/kitchenshare/reviewer/grant-trial-credits — credit the
/// reviewer's account a small trial amount.
pub fn handleGrantTrialCredits(allocator: std.mem.Allocator, io: std.Io, store: ?*store_mod.Store, ledger: ?*ledger_mod.Ledger, auth: *const types.AuthContext) Response {
    const s = store orelse return jsonErr(.service_unavailable);
    const grant_ticks: i64 = 5 * TICKS_PER_USD; // $5 trial credit
    s.creditAccount(io, auth.account.id.slice(), grant_ticks) catch return jsonErr(.internal_server_error);
    var balance_after: i64 = 0;
    if (s.getAccountLocked(auth.account.id.slice())) |acct| balance_after = acct.balance_ticks;
    if (ledger) |l| l.recordCredit(io, auth.account.id.slice(), grant_ticks, balance_after, "reviewer_grant");

    const out = std.json.Stringify.valueAlloc(allocator, .{
        .status = "granted",
        .granted_ticks = grant_ticks,
        .balance_after = balance_after,
    }, .{}) catch return jsonErr(.internal_server_error);
    return .{ .body = out };
}

fn jsonErr(status: http.Status) Response {
    return switch (status) {
        .service_unavailable => .{ .status = .service_unavailable, .body = "{\"error\":\"unavailable\"}" },
        .bad_gateway => .{ .status = .bad_gateway, .body = "{\"error\":\"storage_error\"}" },
        else => .{ .status = .internal_server_error, .body = "{\"error\":\"internal\"}" },
    };
}

/// Build the Firestore stamp document for the trial start. Values escaped via
/// Stringify (no hand-formatted JSON / JSON-IN-FMT).
fn buildStamp(a: std.mem.Allocator, now_ms: i64, user_id: []const u8) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(a);
    var jw: std.json.Stringify = .{ .writer = &aw.writer, .options = .{} };
    try jw.beginObject();
    try jw.objectField("fields");
    try jw.beginObject();
    try jw.objectField("recipebox_trial_started_at_ms");
    try jw.beginObject();
    try jw.objectField("integerValue");
    var buf: [24]u8 = undefined;
    try jw.write(try std.fmt.bufPrint(&buf, "{d}", .{now_ms}));
    try jw.endObject();
    try jw.objectField("user_id");
    try jw.beginObject();
    try jw.objectField("stringValue");
    try jw.write(user_id);
    try jw.endObject();
    try jw.endObject();
    try jw.endObject();
    return aw.toOwnedSlice();
}

fn errPage() Response {
    return .{ .status = .internal_server_error, .body = "{\"error\":\"internal\",\"message\":\"access-state failed\"}" };
}

const CheckoutRequest = struct {
    pack_id: []const u8 = "",
    custom_usd_cents: ?i64 = null,
    success_url: ?[]const u8 = null,
    cancel_url: ?[]const u8 = null,
};

/// POST /qai/v1/kitchenshare/checkout — Stripe Checkout for a top-up pack,
/// a custom amount ($5–$25), or the lifetime app unlock.
pub fn handleCheckout(
    request: *http.Server.Request,
    allocator: std.mem.Allocator,
    environ_map: *const std.process.Environ.Map,
    auth: *const types.AuthContext,
) Response {
    const body = json_util.readBody(request, allocator, 64 * 1024) catch
        return .{ .status = .bad_request, .body = "{\"error\":\"invalid_request\"}" };
    defer allocator.free(body);
    const parsed = std.json.parseFromSlice(CheckoutRequest, allocator, body, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch
        return .{ .status = .bad_request, .body = "{\"error\":\"invalid_request\",\"message\":\"invalid JSON body\"}" };
    defer parsed.deinit();
    const req = parsed.value;

    var cents: i64 = 0;
    var ticks: i64 = 0;
    var label: []const u8 = "";
    if (std.mem.eql(u8, req.pack_id, "pack_custom")) {
        const c = req.custom_usd_cents orelse return badReq("custom_usd_cents required");
        if (c < 500 or c > 2500) return badReq("custom_usd_cents must be 500–2500");
        cents = c;
        ticks = @divTrunc(c, 100) * TICKS_PER_USD; // $1 = 1 USD of ticks
        label = "Kitchen Share — Custom Top-up";
    } else if (std.mem.eql(u8, req.pack_id, "app_unlock")) {
        cents = 499;
        ticks = 0; // entitlement, not credits
        label = "Kitchen Share — Lifetime Unlock";
    } else {
        const pack: Pack = blk: {
            for (PACKS) |p| if (std.mem.eql(u8, p.id, req.pack_id)) break :blk p;
            return badReq("unknown pack");
        };
        cents = @intFromFloat(@round(pack.amount_gbp * 100.0));
        ticks = pack.ticks;
        label = pack.label;
    }

    return stripe.checkout(allocator, environ_map, .{
        .currency = "gbp",
        .amount_cents = cents,
        .product_label = label,
        .success_url = req.success_url orelse "https://kitchenshare.quantumencoding.io/payment-success",
        .cancel_url = req.cancel_url orelse "https://kitchenshare.quantumencoding.io/payment-cancelled",
        .account_id = auth.account.id.slice(),
        .account_email = auth.account.email.slice(),
        .ticks = ticks,
        .pack_id = req.pack_id,
    });
}

fn badReq(msg: []const u8) Response {
    _ = msg;
    return .{ .status = .bad_request, .body = "{\"error\":\"invalid_request\",\"message\":\"checkout request rejected\"}" };
}

const html_headers: [1]http.Header = .{.{ .name = "content-type", .value = "text/html; charset=utf-8" }};

/// GET /qai/v1/kitchenshare/payment-{success,cancelled}
pub fn paymentPage(success: bool) Response {
    const body = if (success)
        "<!doctype html><meta name=viewport content=\"width=device-width,initial-scale=1\"><title>Payment complete</title><body style=\"font-family:system-ui;text-align:center;padding:3rem\"><h1>Thank you</h1><p>Your purchase is complete. You can return to Kitchen Share.</p></body>"
    else
        "<!doctype html><meta name=viewport content=\"width=device-width,initial-scale=1\"><title>Payment cancelled</title><body style=\"font-family:system-ui;text-align:center;padding:3rem\"><h1>Payment cancelled</h1><p>No charge was made.</p></body>";
    return .{ .status = .ok, .body = body, .headers = &html_headers };
}
