// Copyright (c) 2025 QUANTUM ENCODING LTD
// Licensed under the MIT License.

//! plan_tasks tool - Architect submits a task DAG for worker execution
//! The architect AI calls this tool with a structured JSON plan.
//! The orchestrator reads the captured_plan after the architect completes.

const std = @import("std");
const types = @import("types.zig");
const task_graph = @import("../task_graph.zig");

/// Module-level captured plan. Set by execute(), read by orchestrator.
/// Safe: single-threaded execution (one agent runs at a time).
pub var captured_plan: ?task_graph.TaskGraph = null;

/// Free any previously captured plan
pub fn clearCapturedPlan() void {
    if (captured_plan) |*plan| {
        plan.deinit();
        captured_plan = null;
    }
}

pub const plan_tasks_def = types.ToolDefinition{
    .name = "plan_tasks",
    .description = "Submit a task execution plan as a directed acyclic graph (DAG). Each task specifies an AI provider, tools, dependencies, and a detailed prompt. Tasks execute in dependency order. Use this tool exactly once after exploring the codebase to submit your complete plan.",
    .input_schema =
    \\{
    \\  "type": "object",
    \\  "properties": {
    \\    "tasks": {
    \\      "type": "array",
    \\      "description": "Array of task nodes forming the execution DAG",
    \\      "items": {
    \\        "type": "object",
    \\        "properties": {
    \\          "id": {
    \\            "type": "string",
    \\            "description": "Unique task identifier (e.g., 'explore', 'implement_auth')"
    \\          },
    \\          "description": {
    \\            "type": "string",
    \\            "description": "Brief description of what this task does"
    \\          },
    \\          "prompt": {
    \\            "type": "string",
    \\            "description": "Detailed prompt for the worker AI agent"
    \\          },
    \\          "provider": {
    \\            "type": "string",
    \\            "enum": ["claude", "gemini", "openai", "grok", "deepseek"],
    \\            "description": "AI provider for this task",
    \\            "default": "claude"
    \\          },
    \\          "model": {
    \\            "type": "string",
    \\            "description": "Specific model override (null = provider default)"
    \\          },
    \\          "tools": {
    \\            "type": "array",
    \\            "items": {"type": "string"},
    \\            "description": "Tool names this worker can use"
    \\          },
    \\          "dependencies": {
    \\            "type": "array",
    \\            "items": {"type": "string"},
    \\            "description": "IDs of tasks that must complete before this one"
    \\          },
    \\          "max_turns": {
    \\            "type": "integer",
    \\            "description": "Maximum agentic turns for this task",
    \\            "default": 25
    \\          }
    \\        },
    \\        "required": ["id", "description", "prompt"]
    \\      }
    \\    }
    \\  },
    \\  "required": ["tasks"]
    \\}
    ,
};

pub const Args = struct {
    tasks_json: []const u8,
};

pub fn parseArgs(allocator: std.mem.Allocator, args_json: []const u8) !Args {
    // The entire args_json IS the plan (it contains "tasks" key)
    return .{
        .tasks_json = try allocator.dupe(u8, args_json),
    };
}

pub fn freeArgs(allocator: std.mem.Allocator, args: Args) void {
    allocator.free(args.tasks_json);
}

pub fn execute(allocator: std.mem.Allocator, args: Args) !types.ToolOutput {
    // Free any previous plan
    clearCapturedPlan();

    // Parse the task graph
    var graph = task_graph.TaskGraph.parseFromJson(allocator, args.tasks_json) catch |err| {
        const msg = switch (err) {
            task_graph.GraphError.InvalidJson => "Invalid JSON in task plan",
            task_graph.GraphError.EmptyGraph => "Task plan contains no tasks",
            else => "Failed to parse task plan",
        };
        return types.ToolOutput.error_result(allocator, msg);
    };
    errdefer graph.deinit();

    // Validate: cycles, duplicate IDs, valid dependencies
    graph.validate() catch |err| {
        const msg = switch (err) {
            task_graph.GraphError.CycleDetected => "Cycle detected in task dependencies. Tasks must form a DAG.",
            task_graph.GraphError.DuplicateTaskId => "Duplicate task ID found. Each task must have a unique ID.",
            task_graph.GraphError.InvalidDependency => "Task references a dependency that does not exist.",
            else => "Task graph validation failed",
        };
        graph.deinit();
        return types.ToolOutput.error_result(allocator, msg);
    };

    // Build execution summary
    const summary = graph.executionSummary(allocator) catch "unable to compute order";
    defer if (summary.ptr != "unable to compute order".ptr) allocator.free(summary);

    const task_count = graph.tasks.items.len;

    // Store the plan for the orchestrator to pick up
    captured_plan = graph;

    // Build response
    const response = std.fmt.allocPrint(allocator, "Plan accepted: {d} tasks. Execution order: {s}", .{ task_count, summary }) catch
        return types.ToolOutput.success_result(allocator, "Plan accepted");

    defer allocator.free(response);
    return types.ToolOutput.success_result(allocator, response);
}
