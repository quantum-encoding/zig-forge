// User-reported moderation endpoint — POST /qai/v1/moderate
//
// Wire-compatible with the Go /qai/v1/moderate handler. Apps shipped through
// the Quantum SDK must (per Play Store / App Store rules for AI-generated
// content) expose a user-visible "report" button whose report reaches the
// operator. This endpoint records the report to the Firestore
// `moderation_reports` collection for operator review.
//
//   request:  { conversation_id, message_id, content, reason?, source_app? }
//   response: { report_id, status: "received" }
//
// Auth required (standard qai_k_ Bearer — enforced by the router before this
// handler runs). The reporting user (id + email) is recorded so multi-report
// patterns from a single user can be inspected. The reported content is
// stored verbatim — that's the point; an operator needs to see what was said.
//
// App identification priority: X-Quantum-App header → source_app body field →
// "unknown" (same convention as the chat trial gate).

const std = @import("std");
const http = std.http;
const json_util = @import("json.zig");
const router = @import("router.zig");
const security = @import("security.zig");
const gcp = @import("gcp.zig");
const types = @import("store/types.zig");
const Response = router.Response;

// Validation caps — mirror the Go handler. Content gets the most headroom
// because real reports about long AI replies need to capture them in full.
const MAX_CONTENT_LEN: usize = 50_000; // 50KB — covers any plausible AI reply
const MAX_REASON_LEN: usize = 1_000;
const MAX_ID_LEN: usize = 200; // conversation_id, message_id
const MAX_APP_TAG_LEN: usize = 64; // X-Quantum-App / source_app — slugs only

const ModerateRequest = struct {
    conversation_id: []const u8 = "",
    message_id: []const u8 = "",
    content: []const u8 = "",
    reason: []const u8 = "",
    source_app: []const u8 = "",
};

/// POST /qai/v1/moderate
pub fn handle(
    request: *http.Server.Request,
    allocator: std.mem.Allocator,
    io: std.Io,
    auth: *const types.AuthContext,
    gcp_ctx: ?*gcp.GcpContext,
) Response {
    // The report has to land somewhere durable; without Firestore wired we
    // can't honour the store-rule contract, so fail loud rather than silently
    // dropping the report.
    const ctx = gcp_ctx orelse return errResp(.service_unavailable, "moderation reporting unavailable: server has no Firestore backend");

    const body = json_util.readBody(request, allocator, MAX_CONTENT_LEN + 4096) catch {
        return errResp(.bad_request, "Failed to read request body");
    };
    defer allocator.free(body);
    if (body.len == 0) return errResp(.bad_request, "Empty request body");

    const parsed = std.json.parseFromSlice(ModerateRequest, allocator, body, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch {
        return errResp(.bad_request, "Malformed JSON body");
    };
    defer parsed.deinit();

    // Trim + validate (mirrors validateModerateRequest).
    const ws = " \t\r\n";
    const conversation_id = std.mem.trim(u8, parsed.value.conversation_id, ws);
    const message_id = std.mem.trim(u8, parsed.value.message_id, ws);
    const content = std.mem.trim(u8, parsed.value.content, ws);
    const reason = std.mem.trim(u8, parsed.value.reason, ws);
    const source_app = std.mem.trim(u8, parsed.value.source_app, ws);

    if (content.len == 0) return errResp(.bad_request, "content is required");
    if (content.len > MAX_CONTENT_LEN) return errResp(.bad_request, "content exceeds 50000 chars");
    if (reason.len > MAX_REASON_LEN) return errResp(.bad_request, "reason exceeds 1000 chars");
    if (conversation_id.len > MAX_ID_LEN) return errResp(.bad_request, "conversation_id exceeds 200 chars");
    if (message_id.len > MAX_ID_LEN) return errResp(.bad_request, "message_id exceeds 200 chars");
    if (source_app.len > MAX_APP_TAG_LEN) return errResp(.bad_request, "source_app exceeds 64 chars");

    // CRLF rejection on identifier fields — these flow into operator review
    // tooling + structured logs. Content is deliberately exempt (real AI
    // replies span multiple lines); it's escaped where displayed.
    if (containsCrlf(conversation_id) or containsCrlf(message_id) or
        containsCrlf(source_app) or containsCrlf(reason))
    {
        return errResp(.bad_request, "identifier field contains disallowed characters");
    }

    // App identification: X-Quantum-App header → source_app → "unknown".
    var app = std.mem.trim(u8, headerValue(request, "x-quantum-app") orelse "", ws);
    if (app.len == 0) app = source_app;
    if (app.len == 0) app = "unknown";
    if (app.len > MAX_APP_TAG_LEN or containsCrlf(app)) app = "unknown";

    // Generate a Firestore-style 20-char alphanumeric document ID.
    var id_buf: [20]u8 = undefined;
    generateDocId(io, &id_buf);
    const report_id = id_buf[0..];

    // Build the typed Firestore document and PATCH it (create-or-update; a
    // fresh random ID means this creates). All string values go through
    // std.json.Stringify so caller-controlled content is escaped, never
    // hand-interpolated (JSON-IN-FMT).
    const doc = buildDocument(allocator, .{
        .user_id = auth.account.id.slice(),
        .reporter_email = auth.account.email.slice(),
        .app = app,
        .conversation_id = conversation_id,
        .message_id = message_id,
        .content = content,
        .reason = reason,
        .reported_at_ms = types.nowMs(io),
    }) catch {
        return errResp(.internal_server_error, "could not build moderation report");
    };
    defer allocator.free(doc);

    const url = std.fmt.allocPrint(
        allocator,
        "https://firestore.googleapis.com/v1/projects/{s}/databases/(default)/documents/moderation_reports/{s}",
        .{ ctx.project_id, report_id },
    ) catch {
        return errResp(.internal_server_error, "could not record report — please retry");
    };
    defer allocator.free(url);

    var resp = ctx.patchFresh(url, doc) catch {
        return errResp(.internal_server_error, "could not record report — please retry");
    };
    defer resp.deinit();

    if (@intFromEnum(resp.status) >= 400) {
        std.debug.print("  moderation report write failed: HTTP {d} (app={s})\n", .{ @intFromEnum(resp.status), app });
        return errResp(.internal_server_error, "could not record report — please retry");
    }

    const out = std.json.Stringify.valueAlloc(allocator, .{
        .report_id = report_id,
        .status = "received",
    }, .{}) catch {
        return errResp(.internal_server_error, "report recorded but response serialization failed");
    };
    return .{ .status = .ok, .body = out };
}

const DocFields = struct {
    user_id: []const u8,
    reporter_email: []const u8,
    app: []const u8,
    conversation_id: []const u8,
    message_id: []const u8,
    content: []const u8,
    reason: []const u8,
    reported_at_ms: i64,
};

/// Build the Firestore typed-field document body. Mirrors the field set of
/// the Go handler's `moderation_reports` write. `reported_at` is stored as
/// an integer epoch-ms (`reported_at_ms`) rather than a Firestore timestamp
/// to avoid fragile RFC3339 formatting in the hot path — operator tooling
/// formats it on read.
fn buildDocument(allocator: std.mem.Allocator, f: DocFields) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    var jw: std.json.Stringify = .{ .writer = &aw.writer, .options = .{} };

    try jw.beginObject();
    try jw.objectField("fields");
    try jw.beginObject();
    try writeStringField(&jw, "user_id", f.user_id);
    try writeStringField(&jw, "reporter_email", f.reporter_email);
    try writeStringField(&jw, "app", f.app);
    try writeStringField(&jw, "conversation_id", f.conversation_id);
    try writeStringField(&jw, "message_id", f.message_id);
    try writeStringField(&jw, "content", f.content);
    try writeIntField(&jw, "content_length", @as(i64, @intCast(f.content.len)));
    try writeStringField(&jw, "reason", f.reason);
    try writeIntField(&jw, "reported_at_ms", f.reported_at_ms);
    try writeStringField(&jw, "status", "pending"); // pending → reviewing → resolved
    try jw.endObject();
    try jw.endObject();

    return aw.toOwnedSlice();
}

// Firestore typed-value field writers (same envelope as firestore.zig).
fn writeStringField(jw: *std.json.Stringify, name: []const u8, value: []const u8) !void {
    try jw.objectField(name);
    try jw.beginObject();
    try jw.objectField("stringValue");
    try jw.write(value);
    try jw.endObject();
}

fn writeIntField(jw: *std.json.Stringify, name: []const u8, value: i64) !void {
    try jw.objectField(name);
    try jw.beginObject();
    try jw.objectField("integerValue");
    // Firestore int64 is wire-encoded as a string.
    var buf: [24]u8 = undefined;
    const s = try std.fmt.bufPrint(&buf, "{d}", .{value});
    try jw.write(s);
    try jw.endObject();
}

fn containsCrlf(s: []const u8) bool {
    return std.mem.indexOfAny(u8, s, "\r\n") != null;
}

/// Case-insensitive header lookup. Returns the first matching value (slice
/// borrows the request's header buffer, valid until respond()).
fn headerValue(request: *http.Server.Request, name: []const u8) ?[]const u8 {
    var it = request.iterateHeaders();
    while (it.next()) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
    }
    return null;
}

const DOC_ID_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";

/// Fill `out` with a Firestore-style random alphanumeric document ID.
/// Uses the injected CSPRNG (`io.random`, same source keys.zig/apple_auth.zig
/// use) — collision probability over 20 chars of a 62-symbol alphabet is
/// negligible, so a plain create-via-PATCH is safe.
fn generateDocId(io: std.Io, out: []u8) void {
    var rand_bytes: [64]u8 = undefined;
    io.random(rand_bytes[0..out.len]);
    for (out, 0..) |*c, i| {
        c.* = DOC_ID_ALPHABET[rand_bytes[i] % DOC_ID_ALPHABET.len];
    }
}

fn errResp(status: http.Status, message: []const u8) Response {
    _ = message;
    return switch (status) {
        .bad_request => .{ .status = .bad_request, .body = "{\"error\":\"invalid_request\",\"message\":\"Moderation report rejected\"}" },
        .service_unavailable => .{ .status = .service_unavailable, .body = "{\"error\":\"unavailable\",\"message\":\"Moderation reporting is unavailable: server has no Firestore backend\"}" },
        else => .{ .status = .internal_server_error, .body = "{\"error\":\"internal\",\"message\":\"Could not record moderation report — please retry\"}" },
    };
}
