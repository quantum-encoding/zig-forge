// Quantify (quote-generator app) gateway routes.
//
//   GET /qai/v1/quantify/packs   purchasable pack catalog (public/static)
//
// Only the static catalog is ported here. The rest of the Quantify surface
// (checkout, settings GET/PUT, IAP verify, email send/webhook) operates on
// the Go backend's OWN `users` collection + app-specific subcollections — see
// FEATURE_PARITY.md §6. The Zig gateway owns a separate account model
// (`zig_accounts`); making it a second writer to the Go backend's user
// documents is an architectural decision for the operator, not a mechanical
// port, so those routes are intentionally not wired here.
//
// Catalog values mirror routes_quantify.go / routes_iap.go exactly so a
// client renders identical packs.

const std = @import("std");
const http = std.http;
const json_util = @import("json.zig");
const types = @import("store/types.zig");
const stripe = @import("stripe.zig");
const router = @import("router.zig");
const Response = router.Response;

const TICKS_PER_USD: i64 = 10_000_000_000;

const QuantifyPack = struct {
    id: []const u8,
    label: []const u8,
    amount_gbp: f64,
    credits: i64 = 0,
    ticks: i64 = 0,
    kind: []const u8,
    popular: bool = false,
    description: []const u8,
};

const PACKS = [_]QuantifyPack{
    .{ .id = "unlock", .label = "Quantify — Lifetime Unlock", .amount_gbp = 29.99, .kind = "app_unlock", .description = "Lifetime device unlock — removes the 10-quote free-tier cap. One-time, no subscription." },
    .{ .id = "pack5", .label = "£5 Credit Pack", .amount_gbp = 5, .credits = 2_500, .ticks = 50_000_000_000, .kind = "credit_pack", .description = "2,500 AI credits. Expires 18 months after purchase." },
    .{ .id = "pack10", .label = "£10 Credit Pack", .amount_gbp = 10, .credits = 5_500, .ticks = 110_000_000_000, .kind = "credit_pack", .popular = true, .description = "5,500 AI credits (10% bonus). Expires 18 months after purchase." },
    .{ .id = "pack20", .label = "£20 Credit Pack — Best Value", .amount_gbp = 20, .credits = 12_000, .ticks = 240_000_000_000, .kind = "credit_pack", .description = "12,000 AI credits (20% bonus). Expires 18 months after purchase." },
};

/// GET /qai/v1/quantify/packs
pub fn handlePacks(allocator: std.mem.Allocator) Response {
    const out = std.json.Stringify.valueAlloc(allocator, .{ .packs = PACKS }, .{}) catch
        return .{ .status = .internal_server_error, .body = "{\"error\":\"internal\"}" };
    return .{ .body = out };
}

const CheckoutRequest = struct {
    pack_id: []const u8 = "",
    success_url: ?[]const u8 = null,
    cancel_url: ?[]const u8 = null,
};

/// POST /qai/v1/quantify/checkout — Stripe Checkout for a Quantify pack.
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

    const pack: QuantifyPack = blk: {
        for (PACKS) |p| if (std.mem.eql(u8, p.id, req.pack_id)) break :blk p;
        return .{ .status = .bad_request, .body = "{\"error\":\"invalid_request\",\"message\":\"unknown pack\"}" };
    };

    const cents: i64 = @intFromFloat(@round(pack.amount_gbp * 100.0));
    return stripe.checkout(allocator, environ_map, .{
        .currency = "gbp",
        .amount_cents = cents,
        .product_label = pack.label,
        .success_url = req.success_url orelse "https://quantify.quantumencoding.io/payment-success",
        .cancel_url = req.cancel_url orelse "https://quantify.quantumencoding.io/payment-cancelled",
        .account_id = auth.account.id.slice(),
        .account_email = auth.account.email.slice(),
        .ticks = pack.ticks,
        .pack_id = pack.id,
    });
}

const html_headers: [1]http.Header = .{.{ .name = "content-type", .value = "text/html; charset=utf-8" }};

/// GET /qai/v1/quantify/payment-{success,cancelled} — Stripe redirect landing
/// pages with a deep link back into the Quantify app.
pub fn paymentPage(success: bool) Response {
    const body = if (success)
        "<!doctype html><meta name=viewport content=\"width=device-width,initial-scale=1\"><title>Payment complete</title><body style=\"font-family:system-ui;text-align:center;padding:3rem\"><h1>Thank you</h1><p>Your purchase is complete. You can return to Quantify.</p><a href=\"io.quantumencoding.quantify://settings\">Open Quantify</a></body>"
    else
        "<!doctype html><meta name=viewport content=\"width=device-width,initial-scale=1\"><title>Payment cancelled</title><body style=\"font-family:system-ui;text-align:center;padding:3rem\"><h1>Payment cancelled</h1><p>No charge was made.</p><a href=\"io.quantumencoding.quantify://settings\">Back to Quantify</a></body>";
    return .{ .status = .ok, .body = body, .headers = &html_headers };
}
