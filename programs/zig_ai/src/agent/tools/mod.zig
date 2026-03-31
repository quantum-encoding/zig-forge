// Copyright (c) 2025 QUANTUM ENCODING LTD
// Licensed under the MIT License.

//! Agent Tools Module
//! Provides tool registry, permission tier resolution, and execution dispatch

const std = @import("std");
pub const types = @import("types.zig");
pub const read_file = @import("read_file.zig");
pub const write_file = @import("write_file.zig");
pub const list_files = @import("list_files.zig");
pub const search_files = @import("search_files.zig");
pub const execute_command = @import("execute_command.zig");
pub const confirm_action = @import("confirm_action.zig");
pub const trash_file = @import("trash_file.zig");
pub const grep = @import("grep.zig");
pub const cat = @import("cat.zig");
pub const wc = @import("wc.zig");
pub const find = @import("find.zig");
pub const rm = @import("rm.zig");
pub const cp = @import("cp.zig");
pub const mv = @import("mv.zig");
pub const mkdir_tool = @import("mkdir_tool.zig");
pub const touch = @import("touch.zig");
pub const kill_process = @import("kill_process.zig");
pub const process_table = @import("process_table.zig");
pub const plan_tasks = @import("plan_tasks.zig");

const security = @import("../security/mod.zig");
const config = @import("../config.zig");

/// Simple glob pattern matching
/// Supports * as wildcard matching any characters
fn matchesPattern(text: []const u8, pattern: []const u8) bool {
    var t_idx: usize = 0;
    var p_idx: usize = 0;
    var star_idx: ?usize = null;
    var match_idx: usize = 0;

    while (t_idx < text.len) {
        if (p_idx < pattern.len and (pattern[p_idx] == text[t_idx] or pattern[p_idx] == '?')) {
            t_idx += 1;
            p_idx += 1;
        } else if (p_idx < pattern.len and pattern[p_idx] == '*') {
            star_idx = p_idx;
            match_idx = t_idx;
            p_idx += 1;
        } else if (star_idx != null) {
            p_idx = star_idx.? + 1;
            match_idx += 1;
            t_idx = match_idx;
        } else {
            return false;
        }
    }

    while (p_idx < pattern.len and pattern[p_idx] == '*') {
        p_idx += 1;
    }

    return p_idx == pattern.len;
}

// Re-exports
pub const ToolDefinition = types.ToolDefinition;
pub const ToolOutput = types.ToolOutput;
pub const ToolError = types.ToolError;
pub const all_tools = types.all_tools;
pub const getToolDef = types.getToolDef;
pub const formatToolsForClaude = types.formatToolsForClaude;
pub const formatToolsForOpenAI = types.formatToolsForOpenAI;

/// Tool registry for dispatching tool calls
/// Implements permission tier resolution and confirmation prompts
pub const ToolRegistry = struct {
    allocator: std.mem.Allocator,
    enabled_tools: []const []const u8,
    limits: config.LimitsConfig,
    exec_config: config.ExecuteCommandConfig,
    permissions: config.PermissionsConfig,
    external_commands: config.ExternalCommandsConfig,
    external_rules: []const config.ExternalRule,
    // Legacy confirmation rules (kept for backward compat)
    confirmation_rules: []const config.ConfirmationRule,
    proc_table: process_table.ProcessTable,

    pub fn init(
        allocator: std.mem.Allocator,
        agent_config: *const config.AgentConfig,
    ) ToolRegistry {
        return .{
            .allocator = allocator,
            .enabled_tools = agent_config.tools.enabled,
            .limits = agent_config.limits,
            .exec_config = agent_config.tools.execute_command,
            .permissions = agent_config.tools.permissions,
            .external_commands = agent_config.tools.external_commands,
            .external_rules = agent_config.tools.external_rules,
            .confirmation_rules = agent_config.tools.require_confirmation,
            .proc_table = process_table.ProcessTable.init(allocator),
        };
    }

    pub fn deinit(self: *ToolRegistry) void {
        self.proc_table.deinit();
    }

    /// Check if a tool is enabled
    pub fn isToolEnabled(self: *const ToolRegistry, tool_name: []const u8) bool {
        for (self.enabled_tools) |enabled| {
            if (std.mem.eql(u8, enabled, tool_name)) {
                return true;
            }
        }
        return false;
    }

    // ─── Permission Tier Resolution ──────────────────────────────────

    /// Resolve permission tier for a native tool
    fn resolveNativeToolTier(self: *const ToolRegistry, tool_name: []const u8) config.PermissionTier {
        // Check auto list
        for (self.permissions.auto) |name| {
            if (std.mem.eql(u8, name, tool_name)) return .auto;
        }
        // Check confirm list
        for (self.permissions.confirm) |name| {
            if (std.mem.eql(u8, name, tool_name)) return .confirm;
        }
        // Default: confirm (safe default for unknown tools)
        return .confirm;
    }

    /// Resolve permission tier for execute_command based on the command string
    fn resolveExternalCommandTier(self: *const ToolRegistry, command: []const u8) config.PermissionTier {
        // Extract base command (first word)
        const base_cmd = extractBaseCommand(command);

        // Check blocked commands first
        for (self.permissions.blocked_commands) |blocked| {
            if (std.mem.eql(u8, base_cmd, blocked)) return .blocked;
        }

        // Check external rules (per-command subcommand tiers)
        for (self.external_rules) |rule| {
            if (std.mem.eql(u8, base_cmd, rule.command)) {
                const subcommand = extractSubcommand(command, base_cmd.len);
                if (subcommand) |sub| {
                    // Check blocked subcommands
                    for (rule.blocked_subcommands) |blocked| {
                        if (std.mem.eql(u8, sub, blocked)) return .blocked;
                    }
                    // Check auto subcommands
                    for (rule.auto_subcommands) |auto| {
                        if (std.mem.eql(u8, sub, auto)) return .auto;
                    }
                    // Check confirm subcommands
                    for (rule.confirm_subcommands) |conf| {
                        if (std.mem.eql(u8, sub, conf)) return .confirm;
                    }
                }
                // Command matches a rule but subcommand isn't listed — confirm
                return .confirm;
            }
        }

        // Check blocked external commands
        for (self.external_commands.blocked) |blocked| {
            if (std.mem.eql(u8, base_cmd, blocked)) return .blocked;
        }

        // Check askpass patterns (sudo, chown, chgrp)
        if (std.mem.eql(u8, base_cmd, "sudo") or
            std.mem.eql(u8, base_cmd, "chown") or
            std.mem.eql(u8, base_cmd, "chgrp"))
        {
            return .askpass;
        }

        // Check auto external commands
        for (self.external_commands.auto) |auto| {
            if (std.mem.eql(u8, base_cmd, auto)) return .auto;
        }

        // Check confirm external commands
        for (self.external_commands.confirm) |conf| {
            if (std.mem.eql(u8, base_cmd, conf)) return .confirm;
        }

        // Default for unknown external commands: confirm
        return .confirm;
    }

    /// Top-level tier resolution
    fn resolvePermissionTier(self: *const ToolRegistry, tool_name: []const u8, args_json: []const u8) config.PermissionTier {
        if (std.mem.eql(u8, tool_name, "execute_command")) {
            // Parse command from args to determine tier
            const command = extractCommandFromJson(args_json) orelse return .confirm;
            return self.resolveExternalCommandTier(command);
        }

        // confirm_action is always auto (it IS the confirmation mechanism)
        if (std.mem.eql(u8, tool_name, "confirm_action")) return .auto;

        // kill_process is auto — safety check is internal (only tracked PIDs)
        if (std.mem.eql(u8, tool_name, "kill_process")) return .auto;

        return self.resolveNativeToolTier(tool_name);
    }

    /// Extract AI's reason field from tool args JSON
    fn extractReason(args_json: []const u8) ?[]const u8 {
        // Quick substring search for "reason" field
        const needle = "\"reason\"";
        const idx = std.mem.indexOf(u8, args_json, needle) orelse return null;
        const after_key = args_json[idx + needle.len ..];

        // Skip whitespace and colon
        var i: usize = 0;
        while (i < after_key.len and (after_key[i] == ' ' or after_key[i] == ':' or after_key[i] == '\t')) : (i += 1) {}

        if (i >= after_key.len or after_key[i] != '"') return null;
        i += 1; // skip opening quote

        const start = i;
        while (i < after_key.len and after_key[i] != '"') : (i += 1) {
            if (after_key[i] == '\\') i += 1; // skip escaped chars
        }

        if (i > start) return after_key[start..i];
        return null;
    }

    // ─── Confirmation UI ─────────────────────────────────────────────

    /// Standard confirmation prompt for CONFIRM tier (y/N)
    fn promptForConfirm(tool_name: []const u8, args_json: []const u8) bool {
        const reset = "\x1b[0m";
        const bold = "\x1b[1m";
        const yellow = "\x1b[33m";

        var buf: [2048]u8 = undefined;
        var len: usize = 0;

        // Header
        const h = std.fmt.bufPrint(buf[len..], "\n{s}{s}=== CONFIRM ==={s}\n", .{ yellow, bold, reset }) catch return false;
        len += h.len;

        // Tool
        const t = std.fmt.bufPrint(buf[len..], "{s}Tool:{s} {s}\n", .{ bold, reset, tool_name }) catch return false;
        len += t.len;

        // Truncated args
        const display_args = if (args_json.len > 200) args_json[0..200] else args_json;
        const a = std.fmt.bufPrint(buf[len..], "{s}Args:{s} {s}\n", .{ bold, reset, display_args }) catch return false;
        len += a.len;

        // Reason if present
        if (extractReason(args_json)) |reason| {
            const r = std.fmt.bufPrint(buf[len..], "{s}Reason:{s} {s}\n", .{ bold, reset, reason }) catch return false;
            len += r.len;
        }

        // Prompt
        const p = std.fmt.bufPrint(buf[len..], "\n{s}Allow? [y/N]: {s}", .{ yellow, reset }) catch return false;
        len += p.len;

        _ = std.c.write(2, &buf, len);

        // Read response
        var input_buf: [256]u8 = undefined;
        const bytes_read = std.c.read(0, &input_buf, input_buf.len);
        if (bytes_read <= 0) return false;

        const input = std.mem.trim(u8, input_buf[0..@intCast(bytes_read)], &[_]u8{ ' ', '\t', '\n', '\r' });
        const approved = input.len > 0 and (input[0] == 'y' or input[0] == 'Y');

        if (approved) {
            const msg = "\x1b[32mApproved\x1b[0m\n\n";
            _ = std.c.write(2, msg.ptr, msg.len);
        } else {
            const msg = "\x1b[31mDenied\x1b[0m\n\n";
            _ = std.c.write(2, msg.ptr, msg.len);
        }

        return approved;
    }

    /// Elevated confirmation prompt for ASKPASS tier (requires "yes")
    fn promptForAskpass(tool_name: []const u8, args_json: []const u8) bool {
        const reset = "\x1b[0m";
        const bold = "\x1b[1m";
        const red = "\x1b[31;1m";

        var buf: [2048]u8 = undefined;
        var len: usize = 0;

        // Header
        const h = std.fmt.bufPrint(buf[len..], "\n{s}{s}=== ELEVATED PERMISSION REQUIRED ==={s}\n", .{ red, bold, reset }) catch return false;
        len += h.len;

        // Tool
        const t = std.fmt.bufPrint(buf[len..], "{s}Tool:{s} {s}\n", .{ bold, reset, tool_name }) catch return false;
        len += t.len;

        // Full args (no truncation for askpass - user needs to see everything)
        const display_args = if (args_json.len > 500) args_json[0..500] else args_json;
        const a = std.fmt.bufPrint(buf[len..], "{s}Full command:{s} {s}\n", .{ bold, reset, display_args }) catch return false;
        len += a.len;

        // Warning
        const w = std.fmt.bufPrint(buf[len..], "\n{s}This operation requires elevated privileges.{s}\n", .{ red, reset }) catch return false;
        len += w.len;

        // Prompt
        const p = std.fmt.bufPrint(buf[len..], "{s}Type \"yes\" to proceed: {s}", .{ red, reset }) catch return false;
        len += p.len;

        _ = std.c.write(2, &buf, len);

        // Read response
        var input_buf: [256]u8 = undefined;
        const bytes_read = std.c.read(0, &input_buf, input_buf.len);
        if (bytes_read <= 0) return false;

        const input = std.mem.trim(u8, input_buf[0..@intCast(bytes_read)], &[_]u8{ ' ', '\t', '\n', '\r' });
        const approved = std.mem.eql(u8, input, "yes");

        if (approved) {
            const msg = "\x1b[32mApproved\x1b[0m\n\n";
            _ = std.c.write(2, msg.ptr, msg.len);
        } else {
            const msg = "\x1b[31mDenied (must type \"yes\")\x1b[0m\n\n";
            _ = std.c.write(2, msg.ptr, msg.len);
        }

        return approved;
    }

    // ─── Tool Execution ──────────────────────────────────────────────

    /// Execute a tool by name with JSON arguments
    /// Resolves permission tier and prompts as needed
    pub fn executeTool(self: *ToolRegistry, sandbox: *security.Sandbox, tool_name: []const u8, args_json: []const u8) !ToolOutput {
        if (!self.isToolEnabled(tool_name)) {
            return ToolOutput.error_result(self.allocator, "Tool not enabled");
        }

        // Resolve permission tier
        const tier = self.resolvePermissionTier(tool_name, args_json);

        switch (tier) {
            .blocked => {
                return ToolOutput.error_result(self.allocator, "Operation not permitted by security policy");
            },
            .askpass => {
                if (!promptForAskpass(tool_name, args_json)) {
                    return ToolOutput.error_result(self.allocator, "Operation denied by user");
                }
            },
            .confirm => {
                if (!promptForConfirm(tool_name, args_json)) {
                    return ToolOutput.error_result(self.allocator, "Operation denied by user");
                }
            },
            .auto => {},
        }

        // Dispatch to tool implementation
        return self.dispatchTool(sandbox, tool_name, args_json);
    }

    /// Dispatch to the appropriate tool implementation
    fn dispatchTool(self: *ToolRegistry, sandbox: *security.Sandbox, tool_name: []const u8, args_json: []const u8) !ToolOutput {
        if (std.mem.eql(u8, tool_name, "read_file")) {
            const args = read_file.parseArgs(self.allocator, args_json) catch {
                return ToolOutput.error_result(self.allocator, "Invalid arguments for read_file");
            };
            defer self.allocator.free(args.path);
            return read_file.execute(self.allocator, sandbox, args, self.limits.max_file_size_bytes);
        }

        if (std.mem.eql(u8, tool_name, "write_file")) {
            const args = write_file.parseArgs(self.allocator, args_json) catch {
                return ToolOutput.error_result(self.allocator, "Invalid arguments for write_file");
            };
            defer {
                self.allocator.free(args.path);
                self.allocator.free(args.content);
            }
            return write_file.execute(self.allocator, sandbox, args, self.limits.max_file_size_bytes);
        }

        if (std.mem.eql(u8, tool_name, "list_files")) {
            const args = list_files.parseArgs(self.allocator, args_json) catch {
                return ToolOutput.error_result(self.allocator, "Invalid arguments for list_files");
            };
            defer self.allocator.free(args.path);
            return list_files.execute(self.allocator, sandbox, args, self.limits.max_files_per_operation);
        }

        if (std.mem.eql(u8, tool_name, "search_files")) {
            const args = search_files.parseArgs(self.allocator, args_json) catch {
                return ToolOutput.error_result(self.allocator, "Invalid arguments for search_files");
            };
            defer {
                self.allocator.free(args.pattern);
                self.allocator.free(args.path);
                self.allocator.free(args.file_pattern);
            }
            return search_files.execute(self.allocator, sandbox, args);
        }

        if (std.mem.eql(u8, tool_name, "execute_command")) {
            const args = execute_command.parseArgs(self.allocator, args_json) catch {
                return ToolOutput.error_result(self.allocator, "Invalid arguments for execute_command");
            };
            defer {
                self.allocator.free(args.command);
                self.allocator.free(args.working_dir);
            }
            return execute_command.execute(self.allocator, sandbox, args, self.exec_config, &self.proc_table);
        }

        if (std.mem.eql(u8, tool_name, "confirm_action")) {
            const args = confirm_action.parseArgs(self.allocator, args_json) catch {
                return ToolOutput.error_result(self.allocator, "Invalid arguments for confirm_action");
            };
            defer confirm_action.freeArgs(self.allocator, args);
            return confirm_action.execute(self.allocator, args);
        }

        if (std.mem.eql(u8, tool_name, "trash_file")) {
            const args = trash_file.parseArgs(self.allocator, args_json) catch {
                return ToolOutput.error_result(self.allocator, "Invalid arguments for trash_file");
            };
            defer self.allocator.free(args.path);
            return trash_file.execute(self.allocator, sandbox, args, self.limits.max_file_size_bytes);
        }

        if (std.mem.eql(u8, tool_name, "grep")) {
            const args = grep.parseArgs(self.allocator, args_json) catch {
                return ToolOutput.error_result(self.allocator, "Invalid arguments for grep");
            };
            defer grep.freeArgs(self.allocator, args);
            return grep.execute(self.allocator, sandbox, args);
        }

        if (std.mem.eql(u8, tool_name, "cat")) {
            const args = cat.parseArgs(self.allocator, args_json) catch {
                return ToolOutput.error_result(self.allocator, "Invalid arguments for cat");
            };
            defer cat.freeArgs(self.allocator, args);
            return cat.execute(self.allocator, sandbox, args, self.limits.max_file_size_bytes);
        }

        if (std.mem.eql(u8, tool_name, "wc")) {
            const args = wc.parseArgs(self.allocator, args_json) catch {
                return ToolOutput.error_result(self.allocator, "Invalid arguments for wc");
            };
            defer wc.freeArgs(self.allocator, args);
            return wc.execute(self.allocator, sandbox, args, self.limits.max_file_size_bytes);
        }

        if (std.mem.eql(u8, tool_name, "find")) {
            const args = find.parseArgs(self.allocator, args_json) catch {
                return ToolOutput.error_result(self.allocator, "Invalid arguments for find");
            };
            defer find.freeArgs(self.allocator, args);
            return find.execute(self.allocator, sandbox, args);
        }

        if (std.mem.eql(u8, tool_name, "rm")) {
            const args = rm.parseArgs(self.allocator, args_json) catch {
                return ToolOutput.error_result(self.allocator, "Invalid arguments for rm");
            };
            defer rm.freeArgs(self.allocator, args);
            return rm.execute(self.allocator, sandbox, args);
        }

        if (std.mem.eql(u8, tool_name, "cp")) {
            const args = cp.parseArgs(self.allocator, args_json) catch {
                return ToolOutput.error_result(self.allocator, "Invalid arguments for cp");
            };
            defer cp.freeArgs(self.allocator, args);
            return cp.execute(self.allocator, sandbox, args);
        }

        if (std.mem.eql(u8, tool_name, "mv")) {
            const args = mv.parseArgs(self.allocator, args_json) catch {
                return ToolOutput.error_result(self.allocator, "Invalid arguments for mv");
            };
            defer mv.freeArgs(self.allocator, args);
            return mv.execute(self.allocator, sandbox, args);
        }

        if (std.mem.eql(u8, tool_name, "mkdir")) {
            const args = mkdir_tool.parseArgs(self.allocator, args_json) catch {
                return ToolOutput.error_result(self.allocator, "Invalid arguments for mkdir");
            };
            defer mkdir_tool.freeArgs(self.allocator, args);
            return mkdir_tool.execute(self.allocator, sandbox, args);
        }

        if (std.mem.eql(u8, tool_name, "touch")) {
            const args = touch.parseArgs(self.allocator, args_json) catch {
                return ToolOutput.error_result(self.allocator, "Invalid arguments for touch");
            };
            defer touch.freeArgs(self.allocator, args);
            return touch.execute(self.allocator, sandbox, args);
        }

        if (std.mem.eql(u8, tool_name, "kill_process")) {
            const args = kill_process.parseArgs(self.allocator, args_json) catch {
                return ToolOutput.error_result(self.allocator, "Invalid arguments for kill_process");
            };
            defer kill_process.freeArgs(self.allocator, args);
            return kill_process.execute(self.allocator, &self.proc_table, args);
        }

        if (std.mem.eql(u8, tool_name, "plan_tasks")) {
            const args = plan_tasks.parseArgs(self.allocator, args_json) catch {
                return ToolOutput.error_result(self.allocator, "Invalid arguments for plan_tasks");
            };
            defer plan_tasks.freeArgs(self.allocator, args);
            return plan_tasks.execute(self.allocator, args);
        }

        return ToolOutput.error_result(self.allocator, "Unknown tool");
    }

    /// Get tool definitions JSON for AI provider
    pub fn getToolDefinitionsJson(self: *const ToolRegistry, format: ToolFormat) ![]const u8 {
        return switch (format) {
            .claude => formatToolsForClaude(self.allocator, self.enabled_tools),
            .openai => formatToolsForOpenAI(self.allocator, self.enabled_tools),
        };
    }

    pub const ToolFormat = enum {
        claude,
        openai,
    };
};

// ─── Helpers ─────────────────────────────────────────────────────────

/// Skip leading whitespace
fn skipWhitespace(s: []const u8) []const u8 {
    var i: usize = 0;
    while (i < s.len and (s[i] == ' ' or s[i] == '\t')) : (i += 1) {}
    return s[i..];
}

/// Extract base command (first word) from a command string
fn extractBaseCommand(command: []const u8) []const u8 {
    const trimmed = skipWhitespace(command);
    for (trimmed, 0..) |c, i| {
        if (c == ' ' or c == '\t') return trimmed[0..i];
    }
    return trimmed;
}

/// Extract subcommand (second word) from a command string
fn extractSubcommand(command: []const u8, base_len: usize) ?[]const u8 {
    if (base_len >= command.len) return null;
    const rest = skipWhitespace(command[base_len..]);
    if (rest.len == 0) return null;
    for (rest, 0..) |c, i| {
        if (c == ' ' or c == '\t') return rest[0..i];
    }
    return rest;
}

/// Extract "command" field value from JSON args string
fn extractCommandFromJson(args_json: []const u8) ?[]const u8 {
    const needle = "\"command\"";
    const idx = std.mem.indexOf(u8, args_json, needle) orelse return null;
    const after_key = args_json[idx + needle.len ..];

    // Skip whitespace and colon
    var i: usize = 0;
    while (i < after_key.len and (after_key[i] == ' ' or after_key[i] == ':' or after_key[i] == '\t')) : (i += 1) {}

    if (i >= after_key.len or after_key[i] != '"') return null;
    i += 1; // skip opening quote

    const start = i;
    while (i < after_key.len and after_key[i] != '"') : (i += 1) {
        if (after_key[i] == '\\') i += 1; // skip escaped chars
    }

    if (i > start) return after_key[start..i];
    return null;
}

// Tests
test "tool registry" {
    _ = ToolRegistry;
}

test "extractBaseCommand" {
    try std.testing.expectEqualStrings("git", extractBaseCommand("git status"));
    try std.testing.expectEqualStrings("npm", extractBaseCommand("npm install foo"));
    try std.testing.expectEqualStrings("ls", extractBaseCommand("ls"));
    try std.testing.expectEqualStrings("sudo", extractBaseCommand("sudo rm -rf /"));
}

test "extractSubcommand" {
    try std.testing.expectEqualStrings("status", extractSubcommand("git status", 3).?);
    try std.testing.expectEqualStrings("install", extractSubcommand("npm install foo", 3).?);
    try std.testing.expect(extractSubcommand("ls", 2) == null);
}

test "extractCommandFromJson" {
    const json1 = "{\"command\": \"git status\", \"working_dir\": \".\"}";
    try std.testing.expectEqualStrings("git status", extractCommandFromJson(json1).?);

    const json2 = "{\"command\":\"npm install\"}";
    try std.testing.expectEqualStrings("npm install", extractCommandFromJson(json2).?);
}
