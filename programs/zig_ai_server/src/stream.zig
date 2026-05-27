// SSE Streaming — real token-by-token streaming from AI providers
// Uses sendMessageStreaming callback to pipe tokens directly to the client.
// No buffering — first token arrives as soon as the provider emits it.
//
// SSE event format (matches QuantumSDK StreamEvent):
//   data: {"type":"content_delta","delta":{"text":"token"}}\n\n
//   data: {"type":"usage","input_tokens":N,"output_tokens":N}\n\n
//   data: {"type":"done"}\n\n

const std = @import("std");
const http = std.http;
const Io = std.Io;
const hs = @import("http-sentinel");
const json_util = @import("json.zig");
const chat_mod = @import("chat.zig");
const billing = @import("billing.zig");
const store_mod = @import("store/store.zig");
const types = @import("store/types.zig");
const security = @import("security.zig");
const ledger_mod = @import("ledger.zig");

/// Context passed to the streaming callback.
///
/// Audit H8: previously this struct used `token_count: u32` incremented
/// in the per-chunk callback and treated as the output-token total at
/// commit time. That is architecturally wrong — providers split text
/// into chunks for transport reasons unrelated to tokenization, so one
/// chunk is not one token. The ledger therefore systematically
/// over-billed bursty streams and under-billed long-block streams.
///
/// The streaming pipeline now uses the provider's structured event
/// stream (`StreamEvent`). The terminal `message_stop` event carries
/// the provider's authoritative `input_tokens` / `output_tokens`; we
/// record those once at conclusion. If the provider doesn't report on
/// `message_stop` (some report on a later event we don't see), we fall
/// back to a byte-count estimate (4 chars/token) derived from
/// `total_text_bytes`, which is at least proportional to actual
/// content rather than to TCP framing.
const StreamCtx = struct {
    writer: *http.BodyWriter,
    allocator: std.mem.Allocator,
    /// Sum of all `text_delta.text.len` bytes observed during the
    /// stream. Used to estimate output tokens when the provider
    /// doesn't supply usage in the `message_stop` event.
    total_text_bytes: usize = 0,
    /// Token counts reported by the provider on the `message_stop`
    /// event. Zero if the provider didn't report.
    reported_input_tokens: u32 = 0,
    reported_output_tokens: u32 = 0,
    errored: bool = false,
};

/// Streaming event callback — invoked once per structured event from
/// the provider (text deltas, tool_use, message_stop, …).
///
/// We forward text deltas to the client as the existing
/// `content_delta` SSE events for protocol compatibility. tool_use
/// variants are dropped on this endpoint — `/qai/v1/chat/stream` is
/// the legacy text-only streaming surface; the agent endpoint owns
/// the tool-aware contract.
///
/// `message_stop` carries provider-reported token usage which we
/// stash on the context for the post-stream billing commit (audit
/// H8). We deliberately don't ledger here — the single billing
/// record is emitted by `handleStreamCore` after the streaming call
/// returns, whether successfully or via error.
fn streamEventCallback(event: hs.ai.common.StreamEvent, context: ?*anyopaque) bool {
    const ctx: *StreamCtx = @alignCast(@ptrCast(context orelse return false));
    if (ctx.errored) return false;

    switch (event) {
        .text_delta => |td| {
            ctx.total_text_bytes += td.text.len;

            // Audit (JSON-IN-FMT): previously this path called
            // `chat_mod.jsonEscape` then interpolated the result
            // into a JSON-shaped `allocPrint` format string. Two
            // allocations, two failure modes, escape-correctness
            // by-convention. The new path streams the SSE frame
            // directly into the body writer through
            // std.json.Stringify — one writer, zero intermediate
            // allocations, escape owned by the standard library.
            writeSseDataEvent(&ctx.writer.writer, .{
                .type = "content_delta",
                .delta = .{ .text = td.text },
            }) catch {
                ctx.errored = true;
                return false;
            };
            ctx.writer.flush() catch {
                ctx.errored = true;
                return false;
            };
        },
        .message_stop => |ms| {
            // Capture authoritative token counts for the post-stream
            // billing commit. Zero means the provider didn't report
            // on this event; we'll fall back to byte estimation.
            if (ms.input_tokens > 0) ctx.reported_input_tokens = ms.input_tokens;
            if (ms.output_tokens > 0) ctx.reported_output_tokens = ms.output_tokens;
        },
        // Tool-call events are not surfaced on the legacy
        // `/qai/v1/chat/stream` contract; the agent endpoint owns
        // those. Silently drop here.
        .tool_use_start, .tool_input_delta, .block_stop => {},
    }

    return true;
}

/// Handle streaming with a pre-read body (called from router when "stream":true detected).
pub fn handleStreamWithBody(
    request: *http.Server.Request,
    allocator: std.mem.Allocator,
    environ_map: *const std.process.Environ.Map,
    io: ?std.Io,
    store: ?*store_mod.Store,
    auth: ?*const types.AuthContext,
    ledger: ?*ledger_mod.Ledger,
    body: []const u8,
) void {
    return handleStreamCore(request, allocator, environ_map, io, store, auth, ledger, body);
}

/// Handle streaming chat request. Writes SSE events directly to the HTTP stream.
pub fn handleStream(
    request: *http.Server.Request,
    allocator: std.mem.Allocator,
    environ_map: *const std.process.Environ.Map,
    io: ?std.Io,
    store: ?*store_mod.Store,
    auth: ?*const types.AuthContext,
    ledger: ?*ledger_mod.Ledger,
) void {
    const body = json_util.readBody(request, allocator, security.Limits.max_chat_body) catch {
        sendSseError(request, "failed to read request body");
        return;
    };
    defer allocator.free(body);
    return handleStreamCore(request, allocator, environ_map, io, store, auth, ledger, body);
}

fn handleStreamCore(
    request: *http.Server.Request,
    allocator: std.mem.Allocator,
    environ_map: *const std.process.Environ.Map,
    io: ?std.Io,
    store: ?*store_mod.Store,
    auth: ?*const types.AuthContext,
    ledger: ?*ledger_mod.Ledger,
    body: []const u8,
) void {
    if (body.len == 0) {
        sendSseError(request, "empty request body");
        return;
    }

    const parsed = std.json.parseFromSlice(chat_mod.ChatRequest, allocator, body, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch {
        sendSseError(request, "invalid JSON");
        return;
    };
    defer parsed.deinit();
    const chat_req = parsed.value;

    // Resolve provider
    const provider_info = chat_mod.resolveProvider(chat_req.model) orelse {
        sendSseError(request, "unknown model");
        return;
    };

    const api_key = hs.ai.getApiKeyFromEnv(environ_map, provider_info.env_var) catch {
        sendSseError(request, "missing provider API key");
        return;
    };

    var client = hs.ai.AIClient.init(allocator, provider_info.provider, .{
        .api_key = api_key,
    }) catch {
        sendSseError(request, "failed to init provider client");
        return;
    };
    defer client.deinit();

    // Build config — max_tokens dynamically capped by billing
    var config = hs.ai.RequestConfig{
        .model = chat_req.model,
        .stream = true,
    };
    if (chat_req.max_tokens) |mt| {
        if (mt > 0 and mt <= @as(i32, @intCast(security.Limits.max_tokens_cap))) {
            config.max_tokens = @intCast(mt);
        }
    }
    if (chat_req.temperature) |t| {
        config.temperature = @floatCast(t);
    }
    if (chat_req.system_prompt) |sp| {
        config.system_prompt = sp;
    }

    // Build conversation context — pass full message history to the provider.
    // Extract last user message as the prompt, everything else as context.
    var prompt: []const u8 = "";
    var context_messages: std.ArrayListUnmanaged(hs.ai.AIMessage) = .empty;
    defer {
        for (context_messages.items) |*msg| msg.deinit();
        context_messages.deinit(allocator);
    }

    for (chat_req.messages, 0..) |msg, i| {
        const content = msg.content orelse "";
        if (i == chat_req.messages.len - 1 and std.mem.eql(u8, msg.role, "user")) {
            prompt = content;
        } else {
            const role = if (std.mem.eql(u8, msg.role, "assistant"))
                hs.ai.common.MessageRole.assistant
            else if (std.mem.eql(u8, msg.role, "system"))
                hs.ai.common.MessageRole.system
            else
                hs.ai.common.MessageRole.user;

            context_messages.append(allocator, .{
                .id = allocator.dupe(u8, "") catch continue,
                .role = role,
                .content = allocator.dupe(u8, content) catch continue,
                .timestamp = 0,
                .allocator = allocator,
            }) catch continue;
        }
    }

    if (prompt.len == 0) {
        sendSseError(request, "no user message found");
        return;
    }

    // Dynamic output capping
    var reservation_id: ?u64 = null;
    if (store) |s| if (auth) |a| if (io) |io_handle| {
        const input_estimate = billing.estimateInputTokens(body.len);
        const result = billing.reserveWithCap(
            s, io_handle, a, chat_req.model,
            config.max_tokens, input_estimate, "/qai/v1/chat/stream",
        ) catch {
            sendSseError(request, "insufficient balance");
            return;
        };
        reservation_id = result.reservation_id;
        config.max_tokens = result.capped_max_tokens;
    };

    // Start SSE response — chunked transfer encoding. Audit H1
    // follow-up: SSE responses previously broadcast a wildcard
    // `access-control-allow-origin: *`, which silently re-opened the
    // CORS hole Batch 14 closed for non-streaming responses. The
    // streaming endpoints now reflect the request's `Origin` only
    // when it is on the env-driven allowlist; mismatched/absent
    // Origin → no CORS header → browsers block the cross-origin call.
    var stream_buf: [4096]u8 = undefined;
    var sse_headers: [4]http.Header = undefined;
    var sse_header_count: usize = 0;
    sse_headers[sse_header_count] = .{ .name = "content-type", .value = "text/event-stream" };
    sse_header_count += 1;
    sse_headers[sse_header_count] = .{ .name = "cache-control", .value = "no-cache" };
    sse_header_count += 1;
    const router_mod = @import("router.zig");
    if (router_mod.matchOrigin(request)) |origin| {
        sse_headers[sse_header_count] = .{ .name = "access-control-allow-origin", .value = origin };
        sse_header_count += 1;
        sse_headers[sse_header_count] = .{ .name = "vary", .value = "Origin" };
        sse_header_count += 1;
    }
    var body_writer = request.respondStreaming(&stream_buf, .{
        .respond_options = .{
            .status = .ok,
            .extra_headers = sse_headers[0..sse_header_count],
            .keep_alive = false,
        },
    }) catch {
        if (reservation_id) |rid| if (store) |s| if (io) |io_handle| billing.rollback(s, io_handle, rid);
        return;
    };

    // Stream events from provider → SSE content_delta events. Audit
    // H8: structured events let us read provider-reported token
    // counts from the `message_stop` event instead of approximating
    // from chunk arrivals.
    var stream_ctx = StreamCtx{
        .writer = &body_writer,
        .allocator = allocator,
    };

    const stream_failed = blk: {
        client.sendMessageStreamingWithEventsAndContext(
            prompt,
            context_messages.items,
            config,
            streamEventCallback,
            &stream_ctx,
        ) catch break :blk true;
        break :blk false;
    };

    // Reconcile the final token counts. Prefer provider-reported,
    // fall back to byte-count estimation. The input estimate from
    // the request body is used only if the provider didn't report
    // one (some providers only emit usage on the very last SSE
    // event which our event-stream parser may miss).
    const body_input_estimate = billing.estimateInputTokens(body.len);
    const final_input_tokens: u32 = if (stream_ctx.reported_input_tokens > 0)
        stream_ctx.reported_input_tokens
    else
        body_input_estimate;
    const final_output_tokens: u32 = if (stream_ctx.reported_output_tokens > 0)
        stream_ctx.reported_output_tokens
    else
        @intCast(@max(stream_ctx.total_text_bytes / 4, 1));

    if (stream_failed) {
        // Provider call errored out — refund the reservation and
        // tell the client the stream is over. Single billing
        // contract still holds: we record nothing in the ledger on
        // a failed stream (H8).
        if (reservation_id) |rid| if (store) |s| if (io) |io_handle| billing.rollback(s, io_handle, rid);
        const err_event: []const u8 = "data: {\"type\":\"error\",\"message\":\"Provider request failed\"}\n\n";
        body_writer.writer.writeAll(err_event) catch {};
        body_writer.writer.writeAll("data: {\"type\":\"done\"}\n\n") catch {};
        body_writer.end() catch {};
        return;
    }

    // Commit billing exactly once for the whole stream lifecycle.
    if (reservation_id) |rid| if (store) |s| if (io) |io_handle| {
        const tier = if (auth) |a| a.account.tier else types.DevTier.free;
        billing.commit(s, io_handle, rid, chat_req.model, final_input_tokens, final_output_tokens, tier);
        if (ledger) |l| {
            // H10: actualCost can fail for unknown models. We skip
            // the ledger row rather than guessing a price — the
            // upstream handler should have rejected the request, but
            // this branch is defense-in-depth.
            if (billing.actualCost(chat_req.model, final_input_tokens, final_output_tokens, tier)) |bill| {
                l.recordBilling(io_handle, if (auth) |a| a.account.id.slice() else "anonymous",
                    if (auth) |a| a.key.prefix.slice() else "none", bill.cost, bill.margin,
                    if (auth) |a| a.account.balance_ticks else 0,
                    "/qai/v1/chat/stream", chat_req.model, final_input_tokens, final_output_tokens, 0);
            } else |_| {}
        }
    };

    // Emit usage event. Stream directly through Stringify — both
    // interpolated values are u32 (safe by construction) but the
    // hand-formatted JSON pattern is the one we're clearing.
    writeSseDataEvent(&body_writer.writer, .{
        .type = "usage",
        .input_tokens = final_input_tokens,
        .output_tokens = final_output_tokens,
    }) catch {};

    // Done
    body_writer.writer.writeAll("data: {\"type\":\"done\"}\n\n") catch {};
    body_writer.end() catch {};
}

/// Send a single SSE error frame + done marker on the error path.
///
/// Audit M10: the previous implementation built the error frame via
/// `std.fmt.allocPrint(std.heap.c_allocator, …)` and *never freed*
/// the result. Failure paths see this function the most, so the
/// drop was a per-error leak primitive — small but unbounded over
/// the life of the process. Error messages are static literals
/// passed from the surrounding handler (cap ~64 bytes); we now
/// format into a fixed stack buffer with `bufPrint` and write
/// nothing to the heap at all. The literal fallback covers the
/// (essentially-impossible) case that the message somehow exceeds
/// the buffer.
///
/// Same CORS-tightening as the success path: reflect Origin only
/// when it matches the env allowlist (audit H1 follow-up).
fn sendSseError(request: *http.Server.Request, message: []const u8) void {
    var stream_buf: [1024]u8 = undefined;
    var sse_headers: [3]http.Header = undefined;
    var sse_header_count: usize = 0;
    sse_headers[sse_header_count] = .{ .name = "content-type", .value = "text/event-stream" };
    sse_header_count += 1;
    const router_mod = @import("router.zig");
    if (router_mod.matchOrigin(request)) |origin| {
        sse_headers[sse_header_count] = .{ .name = "access-control-allow-origin", .value = origin };
        sse_header_count += 1;
        sse_headers[sse_header_count] = .{ .name = "vary", .value = "Origin" };
        sse_header_count += 1;
    }
    var body_writer = request.respondStreaming(&stream_buf, .{
        .respond_options = .{
            .status = .bad_request,
            .extra_headers = sse_headers[0..sse_header_count],
            .keep_alive = false,
        },
    }) catch return;

    // Stream the error event through std.json.Stringify — same
    // pattern as the success path. Stringify owns the escape, so a
    // message containing `"` or `\` round-trips cleanly. We write
    // straight to the body_writer; no intermediate buffer needed
    // (the SSE writer is itself buffered via stream_buf above).
    writeSseDataEvent(&body_writer.writer, .{
        .type = "error",
        .message = message,
    }) catch {};
    body_writer.writer.writeAll("data: {\"type\":\"done\"}\n\n") catch {};
    body_writer.end() catch {};
}

/// Emit one SSE `data: <json>\n\n` event into `writer`. Routes the
/// JSON construction through `std.json.Stringify` so every string
/// field is escaped by the standard library, removing the need for
/// a hand-rolled `jsonEscape` step. `value` is any anonymous struct
/// or named struct/array Stringify knows how to serialize; the
/// outer `data: …\n\n` framing is wire-format SSE, not part of the
/// JSON payload.
fn writeSseDataEvent(writer: *std.Io.Writer, value: anytype) !void {
    try writer.writeAll("data: ");
    var jw: std.json.Stringify = .{ .writer = writer, .options = .{} };
    try jw.write(value);
    try writer.writeAll("\n\n");
}
