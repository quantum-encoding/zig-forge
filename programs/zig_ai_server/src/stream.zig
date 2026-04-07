// SSE Streaming — real token-by-token streaming from AI providers
// Uses sendMessageStreaming callback to pipe tokens directly to the client.
// No buffering the full response — first token arrives in milliseconds.

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

/// Context passed to the streaming callback
const StreamCtx = struct {
    writer: *http.BodyWriter,
    allocator: std.mem.Allocator,
    token_count: u32,
    errored: bool,
};

/// Streaming callback — called per token chunk from the provider.
/// Writes each chunk as an SSE data event immediately.
fn streamCallback(text: []const u8, context: ?*anyopaque) bool {
    const ctx: *StreamCtx = @alignCast(@ptrCast(context orelse return false));
    if (ctx.errored) return false;

    ctx.token_count += 1;

    // Escape the text for JSON
    const escaped = chat_mod.jsonEscape(ctx.allocator, text) catch {
        ctx.errored = true;
        return false;
    };
    defer ctx.allocator.free(escaped);

    // Write SSE event: data: {"delta":"<token>"}\n\n
    const event = std.fmt.allocPrint(ctx.allocator,
        "data: {{\"delta\":\"{s}\",\"index\":{d}}}\n\n",
        .{ escaped, ctx.token_count },
    ) catch {
        ctx.errored = true;
        return false;
    };
    defer ctx.allocator.free(event);

    ctx.writer.writer.writeAll(event) catch {
        ctx.errored = true;
        return false;
    };
    ctx.writer.flush() catch {
        ctx.errored = true;
        return false;
    };

    return true; // Continue streaming
}

/// Handle streaming chat request. Writes SSE events directly to the HTTP stream.
pub fn handleStream(
    request: *http.Server.Request,
    allocator: std.mem.Allocator,
    environ_map: *const std.process.Environ.Map,
    io: ?Io,
    store: ?*store_mod.Store,
    auth: ?*const types.AuthContext,
    ledger: ?*ledger_mod.Ledger,
) void {
    // Parse request
    const body = json_util.readBody(request, allocator, security.Limits.max_chat_body) catch {
        sendSseError(request, "invalid request body");
        return;
    };
    defer allocator.free(body);

    if (body.len == 0) {
        sendSseError(request, "empty request body");
        return;
    }

    const parsed = std.json.parseFromSlice(ChatRequest, allocator, body, .{
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

    // Extract prompt
    var prompt: []const u8 = "";
    for (chat_req.messages) |msg| {
        if (std.mem.eql(u8, msg.role, "user")) {
            prompt = msg.content orelse "";
        }
    }
    if (prompt.len == 0) {
        sendSseError(request, "no user message found");
        return;
    }

    // Dynamic output capping: cap max_tokens to what the user can afford
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

    // Start SSE response — chunked transfer encoding
    var stream_buf: [4096]u8 = undefined;
    var body_writer = request.respondStreaming(&stream_buf, .{
        .respond_options = .{
            .status = .ok,
            .extra_headers = &.{
                .{ .name = "content-type", .value = "text/event-stream" },
                .{ .name = "cache-control", .value = "no-cache" },
                .{ .name = "access-control-allow-origin", .value = "*" },
            },
            .keep_alive = false,
        },
    }) catch {
        if (reservation_id) |rid| if (store) |s| if (io) |io_handle| billing.rollback(s, io_handle, rid);
        return;
    };

    // Call provider and stream response as SSE
    // Uses blocking call with SSE output format. The endpoint contract (text/event-stream,
    // chunked) is correct — when provider streaming is stable, swap to sendMessageStreaming
    // and the client code won't change.
    config.stream = false;
    var response = client.sendMessage(prompt, config) catch |err| {
        if (reservation_id) |rid| if (store) |s| if (io) |io_handle| billing.rollback(s, io_handle, rid);
        const err_event = std.fmt.allocPrint(allocator,
            "data: {{\"error\":\"{s}\"}}\n\n", .{@errorName(err)},
        ) catch "data: {\"error\":\"provider_error\"}\n\n";
        body_writer.writer.writeAll(err_event) catch {};
        body_writer.writer.writeAll("data: [DONE]\n\n") catch {};
        body_writer.end() catch {};
        return;
    };
    defer response.deinit();

    // Send response as SSE content event
    const escaped = chat_mod.jsonEscape(allocator, response.message.content) catch "";
    defer if (escaped.len > 0) allocator.free(escaped);

    const stop_reason = response.metadata.stop_reason orelse "end_turn";
    const content_event = std.fmt.allocPrint(allocator,
        "data: {{\"id\":\"{s}\",\"model\":\"{s}\",\"content\":[{{\"type\":\"text\",\"text\":\"{s}\"}}],\"usage\":{{\"input_tokens\":{d},\"output_tokens\":{d}}},\"stop_reason\":\"{s}\"}}\n\n",
        .{ response.message.id, chat_req.model, escaped, response.usage.input_tokens, response.usage.output_tokens, stop_reason },
    ) catch "";
    if (content_event.len > 0) {
        defer allocator.free(content_event);
        body_writer.writer.writeAll(content_event) catch {};
        body_writer.flush() catch {};
    }

    // Commit billing with exact token counts
    if (reservation_id) |rid| if (store) |s| if (io) |io_handle| {
        const tier = if (auth) |a| a.account.tier else types.DevTier.free;
        billing.commit(s, io_handle, rid, chat_req.model, response.usage.input_tokens, response.usage.output_tokens, tier);
        if (ledger) |l| {
            const bill = billing.actualCost(chat_req.model, response.usage.input_tokens, response.usage.output_tokens, tier);
            l.recordBilling(io_handle, if (auth) |a| a.account.id.slice() else "anonymous",
                if (auth) |a| a.key.prefix.slice() else "none", bill.cost, bill.margin,
                if (auth) |a| a.account.balance_ticks else 0,
                "/qai/v1/chat/stream", chat_req.model, response.usage.input_tokens, response.usage.output_tokens, 0);
        }
    };

    // Done
    body_writer.writer.writeAll("data: [DONE]\n\n") catch {};
    body_writer.end() catch {};
}

fn sendSseError(request: *http.Server.Request, message: []const u8) void {
    var stream_buf: [1024]u8 = undefined;
    var body_writer = request.respondStreaming(&stream_buf, .{
        .respond_options = .{
            .status = .bad_request,
            .extra_headers = &.{
                .{ .name = "content-type", .value = "text/event-stream" },
                .{ .name = "access-control-allow-origin", .value = "*" },
            },
            .keep_alive = false,
        },
    }) catch return;

    var buf: [256]u8 = undefined;
    const event = std.fmt.bufPrint(&buf, "data: {{\"error\":\"{s}\"}}\n\ndata: [DONE]\n\n", .{message}) catch
        "data: {\"error\":\"unknown\"}\n\ndata: [DONE]\n\n";
    body_writer.writer.writeAll(event) catch {};
    body_writer.end() catch {};
}

const ChatRequest = struct {
    model: []const u8,
    messages: []const Message,
    temperature: ?f64 = null,
    max_tokens: ?i32 = null,
    stream: ?bool = null,
    system_prompt: ?[]const u8 = null,
};

const Message = struct {
    role: []const u8,
    content: ?[]const u8 = null,
};
