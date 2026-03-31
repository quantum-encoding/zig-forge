// Copyright (c) 2025 QUANTUM ENCODING LTD
// Licensed under the MIT License.

//! Task Graph - DAG data model for orchestrator task planning
//! Supports JSON parsing, cycle detection (Kahn's algorithm), and topological sorting

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const TaskStatus = enum {
    pending,
    running,
    completed,
    failed,
    skipped,

    pub fn toString(self: TaskStatus) []const u8 {
        return switch (self) {
            .pending => "pending",
            .running => "running",
            .completed => "completed",
            .failed => "failed",
            .skipped => "skipped",
        };
    }

    pub fn fromString(s: []const u8) TaskStatus {
        if (std.mem.eql(u8, s, "running")) return .running;
        if (std.mem.eql(u8, s, "completed")) return .completed;
        if (std.mem.eql(u8, s, "failed")) return .failed;
        if (std.mem.eql(u8, s, "skipped")) return .skipped;
        return .pending;
    }
};

pub const TaskNode = struct {
    id: []const u8,
    description: []const u8,
    prompt: []const u8,
    provider: []const u8,
    model: ?[]const u8,
    tools: []const []const u8,
    dependencies: []const []const u8,
    max_turns: u32,
    // Runtime state
    status: TaskStatus,
    result: ?[]const u8,
    error_msg: ?[]const u8,
    input_tokens: u32,
    output_tokens: u32,
    duration_ns: u64,
};

pub const GraphError = error{
    CycleDetected,
    InvalidDependency,
    DuplicateTaskId,
    EmptyGraph,
    InvalidJson,
    OutOfMemory,
};

pub const TaskGraph = struct {
    tasks: std.ArrayListUnmanaged(TaskNode),
    allocator: Allocator,
    // Track all allocated strings for cleanup
    _strings: std.ArrayListUnmanaged([]const u8),
    _arrays: std.ArrayListUnmanaged([]const []const u8),

    pub fn init(allocator: Allocator) TaskGraph {
        return .{
            .tasks = .empty,
            .allocator = allocator,
            ._strings = .empty,
            ._arrays = .empty,
        };
    }

    pub fn deinit(self: *TaskGraph) void {
        for (self._strings.items) |s| {
            self.allocator.free(s);
        }
        self._strings.deinit(self.allocator);
        for (self._arrays.items) |arr| {
            self.allocator.free(arr);
        }
        self._arrays.deinit(self.allocator);
        self.tasks.deinit(self.allocator);
    }

    fn dupeStr(self: *TaskGraph, s: []const u8) ![]const u8 {
        const d = try self.allocator.dupe(u8, s);
        try self._strings.append(self.allocator, d);
        return d;
    }

    fn dupeStrArray(self: *TaskGraph, items: []const std.json.Value) ![]const []const u8 {
        const arr = try self.allocator.alloc([]const u8, items.len);
        errdefer self.allocator.free(arr);
        for (items, 0..) |item, i| {
            arr[i] = try self.dupeStr(item.string);
        }
        try self._arrays.append(self.allocator, arr);
        return arr;
    }

    /// Parse a task graph from JSON string (output of plan_tasks tool)
    pub fn parseFromJson(allocator: Allocator, json_str: []const u8) !TaskGraph {
        const parsed = std.json.parseFromSlice(std.json.Value, allocator, json_str, .{
            .allocate = .alloc_always,
        }) catch {
            return GraphError.InvalidJson;
        };
        defer parsed.deinit();

        var graph = TaskGraph.init(allocator);
        errdefer graph.deinit();

        const root = parsed.value;

        // Support both {"tasks": [...]} and bare [...]
        const tasks_val = if (root == .object)
            (root.object.get("tasks") orelse return GraphError.InvalidJson)
        else if (root == .array)
            root
        else
            return GraphError.InvalidJson;

        const tasks_arr = tasks_val.array.items;
        if (tasks_arr.len == 0) return GraphError.EmptyGraph;

        for (tasks_arr) |task_val| {
            const obj = task_val.object;

            const id = try graph.dupeStr((obj.get("id") orelse return GraphError.InvalidJson).string);
            const description = try graph.dupeStr((obj.get("description") orelse return GraphError.InvalidJson).string);
            const prompt = try graph.dupeStr((obj.get("prompt") orelse return GraphError.InvalidJson).string);

            const provider = if (obj.get("provider")) |p|
                try graph.dupeStr(p.string)
            else
                try graph.dupeStr("claude");

            const model: ?[]const u8 = if (obj.get("model")) |m|
                (if (m == .string) try graph.dupeStr(m.string) else null)
            else
                null;

            const tools_list = if (obj.get("tools")) |t|
                try graph.dupeStrArray(t.array.items)
            else
                &[_][]const u8{};

            const deps = if (obj.get("dependencies")) |d|
                try graph.dupeStrArray(d.array.items)
            else
                &[_][]const u8{};

            const max_turns: u32 = if (obj.get("max_turns")) |t|
                @intCast(t.integer)
            else
                25;

            try graph.tasks.append(allocator, .{
                .id = id,
                .description = description,
                .prompt = prompt,
                .provider = provider,
                .model = model,
                .tools = tools_list,
                .dependencies = deps,
                .max_turns = max_turns,
                .status = .pending,
                .result = null,
                .error_msg = null,
                .input_tokens = 0,
                .output_tokens = 0,
                .duration_ns = 0,
            });
        }

        return graph;
    }

    /// Validate the graph: no cycles, no duplicate IDs, all dependencies exist
    pub fn validate(self: *const TaskGraph) !void {
        if (self.tasks.items.len == 0) return GraphError.EmptyGraph;

        // Check for duplicate IDs
        for (self.tasks.items, 0..) |task, i| {
            for (self.tasks.items[i + 1 ..]) |other| {
                if (std.mem.eql(u8, task.id, other.id)) {
                    return GraphError.DuplicateTaskId;
                }
            }
        }

        // Check all dependencies reference existing tasks
        for (self.tasks.items) |task| {
            for (task.dependencies) |dep| {
                if (self.getTask(dep) == null) {
                    return GraphError.InvalidDependency;
                }
            }
        }

        // Cycle detection via Kahn's algorithm (in-degree counting)
        const n = self.tasks.items.len;
        const in_degree = self.allocator.alloc(u32, n) catch return GraphError.OutOfMemory;
        defer self.allocator.free(in_degree);
        @memset(in_degree, 0);

        // Compute in-degrees
        for (self.tasks.items, 0..) |task, i| {
            _ = i;
            for (task.dependencies) |dep| {
                const dep_idx = self.getTaskIndex(dep) orelse return GraphError.InvalidDependency;
                _ = dep_idx;
                // The current task depends on dep, so current task gets +1 in-degree
            }
        }

        // Actually: in-degree of task i = number of dependencies task i has
        for (self.tasks.items, 0..) |task, i| {
            in_degree[i] = @intCast(task.dependencies.len);
        }

        // BFS queue
        var queue: std.ArrayListUnmanaged(usize) = .empty;
        defer queue.deinit(self.allocator);

        for (0..n) |i| {
            if (in_degree[i] == 0) {
                queue.append(self.allocator, i) catch return GraphError.OutOfMemory;
            }
        }

        var visited: usize = 0;
        var head: usize = 0;

        while (head < queue.items.len) {
            const current = queue.items[head];
            head += 1;
            visited += 1;

            // For each task that depends on current, decrement in-degree
            for (self.tasks.items, 0..) |task, i| {
                for (task.dependencies) |dep| {
                    if (self.getTaskIndex(dep)) |dep_idx| {
                        if (dep_idx == current) {
                            in_degree[i] -= 1;
                            if (in_degree[i] == 0) {
                                queue.append(self.allocator, i) catch return GraphError.OutOfMemory;
                            }
                        }
                    }
                }
            }
        }

        if (visited != n) {
            return GraphError.CycleDetected;
        }
    }

    /// Topological sort using Kahn's algorithm. Returns indices into tasks array.
    pub fn topologicalSort(self: *const TaskGraph, allocator: Allocator) ![]usize {
        const n = self.tasks.items.len;
        const in_degree = try allocator.alloc(u32, n);
        defer allocator.free(in_degree);

        for (self.tasks.items, 0..) |task, i| {
            in_degree[i] = @intCast(task.dependencies.len);
        }

        var queue: std.ArrayListUnmanaged(usize) = .empty;
        defer queue.deinit(allocator);

        for (0..n) |i| {
            if (in_degree[i] == 0) {
                try queue.append(allocator, i);
            }
        }

        var result: std.ArrayListUnmanaged(usize) = .empty;
        errdefer result.deinit(allocator);

        var head: usize = 0;
        while (head < queue.items.len) {
            const current = queue.items[head];
            head += 1;
            try result.append(allocator, current);

            for (self.tasks.items, 0..) |task, i| {
                for (task.dependencies) |dep| {
                    if (self.getTaskIndex(dep)) |dep_idx| {
                        if (dep_idx == current) {
                            in_degree[i] -= 1;
                            if (in_degree[i] == 0) {
                                try queue.append(allocator, i);
                            }
                        }
                    }
                }
            }
        }

        return result.toOwnedSlice(allocator);
    }

    /// Build context string from completed upstream tasks for a worker
    pub fn buildContext(self: *const TaskGraph, allocator: Allocator, task_id: []const u8) ![]const u8 {
        const task = self.getTask(task_id) orelse return allocator.dupe(u8, "");

        var ctx: std.ArrayListUnmanaged(u8) = .empty;
        errdefer ctx.deinit(allocator);

        for (task.dependencies) |dep_id| {
            const dep = self.getTask(dep_id) orelse continue;
            if (dep.status != .completed) continue;

            try ctx.appendSlice(allocator, "=== CONTEXT FROM PREVIOUS TASK ===\n");
            try ctx.appendSlice(allocator, "[");
            try ctx.appendSlice(allocator, dep.id);
            try ctx.appendSlice(allocator, "] ");
            try ctx.appendSlice(allocator, dep.description);
            try ctx.appendSlice(allocator, "\nStatus: completed\nResponse: ");

            if (dep.result) |result| {
                // Truncate to 4000 chars
                const truncated = if (result.len > 4000) result[0..4000] else result;
                try ctx.appendSlice(allocator, truncated);
                if (result.len > 4000) {
                    try ctx.appendSlice(allocator, "\n... (truncated)");
                }
            } else {
                try ctx.appendSlice(allocator, "(no output)");
            }
            try ctx.appendSlice(allocator, "\n=== END CONTEXT ===\n\n");
        }

        return ctx.toOwnedSlice(allocator);
    }

    /// Serialize the graph to JSON
    pub fn toJson(self: *const TaskGraph, allocator: Allocator) ![]const u8 {
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        errdefer buf.deinit(allocator);

        try buf.appendSlice(allocator, "{\"tasks\":[");

        for (self.tasks.items, 0..) |task, i| {
            if (i > 0) try buf.append(allocator, ',');
            try buf.appendSlice(allocator, "{\"id\":\"");
            try appendJsonEscaped(&buf, allocator, task.id);
            try buf.appendSlice(allocator, "\",\"description\":\"");
            try appendJsonEscaped(&buf, allocator, task.description);
            try buf.appendSlice(allocator, "\",\"prompt\":\"");
            try appendJsonEscaped(&buf, allocator, task.prompt);
            try buf.appendSlice(allocator, "\",\"provider\":\"");
            try appendJsonEscaped(&buf, allocator, task.provider);
            try buf.appendSlice(allocator, "\"");

            if (task.model) |m| {
                try buf.appendSlice(allocator, ",\"model\":\"");
                try appendJsonEscaped(&buf, allocator, m);
                try buf.appendSlice(allocator, "\"");
            } else {
                try buf.appendSlice(allocator, ",\"model\":null");
            }

            // tools array
            try buf.appendSlice(allocator, ",\"tools\":[");
            for (task.tools, 0..) |t, j| {
                if (j > 0) try buf.append(allocator, ',');
                try buf.appendSlice(allocator, "\"");
                try appendJsonEscaped(&buf, allocator, t);
                try buf.appendSlice(allocator, "\"");
            }
            try buf.appendSlice(allocator, "]");

            // dependencies array
            try buf.appendSlice(allocator, ",\"dependencies\":[");
            for (task.dependencies, 0..) |d, j| {
                if (j > 0) try buf.append(allocator, ',');
                try buf.appendSlice(allocator, "\"");
                try appendJsonEscaped(&buf, allocator, d);
                try buf.appendSlice(allocator, "\"");
            }
            try buf.appendSlice(allocator, "]");

            // max_turns
            const mt = try std.fmt.allocPrint(allocator, ",\"max_turns\":{d}", .{task.max_turns});
            defer allocator.free(mt);
            try buf.appendSlice(allocator, mt);

            // runtime state
            try buf.appendSlice(allocator, ",\"status\":\"");
            try buf.appendSlice(allocator, task.status.toString());
            try buf.appendSlice(allocator, "\"");

            if (task.result) |r| {
                try buf.appendSlice(allocator, ",\"result\":\"");
                try appendJsonEscaped(&buf, allocator, r);
                try buf.appendSlice(allocator, "\"");
            } else {
                try buf.appendSlice(allocator, ",\"result\":null");
            }

            if (task.error_msg) |e| {
                try buf.appendSlice(allocator, ",\"error_msg\":\"");
                try appendJsonEscaped(&buf, allocator, e);
                try buf.appendSlice(allocator, "\"");
            } else {
                try buf.appendSlice(allocator, ",\"error_msg\":null");
            }

            const stats = try std.fmt.allocPrint(allocator, ",\"input_tokens\":{d},\"output_tokens\":{d},\"duration_ns\":{d}", .{ task.input_tokens, task.output_tokens, task.duration_ns });
            defer allocator.free(stats);
            try buf.appendSlice(allocator, stats);

            try buf.append(allocator, '}');
        }

        try buf.appendSlice(allocator, "]}");
        return buf.toOwnedSlice(allocator);
    }

    /// Get a task by ID (mutable)
    pub fn getTaskMut(self: *TaskGraph, id: []const u8) ?*TaskNode {
        for (self.tasks.items) |*task| {
            if (std.mem.eql(u8, task.id, id)) return task;
        }
        return null;
    }

    /// Get a task by ID (const)
    pub fn getTask(self: *const TaskGraph, id: []const u8) ?*const TaskNode {
        for (self.tasks.items) |*task| {
            if (std.mem.eql(u8, task.id, id)) return task;
        }
        return null;
    }

    /// Get the index of a task by ID
    fn getTaskIndex(self: *const TaskGraph, id: []const u8) ?usize {
        for (self.tasks.items, 0..) |task, i| {
            if (std.mem.eql(u8, task.id, id)) return i;
        }
        return null;
    }

    /// Check if all dependencies of a task are completed
    pub fn areDependenciesMet(self: *const TaskGraph, task: *const TaskNode) bool {
        for (task.dependencies) |dep_id| {
            const dep = self.getTask(dep_id) orelse return false;
            if (dep.status != .completed) return false;
        }
        return true;
    }

    /// Check if any dependency of a task has failed
    pub fn hasDependencyFailed(self: *const TaskGraph, task: *const TaskNode) bool {
        for (task.dependencies) |dep_id| {
            const dep = self.getTask(dep_id) orelse return true;
            if (dep.status == .failed or dep.status == .skipped) return true;
        }
        return false;
    }

    /// Get summary string: "task1 -> task2 -> [task3, task4] -> task5"
    pub fn executionSummary(self: *const TaskGraph, allocator: Allocator) ![]const u8 {
        const order = try self.topologicalSort(allocator);
        defer allocator.free(order);

        var buf: std.ArrayListUnmanaged(u8) = .empty;
        errdefer buf.deinit(allocator);

        for (order, 0..) |idx, i| {
            if (i > 0) try buf.appendSlice(allocator, " -> ");
            try buf.appendSlice(allocator, self.tasks.items[idx].id);
        }

        return buf.toOwnedSlice(allocator);
    }
};

/// Append a JSON-escaped string to the buffer
fn appendJsonEscaped(buf: *std.ArrayListUnmanaged(u8), allocator: Allocator, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '"' => try buf.appendSlice(allocator, "\\\""),
            '\\' => try buf.appendSlice(allocator, "\\\\"),
            '\n' => try buf.appendSlice(allocator, "\\n"),
            '\r' => try buf.appendSlice(allocator, "\\r"),
            '\t' => try buf.appendSlice(allocator, "\\t"),
            else => {
                if (c < 0x20) {
                    // Control character - skip
                } else {
                    try buf.append(allocator, c);
                }
            },
        }
    }
}
