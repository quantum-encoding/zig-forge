// Chat cost estimate — POST /qai/v1/chat/estimate
//
// Wire-compatible with the Go /qai/v1/chat/estimate handler: same ChatRequest
// shape, no provider round-trip, no credit deduction. Clients call this
// BEFORE /qai/v1/chat to render an "estimated cost" hint and to short-circuit
// when the user couldn't afford the call.
//
//   response: { estimated_cost_ticks, estimated_cost_usd, model }
//
// Estimate model mirrors estimatePessimisticChatTicks: input tokens ≈
// chars/3 + 1, output ceiling = max_tokens (or 8192 pessimistic default),
// priced via the registry with the account-tier margin. Unknown models fail
// CLOSED with a high pessimistic ceiling ($5) so an unfunded account is gated
// and the missing-price misconfiguration surfaces, rather than estimating $0
// and letting the real call ride free.

const std = @import("std");
const http = std.http;
const json_util = @import("json.zig");
const router = @import("router.zig");
const chat = @import("chat.zig");
const billing = @import("billing.zig");
const security = @import("security.zig");
const types = @import("store/types.zig");
const Response = router.Response;

const TICKS_PER_USD: i64 = 10_000_000_000;
const DEFAULT_PESSIMISTIC_OUTPUT_TOKENS: u32 = 8192;
const UNKNOWN_MODEL_PESSIMISTIC_TICKS: i64 = 5 * TICKS_PER_USD;

pub fn handle(
    request: *http.Server.Request,
    allocator: std.mem.Allocator,
    auth: *const types.AuthContext,
) Response {
    const body = json_util.readBody(request, allocator, security.Limits.max_chat_body) catch {
        return errResp(.bad_request, "Failed to read request body");
    };
    defer allocator.free(body);
    if (body.len == 0) return errResp(.bad_request, "Empty request body");

    const parsed = std.json.parseFromSlice(chat.ChatRequest, allocator, body, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch {
        return errResp(.bad_request, "invalid JSON body");
    };
    defer parsed.deinit();
    const req = parsed.value;

    if (req.model.len == 0 or req.model.len > security.Limits.max_model_name) {
        return errResp(.bad_request, "model is required");
    }
    if (req.messages.len == 0) {
        return errResp(.bad_request, "messages is required");
    }

    // Input tokens: sum of message content chars / 3 + 1 (matches the Go
    // pessimistic estimator's text accumulator). The in-tree Message shape is
    // text-only, so there are no media/file_uri parts to weight here.
    var input_chars: usize = 0;
    for (req.messages) |m| {
        if (m.content) |c| input_chars += c.len;
    }
    const input_tokens: u32 = @intCast(input_chars / 3 + 1);

    // Output ceiling: requested max_tokens (when positive) else the
    // pessimistic default.
    const output_tokens: u32 = blk: {
        if (req.max_tokens) |mt| {
            if (mt > 0) break :blk @intCast(mt);
        }
        break :blk DEFAULT_PESSIMISTIC_OUTPUT_TOKENS;
    };

    // Price via the registry with the account tier's margin. Unknown model →
    // fail-closed pessimistic ceiling.
    const ticks: i64 = blk: {
        const c = billing.actualCost(req.model, input_tokens, output_tokens, auth.account.tier) catch
            break :blk UNKNOWN_MODEL_PESSIMISTIC_TICKS;
        break :blk c.cost + c.margin;
    };

    const out = std.json.Stringify.valueAlloc(allocator, .{
        .estimated_cost_ticks = ticks,
        // Display-only convenience for the UI — derived at the JSON boundary,
        // never an accumulator (billing math stays integer ticks).
        .estimated_cost_usd = @as(f64, @floatFromInt(ticks)) / @as(f64, TICKS_PER_USD),
        .model = req.model,
    }, .{}) catch {
        return errResp(.internal_server_error, "Failed to build response JSON");
    };
    return .{ .status = .ok, .body = out };
}

fn errResp(status: http.Status, message: []const u8) Response {
    _ = message;
    return switch (status) {
        .bad_request => .{ .status = .bad_request, .body = "{\"error\":\"invalid_request\",\"message\":\"Estimate request rejected\"}" },
        else => .{ .status = .internal_server_error, .body = "{\"error\":\"internal\",\"message\":\"Estimate failed\"}" },
    };
}
