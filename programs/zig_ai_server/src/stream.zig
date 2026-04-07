// SSE Streaming — Server-Sent Events for real-time AI responses
// Uses chunked transfer encoding via std.http.Server.respondStreaming
//
// SSE format:
//   data: {"content":"token..."}\n\n
//   data: [DONE]\n\n
//
// Phase 1: Provider call is blocking, response streamed as single SSE event.
// Phase 2 (future): Token-by-token streaming from providers.

const std = @import("std");
const http = std.http;
const Io = std.Io;
const hs = @import("http-sentinel");
const json_util = @import("json.zig");
const chat_mod = @import("chat.zig");
const billing = @import("billing.zig");
const models_mod = @import("models.zig");
const store_mod = @import("store/store.zig");
const types = @import("store/types.zig");
const security = @import("security.zig");
const router = @import("router.zig");
const ledger_mod = @import("ledger.zig");

/// Handle streaming chat request. Takes ownership of the response stream.
/// Returns void because we write directly to the HTTP body writer.
pub fn handleStream(
    request: *http.Server.Request,
    allocator: std.mem.Allocator,
    environ_map: *const std.process.Environ.Map,
    io: ?Io,
    store: ?*store_mod.Store,
    auth: ?*const types.AuthContext,
    ledger: ?*ledger_mod.Ledger,
) void {
    // Parse request body
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

    // Get API key
    const api_key = hs.ai.getApiKeyFromEnv(environ_map, provider_info.env_var) catch {
        sendSseError(request, "missing provider API key");
        return;
    };

    // Init client
    var client = hs.ai.AIClient.init(allocator, provider_info.provider, .{
        .api_key = api_key,
    }) catch {
        sendSseError(request, "failed to init provider client");
        return;
    };
    defer client.deinit();

    // Build config
    var config = hs.ai.RequestConfig{
        .model = chat_req.model,
    };
    if (chat_req.max_tokens) |mt| {
        config.max_tokens = if (mt > 0 and mt <= @as(i32, @intCast(security.Limits.max_tokens_cap)))
            @intCast(mt)
        else
            4096;
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

    // Billing reserve
    var reservation_id: ?u64 = null;
    if (store) |s| {
        if (auth) |a| {
            if (io) |io_handle| {
                reservation_id = billing.reserve(s, io_handle, a, chat_req.model, config.max_tokens, "/qai/v1/chat") catch {
                    sendSseError(request, "insufficient balance");
                    return;
                };
            }
        }
    }

    // Start SSE response (chunked transfer encoding)
    var stream_buf: [4096]u8 = undefined;
    var body_writer = request.respondStreaming(&stream_buf, .{
        .respond_options = .{
            .status = .ok,
            .extra_headers = &.{
                .{ .name = "content-type", .value = "text/event-stream" },
                .{ .name = "cache-control", .value = "no-cache" },
                .{ .name = "access-control-allow-origin", .value = "*" },
            },
            .keep_alive = false, // SSE connections are not reused
        },
    }) catch {
        // Rollback if we can't even start streaming
        if (reservation_id) |rid| if (store) |s| if (io) |io_handle| billing.rollback(s, io_handle, rid);
        return;
    };

    // Call provider (blocking for now — Phase 2 will stream tokens)
    var response = client.sendMessage(prompt, config) catch |err| {
        // Rollback billing
        if (reservation_id) |rid| if (store) |s| if (io) |io_handle| billing.rollback(s, io_handle, rid);

        // Send error event
        const err_event = std.fmt.allocPrint(allocator,
            "data: {{\"error\":\"{s}\"}}\n\n", .{@errorName(err)},
        ) catch "data: {\"error\":\"provider_error\"}\n\n";
        body_writer.writer.writeAll(err_event) catch {};
        if (err_event.ptr != "data: {\"error\":\"provider_error\"}\n\n".ptr) allocator.free(err_event);
        body_writer.writer.writeAll("data: [DONE]\n\n") catch {};
        body_writer.end() catch {};
        return;
    };
    defer response.deinit();

    // Commit billing
    if (reservation_id) |rid| if (store) |s| if (io) |io_handle| {
        const tier = if (auth) |a| a.account.tier else types.DevTier.free;
        billing.commit(s, io_handle, rid, chat_req.model, response.usage.input_tokens, response.usage.output_tokens, tier);
    };

    // Ledger
    if (ledger) |l| if (io) |io_handle| {
        const bill = billing.actualCost(
            chat_req.model,
            response.usage.input_tokens,
            response.usage.output_tokens,
            if (auth) |a| a.account.tier else types.DevTier.free,
        );
        const acct_id = if (auth) |a| a.account.id.slice() else "anonymous";
        const key_pfx = if (auth) |a| a.key.prefix.slice() else "none";
        const bal = if (auth) |a| a.account.balance_ticks else 0;
        l.recordBilling(io_handle, acct_id, key_pfx, bill.cost, bill.margin, bal, "/qai/v1/chat", chat_req.model, response.usage.input_tokens, response.usage.output_tokens, 0);
    };

    // Stream the response as SSE events
    // For Phase 1, send the complete response as a single content event
    const escaped = chat_mod.jsonEscape(allocator, response.message.content) catch "";
    defer if (escaped.len > 0) allocator.free(escaped);

    const stop_reason = response.metadata.stop_reason orelse "end_turn";
    const cost = billing.actualCost(
        chat_req.model,
        response.usage.input_tokens,
        response.usage.output_tokens,
        if (auth) |a| a.account.tier else types.DevTier.free,
    );
    const cost_ticks = cost.cost + cost.margin;

    // Content event
    const content_event = std.fmt.allocPrint(allocator,
        "data: {{\"id\":\"{s}\",\"model\":\"{s}\",\"content\":[{{\"type\":\"text\",\"text\":\"{s}\"}}],\"usage\":{{\"input_tokens\":{d},\"output_tokens\":{d},\"cost_ticks\":{d}}},\"stop_reason\":\"{s}\"}}\n\n",
        .{
            response.message.id,
            chat_req.model,
            escaped,
            response.usage.input_tokens,
            response.usage.output_tokens,
            cost_ticks,
            stop_reason,
        },
    ) catch {
        body_writer.writer.writeAll("data: {\"error\":\"serialization_error\"}\n\n") catch {};
        body_writer.writer.writeAll("data: [DONE]\n\n") catch {};
        body_writer.end() catch {};
        return;
    };
    defer allocator.free(content_event);

    body_writer.writer.writeAll(content_event) catch {};
    body_writer.flush() catch {};

    // Done event
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
    const event = std.fmt.bufPrint(&buf, "data: {{\"error\":\"{s}\"}}\n\ndata: [DONE]\n\n", .{message}) catch "data: {\"error\":\"unknown\"}\n\ndata: [DONE]\n\n";
    body_writer.writer.writeAll(event) catch {};
    body_writer.end() catch {};
}

// Request type (same as chat.zig)
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
