// Ledger query / aggregation — read side of the append-only ledger.jsonl.
//
// The Go gateway serves usage history from a per-user Firestore ledger and
// rollups from BigQuery. The Zig server writes every billing event to a local
// `ledger.jsonl` (see ledger.zig); this module reads that file back and
// aggregates it to serve the equivalent read endpoints with no external
// dependency:
//
//   GET /qai/v1/account/usage           recent billing entries (this account)
//   GET /qai/v1/account/usage/summary   all-time rollup (this account)
//   GET /qai/v1/stats/overview          totals (this account)
//   GET /qai/v1/stats/models            per-model breakdown (this account)
//   GET /qai/v1/stats/timeline          per-day buckets (this account)
//   GET /admin/stats/overview           global totals (admin)
//   GET /admin/stats/usage/models       global per-model (admin)
//
// Reading the whole file per request is O(file); these are cold stats
// endpoints, not the hot path, and the read is capped at 64 MB. Credit
// top-up lines (type="credit") are excluded — only debit/billing lines count
// toward usage. Divergence note: the Go entry shape carries a few Firestore
// fields (request_id, cursor) the local ledger doesn't record; the fields it
// does have (model, endpoint, ticks, tokens, balance_after, ts) match.

const std = @import("std");
const http = std.http;
const Dir = std.Io.Dir;
const router = @import("router.zig");
const ledger_mod = @import("ledger.zig");
const types = @import("store/types.zig");
const Response = router.Response;

const TICKS_PER_USD: i64 = 10_000_000_000;
const MAX_LEDGER_READ: usize = 64 * 1024 * 1024;
const DEFAULT_USAGE_LIMIT: usize = 20;

/// One parsed billing line. Fields default so credit-lines / partial lines
/// parse without error; we filter to billing lines (`type` empty) downstream.
const Entry = struct {
    account_id: []const u8 = "",
    key_prefix: []const u8 = "",
    total_ticks: i64 = 0,
    balance_after: i64 = 0,
    endpoint: []const u8 = "",
    model: []const u8 = "",
    input_tokens: u32 = 0,
    output_tokens: u32 = 0,
    latency_ms: u32 = 0,
    ts: i64 = 0,
    type: []const u8 = "",
    // credit-line fields (type == "credit")
    amount_ticks: i64 = 0,
    admin_key: []const u8 = "",
};

/// Read + parse ledger.jsonl into the arena. Returns billing entries only
/// (credit top-ups excluded). Missing file → empty slice.
fn loadEntries(arena: std.mem.Allocator, io: std.Io, path: []const u8) []Entry {
    const data = Dir.cwd().readFileAlloc(io, path, arena, .limited(MAX_LEDGER_READ)) catch return &.{};

    var list: std.ArrayListUnmanaged(Entry) = .empty;
    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0 or trimmed[0] != '{') continue;
        const parsed = std.json.parseFromSliceLeaky(Entry, arena, trimmed, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        }) catch continue;
        if (parsed.type.len != 0) continue; // skip credit top-ups
        list.append(arena, parsed) catch break;
    }
    return list.toOwnedSlice(arena) catch &.{};
}

// ── admin: recent requests / errors (from the local audit log) ───────

/// GET /admin/audit, /admin/requests/recent, /admin/requests/errors — reads
/// audit.jsonl (every request is logged there by ledger.recordAudit). Admin
/// only. `errors_only` keeps status >= 400.
pub fn handleAuditRecent(
    allocator: std.mem.Allocator,
    io: std.Io,
    ledger: *ledger_mod.Ledger,
    auth: *const types.AuthContext,
    errors_only: bool,
) Response {
    if (auth.account.role != .admin) return forbidden();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const data = Dir.cwd().readFileAlloc(io, ledger.audit_path, a, .limited(MAX_LEDGER_READ)) catch "";

    const AuditLine = struct {
        key: []const u8 = "",
        account: []const u8 = "",
        endpoint: []const u8 = "",
        method: []const u8 = "",
        status: u16 = 0,
        model: []const u8 = "",
        in: u32 = 0,
        out: u32 = 0,
        cost: i64 = 0,
        ms: u32 = 0,
        ts: i64 = 0,
    };
    var rows: std.ArrayListUnmanaged(AuditLine) = .empty;
    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0 or trimmed[0] != '{') continue;
        const e = std.json.parseFromSliceLeaky(AuditLine, a, trimmed, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch continue;
        if (errors_only and e.status < 400) continue;
        rows.append(a, e) catch break;
    }
    // newest first, cap 200
    std.mem.sort(AuditLine, rows.items, {}, struct {
        fn f(_: void, l: AuditLine, r: AuditLine) bool {
            return l.ts > r.ts;
        }
    }.f);
    const shown = if (rows.items.len > 200) rows.items[0..200] else rows.items;

    const out = std.json.Stringify.valueAlloc(allocator, .{ .requests = shown }, .{}) catch return errResp(.internal_server_error);
    return .{ .body = out };
}

// ── purchase history (credit top-ups from the ledger) ────────────────
//
// Stripe/IAP credits are recorded to the ledger via ledger.recordCredit
// (type == "credit"). Purchase-history lists those for the account — no
// separate purchases store needed.

pub fn handlePurchaseHistory(
    allocator: std.mem.Allocator,
    io: std.Io,
    ledger: *ledger_mod.Ledger,
    auth: *const types.AuthContext,
) Response {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const data = Dir.cwd().readFileAlloc(io, ledger.ledger_path, a, .limited(MAX_LEDGER_READ)) catch "";
    const account_id = auth.account.id.slice();

    const Purchase = struct {
        amount_ticks: i64,
        balance_after: i64,
        source: []const u8,
        ts: i64,
    };
    var purchases: std.ArrayListUnmanaged(Purchase) = .empty;

    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0 or trimmed[0] != '{') continue;
        const e = std.json.parseFromSliceLeaky(Entry, a, trimmed, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch continue;
        if (!std.mem.eql(u8, e.type, "credit")) continue;
        if (!std.mem.eql(u8, e.account_id, account_id)) continue;
        purchases.append(a, .{ .amount_ticks = e.amount_ticks, .balance_after = e.balance_after, .source = e.admin_key, .ts = e.ts }) catch break;
    }
    std.mem.sort(Purchase, purchases.items, {}, struct {
        fn f(_: void, l: Purchase, r: Purchase) bool {
            return l.ts > r.ts;
        }
    }.f);

    const out = std.json.Stringify.valueAlloc(allocator, .{ .purchases = purchases.items }, .{}) catch
        return errResp(.internal_server_error);
    return .{ .body = out };
}

// ── GET /qai/v1/account/usage ────────────────────────────────────────

pub fn handleAccountUsage(
    request: *http.Server.Request,
    allocator: std.mem.Allocator,
    io: std.Io,
    ledger: *ledger_mod.Ledger,
    auth: *const types.AuthContext,
) Response {
    const limit = parseLimit(request) orelse DEFAULT_USAGE_LIMIT;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const entries = loadEntries(a, io, ledger.ledger_path);
    const account_id = auth.account.id.slice();

    // Collect this account's entries, newest first.
    var mine: std.ArrayListUnmanaged(Entry) = .empty;
    for (entries) |e| {
        if (std.mem.eql(u8, e.account_id, account_id)) mine.append(a, e) catch break;
    }
    std.mem.sort(Entry, mine.items, {}, tsDesc);

    const has_more = mine.items.len > limit;
    const shown = if (has_more) mine.items[0..limit] else mine.items;

    // Emit a UsageEntry view (the wire fields the local ledger actually has).
    const UsageEntry = struct {
        model: []const u8,
        endpoint: []const u8,
        cost_ticks: i64,
        balance_after: i64,
        input_tokens: u32,
        output_tokens: u32,
        ts: i64,
    };
    var view = a.alloc(UsageEntry, shown.len) catch return errResp(.internal_server_error);
    for (shown, 0..) |e, i| {
        view[i] = .{
            .model = e.model,
            .endpoint = e.endpoint,
            .cost_ticks = e.total_ticks,
            .balance_after = e.balance_after,
            .input_tokens = e.input_tokens,
            .output_tokens = e.output_tokens,
            .ts = e.ts,
        };
    }

    const out = std.json.Stringify.valueAlloc(allocator, .{
        .entries = view,
        .has_more = has_more,
    }, .{}) catch return errResp(.internal_server_error);
    return .{ .body = out };
}

// ── GET /qai/v1/account/usage/summary + /qai/v1/stats/overview ───────

pub fn handleAccountSummary(
    allocator: std.mem.Allocator,
    io: std.Io,
    ledger: *ledger_mod.Ledger,
    auth: *const types.AuthContext,
) Response {
    return overview(allocator, io, ledger, auth.account.id.slice());
}

pub fn handleStatsOverview(
    allocator: std.mem.Allocator,
    io: std.Io,
    ledger: *ledger_mod.Ledger,
    auth: *const types.AuthContext,
) Response {
    return overview(allocator, io, ledger, auth.account.id.slice());
}

pub fn handleAdminStatsOverview(
    allocator: std.mem.Allocator,
    io: std.Io,
    ledger: *ledger_mod.Ledger,
    auth: *const types.AuthContext,
) Response {
    if (auth.account.role != .admin) return forbidden();
    return overview(allocator, io, ledger, null); // null → all accounts
}

/// Totals rollup. `account_filter` null → global (admin).
fn overview(allocator: std.mem.Allocator, io: std.Io, ledger: *ledger_mod.Ledger, account_filter: ?[]const u8) Response {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const entries = loadEntries(a, io, ledger.ledger_path);

    var total_ticks: i64 = 0;
    var request_count: u64 = 0;
    var input_tokens: u64 = 0;
    var output_tokens: u64 = 0;
    for (entries) |e| {
        if (account_filter) |f| if (!std.mem.eql(u8, e.account_id, f)) continue;
        total_ticks += e.total_ticks;
        request_count += 1;
        input_tokens += e.input_tokens;
        output_tokens += e.output_tokens;
    }

    const out = std.json.Stringify.valueAlloc(allocator, .{
        .total_ticks = total_ticks,
        .total_usd = @as(f64, @floatFromInt(total_ticks)) / @as(f64, TICKS_PER_USD),
        .request_count = request_count,
        .input_tokens = input_tokens,
        .output_tokens = output_tokens,
        .scope = if (account_filter == null) "global" else "account",
    }, .{}) catch return errResp(.internal_server_error);
    return .{ .body = out };
}

// ── GET /qai/v1/stats/models + /admin/stats/usage/models ─────────────

pub fn handleStatsModels(
    allocator: std.mem.Allocator,
    io: std.Io,
    ledger: *ledger_mod.Ledger,
    auth: *const types.AuthContext,
) Response {
    return modelBreakdown(allocator, io, ledger, auth.account.id.slice());
}

pub fn handleAdminStatsModels(
    allocator: std.mem.Allocator,
    io: std.Io,
    ledger: *ledger_mod.Ledger,
    auth: *const types.AuthContext,
) Response {
    if (auth.account.role != .admin) return forbidden();
    return modelBreakdown(allocator, io, ledger, null);
}

const ModelAgg = struct {
    model: []const u8,
    request_count: u64 = 0,
    total_ticks: i64 = 0,
    input_tokens: u64 = 0,
    output_tokens: u64 = 0,
};

fn modelBreakdown(allocator: std.mem.Allocator, io: std.Io, ledger: *ledger_mod.Ledger, account_filter: ?[]const u8) Response {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const entries = loadEntries(a, io, ledger.ledger_path);

    var map: std.StringHashMapUnmanaged(ModelAgg) = .empty;
    for (entries) |e| {
        if (account_filter) |f| if (!std.mem.eql(u8, e.account_id, f)) continue;
        const key = if (e.model.len > 0) e.model else "unknown";
        const gop = map.getOrPut(a, key) catch continue;
        if (!gop.found_existing) gop.value_ptr.* = .{ .model = key };
        gop.value_ptr.request_count += 1;
        gop.value_ptr.total_ticks += e.total_ticks;
        gop.value_ptr.input_tokens += e.input_tokens;
        gop.value_ptr.output_tokens += e.output_tokens;
    }

    var models: std.ArrayListUnmanaged(ModelAgg) = .empty;
    var vit = map.valueIterator();
    while (vit.next()) |v| models.append(a, v.*) catch break;
    std.mem.sort(ModelAgg, models.items, {}, modelTicksDesc);

    const out = std.json.Stringify.valueAlloc(allocator, .{
        .models = models.items,
        .scope = if (account_filter == null) "global" else "account",
    }, .{}) catch return errResp(.internal_server_error);
    return .{ .body = out };
}

// ── Admin group-by aggregations over the same ledger data ────────────
//   GET /admin/stats/usage/endpoints   group by endpoint
//   GET /admin/stats/usage/providers   group by provider (derived from model)
//   GET /admin/stats/usage/top-users   group by account_id (top 50 by spend)
//   GET /admin/stats/usage/daily       group by epoch-day (global)

const KeyAgg = struct {
    key: []const u8,
    request_count: u64 = 0,
    total_ticks: i64 = 0,
    input_tokens: u64 = 0,
    output_tokens: u64 = 0,
};

const GroupBy = enum { endpoint, provider, account };

pub fn handleAdminStatsEndpoints(allocator: std.mem.Allocator, io: std.Io, ledger: *ledger_mod.Ledger, auth: *const types.AuthContext) Response {
    if (auth.account.role != .admin) return forbidden();
    return groupByString(allocator, io, ledger, .endpoint, 0, "endpoints");
}

pub fn handleAdminStatsProviders(allocator: std.mem.Allocator, io: std.Io, ledger: *ledger_mod.Ledger, auth: *const types.AuthContext) Response {
    if (auth.account.role != .admin) return forbidden();
    return groupByString(allocator, io, ledger, .provider, 0, "providers");
}

pub fn handleAdminStatsTopUsers(allocator: std.mem.Allocator, io: std.Io, ledger: *ledger_mod.Ledger, auth: *const types.AuthContext) Response {
    if (auth.account.role != .admin) return forbidden();
    return groupByString(allocator, io, ledger, .account, 50, "top_users");
}

fn groupByString(allocator: std.mem.Allocator, io: std.Io, ledger: *ledger_mod.Ledger, by: GroupBy, top_n: usize, field: []const u8) Response {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const entries = loadEntries(a, io, ledger.ledger_path);
    const models_mod = @import("models.zig");

    var map: std.StringHashMapUnmanaged(KeyAgg) = .empty;
    for (entries) |e| {
        const key = switch (by) {
            .endpoint => if (e.endpoint.len > 0) e.endpoint else "unknown",
            .account => if (e.account_id.len > 0) e.account_id else "unknown",
            .provider => if (models_mod.getModel(e.model)) |m| m.provider else "unknown",
        };
        const gop = map.getOrPut(a, key) catch continue;
        if (!gop.found_existing) gop.value_ptr.* = .{ .key = key };
        gop.value_ptr.request_count += 1;
        gop.value_ptr.total_ticks += e.total_ticks;
        gop.value_ptr.input_tokens += e.input_tokens;
        gop.value_ptr.output_tokens += e.output_tokens;
    }

    var groups: std.ArrayListUnmanaged(KeyAgg) = .empty;
    var vit = map.valueIterator();
    while (vit.next()) |v| groups.append(a, v.*) catch break;
    std.mem.sort(KeyAgg, groups.items, {}, keyTicksDesc);

    const shown = if (top_n > 0 and groups.items.len > top_n) groups.items[0..top_n] else groups.items;

    // Emit under the named field so the client gets {<field>: [...]}.
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    var jw: std.json.Stringify = .{ .writer = &aw.writer, .options = .{} };
    jw.beginObject() catch return errResp(.internal_server_error);
    jw.objectField(field) catch return errResp(.internal_server_error);
    jw.write(shown) catch return errResp(.internal_server_error);
    jw.objectField("scope") catch return errResp(.internal_server_error);
    jw.write("global") catch return errResp(.internal_server_error);
    jw.endObject() catch return errResp(.internal_server_error);
    const out = aw.toOwnedSlice() catch return errResp(.internal_server_error);
    return .{ .body = out };
}

/// GET /admin/stats/usage/partners + /admin/analytics/users — group spend by
/// account (partner). Admin only.
pub fn handleAdminStatsPartners(allocator: std.mem.Allocator, io: std.Io, ledger: *ledger_mod.Ledger, auth: *const types.AuthContext) Response {
    if (auth.account.role != .admin) return forbidden();
    return groupByString(allocator, io, ledger, .account, 0, "partners");
}

/// GET /admin/stats/usage/providers/daily — provider × day cross-tab. Admin.
pub fn handleAdminStatsProvidersDaily(allocator: std.mem.Allocator, io: std.Io, ledger: *ledger_mod.Ledger, auth: *const types.AuthContext) Response {
    if (auth.account.role != .admin) return forbidden();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const entries = loadEntries(a, io, ledger.ledger_path);
    const models_mod = @import("models.zig");

    const Cell = struct { provider: []const u8, day: i64, request_count: u64 = 0, total_ticks: i64 = 0 };
    // Key = "provider|day"; small N so a flat list + linear find is fine.
    var cells: std.ArrayListUnmanaged(Cell) = .empty;
    for (entries) |e| {
        const provider = if (models_mod.getModel(e.model)) |m| m.provider else "unknown";
        const day = @divTrunc(e.ts, 86_400_000);
        var found = false;
        for (cells.items) |*c| {
            if (c.day == day and std.mem.eql(u8, c.provider, provider)) {
                c.request_count += 1;
                c.total_ticks += e.total_ticks;
                found = true;
                break;
            }
        }
        if (!found) cells.append(a, .{ .provider = provider, .day = day, .request_count = 1, .total_ticks = e.total_ticks }) catch break;
    }
    const out = std.json.Stringify.valueAlloc(allocator, .{ .cells = cells.items, .scope = "global" }, .{}) catch return errResp(.internal_server_error);
    return .{ .body = out };
}

pub fn handleAdminStatsDaily(allocator: std.mem.Allocator, io: std.Io, ledger: *ledger_mod.Ledger, auth: *const types.AuthContext) Response {
    if (auth.account.role != .admin) return forbidden();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const entries = loadEntries(a, io, ledger.ledger_path);

    var map: std.AutoHashMapUnmanaged(i64, DayBucket) = .empty;
    for (entries) |e| {
        const day = @divTrunc(e.ts, 86_400_000);
        const gop = map.getOrPut(a, day) catch continue;
        if (!gop.found_existing) gop.value_ptr.* = .{ .day = day };
        gop.value_ptr.request_count += 1;
        gop.value_ptr.total_ticks += e.total_ticks;
    }
    var buckets: std.ArrayListUnmanaged(DayBucket) = .empty;
    var vit = map.valueIterator();
    while (vit.next()) |v| buckets.append(a, v.*) catch break;
    std.mem.sort(DayBucket, buckets.items, {}, dayAsc);

    const out = std.json.Stringify.valueAlloc(allocator, .{ .daily = buckets.items, .scope = "global" }, .{}) catch return errResp(.internal_server_error);
    return .{ .body = out };
}

fn keyTicksDesc(_: void, l: KeyAgg, r: KeyAgg) bool {
    return l.total_ticks > r.total_ticks;
}

// ── GET /qai/v1/stats/timeline ───────────────────────────────────────

const DayBucket = struct {
    day: i64, // epoch-day (ts_ms / 86_400_000)
    request_count: u64 = 0,
    total_ticks: i64 = 0,
};

pub fn handleStatsTimeline(
    allocator: std.mem.Allocator,
    io: std.Io,
    ledger: *ledger_mod.Ledger,
    auth: *const types.AuthContext,
) Response {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const entries = loadEntries(a, io, ledger.ledger_path);
    const account_id = auth.account.id.slice();

    var map: std.AutoHashMapUnmanaged(i64, DayBucket) = .empty;
    for (entries) |e| {
        if (!std.mem.eql(u8, e.account_id, account_id)) continue;
        const day = @divTrunc(e.ts, 86_400_000);
        const gop = map.getOrPut(a, day) catch continue;
        if (!gop.found_existing) gop.value_ptr.* = .{ .day = day };
        gop.value_ptr.request_count += 1;
        gop.value_ptr.total_ticks += e.total_ticks;
    }

    var buckets: std.ArrayListUnmanaged(DayBucket) = .empty;
    var vit = map.valueIterator();
    while (vit.next()) |v| buckets.append(a, v.*) catch break;
    std.mem.sort(DayBucket, buckets.items, {}, dayAsc);

    const out = std.json.Stringify.valueAlloc(allocator, .{
        .timeline = buckets.items,
    }, .{}) catch return errResp(.internal_server_error);
    return .{ .body = out };
}

// ── helpers ──────────────────────────────────────────────────────────

fn parseLimit(request: *http.Server.Request) ?usize {
    const target = request.head.target;
    const q = std.mem.indexOfScalar(u8, target, '?') orelse return null;
    var it = std.mem.splitScalar(u8, target[q + 1 ..], '&');
    while (it.next()) |pair| {
        if (std.mem.startsWith(u8, pair, "limit=")) {
            const v = std.fmt.parseInt(usize, pair[6..], 10) catch return null;
            if (v == 0 or v > 100) return null;
            return v;
        }
    }
    return null;
}

fn tsDesc(_: void, l: Entry, r: Entry) bool {
    return l.ts > r.ts;
}
fn modelTicksDesc(_: void, l: ModelAgg, r: ModelAgg) bool {
    return l.total_ticks > r.total_ticks;
}
fn dayAsc(_: void, l: DayBucket, r: DayBucket) bool {
    return l.day < r.day;
}

fn forbidden() Response {
    return .{ .status = .forbidden, .body =
        \\{"error":"forbidden","message":"Admin role required"}
    };
}

fn errResp(status: http.Status) Response {
    return .{ .status = status, .body = "{\"error\":\"internal\",\"message\":\"stats query failed\"}" };
}
