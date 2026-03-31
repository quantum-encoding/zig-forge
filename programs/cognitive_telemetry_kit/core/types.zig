//! Shared types for the Cognitive Telemetry Kit.

pub const AgentInstance = struct {
    pid: u32,
    executable: []const u8,
    working_dir: []const u8,
    status: Status,
    started_at_ns: u64,
    last_activity_ns: u64,
    cognitive_state: ?[]const u8 = null,
    agent_id: ?[]const u8 = null,

    pub const Status = enum(u8) {
        running = 0,
        waiting_permission = 1,
        paused = 2,
        completed = 3,
        failed = 4,
    };
};

pub const ProcessInfo = struct {
    pid: u32,
    executable: []const u8,
    is_trusted: bool = false,
    is_es_client: bool = false,
};
