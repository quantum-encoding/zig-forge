// Generic Firestore-backed CRUD for the tenant verticals.
//
// Many gateway routes are plain owner-scoped document CRUD over a Firestore
// collection (observations, sessions, recipebox, reservations, notification
// devices, …). Rather than hand-model each, this layer stores/reads arbitrary
// client JSON via fs_value.zig and scopes every document to the authenticated
// account through an owner field (default "user_id"). A vertical is then just
// a Spec (collection name + owner field + optional list ordering) wired to
// these handlers.
//
// create  POST   → stamps owner + created_at_ms, returns {id, …}
// list    GET     → runQuery where owner == account [order by] [limit], {items:[…]}
// get     GET/{id}→ reads one (404 unless owned by the account / admin)
// remove  DELETE  → deletes one (404 unless owned)
//
// All documents are scoped by owner on read/delete — a caller can never read
// or delete another account's documents (admins may).

const std = @import("std");
const http = std.http;
const json_util = @import("json.zig");
const router = @import("router.zig");
const security = @import("security.zig");
const gcp = @import("gcp.zig");
const types = @import("store/types.zig");
const fs = @import("fs_value.zig");
const Response = router.Response;

const FS_BASE = "https://firestore.googleapis.com/v1/projects";

pub const Spec = struct {
    collection: []const u8,
    owner_field: []const u8 = "user_id",
    order_field: ?[]const u8 = null,
    default_limit: u32 = 50,
};

fn docsBase(allocator: std.mem.Allocator, project: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/{s}/databases/(default)/documents", .{ FS_BASE, project });
}

// ── create ───────────────────────────────────────────────────────────

pub fn create(
    request: *http.Server.Request,
    allocator: std.mem.Allocator,
    io: std.Io,
    gcp_ctx: ?*gcp.GcpContext,
    auth: *const types.AuthContext,
    spec: Spec,
) Response {
    const ctx = gcp_ctx orelse return err(.service_unavailable);
    const body = json_util.readBody(request, allocator, security.Limits.max_chat_body) catch return err(.bad_request);
    defer allocator.free(body);
    if (body.len == 0) return err(.bad_request);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const parsed = std.json.parseFromSliceLeaky(std.json.Value, a, body, .{}) catch return err(.bad_request);
    if (parsed != .object) return err(.bad_request);
    var obj = parsed.object;
    // Stamp ownership + creation time (overwrites any client-supplied values).
    obj.put(a, spec.owner_field, .{ .string = auth.account.id.slice() }) catch return err(.internal_server_error);
    obj.put(a, "created_at_ms", .{ .integer = types.nowMs(io) }) catch return err(.internal_server_error);

    const doc_body = fs.documentAlloc(a, .{ .object = obj }) catch return err(.internal_server_error);

    const url = std.fmt.allocPrint(a, "{s}/{s}", .{ docsBase(a, ctx.project_id) catch return err(.internal_server_error), spec.collection }) catch return err(.internal_server_error);
    var resp = ctx.post(url, doc_body) catch return err(.bad_gateway);
    defer resp.deinit();
    if (@intFromEnum(resp.status) >= 300) return err(.bad_gateway);

    return docResponse(allocator, a, resp.body);
}

/// POST a batch of documents: body { <array_field>: [ {...}, ... ] }. Each
/// element is owner-stamped and created. Returns { created: [ {id}, ... ] }.
pub fn createBatch(
    request: *http.Server.Request,
    allocator: std.mem.Allocator,
    io: std.Io,
    gcp_ctx: ?*gcp.GcpContext,
    auth: *const types.AuthContext,
    spec: Spec,
    array_field: []const u8,
) Response {
    const ctx = gcp_ctx orelse return err(.service_unavailable);
    const body = json_util.readBody(request, allocator, 8 * 1024 * 1024) catch return err(.bad_request);
    defer allocator.free(body);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const root = std.json.parseFromSliceLeaky(std.json.Value, a, body, .{}) catch return err(.bad_request);
    if (root != .object) return err(.bad_request);
    const arr = root.object.get(array_field) orelse return err(.bad_request);
    if (arr != .array) return err(.bad_request);

    const base = std.fmt.allocPrint(a, "{s}/{s}", .{ docsBase(a, ctx.project_id) catch return err(.internal_server_error), spec.collection }) catch return err(.internal_server_error);

    var ids = std.json.Array.init(a);
    for (arr.array.items) |item| {
        if (item != .object) continue;
        var obj = item.object;
        obj.put(a, spec.owner_field, .{ .string = auth.account.id.slice() }) catch continue;
        obj.put(a, "created_at_ms", .{ .integer = types.nowMs(io) }) catch continue;
        const doc_body = fs.documentAlloc(a, .{ .object = obj }) catch continue;
        var resp = ctx.post(base, doc_body) catch continue;
        defer resp.deinit();
        if (@intFromEnum(resp.status) >= 300) continue;
        const doc = std.json.parseFromSliceLeaky(std.json.Value, a, resp.body, .{}) catch continue;
        // Collect the created id from the returned document name.
        if (doc == .object) if (doc.object.get("name")) |name| if (name == .string)
            ids.append(.{ .string = lastSegment(name.string) }) catch {};
    }

    const out = std.json.Stringify.valueAlloc(allocator, .{ .created = std.json.Value{ .array = ids } }, .{}) catch return err(.internal_server_error);
    return .{ .body = out };
}

// ── list ─────────────────────────────────────────────────────────────

pub fn list(
    request: *http.Server.Request,
    allocator: std.mem.Allocator,
    gcp_ctx: ?*gcp.GcpContext,
    auth: *const types.AuthContext,
    spec: Spec,
) Response {
    const ctx = gcp_ctx orelse return err(.service_unavailable);
    const limit = parseLimit(request) orelse spec.default_limit;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // structuredQuery: from collection, where owner == account, [orderBy], limit.
    const query_body = buildQuery(a, spec, auth.account.id.slice(), limit) catch return err(.internal_server_error);
    const url = std.fmt.allocPrint(a, "{s}:runQuery", .{docsBase(a, ctx.project_id) catch return err(.internal_server_error)}) catch return err(.internal_server_error);
    var resp = ctx.post(url, query_body) catch return err(.bad_gateway);
    defer resp.deinit();
    if (@intFromEnum(resp.status) >= 300) return err(.bad_gateway);

    // runQuery returns an array of {document?:{...}, readTime}. Collect docs.
    const RunResult = []const struct {
        document: ?std.json.Value = null,
    };
    const parsed = std.json.parseFromSliceLeaky(RunResult, a, resp.body, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch return err(.bad_gateway);

    var items = std.json.Array.init(a);
    for (parsed) |row| {
        if (row.document) |doc| {
            const plain = docToPlain(a, doc) catch continue;
            items.append(plain) catch break;
        }
    }

    const out = std.json.Stringify.valueAlloc(allocator, .{ .items = std.json.Value{ .array = items } }, .{}) catch return err(.internal_server_error);
    return .{ .body = out };
}

// ── get ──────────────────────────────────────────────────────────────

pub fn get(
    allocator: std.mem.Allocator,
    gcp_ctx: ?*gcp.GcpContext,
    auth: *const types.AuthContext,
    spec: Spec,
    id: []const u8,
) Response {
    const ctx = gcp_ctx orelse return err(.service_unavailable);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const url = std.fmt.allocPrint(a, "{s}/{s}/{s}", .{ docsBase(a, ctx.project_id) catch return err(.internal_server_error), spec.collection, id }) catch return err(.internal_server_error);
    var resp = ctx.get(url) catch return err(.bad_gateway);
    defer resp.deinit();
    if (resp.status != .ok) return err(.not_found);

    const doc = std.json.parseFromSliceLeaky(std.json.Value, a, resp.body, .{}) catch return err(.bad_gateway);
    const plain = docToPlain(a, doc) catch return err(.bad_gateway);
    if (!owns(plain, spec, auth)) return err(.not_found);

    const out = std.json.Stringify.valueAlloc(allocator, plain, .{}) catch return err(.internal_server_error);
    return .{ .body = out };
}

// ── remove ───────────────────────────────────────────────────────────

pub fn remove(
    allocator: std.mem.Allocator,
    gcp_ctx: ?*gcp.GcpContext,
    auth: *const types.AuthContext,
    spec: Spec,
    id: []const u8,
) Response {
    const ctx = gcp_ctx orelse return err(.service_unavailable);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const url = std.fmt.allocPrint(a, "{s}/{s}/{s}", .{ docsBase(a, ctx.project_id) catch return err(.internal_server_error), spec.collection, id }) catch return err(.internal_server_error);

    // Ownership check: read first, verify, then delete.
    var gresp = ctx.get(url) catch return err(.bad_gateway);
    const owned = blk: {
        defer gresp.deinit();
        if (gresp.status != .ok) break :blk false;
        const doc = std.json.parseFromSliceLeaky(std.json.Value, a, gresp.body, .{}) catch break :blk false;
        const plain = docToPlain(a, doc) catch break :blk false;
        break :blk owns(plain, spec, auth);
    };
    if (!owned) return err(.not_found);

    var dresp = ctx.delete(url) catch return err(.bad_gateway);
    defer dresp.deinit();
    if (@intFromEnum(dresp.status) >= 300) return err(.bad_gateway);

    return .{ .body = "{\"status\":\"deleted\"}" };
}

// ── single-doc-per-owner (settings-style) ───────────────────────────
// The document id IS the account id, so there's exactly one doc per user.

/// GET {collection}/{account_id}. Returns {} (empty object) when unset, so a
/// settings read on a fresh account succeeds with defaults rather than 404.
pub fn getByOwner(
    allocator: std.mem.Allocator,
    gcp_ctx: ?*gcp.GcpContext,
    auth: *const types.AuthContext,
    spec: Spec,
) Response {
    const ctx = gcp_ctx orelse return err(.service_unavailable);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const url = std.fmt.allocPrint(a, "{s}/{s}/{s}", .{ docsBase(a, ctx.project_id) catch return err(.internal_server_error), spec.collection, auth.account.id.slice() }) catch return err(.internal_server_error);
    var resp = ctx.get(url) catch return err(.bad_gateway);
    defer resp.deinit();
    if (resp.status != .ok) return .{ .body = "{}" }; // unset → defaults

    const doc = std.json.parseFromSliceLeaky(std.json.Value, a, resp.body, .{}) catch return err(.bad_gateway);
    const plain = docToPlain(a, doc) catch return err(.bad_gateway);
    const out = std.json.Stringify.valueAlloc(allocator, plain, .{}) catch return err(.internal_server_error);
    return .{ .body = out };
}

/// PATCH {collection}/{account_id} with the request body (upsert). Stamps the
/// owner + updated_at_ms.
pub fn putByOwner(
    request: *http.Server.Request,
    allocator: std.mem.Allocator,
    io: std.Io,
    gcp_ctx: ?*gcp.GcpContext,
    auth: *const types.AuthContext,
    spec: Spec,
) Response {
    const ctx = gcp_ctx orelse return err(.service_unavailable);
    const body = json_util.readBody(request, allocator, security.Limits.max_chat_body) catch return err(.bad_request);
    defer allocator.free(body);
    if (body.len == 0) return err(.bad_request);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const parsed = std.json.parseFromSliceLeaky(std.json.Value, a, body, .{}) catch return err(.bad_request);
    if (parsed != .object) return err(.bad_request);
    var obj = parsed.object;
    obj.put(a, spec.owner_field, .{ .string = auth.account.id.slice() }) catch return err(.internal_server_error);
    obj.put(a, "updated_at_ms", .{ .integer = types.nowMs(io) }) catch return err(.internal_server_error);

    const doc_body = fs.documentAlloc(a, .{ .object = obj }) catch return err(.internal_server_error);
    const url = std.fmt.allocPrint(a, "{s}/{s}/{s}", .{ docsBase(a, ctx.project_id) catch return err(.internal_server_error), spec.collection, auth.account.id.slice() }) catch return err(.internal_server_error);

    var resp = ctx.patchFresh(url, doc_body) catch return err(.bad_gateway);
    defer resp.deinit();
    if (@intFromEnum(resp.status) >= 300) return err(.bad_gateway);

    return docResponse(allocator, a, resp.body);
}

// ── status transition (field-level patch, ownership-checked) ─────────

/// PATCH only the `status` (+ updated_at_ms) field on collection/{id} after an
/// ownership check. Uses updateMask so other fields are preserved (a bare
/// Firestore PATCH would overwrite the whole document).
pub fn patchStatus(
    allocator: std.mem.Allocator,
    io: std.Io,
    gcp_ctx: ?*gcp.GcpContext,
    auth: *const types.AuthContext,
    spec: Spec,
    id: []const u8,
    status: []const u8,
) Response {
    const ctx = gcp_ctx orelse return err(.service_unavailable);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const base = std.fmt.allocPrint(a, "{s}/{s}/{s}", .{ docsBase(a, ctx.project_id) catch return err(.internal_server_error), spec.collection, id }) catch return err(.internal_server_error);

    // Ownership check.
    {
        var gresp = ctx.get(base) catch return err(.bad_gateway);
        defer gresp.deinit();
        if (gresp.status != .ok) return err(.not_found);
        const doc = std.json.parseFromSliceLeaky(std.json.Value, a, gresp.body, .{}) catch return err(.bad_gateway);
        const plain = docToPlain(a, doc) catch return err(.bad_gateway);
        if (!owns(plain, spec, auth)) return err(.not_found);
    }

    const url = std.fmt.allocPrint(a, "{s}?updateMask.fieldPaths=status&updateMask.fieldPaths=updated_at_ms", .{base}) catch return err(.internal_server_error);

    // Build the partial document {fields:{status, updated_at_ms}}.
    var aw: std.Io.Writer.Allocating = .init(a);
    var jw: std.json.Stringify = .{ .writer = &aw.writer, .options = .{} };
    jw.beginObject() catch return err(.internal_server_error);
    jw.objectField("fields") catch {};
    jw.beginObject() catch {};
    jw.objectField("status") catch {};
    jw.beginObject() catch {};
    jw.objectField("stringValue") catch {};
    jw.write(status) catch {};
    jw.endObject() catch {};
    jw.objectField("updated_at_ms") catch {};
    jw.beginObject() catch {};
    jw.objectField("integerValue") catch {};
    var nb: [24]u8 = undefined;
    jw.write(std.fmt.bufPrint(&nb, "{d}", .{types.nowMs(io)}) catch "0") catch {};
    jw.endObject() catch {};
    jw.endObject() catch {};
    jw.endObject() catch {};
    const doc_body = aw.toOwnedSlice() catch return err(.internal_server_error);

    var resp = ctx.patchFresh(url, doc_body) catch return err(.bad_gateway);
    defer resp.deinit();
    if (@intFromEnum(resp.status) >= 300) return err(.bad_gateway);

    const out = std.json.Stringify.valueAlloc(allocator, .{ .id = id, .status = status }, .{}) catch return err(.internal_server_error);
    return .{ .body = out };
}

// ── helpers ──────────────────────────────────────────────────────────

/// Build a structuredQuery body filtering by owner, optional order, limit.
fn buildQuery(a: std.mem.Allocator, spec: Spec, owner: []const u8, limit: u32) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(a);
    var jw: std.json.Stringify = .{ .writer = &aw.writer, .options = .{} };
    try jw.beginObject();
    try jw.objectField("structuredQuery");
    try jw.beginObject();

    try jw.objectField("from");
    try jw.beginArray();
    try jw.beginObject();
    try jw.objectField("collectionId");
    try jw.write(spec.collection);
    try jw.endObject();
    try jw.endArray();

    try jw.objectField("where");
    try jw.beginObject();
    try jw.objectField("fieldFilter");
    try jw.beginObject();
    try jw.objectField("field");
    try jw.beginObject();
    try jw.objectField("fieldPath");
    try jw.write(spec.owner_field);
    try jw.endObject();
    try jw.objectField("op");
    try jw.write("EQUAL");
    try jw.objectField("value");
    try jw.beginObject();
    try jw.objectField("stringValue");
    try jw.write(owner);
    try jw.endObject();
    try jw.endObject();
    try jw.endObject();

    if (spec.order_field) |of| {
        try jw.objectField("orderBy");
        try jw.beginArray();
        try jw.beginObject();
        try jw.objectField("field");
        try jw.beginObject();
        try jw.objectField("fieldPath");
        try jw.write(of);
        try jw.endObject();
        try jw.objectField("direction");
        try jw.write("DESCENDING");
        try jw.endObject();
        try jw.endArray();
    }

    try jw.objectField("limit");
    try jw.write(limit);

    try jw.endObject();
    try jw.endObject();
    return aw.toOwnedSlice();
}

/// Convert a Firestore document {name, fields} into a plain object, with the
/// document id extracted from `name` and added as "id".
fn docToPlain(a: std.mem.Allocator, doc: std.json.Value) !std.json.Value {
    if (doc != .object) return err_value;
    const fields = doc.object.get("fields") orelse std.json.Value{ .null = {} };
    var plain = try fs.fieldsToPlain(a, fields);
    if (doc.object.get("name")) |name| if (name == .string) {
        const id = lastSegment(name.string);
        if (plain == .object) try plain.object.put(a, "id", .{ .string = id });
    };
    return plain;
}

const err_value: std.json.Value = .{ .null = {} };

fn docResponse(allocator: std.mem.Allocator, a: std.mem.Allocator, doc_body: []const u8) Response {
    const doc = std.json.parseFromSliceLeaky(std.json.Value, a, doc_body, .{}) catch return err(.bad_gateway);
    const plain = docToPlain(a, doc) catch return err(.bad_gateway);
    const out = std.json.Stringify.valueAlloc(allocator, plain, .{}) catch return err(.internal_server_error);
    return .{ .body = out };
}

fn owns(plain: std.json.Value, spec: Spec, auth: *const types.AuthContext) bool {
    if (auth.account.role == .admin) return true;
    if (plain != .object) return false;
    const owner = plain.object.get(spec.owner_field) orelse return false;
    if (owner != .string) return false;
    return std.mem.eql(u8, owner.string, auth.account.id.slice());
}

fn lastSegment(path: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |i| return path[i + 1 ..];
    return path;
}

fn parseLimit(request: *http.Server.Request) ?u32 {
    const target = request.head.target;
    const q = std.mem.indexOfScalar(u8, target, '?') orelse return null;
    var it = std.mem.splitScalar(u8, target[q + 1 ..], '&');
    while (it.next()) |pair| {
        if (std.mem.startsWith(u8, pair, "limit=")) {
            const v = std.fmt.parseInt(u32, pair[6..], 10) catch return null;
            if (v == 0 or v > 1000) return null;
            return v;
        }
    }
    return null;
}

fn err(status: http.Status) Response {
    return switch (status) {
        .bad_request => .{ .status = .bad_request, .body = "{\"error\":\"invalid_request\",\"message\":\"request rejected\"}" },
        .not_found => .{ .status = .not_found, .body = "{\"error\":\"not_found\",\"message\":\"not found\"}" },
        .service_unavailable => .{ .status = .service_unavailable, .body = "{\"error\":\"unavailable\",\"message\":\"storage backend not available\"}" },
        .bad_gateway => .{ .status = .bad_gateway, .body = "{\"error\":\"storage_error\",\"message\":\"Firestore request failed\"}" },
        else => .{ .status = .internal_server_error, .body = "{\"error\":\"internal\",\"message\":\"request failed\"}" },
    };
}
