// Firestore REST API client — CRUD for accounts and keys
// Uses gcp-auth for authenticated requests.
// Handles Firestore's typed field encoding (stringValue, integerValue, etc.)
//
// Collections: zig_accounts, zig_keys (prefixed to avoid Go backend collision)

const std = @import("std");
const gcp = @import("gcp.zig");
const types = @import("store/types.zig");

const FIRESTORE_BASE = "https://firestore.googleapis.com/v1/projects/";

// ── Document URLs ───────────────────────────────────────────

fn accountUrl(allocator: std.mem.Allocator, project: []const u8, account_id: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator,
        "{s}{s}/databases/(default)/documents/zig_accounts/{s}",
        .{ FIRESTORE_BASE, project, account_id },
    );
}

fn keyUrl(allocator: std.mem.Allocator, project: []const u8, key_hash_hex: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator,
        "{s}{s}/databases/(default)/documents/zig_keys/{s}",
        .{ FIRESTORE_BASE, project, key_hash_hex },
    );
}

fn collectionUrl(allocator: std.mem.Allocator, project: []const u8, collection: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator,
        "{s}{s}/databases/(default)/documents/{s}",
        .{ FIRESTORE_BASE, project, collection },
    );
}

// ── Account CRUD ────────────────────────────────────────────

pub fn saveAccount(ctx: *gcp.GcpContext, account: types.Account) !void {
    const url = try accountUrl(ctx.allocator, ctx.project_id, account.id.slice());
    defer ctx.allocator.free(url);

    const body = try buildAccountDocument(ctx.allocator, account);
    defer ctx.allocator.free(body);

    // Use fresh connection to avoid stale pool after loadFromFirestore GETs
    var resp = ctx.patchFresh(url, body) catch |err| {
        std.debug.print("  Firestore saveAccount FAILED: {s} (account={s})\n", .{ @errorName(err), account.id.slice() });
        return err;
    };
    defer resp.deinit();

    if (@intFromEnum(resp.status) >= 400) {
        std.debug.print("  Firestore saveAccount HTTP {d} (account={s}): {s}\n", .{
            @intFromEnum(resp.status), account.id.slice(),
            if (resp.body.len > 200) resp.body[0..200] else resp.body,
        });
    }
}

pub fn loadAccount(ctx: *gcp.GcpContext, account_id: []const u8) !?types.Account {
    const url = try accountUrl(ctx.allocator, ctx.project_id, account_id);
    defer ctx.allocator.free(url);

    var resp = ctx.get(url) catch return null;
    defer resp.deinit();

    if (resp.status != .ok) return null;
    return parseAccountDocument(resp.body);
}

pub fn loadAllAccounts(ctx: *gcp.GcpContext, allocator: std.mem.Allocator) ![]types.Account {
    // Use Firestore list documents API
    const url = try collectionUrl(allocator, ctx.project_id, "zig_accounts");
    defer allocator.free(url);

    var resp = ctx.get(url) catch return &.{};
    defer resp.deinit();

    if (resp.status != .ok) return &.{};
    return parseAccountList(allocator, resp.body);
}

pub fn loadAllKeys(ctx: *gcp.GcpContext, allocator: std.mem.Allocator) ![]types.ApiKey {
    const url = try collectionUrl(allocator, ctx.project_id, "zig_keys");
    defer allocator.free(url);

    var resp = ctx.get(url) catch return &.{};
    defer resp.deinit();

    if (resp.status != .ok) return &.{};
    return parseKeyList(allocator, resp.body);
}

// ── Key CRUD ────────────────────────────────────────────────

pub fn saveKey(ctx: *gcp.GcpContext, key: types.ApiKey) !void {
    var hash_hex: [64]u8 = undefined;
    types.hexEncode(&key.key_hash, &hash_hex);

    const url = try keyUrl(ctx.allocator, ctx.project_id, &hash_hex);
    defer ctx.allocator.free(url);

    const body = try buildKeyDocument(ctx.allocator, key);
    defer ctx.allocator.free(body);

    var resp = ctx.patchFresh(url, body) catch |err| {
        std.debug.print("  Firestore saveKey FAILED: {s}\n", .{@errorName(err)});
        return err;
    };
    defer resp.deinit();

    if (@intFromEnum(resp.status) >= 400) {
        std.debug.print("  Firestore saveKey HTTP {d}: {s}\n", .{
            @intFromEnum(resp.status),
            if (resp.body.len > 200) resp.body[0..200] else resp.body,
        });
    }
}

pub fn updateAccountBalance(ctx: *gcp.GcpContext, io: std.Io, account_id: []const u8, balance_ticks: i64) !void {
    const url_base = try accountUrl(ctx.allocator, ctx.project_id, account_id);
    defer ctx.allocator.free(url_base);
    // Use updateMask to only update balance_ticks field
    const url = try std.fmt.allocPrint(ctx.allocator, "{s}?updateMask.fieldPaths=balance_ticks&updateMask.fieldPaths=updated_at", .{url_base});
    defer ctx.allocator.free(url);

    var aw: std.Io.Writer.Allocating = .init(ctx.allocator);
    defer aw.deinit();
    var jw: std.json.Stringify = .{ .writer = &aw.writer, .options = .{} };
    try jw.beginObject();
    try jw.objectField("fields");
    try jw.beginObject();
    try writeIntField(&jw, "balance_ticks", balance_ticks);
    try writeIntField(&jw, "updated_at", types.nowMs(io));
    try jw.endObject();
    try jw.endObject();

    var resp = try ctx.patchFresh(url, aw.written());
    defer resp.deinit();
}

// ── Firestore typed-value helpers ───────────────────────────
//
// Firestore's REST wire format wraps every field value in a typed
// envelope: `{"stringValue":"…"}`, `{"integerValue":"123"}`,
// `{"booleanValue":true}`. Integers are sent as STRINGS because the
// JSON spec stores numbers as f64 and Firestore int64 doesn't
// round-trip cleanly through that.
//
// These helpers stream that envelope via std.json.Stringify so every
// user-supplied value (email, name, account_id) is escaped by the
// standard library rather than concatenated with hand-rolled
// allocPrint. The prior code (audit C5) interpolated raw `{s}` for
// every string field, letting a hostile email like
//   `","balance_ticks":99999999999,"role":"admin","x":"`
// inject a forged role into the Firestore document at the document
// boundary.

fn writeStringField(jw: *std.json.Stringify, name: []const u8, value: []const u8) !void {
    try jw.objectField(name);
    try jw.beginObject();
    try jw.objectField("stringValue");
    try jw.write(value);
    try jw.endObject();
}

fn writeIntField(jw: *std.json.Stringify, name: []const u8, value: anytype) !void {
    try jw.objectField(name);
    try jw.beginObject();
    try jw.objectField("integerValue");
    // Firestore wants int64 as a JSON string — render the decimal
    // representation directly into the writer.
    var buf: [32]u8 = undefined;
    const s = try std.fmt.bufPrint(&buf, "{d}", .{value});
    try jw.write(s);
    try jw.endObject();
}

fn writeBoolField(jw: *std.json.Stringify, name: []const u8, value: bool) !void {
    try jw.objectField(name);
    try jw.beginObject();
    try jw.objectField("booleanValue");
    try jw.write(value);
    try jw.endObject();
}

pub fn updateKeyRevoked(ctx: *gcp.GcpContext, key: types.ApiKey) !void {
    var hash_hex: [64]u8 = undefined;
    types.hexEncode(&key.key_hash, &hash_hex);

    const url_base = try keyUrl(ctx.allocator, ctx.project_id, &hash_hex);
    defer ctx.allocator.free(url_base);
    const url = try std.fmt.allocPrint(ctx.allocator, "{s}?updateMask.fieldPaths=revoked", .{url_base});
    defer ctx.allocator.free(url);

    const body =
        \\{"fields":{"revoked":{"booleanValue":true}}}
    ;

    var resp = try ctx.patchFresh(url, body);
    defer resp.deinit();
}

// ── Firestore Document Builders ─────────────────────────────

fn buildAccountDocument(allocator: std.mem.Allocator, account: types.Account) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    var jw: std.json.Stringify = .{ .writer = &aw.writer, .options = .{} };
    try jw.beginObject();
    try jw.objectField("fields");
    try jw.beginObject();
    try writeStringField(&jw, "email", account.email.slice());
    try writeIntField(&jw, "balance_ticks", account.balance_ticks);
    try writeStringField(&jw, "role", account.role.toString());
    try writeStringField(&jw, "tier", account.tier.toString());
    try writeIntField(&jw, "created_at", account.created_at);
    try writeIntField(&jw, "updated_at", account.updated_at);
    try jw.endObject();
    try jw.endObject();
    return aw.toOwnedSlice();
}

fn buildKeyDocument(allocator: std.mem.Allocator, key: types.ApiKey) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    var jw: std.json.Stringify = .{ .writer = &aw.writer, .options = .{} };
    try jw.beginObject();
    try jw.objectField("fields");
    try jw.beginObject();
    try writeStringField(&jw, "account_id", key.account_id.slice());
    try writeStringField(&jw, "name", key.name.slice());
    try writeStringField(&jw, "prefix", key.prefix.slice());
    try writeIntField(&jw, "spent_ticks", key.spent_ticks);
    try writeBoolField(&jw, "revoked", key.revoked);
    try writeIntField(&jw, "created_at", key.created_at);
    try writeIntField(&jw, "expires_at", key.expires_at);
    try writeIntField(&jw, "spend_cap_ticks", key.scope.spend_cap_ticks);
    try writeIntField(&jw, "rate_limit_rpm", key.scope.rate_limit_rpm);
    try writeIntField(&jw, "endpoints", key.scope.endpoints);
    try jw.endObject();
    try jw.endObject();
    return aw.toOwnedSlice();
}

// ── Firestore Document Parsers ──────────────────────────────

fn parseAccountDocument(body: []const u8) ?types.Account {
    const parsed = std.json.parseFromSlice(FirestoreDocument, std.heap.c_allocator, body, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch return null;
    defer parsed.deinit();

    return documentToAccount(parsed.value);
}

fn parseAccountList(allocator: std.mem.Allocator, body: []const u8) ![]types.Account {
    const parsed = std.json.parseFromSlice(FirestoreListResponse, allocator, body, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch return &.{};
    defer parsed.deinit();

    const docs = parsed.value.documents orelse return &.{};
    var result = try allocator.alloc(types.Account, docs.len);
    var count: usize = 0;

    for (docs) |doc| {
        if (documentToAccount(doc)) |account| {
            result[count] = account;
            count += 1;
        }
    }

    return result[0..count];
}

fn parseKeyList(allocator: std.mem.Allocator, body: []const u8) ![]types.ApiKey {
    const parsed = std.json.parseFromSlice(FirestoreListResponse, allocator, body, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch return &.{};
    defer parsed.deinit();

    const docs = parsed.value.documents orelse return &.{};
    var result = try allocator.alloc(types.ApiKey, docs.len);
    var count: usize = 0;

    for (docs) |doc| {
        if (documentToKey(doc)) |key| {
            result[count] = key;
            count += 1;
        }
    }

    return result[0..count];
}

// ── Firestore JSON types ────────────────────────────────────

const FirestoreListResponse = struct {
    documents: ?[]const FirestoreDocument = null,
};

const FirestoreDocument = struct {
    name: ?[]const u8 = null, // "projects/.../documents/collection/docId"
    fields: ?std.json.Value = null,
};

fn getStringField(fields: std.json.Value, key: []const u8) []const u8 {
    if (fields != .object) return "";
    const field = fields.object.get(key) orelse return "";
    if (field != .object) return "";
    const sv = field.object.get("stringValue") orelse return "";
    if (sv == .string) return sv.string;
    return "";
}

fn getIntField(fields: std.json.Value, key: []const u8) i64 {
    if (fields != .object) return 0;
    const field = fields.object.get(key) orelse return 0;
    if (field != .object) return 0;
    const iv = field.object.get("integerValue") orelse return 0;
    if (iv == .string) return std.fmt.parseInt(i64, iv.string, 10) catch 0;
    if (iv == .integer) return iv.integer;
    return 0;
}

fn getBoolField(fields: std.json.Value, key: []const u8) bool {
    if (fields != .object) return false;
    const field = fields.object.get(key) orelse return false;
    if (field != .object) return false;
    const bv = field.object.get("booleanValue") orelse return false;
    if (bv == .bool) return bv.bool;
    return false;
}

fn documentToAccount(doc: FirestoreDocument) ?types.Account {
    const fields = doc.fields orelse return null;

    // Extract doc ID from name path: "projects/.../documents/zig_accounts/{id}"
    const name = doc.name orelse return null;
    const last_slash = std.mem.lastIndexOfScalar(u8, name, '/') orelse return null;
    const doc_id = name[last_slash + 1 ..];

    return .{
        .id = types.FixedStr64.fromSlice(doc_id),
        .email = types.FixedStr256.fromSlice(getStringField(fields, "email")),
        .balance_ticks = getIntField(fields, "balance_ticks"),
        .role = std.meta.stringToEnum(types.Role, getStringField(fields, "role")) orelse .user,
        .tier = std.meta.stringToEnum(types.DevTier, getStringField(fields, "tier")) orelse .free,
        .created_at = getIntField(fields, "created_at"),
        .updated_at = getIntField(fields, "updated_at"),
    };
}

fn documentToKey(doc: FirestoreDocument) ?types.ApiKey {
    const fields = doc.fields orelse return null;

    // Extract key hash from name: "projects/.../documents/zig_keys/{hash_hex}"
    const name = doc.name orelse return null;
    const last_slash = std.mem.lastIndexOfScalar(u8, name, '/') orelse return null;
    const hash_hex = name[last_slash + 1 ..];

    var key = types.ApiKey{};

    // Decode hex hash back to bytes
    if (hash_hex.len == 64) {
        _ = std.fmt.hexToBytes(&key.key_hash, hash_hex) catch return null;
    } else return null;

    key.account_id = types.FixedStr64.fromSlice(getStringField(fields, "account_id"));
    key.name = types.FixedStr128.fromSlice(getStringField(fields, "name"));
    key.prefix = types.FixedStr16.fromSlice(getStringField(fields, "prefix"));
    key.spent_ticks = getIntField(fields, "spent_ticks");
    key.revoked = getBoolField(fields, "revoked");
    key.created_at = getIntField(fields, "created_at");
    key.expires_at = getIntField(fields, "expires_at");
    key.scope.spend_cap_ticks = getIntField(fields, "spend_cap_ticks");
    key.scope.rate_limit_rpm = @intCast(@max(getIntField(fields, "rate_limit_rpm"), 0));
    key.scope.endpoints = @intCast(@max(getIntField(fields, "endpoints"), 0));

    return key;
}
