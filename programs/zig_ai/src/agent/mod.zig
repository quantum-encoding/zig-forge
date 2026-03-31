// Copyright (c) 2025 QUANTUM ENCODING LTD
// Licensed under the MIT License.

//! Agent Module
//! Provides autonomous agent capabilities with security sandboxing

pub const config = @import("config.zig");
pub const security = @import("security/mod.zig");
pub const tools = @import("tools/mod.zig");
pub const executor = @import("executor.zig");
pub const cli = @import("cli.zig");
pub const pricing = @import("pricing.zig");
pub const orchestrator = @import("orchestrator.zig");
pub const task_graph = @import("task_graph.zig");
pub const session = @import("session.zig");
pub const audit = @import("audit.zig");

// Re-exports
pub const AgentConfig = config.AgentConfig;
pub const OrchestratorConfig = config.OrchestratorConfig;
pub const AgentExecutor = executor.AgentExecutor;
pub const AgentResult = executor.AgentResult;
pub const ToolEvent = executor.ToolEvent;
pub const EventCallback = executor.EventCallback;
pub const Sandbox = security.Sandbox;
pub const SandboxConfig = security.SandboxConfig;
pub const ToolRegistry = tools.ToolRegistry;
pub const ToolOutput = tools.ToolOutput;
pub const Orchestrator = orchestrator.Orchestrator;
pub const OrchestratorResult = orchestrator.OrchestratorResult;
pub const OrchestratorEvent = orchestrator.OrchestratorEvent;
pub const TaskGraph = task_graph.TaskGraph;
pub const TaskNode = task_graph.TaskNode;
pub const Session = session.Session;
pub const AuditLog = audit.AuditLog;

/// Run CLI commands
pub fn runCli(allocator: @import("std").mem.Allocator, args: []const []const u8) !void {
    try cli.run(allocator, args);
}
