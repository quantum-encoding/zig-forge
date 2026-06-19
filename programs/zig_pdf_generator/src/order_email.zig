//! App-aware order-confirmation email generator.
//!
//! One Stripe account (`QUANTUM ENCODING LTD`, acct_1SOZqPEeBZaxUZah) backs
//! every Quantum-Encoding app, so a single webhook endpoint receives every
//! `checkout.session.completed` event. This module routes each event to the
//! correct per-app email template instead of always emitting the Lutuno
//! physical-order template.
//!
//! Hard rules (from the spec, enforced here):
//!   * Route by `metadata.app` on the session; fall back to the product's
//!     `metadata.app` (the webhook expands `line_items[0].price.product` and
//!     passes it in as `product_app`).
//!   * An unknown / untagged app NEVER falls through to Lutuno — it returns a
//!     `skip` decision and the webhook sends nothing.
//!   * `is_physical` is per-app. Only Lutuno ships today; digital apps must
//!     never render tracking / shipping copy.
//!
//! Legal-entity split (set by Rich, 2026-06-19):
//!   * Digital apps (exact, quantify, kitchenshare, qai) are sold on the main
//!     English account => "Quantum Encoding Ltd".
//!   * Lutuno is a dropshipping webstore. EU destinations bill from the Irish
//!     company "Quantum Encoding Europe Limited"; UK (GB) destinations bill
//!     from "Quantum Encoding Ltd". Resolved here from the ship-to country
//!     (falls back to billing country, then defaults to the EU/Irish entity).
//!
//! I/O contract: this is a PURE, STATELESS function. JSON in -> JSON envelope
//! out. Event-id idempotency stays in the webhook (it dedups before/after
//! calling); we echo `event_id` and `order_ref` back to help. The envelope is
//! built with `std.json.Stringify` (never format-string concatenation — see
//! the JSON-IN-FMT anti-pattern in CLAUDE.md). All session-derived values
//! interpolated into the HTML body are HTML-escaped first.
//!
//! Output envelope shape:
//!   {"action":"send","app":"exact","from_name":"Exact",
//!    "from_email":"orders@exactpdfconverter.com","to":"a@b.com",
//!    "subject":"Your Exact credits are ready","order_ref":"EXA-...",
//!    "legal_entity":"Quantum Encoding Ltd","event_id":"evt_...","html":"<...>"}
//!   {"action":"skip","reason":"unknown app for session ...; no email sent",
//!    "app":"","order_ref":null,"event_id":"evt_..."}

const std = @import("std");

// =============================================================================
// Per-app template registry
// =============================================================================

pub const Template = struct {
    app: []const u8,
    brand_name: []const u8,
    from_name: []const u8,
    /// Default sender. Overridable per-call via the input `from_email` field.
    /// The three apps whose domains Rich has not yet confirmed point at a
    /// `.invalid` placeholder so an un-overridden send FAILS LOUDLY at the
    /// mail layer rather than mailing from a real-but-wrong domain.
    from_email: []const u8,
    subject: []const u8,
    is_physical: bool,
    item_label: []const u8,
    cta_label: []const u8,
    /// Fallback CTA target. Empty => no button unless the session supplies
    /// `site` (Exact's metadata.site deep-link) or a `cta_url` override.
    cta_url: []const u8,
    accent: []const u8,
    /// Order-reference prefix, e.g. "EXA" -> "EXA-AB12CD34EF".
    order_prefix: []const u8,
};

/// Returns the template for `app`, or null when the app is not in the registry
/// (the caller must then SKIP — never default to Lutuno).
pub fn lookup(app: []const u8) ?Template {
    if (std.mem.eql(u8, app, "exact")) return .{
        .app = "exact",
        .brand_name = "Exact",
        .from_name = "Exact",
        .from_email = "orders@exactpdfconverter.com",
        .subject = "Your Exact credits are ready",
        .is_physical = false,
        .item_label = "Exact Credits",
        .cta_label = "Go to your account",
        .cta_url = "https://exactpdfconverter.com/account",
        .accent = "#2563eb",
        .order_prefix = "EXA",
    };
    if (std.mem.eql(u8, app, "quantify")) return .{
        .app = "quantify",
        .brand_name = "Quantify",
        .from_name = "Quantify",
        .from_email = "orders@CONFIGURE-ME.invalid", // TODO(rich): real Quantify sender domain
        .subject = "Your Quantify credits are ready",
        .is_physical = false,
        .item_label = "Quantify Credits",
        .cta_label = "Go to your account",
        .cta_url = "", // TODO(rich): Quantify account URL
        .accent = "#7c3aed",
        .order_prefix = "QFY",
    };
    if (std.mem.eql(u8, app, "kitchenshare")) return .{
        .app = "kitchenshare",
        .brand_name = "Kitchen Share",
        .from_name = "Kitchen Share",
        .from_email = "orders@CONFIGURE-ME.invalid", // TODO(rich): real Kitchen Share sender domain
        .subject = "Your Kitchen Share credits are ready",
        .is_physical = false,
        .item_label = "Kitchen Share Credits",
        .cta_label = "Go to your account",
        .cta_url = "", // TODO(rich): Kitchen Share account URL
        .accent = "#ea580c",
        .order_prefix = "KSH",
    };
    if (std.mem.eql(u8, app, "qai")) return .{
        .app = "qai",
        .brand_name = "qai",
        .from_name = "qai",
        .from_email = "orders@CONFIGURE-ME.invalid", // TODO(rich): real qai sender domain
        .subject = "Your qai credits are ready",
        .is_physical = false,
        .item_label = "qai Credits",
        .cta_label = "Go to your account",
        .cta_url = "", // TODO(rich): qai account URL
        .accent = "#0891b2",
        .order_prefix = "QAI",
    };
    if (std.mem.eql(u8, app, "lutuno")) return .{
        .app = "lutuno",
        .brand_name = "Lutuno",
        .from_name = "Lutuno",
        .from_email = "orders@lutuno.com",
        .subject = "Your Lutuno order is confirmed",
        .is_physical = true,
        .item_label = "Order",
        .cta_label = "View your order",
        .cta_url = "https://lutuno.com/account",
        .accent = "#b39a7d",
        .order_prefix = "LUT",
    };
    return null;
}

// Legal entities.
const ENTITY_UK = "Quantum Encoding Ltd";
const ENTITY_EU = "Quantum Encoding Europe Limited";

// =============================================================================
// Input model (normalized by the webhook from the Stripe event)
// =============================================================================

const Input = struct {
    event_id: []const u8 = "",
    session_id: []const u8 = "",
    payment_intent_id: []const u8 = "",
    /// session.metadata.app
    app: []const u8 = "",
    /// product.metadata.app (fallback when the session is untagged)
    product_app: []const u8 = "",
    /// product.metadata.kind (credit_pack | app_unlock | ...), informational
    product_kind: []const u8 = "",
    customer_email: []const u8 = "",
    customer_name: []const u8 = "",
    amount_total: i64 = 0, // minor units
    currency: []const u8 = "",
    credits: i64 = 0,
    pack: []const u8 = "",
    user_id: []const u8 = "",
    /// session.metadata.site — Exact's two-domain CTA deep-link.
    site: []const u8 = "",
    /// Ship-to / bill-to country (ISO-3166 alpha-2) — drives Lutuno entity.
    shipping_country: []const u8 = "",
    billing_country: []const u8 = "",
    /// Optional per-call sender override (lets the webhook set the real domain
    /// for an app whose default is still a placeholder, no rebuild needed).
    from_email_override: []const u8 = "",
    cta_url_override: []const u8 = "",
    /// Lutuno physical line items.
    line_items: []const LineItem = &.{},
};

const LineItem = struct {
    label: []const u8 = "",
    quantity: i64 = 1,
    amount_total: i64 = 0, // minor units, line total
};

// =============================================================================
// Public entry point
// =============================================================================

pub const Error = error{ InvalidJson, OutOfMemory };

/// Parse the normalized Stripe-event JSON, route to the right template, render,
/// and return a JSON envelope the webhook acts on. Caller owns the returned
/// bytes. Returns InvalidJson only on malformed input; an unknown app is a
/// successful `{"action":"skip"}` result, not an error.
pub fn generateFromJson(allocator: std.mem.Allocator, json_str: []const u8) Error![]u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json_str, .{}) catch {
        return error.InvalidJson;
    };
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidJson;

    const in = parseInput(allocator, parsed.value.object) catch return error.OutOfMemory;
    defer allocator.free(in.line_items);

    // --- Routing: session app -> product app -> SKIP (never Lutuno) ---------
    var app = in.app;
    if (app.len == 0) app = in.product_app;

    const tmpl = lookup(app) orelse {
        return skipEnvelope(allocator, in.event_id);
    };

    const order_ref = try buildOrderRef(allocator, tmpl.order_prefix, in.session_id, in.payment_intent_id);
    defer allocator.free(order_ref);

    const legal_entity = resolveLegalEntity(tmpl, in.shipping_country, in.billing_country);

    const html = try renderHtml(allocator, tmpl, in, order_ref, legal_entity);
    defer allocator.free(html);

    const from_email = if (in.from_email_override.len > 0) in.from_email_override else tmpl.from_email;

    const SendEnvelope = struct {
        action: []const u8,
        app: []const u8,
        from_name: []const u8,
        from_email: []const u8,
        to: []const u8,
        subject: []const u8,
        order_ref: []const u8,
        legal_entity: []const u8,
        is_physical: bool,
        event_id: ?[]const u8,
        html: []const u8,
    };

    return std.json.Stringify.valueAlloc(allocator, SendEnvelope{
        .action = "send",
        .app = tmpl.app,
        .from_name = tmpl.from_name,
        .from_email = from_email,
        .to = in.customer_email,
        .subject = tmpl.subject,
        .order_ref = order_ref,
        .legal_entity = legal_entity,
        .is_physical = tmpl.is_physical,
        .event_id = if (in.event_id.len > 0) in.event_id else null,
        .html = html,
    }, .{});
}

fn skipEnvelope(allocator: std.mem.Allocator, event_id: []const u8) Error![]u8 {
    const SkipEnvelope = struct {
        action: []const u8,
        reason: []const u8,
        app: []const u8,
        order_ref: ?[]const u8,
        event_id: ?[]const u8,
        html: ?[]const u8,
    };
    return std.json.Stringify.valueAlloc(allocator, SkipEnvelope{
        .action = "skip",
        .reason = "unknown or untagged app for this session; no email sent",
        .app = "",
        .order_ref = null,
        .event_id = if (event_id.len > 0) event_id else null,
        .html = null,
    }, .{});
}

// =============================================================================
// Legal entity / order ref
// =============================================================================

fn resolveLegalEntity(tmpl: Template, shipping_country: []const u8, billing_country: []const u8) []const u8 {
    if (!tmpl.is_physical) return ENTITY_UK; // digital apps are all on the English account
    // Lutuno: ship-to (else bill-to) country picks the billing entity.
    const country = if (shipping_country.len > 0) shipping_country else billing_country;
    if (eqlIgnoreCase(country, "GB")) return ENTITY_UK;
    return ENTITY_EU; // EU destinations + unknown default to the Irish entity
}

/// "<PREFIX>-<short id>" derived deterministically from the session id (else
/// the payment intent), so the same event always yields the same reference.
fn buildOrderRef(allocator: std.mem.Allocator, prefix: []const u8, session_id: []const u8, pi_id: []const u8) Error![]u8 {
    const source = if (session_id.len > 0) session_id else pi_id;
    var short: [12]u8 = undefined;
    var n: usize = 0;
    // Walk the source backwards, keeping alphanumerics, uppercased.
    var i: usize = source.len;
    while (i > 0 and n < short.len) {
        i -= 1;
        const c = source[i];
        if (std.ascii.isAlphanumeric(c)) {
            short[short.len - 1 - n] = std.ascii.toUpper(c);
            n += 1;
        }
    }
    const tail = if (n > 0) short[short.len - n ..] else "UNKNOWN";
    return std.fmt.allocPrint(allocator, "{s}-{s}", .{ prefix, tail });
}

// =============================================================================
// HTML rendering
// =============================================================================

fn renderHtml(
    allocator: std.mem.Allocator,
    tmpl: Template,
    in: Input,
    order_ref: []const u8,
    legal_entity: []const u8,
) Error![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);
    const a = allocator;

    const amount = try formatMoney(a, in.amount_total, in.currency);
    defer a.free(amount);

    // Resolve CTA: explicit override -> session.metadata.site -> template default.
    const cta_url = if (in.cta_url_override.len > 0)
        in.cta_url_override
    else if (in.site.len > 0)
        in.site
    else
        tmpl.cta_url;

    try buf.appendSlice(a, "<!DOCTYPE html><html><head><meta charset=\"utf-8\">");
    try buf.appendSlice(a, "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\"></head>");
    try buf.appendSlice(a, "<body style=\"margin:0;padding:0;background:#f4f4f5;font-family:-apple-system,Segoe UI,Roboto,Helvetica,Arial,sans-serif;color:#1a1a1a;\">");
    try buf.appendSlice(a, "<table role=\"presentation\" width=\"100%\" cellpadding=\"0\" cellspacing=\"0\"><tr><td align=\"center\" style=\"padding:24px;\">");
    try buf.appendSlice(a, "<table role=\"presentation\" width=\"560\" cellpadding=\"0\" cellspacing=\"0\" style=\"max-width:560px;background:#ffffff;border-radius:12px;overflow:hidden;\">");

    // Header bar (brand accent).
    try buf.appendSlice(a, "<tr><td style=\"background:");
    try appendEscaped(&buf, a, tmpl.accent);
    try buf.appendSlice(a, ";padding:28px 32px;\"><span style=\"color:#ffffff;font-size:22px;font-weight:700;\">");
    try appendEscaped(&buf, a, tmpl.brand_name);
    try buf.appendSlice(a, "</span></td></tr>");

    // Body.
    try buf.appendSlice(a, "<tr><td style=\"padding:32px;\">");

    if (in.customer_name.len > 0) {
        try buf.appendSlice(a, "<p style=\"font-size:16px;margin:0 0 16px;\">Hi ");
        try appendEscaped(&buf, a, in.customer_name);
        try buf.appendSlice(a, ",</p>");
    }

    if (tmpl.is_physical) {
        try renderPhysicalBody(&buf, a, tmpl, in, amount);
    } else {
        try renderDigitalBody(&buf, a, tmpl, in);
    }

    // Order summary box (shared).
    try buf.appendSlice(a, "<table role=\"presentation\" width=\"100%\" cellpadding=\"0\" cellspacing=\"0\" style=\"margin:24px 0;background:#f9fafb;border-radius:8px;\"><tr><td style=\"padding:16px 20px;\">");
    try appendSummaryRow(&buf, a, "Order reference", order_ref);
    try appendSummaryRow(&buf, a, "Amount paid", amount);
    try buf.appendSlice(a, "</td></tr></table>");

    // CTA button (only if we actually have a URL).
    if (cta_url.len > 0) {
        try buf.appendSlice(a, "<p style=\"margin:24px 0;\"><a href=\"");
        try appendEscaped(&buf, a, cta_url);
        try buf.appendSlice(a, "\" style=\"display:inline-block;background:");
        try appendEscaped(&buf, a, tmpl.accent);
        try buf.appendSlice(a, ";color:#ffffff;text-decoration:none;padding:12px 24px;border-radius:8px;font-weight:600;\">");
        try appendEscaped(&buf, a, tmpl.cta_label);
        try buf.appendSlice(a, "</a></p>");
    }

    try buf.appendSlice(a, "</td></tr>");

    // Footer with the correct legal entity.
    try buf.appendSlice(a, "<tr><td style=\"padding:20px 32px;background:#f9fafb;border-top:1px solid #e5e7eb;\">");
    try buf.appendSlice(a, "<p style=\"font-size:12px;color:#6b7280;margin:0;\">This receipt was issued by ");
    try appendEscaped(&buf, a, legal_entity);
    try buf.appendSlice(a, ".</p>");
    // TODO(rich): add registered office address + company number per entity.
    try buf.appendSlice(a, "</td></tr></table></td></tr></table></body></html>");

    return buf.toOwnedSlice(a);
}

fn renderDigitalBody(buf: *std.ArrayListUnmanaged(u8), a: std.mem.Allocator, tmpl: Template, in: Input) Error!void {
    try buf.appendSlice(a, "<p style=\"font-size:16px;line-height:1.6;margin:0 0 16px;\">Thanks for your purchase. ");
    if (in.credits > 0) {
        var num: [24]u8 = undefined;
        const credits_str = std.fmt.bufPrint(&num, "{d}", .{in.credits}) catch "your";
        try buf.appendSlice(a, "<strong>");
        try appendEscaped(buf, a, credits_str);
        try buf.appendSlice(a, "</strong> credits have been added to your ");
        try appendEscaped(buf, a, tmpl.brand_name);
        try buf.appendSlice(a, " account and are ready to use now. Credits never expire.");
    } else {
        try appendEscaped(buf, a, tmpl.item_label);
        try buf.appendSlice(a, " has been added to your ");
        try appendEscaped(buf, a, tmpl.brand_name);
        try buf.appendSlice(a, " account and is ready to use now.");
    }
    try buf.appendSlice(a, "</p>");
}

fn renderPhysicalBody(buf: *std.ArrayListUnmanaged(u8), a: std.mem.Allocator, tmpl: Template, in: Input, amount: []const u8) Error!void {
    _ = amount;
    try buf.appendSlice(a, "<p style=\"font-size:16px;line-height:1.6;margin:0 0 16px;\">Thanks for your order from ");
    try appendEscaped(buf, a, tmpl.brand_name);
    try buf.appendSlice(a, ". We're getting it ready — we'll email tracking once it ships.</p>");

    if (in.line_items.len > 0) {
        try buf.appendSlice(a, "<table role=\"presentation\" width=\"100%\" cellpadding=\"0\" cellspacing=\"0\" style=\"margin:16px 0;border-collapse:collapse;\">");
        for (in.line_items) |li| {
            try buf.appendSlice(a, "<tr><td style=\"padding:8px 0;border-bottom:1px solid #eee;font-size:14px;\">");
            var qty: [24]u8 = undefined;
            const qty_str = std.fmt.bufPrint(&qty, "{d}", .{li.quantity}) catch "1";
            try appendEscaped(buf, a, qty_str);
            try buf.appendSlice(a, " &times; ");
            try appendEscaped(buf, a, li.label);
            try buf.appendSlice(a, "</td><td align=\"right\" style=\"padding:8px 0;border-bottom:1px solid #eee;font-size:14px;\">");
            const line_amt = try formatMoney(a, li.amount_total, in.currency);
            defer a.free(line_amt);
            try appendEscaped(buf, a, line_amt);
            try buf.appendSlice(a, "</td></tr>");
        }
        try buf.appendSlice(a, "</table>");
    }
}

fn appendSummaryRow(buf: *std.ArrayListUnmanaged(u8), a: std.mem.Allocator, label: []const u8, val: []const u8) Error!void {
    try buf.appendSlice(a, "<p style=\"margin:4px 0;font-size:14px;color:#374151;\"><span style=\"color:#6b7280;\">");
    try appendEscaped(buf, a, label);
    try buf.appendSlice(a, ":</span> <strong>");
    try appendEscaped(buf, a, val);
    try buf.appendSlice(a, "</strong></p>");
}

// =============================================================================
// Helpers
// =============================================================================

/// Append `text` to `buf` with HTML special characters escaped. This is the
/// HTML analogue of the JSON-IN-FMT rule: every session-derived value that
/// lands in markup is escaped so a customer name like `<script>` or `&` can't
/// break (or inject into) the email body.
fn appendEscaped(buf: *std.ArrayListUnmanaged(u8), a: std.mem.Allocator, text: []const u8) Error!void {
    for (text) |c| {
        switch (c) {
            '&' => try buf.appendSlice(a, "&amp;"),
            '<' => try buf.appendSlice(a, "&lt;"),
            '>' => try buf.appendSlice(a, "&gt;"),
            '"' => try buf.appendSlice(a, "&quot;"),
            '\'' => try buf.appendSlice(a, "&#39;"),
            else => try buf.append(a, c),
        }
    }
}

/// Format a minor-unit amount + ISO currency into a display string, e.g.
/// (1000, "gbp") -> "£10.00". Zero-decimal currencies print as integers.
fn formatMoney(a: std.mem.Allocator, amount_minor: i64, currency: []const u8) Error![]u8 {
    const symbol = currencySymbol(currency);
    if (isZeroDecimal(currency)) {
        return std.fmt.allocPrint(a, "{s}{d}", .{ symbol, amount_minor });
    }
    const neg = amount_minor < 0;
    const abs: u64 = @abs(amount_minor); // u64 result handles the i64-min edge
    const major = abs / 100;
    const minor = abs % 100;
    return std.fmt.allocPrint(a, "{s}{s}{d}.{d:0>2}", .{ if (neg) "-" else "", symbol, major, minor });
}

fn currencySymbol(currency: []const u8) []const u8 {
    if (eqlIgnoreCase(currency, "gbp")) return "£";
    if (eqlIgnoreCase(currency, "eur")) return "€";
    if (eqlIgnoreCase(currency, "usd")) return "$";
    if (eqlIgnoreCase(currency, "jpy")) return "¥";
    // Unknown: prefix the uppercase code + space, handled by caller via symbol.
    return "";
}

fn isZeroDecimal(currency: []const u8) bool {
    return eqlIgnoreCase(currency, "jpy") or eqlIgnoreCase(currency, "krw");
}

fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

// =============================================================================
// Input parsing (std.json.Value -> Input). Slices borrow from the parsed
// document, which the caller keeps alive until after rendering.
// =============================================================================

fn parseInput(allocator: std.mem.Allocator, obj: std.json.ObjectMap) !Input {
    var in = Input{};
    in.event_id = getStr(obj, "event_id");
    in.session_id = getStr(obj, "session_id");
    in.payment_intent_id = getStr(obj, "payment_intent_id");
    in.app = getStr(obj, "app");
    in.product_app = getStr(obj, "product_app");
    in.product_kind = getStr(obj, "product_kind");
    in.customer_email = getStr(obj, "customer_email");
    in.customer_name = getStr(obj, "customer_name");
    in.amount_total = getInt(obj, "amount_total");
    in.currency = getStr(obj, "currency");
    in.credits = getInt(obj, "credits");
    in.pack = getStr(obj, "pack");
    in.user_id = getStr(obj, "user_id");
    in.site = getStr(obj, "site");
    in.shipping_country = getStr(obj, "shipping_country");
    in.billing_country = getStr(obj, "billing_country");
    in.from_email_override = getStr(obj, "from_email_override");
    in.cta_url_override = getStr(obj, "cta_url_override");

    if (obj.get("line_items")) |val| {
        if (val == .array) {
            const arr = val.array;
            const items = try allocator.alloc(LineItem, arr.items.len);
            for (arr.items, 0..) |item_val, i| {
                items[i] = .{};
                if (item_val == .object) {
                    const io = item_val.object;
                    items[i].label = getStr(io, "label");
                    items[i].quantity = getIntDefault(io, "quantity", 1);
                    items[i].amount_total = getInt(io, "amount_total");
                }
            }
            in.line_items = items;
        }
    }
    return in;
}

fn getStr(obj: std.json.ObjectMap, key: []const u8) []const u8 {
    if (obj.get(key)) |val| {
        if (val == .string) return val.string;
    }
    return "";
}

fn getInt(obj: std.json.ObjectMap, key: []const u8) i64 {
    return getIntDefault(obj, key, 0);
}

fn getIntDefault(obj: std.json.ObjectMap, key: []const u8, default: i64) i64 {
    if (obj.get(key)) |val| {
        switch (val) {
            .integer => return val.integer,
            .float => return @intFromFloat(val.float),
            .string => return std.fmt.parseInt(i64, val.string, 10) catch default,
            else => {},
        }
    }
    return default;
}

// =============================================================================
// Tests — exercise routing, the hard "never Lutuno" rule, both render paths,
// the legal-entity split, and escaping.
// =============================================================================

const testing = std.testing;

fn fieldEquals(json: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, json, needle) != null;
}

test "exact digital: routes to Exact, credits copy, no shipping, non-Lutuno sender" {
    const a = testing.allocator;
    const input =
        \\{"event_id":"evt_1","session_id":"cs_test_abc12345","app":"exact",
        \\ "customer_email":"buyer@example.com","amount_total":1000,"currency":"gbp",
        \\ "credits":250,"pack":"starter"}
    ;
    const out = try generateFromJson(a, input);
    defer a.free(out);

    try testing.expect(fieldEquals(out, "\"action\":\"send\""));
    try testing.expect(fieldEquals(out, "\"app\":\"exact\""));
    try testing.expect(fieldEquals(out, "\"from_email\":\"orders@exactpdfconverter.com\""));
    try testing.expect(fieldEquals(out, "\"to\":\"buyer@example.com\""));
    try testing.expect(fieldEquals(out, "\"order_ref\":\"EXA-"));
    try testing.expect(fieldEquals(out, "\"legal_entity\":\"Quantum Encoding Ltd\""));
    try testing.expect(fieldEquals(out, "\"is_physical\":false"));
    // Body: credits added, never expire; NO shipping copy; not Lutuno-branded.
    try testing.expect(fieldEquals(out, "250"));
    try testing.expect(fieldEquals(out, "Credits never expire"));
    try testing.expect(!fieldEquals(out, "tracking"));
    try testing.expect(!fieldEquals(out, "Lutuno"));
    try testing.expect(!fieldEquals(out, "lutuno.com"));
    // £10.00 -> JSON-escaped £ is fine; check the numeric part.
    try testing.expect(fieldEquals(out, "10.00"));
}

test "exact CTA deep-links via metadata.site when present" {
    const a = testing.allocator;
    const input =
        \\{"session_id":"cs_x1","app":"exact","customer_email":"b@e.com",
        \\ "amount_total":500,"currency":"gbp","credits":100,
        \\ "site":"https://exacthandwritingextractor.com/account"}
    ;
    const out = try generateFromJson(a, input);
    defer a.free(out);
    try testing.expect(fieldEquals(out, "exacthandwritingextractor.com/account"));
    // The default CTA path is replaced by metadata.site. (from_email still
    // legitimately carries the exactpdfconverter.com sender domain.)
    try testing.expect(!fieldEquals(out, "exactpdfconverter.com/account"));
}

test "unknown app: SKIP, never falls through to Lutuno" {
    const a = testing.allocator;
    const input =
        \\{"event_id":"evt_9","session_id":"cs_unknown","customer_email":"x@y.com",
        \\ "amount_total":999,"currency":"usd"}
    ;
    const out = try generateFromJson(a, input);
    defer a.free(out);
    try testing.expect(fieldEquals(out, "\"action\":\"skip\""));
    try testing.expect(fieldEquals(out, "\"event_id\":\"evt_9\""));
    try testing.expect(!fieldEquals(out, "Lutuno"));
    try testing.expect(!fieldEquals(out, "\"action\":\"send\""));
}

test "product_app fallback when session app is empty" {
    const a = testing.allocator;
    const input =
        \\{"session_id":"cs_p1","product_app":"qai","customer_email":"q@e.com",
        \\ "amount_total":2000,"currency":"usd","credits":500}
    ;
    const out = try generateFromJson(a, input);
    defer a.free(out);
    try testing.expect(fieldEquals(out, "\"app\":\"qai\""));
    try testing.expect(fieldEquals(out, "\"action\":\"send\""));
}

test "lutuno physical EU order: Irish entity, shipping copy" {
    const a = testing.allocator;
    const input =
        \\{"session_id":"cs_lut_eu","app":"lutuno","customer_email":"eu@buyer.de",
        \\ "amount_total":4500,"currency":"eur","shipping_country":"DE",
        \\ "line_items":[{"label":"Widget","quantity":2,"amount_total":4500}]}
    ;
    const out = try generateFromJson(a, input);
    defer a.free(out);
    try testing.expect(fieldEquals(out, "\"app\":\"lutuno\""));
    try testing.expect(fieldEquals(out, "\"is_physical\":true"));
    try testing.expect(fieldEquals(out, "\"legal_entity\":\"Quantum Encoding Europe Limited\""));
    try testing.expect(fieldEquals(out, "\"order_ref\":\"LUT-"));
    try testing.expect(fieldEquals(out, "tracking once it ships"));
    try testing.expect(fieldEquals(out, "Widget"));
}

test "lutuno physical UK order: English entity" {
    const a = testing.allocator;
    const input =
        \\{"session_id":"cs_lut_uk","app":"lutuno","customer_email":"uk@buyer.co.uk",
        \\ "amount_total":3000,"currency":"gbp","shipping_country":"GB"}
    ;
    const out = try generateFromJson(a, input);
    defer a.free(out);
    try testing.expect(fieldEquals(out, "\"legal_entity\":\"Quantum Encoding Ltd\""));
}

test "lutuno with no country defaults to Irish entity" {
    const a = testing.allocator;
    const input =
        \\{"session_id":"cs_lut_x","app":"lutuno","customer_email":"a@b.com",
        \\ "amount_total":1000,"currency":"eur"}
    ;
    const out = try generateFromJson(a, input);
    defer a.free(out);
    try testing.expect(fieldEquals(out, "\"legal_entity\":\"Quantum Encoding Europe Limited\""));
}

test "from_email override replaces placeholder sender" {
    const a = testing.allocator;
    const input =
        \\{"session_id":"cs_q1","app":"quantify","customer_email":"c@e.com",
        \\ "amount_total":1500,"currency":"gbp","credits":300,
        \\ "from_email_override":"orders@quantify.io"}
    ;
    const out = try generateFromJson(a, input);
    defer a.free(out);
    try testing.expect(fieldEquals(out, "\"from_email\":\"orders@quantify.io\""));
    try testing.expect(!fieldEquals(out, "CONFIGURE-ME.invalid"));
}

test "html escaping of customer name prevents markup injection" {
    const a = testing.allocator;
    const input =
        \\{"session_id":"cs_e1","app":"exact","customer_email":"x@y.com",
        \\ "customer_name":"<script>alert(1)</script>","amount_total":1000,
        \\ "currency":"gbp","credits":10}
    ;
    const out = try generateFromJson(a, input);
    defer a.free(out);
    // Raw <script> must not appear in the HTML body; escaped form must.
    try testing.expect(!fieldEquals(out, "<script>"));
    try testing.expect(fieldEquals(out, "&lt;script&gt;"));
}

test "invalid json returns error" {
    const a = testing.allocator;
    try testing.expectError(error.InvalidJson, generateFromJson(a, "not json"));
    try testing.expectError(error.InvalidJson, generateFromJson(a, "[1,2,3]"));
}

test "order ref is deterministic for same session" {
    const a = testing.allocator;
    const input =
        \\{"session_id":"cs_test_DETERMINISTIC123","app":"exact",
        \\ "customer_email":"x@y.com","amount_total":100,"currency":"gbp","credits":5}
    ;
    const out1 = try generateFromJson(a, input);
    defer a.free(out1);
    const out2 = try generateFromJson(a, input);
    defer a.free(out2);
    try testing.expectEqualStrings(out1, out2);
}
