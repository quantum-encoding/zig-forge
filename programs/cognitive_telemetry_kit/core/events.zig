//! Unified event type for the Cognitive Telemetry Kit.
//!
//! All observation sources (eBPF, Endpoint Security, DYLD interposition,
//! PTY capture) produce Events. The policy engine and intelligence layer
//! consume them. One event type, platform-agnostic.

const std = @import("std");
const types = @import("types.zig");

pub const Event = struct {
    timestamp_ns: u64,
    pid: u32,
    process_path: []const u8,
    kind: Kind,
    target_path: ?[]const u8 = null,
    detail: ?[]const u8 = null,
    agent_id: ?[]const u8 = null,
    responsible_pid: ?u32 = null, // macOS: from responsible_audit_token
    parent_pid: ?u32 = null, // parent process

    pub const Kind = enum(u8) {
        // File operations — from ES AUTH events (macOS) and eBPF tracepoints (Linux)
        file_unlink = 0,
        file_rename = 1,
        file_truncate = 2,
        file_link = 3,
        file_create = 4,
        file_clone = 5,
        file_open = 6,
        file_chmod = 7,
        file_exchangedata = 8,
        file_setextattr = 9,
        file_deleteextattr = 10,

        // Network — from eBPF tracepoints / ES notify
        net_connect = 16,
        net_bind = 17,
        net_listen = 18,
        net_send = 19,

        // Execution — from eBPF / ES
        exec = 32,
        fork = 33,
        setuid = 34,
        signal = 35,

        // Cognitive — from TTY capture (eBPF kprobe / DYLD interposition)
        cognitive_state_change = 48,
        tool_invocation = 49,
        tool_completion = 50,
        permission_request = 51,
        permission_response = 52,

        // Module loading — from eBPF (rootkit detection)
        module_load = 64,
    };

    /// Returns true if this event kind represents a file operation.
    pub fn isFileOp(self: Event) bool {
        return @intFromEnum(self.kind) <= 10;
    }

    /// Returns true if this event kind represents a network operation.
    pub fn isNetOp(self: Event) bool {
        const k = @intFromEnum(self.kind);
        return k >= 16 and k <= 19;
    }

    /// Returns true if this event kind represents a cognitive observation.
    pub fn isCognitive(self: Event) bool {
        const k = @intFromEnum(self.kind);
        return k >= 48 and k <= 52;
    }
};

/// Serialise an event to JSON in a caller-provided buffer.
pub fn eventToJson(event: *const Event, buf: []u8) ?[]const u8 {
    const target = event.target_path orelse "";
    const detail = event.detail orelse "";
    const agent = event.agent_id orelse "";
    return std.fmt.bufPrint(buf,
        \\{{"ts":{d},"pid":{d},"kind":{d},"proc":"{s}","target":"{s}","detail":"{s}","agent":"{s}"}}
    , .{
        event.timestamp_ns,
        event.pid,
        @intFromEnum(event.kind),
        event.process_path,
        target,
        detail,
        agent,
    }) catch null;
}
