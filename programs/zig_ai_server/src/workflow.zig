// Workflow execution engine — sequential LLM step runner.
//
// Dispatched as the "workflow/execute" job type. A workflow is a list of
// steps, each a prompt (+ optional model); the runner executes them in order
// through the real provider clients, billing each step exactly like
// /qai/v1/chat (reserve → call → commit with reported usage), and returns the
// per-step outputs. The client submits the steps inline at execute time
// (the replacement server owns the workflow collection's schema):
//
//   params: { steps: [ { prompt, model?, system_prompt? }, ... ] }
//   result: { status, outputs: [ { index, model, text } ], total_cost_ticks }
//
// Sequential execution covers the common workflow shape. Parallel/dependency
// graphs (fan-out, conditional edges) are a future enhancement; this runs the
// declared steps in order and stops on the first hard failure.

const std = @import("std");
const hs = @import("http-sentinel");
const chat = @import("chat.zig");
const billing = @import("billing.zig");
const security = @import("security.zig");
const store_mod = @import("store/store.zig");
const types = @import("store/types.zig");
const ledger_mod = @import("ledger.zig");
const router = @import("router.zig");
const Response = router.Response;

const DEFAULT_MODEL = "gpt-4.1-mini";
const MAX_STEPS: usize = 50;
const STEP_MAX_TOKENS: u32 = 2048;

const Step = struct {
    prompt: []const u8 = "",
    model: ?[]const u8 = null,
    system_prompt: ?[]const u8 = null,
};
const Params = struct {
    steps: []const Step = &.{},
};

const StepOutput = struct {
    index: u32,
    model: []const u8,
    text: []const u8,
    input_tokens: u32,
    output_tokens: u32,
};

/// Job-worker entry for "workflow/execute".
pub fn executeCore(
    a: std.mem.Allocator,
    env: *const std.process.Environ.Map,
    io_opt: ?std.Io,
    st: ?*store_mod.Store,
    au: ?*const types.AuthContext,
    lg: ?*ledger_mod.Ledger,
    body: []const u8,
) Response {
    const io = io_opt orelse return err("io unavailable");
    const parsed = std.json.parseFromSlice(Params, a, body, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch
        return err("invalid workflow params");
    const steps = parsed.value.steps;
    if (steps.len == 0) return err("steps is required");
    if (steps.len > MAX_STEPS) return err("too many steps");

    var outputs: std.ArrayListUnmanaged(StepOutput) = .empty;
    var total_cost: i64 = 0;

    for (steps, 0..) |step, i| {
        if (step.prompt.len == 0) continue;
        const model = step.model orelse DEFAULT_MODEL;

        const provider_info = chat.resolveProvider(model) orelse {
            outputs.append(a, .{ .index = @intCast(i), .model = model, .text = "[skipped: unknown provider]", .input_tokens = 0, .output_tokens = 0 }) catch break;
            continue;
        };
        const api_key = hs.ai.getApiKeyFromEnv(env, provider_info.env_var) catch {
            outputs.append(a, .{ .index = @intCast(i), .model = model, .text = "[skipped: missing provider key]", .input_tokens = 0, .output_tokens = 0 }) catch break;
            continue;
        };

        // Bill this step like a chat call: reserve against the account, run,
        // commit with reported usage.
        var reservation_id: ?u64 = null;
        if (st) |s| if (au) |auth| {
            if (auth.account.role != .admin) {
                const input_est = billing.estimateInputTokens(step.prompt.len);
                const result = billing.reserveWithCap(s, io, auth, model, STEP_MAX_TOKENS, input_est, "workflow/execute") catch {
                    // Out of balance — stop the workflow here.
                    break;
                };
                reservation_id = result.reservation_id;
            }
        };

        var client = hs.ai.AIClient.init(a, provider_info.provider, .{ .api_key = api_key }) catch {
            if (reservation_id) |rid| if (st) |s| s.rollbackReservation(io, rid);
            continue;
        };
        defer client.deinit();

        var config = hs.ai.RequestConfig{ .model = model, .max_tokens = STEP_MAX_TOKENS };
        if (step.system_prompt) |sp| config.system_prompt = sp;

        const response = client.sendMessage(step.prompt, config) catch {
            if (reservation_id) |rid| if (st) |s| s.rollbackReservation(io, rid);
            outputs.append(a, .{ .index = @intCast(i), .model = model, .text = "[error: provider call failed]", .input_tokens = 0, .output_tokens = 0 }) catch break;
            continue;
        };

        const in_t = response.usage.input_tokens;
        const out_t = response.usage.output_tokens;
        if (reservation_id) |rid| if (st) |s| if (au) |auth| {
            billing.commit(s, io, rid, model, in_t, out_t, auth.account.tier);
        };
        if (lg) |l| if (au) |auth| {
            var bal: i64 = 0;
            if (st) |s| if (s.getAccount(auth.account.id.slice())) |acct| {
                bal = acct.balance_ticks;
            };
            const cost = billing.actualCost(model, in_t, out_t, auth.account.tier) catch null;
            if (cost) |c| {
                total_cost += c.cost + c.margin;
                l.recordBilling(io, auth.account.id.slice(), auth.key.prefix.slice(), c.cost, c.margin, bal, "workflow/execute", model, in_t, out_t, 0);
            }
        };

        outputs.append(a, .{
            .index = @intCast(i),
            .model = model,
            .text = a.dupe(u8, response.message.content) catch "",
            .input_tokens = in_t,
            .output_tokens = out_t,
        }) catch break;
    }

    const out = std.json.Stringify.valueAlloc(a, .{
        .status = "completed",
        .outputs = outputs.items,
        .steps_run = outputs.items.len,
        .total_cost_ticks = total_cost,
    }, .{}) catch return err("serialize failed");
    return .{ .status = .ok, .body = out };
}

fn err(message: []const u8) Response {
    _ = message;
    return .{ .status = .bad_gateway, .body = "{\"error\":\"workflow_error\",\"message\":\"workflow execution failed\"}" };
}
