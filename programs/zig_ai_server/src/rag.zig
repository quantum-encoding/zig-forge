// RAG endpoints — Vertex AI RAG Engine
//
//   GET  /qai/v1/rag/corpora   list available corpora (free)
//   POST /qai/v1/rag/search    retrieve contexts for a query (flat $0.002)
//
// Wire-compatible with the Go /qai/v1/rag/* handlers. Both use the server's
// existing GCP credentials (server_gcp) to call the Vertex aiplatform API —
// no extra service wiring needed. The Vertex RAG store only supports one
// corpus per query, so search lists corpora, filters, queries each, merges,
// sorts by score, and returns the top-k.
//
// `rag/surreal/*` and `rag/collections/*` proxy to a separate external RAG
// service and remain stubs here.
//
// apiBase: https://{loc}-aiplatform.googleapis.com/v1/projects/{project}/locations/{loc}
// location defaults to us-central1 (override with QAI_RAG_LOCATION).

const std = @import("std");
const http = std.http;
const json_util = @import("json.zig");
const router = @import("router.zig");
const security = @import("security.zig");
const gcp = @import("gcp.zig");
const store_mod = @import("store/store.zig");
const types = @import("store/types.zig");
const ledger_mod = @import("ledger.zig");
const Response = router.Response;

const COST_SEARCH_TICKS: i64 = 20_000_000; // $0.002
const DEFAULT_TOP_K: u32 = 10;

const Corpus = struct {
    name: []const u8 = "",
    displayName: []const u8 = "",
    description: []const u8 = "",
    state: []const u8 = "",
};

const ContextResult = struct {
    source_uri: []const u8,
    source_name: []const u8,
    text: []const u8,
    score: f64,
    distance: f64,
};

// ── GET /qai/v1/rag/corpora ──────────────────────────────────────────

pub fn handleCorpora(
    allocator: std.mem.Allocator,
    environ_map: *const std.process.Environ.Map,
    gcp_ctx: ?*gcp.GcpContext,
) Response {
    const ctx = gcp_ctx orelse return errResp(.service_unavailable, "RAG unavailable: server has no GCP backend");

    const api_base = buildApiBase(allocator, ctx.project_id, environ_map) catch {
        return errResp(.internal_server_error, "alloc failed");
    };
    defer allocator.free(api_base);

    const corpora = listCorpora(allocator, ctx, api_base) catch {
        return errResp(.bad_gateway, "list corpora failed");
    };
    defer freeCorpora(allocator, corpora);

    const out = std.json.Stringify.valueAlloc(allocator, .{
        .corpora = corpora,
    }, .{}) catch {
        return errResp(.internal_server_error, "Failed to build response JSON");
    };
    return .{ .status = .ok, .body = out };
}

// ── POST /qai/v1/rag/search ──────────────────────────────────────────

const SearchRequest = struct {
    query: []const u8 = "",
    corpus: ?[]const u8 = null,
    top_k: ?u32 = null,
};

pub fn handleSearch(
    request: *http.Server.Request,
    allocator: std.mem.Allocator,
    environ_map: *const std.process.Environ.Map,
    io: ?std.Io,
    store: ?*store_mod.Store,
    auth: ?*const types.AuthContext,
    ledger: ?*ledger_mod.Ledger,
    gcp_ctx: ?*gcp.GcpContext,
) Response {
    const ctx = gcp_ctx orelse return errResp(.service_unavailable, "RAG unavailable: server has no GCP backend");

    const body = json_util.readBody(request, allocator, security.Limits.max_chat_body) catch {
        return errResp(.bad_request, "Failed to read request body");
    };
    defer allocator.free(body);
    if (body.len == 0) return errResp(.bad_request, "Empty request body");

    const parsed = std.json.parseFromSlice(SearchRequest, allocator, body, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch {
        return errResp(.bad_request, "invalid JSON body");
    };
    defer parsed.deinit();
    const req = parsed.value;
    if (req.query.len == 0) return errResp(.bad_request, "query is required");

    const api_base = buildApiBase(allocator, ctx.project_id, environ_map) catch {
        return errResp(.internal_server_error, "alloc failed");
    };
    defer allocator.free(api_base);

    const all_corpora = listCorpora(allocator, ctx, api_base) catch {
        return errResp(.bad_gateway, "list corpora failed");
    };
    defer freeCorpora(allocator, all_corpora);

    // Resolve which corpora to search: explicit filter or all ACTIVE.
    var search_corpora: std.ArrayListUnmanaged(Corpus) = .empty;
    defer search_corpora.deinit(allocator);
    if (req.corpus) |filter_raw| {
        const filter = std.mem.trim(u8, filter_raw, " \t");
        for (all_corpora) |c| {
            if (corpusMatches(c, filter)) search_corpora.append(allocator, c) catch {};
        }
        if (search_corpora.items.len == 0) {
            return errResp(.bad_request, "no corpus matching the requested filter");
        }
    } else {
        for (all_corpora) |c| {
            if (c.state.len == 0 or std.mem.eql(u8, c.state, "ACTIVE")) search_corpora.append(allocator, c) catch {};
        }
    }

    const top_k = req.top_k orelse DEFAULT_TOP_K;

    // Reserve flat search cost.
    const margin_bps: i64 = if (auth) |a| @intCast(a.account.tier.marginBps()) else 0;
    const cost = COST_SEARCH_TICKS;
    const margin = @divFloor(cost * margin_bps, 10000);
    var reservation_id: ?u64 = null;
    if (store) |s| if (auth) |a| if (io) |io_handle| {
        if (a.account.role != .admin) {
            reservation_id = s.reserve(io_handle, a.account.id.slice(), a.key_hash, @max(cost + margin, 1000), "/qai/v1/rag/search", "vertex-rag") catch |err| switch (err) {
                error.InsufficientBalance => return errResp(.payment_required, "Account balance is too low for RAG search"),
                else => return errResp(.internal_server_error, "Failed to reserve credits"),
            };
        }
    };

    // Query each corpus (Vertex RAG: one corpus per retrieveContexts call).
    var results: std.ArrayListUnmanaged(ContextResult) = .empty;
    defer results.deinit(allocator);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const ctx_arena = arena.allocator();

    const url = std.fmt.allocPrint(allocator, "{s}:retrieveContexts", .{api_base}) catch {
        rollback(store, io, reservation_id);
        return errResp(.internal_server_error, "alloc failed");
    };
    defer allocator.free(url);

    for (search_corpora.items) |corpus| {
        const q_body = buildRetrieveBody(allocator, corpus.name, req.query, top_k) catch continue;
        defer allocator.free(q_body);

        var resp = ctx.post(url, q_body) catch continue;
        defer resp.deinit();
        if (resp.status != .ok) continue;

        appendContexts(ctx_arena, &results, allocator, resp.body) catch continue;
    }

    // Sort by score descending, take top_k.
    std.mem.sort(ContextResult, results.items, {}, scoreDesc);
    const final = if (results.items.len > top_k) results.items[0..top_k] else results.items;

    // Commit flat cost.
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
        l.recordBilling(io_handle, acct_id, key_pfx, cost, margin, balance_after, "/qai/v1/rag/search", "vertex-rag", 0, 0, 0);
    };

    // Corpus display names searched.
    var names: std.ArrayListUnmanaged([]const u8) = .empty;
    defer names.deinit(allocator);
    for (search_corpora.items) |c| names.append(allocator, c.displayName) catch {};

    const out = std.json.Stringify.valueAlloc(allocator, .{
        .results = final,
        .query = req.query,
        .corpora = names.items,
        .cost_ticks = cost + margin,
        .balance_after = balance_after,
    }, .{}) catch {
        return errResp(.internal_server_error, "Failed to build response JSON");
    };
    return .{ .status = .ok, .body = out };
}

// ── Vertex helpers ───────────────────────────────────────────────────

fn buildApiBase(allocator: std.mem.Allocator, project: []const u8, environ_map: *const std.process.Environ.Map) ![]u8 {
    const loc = environ_map.get("QAI_RAG_LOCATION") orelse "us-central1";
    return std.fmt.allocPrint(allocator, "https://{s}-aiplatform.googleapis.com/v1/projects/{s}/locations/{s}", .{ loc, project, loc });
}

/// List all RAG corpora, following pagination so nothing is silently dropped.
fn listCorpora(allocator: std.mem.Allocator, ctx: *gcp.GcpContext, api_base: []const u8) ![]Corpus {
    var out: std.ArrayListUnmanaged(Corpus) = .empty;
    errdefer freeCorporaList(allocator, &out);

    var page_token: []const u8 = "";
    var token_owned: ?[]u8 = null;
    defer if (token_owned) |t| allocator.free(t);

    var pages: u32 = 0;
    while (pages < 100) : (pages += 1) { // hard ceiling against a runaway loop
        const url = if (page_token.len == 0)
            try std.fmt.allocPrint(allocator, "{s}/ragCorpora?pageSize=100", .{api_base})
        else
            try std.fmt.allocPrint(allocator, "{s}/ragCorpora?pageSize=100&pageToken={s}", .{ api_base, page_token });
        defer allocator.free(url);

        var resp = try ctx.get(url);
        defer resp.deinit();
        if (resp.status != .ok) return error.RagListFailed;

        const Page = struct {
            ragCorpora: []const Corpus = &.{},
            nextPageToken: []const u8 = "",
        };
        const parsed = try std.json.parseFromSlice(Page, allocator, resp.body, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        });
        defer parsed.deinit();

        for (parsed.value.ragCorpora) |c| {
            try out.append(allocator, .{
                .name = try allocator.dupe(u8, c.name),
                .displayName = try allocator.dupe(u8, c.displayName),
                .description = try allocator.dupe(u8, c.description),
                .state = try allocator.dupe(u8, c.state),
            });
        }

        if (token_owned) |t| {
            allocator.free(t);
            token_owned = null;
        }
        if (parsed.value.nextPageToken.len == 0) break;
        token_owned = try allocator.dupe(u8, parsed.value.nextPageToken);
        page_token = token_owned.?;
    }

    return out.toOwnedSlice(allocator);
}

fn freeCorpora(allocator: std.mem.Allocator, corpora: []Corpus) void {
    for (corpora) |c| {
        allocator.free(c.name);
        allocator.free(c.displayName);
        allocator.free(c.description);
        allocator.free(c.state);
    }
    allocator.free(corpora);
}

fn freeCorporaList(allocator: std.mem.Allocator, list: *std.ArrayListUnmanaged(Corpus)) void {
    for (list.items) |c| {
        allocator.free(c.name);
        allocator.free(c.displayName);
        allocator.free(c.description);
        allocator.free(c.state);
    }
    list.deinit(allocator);
}

fn buildRetrieveBody(allocator: std.mem.Allocator, corpus_name: []const u8, query: []const u8, top_k: u32) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, .{
        .vertexRagStore = .{
            .ragResources = .{
                .{ .ragCorpus = corpus_name },
            },
        },
        .query = .{
            .text = query,
            .similarityTopK = top_k,
        },
    }, .{});
}

/// Parse a retrieveContexts response and append its contexts. Strings are
/// duped into the arena `a` so they outlive the per-corpus response buffer;
/// the ArrayList itself lives in `list_alloc`.
fn appendContexts(a: std.mem.Allocator, list: *std.ArrayListUnmanaged(ContextResult), list_alloc: std.mem.Allocator, body: []const u8) !void {
    const Resp = struct {
        contexts: ?struct {
            contexts: []const struct {
                sourceUri: []const u8 = "",
                sourceName: []const u8 = "",
                text: []const u8 = "",
                score: f64 = 0,
                distance: f64 = 0,
            } = &.{},
        } = null,
    };
    const parsed = std.json.parseFromSlice(Resp, a, body, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch return;
    // parsed is arena-backed (a); no deinit needed — arena frees it.

    const ctxs = if (parsed.value.contexts) |c| c.contexts else return;
    for (ctxs) |c| {
        const source = if (c.sourceName.len > 0) c.sourceName else c.sourceUri;
        try list.append(list_alloc, .{
            .source_uri = c.sourceUri,
            .source_name = source,
            .text = c.text,
            .score = c.score,
            .distance = c.distance,
        });
    }
}

fn scoreDesc(_: void, lhs: ContextResult, rhs: ContextResult) bool {
    return lhs.score > rhs.score;
}

fn corpusMatches(c: Corpus, filter_lower_input: []const u8) bool {
    // Case-insensitive match on display name (contains) or trailing ID segment.
    const id = corpusId(c.name);
    if (std.ascii.eqlIgnoreCase(id, filter_lower_input)) return true;
    if (std.ascii.eqlIgnoreCase(c.displayName, filter_lower_input)) return true;
    return containsIgnoreCase(c.displayName, filter_lower_input);
}

fn corpusId(name: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, name, '/')) |i| return name[i + 1 ..];
    return name;
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

fn rollback(store: ?*store_mod.Store, io: ?std.Io, reservation_id: ?u64) void {
    if (reservation_id) |rid| if (store) |s| if (io) |io_handle| s.rollbackReservation(io_handle, rid);
}

fn errResp(status: http.Status, message: []const u8) Response {
    _ = message;
    return switch (status) {
        .bad_request => .{ .status = .bad_request, .body = "{\"error\":\"invalid_request\",\"message\":\"RAG request rejected\"}" },
        .payment_required => .{ .status = .payment_required, .body = "{\"error\":\"insufficient_balance\",\"message\":\"Account balance is too low for RAG search\"}" },
        .service_unavailable => .{ .status = .service_unavailable, .body = "{\"error\":\"service_unavailable\",\"message\":\"RAG is unavailable: server has no GCP backend\"}" },
        .bad_gateway => .{ .status = .bad_gateway, .body = "{\"error\":\"provider_error\",\"message\":\"Vertex RAG request failed\"}" },
        else => .{ .status = .internal_server_error, .body = "{\"error\":\"internal\",\"message\":\"RAG request failed\"}" },
    };
}
