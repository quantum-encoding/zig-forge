//! Unified config parser for the Cognitive Telemetry Kit.
//!
//! Reads /etc/warden/ctk.conf (or a custom path) and produces a Rule array
//! consumed by the PolicyEngine.
//!
//! Format: key = value, one per line. # for comments.
//!
//!   protected = /etc/
//!   whitelist = /tmp/
//!   trusted = /usr/bin/git
//!   allow_command = cat
//!   deny_command = sudo
//!   prompt_command = rm
//!   network_allow = github.com
//!   observe = claude
//!   max_hourly_usd = 50.00

const std = @import("std");
const policy = @import("policy.zig");
const Rule = policy.Rule;

pub const DEFAULT_CONFIG_PATH = "/etc/warden/ctk.conf";

pub const Config = struct {
    rules: std.ArrayListUnmanaged(Rule),
    observed_processes: std.ArrayListUnmanaged([]const u8),
    max_hourly_usd: ?f64,

    pub fn deinit(self: *Config, allocator: std.mem.Allocator) void {
        // Rules point into the config buffer, so just free the lists
        self.rules.deinit(allocator);
        self.observed_processes.deinit(allocator);
    }
};

/// Load config from a file. Returns default config if file doesn't exist.
pub fn load(allocator: std.mem.Allocator, path: []const u8) Config {
    var config = Config{
        .rules = .empty,
        .max_hourly_usd = null,
        .observed_processes = .empty,
    };

    // Read config file using C APIs (platform-agnostic, no std.Io needed)
    const path_z = allocator.dupeZ(u8, path) catch {
        loadDefaults(allocator, &config);
        return config;
    };
    defer allocator.free(path_z);

    const c = @import("std").c;
    const fd = c.open(path_z, .{});
    if (fd < 0) {
        loadDefaults(allocator, &config);
        return config;
    }
    defer _ = c.close(fd);

    var buf: [16384]u8 = undefined;
    const n = c.read(fd, &buf, buf.len);
    if (n <= 0) {
        loadDefaults(allocator, &config);
        return config;
    }
    const content = buf[0..@intCast(n)];

    // Parse lines
    var line_start: usize = 0;
    for (content, 0..) |ch, i| {
        if (ch == '\n' or i == content.len - 1) {
            const end = if (ch == '\n') i else i + 1;
            if (end > line_start) {
                if (parseLine(content[line_start..end])) |rule| {
                    config.rules.append(allocator, rule) catch continue;
                }
            }
            line_start = i + 1;
        }
    }

    // Fall back to defaults if no rules loaded
    if (config.rules.items.len == 0) {
        loadDefaults(allocator, &config);
    }
    return config;
}

/// Load default rules (used when no config file exists).
pub fn loadDefaults(allocator: std.mem.Allocator, config: *Config) void {
    const defaults = [_]Rule{
        // Protected paths
        .{ .kind = .protected_path, .pattern = "/etc/", .decision = .deny },
        .{ .kind = .protected_path, .pattern = "/System/", .decision = .deny },
        .{ .kind = .protected_path, .pattern = "/Library/", .decision = .deny },
        .{ .kind = .protected_path, .pattern = "/usr/", .decision = .deny },
        .{ .kind = .protected_path, .pattern = "/bin/", .decision = .deny },
        .{ .kind = .protected_path, .pattern = "/sbin/", .decision = .deny },

        // Whitelisted paths
        .{ .kind = .whitelisted_path, .pattern = "/usr/local/", .decision = .allow },
        .{ .kind = .whitelisted_path, .pattern = "/tmp/", .decision = .allow },
        .{ .kind = .whitelisted_path, .pattern = "/private/tmp/", .decision = .allow },
        .{ .kind = .whitelisted_path, .pattern = "/var/folders/", .decision = .allow },
        .{ .kind = .whitelisted_path, .pattern = "/private/var/folders/", .decision = .allow },

        // Trusted processes
        .{ .kind = .trusted_process, .pattern = "/usr/bin/git", .decision = .allow },
        .{ .kind = .trusted_process, .pattern = "/usr/local/bin/git", .decision = .allow },
        .{ .kind = .trusted_process, .pattern = "/opt/homebrew/bin/git", .decision = .allow },
        .{ .kind = .trusted_process, .pattern = "/usr/local/bin/trash", .decision = .allow },

        // Denied commands (dangerous)
        .{ .kind = .denied_command, .pattern = "sudo", .decision = .deny, .reason = "privilege escalation" },
        .{ .kind = .denied_command, .pattern = "su", .decision = .deny, .reason = "privilege escalation" },
        .{ .kind = .denied_command, .pattern = "dd", .decision = .deny, .reason = "raw disk access" },
        .{ .kind = .denied_command, .pattern = "mkfs", .decision = .deny, .reason = "filesystem creation" },

        // Allowed commands (safe read-only)
        .{ .kind = .allowed_command, .pattern = "cat", .decision = .allow },
        .{ .kind = .allowed_command, .pattern = "ls", .decision = .allow },
        .{ .kind = .allowed_command, .pattern = "grep", .decision = .allow },
        .{ .kind = .allowed_command, .pattern = "rg", .decision = .allow },
        .{ .kind = .allowed_command, .pattern = "find", .decision = .allow },
        .{ .kind = .allowed_command, .pattern = "head", .decision = .allow },
        .{ .kind = .allowed_command, .pattern = "tail", .decision = .allow },
        .{ .kind = .allowed_command, .pattern = "wc", .decision = .allow },

        // Prompt commands (potentially destructive)
        .{ .kind = .prompt_command, .pattern = "rm", .decision = .prompt, .reason = "file deletion" },
        .{ .kind = .prompt_command, .pattern = "mv", .decision = .prompt, .reason = "file move" },
        .{ .kind = .prompt_command, .pattern = "chmod", .decision = .prompt, .reason = "permission change" },
        .{ .kind = .prompt_command, .pattern = "chown", .decision = .prompt, .reason = "ownership change" },
    };

    for (defaults) |rule| {
        config.rules.append(allocator, rule) catch continue;
    }
}

/// Parse a single config line into a Rule.
pub fn parseLine(line: []const u8) ?Rule {
    const trimmed = std.mem.trim(u8, line, " \t\r\n");
    if (trimmed.len == 0 or trimmed[0] == '#') return null;

    const eq = std.mem.indexOf(u8, trimmed, "=") orelse return null;
    const key = std.mem.trim(u8, trimmed[0..eq], " \t");
    const value = std.mem.trim(u8, trimmed[eq + 1 ..], " \t");
    if (value.len == 0) return null;

    if (std.mem.eql(u8, key, "protected")) return .{ .kind = .protected_path, .pattern = value, .decision = .deny };
    if (std.mem.eql(u8, key, "whitelist")) return .{ .kind = .whitelisted_path, .pattern = value, .decision = .allow };
    if (std.mem.eql(u8, key, "trusted")) return .{ .kind = .trusted_process, .pattern = value, .decision = .allow };
    if (std.mem.eql(u8, key, "allow_command")) return .{ .kind = .allowed_command, .pattern = value, .decision = .allow };
    if (std.mem.eql(u8, key, "deny_command")) return .{ .kind = .denied_command, .pattern = value, .decision = .deny };
    if (std.mem.eql(u8, key, "prompt_command")) return .{ .kind = .prompt_command, .pattern = value, .decision = .prompt };
    if (std.mem.eql(u8, key, "network_allow")) return .{ .kind = .network_allow, .pattern = value, .decision = .allow };
    if (std.mem.eql(u8, key, "observe")) return .{ .kind = .observe_process, .pattern = value, .decision = .allow };
    if (std.mem.eql(u8, key, "agent_deny")) return .{ .kind = .agent_deny, .pattern = value, .decision = .deny };
    if (std.mem.eql(u8, key, "agent_allow")) return .{ .kind = .agent_allow, .pattern = value, .decision = .allow };
    if (std.mem.eql(u8, key, "agent_askpass")) return .{ .kind = .agent_askpass, .pattern = value, .decision = .allow };

    return null;
}

test "config: parse line" {
    const r1 = parseLine("protected = /etc/").?;
    try std.testing.expectEqual(Rule.Kind.protected_path, r1.kind);
    try std.testing.expectEqualStrings("/etc/", r1.pattern);

    const r2 = parseLine("network_allow = *.googleapis.com").?;
    try std.testing.expectEqual(Rule.Kind.network_allow, r2.kind);

    try std.testing.expect(parseLine("# comment") == null);
    try std.testing.expect(parseLine("") == null);
}

test "config: parseLine agent rule keys" {
    const r1 = parseLine("agent_deny = rm").?;
    try std.testing.expectEqual(Rule.Kind.agent_deny, r1.kind);
    try std.testing.expectEqualStrings("rm", r1.pattern);
    try std.testing.expectEqual(policy.Decision.deny, r1.decision);

    const r2 = parseLine("agent_allow = cat").?;
    try std.testing.expectEqual(Rule.Kind.agent_allow, r2.kind);
    try std.testing.expectEqualStrings("cat", r2.pattern);
    try std.testing.expectEqual(policy.Decision.allow, r2.decision);

    const r3 = parseLine("agent_askpass = sudo").?;
    try std.testing.expectEqual(Rule.Kind.agent_askpass, r3.kind);
    try std.testing.expectEqualStrings("sudo", r3.pattern);
    try std.testing.expectEqual(policy.Decision.allow, r3.decision);
}

test "config: parseLine all supported keys" {
    try std.testing.expect(parseLine("whitelist = /tmp/") != null);
    try std.testing.expect(parseLine("trusted = /usr/bin/git") != null);
    try std.testing.expect(parseLine("allow_command = cat") != null);
    try std.testing.expect(parseLine("deny_command = sudo") != null);
    try std.testing.expect(parseLine("prompt_command = rm") != null);
    try std.testing.expect(parseLine("observe = claude") != null);
    try std.testing.expect(parseLine("agent_deny = wget") != null);
    try std.testing.expect(parseLine("agent_allow = ls") != null);
    try std.testing.expect(parseLine("agent_askpass = sudo") != null);
}

test "config: parseLine rejects invalid input" {
    // Unknown key
    try std.testing.expect(parseLine("unknown_key = value") == null);
    // Missing value after equals
    try std.testing.expect(parseLine("protected =") == null);
    // No equals sign
    try std.testing.expect(parseLine("protected /etc/") == null);
    // Whitespace-only
    try std.testing.expect(parseLine("   \t  ") == null);
}

test "config: parseLine preserves pattern values" {
    const r = parseLine("whitelist = /usr/local/bin/").?;
    try std.testing.expectEqual(Rule.Kind.whitelisted_path, r.kind);
    try std.testing.expectEqualStrings("/usr/local/bin/", r.pattern);

    const r2 = parseLine("network_allow = *.github.com").?;
    try std.testing.expectEqualStrings("*.github.com", r2.pattern);

    const r3 = parseLine("observe = claude-code").?;
    try std.testing.expectEqualStrings("claude-code", r3.pattern);
}
