//! Cognitive Telemetry Kit — Core Module
//!
//! Platform-agnostic types, policy engine, config parser, and IPC protocol
//! shared between all CTK components (Linux eBPF, macOS Endpoint Security,
//! conductor, CLI tools).
//!
//! No platform dependencies. No libc. Compiles everywhere Zig targets.

pub const events = @import("events.zig");
pub const policy = @import("policy.zig");
pub const config = @import("config.zig");
pub const cognitive = @import("cognitive.zig");
pub const ipc = @import("ipc.zig");
pub const timestamp = @import("timestamp.zig");
pub const types = @import("types.zig");

// Re-export the most commonly used types at top level
pub const Event = events.Event;
pub const Decision = policy.Decision;
pub const Rule = policy.Rule;
pub const PolicyEngine = policy.PolicyEngine;
pub const PhiTimestamp = timestamp.PhiTimestamp;
pub const AgentInstance = types.AgentInstance;
pub const Message = ipc.Message;

test {
    _ = events;
    _ = policy;
    _ = config;
    _ = cognitive;
    _ = ipc;
    _ = timestamp;
    _ = types;
}
