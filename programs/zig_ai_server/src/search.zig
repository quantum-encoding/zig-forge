// Search endpoints — Brave Search API gateway
//
//   POST /qai/v1/search/web      → Brave web search   (flat $0.005)
//   POST /qai/v1/search/context  → Brave LLM context  (flat $0.010)
//   POST /qai/v1/search/answer   → Brave answers       (flat $0.020)
//
// Wire-compatible with the Go /qai/v1/search/* handlers. Each handler reads a
// small JSON request, calls the matching Brave endpoint, and passes the Brave
// response body straight through to the client (Brave's wire shape is exactly
// what the Go SDK structs re-encode, so a pass-through is faithful and avoids
// re-modelling Brave's large response schema).
//
// Billing: flat per-call USD rate × TICKS_PER_USD, plus the account tier's
// margin. Cost is known up-front, so we reserve the exact amount and commit
// it (mirrors images.zig's reserve→commit, with estimate == actual). All
// integer math (Batch 31 FLOAT-OBSESSION).
//
// Auth keys (env): BRAVE_SEARCH_API_KEY for web+context, BRAVE_ANSWERS_KEY for
// answers (falls back to the search key when unset — matches the Go
// brave.NewWithKeys default).

const std = @import("std");
const http = std.http;
const hs = @import("http-sentinel");
const json_util = @import("json.zig");
const router = @import("router.zig");
const security = @import("security.zig");
const store_mod = @import("store/store.zig");
const types = @import("store/types.zig");
const ledger_mod = @import("ledger.zig");
const Response = router.Response;

const TICKS_PER_USD: i64 = 10_000_000_000;
const BRAVE_BASE = "https://api.search.brave.com";

// Flat per-call costs in ticks (USD × TICKS_PER_USD), matching the Go rates.
const COST_WEB_TICKS: i64 = 50_000_000; // $0.005
const COST_CONTEXT_TICKS: i64 = 100_000_000; // $0.010
const COST_ANSWER_TICKS: i64 = 200_000_000; // $0.020

const Kind = enum { web, context, answer };

// ── Public entry points ─────────────────────────────────────────────

pub fn handleWeb(
    request: *http.Server.Request,
    allocator: std.mem.Allocator,
    environ_map: *const std.process.Environ.Map,
    io: ?std.Io,
    store: ?*store_mod.Store,
    auth: ?*const types.AuthContext,
    ledger: ?*ledger_mod.Ledger,
) Response {
    return handleSearch(.web, request, allocator, environ_map, io, store, auth, ledger);
}

pub fn handleContext(
    request: *http.Server.Request,
    allocator: std.mem.Allocator,
    environ_map: *const std.process.Environ.Map,
    io: ?std.Io,
    store: ?*store_mod.Store,
    auth: ?*const types.AuthContext,
    ledger: ?*ledger_mod.Ledger,
) Response {
    return handleSearch(.context, request, allocator, environ_map, io, store, auth, ledger);
}

pub fn handleAnswer(
    request: *http.Server.Request,
    allocator: std.mem.Allocator,
    environ_map: *const std.process.Environ.Map,
    io: ?std.Io,
    store: ?*store_mod.Store,
    auth: ?*const types.AuthContext,
    ledger: ?*ledger_mod.Ledger,
) Response {
    return handleSearch(.answer, request, allocator, environ_map, io, store, auth, ledger);
}

// ── Request shapes ───────────────────────────────────────────────────

const WebRequest = struct {
    query: []const u8 = "",
    count: ?u32 = null,
    offset: ?u32 = null,
    country: ?[]const u8 = null,
    language: ?[]const u8 = null,
    freshness: ?[]const u8 = null,
    safesearch: ?[]const u8 = null,
};

const ContextRequest = struct {
    query: []const u8 = "",
    count: ?u32 = null,
    country: ?[]const u8 = null,
    language: ?[]const u8 = null,
    freshness: ?[]const u8 = null,
};

const ChatMessage = struct {
    role: []const u8,
    content: []const u8,
};

const AnswerRequest = struct {
    messages: []const ChatMessage = &.{},
    model: ?[]const u8 = null,
};

// ── Core ─────────────────────────────────────────────────────────────

fn handleSearch(
    kind: Kind,
    request: *http.Server.Request,
    allocator: std.mem.Allocator,
    environ_map: *const std.process.Environ.Map,
    io: ?std.Io,
    store: ?*store_mod.Store,
    auth: ?*const types.AuthContext,
    ledger: ?*ledger_mod.Ledger,
) Response {
    const body = json_util.readBody(request, allocator, security.Limits.max_chat_body) catch {
        return errResp(.bad_request, "Failed to read request body");
    };
    defer allocator.free(body);
    if (body.len == 0) return errResp(.bad_request, "Empty request body");

    // Resolve the Brave subscription key for this endpoint.
    const env_name = if (kind == .answer) "BRAVE_ANSWERS_KEY" else "BRAVE_SEARCH_API_KEY";
    const key = hs.ai.getApiKeyFromEnv(environ_map, env_name) catch
        hs.ai.getApiKeyFromEnv(environ_map, "BRAVE_SEARCH_API_KEY") catch {
            return errResp(.service_unavailable, "search not configured (BRAVE_SEARCH_API_KEY unset)");
        };

    // Build the upstream request (URL + optional POST body) per endpoint.
    var post_body: ?[]u8 = null;
    defer if (post_body) |pb| allocator.free(pb);

    const url: []u8 = switch (kind) {
        .web => buildWebUrl(allocator, body) catch |e| return buildErr(e),
        .context => buildContextUrl(allocator, body) catch |e| return buildErr(e),
        .answer => blk: {
            const built = buildAnswerBody(allocator, body) catch |e| return buildErr(e);
            post_body = built;
            break :blk allocator.dupe(u8, BRAVE_BASE ++ "/res/v1/chat/completions") catch return errResp(.internal_server_error, "alloc failed");
        },
    };
    defer allocator.free(url);

    const cost_ticks: i64 = switch (kind) {
        .web => COST_WEB_TICKS,
        .context => COST_CONTEXT_TICKS,
        .answer => COST_ANSWER_TICKS,
    };
    const margin_ticks: i64 = if (auth) |a|
        @divFloor(cost_ticks * @as(i64, a.account.tier.marginBps()), 10000)
    else
        0;
    const reserve_ticks = cost_ticks + margin_ticks;

    // Reserve the (known) cost. Skip for admin / unauthenticated / test.
    var reservation_id: ?u64 = null;
    if (store) |s| if (auth) |a| if (io) |io_handle| {
        if (a.account.role != .admin) {
            reservation_id = s.reserve(
                io_handle,
                a.account.id.slice(),
                a.key_hash,
                reserve_ticks,
                endpointPath(kind),
                braveModelName(kind),
            ) catch |err| switch (err) {
                error.InsufficientBalance => return errResp(.payment_required, "Account balance is too low for this search"),
                else => return errResp(.internal_server_error, "Failed to reserve credits"),
            };
        }
    };

    // Call Brave.
    var http_client = hs.HttpClient.init(allocator) catch {
        rollback(store, io, reservation_id);
        return errResp(.internal_server_error, "Failed to initialize HTTP client");
    };
    defer http_client.deinit();

    const headers = [_]http.Header{
        .{ .name = "X-Subscription-Token", .value = key },
        .{ .name = "Accept", .value = "application/json" },
        .{ .name = "Content-Type", .value = "application/json" },
    };

    var resp = blk: {
        if (post_body) |pb| {
            break :blk http_client.post(url, &headers, pb) catch {
                rollback(store, io, reservation_id);
                return errResp(.bad_gateway, "Brave request failed");
            };
        } else {
            break :blk http_client.get(url, headers[0..2]) catch {
                rollback(store, io, reservation_id);
                return errResp(.bad_gateway, "Brave request failed");
            };
        }
    };
    defer resp.deinit();

    if (resp.status != .ok) {
        rollback(store, io, reservation_id);
        return errResp(if (resp.status == .too_many_requests) .too_many_requests else .bad_gateway, "Brave rejected the request");
    }

    // Own the response body before resp.deinit() frees it.
    const out_body = allocator.dupe(u8, resp.body) catch {
        rollback(store, io, reservation_id);
        return errResp(.internal_server_error, "Failed to buffer search response");
    };

    // Commit billing (estimate == actual for flat-rate search).
    var balance_after: i64 = 0;
    if (reservation_id) |rid| if (store) |s| if (io) |io_handle| {
        s.commitReservation(io_handle, rid, cost_ticks, margin_ticks) catch {};
    };
    if (auth) |a| if (store) |s| {
        if (s.getAccount(a.account.id.slice())) |acct| balance_after = acct.balance_ticks;
    };

    if (ledger) |l| if (io) |io_handle| {
        const acct_id = if (auth) |a| a.account.id.slice() else "anonymous";
        const key_pfx = if (auth) |a| a.key.prefix.slice() else "none";
        l.recordBilling(
            io_handle, acct_id, key_pfx,
            cost_ticks, margin_ticks, balance_after,
            endpointPath(kind), braveModelName(kind),
            0, 0, 0,
        );
    };

    return .{ .status = .ok, .body = out_body };
}

// ── Upstream URL / body builders ─────────────────────────────────────

fn buildWebUrl(allocator: std.mem.Allocator, body: []const u8) ![]u8 {
    const parsed = std.json.parseFromSlice(WebRequest, allocator, body, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch return error.BadJson;
    defer parsed.deinit();
    const req = parsed.value;
    if (req.query.len == 0) return error.MissingQuery;

    var qb: QueryBuilder = .init(allocator, BRAVE_BASE ++ "/res/v1/web/search");
    defer qb.deinit();
    try qb.addStr("q", req.query);
    if (req.count) |c| try qb.addInt("count", c);
    if (req.offset) |o| try qb.addInt("offset", o);
    if (req.country) |v| try qb.addStr("country", v);
    if (req.language) |v| try qb.addStr("ui_lang", v); // Go maps language → ui_lang
    if (req.freshness) |v| try qb.addStr("freshness", v);
    if (req.safesearch) |v| try qb.addStr("safesearch", v);
    return qb.finish();
}

fn buildContextUrl(allocator: std.mem.Allocator, body: []const u8) ![]u8 {
    const parsed = std.json.parseFromSlice(ContextRequest, allocator, body, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch return error.BadJson;
    defer parsed.deinit();
    const req = parsed.value;
    if (req.query.len == 0) return error.MissingQuery;

    var qb: QueryBuilder = .init(allocator, BRAVE_BASE ++ "/res/v1/llm/context");
    defer qb.deinit();
    try qb.addStr("q", req.query);
    if (req.count) |c| try qb.addInt("count", c);
    if (req.country) |v| try qb.addStr("country", v);
    if (req.language) |v| try qb.addStr("ui_lang", v);
    if (req.freshness) |v| try qb.addStr("freshness", v);
    return qb.finish();
}

fn buildAnswerBody(allocator: std.mem.Allocator, body: []const u8) ![]u8 {
    const parsed = std.json.parseFromSlice(AnswerRequest, allocator, body, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch return error.BadJson;
    defer parsed.deinit();
    const req = parsed.value;
    if (req.messages.len == 0) return error.MissingMessages;

    // Brave /res/v1/chat/completions: {model, messages, stream:false}.
    // All strings escaped by std.json.Stringify (JSON-IN-FMT).
    return std.json.Stringify.valueAlloc(allocator, .{
        .model = req.model orelse "brave",
        .messages = req.messages,
        .stream = false,
    }, .{});
}

// ── Small helpers ────────────────────────────────────────────────────

fn endpointPath(kind: Kind) []const u8 {
    return switch (kind) {
        .web => "/qai/v1/search/web",
        .context => "/qai/v1/search/context",
        .answer => "/qai/v1/search/answer",
    };
}

fn braveModelName(kind: Kind) []const u8 {
    return switch (kind) {
        .web => "brave-web-search",
        .context => "brave-llm-context",
        .answer => "brave-answer",
    };
}

fn rollback(store: ?*store_mod.Store, io: ?std.Io, reservation_id: ?u64) void {
    if (reservation_id) |rid| if (store) |s| if (io) |io_handle| s.rollbackReservation(io_handle, rid);
}

fn buildErr(e: anyerror) Response {
    return switch (e) {
        error.MissingQuery => errResp(.bad_request, "query is required"),
        error.MissingMessages => errResp(.bad_request, "messages is required"),
        error.BadJson => errResp(.bad_request, "invalid JSON body"),
        else => errResp(.internal_server_error, "Failed to build search request"),
    };
}

fn errResp(status: http.Status, message: []const u8) Response {
    _ = message;
    return switch (status) {
        .bad_request => .{ .status = .bad_request, .body = "{\"error\":\"invalid_request\",\"message\":\"Search request rejected\"}" },
        .payment_required => .{ .status = .payment_required, .body = "{\"error\":\"insufficient_balance\",\"message\":\"Account balance is too low for this search\"}" },
        .service_unavailable => .{ .status = .service_unavailable, .body = "{\"error\":\"service_unavailable\",\"message\":\"Search is not configured on this server\"}" },
        .too_many_requests => .{ .status = .too_many_requests, .body = "{\"error\":\"rate_limited\",\"message\":\"Brave rate limit exceeded\"}" },
        .bad_gateway => .{ .status = .bad_gateway, .body = "{\"error\":\"provider_error\",\"message\":\"Brave search request failed\"}" },
        else => .{ .status = .internal_server_error, .body = "{\"error\":\"internal\",\"message\":\"Search request failed\"}" },
    };
}

// ── URL query builder with percent-encoding ──────────────────────────
//
// The `q` value is caller-controlled and routinely contains spaces, `&`,
// `=`, etc. — it MUST be percent-encoded or it breaks the query string (and
// could smuggle extra params). We encode everything except RFC 3986
// unreserved characters.

const QueryBuilder = struct {
    buf: std.ArrayListUnmanaged(u8) = .empty,
    allocator: std.mem.Allocator,
    has_query: bool = false,

    fn init(allocator: std.mem.Allocator, base_with_path: []const u8) QueryBuilder {
        var qb: QueryBuilder = .{ .allocator = allocator };
        qb.buf.appendSlice(allocator, base_with_path) catch {};
        return qb;
    }

    fn deinit(self: *QueryBuilder) void {
        self.buf.deinit(self.allocator);
    }

    fn sep(self: *QueryBuilder) !void {
        try self.buf.append(self.allocator, if (self.has_query) '&' else '?');
        self.has_query = true;
    }

    fn addStr(self: *QueryBuilder, name: []const u8, value: []const u8) !void {
        try self.sep();
        try self.buf.appendSlice(self.allocator, name);
        try self.buf.append(self.allocator, '=');
        try percentEncode(&self.buf, self.allocator, value);
    }

    fn addInt(self: *QueryBuilder, name: []const u8, value: u32) !void {
        try self.sep();
        try self.buf.appendSlice(self.allocator, name);
        try self.buf.append(self.allocator, '=');
        var num: [10]u8 = undefined;
        const s = try std.fmt.bufPrint(&num, "{d}", .{value});
        try self.buf.appendSlice(self.allocator, s);
    }

    /// Hand ownership of the assembled URL to the caller.
    fn finish(self: *QueryBuilder) ![]u8 {
        return self.buf.toOwnedSlice(self.allocator);
    }
};

fn percentEncode(buf: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, value: []const u8) !void {
    const hex = "0123456789ABCDEF";
    for (value) |c| {
        if (isUnreserved(c)) {
            try buf.append(allocator, c);
        } else {
            try buf.append(allocator, '%');
            try buf.append(allocator, hex[c >> 4]);
            try buf.append(allocator, hex[c & 0x0F]);
        }
    }
}

fn isUnreserved(c: u8) bool {
    return switch (c) {
        'A'...'Z', 'a'...'z', '0'...'9', '-', '_', '.', '~' => true,
        else => false,
    };
}
