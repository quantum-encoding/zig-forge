// Copyright (c) 2025 QUANTUM ENCODING LTD
// Licensed under the MIT License.

//! Orchestrator - Architect/Worker task DAG execution engine
//!
//! Phase 1: ARCHITECT - An expensive AI explores the codebase and produces a task DAG
//! Phase 2: VALIDATE  - Parse and validate the DAG (cycle detection, dep resolution)
//! Phase 3: EXECUTE   - Cheap worker AIs execute tasks in dependency order

const std = @import("std");
const Allocator = std.mem.Allocator;
const config = @import("config.zig");
const executor = @import("executor.zig");
const task_graph = @import("task_graph.zig");
const plan_tasks = @import("tools/plan_tasks.zig");
const session_mod = @import("session.zig");
const audit_mod = @import("audit.zig");
const pricing = @import("pricing.zig");
const security = @import("security/mod.zig");
const Timer = @import("../timer.zig").Timer;

pub const OrchestratorError = error{
    ArchitectFailed,
    NoPlanProduced,
    PlanValidationFailed,
    WorkerFailed,
    CostLimitExceeded,
    OutOfMemory,
};

pub const OrchestratorResult = struct {
    success: bool,
    tasks_completed: u32,
    tasks_failed: u32,
    tasks_skipped: u32,
    total_input_tokens: u32,
    total_output_tokens: u32,
    total_cost_usd: f64,
    plan_path: ?[]const u8,
    summary: []const u8,
    allocator: Allocator,

    pub fn deinit(self: *OrchestratorResult) void {
        self.allocator.free(self.summary);
        if (self.plan_path) |p| self.allocator.free(p);
    }
};

/// Event types emitted by the orchestrator for real-time progress
pub const OrchestratorEvent = union(enum) {
    phase_start: struct { phase: []const u8 },
    architect_turn: struct { turn: u32 },
    plan_accepted: struct { task_count: u32, execution_order: []const u8 },
    worker_start: struct { task_id: []const u8, provider: []const u8 },
    worker_complete: struct { task_id: []const u8, success: bool, duration_ms: u64 },
    worker_skipped: struct { task_id: []const u8, reason: []const u8 },
    cost_update: struct { total_usd: f64 },
    orchestration_complete: struct { success: bool },
};

pub const OrchestratorEventCallback = ?*const fn (OrchestratorEvent) void;

/// Default event handler - prints formatted output to stderr
fn defaultOrchestratorEventHandler(event: OrchestratorEvent) void {
    switch (event) {
        .phase_start => |e| std.debug.print("\n[orchestrator] Phase: {s}\n", .{e.phase}),
        .architect_turn => |e| std.debug.print("[architect] Turn {d}...\n", .{e.turn}),
        .plan_accepted => |e| std.debug.print("[orchestrator] Plan accepted: {d} tasks. Order: {s}\n", .{ e.task_count, e.execution_order }),
        .worker_start => |e| std.debug.print("\n[worker:{s}] Starting ({s})...\n", .{ e.task_id, e.provider }),
        .worker_complete => |e| {
            const symbol: []const u8 = if (e.success) "completed" else "FAILED";
            std.debug.print("[worker:{s}] {s} ({d}ms)\n", .{ e.task_id, symbol, e.duration_ms });
        },
        .worker_skipped => |e| std.debug.print("[worker:{s}] Skipped: {s}\n", .{ e.task_id, e.reason }),
        .cost_update => |e| {
            var buf: [64]u8 = undefined;
            std.debug.print("[orchestrator] Running cost: {s}\n", .{pricing.formatCost(&buf, e.total_usd)});
        },
        .orchestration_complete => |e| {
            const status: []const u8 = if (e.success) "SUCCESS" else "PARTIAL";
            std.debug.print("\n[orchestrator] Orchestration {s}\n", .{status});
        },
    }
}

pub const Orchestrator = struct {
    allocator: Allocator,
    agent_config: config.AgentConfig,
    orch_config: config.OrchestratorConfig,
    on_event: OrchestratorEventCallback,
    audit: ?audit_mod.AuditLog,

    pub fn init(
        allocator: Allocator,
        agent_config: config.AgentConfig,
        orch_config: config.OrchestratorConfig,
    ) Orchestrator {
        // Initialize audit log if enabled
        var audit: ?audit_mod.AuditLog = null;
        if (orch_config.audit_log) {
            const audit_path = orch_config.audit_path orelse blk: {
                const p = std.fmt.allocPrint(allocator, "{s}/audit.jsonl", .{agent_config.sandbox.root}) catch break :blk "audit.jsonl";
                break :blk p;
            };
            audit = audit_mod.AuditLog.init(allocator, audit_path) catch null;
        }

        return .{
            .allocator = allocator,
            .agent_config = agent_config,
            .orch_config = orch_config,
            .on_event = &defaultOrchestratorEventHandler,
            .audit = audit,
        };
    }

    pub fn deinit(self: *Orchestrator) void {
        if (self.audit) |*a| a.deinit();
    }

    /// Run the full orchestration: architect -> validate -> execute workers
    pub fn run(self: *Orchestrator, goal: []const u8) !OrchestratorResult {
        if (self.audit) |*a| a.logPhase("start", goal);

        // Phase 1: Architect
        if (self.on_event) |emit| emit(.{ .phase_start = .{ .phase = "ARCHITECT" } });
        if (self.audit) |*a| a.logPhase("architect", "starting");

        var graph = self.runArchitect(goal) catch |err| {
            if (self.audit) |*a| a.logPhase("architect_failed", @errorName(err));
            return OrchestratorResult{
                .success = false,
                .tasks_completed = 0,
                .tasks_failed = 0,
                .tasks_skipped = 0,
                .total_input_tokens = 0,
                .total_output_tokens = 0,
                .total_cost_usd = 0,
                .plan_path = null,
                .summary = try self.allocator.dupe(u8, "Architect phase failed"),
                .allocator = self.allocator,
            };
        };
        defer graph.deinit();

        // Phase 2: Validate (already done in plan_tasks tool, but double-check)
        if (self.on_event) |emit| emit(.{ .phase_start = .{ .phase = "VALIDATE" } });

        graph.validate() catch {
            return OrchestratorResult{
                .success = false,
                .tasks_completed = 0,
                .tasks_failed = 0,
                .tasks_skipped = 0,
                .total_input_tokens = 0,
                .total_output_tokens = 0,
                .total_cost_usd = 0,
                .plan_path = null,
                .summary = try self.allocator.dupe(u8, "Plan validation failed"),
                .allocator = self.allocator,
            };
        };

        const exec_summary = graph.executionSummary(self.allocator) catch "?";
        defer self.allocator.free(exec_summary);

        if (self.on_event) |emit| emit(.{ .plan_accepted = .{
            .task_count = @intCast(graph.tasks.items.len),
            .execution_order = exec_summary,
        } });

        // Save plan if configured
        var plan_path: ?[]const u8 = null;
        if (self.orch_config.save_plan) {
            const path = self.orch_config.plan_path orelse blk: {
                const p = std.fmt.allocPrint(self.allocator, "{s}/plan.json", .{self.agent_config.sandbox.root}) catch break :blk null;
                break :blk p;
            };
            if (path) |p| {
                var sess = session_mod.Session.create(self.allocator, goal, &graph) catch null;
                if (sess) |*s| {
                    s.save(p) catch {};
                    s.deinit();
                }
                plan_path = try self.allocator.dupe(u8, p);
                // Free the path if it was allocated from the blk
                if (self.orch_config.plan_path == null) self.allocator.free(p);
            }
        }

        // Phase 3: Execute workers
        if (self.on_event) |emit| emit(.{ .phase_start = .{ .phase = "EXECUTE" } });
        if (self.audit) |*a| a.logPhase("execute", "starting workers");

        return self.executeTaskGraph(&graph, plan_path);
    }

    /// Resume from a saved plan
    pub fn runFromPlan(self: *Orchestrator, plan_json: []const u8) !OrchestratorResult {
        if (self.audit) |*a| a.logPhase("resume", "loading plan");

        var graph = task_graph.TaskGraph.parseFromJson(self.allocator, plan_json) catch {
            return OrchestratorResult{
                .success = false,
                .tasks_completed = 0,
                .tasks_failed = 0,
                .tasks_skipped = 0,
                .total_input_tokens = 0,
                .total_output_tokens = 0,
                .total_cost_usd = 0,
                .plan_path = null,
                .summary = try self.allocator.dupe(u8, "Failed to parse plan JSON"),
                .allocator = self.allocator,
            };
        };
        defer graph.deinit();

        graph.validate() catch {
            return OrchestratorResult{
                .success = false,
                .tasks_completed = 0,
                .tasks_failed = 0,
                .tasks_skipped = 0,
                .total_input_tokens = 0,
                .total_output_tokens = 0,
                .total_cost_usd = 0,
                .plan_path = null,
                .summary = try self.allocator.dupe(u8, "Plan validation failed"),
                .allocator = self.allocator,
            };
        };

        if (self.on_event) |emit| emit(.{ .phase_start = .{ .phase = "EXECUTE (resume)" } });

        return self.executeTaskGraph(&graph, null);
    }

    /// Phase 1: Run the architect agent to produce a task DAG
    fn runArchitect(self: *Orchestrator, goal: []const u8) !task_graph.TaskGraph {
        // Clear any previous captured plan
        plan_tasks.clearCapturedPlan();

        // Build architect-specific config
        var arch_config = self.agent_config;
        arch_config.provider = .{
            .name = self.orch_config.architect_provider,
            .model = self.orch_config.architect_model,
            .max_tokens = 64000,
            .max_turns = self.orch_config.architect_max_turns,
            .temperature = 0.7,
        };

        // Enable plan_tasks tool + read-only tools for architect
        const architect_tools = &[_][]const u8{
            "read_file", "list_files", "search_files", "grep", "cat", "find", "plan_tasks",
        };
        arch_config.tools.enabled = architect_tools;

        // Set architect system prompt
        arch_config.system_prompt =
            \\You are an AI architect. Your job is to explore a codebase and design a task execution plan.
            \\
            \\INSTRUCTIONS:
            \\1. First, explore the codebase using read-only tools (list_files, read_file, grep, etc.)
            \\2. Understand the project structure, patterns, and existing code
            \\3. Design a task DAG (directed acyclic graph) that breaks the goal into subtasks
            \\4. Call the plan_tasks tool EXACTLY ONCE with your complete plan
            \\
            \\TASK DESIGN GUIDELINES:
            \\- Each task should be self-contained and achievable by a single agent
            \\- Use dependencies to express ordering constraints
            \\- Choose the right provider/model for each task:
            \\  - Simple tasks (create files, copy): use "claude" with model "claude-haiku-4-5-20251001"
            \\  - Complex tasks (implement logic, refactor): use "claude" with model "claude-sonnet-4-5-20250929"
            \\  - Tasks needing web info: use "grok" for web search capability
            \\- Assign appropriate tools to each task (read_file, write_file, execute_command, etc.)
            \\- Keep tasks focused — one task per logical unit of work
            \\- Include a final verification/test task when appropriate
        ;

        // Create and run the architect executor
        var arch_executor = executor.AgentExecutor.init(self.allocator, arch_config) catch {
            return OrchestratorError.ArchitectFailed;
        };
        defer arch_executor.deinit();

        // Wrap the architect event handler
        arch_executor.on_event = &defaultArchitectEventHandler;

        const task_prompt = std.fmt.allocPrint(self.allocator,
            \\GOAL: {s}
            \\
            \\Explore the codebase and design a task plan to achieve this goal.
            \\Call plan_tasks with your complete plan when ready.
        , .{goal}) catch return OrchestratorError.OutOfMemory;
        defer self.allocator.free(task_prompt);

        var result = arch_executor.run(task_prompt) catch {
            return OrchestratorError.ArchitectFailed;
        };
        defer result.deinit();

        // Check if plan_tasks was called and captured a plan
        if (plan_tasks.captured_plan) |*plan| {
            // Move ownership: take the plan, null out the module var
            const graph = plan.*;
            plan_tasks.captured_plan = null;
            return graph;
        }

        return OrchestratorError.NoPlanProduced;
    }

    /// Phase 3: Execute all tasks in the graph in dependency order
    fn executeTaskGraph(self: *Orchestrator, graph: *task_graph.TaskGraph, plan_path: ?[]const u8) !OrchestratorResult {
        const order = graph.topologicalSort(self.allocator) catch {
            return OrchestratorResult{
                .success = false,
                .tasks_completed = 0,
                .tasks_failed = 0,
                .tasks_skipped = 0,
                .total_input_tokens = 0,
                .total_output_tokens = 0,
                .total_cost_usd = 0,
                .plan_path = plan_path,
                .summary = try self.allocator.dupe(u8, "Failed to sort task graph"),
                .allocator = self.allocator,
            };
        };
        defer self.allocator.free(order);

        var completed: u32 = 0;
        var failed: u32 = 0;
        var skipped: u32 = 0;
        var total_input: u32 = 0;
        var total_output: u32 = 0;
        var total_cost: f64 = 0;

        for (order) |idx| {
            const task = &graph.tasks.items[idx];

            // Check if dependencies are met
            if (graph.hasDependencyFailed(task)) {
                task.status = .skipped;
                skipped += 1;
                if (self.on_event) |emit| emit(.{ .worker_skipped = .{
                    .task_id = task.id,
                    .reason = "dependency failed",
                } });
                if (self.audit) |*a| a.logTaskStatus(task.id, "skipped", 0, 0, 0);
                continue;
            }

            // Skip already completed tasks (resume support)
            if (task.status == .completed) {
                completed += 1;
                continue;
            }

            // Check cost limit
            if (self.orch_config.max_cost_usd > 0 and total_cost >= self.orch_config.max_cost_usd) {
                task.status = .skipped;
                skipped += 1;
                if (self.on_event) |emit| emit(.{ .worker_skipped = .{
                    .task_id = task.id,
                    .reason = "cost limit reached",
                } });
                continue;
            }

            // Run the worker
            if (self.on_event) |emit| emit(.{ .worker_start = .{
                .task_id = task.id,
                .provider = task.provider,
            } });

            var timer = Timer.start() catch unreachable;
            task.status = .running;

            self.runWorker(graph, task) catch {
                task.status = .failed;
                task.error_msg = "Worker execution error";
            };

            const elapsed_ns = timer.read();
            const elapsed_ms = elapsed_ns / std.time.ns_per_ms;
            task.duration_ns = elapsed_ns;

            total_input += task.input_tokens;
            total_output += task.output_tokens;

            // Calculate cost for this task
            const effective_model = task.model orelse getDefaultModel(task.provider);
            if (pricing.calculateCost(effective_model, task.input_tokens, task.output_tokens)) |cost| {
                total_cost += cost;
            }

            if (task.status == .completed) {
                completed += 1;
            } else {
                failed += 1;
            }

            if (self.on_event) |emit| {
                emit(.{ .worker_complete = .{
                    .task_id = task.id,
                    .success = task.status == .completed,
                    .duration_ms = elapsed_ms,
                } });
                emit(.{ .cost_update = .{ .total_usd = total_cost } });
            }

            if (self.audit) |*a| {
                a.logTaskStatus(
                    task.id,
                    task.status.toString(),
                    task.input_tokens,
                    task.output_tokens,
                    elapsed_ms,
                );
            }

            // Update saved plan after each task
            if (self.orch_config.save_plan) {
                if (plan_path) |pp| {
                    var sess = session_mod.Session.create(self.allocator, "", graph) catch null;
                    if (sess) |*s| {
                        s.total_input_tokens = total_input;
                        s.total_output_tokens = total_output;
                        s.save(pp) catch {};
                        s.deinit();
                    }
                }
            }
        }

        const all_success = failed == 0 and skipped == 0;

        if (self.on_event) |emit| emit(.{ .orchestration_complete = .{ .success = all_success } });
        if (self.audit) |*a| {
            const status: []const u8 = if (all_success) "success" else "partial";
            a.logPhase("complete", status);
        }

        // Build summary
        var cost_buf: [64]u8 = undefined;
        const summary = std.fmt.allocPrint(self.allocator,
            \\Orchestration complete: {d} completed, {d} failed, {d} skipped
            \\Tokens: {d} input, {d} output
            \\Cost: {s}
        , .{
            completed,
            failed,
            skipped,
            total_input,
            total_output,
            pricing.formatCost(&cost_buf, total_cost),
        }) catch try self.allocator.dupe(u8, "Orchestration complete");

        return OrchestratorResult{
            .success = all_success,
            .tasks_completed = completed,
            .tasks_failed = failed,
            .tasks_skipped = skipped,
            .total_input_tokens = total_input,
            .total_output_tokens = total_output,
            .total_cost_usd = total_cost,
            .plan_path = plan_path,
            .summary = summary,
            .allocator = self.allocator,
        };
    }

    /// Execute a single worker task
    fn runWorker(self: *Orchestrator, graph: *task_graph.TaskGraph, task: *task_graph.TaskNode) !void {
        // Build context from upstream completed tasks
        const context = graph.buildContext(self.allocator, task.id) catch "";
        defer if (context.len > 0) self.allocator.free(context);

        // Build worker config
        var worker_config = self.agent_config;
        worker_config.provider = .{
            .name = task.provider,
            .model = task.model,
            .max_tokens = 64000,
            .max_turns = task.max_turns,
            .temperature = 0.7,
        };

        // Set worker tools (use task-specific tools, or defaults)
        if (task.tools.len > 0) {
            worker_config.tools.enabled = task.tools;
        }

        // Create executor
        var worker_executor = executor.AgentExecutor.init(self.allocator, worker_config) catch {
            task.status = .failed;
            task.error_msg = "Failed to initialize worker executor";
            return;
        };
        defer worker_executor.deinit();

        // Inject context from upstream tasks
        if (context.len > 0) {
            worker_executor.context_injection = context;
        }

        // Run the worker
        var result = worker_executor.run(task.prompt) catch {
            task.status = .failed;
            task.error_msg = "Worker agent returned error";
            return;
        };
        defer result.deinit();

        // Store results
        task.status = if (result.success) .completed else .failed;
        task.result = self.allocator.dupe(u8, result.final_response) catch null;
        task.input_tokens = result.total_input_tokens;
        task.output_tokens = result.total_output_tokens;

        // Track the allocated result string
        if (task.result) |r| {
            graph._strings.append(self.allocator, r) catch {};
        }
    }
};

fn defaultArchitectEventHandler(event: executor.ToolEvent) void {
    switch (event) {
        .turn_start => |e| std.debug.print("[architect] Turn {d}...\n", .{e.turn}),
        .tool_start => |e| std.debug.print("[architect] {s}\n", .{e.name}),
        .tool_complete => |e| {
            const symbol: []const u8 = if (e.success) "done" else "failed";
            std.debug.print("[architect] {s} {s} ({d}ms)\n", .{ e.name, symbol, e.duration_ms });
        },
        .turn_complete => {},
    }
}

fn getDefaultModel(provider: []const u8) []const u8 {
    if (std.mem.eql(u8, provider, "claude")) return "claude-sonnet-4-5-20250929";
    if (std.mem.eql(u8, provider, "gemini")) return "gemini-2.5-pro";
    if (std.mem.eql(u8, provider, "openai") or std.mem.eql(u8, provider, "gpt")) return "gpt-5.2";
    if (std.mem.eql(u8, provider, "grok")) return "grok-4-1-fast-non-reasoning";
    if (std.mem.eql(u8, provider, "deepseek")) return "deepseek-chat";
    return "unknown";
}
