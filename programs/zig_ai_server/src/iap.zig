// In-app-purchase receipt verification (App Store).
//
//   POST /qai/v1/{quantify,kitchenshare}/iap/app-store/verify
//
// Validates an App Store receipt against Apple's verifyReceipt endpoint with
// the app's shared secret (APP_STORE_SHARED_SECRET), then credits the account
// by the product→ticks table (copied verbatim from the Go gateway's
// routes_iap.go). Money path — safety notes:
//   - The receipt is verified by APPLE (HMAC-signed by Apple); a forged
//     receipt fails with a non-zero status and grants nothing.
//   - Each Apple transaction_id credits at most once (in-memory idempotency
//     set; non-durable across restart — same caveat as the Stripe webhook,
//     noted in FEATURE_PARITY.md).
//   - Unknown product ids grant 0 (fail-closed) rather than guess.
//   - Google Play verification needs the Android Publisher OAuth flow (service
//     account) — returns 501 until that's wired.

const std = @import("std");
const http = std.http;
const hs = @import("http-sentinel");
const json_util = @import("json.zig");
const router = @import("router.zig");
const store_mod = @import("store/store.zig");
const types = @import("store/types.zig");
const ledger_mod = @import("ledger.zig");
const Response = router.Response;

const APPLE_PROD = "https://buy.itunes.apple.com/verifyReceipt";
const APPLE_SANDBOX = "https://sandbox.itunes.apple.com/verifyReceipt";

/// product_id → ticks. Mirrors routes_iap.go (both dotted and underscore
/// variants Apple/Play emit). Credit packs only; app-unlock products are
/// entitlements (0 ticks).
fn productTicks(product_id: []const u8) i64 {
    const table = .{
        .{ "quantify.pack5", 50_000_000_000 },  .{ "quantify_pack5", 50_000_000_000 },
        .{ "quantify.pack10", 110_000_000_000 }, .{ "quantify_pack10", 110_000_000_000 },
        .{ "quantify.pack20", 240_000_000_000 }, .{ "quantify_pack20", 240_000_000_000 },
    };
    inline for (table) |row| {
        if (std.mem.eql(u8, product_id, row[0])) return row[1];
    }
    return 0;
}

const VerifyRequest = struct {
    receipt_data: []const u8 = "",
};

pub fn handleAppStoreVerify(
    request: *http.Server.Request,
    allocator: std.mem.Allocator,
    environ_map: *const std.process.Environ.Map,
    io: std.Io,
    store: ?*store_mod.Store,
    ledger: ?*ledger_mod.Ledger,
    auth: *const types.AuthContext,
) Response {
    const shared_secret = hs.ai.getApiKeyFromEnv(environ_map, "APP_STORE_SHARED_SECRET") catch
        return err(.service_unavailable, "IAP not configured (APP_STORE_SHARED_SECRET unset)");

    const body = json_util.readBody(request, allocator, 512 * 1024) catch return err(.bad_request, "read body");
    defer allocator.free(body);
    const parsed = std.json.parseFromSlice(VerifyRequest, allocator, body, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch
        return err(.bad_request, "invalid JSON body");
    defer parsed.deinit();
    if (parsed.value.receipt_data.len == 0) return err(.bad_request, "receipt_data is required");

    // Apple request body: {"receipt-data","password","exclude-old-transactions"}.
    const apple_body = std.json.Stringify.valueAlloc(allocator, .{
        .@"receipt-data" = parsed.value.receipt_data,
        .password = shared_secret,
        .@"exclude-old-transactions" = false,
    }, .{}) catch return err(.internal_server_error, "build");
    defer allocator.free(apple_body);

    var client = hs.HttpClient.init(allocator) catch return err(.internal_server_error, "http init");
    defer client.deinit();
    const headers = [_]http.Header{.{ .name = "Content-Type", .value = "application/json" }};

    // Try production; on 21007 (sandbox receipt) retry sandbox.
    var resp = client.post(APPLE_PROD, &headers, apple_body) catch return err(.bad_gateway, "apple verify failed");
    var body_owned = allocator.dupe(u8, resp.body) catch {
        resp.deinit();
        return err(.internal_server_error, "alloc");
    };
    resp.deinit();
    defer allocator.free(body_owned);

    if (statusOf(allocator, body_owned) == 21007) {
        allocator.free(body_owned);
        var sresp = client.post(APPLE_SANDBOX, &headers, apple_body) catch return err(.bad_gateway, "apple sandbox verify failed");
        body_owned = allocator.dupe(u8, sresp.body) catch {
            sresp.deinit();
            return err(.internal_server_error, "alloc");
        };
        sresp.deinit();
    }

    // Parse the verified receipt.
    const Receipt = struct {
        status: i64 = -1,
        receipt: ?struct {
            in_app: []const struct {
                product_id: []const u8 = "",
                transaction_id: []const u8 = "",
            } = &.{},
        } = null,
    };
    const r = std.json.parseFromSlice(Receipt, allocator, body_owned, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch
        return err(.bad_gateway, "parse apple response");
    defer r.deinit();

    if (r.value.status != 0) return err(.bad_request, "invalid receipt");

    // Credit each new transaction's product.
    var credited: i64 = 0;
    if (r.value.receipt) |rcpt| {
        for (rcpt.in_app) |item| {
            const ticks = productTicks(item.product_id);
            if (ticks <= 0) continue;
            if (item.transaction_id.len == 0) continue;
            if (!markProcessed(item.transaction_id)) continue; // already credited
            if (store) |s| {
                s.creditAccount(io, auth.account.id.slice(), ticks) catch {
                    unmarkProcessed(item.transaction_id);
                    continue;
                };
                credited += ticks;
            }
        }
    }

    var balance_after: i64 = 0;
    if (store) |s| if (s.getAccountLocked(auth.account.id.slice())) |acct| {
        balance_after = acct.balance_ticks;
    };
    if (credited > 0) if (ledger) |l| l.recordCredit(io, auth.account.id.slice(), credited, balance_after, "app_store_iap");

    const out = std.json.Stringify.valueAlloc(allocator, .{
        .status = "valid",
        .credited_ticks = credited,
        .balance_after = balance_after,
    }, .{}) catch return err(.internal_server_error, "serialize");
    return .{ .status = .ok, .body = out };
}

/// Google Play verification needs the Android Publisher API (service-account
/// OAuth) — not yet wired.
pub fn handleGooglePlayVerify(request: *http.Server.Request, allocator: std.mem.Allocator) Response {
    _ = request;
    _ = allocator;
    return .{ .status = .not_implemented, .body = "{\"error\":\"not_implemented\",\"message\":\"Google Play receipt verification needs the Android Publisher service-account flow (not yet wired).\"}" };
}

fn statusOf(allocator: std.mem.Allocator, body: []const u8) i64 {
    const S = struct { status: i64 = -1 };
    const p = std.json.parseFromSlice(S, allocator, body, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch return -1;
    defer p.deinit();
    return p.value.status;
}

// ── transaction idempotency set ──────────────────────────────────────
var processed_lock: std.atomic.Value(u32) = .init(0);
var processed: std.StringHashMapUnmanaged(void) = .empty;

fn markProcessed(txn_id: []const u8) bool {
    const a = std.heap.c_allocator;
    while (processed_lock.cmpxchgWeak(0, 1, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
    defer processed_lock.store(0, .release);
    if (processed.contains(txn_id)) return false;
    if (processed.count() >= 200_000) return true;
    const key = a.dupe(u8, txn_id) catch return true;
    processed.put(a, key, {}) catch {
        a.free(key);
        return true;
    };
    return true;
}

fn unmarkProcessed(txn_id: []const u8) void {
    const a = std.heap.c_allocator;
    while (processed_lock.cmpxchgWeak(0, 1, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
    defer processed_lock.store(0, .release);
    if (processed.fetchRemove(txn_id)) |kv| a.free(kv.key);
}

fn err(status: http.Status, message: []const u8) Response {
    _ = message;
    return switch (status) {
        .bad_request => .{ .status = .bad_request, .body = "{\"error\":\"invalid_request\",\"message\":\"receipt rejected\"}" },
        .service_unavailable => .{ .status = .service_unavailable, .body = "{\"error\":\"unavailable\",\"message\":\"IAP not configured\"}" },
        .bad_gateway => .{ .status = .bad_gateway, .body = "{\"error\":\"provider_error\",\"message\":\"Apple verification failed\"}" },
        else => .{ .status = .internal_server_error, .body = "{\"error\":\"internal\",\"message\":\"IAP verification failed\"}" },
    };
}
