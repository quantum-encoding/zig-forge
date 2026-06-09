// Stripe payments — credit-pack purchase + webhook crediting.
//
//   POST /qai/v1/credits/purchase   (auth)   → Stripe Checkout Session URL
//   POST /qai/v1/webhooks/stripe     (public) → credits the account on
//                                               checkout.session.completed
//
// Ports the Go gateway's credit flow, using the Stripe REST API directly
// (the Stripe API is form-encoded, Bearer-auth with the secret key). The
// purchase handler creates a one-time Checkout Session with inline price_data
// (no pre-created Price IDs needed — same as the dropship sites) and stamps
// {user_id, pack_id, ticks} into the session metadata. The webhook verifies
// the Stripe-Signature HMAC over the RAW body, then on
// checkout.session.completed reads the signed metadata and credits the
// account by `ticks`.
//
// SECURITY (money path):
//  - Webhook signature: HMAC-SHA256 over "<t>.<rawbody>" with
//    STRIPE_WEBHOOK_SECRET, compared to the header's v1 in CONSTANT TIME
//    (std.crypto.timing_safe.eql) — EQL-FOR-SECRETS. An unsigned/forged event
//    is rejected before any crediting.
//  - `ticks` is trusted only AFTER signature verification: we set it at
//    session creation and Stripe signs the event that echoes it back.
//  - Idempotency: each Stripe session id credits at most once (in-memory
//    processed-set). NOTE non-durable across restart — a re-delivered event
//    after a restart could double-credit; documented in FEATURE_PARITY.md as
//    the follow-up (persist processed ids to the store/WAL).

const std = @import("std");
const http = std.http;
const hs = @import("http-sentinel");
const json_util = @import("json.zig");
const router = @import("router.zig");
const store_mod = @import("store/store.zig");
const types = @import("store/types.zig");
const ledger_mod = @import("ledger.zig");
const Response = router.Response;

const TICKS_PER_USD: i64 = 10_000_000_000;

const Pack = struct { id: []const u8, label: []const u8, amount_usd: i64, ticks: i64 };
const PACKS = [_]Pack{
    .{ .id = "pack_5", .label = "£5 Starter", .amount_usd = 5, .ticks = 5 * TICKS_PER_USD },
    .{ .id = "pack_10", .label = "£10 Creator", .amount_usd = 10, .ticks = 10 * TICKS_PER_USD },
    .{ .id = "pack_25", .label = "£25 Builder", .amount_usd = 25, .ticks = 25 * TICKS_PER_USD },
    .{ .id = "pack_50", .label = "£50 Pro", .amount_usd = 50, .ticks = 50 * TICKS_PER_USD },
    .{ .id = "pack_100", .label = "£100 Team", .amount_usd = 100, .ticks = 100 * TICKS_PER_USD },
};

// ── POST /qai/v1/credits/purchase ────────────────────────────────────

const PurchaseRequest = struct {
    pack_id: []const u8 = "",
    success_url: ?[]const u8 = null,
    cancel_url: ?[]const u8 = null,
};

pub fn handlePurchase(
    request: *http.Server.Request,
    allocator: std.mem.Allocator,
    environ_map: *const std.process.Environ.Map,
    auth: *const types.AuthContext,
) Response {
    const secret = hs.ai.getApiKeyFromEnv(environ_map, "STRIPE_SECRET_KEY") catch
        return errStatus(.service_unavailable, "payments not configured (STRIPE_SECRET_KEY unset)");

    const body = json_util.readBody(request, allocator, 64 * 1024) catch return errStatus(.bad_request, "read body");
    defer allocator.free(body);
    const parsed = std.json.parseFromSlice(PurchaseRequest, allocator, body, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch
        return errStatus(.bad_request, "invalid JSON body");
    defer parsed.deinit();
    const req = parsed.value;

    const pack: Pack = blk: {
        for (PACKS) |p| if (std.mem.eql(u8, p.id, req.pack_id)) break :blk p;
        return errStatus(.bad_request, "unknown pack");
    };

    _ = secret; // checkout re-reads it
    return checkout(allocator, environ_map, .{
        .currency = "usd",
        .amount_cents = pack.amount_usd * 100,
        .product_label = pack.label,
        .product_prefix = "Quantum Encoding Credits — ",
        .success_url = req.success_url orelse "https://cosmicduck.dev/dashboard?purchase=success",
        .cancel_url = req.cancel_url orelse "https://cosmicduck.dev/dashboard?purchase=cancelled",
        .account_id = auth.account.id.slice(),
        .account_email = auth.account.email.slice(),
        .ticks = pack.ticks,
        .pack_id = pack.id,
    });
}

// ── Generic Checkout Session creation (reused by all app checkouts) ──

pub const CheckoutParams = struct {
    currency: []const u8,
    amount_cents: i64,
    product_label: []const u8,
    product_prefix: []const u8 = "",
    success_url: []const u8,
    cancel_url: []const u8,
    account_id: []const u8,
    account_email: []const u8,
    ticks: i64,
    pack_id: []const u8,
};

/// Create a Stripe Checkout Session (mode=payment, inline price_data) and
/// return { checkout_url, session_id, pack_id }. The session metadata carries
/// {user_id, pack_id, ticks} so the webhook credits the right account.
pub fn checkout(allocator: std.mem.Allocator, environ_map: *const std.process.Environ.Map, p: CheckoutParams) Response {
    const secret = hs.ai.getApiKeyFromEnv(environ_map, "STRIPE_SECRET_KEY") catch
        return errStatus(.service_unavailable, "payments not configured");

    var form = FormBuilder.init(allocator);
    defer form.deinit();
    form.add("mode", "payment") catch return errStatus(.internal_server_error, "build");
    form.add("success_url", p.success_url) catch return errStatus(.internal_server_error, "build");
    form.add("cancel_url", p.cancel_url) catch return errStatus(.internal_server_error, "build");
    form.add("line_items[0][quantity]", "1") catch return errStatus(.internal_server_error, "build");
    form.add("line_items[0][price_data][currency]", p.currency) catch return errStatus(.internal_server_error, "build");
    var cents_buf: [24]u8 = undefined;
    const cents = std.fmt.bufPrint(&cents_buf, "{d}", .{p.amount_cents}) catch return errStatus(.internal_server_error, "build");
    form.add("line_items[0][price_data][unit_amount]", cents) catch return errStatus(.internal_server_error, "build");
    var name_buf: [160]u8 = undefined;
    const prod_name = std.fmt.bufPrint(&name_buf, "{s}{s}", .{ p.product_prefix, p.product_label }) catch p.product_label;
    form.add("line_items[0][price_data][product_data][name]", prod_name) catch return errStatus(.internal_server_error, "build");
    if (p.account_email.len > 0) form.add("customer_email", p.account_email) catch return errStatus(.internal_server_error, "build");
    form.add("client_reference_id", p.account_id) catch return errStatus(.internal_server_error, "build");
    form.add("metadata[user_id]", p.account_id) catch return errStatus(.internal_server_error, "build");
    form.add("metadata[pack_id]", p.pack_id) catch return errStatus(.internal_server_error, "build");
    var ticks_buf: [24]u8 = undefined;
    const ticks_str = std.fmt.bufPrint(&ticks_buf, "{d}", .{p.ticks}) catch return errStatus(.internal_server_error, "build");
    form.add("metadata[ticks]", ticks_str) catch return errStatus(.internal_server_error, "build");
    const form_body = form.finish() catch return errStatus(.internal_server_error, "build");
    defer allocator.free(form_body);

    var client = hs.HttpClient.init(allocator) catch return errStatus(.internal_server_error, "http init");
    defer client.deinit();
    const auth_header = std.fmt.allocPrint(allocator, "Bearer {s}", .{secret}) catch return errStatus(.internal_server_error, "alloc");
    defer allocator.free(auth_header);
    const headers = [_]http.Header{
        .{ .name = "Authorization", .value = auth_header },
        .{ .name = "Content-Type", .value = "application/x-www-form-urlencoded" },
    };

    var resp = client.post("https://api.stripe.com/v1/checkout/sessions", &headers, form_body) catch
        return errStatus(.bad_gateway, "stripe request failed");
    defer resp.deinit();
    if (resp.status != .ok) return errStatus(.bad_gateway, "stripe rejected the checkout session");

    const Session = struct { id: []const u8 = "", url: []const u8 = "" };
    const sp = std.json.parseFromSlice(Session, allocator, resp.body, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch
        return errStatus(.bad_gateway, "parse stripe response");
    defer sp.deinit();
    if (sp.value.url.len == 0) return errStatus(.bad_gateway, "stripe returned no checkout url");

    const out = std.json.Stringify.valueAlloc(allocator, .{
        .checkout_url = sp.value.url,
        .session_id = sp.value.id,
        .pack_id = p.pack_id,
    }, .{}) catch return errStatus(.internal_server_error, "serialize");
    return .{ .body = out };
}

// ── POST /qai/v1/account/billing-portal ──────────────────────────────

const PortalRequest = struct { return_url: ?[]const u8 = null };

/// Create a Stripe Billing Portal session. Resolves (creates) a customer for
/// the account's email, then opens a portal session.
pub fn handleBillingPortal(
    request: *http.Server.Request,
    allocator: std.mem.Allocator,
    environ_map: *const std.process.Environ.Map,
    auth: *const types.AuthContext,
) Response {
    const secret = hs.ai.getApiKeyFromEnv(environ_map, "STRIPE_SECRET_KEY") catch
        return errStatus(.service_unavailable, "payments not configured");
    const body = json_util.readBody(request, allocator, 16 * 1024) catch return errStatus(.bad_request, "read body");
    defer allocator.free(body);
    const parsed = std.json.parseFromSlice(PortalRequest, allocator, body, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch
        return errStatus(.bad_request, "invalid JSON body");
    defer parsed.deinit();
    const return_url = parsed.value.return_url orelse "https://cosmicduck.dev/dashboard";

    var client = hs.HttpClient.init(allocator) catch return errStatus(.internal_server_error, "http init");
    defer client.deinit();
    const auth_header = std.fmt.allocPrint(allocator, "Bearer {s}", .{secret}) catch return errStatus(.internal_server_error, "alloc");
    defer allocator.free(auth_header);
    const headers = [_]http.Header{
        .{ .name = "Authorization", .value = auth_header },
        .{ .name = "Content-Type", .value = "application/x-www-form-urlencoded" },
    };

    // Create (or reuse — Stripe dedups loosely by email at the dashboard) a
    // customer for this account, then open a portal session for it.
    var cust_form = FormBuilder.init(allocator);
    defer cust_form.deinit();
    cust_form.add("email", auth.account.email.slice()) catch return errStatus(.internal_server_error, "build");
    cust_form.add("metadata[user_id]", auth.account.id.slice()) catch return errStatus(.internal_server_error, "build");
    const cust_body = cust_form.finish() catch return errStatus(.internal_server_error, "build");
    defer allocator.free(cust_body);

    var cresp = client.post("https://api.stripe.com/v1/customers", &headers, cust_body) catch return errStatus(.bad_gateway, "stripe customer failed");
    const customer_id = blk: {
        defer cresp.deinit();
        if (cresp.status != .ok) return errStatus(.bad_gateway, "stripe rejected customer create");
        const C = struct { id: []const u8 = "" };
        const cp = std.json.parseFromSlice(C, allocator, cresp.body, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch return errStatus(.bad_gateway, "parse customer");
        defer cp.deinit();
        if (cp.value.id.len == 0) return errStatus(.bad_gateway, "no customer id");
        break :blk allocator.dupe(u8, cp.value.id) catch return errStatus(.internal_server_error, "alloc");
    };
    defer allocator.free(customer_id);

    var portal_form = FormBuilder.init(allocator);
    defer portal_form.deinit();
    portal_form.add("customer", customer_id) catch return errStatus(.internal_server_error, "build");
    portal_form.add("return_url", return_url) catch return errStatus(.internal_server_error, "build");
    const portal_body = portal_form.finish() catch return errStatus(.internal_server_error, "build");
    defer allocator.free(portal_body);

    var presp = client.post("https://api.stripe.com/v1/billing_portal/sessions", &headers, portal_body) catch return errStatus(.bad_gateway, "stripe portal failed");
    defer presp.deinit();
    if (presp.status != .ok) return errStatus(.bad_gateway, "stripe rejected portal session");
    const P = struct { url: []const u8 = "" };
    const pp = std.json.parseFromSlice(P, allocator, presp.body, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch return errStatus(.bad_gateway, "parse portal");
    defer pp.deinit();
    if (pp.value.url.len == 0) return errStatus(.bad_gateway, "no portal url");

    const out = std.json.Stringify.valueAlloc(allocator, .{ .portal_url = pp.value.url }, .{}) catch return errStatus(.internal_server_error, "serialize");
    return .{ .body = out };
}

// ── POST /qai/v1/webhooks/stripe (public; self-authenticating) ───────

pub fn handleWebhook(
    request: *http.Server.Request,
    allocator: std.mem.Allocator,
    io: std.Io,
    store: *store_mod.Store,
    ledger: ?*ledger_mod.Ledger,
    environ_map: *const std.process.Environ.Map,
) Response {
    const secret = hs.ai.getApiKeyFromEnv(environ_map, "STRIPE_WEBHOOK_SECRET") catch
        return errStatus(.service_unavailable, "webhook not configured");

    // RAW body — the HMAC is computed over these exact bytes.
    const body = json_util.readBody(request, allocator, 1 * 1024 * 1024) catch return errStatus(.bad_request, "read body");
    defer allocator.free(body);

    const sig_header = headerValue(request, "stripe-signature") orelse return errStatus(.bad_request, "missing signature");
    if (!verifySignature(allocator, sig_header, body, secret)) {
        return .{ .status = .bad_request, .body = "{\"error\":\"invalid_signature\"}" };
    }

    // Parse the (now-trusted) event.
    const Event = struct {
        type: []const u8 = "",
        data: struct {
            object: struct {
                id: []const u8 = "",
                metadata: struct {
                    user_id: []const u8 = "",
                    ticks: []const u8 = "",
                } = .{},
            } = .{},
        } = .{},
    };
    const ev = std.json.parseFromSlice(Event, allocator, body, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch
        return .{ .status = .ok, .body = "{\"received\":true}" }; // ack unparseable to stop retries
    defer ev.deinit();

    if (!std.mem.eql(u8, ev.value.type, "checkout.session.completed")) {
        return .{ .status = .ok, .body = "{\"received\":true}" }; // ignore other events
    }

    const obj = ev.value.data.object;
    const session_id = obj.id;
    const user_id = obj.metadata.user_id;
    const ticks = std.fmt.parseInt(i64, obj.metadata.ticks, 10) catch 0;
    if (user_id.len == 0 or ticks <= 0 or session_id.len == 0) {
        return .{ .status = .ok, .body = "{\"received\":true}" };
    }

    // Idempotency: credit each session id at most once.
    if (!markProcessed(session_id)) {
        return .{ .status = .ok, .body = "{\"received\":true,\"duplicate\":true}" };
    }

    store.creditAccount(io, user_id, ticks) catch {
        // Crediting failed — un-mark so a Stripe retry can re-attempt.
        unmarkProcessed(session_id);
        return errStatus(.internal_server_error, "credit failed");
    };

    if (ledger) |l| {
        var balance_after: i64 = 0;
        if (store.getAccountLocked(user_id)) |acct| balance_after = acct.balance_ticks;
        l.recordCredit(io, user_id, ticks, balance_after, "stripe");
    }

    return .{ .status = .ok, .body = "{\"received\":true,\"credited\":true}" };
}

/// Verify a Stripe-Signature header against the raw body. Header form:
/// "t=<unix>,v1=<hex>,v0=<hex>". HMAC-SHA256 over "<t>.<body>" with the
/// webhook secret must equal v1 (constant-time). Returns true iff valid.
fn verifySignature(allocator: std.mem.Allocator, sig_header: []const u8, body: []const u8, secret: []const u8) bool {
    var t_part: ?[]const u8 = null;
    var v1_part: ?[]const u8 = null;
    var it = std.mem.splitScalar(u8, sig_header, ',');
    while (it.next()) |kv| {
        if (std.mem.startsWith(u8, kv, "t=")) t_part = kv[2..];
        if (std.mem.startsWith(u8, kv, "v1=")) v1_part = kv[3..];
    }
    const t = t_part orelse return false;
    const v1_hex = v1_part orelse return false;
    if (v1_hex.len != 64) return false; // SHA-256 hex

    // signed_payload = "<t>.<body>"
    const signed = std.fmt.allocPrint(allocator, "{s}.{s}", .{ t, body }) catch return false;
    defer allocator.free(signed);

    const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;
    var mac: [HmacSha256.mac_length]u8 = undefined;
    HmacSha256.create(&mac, signed, secret);

    // Decode v1 hex → 32 bytes, then constant-time compare (EQL-FOR-SECRETS).
    var expected: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&expected, v1_hex) catch return false;
    return std.crypto.timing_safe.eql([32]u8, mac, expected);
}

// ── In-memory idempotency set ────────────────────────────────────────

var processed_lock: std.atomic.Value(u32) = .init(0);
var processed: std.StringHashMapUnmanaged(void) = .empty;

fn lockProcessed() void {
    while (processed_lock.cmpxchgWeak(0, 1, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
}
fn unlockProcessed() void {
    processed_lock.store(0, .release);
}

/// Returns true if this session id was newly marked (caller should credit);
/// false if it was already processed (skip).
fn markProcessed(session_id: []const u8) bool {
    const a = std.heap.c_allocator;
    lockProcessed();
    defer unlockProcessed();
    if (processed.contains(session_id)) return false;
    // Crude unbounded-growth guard: sessions are infrequent, but cap anyway.
    if (processed.count() >= 100_000) return true; // stop tracking; allow credit (better than blocking purchases)
    const key = a.dupe(u8, session_id) catch return true;
    processed.put(a, key, {}) catch {
        a.free(key);
        return true;
    };
    return true;
}

fn unmarkProcessed(session_id: []const u8) void {
    const a = std.heap.c_allocator;
    lockProcessed();
    defer unlockProcessed();
    if (processed.fetchRemove(session_id)) |kv| a.free(kv.key);
}

// ── Form encoder (application/x-www-form-urlencoded) ─────────────────

const FormBuilder = struct {
    buf: std.ArrayListUnmanaged(u8) = .empty,
    allocator: std.mem.Allocator,
    first: bool = true,

    fn init(allocator: std.mem.Allocator) FormBuilder {
        return .{ .allocator = allocator };
    }
    fn deinit(self: *FormBuilder) void {
        self.buf.deinit(self.allocator);
    }
    fn add(self: *FormBuilder, key: []const u8, value: []const u8) !void {
        if (!self.first) try self.buf.append(self.allocator, '&');
        self.first = false;
        try encode(&self.buf, self.allocator, key);
        try self.buf.append(self.allocator, '=');
        try encode(&self.buf, self.allocator, value);
    }
    fn finish(self: *FormBuilder) ![]u8 {
        return self.buf.toOwnedSlice(self.allocator);
    }
};

fn encode(buf: *std.ArrayListUnmanaged(u8), a: std.mem.Allocator, s: []const u8) !void {
    const hex = "0123456789ABCDEF";
    for (s) |c| {
        switch (c) {
            'A'...'Z', 'a'...'z', '0'...'9', '-', '_', '.', '~' => try buf.append(a, c),
            else => {
                try buf.append(a, '%');
                try buf.append(a, hex[c >> 4]);
                try buf.append(a, hex[c & 0x0F]);
            },
        }
    }
}

fn headerValue(request: *http.Server.Request, name: []const u8) ?[]const u8 {
    var it = request.iterateHeaders();
    while (it.next()) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
    }
    return null;
}

fn errStatus(status: http.Status, message: []const u8) Response {
    _ = message;
    return switch (status) {
        .bad_request => .{ .status = .bad_request, .body = "{\"error\":\"invalid_request\",\"message\":\"Stripe request rejected\"}" },
        .service_unavailable => .{ .status = .service_unavailable, .body = "{\"error\":\"unavailable\",\"message\":\"Payments are not configured on this server\"}" },
        .bad_gateway => .{ .status = .bad_gateway, .body = "{\"error\":\"payment_error\",\"message\":\"Stripe request failed\"}" },
        else => .{ .status = .internal_server_error, .body = "{\"error\":\"internal\",\"message\":\"Payment request failed\"}" },
    };
}
