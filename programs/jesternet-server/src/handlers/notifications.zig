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

    // Build JSON body via std.json.Stringify over an allocating writer
    // backed by the per-request arena. The arena is freed by main.zig's
    // `defer arena.deinit()` after `respond()`, so the slice is valid
    // for the response's send-time. Stringify handles the array commas
    // and all string escaping — no hand-rolled emitter (JSON-IN-FMT
    // corrective).
    var aw = std.Io.Writer.Allocating.init(ctx.allocator);
    var js: std.json.Stringify = .{ .writer = &aw.writer };

    js.beginArray() catch return internalError();

    const Collector = struct {
        js: *std.json.Stringify,
        failed: bool,
    };
    var coll = Collector{ .js = &js, .failed = false };

    ctx.store.iterateRecent(limit, &coll, struct {
        fn cb(raw_ctx: ?*anyopaque, row: types.EventRow) void {
            const c: *Collector = @alignCast(@ptrCast(raw_ctx orelse return));
            if (c.failed) return;
            writeEventJson(c.js, row) catch {
                c.failed = true;
            };
        }
    }.cb);

    if (coll.failed) return internalError();
    js.endArray() catch return internalError();

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

/// Emit one event object into an open JSON array via std.json.Stringify.
///
/// Field ORDER is load-bearing: it mirrors the TS reference's `toItem`
/// (jesternet-astro/src/pages/api/notifications/recent.ts) exactly —
/// `id, kind, title, repo, at, seen, data` — because JSON.stringify
/// preserves insertion order and the conformance suite compares bytes.
/// (The prior hand-rolled emitter had `repo` before `title`, a silent
/// drift from the reference; the byte-exact golden test below now pins
/// the order.)
///
/// Stringify does all string escaping — the bespoke `writeJsonEscaped`
/// helper this replaced is deleted per the repo's JSON-IN-FMT corrective
/// ("pre-existing escape helpers should be deleted; Stringify is
/// already audited"). The one raw-embedded field is `data`, whose bytes
/// were validated as well-formed JSON at insertEvent time (store.zig),
/// so `beginWriteRaw` cannot inject malformed JSON here.
fn writeEventJson(js: *std.json.Stringify, row: types.EventRow) !void {
    try js.beginObject();

    // id: the durable WAL seq, emitted as a STRING (the reference does
    // `String(row.id)`; SSE Last-Event-ID is a text header value). A u64
    // is at most 20 decimal digits, so the buffer is sized to fit and
    // bufPrint cannot overflow — but propagate the error rather than
    // `catch unreachable` (the whole function is already `!void`).
    try js.objectField("id");
    var id_buf: [20]u8 = undefined;
    try js.write(try std.fmt.bufPrint(&id_buf, "{d}", .{row.seq}));

    try js.objectField("kind");
    try js.write(eventKindString(row.kind));

    try js.objectField("title");
    try js.write(row.title.slice());

    try js.objectField("repo");
    try js.write(row.repo.slice());

    try js.objectField("at");
    var iso_buf: [iso.ISO_LEN]u8 = undefined;
    try js.write(iso.fromEpochMs(row.created_at, &iso_buf));

    try js.objectField("seen");
    try js.write(row.seen);

    // data: embed the stored payload verbatim. It is already validated
    // JSON (insertEvent rejects oversize/non-JSON), so raw-embedding
    // avoids a parse-then-re-emit roundtrip. Empty payload → `{}`, the
    // reference's `data = row.payload ? JSON.parse(...) : {}` fallback.
    try js.objectField("data");
    try js.beginWriteRaw();
    const payload_slice = row.payload.slice();
    try js.writer.writeAll(if (payload_slice.len == 0) "{}" else payload_slice);
    js.endWriteRaw();

    try js.endObject();
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

// ── Tests ──
//
// EXTERNAL ANCHOR (zig-forge/CLAUDE.md golden rule §1): the expected
// bytes below are NOT self-authored. They were produced by running the
// TypeScript reference's `toItem()` + `JSON.stringify()` from
// `/Users/director/work/websites/jesternet-astro/src/pages/api/
// notifications/recent.ts` under Node.js — the exact serializer the
// conformance suite asserts against. This pins (a) field order
// (`id, kind, title, repo, at, seen, data`), (b) `id` as a string, (c)
// `seen` as a bool, (d) the empty-payload → `{}` fallback, and (e) the
// `toISOString()` timestamp form. Any drift from the reference wire
// shape now fails the build.

const testing = std.testing;

/// Reproduce handleRecent's array-building over a fixed event set and
/// compare byte-exact against the Node-generated reference output.
fn renderEventsForTest(alloc: std.mem.Allocator, rows: []const types.EventRow) ![]u8 {
    var aw = std.Io.Writer.Allocating.init(alloc);
    errdefer aw.deinit();
    var js: std.json.Stringify = .{ .writer = &aw.writer };
    try js.beginArray();
    for (rows) |row| try writeEventJson(&js, row);
    try js.endArray();
    return aw.toOwnedSlice();
}

test "recent.ts byte-exact golden (single event)" {
    const row = types.EventRow{
        .seq = 42,
        .kind = .commit_pushed,
        .title = types.FixedStr256.fromSlice("push: main -> abc"),
        .repo = types.FixedStr128.fromSlice("jak/foo"),
        .payload = types.FixedStr512.fromSlice("{\"branch\":\"main\",\"sha\":\"abc123\"}"),
        .seen = false,
        .created_at = 1779369255678,
    };

    const out = try renderEventsForTest(testing.allocator, &.{row});
    defer testing.allocator.free(out);

    // From: node → JSON.stringify([toItem(ev1)]) against recent.ts.
    const golden =
        "[{\"id\":\"42\",\"kind\":\"commit.pushed\",\"title\":\"push: main -> abc\"," ++
        "\"repo\":\"jak/foo\",\"at\":\"2026-05-21T13:14:15.678Z\",\"seen\":false," ++
        "\"data\":{\"branch\":\"main\",\"sha\":\"abc123\"}}]";
    try testing.expectEqualStrings(golden, out);
}

test "recent.ts byte-exact golden (array, empty payload → {})" {
    const rows = [_]types.EventRow{
        .{
            .seq = 42,
            .kind = .commit_pushed,
            .title = types.FixedStr256.fromSlice("push: main -> abc"),
            .repo = types.FixedStr128.fromSlice("jak/foo"),
            .payload = types.FixedStr512.fromSlice("{\"branch\":\"main\",\"sha\":\"abc123\"}"),
            .seen = false,
            .created_at = 1779369255678,
        },
        .{
            .seq = 7,
            .kind = .pr_merged,
            .title = types.FixedStr256.fromSlice("PR #7 merged"),
            .repo = types.FixedStr128.fromSlice("jak/forge"),
            .payload = types.FixedStr512.fromSlice(""), // empty → {}
            .seen = true,
            .created_at = 1704164645006,
        },
    };

    const out = try renderEventsForTest(testing.allocator, &rows);
    defer testing.allocator.free(out);

    // From: node → JSON.stringify([toItem(ev1), toItem(ev2)]) against recent.ts.
    const golden =
        "[{\"id\":\"42\",\"kind\":\"commit.pushed\",\"title\":\"push: main -> abc\"," ++
        "\"repo\":\"jak/foo\",\"at\":\"2026-05-21T13:14:15.678Z\",\"seen\":false," ++
        "\"data\":{\"branch\":\"main\",\"sha\":\"abc123\"}}," ++
        "{\"id\":\"7\",\"kind\":\"pr.merged\",\"title\":\"PR #7 merged\"," ++
        "\"repo\":\"jak/forge\",\"at\":\"2024-01-02T03:04:05.006Z\",\"seen\":true," ++
        "\"data\":{}}]";
    try testing.expectEqualStrings(golden, out);
}

test "writeEventJson escapes quotes/backslashes in title (Stringify, not hand-rolled)" {
    // The bespoke escaper is gone; Stringify must still escape a title
    // containing a quote and a backslash so the array stays valid JSON.
    const row = types.EventRow{
        .seq = 1,
        .kind = .commit_pushed,
        .title = types.FixedStr256.fromSlice("say \"hi\" \\ bye"),
        .repo = types.FixedStr128.fromSlice("jak/foo"),
        .payload = types.FixedStr512.fromSlice(""),
        .seen = false,
        .created_at = 0,
    };
    const out = try renderEventsForTest(testing.allocator, &.{row});
    defer testing.allocator.free(out);

    const golden =
        "[{\"id\":\"1\",\"kind\":\"commit.pushed\"," ++
        "\"title\":\"say \\\"hi\\\" \\\\ bye\"," ++
        "\"repo\":\"jak/foo\",\"at\":\"1970-01-01T00:00:00.000Z\",\"seen\":false," ++
        "\"data\":{}}]";
    try testing.expectEqualStrings(golden, out);
}
