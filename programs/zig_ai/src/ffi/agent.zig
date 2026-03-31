// Copyright (c) 2025 QUANTUM ENCODING LTD
// Licensed under the MIT License.

//! Agent FFI - C-compatible bindings for AgentExecutor
//!
//! Exposes the agent system to C/Rust consumers (e.g. Tauri/Svelte chat app).
//!
//! Memory model:
//! - C owns input strings (config, task) — Zig copies on entry
//! - Zig owns output strings (result) — C calls zig_ai_agent_result_free()
//! - Events are valid only during callback — C must copy if needed

const std = @import("std");
const types = @import("types.zig");
const agent_mod = @import("../agent/mod.zig");

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;

const CString = types.CString;
const CAgentSession = types.CAgentSession;
const CAgentConfig = types.CAgentConfig;
const CAgentEvent = types.CAgentEvent;
const CAgentEventType = types.CAgentEventType;
const CAgentResult = types.CAgentResult;
const CAgentEventCallback = types.CAgentEventCallback;

/// Internal agent handle (opaque to C)
const AgentHandle = struct {
    executor: agent_mod.AgentExecutor,
    callback: CAgentEventCallback = null,
    userdata: ?*anyopaque = null,
    allocator: std.mem.Allocator,
    // Track strings we allocated for config
    allocated_strings: std.ArrayListUnmanaged([]const u8) = .empty,

    fn deinit(self: *AgentHandle) void {
        self.executor.deinit();
        for (self.allocated_strings.items) |s| {
            self.allocator.free(s);
        }
        self.allocated_strings.deinit(self.allocator);
    }
};

/// Global allocator for FFI
const ffi_allocator = std.heap.c_allocator;

/// Event bridge: converts ToolEvent to CAgentEvent and calls C callback
fn bridgeEvent(handle: *AgentHandle, event: agent_mod.ToolEvent) void {
    const cb = handle.callback orelse return;

    var c_event: CAgentEvent = std.mem.zeroes(CAgentEvent);

    switch (event) {
        .turn_start => |e| {
            c_event.type = .turn_start;
            c_event.turn = e.turn;
        },
        .tool_start => |e| {
            c_event.type = .tool_start;
            c_event.tool_name = CString.fromSlice(e.name);
            if (e.reason) |r| {
                c_event.tool_reason = CString.fromSlice(r);
            }
        },
        .tool_complete => |e| {
            c_event.type = .tool_complete;
            c_event.tool_name = CString.fromSlice(e.name);
            c_event.tool_success = e.success;
            c_event.duration_ms = e.duration_ms;
        },
        .turn_complete => |e| {
            c_event.type = .turn_complete;
            c_event.turn = e.turn;
            c_event.has_tool_calls = e.has_tool_calls;
        },
    }

    cb(&c_event, handle.userdata);
}

// ============================================================================
// FFI Functions
// ============================================================================

/// Create an agent session from a flat config
pub fn agentCreate(c_config: *const CAgentConfig) ?*CAgentSession {
    const allocator = ffi_allocator;

    // Copy input strings
    const provider = dupeFromCString(allocator, c_config.provider) catch return null;
    const model = dupeFromCStringOpt(allocator, c_config.model) catch return null;
    const sandbox_root = dupeFromCString(allocator, c_config.sandbox_root) catch return null;
    const system_prompt = dupeFromCStringOpt(allocator, c_config.system_prompt) catch return null;

    if (sandbox_root.len == 0) return null;

    // Build AgentConfig
    const agent_config = agent_mod.AgentConfig{
        .agent_name = "ffi-agent",
        .sandbox = .{ .root = sandbox_root },
        .provider = .{
            .name = provider,
            .model = model,
            .max_tokens = if (c_config.max_tokens > 0) c_config.max_tokens else 32768,
            .max_turns = if (c_config.max_turns > 0) c_config.max_turns else 50,
            .temperature = if (c_config.temperature >= 0) c_config.temperature else 0.7,
        },
        .system_prompt = system_prompt,
        .allocator = allocator,
    };

    // If API key provided, set it as environment variable
    if (c_config.api_key.ptr) |key_ptr| {
        if (c_config.api_key.len > 0) {
            const env_name = getEnvVarForProvider(provider);
            _ = setenv(env_name.ptr, key_ptr, 1);
        }
    }

    // Create executor
    var executor = agent_mod.AgentExecutor.init(allocator, agent_config) catch return null;

    // Create handle
    var handle = allocator.create(AgentHandle) catch {
        executor.deinit();
        return null;
    };
    handle.* = .{
        .executor = executor,
        .allocator = allocator,
    };

    // Track allocated strings for cleanup
    handle.allocated_strings.append(allocator, provider) catch {};
    if (model) |m| handle.allocated_strings.append(allocator, m) catch {};
    handle.allocated_strings.append(allocator, sandbox_root) catch {};
    if (system_prompt) |sp| handle.allocated_strings.append(allocator, sp) catch {};

    return @ptrCast(handle);
}

/// Destroy an agent session
pub fn agentDestroy(session: ?*CAgentSession) void {
    if (session == null) return;
    const handle: *AgentHandle = @ptrCast(@alignCast(session));
    handle.deinit();
    ffi_allocator.destroy(handle);
}

/// Set event callback
pub fn agentSetCallback(session: ?*CAgentSession, cb: CAgentEventCallback, userdata: ?*anyopaque) void {
    if (session == null) return;
    const handle: *AgentHandle = @ptrCast(@alignCast(session));
    handle.callback = cb;
    handle.userdata = userdata;
}

/// Run agent with a task (blocking)
pub fn agentRun(session: ?*CAgentSession, task: CString, result_out: *CAgentResult) void {
    result_out.* = std.mem.zeroes(CAgentResult);

    if (session == null) {
        result_out.success = false;
        result_out.error_message = makeCString("Session is null");
        return;
    }

    const handle: *AgentHandle = @ptrCast(@alignCast(session));
    const task_slice = task.toSlice();

    if (task_slice.len == 0) {
        result_out.success = false;
        result_out.error_message = makeCString("Task is empty");
        return;
    }

    // Install event bridge as the executor's callback
    // We use a thread-local to pass the handle to the event bridge
    current_handle = handle;
    handle.executor.on_event = &eventBridgeTrampoline;

    var result = handle.executor.run(task_slice) catch |err| {
        result_out.success = false;
        result_out.error_message = makeCString(@errorName(err));
        return;
    };
    defer result.deinit();

    // Copy result to C struct
    result_out.success = result.success;
    result_out.final_response = makeCString(result.final_response);
    result_out.turns_used = result.turns_used;
    result_out.tool_calls_made = result.tool_calls_made;
    result_out.input_tokens = result.total_input_tokens;
    result_out.output_tokens = result.total_output_tokens;
}

/// Free agent result strings
pub fn agentResultFree(result: *CAgentResult) void {
    freeCString(result.final_response);
    freeCString(result.error_message);
    result.* = std.mem.zeroes(CAgentResult);
}

// ============================================================================
// Internal helpers
// ============================================================================

/// Thread-local handle for event bridge trampoline
threadlocal var current_handle: ?*AgentHandle = null;

/// Trampoline that matches EventCallback signature and delegates to bridgeEvent
fn eventBridgeTrampoline(event: agent_mod.ToolEvent) void {
    if (current_handle) |handle| {
        bridgeEvent(handle, event);
    }
}

fn dupeFromCString(allocator: std.mem.Allocator, cs: CString) ![]const u8 {
    const slice = cs.toSlice();
    if (slice.len == 0) return try allocator.dupe(u8, "");
    return try allocator.dupe(u8, slice);
}

fn dupeFromCStringOpt(allocator: std.mem.Allocator, cs: CString) !?[]const u8 {
    if (cs.ptr == null or cs.len == 0) return null;
    return try allocator.dupe(u8, cs.toSlice());
}

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
