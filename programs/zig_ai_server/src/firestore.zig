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

    var resp = try ctx.patch(url, body);
    defer resp.deinit();
    // 200 = updated, 404 would mean collection doesn't exist (auto-creates)
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

    var resp = try ctx.patch(url, body);
    defer resp.deinit();
}

pub fn updateAccountBalance(ctx: *gcp.GcpContext, account_id: []const u8, balance_ticks: i64) !void {
    const url_base = try accountUrl(ctx.allocator, ctx.project_id, account_id);
    defer ctx.allocator.free(url_base);
    // Use updateMask to only update balance_ticks field
    const url = try std.fmt.allocPrint(ctx.allocator, "{s}?updateMask.fieldPaths=balance_ticks&updateMask.fieldPaths=updated_at", .{url_base});
    defer ctx.allocator.free(url);

    const body = try std.fmt.allocPrint(ctx.allocator,
        \\{{"fields":{{"balance_ticks":{{"integerValue":"{d}"}},"updated_at":{{"integerValue":"{d}"}}}}}}
    , .{ balance_ticks, types.nowMs() });
    defer ctx.allocator.free(body);

    var resp = try ctx.patch(url, body);
    defer resp.deinit();
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

    var resp = try ctx.patch(url, body);
    defer resp.deinit();
}

// ── Firestore Document Builders ─────────────────────────────

fn buildAccountDocument(allocator: std.mem.Allocator, account: types.Account) ![]u8 {
    return std.fmt.allocPrint(allocator,
        \\{{"fields":{{"email":{{"stringValue":"{s}"}},"balance_ticks":{{"integerValue":"{d}"}},"role":{{"stringValue":"{s}"}},"tier":{{"stringValue":"{s}"}},"created_at":{{"integerValue":"{d}"}},"updated_at":{{"integerValue":"{d}"}}}}}}
    , .{
        account.email.slice(),
        account.balance_ticks,
        account.role.toString(),
        account.tier.toString(),
        account.created_at,
        account.updated_at,
    });
}

fn buildKeyDocument(allocator: std.mem.Allocator, key: types.ApiKey) ![]u8 {
    return std.fmt.allocPrint(allocator,
        \\{{"fields":{{"account_id":{{"stringValue":"{s}"}},"name":{{"stringValue":"{s}"}},"prefix":{{"stringValue":"{s}"}},"spent_ticks":{{"integerValue":"{d}"}},"revoked":{{"booleanValue":{s}}},"created_at":{{"integerValue":"{d}"}},"expires_at":{{"integerValue":"{d}"}},"spend_cap_ticks":{{"integerValue":"{d}"}},"rate_limit_rpm":{{"integerValue":"{d}"}},"endpoints":{{"integerValue":"{d}"}}}}}}
    , .{
        key.account_id.slice(),
        key.name.slice(),
        key.prefix.slice(),
        key.spent_ticks,
        if (key.revoked) "true" else "false",
        key.created_at,
        key.expires_at,
        key.scope.spend_cap_ticks,
        key.scope.rate_limit_rpm,
        key.scope.endpoints,
    });
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
        .id = types.FixedStr32.fromSlice(doc_id),
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

    key.account_id = types.FixedStr32.fromSlice(getStringField(fields, "account_id"));
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
