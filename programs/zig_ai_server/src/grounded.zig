// Google grounded search — POST /qai/v1/search/google
//
// Wire-compatible with the Go /qai/v1/search/google handler. Fires a Gemini
// Flash request with the built-in google_search tool and returns the grounded
// answer plus structured metadata (citations, the ToS-required
// search-entry-point HTML, executed search queries, supports).
//
//   request:  { query }
//   response: { answer, citations[], search_entry_point, web_search_queries[],
//               supports[], cost_ticks, balance_after }
//
// Cost model (premium search): billed per EXECUTED query —
// googleGroundedCostPerQueryUSD ($0.035) × len(web_search_queries). A single
// prompt may fire 0 (no grounding needed → free), 1, or several queries; we
// bill the actual count, matching how Google bills us. We reserve a
// pessimistic 3-query ceiling up-front and settle to the actual count after
// the call. Integer math throughout.
//
// Auth: GEMINI_API_KEY (env). The key is passed in the URL query string, as
// the generativelanguage.googleapis.com API requires.

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
// $0.035 per executed query.
const COST_PER_QUERY_TICKS: i64 = 350_000_000;
const GROUNDED_MODEL = "gemini-2.5-flash";
const GROUNDED_MODEL_BILLING = "gemini-2.5-flash-grounded";
const MAX_OUTPUT_TOKENS: u32 = 2048;

const GoogleRequest = struct {
    query: []const u8 = "",
};

pub fn handle(
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

    const parsed = std.json.parseFromSlice(GoogleRequest, allocator, body, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch {
        return errResp(.bad_request, "invalid JSON body");
    };
    defer parsed.deinit();
    const req = parsed.value;
    if (req.query.len == 0) return errResp(.bad_request, "query is required");

    const api_key = hs.ai.getApiKeyFromEnv(environ_map, "GEMINI_API_KEY") catch {
        return errResp(.service_unavailable, "google grounded search not configured (GEMINI_API_KEY unset)");
    };

    // Pre-flight reserve: pessimistic 3-query ceiling. Settled to the actual
    // executed-query count after the call (0 queries → fully refunded).
    const margin_bps: i64 = if (auth) |a| @intCast(a.account.tier.marginBps()) else 0;
    const preflight_cost = 3 * COST_PER_QUERY_TICKS;
    const preflight_ticks = preflight_cost + @divFloor(preflight_cost * margin_bps, 10000);

    var reservation_id: ?u64 = null;
    if (store) |s| if (auth) |a| if (io) |io_handle| {
        if (a.account.role != .admin) {
            reservation_id = s.reserve(
                io_handle,
                a.account.id.slice(),
                a.key_hash,
                @max(preflight_ticks, 1000),
                "/qai/v1/search/google",
                GROUNDED_MODEL_BILLING,
            ) catch |err| switch (err) {
                error.InsufficientBalance => return errResp(.payment_required, "Account balance is too low for grounded search"),
                else => return errResp(.internal_server_error, "Failed to reserve credits"),
            };
        }
    };

    // Build the generateContent request body.
    const request_body = buildBody(allocator, req.query) catch {
        rollback(store, io, reservation_id);
        return errResp(.internal_server_error, "Failed to build provider request");
    };
    defer allocator.free(request_body);

    const url = std.fmt.allocPrint(
        allocator,
        "https://generativelanguage.googleapis.com/v1beta/models/{s}:generateContent?key={s}",
        .{ GROUNDED_MODEL, api_key },
    ) catch {
        rollback(store, io, reservation_id);
        return errResp(.internal_server_error, "alloc failed");
    };
    defer allocator.free(url);

    var http_client = hs.HttpClient.init(allocator) catch {
        rollback(store, io, reservation_id);
        return errResp(.internal_server_error, "Failed to initialize HTTP client");
    };
    defer http_client.deinit();

    const headers = [_]http.Header{
        .{ .name = "Content-Type", .value = "application/json" },
    };

    var resp = http_client.post(url, &headers, request_body) catch {
        rollback(store, io, reservation_id);
        return errResp(.bad_gateway, "Gemini grounded search request failed");
    };
    defer resp.deinit();

    if (resp.status != .ok) {
        rollback(store, io, reservation_id);
        return errResp(if (resp.status == .too_many_requests) .too_many_requests else .bad_gateway, "Gemini rejected the grounded search request");
    }

    const result = parseGrounded(allocator, resp.body) catch {
        rollback(store, io, reservation_id);
        return errResp(.bad_gateway, "Could not parse Gemini grounded response");
    };
    defer result.deinit();

    // Bill per executed query. Zero queries → zero cost (commit 0 refunds the
    // whole reservation).
    const query_count: i64 = @intCast(result.value.web_search_queries.len);
    const cost = query_count * COST_PER_QUERY_TICKS;
    const margin = @divFloor(cost * margin_bps, 10000);

    var balance_after: i64 = 0;
    if (reservation_id) |rid| if (store) |s| if (io) |io_handle| {
        s.commitReservation(io_handle, rid, cost, margin) catch {};
    };
    if (auth) |a| if (store) |s| {
        if (s.getAccount(a.account.id.slice())) |acct| balance_after = acct.balance_ticks;
    };

    if (ledger) |l| if (io) |io_handle| {
        const acct_id = if (auth) |a| a.account.id.slice() else "anonymous";
        const key_pfx = if (auth) |a| a.key.prefix.slice() else "none";
        l.recordBilling(io_handle, acct_id, key_pfx, cost, margin, balance_after, "/qai/v1/search/google", GROUNDED_MODEL_BILLING, 0, 0, 0);
    };

    const r = result.value;
    const out = std.json.Stringify.valueAlloc(allocator, .{
        .answer = r.answer,
        .citations = r.citations,
        .search_entry_point = r.search_entry_point,
        .web_search_queries = r.web_search_queries,
        .supports = r.supports,
        .cost_ticks = cost + margin,
        .balance_after = balance_after,
    }, .{}) catch {
        return errResp(.internal_server_error, "Failed to build response JSON");
    };
    return .{ .status = .ok, .body = out };
}

fn buildBody(allocator: std.mem.Allocator, query: []const u8) ![]u8 {
    // {contents:[{parts:[{text:query}]}], tools:[{google_search:{}}],
    //  generationConfig:{maxOutputTokens:N}} — query escaped by Stringify.
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    var jw: std.json.Stringify = .{ .writer = &aw.writer, .options = .{} };

    try jw.beginObject();
    try jw.objectField("contents");
    try jw.beginArray();
    try jw.beginObject();
    try jw.objectField("parts");
    try jw.beginArray();
    try jw.beginObject();
    try jw.objectField("text");
    try jw.write(query);
    try jw.endObject();
    try jw.endArray();
    try jw.endObject();
    try jw.endArray();

    try jw.objectField("tools");
    try jw.beginArray();
    try jw.beginObject();
    try jw.objectField("google_search");
    try jw.beginObject();
    try jw.endObject();
    try jw.endObject();
    try jw.endArray();

    try jw.objectField("generationConfig");
    try jw.beginObject();
    try jw.objectField("maxOutputTokens");
    try jw.write(MAX_OUTPUT_TOKENS);
    try jw.endObject();

    try jw.endObject();
    return aw.toOwnedSlice();
}

// ── Response reshaping ───────────────────────────────────────────────

const Citation = struct {
    url: []const u8,
    title: []const u8,
};

const Support = struct {
    start_index: i64,
    end_index: i64,
    text: []const u8,
    grounding_chunk_indices: []const i64,
};

const GroundedResult = struct {
    answer: []const u8,
    citations: []const Citation,
    search_entry_point: []const u8,
    web_search_queries: []const []const u8,
    supports: []const Support,
};

/// Parse the Gemini generateContent grounded response into the wire shape the
/// Go handler returns. Returns a Parsed-like wrapper so the caller can free
/// the backing arena after serialization.
const ParsedGrounded = struct {
    arena: *std.heap.ArenaAllocator,
    value: GroundedResult,

    fn deinit(self: ParsedGrounded) void {
        const child = self.arena.child_allocator;
        self.arena.deinit();
        child.destroy(self.arena);
    }
};

fn parseGrounded(allocator: std.mem.Allocator, body: []const u8) !ParsedGrounded {
    const arena = try allocator.create(std.heap.ArenaAllocator);
    errdefer allocator.destroy(arena);
    arena.* = .init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();

    const Raw = struct {
        candidates: []const struct {
            content: struct {
                parts: []const struct { text: []const u8 = "" } = &.{},
            } = .{},
            groundingMetadata: ?struct {
                webSearchQueries: []const []const u8 = &.{},
                searchEntryPoint: ?struct { renderedContent: []const u8 = "" } = null,
                groundingChunks: []const struct {
                    web: ?struct {
                        uri: []const u8 = "",
                        title: []const u8 = "",
                    } = null,
                } = &.{},
                groundingSupports: []const struct {
                    segment: struct {
                        startIndex: i64 = 0,
                        endIndex: i64 = 0,
                        text: []const u8 = "",
                    } = .{},
                    groundingChunkIndices: []const i64 = &.{},
                } = &.{},
            } = null,
        } = &.{},
    };

    const parsed = try std.json.parseFromSliceLeaky(Raw, a, body, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });

    var result: GroundedResult = .{
        .answer = "",
        .citations = &.{},
        .search_entry_point = "",
        .web_search_queries = &.{},
        .supports = &.{},
    };

    if (parsed.candidates.len == 0) {
        // Safety-blocked or empty — soft-empty result (matches Go).
        return .{ .arena = arena, .value = result };
    }
    const cand = parsed.candidates[0];

    // Concatenate text parts.
    var answer: std.ArrayListUnmanaged(u8) = .empty;
    for (cand.content.parts) |p| try answer.appendSlice(a, p.text);
    result.answer = try answer.toOwnedSlice(a);

    if (cand.groundingMetadata) |gm| {
        result.web_search_queries = gm.webSearchQueries;
        if (gm.searchEntryPoint) |sep| result.search_entry_point = sep.renderedContent;

        var citations: std.ArrayListUnmanaged(Citation) = .empty;
        for (gm.groundingChunks) |chunk| {
            if (chunk.web) |w| {
                if (w.uri.len > 0) try citations.append(a, .{ .url = w.uri, .title = w.title });
            }
        }
        result.citations = try citations.toOwnedSlice(a);

        var supports: std.ArrayListUnmanaged(Support) = .empty;
        for (gm.groundingSupports) |sup| {
            try supports.append(a, .{
                .start_index = sup.segment.startIndex,
                .end_index = sup.segment.endIndex,
                .text = sup.segment.text,
                .grounding_chunk_indices = sup.groundingChunkIndices,
            });
        }
        result.supports = try supports.toOwnedSlice(a);
    }

    return .{ .arena = arena, .value = result };
}

fn rollback(store: ?*store_mod.Store, io: ?std.Io, reservation_id: ?u64) void {
    if (reservation_id) |rid| if (store) |s| if (io) |io_handle| s.rollbackReservation(io_handle, rid);
}

fn errResp(status: http.Status, message: []const u8) Response {
    _ = message;
    return switch (status) {
        .bad_request => .{ .status = .bad_request, .body = "{\"error\":\"invalid_request\",\"message\":\"Grounded search request rejected\"}" },
        .payment_required => .{ .status = .payment_required, .body = "{\"error\":\"insufficient_balance\",\"message\":\"Account balance is too low for grounded search\"}" },
        .service_unavailable => .{ .status = .service_unavailable, .body = "{\"error\":\"service_unavailable\",\"message\":\"Google grounded search is not configured on this server\"}" },
        .too_many_requests => .{ .status = .too_many_requests, .body = "{\"error\":\"rate_limited\",\"message\":\"Gemini rate limit exceeded\"}" },
        .bad_gateway => .{ .status = .bad_gateway, .body = "{\"error\":\"provider_error\",\"message\":\"Gemini grounded search request failed\"}" },
        else => .{ .status = .internal_server_error, .body = "{\"error\":\"internal\",\"message\":\"Grounded search failed\"}" },
    };
}
