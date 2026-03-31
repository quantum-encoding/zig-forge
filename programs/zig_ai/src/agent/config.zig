// Copyright (c) 2025 QUANTUM ENCODING LTD
// Licensed under the MIT License.

//! Agent configuration loading and validation
//! Loads JSON config files from ~/.config/zig_ai/agents/ or ./config/agents/

const std = @import("std");
const security = @import("security/mod.zig");

pub const ConfigError = error{
    ConfigNotFound,
    InvalidConfig,
    InvalidJson,
    MissingSandboxRoot,
    OutOfMemory,
};

pub const ProviderConfig = struct {
    name: []const u8 = "claude",
    model: ?[]const u8 = null,
    max_tokens: u32 = 64000,
    max_turns: u32 = 50,
    temperature: f32 = 0.7,
};

pub const SandboxConfig = struct {
    root: []const u8,
    writable_paths: []const []const u8 = &.{},
    readonly_paths: []const []const u8 = &.{},
    allow_network: bool = false,
};

pub const ExecuteCommandConfig = struct {
    allowed_commands: []const []const u8 = &security.default_allowed_commands,
    banned_patterns: []const []const u8 = &security.default_banned_patterns,
    timeout_ms: u32 = 30000,
    max_output_bytes: u32 = 65536,
    kill_process_group: bool = true,
};

/// Rule for automatic confirmation interception
/// When a tool matches these rules, user is prompted before execution
/// The AI never knows confirmation was required - just sees the result
pub const ConfirmationRule = struct {
    tool: []const u8, // Tool name to match
    pattern: ?[]const u8 = null, // Optional glob pattern for arguments
    risk_level: RiskLevel = .medium,

    pub const RiskLevel = enum {
        low,
        medium,
        high,
        critical,

        pub fn fromString(s: []const u8) RiskLevel {
            if (std.mem.eql(u8, s, "low")) return .low;
            if (std.mem.eql(u8, s, "high")) return .high;
            if (std.mem.eql(u8, s, "critical")) return .critical;
            return .medium;
        }

        pub fn symbol(self: RiskLevel) []const u8 {
            return switch (self) {
                .low => "[LOW]",
                .medium => "[MEDIUM]",
                .high => "[HIGH]",
                .critical => "[CRITICAL]",
            };
        }

        pub fn color(self: RiskLevel) []const u8 {
            return switch (self) {
                .low => "\x1b[32m", // green
                .medium => "\x1b[33m", // yellow
                .high => "\x1b[91m", // light red
                .critical => "\x1b[31;1m", // bold red
            };
        }
    };
};

/// Default confirmation rules - tools that always require human approval
pub const default_confirmation_rules = [_]ConfirmationRule{
    .{ .tool = "trash_file", .risk_level = .high },
    .{ .tool = "execute_command", .pattern = "rm *", .risk_level = .critical },
    .{ .tool = "execute_command", .pattern = "chmod *", .risk_level = .medium },
    .{ .tool = "execute_command", .pattern = "sudo *", .risk_level = .critical },
    .{ .tool = "write_file", .pattern = "*.env", .risk_level = .critical },
    .{ .tool = "write_file", .pattern = "*config*", .risk_level = .high },
};

/// Permission tier for tool execution
pub const PermissionTier = enum {
    auto, // Runs immediately, no confirmation
    confirm, // Requires user confirmation with reason
    askpass, // Always requires confirmation, full "yes" required
    blocked, // Hard no, structured error returned

    pub fn fromString(s: []const u8) PermissionTier {
        if (std.mem.eql(u8, s, "auto")) return .auto;
        if (std.mem.eql(u8, s, "confirm")) return .confirm;
        if (std.mem.eql(u8, s, "askpass")) return .askpass;
        if (std.mem.eql(u8, s, "blocked")) return .blocked;
        return .confirm; // safe default
    }
};

pub const default_auto_tools = [_][]const u8{
    "grep", "cat", "wc", "find", "read_file", "list_files", "search_files",
};
pub const default_confirm_tools = [_][]const u8{
    "write_file", "trash_file", "rm", "cp", "mv", "mkdir", "touch",
};
pub const default_blocked_commands = [_][]const u8{
    "dd", "shred", "chroot", "mkfifo", "mknod",
};
pub const default_auto_ext_commands = [_][]const u8{
    "npm", "node", "zig", "cargo", "python", "python3", "git", "make", "cmake",
};
pub const default_confirm_ext_commands = [_][]const u8{
    "curl", "wget", "pip", "brew", "apt",
};
pub const default_blocked_ext_commands = [_][]const u8{
    "docker", "podman", "systemctl", "launchctl", "reboot", "shutdown",
};

/// Permission tiers for native tools
pub const PermissionsConfig = struct {
    auto: []const []const u8 = &default_auto_tools,
    confirm: []const []const u8 = &default_confirm_tools,
    blocked_commands: []const []const u8 = &default_blocked_commands,
};

/// Permission tiers for external commands (via execute_command)
pub const ExternalCommandsConfig = struct {
    auto: []const []const u8 = &default_auto_ext_commands,
    confirm: []const []const u8 = &default_confirm_ext_commands,
    blocked: []const []const u8 = &default_blocked_ext_commands,
};

/// Per-command subcommand rules for execute_command
pub const ExternalRule = struct {
    command: []const u8,
    auto_subcommands: []const []const u8 = &.{},
    confirm_subcommands: []const []const u8 = &.{},
    blocked_subcommands: []const []const u8 = &.{},
};

pub const ToolsConfig = struct {
    enabled: []const []const u8 = &.{ "read_file", "write_file", "list_files", "search_files", "execute_command", "confirm_action", "trash_file", "grep", "cat", "wc", "find", "rm", "cp", "mv", "mkdir", "touch", "kill_process" },
    disabled: []const []const u8 = &.{},
    execute_command: ExecuteCommandConfig = .{},
    permissions: PermissionsConfig = .{},
    external_commands: ExternalCommandsConfig = .{},
    external_rules: []const ExternalRule = &.{},
    // Legacy: kept for backward compatibility
    require_confirmation: []const ConfirmationRule = &default_confirmation_rules,
};

/// Configuration for the architect/worker orchestration system
pub const OrchestratorConfig = struct {
    architect_provider: []const u8 = "claude",
    architect_model: ?[]const u8 = null, // null = "claude-opus-4-6"
    architect_max_turns: u32 = 30,
    worker_provider: []const u8 = "claude",
    worker_model: ?[]const u8 = null, // null = "claude-haiku-4-5-20251001"
    worker_max_turns: u32 = 25,
    save_plan: bool = true,
    plan_path: ?[]const u8 = null,
    audit_log: bool = true,
    audit_path: ?[]const u8 = null,
    max_tasks: u32 = 20,
    max_cost_usd: f64 = 0.0, // 0 = no limit
};

pub const LimitsConfig = struct {
    max_file_size_bytes: u32 = 1048576, // 1MB
    max_files_per_operation: u32 = 100,
    max_directory_depth: u32 = 10,
    max_total_output_bytes: u32 = 10485760, // 10MB
};

pub const AgentConfig = struct {
    agent_name: []const u8,
    description: ?[]const u8 = null,
    version: []const u8 = "1.0.0",

    provider: ProviderConfig = .{},
    sandbox: SandboxConfig,
    tools: ToolsConfig = .{},
    limits: LimitsConfig = .{},

    system_prompt: ?[]const u8 = null,
    orchestrator: ?OrchestratorConfig = null,

    allocator: std.mem.Allocator,

    // Internal: track allocated strings for cleanup
    _allocated_strings: std.ArrayListUnmanaged([]const u8) = .empty,
    // Internal: track allocated arrays for cleanup
    _allocated_arrays: std.ArrayListUnmanaged([]const []const u8) = .empty,
    _allocated_rule_arrays: std.ArrayListUnmanaged([]const ConfirmationRule) = .empty,
    _allocated_ext_rule_arrays: std.ArrayListUnmanaged([]const ExternalRule) = .empty,

    pub fn deinit(self: *AgentConfig) void {
        for (self._allocated_strings.items) |s| {
            self.allocator.free(s);
        }
        self._allocated_strings.deinit(self.allocator);

        for (self._allocated_arrays.items) |arr| {
            self.allocator.free(arr);
        }
        self._allocated_arrays.deinit(self.allocator);

        for (self._allocated_rule_arrays.items) |arr| {
            self.allocator.free(arr);
        }
        self._allocated_rule_arrays.deinit(self.allocator);

        for (self._allocated_ext_rule_arrays.items) |arr| {
            self.allocator.free(arr);
        }
        self._allocated_ext_rule_arrays.deinit(self.allocator);
    }

    /// Load config from a file path
    pub fn loadFromFile(allocator: std.mem.Allocator, path: []const u8) !AgentConfig {
        // Read file using C API (Zig 0.16 compatible)
        const path_z = try allocator.allocSentinel(u8, path.len, 0);
        defer allocator.free(path_z);
        @memcpy(path_z, path);

        const file = std.c.fopen(path_z.ptr, "rb") orelse {
            return ConfigError.ConfigNotFound;
        };
        defer _ = std.c.fclose(file);

        // Read content in chunks (no fseek/ftell in Zig 0.16 C bindings)
        var content: std.ArrayListUnmanaged(u8) = .empty;
        defer content.deinit(allocator);

        var buf: [4096]u8 = undefined;
        while (true) {
            const read_count = std.c.fread(&buf, 1, buf.len, file);
            if (read_count > 0) {
                try content.appendSlice(allocator, buf[0..read_count]);
            }
            if (read_count < buf.len) break; // EOF or error
        }

        if (content.items.len == 0) return ConfigError.InvalidConfig;

        return parseJson(allocator, content.items);
    }

    /// Load config by name (searches config directories)
    pub fn loadByName(allocator: std.mem.Allocator, name: []const u8) !AgentConfig {
        // Try user config first
        const home = std.mem.span(std.c.getenv("HOME") orelse "/tmp");
        const user_path = try std.fmt.allocPrint(allocator, "{s}/.config/zig_ai/agents/{s}.json", .{ home, name });
        defer allocator.free(user_path);

        if (loadFromFile(allocator, user_path)) |config| {
            return config;
        } else |_| {}

        // Try project config
        const project_path = try std.fmt.allocPrint(allocator, "./config/agents/{s}.json", .{name});
        defer allocator.free(project_path);

        return loadFromFile(allocator, project_path);
    }

    /// Parse JSON content into AgentConfig
    fn parseJson(allocator: std.mem.Allocator, content: []const u8) !AgentConfig {
        const parsed = std.json.parseFromSlice(std.json.Value, allocator, content, .{
            .allocate = .alloc_always,
        }) catch {
            return ConfigError.InvalidJson;
        };
        defer parsed.deinit();

        const root = parsed.value.object;

        var config = AgentConfig{
            .agent_name = "",
            .sandbox = .{ .root = "" },
            .allocator = allocator,
        };
        errdefer config.deinit();

        // Parse required fields
        if (root.get("agent_name")) |v| {
            config.agent_name = try dupeAndTrack(&config, v.string);
        } else {
            config.agent_name = try dupeAndTrack(&config, "unnamed");
        }

        // Parse sandbox (required)
        if (root.get("sandbox")) |sandbox_val| {
            const sandbox_obj = sandbox_val.object;
            if (sandbox_obj.get("root")) |r| {
                config.sandbox.root = try dupeAndTrack(&config, r.string);
            } else {
                return ConfigError.MissingSandboxRoot;
            }

            if (sandbox_obj.get("allow_network")) |n| {
                config.sandbox.allow_network = n.bool;
            }

            if (sandbox_obj.get("writable_paths")) |wp| {
                config.sandbox.writable_paths = try parseStringArray(&config, wp.array.items);
            }

            if (sandbox_obj.get("readonly_paths")) |rp| {
                config.sandbox.readonly_paths = try parseStringArray(&config, rp.array.items);
            }
        } else {
            return ConfigError.MissingSandboxRoot;
        }

        // Parse optional fields
        if (root.get("description")) |v| {
            config.description = try dupeAndTrack(&config, v.string);
        }

        if (root.get("version")) |v| {
            config.version = try dupeAndTrack(&config, v.string);
        }

        if (root.get("system_prompt")) |v| {
            config.system_prompt = try dupeAndTrack(&config, v.string);
        }

        // Parse provider
        if (root.get("provider")) |prov_val| {
            const prov_obj = prov_val.object;
            if (prov_obj.get("name")) |n| {
                config.provider.name = try dupeAndTrack(&config, n.string);
            }
            if (prov_obj.get("model")) |m| {
                config.provider.model = try dupeAndTrack(&config, m.string);
            }
            if (prov_obj.get("max_tokens")) |t| {
                config.provider.max_tokens = @intCast(t.integer);
            }
            if (prov_obj.get("max_turns")) |t| {
                config.provider.max_turns = @intCast(t.integer);
            }
            if (prov_obj.get("temperature")) |t| {
                config.provider.temperature = @floatCast(t.float);
            }
        }

        // Parse tools
        if (root.get("tools")) |tools_val| {
            const tools_obj = tools_val.object;
            if (tools_obj.get("enabled")) |e| {
                config.tools.enabled = try parseStringArray(&config, e.array.items);
            }
            if (tools_obj.get("disabled")) |d| {
                config.tools.disabled = try parseStringArray(&config, d.array.items);
            }

            if (tools_obj.get("execute_command")) |exec_val| {
                const exec_obj = exec_val.object;
                if (exec_obj.get("allowed_commands")) |ac| {
                    config.tools.execute_command.allowed_commands = try parseStringArray(&config, ac.array.items);
                }
                if (exec_obj.get("banned_patterns")) |bp| {
                    config.tools.execute_command.banned_patterns = try parseStringArray(&config, bp.array.items);
                }
                if (exec_obj.get("timeout_ms")) |t| {
                    config.tools.execute_command.timeout_ms = @intCast(t.integer);
                }
                if (exec_obj.get("max_output_bytes")) |m| {
                    config.tools.execute_command.max_output_bytes = @intCast(m.integer);
                }
                if (exec_obj.get("kill_process_group")) |k| {
                    config.tools.execute_command.kill_process_group = k.bool;
                }
            }

            // Parse confirmation rules (legacy)
            if (tools_obj.get("require_confirmation")) |rules_val| {
                config.tools.require_confirmation = try parseConfirmationRules(&config, rules_val.array.items);
            }

            // Parse permission tiers
            if (tools_obj.get("permissions")) |perms_val| {
                const perms_obj = perms_val.object;
                if (perms_obj.get("auto")) |a| {
                    config.tools.permissions.auto = try parseStringArray(&config, a.array.items);
                }
                if (perms_obj.get("confirm")) |c| {
                    config.tools.permissions.confirm = try parseStringArray(&config, c.array.items);
                }
                if (perms_obj.get("blocked_commands")) |b| {
                    config.tools.permissions.blocked_commands = try parseStringArray(&config, b.array.items);
                }
            }

            // Parse external command tiers
            if (tools_obj.get("external_commands")) |ext_val| {
                const ext_obj = ext_val.object;
                if (ext_obj.get("auto")) |a| {
                    config.tools.external_commands.auto = try parseStringArray(&config, a.array.items);
                }
                if (ext_obj.get("confirm")) |c| {
                    config.tools.external_commands.confirm = try parseStringArray(&config, c.array.items);
                }
                if (ext_obj.get("blocked")) |b| {
                    config.tools.external_commands.blocked = try parseStringArray(&config, b.array.items);
                }
            }

            // Parse external rules (per-command subcommand tiers)
            if (tools_obj.get("external_rules")) |rules_val| {
                config.tools.external_rules = try parseExternalRules(&config, rules_val.object);
            }
        }

        // Parse orchestrator config
        if (root.get("orchestrator")) |orch_val| {
            const orch_obj = orch_val.object;
            var orch = OrchestratorConfig{};

            if (orch_obj.get("architect_provider")) |v| {
                orch.architect_provider = try dupeAndTrack(&config, v.string);
            }
            if (orch_obj.get("architect_model")) |v| {
                orch.architect_model = try dupeAndTrack(&config, v.string);
            }
            if (orch_obj.get("architect_max_turns")) |v| {
                orch.architect_max_turns = @intCast(v.integer);
            }
            if (orch_obj.get("worker_provider")) |v| {
                orch.worker_provider = try dupeAndTrack(&config, v.string);
            }
            if (orch_obj.get("worker_model")) |v| {
                orch.worker_model = try dupeAndTrack(&config, v.string);
            }
            if (orch_obj.get("worker_max_turns")) |v| {
                orch.worker_max_turns = @intCast(v.integer);
            }
            if (orch_obj.get("save_plan")) |v| {
                orch.save_plan = v.bool;
            }
            if (orch_obj.get("plan_path")) |v| {
                orch.plan_path = try dupeAndTrack(&config, v.string);
            }
            if (orch_obj.get("audit_log")) |v| {
                orch.audit_log = v.bool;
            }
            if (orch_obj.get("audit_path")) |v| {
                orch.audit_path = try dupeAndTrack(&config, v.string);
            }
            if (orch_obj.get("max_tasks")) |v| {
                orch.max_tasks = @intCast(v.integer);
            }
            if (orch_obj.get("max_cost_usd")) |v| {
                orch.max_cost_usd = if (v == .float) @floatCast(v.float) else @floatFromInt(v.integer);
            }

            config.orchestrator = orch;
        }

        // Parse limits
        if (root.get("limits")) |limits_val| {
            const limits_obj = limits_val.object;
            if (limits_obj.get("max_file_size_bytes")) |m| {
                config.limits.max_file_size_bytes = @intCast(m.integer);
            }
            if (limits_obj.get("max_files_per_operation")) |m| {
                config.limits.max_files_per_operation = @intCast(m.integer);
            }
            if (limits_obj.get("max_directory_depth")) |m| {
                config.limits.max_directory_depth = @intCast(m.integer);
            }
            if (limits_obj.get("max_total_output_bytes")) |m| {
                config.limits.max_total_output_bytes = @intCast(m.integer);
            }
        }

        return config;
    }

    /// Check if a tool is enabled
    pub fn isToolEnabled(self: *const AgentConfig, tool_name: []const u8) bool {
        // Check disabled list first
        for (self.tools.disabled) |disabled| {
            if (std.mem.eql(u8, disabled, tool_name)) {
                return false;
            }
        }

        // Check enabled list
        for (self.tools.enabled) |enabled| {
            if (std.mem.eql(u8, enabled, tool_name)) {
                return true;
            }
        }

        return false;
    }
};

// Helper to duplicate string and track for cleanup
fn dupeAndTrack(config: *AgentConfig, s: []const u8) ![]const u8 {
    const duped = try config.allocator.dupe(u8, s);
    try config._allocated_strings.append(config.allocator, duped);
    return duped;
}

// Helper to parse array of strings
fn parseStringArray(config: *AgentConfig, items: []const std.json.Value) ![]const []const u8 {
    var result = try config.allocator.alloc([]const u8, items.len);
    errdefer config.allocator.free(result);

    for (items, 0..) |item, i| {
        result[i] = try dupeAndTrack(config, item.string);
    }

    // Track the array itself for cleanup
    try config._allocated_arrays.append(config.allocator, result);
    return result;
}

// Helper to parse confirmation rules array
fn parseConfirmationRules(config: *AgentConfig, items: []const std.json.Value) ![]const ConfirmationRule {
    var result = try config.allocator.alloc(ConfirmationRule, items.len);
    errdefer config.allocator.free(result);

    for (items, 0..) |item, i| {
        const obj = item.object;

        // Tool name is required
        const tool = if (obj.get("tool")) |t| try dupeAndTrack(config, t.string) else continue;

        // Pattern is optional
        const pattern = if (obj.get("pattern")) |p| try dupeAndTrack(config, p.string) else null;

        // Risk level is optional with default
        const risk_level = if (obj.get("risk_level")) |r|
            ConfirmationRule.RiskLevel.fromString(r.string)
        else
            .medium;

        result[i] = .{
            .tool = tool,
            .pattern = pattern,
            .risk_level = risk_level,
        };
    }

    // Track the array itself for cleanup
    try config._allocated_rule_arrays.append(config.allocator, result);
    return result;
}

// Helper to parse external rules (per-command subcommand tiers)
fn parseExternalRules(config: *AgentConfig, obj: std.json.ObjectMap) ![]const ExternalRule {
    var result = try config.allocator.alloc(ExternalRule, obj.count());
    errdefer config.allocator.free(result);

    var i: usize = 0;
    var it = obj.iterator();
    while (it.next()) |entry| {
        const command = try dupeAndTrack(config, entry.key_ptr.*);
        const rule_obj = entry.value_ptr.*.object;

        result[i] = .{
            .command = command,
            .auto_subcommands = if (rule_obj.get("auto_subcommands")) |a|
                try parseStringArray(config, a.array.items)
            else
                &.{},
            .confirm_subcommands = if (rule_obj.get("confirm_subcommands")) |c|
                try parseStringArray(config, c.array.items)
            else
                &.{},
            .blocked_subcommands = if (rule_obj.get("blocked_subcommands")) |b|
                try parseStringArray(config, b.array.items)
            else
                &.{},
        };
        i += 1;
    }

    try config._allocated_ext_rule_arrays.append(config.allocator, result);
    return result;
}

/// Get config directories
pub fn getConfigDirs(allocator: std.mem.Allocator) ![]const []const u8 {
    var dirs: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer dirs.deinit(allocator);

    // User config
    const home = std.mem.span(std.c.getenv("HOME") orelse "/tmp");
    const user_dir = try std.fmt.allocPrint(allocator, "{s}/.config/zig_ai/agents/", .{home});
    try dirs.append(allocator, user_dir);

    // Project config
    const project_dir = try allocator.dupe(u8, "./config/agents/");
    try dirs.append(allocator, project_dir);

    return dirs.toOwnedSlice(allocator);
}
