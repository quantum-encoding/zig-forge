// Copyright (c) 2025 QUANTUM ENCODING LTD
// Licensed under the MIT License.

//! Orchestrator FFI - C-compatible bindings for the Architect/Worker orchestration engine
//!
//! Exposes orchestration to C/Rust consumers (e.g. Tauri/Svelte DAG app).
//!
//! Memory model:
//! - C owns input strings (config, goal, plan_json) — Zig copies on entry
//! - Zig owns output strings (result) — C calls zig_ai_orchestrator_result_free()
//! - Events are valid only during callback — C must copy if needed

const std = @import("std");
const types = @import("types.zig");
const agent_config = @import("../agent/config.zig");
const orchestrator_mod = @import("../agent/orchestrator.zig");
const session_mod = @import("../agent/session.zig");

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;

const CString = types.CString;
const COrchestratorConfig = types.COrchestratorConfig;
const COrchestratorResult = types.COrchestratorResult;
const COrchestratorEvent = types.COrchestratorEvent;
const COrchestratorEventCallback = types.COrchestratorEventCallback;
const ErrorCode = types.ErrorCode;

/// Global allocator for FFI
const ffi_allocator = std.heap.c_allocator;

/// Thread-local state for event bridge
const EventBridgeState = struct {
    callback: COrchestratorEventCallback,
    userdata: ?*anyopaque,
};

threadlocal var current_bridge: ?EventBridgeState = null;

/// Bridge: converts OrchestratorEvent to COrchestratorEvent and calls C callback
fn orchestratorEventBridge(event: orchestrator_mod.OrchestratorEvent) void {
    const bridge = current_bridge orelse return;
    const cb = bridge.callback orelse return;

    var c_event: COrchestratorEvent = std.mem.zeroes(COrchestratorEvent);

    switch (event) {
        .phase_start => |e| {
            c_event.type = .phase_start;
            c_event.phase = CString.fromSlice(e.phase);
        },
        .architect_turn => |e| {
            c_event.type = .architect_turn;
            c_event.turn = e.turn;
        },
        .plan_accepted => |e| {
            c_event.type = .plan_accepted;
            c_event.task_count = e.task_count;
            c_event.execution_order = CString.fromSlice(e.execution_order);
        },
        .worker_start => |e| {
            c_event.type = .worker_start;
            c_event.task_id = CString.fromSlice(e.task_id);
            c_event.provider = CString.fromSlice(e.provider);
        },
        .worker_complete => |e| {
            c_event.type = .worker_complete;
            c_event.task_id = CString.fromSlice(e.task_id);
            c_event.success = e.success;
            c_event.duration_ms = e.duration_ms;
        },
        .worker_skipped => |e| {
            c_event.type = .worker_skipped;
            c_event.task_id = CString.fromSlice(e.task_id);
            c_event.reason = CString.fromSlice(e.reason);
        },
        .cost_update => |e| {
            c_event.type = .cost_update;
            c_event.total_cost_usd = e.total_usd;
        },
        .orchestration_complete => |e| {
            c_event.type = .orchestration_complete;
            c_event.success = e.success;
        },
    }

    cb(&c_event, bridge.userdata);
}

/// Build internal configs from C config struct
fn buildConfigs(c_config: *const COrchestratorConfig) ?struct { agent: agent_config.AgentConfig, orch: agent_config.OrchestratorConfig } {
    const sandbox_root = c_config.sandbox_root.toSlice();
    if (sandbox_root.len == 0) return null;

    const sandbox_duped = ffi_allocator.dupe(u8, sandbox_root) catch return null;

    // Set API key if provided
    if (c_config.api_key.ptr) |key_ptr| {
        if (c_config.api_key.len > 0) {
            const provider_name = c_config.architect_provider.toSlice();
            const env_name = getEnvVarForProvider(provider_name);
            _ = setenv(env_name.ptr, key_ptr, 1);
        }
    }

    const a_config = agent_config.AgentConfig{
        .agent_name = "orchestrator",
        .sandbox = .{ .root = sandbox_duped },
        .provider = .{
            .name = if (c_config.worker_provider.len > 0) c_config.worker_provider.toSlice() else "claude",
        },
        .allocator = ffi_allocator,
    };

    const o_config = agent_config.OrchestratorConfig{
        .architect_provider = if (c_config.architect_provider.len > 0) c_config.architect_provider.toSlice() else "claude",
        .architect_model = if (c_config.architect_model.len > 0) c_config.architect_model.toSlice() else null,
        .architect_max_turns = if (c_config.architect_max_turns > 0) c_config.architect_max_turns else 30,
        .worker_provider = if (c_config.worker_provider.len > 0) c_config.worker_provider.toSlice() else "claude",
        .worker_model = if (c_config.worker_model.len > 0) c_config.worker_model.toSlice() else null,
        .worker_max_turns = if (c_config.worker_max_turns > 0) c_config.worker_max_turns else 25,
        .save_plan = c_config.save_plan,
        .plan_path = if (c_config.plan_path.len > 0) c_config.plan_path.toSlice() else null,
        .audit_log = c_config.audit_log,
        .audit_path = if (c_config.audit_path.len > 0) c_config.audit_path.toSlice() else null,
        .max_tasks = if (c_config.max_tasks > 0) c_config.max_tasks else 20,
        .max_cost_usd = c_config.max_cost_usd,
    };

    return .{ .agent = a_config, .orch = o_config };
}

fn fillResult(result_out: *COrchestratorResult, orch_result: *orchestrator_mod.OrchestratorResult) void {
    result_out.success = orch_result.success;
    result_out.error_code = ErrorCode.SUCCESS;
    result_out.tasks_completed = orch_result.tasks_completed;
    result_out.tasks_failed = orch_result.tasks_failed;
    result_out.tasks_skipped = orch_result.tasks_skipped;
    result_out.total_input_tokens = orch_result.total_input_tokens;
    result_out.total_output_tokens = orch_result.total_output_tokens;
    result_out.total_cost_usd = orch_result.total_cost_usd;
    result_out.summary = makeCString(orch_result.summary);
    result_out.plan_path = if (orch_result.plan_path) |p| makeCString(p) else .{ .ptr = null, .len = 0 };
}

// ============================================================================
// Exported FFI Functions
// ============================================================================

/// Run orchestration with a goal string (architect + workers)
pub fn orchestratorRun(
    c_config: *const COrchestratorConfig,
    goal: CString,
    callback: COrchestratorEventCallback,
    userdata: ?*anyopaque,
    result_out: *COrchestratorResult,
) void {
    result_out.* = std.mem.zeroes(COrchestratorResult);

    const goal_slice = goal.toSlice();
    if (goal_slice.len == 0) {
        result_out.success = false;
        result_out.error_code = ErrorCode.INVALID_ARGUMENT;
        result_out.error_message = makeCString("Goal is empty");
        return;
    }

    const configs = buildConfigs(c_config) orelse {
        result_out.success = false;
        result_out.error_code = ErrorCode.INVALID_ARGUMENT;
        result_out.error_message = makeCString("Invalid config (sandbox_root required)");
        return;
    };

    var orch = orchestrator_mod.Orchestrator.init(ffi_allocator, configs.agent, configs.orch);
    defer orch.deinit();

    // Install event bridge if callback provided
    if (callback != null) {
        current_bridge = .{ .callback = callback, .userdata = userdata };
        orch.on_event = &orchestratorEventBridge;
    }

    var orch_result = orch.run(goal_slice) catch |err| {
        result_out.success = false;
        result_out.error_code = ErrorCode.API_ERROR;
        result_out.error_message = makeCString(@errorName(err));
        return;
    };
    defer orch_result.deinit();

    fillResult(result_out, &orch_result);
    current_bridge = null;
}

/// Resume orchestration from a saved plan JSON
pub fn orchestratorRunFromPlan(
    c_config: *const COrchestratorConfig,
    plan_json: CString,
    callback: COrchestratorEventCallback,
    userdata: ?*anyopaque,
    result_out: *COrchestratorResult,
) void {
    result_out.* = std.mem.zeroes(COrchestratorResult);

    const plan_slice = plan_json.toSlice();
    if (plan_slice.len == 0) {
        result_out.success = false;
        result_out.error_code = ErrorCode.INVALID_ARGUMENT;
        result_out.error_message = makeCString("Plan JSON is empty");
        return;
    }

    const configs = buildConfigs(c_config) orelse {
        result_out.success = false;
        result_out.error_code = ErrorCode.INVALID_ARGUMENT;
        result_out.error_message = makeCString("Invalid config (sandbox_root required)");
        return;
    };

    var orch = orchestrator_mod.Orchestrator.init(ffi_allocator, configs.agent, configs.orch);
    defer orch.deinit();

    // Install event bridge if callback provided
    if (callback != null) {
        current_bridge = .{ .callback = callback, .userdata = userdata };
        orch.on_event = &orchestratorEventBridge;
    }

    var orch_result = orch.runFromPlan(plan_slice) catch |err| {
        result_out.success = false;
        result_out.error_code = ErrorCode.API_ERROR;
        result_out.error_message = makeCString(@errorName(err));
        return;
    };
    defer orch_result.deinit();

    fillResult(result_out, &orch_result);
    current_bridge = null;
}

/// Free an orchestrator result
pub fn orchestratorResultFree(result: *COrchestratorResult) void {
    freeCString(result.summary);
    freeCString(result.plan_path);
    freeCString(result.error_message);
    result.* = std.mem.zeroes(COrchestratorResult);
}

// ============================================================================
// Internal helpers
// ============================================================================

fn makeCString(s: []const u8) CString {
    const duped = ffi_allocator.dupeZ(u8, s) catch return .{ .ptr = null, .len = 0 };
    return .{ .ptr = duped.ptr, .len = s.len };
}

fn freeCString(cs: CString) void {
    if (cs.ptr) |p| {
        ffi_allocator.free(p[0 .. cs.len + 1]);
    }
}

fn getEnvVarForProvider(provider: []const u8) [:0]const u8 {
    if (std.mem.eql(u8, provider, "claude")) return "ANTHROPIC_API_KEY";
    if (std.mem.eql(u8, provider, "gemini")) return "GEMINI_API_KEY";
    if (std.mem.eql(u8, provider, "openai") or std.mem.eql(u8, provider, "gpt")) return "OPENAI_API_KEY";
    if (std.mem.eql(u8, provider, "grok")) return "XAI_API_KEY";
    if (std.mem.eql(u8, provider, "deepseek")) return "DEEPSEEK_API_KEY";
    return "API_KEY";
}
