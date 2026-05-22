// Layer C notifications handlers — recent + seen.
//
// The SSE stream handler (GET /api/notifications/stream) is a focused
// follow-up; it needs careful poll-loop construction with backpressure
// and is its own milestone.
//
// Auth model: `any_authenticated` — any valid PAT (or future session)
// passes. The events the bell surfaces span repos the user can see;
// per-repo gating happens at the events INSERT side, not the read side.
// This matches the TS reference's recent.ts + seen.ts (post the auth
// hardening landed in commit 82ffb12).

const std = @import("std");
const http = std.http;

const router = @import("../router.zig");
const pipeline = @import("../auth/pipeline.zig");
const types = @import("../store/types.zig");
const iso = @import("iso_timestamp.zig");

/// GET /api/notifications/recent?limit=N
///
/// Returns a JSON array of the most-recently-inserted events
/// (newest-first). `?limit=N` defaults to 10, capped at 50, mirroring
/// the TS reference's bounds.
pub fn handleRecent(request: *http.Server.Request, ctx: router.HandlerCtx) router.Response {
    // Auth gate — `any_authenticated`: any valid PAT passes.
    const auth = pipeline.authorize(
        request,
        ctx.now_ms,
        ctx.store.tokenStore(ctx.io),
        .any_authenticated,
    );
    switch (auth) {
        .denied => |err| return .{
            .status = err.status,
            .body = err.body,
            .headers = &router.headers_json_cors,
        },
        .ok => {},
    }

    // Parse `?limit=N`. Defaults to 10, capped at 50. Negative or
    // malformed values get the default.
    var limit: usize = 10;
    const target = request.head.target;
    if (std.mem.indexOfScalar(u8, target, '?')) |q_start| {
        var iter = std.mem.tokenizeScalar(u8, target[q_start + 1 ..], '&');
        while (iter.next()) |pair| {
            if (std.mem.startsWith(u8, pair, "limit=")) {
                const v = pair["limit=".len..];
                if (std.fmt.parseInt(usize, v, 10)) |n| {
                    limit = @min(n, 50);
                    if (limit == 0) limit = 10;
                } else |_| {}
            }
        }
    }

    // Build JSON body via an allocating writer backed by the per-
    // request arena. The arena is freed by main.zig's `defer
    // arena.deinit()` after `respond()`, so the slice is valid for
    // the response's send-time.
    var aw = std.Io.Writer.Allocating.init(ctx.allocator);
    const w = &aw.writer;

    w.writeAll("[") catch return internalError();

    const Collector = struct {
        writer: *std.Io.Writer,
        first: bool,
        oom: bool,
    };
    var coll = Collector{ .writer = w, .first = true, .oom = false };

    ctx.store.iterateRecent(limit, &coll, struct {
        fn cb(raw_ctx: ?*anyopaque, row: types.EventRow) void {
            const c: *Collector = @alignCast(@ptrCast(raw_ctx orelse return));
            if (c.oom) return;
            writeEventJson(c.writer, row, c.first) catch {
                c.oom = true;
                return;
            };
            c.first = false;
        }
    }.cb);

    if (coll.oom) return internalError();
    w.writeAll("]") catch return internalError();

    return .{
        .status = .ok,
        .body = aw.writer.buffered(),
        .headers = &router.headers_json_cors,
    };
}

/// POST /api/notifications/seen
///
/// Body: `{"upTo": <seq>}`. Marks all events with seq <= upTo as
/// seen. Idempotent (replaying a smaller upTo doesn't un-mark).
/// 204 No Content on success.
pub fn handleSeen(request: *http.Server.Request, ctx: router.HandlerCtx) router.Response {
    const auth = pipeline.authorize(
        request,
        ctx.now_ms,
        ctx.store.tokenStore(ctx.io),
        .any_authenticated,
    );
    switch (auth) {
        .denied => |err| return .{
            .status = err.status,
            .body = err.body,
            .headers = &router.headers_json_cors,
        },
        .ok => {},
    }

    // Read body. Bounded to a small size — we only expect a tiny
    // JSON object here ({"upTo": N}).
    const SEEN_BODY_LIMIT: usize = 256;
    var body_buf: [256]u8 = undefined;
    const body_reader = request.readerExpectNone(&body_buf);
    const body = body_reader.allocRemaining(ctx.allocator, .limited(SEEN_BODY_LIMIT)) catch {
        return invalidRequest("Failed to read body");
    };

    // Parse `{"upTo": N}` — std.json since we want robustness against
    // whitespace and key ordering.
    const Parsed = struct { upTo: ?u64 = null };
    var parsed = std.json.parseFromSlice(Parsed, ctx.allocator, body, .{
        .ignore_unknown_fields = true,
    }) catch return invalidRequest("Body must be JSON {\"upTo\": <seq>}");
    defer parsed.deinit();

    const up_to = parsed.value.upTo orelse return invalidRequest("Missing required field: upTo");

    ctx.store.markEventsSeenUpTo(ctx.io, up_to) catch {
        return internalError();
    };

    return .{
        .status = .no_content,
        .body = "",
        .headers = &router.headers_json_cors,
    };
}

// ── helpers ──

fn writeEventJson(w: *std.Io.Writer, row: types.EventRow, is_first: bool) !void {
    if (!is_first) try w.writeAll(",");
    try w.writeAll("{\"id\":\"");
    try w.print("{d}", .{row.seq});
    try w.writeAll("\",\"kind\":\"");
    try w.writeAll(eventKindString(row.kind));
    try w.writeAll("\",\"repo\":\"");
    try writeJsonEscaped(w, row.repo.slice());
    try w.writeAll("\",\"title\":\"");
    try writeJsonEscaped(w, row.title.slice());
    try w.writeAll("\",\"at\":\"");
    var iso_buf: [iso.ISO_LEN]u8 = undefined;
    const iso_str = iso.fromEpochMs(row.created_at, &iso_buf);
    try w.writeAll(iso_str);
    try w.writeAll("\",\"seen\":");
    try w.writeAll(if (row.seen) "true" else "false");

    // Data field: embed the stored payload as JSON. The payload is
    // already JSON (insertEvent's contract); embedding raw avoids
    // a parse-then-re-emit roundtrip. If the payload is empty,
    // emit an empty object so the field has a stable shape.
    const payload_slice = row.payload.slice();
    try w.writeAll(",\"data\":");
    if (payload_slice.len == 0) {
        try w.writeAll("{}");
    } else {
        try w.writeAll(payload_slice);
    }

    try w.writeAll("}");
}

/// EventKind enum → string form. Mirrors the TS reference's EventKind
/// union (kebab-case-with-dots) so the wire shape is identical.
fn eventKindString(kind: types.EventKind) []const u8 {
    return switch (kind) {
        .commit_pushed => "commit.pushed",
        .build_success => "build.success",
        .build_failure => "build.failure",
        .deploy_success => "deploy.success",
        .deploy_failure => "deploy.failure",
        .pr_opened => "pr.opened",
        .pr_closed => "pr.closed",
        .pr_merged => "pr.merged",
        .pr_commented => "pr.commented",
    };
}

/// Minimal JSON string-escaper. Handles the four characters that
/// MUST be escaped per RFC 8259 §7 (quote, backslash, control chars
/// < 0x20). Non-control extended UTF-8 passes through unchanged
/// because JSON strings are Unicode and the input from FixedString
/// is already byte-encoded UTF-8.
fn writeJsonEscaped(w: *std.Io.Writer, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            0...0x08, 0x0b, 0x0c, 0x0e...0x1f => try w.print("\\u{x:0>4}", .{c}),
            else => try w.writeByte(c),
        }
    }
}

const body_internal_error =
    \\{"error":"internal","message":"Server error while building response"}
;

fn internalError() router.Response {
    return .{
        .status = .internal_server_error,
        .body = body_internal_error,
        .headers = &router.headers_json_cors,
    };
}

fn invalidRequest(comptime message: []const u8) router.Response {
    const body = "{\"error\":\"bad-request\",\"message\":\"" ++ message ++ "\"}";
    return .{
        .status = .bad_request,
        .body = body,
        .headers = &router.headers_json_cors,
    };
}
