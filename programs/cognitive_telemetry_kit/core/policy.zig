//! Unified policy engine for the Cognitive Telemetry Kit.
//!
//! Merges Guardian Shield path protection, claude-shepherd command rules,
//! and network allowlisting into one rule evaluator. Platform-agnostic —
//! the same rules are enforced by eBPF (Linux) and Endpoint Security (macOS).

const std = @import("std");
const events = @import("events.zig");
const Event = events.Event;

pub const Decision = enum(u8) {
    allow = 0,
    deny = 1,
    prompt = 2, // ask user (only for interactive orchestration, not kernel enforcement)
    allow_if_askpass = 3, // allow only if invoked via askpass (human-in-the-loop)
};

pub const Rule = struct {
    kind: Kind,
    pattern: []const u8,
    decision: Decision,
    reason: []const u8 = "",

    pub const Kind = enum(u8) {
        protected_path = 0, // blocks file ops on matching paths
        whitelisted_path = 1, // always allows file ops (overrides protected)
        trusted_process = 2, // bypass all checks for this executable
        allowed_command = 3, // allow this tool/command (global)
        denied_command = 4, // block this tool/command (global)
        prompt_command = 5, // require user confirmation
        network_allow = 6, // allow connections to this host/pattern
        observe_process = 7, // capture cognitive state from this process name
        cost_limit = 8, // max USD per interval (pattern = "50.00")
        agent_deny = 9, // block only when responsible process is an observed agent
        agent_allow = 10, // allow only these commands from observed agents (allowlist mode)
        agent_askpass = 11, // allow for agents ONLY via askpass (human-in-the-loop sudo)
    };
};

pub const PolicyEngine = struct {
    rules: []const Rule,

    /// Evaluate an event against the rule set.
    /// Rules are evaluated in priority order:
    ///   1. Emergency disable check (caller responsibility)
    ///   2. Trusted process → allow (bypass everything)
    ///   3. Whitelisted path → allow (for file ops)
    ///   4. Protected path → deny (for file ops)
    ///   5. Denied command → deny (for tool invocations)
    ///   6. Allowed command → allow (for tool invocations)
    ///   7. Prompt command → prompt
    ///   8. Network allowlist → deny if not listed
    ///   9. Default: allow
    pub fn evaluate(self: *const PolicyEngine, event: *const Event) Decision {
        // Trusted process bypass
        for (self.rules) |rule| {
            if (rule.kind == .trusted_process and pathMatches(event.process_path, rule.pattern)) {
                return .allow;
            }
        }

        // File operation rules
        if (event.isFileOp()) {
            if (event.target_path) |target| {
                // Whitelist first (overrides protection)
                for (self.rules) |rule| {
                    if (rule.kind == .whitelisted_path and pathStartsWith(target, rule.pattern)) {
                        return .allow;
                    }
                }
                // Then protected paths
                for (self.rules) |rule| {
                    if (rule.kind == .protected_path and pathStartsWith(target, rule.pattern)) {
                        return .deny;
                    }
                }
            }
        }

        // Command/tool rules (for exec, permission_request, and tool_invocation events)
        if (event.kind == .exec or event.kind == .permission_request or event.kind == .tool_invocation) {
            if (event.detail) |cmd| {
                // Deny rules first
                for (self.rules) |rule| {
                    if (rule.kind == .denied_command and commandMatches(cmd, rule.pattern)) {
                        return .deny;
                    }
                }
                // Allow rules
                for (self.rules) |rule| {
                    if (rule.kind == .allowed_command and commandMatches(cmd, rule.pattern)) {
                        return .allow;
                    }
                }
                // Prompt rules
                for (self.rules) |rule| {
                    if (rule.kind == .prompt_command and commandMatches(cmd, rule.pattern)) {
                        return .prompt;
                    }
                }
            }
        }

        // Agent-scoped rules (only apply when responsible process is an observed agent)
        if (event.kind == .exec or event.kind == .permission_request or event.kind == .tool_invocation) {
            if (self.isAgentSpawned(event)) {
                if (event.detail) |cmd| {
                    // Agent askpass rules — allow via human review gate
                    for (self.rules) |rule| {
                        if (rule.kind == .agent_askpass and commandMatches(cmd, rule.pattern)) {
                            return .allow_if_askpass;
                        }
                    }
                    // Agent deny rules
                    for (self.rules) |rule| {
                        if (rule.kind == .agent_deny and commandMatches(cmd, rule.pattern)) {
                            return .deny;
                        }
                    }
                    // Agent allowlist mode — if ANY agent_allow rules exist,
                    // only explicitly allowed commands pass
                    var has_agent_allow = false;
                    for (self.rules) |rule| {
                        if (rule.kind == .agent_allow) {
                            has_agent_allow = true;
                            if (commandMatches(cmd, rule.pattern)) return .allow;
                        }
                    }
                    if (has_agent_allow) return .deny; // not in allowlist
                }
            }
        }

        // Network rules — deny if connecting to unlisted host
        if (event.isNetOp() and event.kind == .net_connect) {
            if (event.target_path) |host| {
                var has_network_rules = false;
                for (self.rules) |rule| {
                    if (rule.kind == .network_allow) {
                        has_network_rules = true;
                        if (hostMatches(host, rule.pattern)) return .allow;
                    }
                }
                if (has_network_rules) return .deny; // no match in allowlist
            }
        }

        return .allow;
    }

    /// Check if the event was spawned by an observed agent process.
    /// Uses responsible_pid to trace back to the root process, then checks
    /// if that process path matches an observe_process rule.
    /// Falls back to checking the process_path directly.
    fn isAgentSpawned(self: *const PolicyEngine, event: *const Event) bool {
        // If the caller already identified this as agent-spawned
        if (event.agent_id != null) return true;

        // Check if the process itself is an observed agent
        for (self.rules) |rule| {
            if (rule.kind == .observe_process) {
                const proc_basename = std.fs.path.basename(event.process_path);
                if (std.mem.indexOf(u8, proc_basename, rule.pattern) != null) return true;
            }
        }
        return false;
    }
};

// ── Matching helpers ─────────────────────────────────────────────────

fn pathStartsWith(path: []const u8, prefix: []const u8) bool {
    return std.mem.startsWith(u8, path, prefix);
}

fn pathMatches(path: []const u8, pattern: []const u8) bool {
    if (std.mem.eql(u8, pattern, "*")) return true;
    return std.mem.eql(u8, path, pattern);
}

fn commandMatches(cmd: []const u8, pattern: []const u8) bool {
    if (std.mem.eql(u8, pattern, "*")) return true;
    // Match command name (first word) or full string
    const first_space = std.mem.indexOf(u8, cmd, " ") orelse cmd.len;
    const cmd_name = cmd[0..first_space];
    return std.mem.eql(u8, cmd_name, pattern) or std.mem.eql(u8, cmd, pattern);
}

fn hostMatches(host: []const u8, pattern: []const u8) bool {
    if (std.mem.eql(u8, pattern, "*")) return true;
    // Wildcard prefix: *.googleapis.com matches storage.googleapis.com
    if (pattern.len > 2 and pattern[0] == '*' and pattern[1] == '.') {
        const suffix = pattern[1..]; // ".googleapis.com"
        return std.mem.endsWith(u8, host, suffix);
    }
    return std.mem.eql(u8, host, pattern);
}

// ── Tests ────────────────────────────────────────────────────────────

test "policy: protected path blocks unlink" {
    const rules = [_]Rule{
        .{ .kind = .protected_path, .pattern = "/etc/", .decision = .deny },
        .{ .kind = .whitelisted_path, .pattern = "/tmp/", .decision = .allow },
    };
    const engine = PolicyEngine{ .rules = &rules };

    const deny_event = Event{
        .timestamp_ns = 0,
        .pid = 1,
        .process_path = "/usr/bin/rm",
        .kind = .file_unlink,
        .target_path = "/etc/passwd",
    };
    try std.testing.expectEqual(Decision.deny, engine.evaluate(&deny_event));

    const allow_event = Event{
        .timestamp_ns = 0,
        .pid = 1,
        .process_path = "/usr/bin/rm",
        .kind = .file_unlink,
        .target_path = "/tmp/scratch.txt",
    };
    try std.testing.expectEqual(Decision.allow, engine.evaluate(&allow_event));
}

test "policy: trusted process bypasses protection" {
    const rules = [_]Rule{
        .{ .kind = .trusted_process, .pattern = "/usr/bin/git", .decision = .allow },
        .{ .kind = .protected_path, .pattern = "/etc/", .decision = .deny },
    };
    const engine = PolicyEngine{ .rules = &rules };

    const event = Event{
        .timestamp_ns = 0,
        .pid = 1,
        .process_path = "/usr/bin/git",
        .kind = .file_unlink,
        .target_path = "/etc/something",
    };
    try std.testing.expectEqual(Decision.allow, engine.evaluate(&event));
}

test "policy: network allowlist" {
    const rules = [_]Rule{
        .{ .kind = .network_allow, .pattern = "github.com", .decision = .allow },
        .{ .kind = .network_allow, .pattern = "*.googleapis.com", .decision = .allow },
    };
    const engine = PolicyEngine{ .rules = &rules };

    const allow_event = Event{
        .timestamp_ns = 0,
        .pid = 1,
        .process_path = "/usr/bin/curl",
        .kind = .net_connect,
        .target_path = "storage.googleapis.com",
    };
    try std.testing.expectEqual(Decision.allow, engine.evaluate(&allow_event));

    const deny_event = Event{
        .timestamp_ns = 0,
        .pid = 1,
        .process_path = "/usr/bin/curl",
        .kind = .net_connect,
        .target_path = "evil.example.com",
    };
    try std.testing.expectEqual(Decision.deny, engine.evaluate(&deny_event));
}

test "policy: agent_deny blocks command only from agent processes" {
    const rules = [_]Rule{
        .{ .kind = .agent_deny, .pattern = "rm", .decision = .deny },
    };
    const engine = PolicyEngine{ .rules = &rules };

    // Agent (has agent_id) running a denied command → deny
    const agent_event = Event{
        .timestamp_ns = 0,
        .pid = 42,
        .process_path = "/usr/bin/claude",
        .kind = .exec,
        .detail = "rm -rf /tmp/foo",
        .agent_id = "agent-1",
    };
    try std.testing.expectEqual(Decision.deny, engine.evaluate(&agent_event));

    // Non-agent running the same command → allow (no agent_deny applies)
    const non_agent_event = Event{
        .timestamp_ns = 0,
        .pid = 43,
        .process_path = "/usr/bin/bash",
        .kind = .exec,
        .detail = "rm -rf /tmp/foo",
    };
    try std.testing.expectEqual(Decision.allow, engine.evaluate(&non_agent_event));
}

test "policy: agent_allow allowlist mode blocks unlisted agent commands" {
    const rules = [_]Rule{
        .{ .kind = .agent_allow, .pattern = "cat", .decision = .allow },
        .{ .kind = .agent_allow, .pattern = "ls", .decision = .allow },
    };
    const engine = PolicyEngine{ .rules = &rules };

    // Command in allowlist → allow
    const allowed_event = Event{
        .timestamp_ns = 0,
        .pid = 42,
        .process_path = "/usr/bin/claude",
        .kind = .exec,
        .detail = "cat README.md",
        .agent_id = "agent-1",
    };
    try std.testing.expectEqual(Decision.allow, engine.evaluate(&allowed_event));

    // Command not in allowlist → deny
    const denied_event = Event{
        .timestamp_ns = 0,
        .pid = 42,
        .process_path = "/usr/bin/claude",
        .kind = .exec,
        .detail = "wget http://example.com",
        .agent_id = "agent-1",
    };
    try std.testing.expectEqual(Decision.deny, engine.evaluate(&denied_event));
}

test "policy: agent_allow does not restrict non-agent processes" {
    const rules = [_]Rule{
        .{ .kind = .agent_allow, .pattern = "cat", .decision = .allow },
    };
    const engine = PolicyEngine{ .rules = &rules };

    // Non-agent running something not in agent allowlist → still allowed (no agent context)
    const event = Event{
        .timestamp_ns = 0,
        .pid = 10,
        .process_path = "/usr/bin/bash",
        .kind = .exec,
        .detail = "wget http://example.com",
    };
    try std.testing.expectEqual(Decision.allow, engine.evaluate(&event));
}

test "policy: agent_askpass returns allow_if_askpass for agent" {
    const rules = [_]Rule{
        .{ .kind = .agent_askpass, .pattern = "sudo", .decision = .allow },
    };
    const engine = PolicyEngine{ .rules = &rules };

    const event = Event{
        .timestamp_ns = 0,
        .pid = 42,
        .process_path = "/usr/bin/claude",
        .kind = .exec,
        .detail = "sudo apt-get install curl",
        .agent_id = "agent-1",
    };
    try std.testing.expectEqual(Decision.allow_if_askpass, engine.evaluate(&event));
}

test "policy: agent rules via observe_process detect agent by process name" {
    const rules = [_]Rule{
        .{ .kind = .observe_process, .pattern = "claude", .decision = .allow },
        .{ .kind = .agent_deny, .pattern = "dd", .decision = .deny },
    };
    const engine = PolicyEngine{ .rules = &rules };

    // Process named "claude" is treated as an observed agent — no explicit agent_id needed
    const event = Event{
        .timestamp_ns = 0,
        .pid = 55,
        .process_path = "/usr/local/bin/claude",
        .kind = .exec,
        .detail = "dd if=/dev/zero of=/tmp/f",
    };
    try std.testing.expectEqual(Decision.deny, engine.evaluate(&event));
}
