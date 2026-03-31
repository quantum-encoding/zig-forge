//! Policy Engine for claude-shepherd
//!
//! Evaluates permission requests against configurable policy rules.
//! Supports pattern matching, command whitelisting, and auto-approval.

const std = @import("std");

// Custom Mutex implementation for Zig 0.16 compatibility
// std.Thread.Mutex was removed; use pthread directly
const Mutex = struct {
    inner: std.c.pthread_mutex_t = std.c.PTHREAD_MUTEX_INITIALIZER,
    pub fn lock(self: *Mutex) void {
        _ = std.c.pthread_mutex_lock(&self.inner);
    }
    pub fn unlock(self: *Mutex) void {
        _ = std.c.pthread_mutex_unlock(&self.inner);
    }
};

pub const Decision = enum {
    allow,
    deny,
    prompt,
};

pub const Rule = struct {
    cmd: []const u8,
    args_pattern: ?[]const u8 = null,
    path_pattern: ?[]const u8 = null,
    decision: Decision,
    reason: []const u8 = "",

    pub fn matches(self: *const Rule, cmd: []const u8, args: []const u8) bool {
        // Check command match
        if (!std.mem.eql(u8, self.cmd, cmd) and !std.mem.eql(u8, self.cmd, "*")) {
            return false;
        }

        // Check args pattern if specified
        if (self.args_pattern) |pattern| {
            if (!matchPattern(pattern, args)) {
                return false;
            }
        }

        return true;
    }
};

pub const AutoApproval = struct {
    pattern: []const u8,
    remaining: ?u32 = null, // null = unlimited
    scope: Scope = .session,

    pub const Scope = enum {
        session,
        permanent,
        count_limited,
    };
};

pub const PolicyEngine = struct {
    allocator: std.mem.Allocator,
    allow_rules: std.ArrayListUnmanaged(Rule),
    prompt_rules: std.ArrayListUnmanaged(Rule),
    deny_rules: std.ArrayListUnmanaged(Rule),
    auto_approvals: std.ArrayListUnmanaged(AutoApproval),
    mutex: Mutex,

    pub fn init(allocator: std.mem.Allocator) !PolicyEngine {
        var engine = PolicyEngine{
            .allocator = allocator,
            .allow_rules = .empty,
            .prompt_rules = .empty,
            .deny_rules = .empty,
            .auto_approvals = .empty,
            .mutex = .{},
        };

        // Load default rules
        try engine.loadDefaults();

        return engine;
    }

    pub fn deinit(self: *PolicyEngine) void {
        self.allow_rules.deinit(self.allocator);
        self.prompt_rules.deinit(self.allocator);
        self.deny_rules.deinit(self.allocator);
        self.auto_approvals.deinit(self.allocator);
    }

    fn loadDefaults(self: *PolicyEngine) !void {
        // Default allow rules - safe read-only commands
        try self.allow_rules.append(self.allocator, .{
            .cmd = "cat",
            .decision = .allow,
            .reason = "read-only file access",
        });
        try self.allow_rules.append(self.allocator, .{
            .cmd = "ls",
            .decision = .allow,
            .reason = "directory listing",
        });
        try self.allow_rules.append(self.allocator, .{
            .cmd = "tree",
            .decision = .allow,
            .reason = "directory tree",
        });
        try self.allow_rules.append(self.allocator, .{
            .cmd = "find",
            .decision = .allow,
            .reason = "file search",
        });
        try self.allow_rules.append(self.allocator, .{
            .cmd = "head",
            .decision = .allow,
            .reason = "read file head",
        });
        try self.allow_rules.append(self.allocator, .{
            .cmd = "tail",
            .decision = .allow,
            .reason = "read file tail",
        });
        try self.allow_rules.append(self.allocator, .{
            .cmd = "grep",
            .decision = .allow,
            .reason = "text search",
        });
        try self.allow_rules.append(self.allocator, .{
            .cmd = "rg",
            .decision = .allow,
            .reason = "ripgrep search",
        });
        try self.allow_rules.append(self.allocator, .{
            .cmd = "wc",
            .decision = .allow,
            .reason = "word count",
        });
        try self.allow_rules.append(self.allocator, .{
            .cmd = "file",
            .decision = .allow,
            .reason = "file type detection",
        });

        // Zig build commands
        try self.allow_rules.append(self.allocator, .{
            .cmd = "zig",
            .args_pattern = "build*",
            .decision = .allow,
            .reason = "zig build command",
        });
        try self.allow_rules.append(self.allocator, .{
            .cmd = "zig",
            .args_pattern = "test*",
            .decision = .allow,
            .reason = "zig test command",
        });
        try self.allow_rules.append(self.allocator, .{
            .cmd = "zig",
            .args_pattern = "version*",
            .decision = .allow,
            .reason = "zig version check",
        });

        // Project binaries (zig-out)
        try self.allow_rules.append(self.allocator, .{
            .cmd = "./zig-out/bin/*",
            .decision = .allow,
            .reason = "project binary execution",
        });

        // Default prompt rules - potentially destructive
        try self.prompt_rules.append(self.allocator, .{
            .cmd = "rm",
            .decision = .prompt,
            .reason = "file deletion",
        });
        try self.prompt_rules.append(self.allocator, .{
            .cmd = "mv",
            .decision = .prompt,
            .reason = "file move/rename",
        });
        try self.prompt_rules.append(self.allocator, .{
            .cmd = "cp",
            .decision = .prompt,
            .reason = "file copy",
        });
        try self.prompt_rules.append(self.allocator, .{
            .cmd = "chmod",
            .decision = .prompt,
            .reason = "permission change",
        });
        try self.prompt_rules.append(self.allocator, .{
            .cmd = "chown",
            .decision = .prompt,
            .reason = "ownership change",
        });

        // Default deny rules - dangerous commands
        try self.deny_rules.append(self.allocator, .{
            .cmd = "sudo",
            .decision = .deny,
            .reason = "privilege escalation",
        });
        try self.deny_rules.append(self.allocator, .{
            .cmd = "su",
            .decision = .deny,
            .reason = "user switching",
        });
        try self.deny_rules.append(self.allocator, .{
            .cmd = "dd",
            .decision = .deny,
            .reason = "raw disk access",
        });
        try self.deny_rules.append(self.allocator, .{
            .cmd = "mkfs",
            .decision = .deny,
            .reason = "filesystem creation",
        });
        try self.deny_rules.append(self.allocator, .{
            .cmd = "fdisk",
            .decision = .deny,
            .reason = "partition editing",
        });
    }

    pub fn evaluate(self: *PolicyEngine, cmd: []const u8, args: []const u8) Decision {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Check deny rules first (highest priority)
        for (self.deny_rules.items) |*rule| {
            if (rule.matches(cmd, args)) {
                return .deny;
            }
        }

        // Check allow rules
        for (self.allow_rules.items) |*rule| {
            if (rule.matches(cmd, args)) {
                return .allow;
            }
        }

        // Check auto-approvals
        for (self.auto_approvals.items) |*approval| {
            if (matchPattern(approval.pattern, cmd)) {
                if (approval.remaining) |*remaining| {
                    if (remaining.* > 0) {
                        remaining.* -= 1;
                        return .allow;
                    }
                } else {
                    return .allow;
                }
            }
        }

        // Check prompt rules
        for (self.prompt_rules.items) |*rule| {
            if (rule.matches(cmd, args)) {
                return .prompt;
            }
        }

        // Default: prompt for unknown commands
        return .prompt;
    }

    pub fn addRule(self: *PolicyEngine, rule: Rule) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        switch (rule.decision) {
            .allow => try self.allow_rules.append(self.allocator, rule),
            .prompt => try self.prompt_rules.append(self.allocator, rule),
            .deny => try self.deny_rules.append(self.allocator, rule),
        }
    }

    pub fn addAutoApproval(self: *PolicyEngine, pattern: []const u8, count: ?u32) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        try self.auto_approvals.append(self.allocator, .{
            .pattern = pattern,
            .remaining = count,
            .scope = if (count != null) .count_limited else .session,
        });
    }

    pub fn clearAutoApprovals(self: *PolicyEngine) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        self.auto_approvals.clearRetainingCapacity();
    }
};

/// Simple glob-style pattern matching
/// Supports: * (any chars), ? (single char)
fn matchPattern(pattern: []const u8, text: []const u8) bool {
    var p_idx: usize = 0;
    var t_idx: usize = 0;
    var star_p: ?usize = null;
    var star_t: usize = 0;

    while (t_idx < text.len) {
        if (p_idx < pattern.len and (pattern[p_idx] == text[t_idx] or pattern[p_idx] == '?')) {
            p_idx += 1;
            t_idx += 1;
        } else if (p_idx < pattern.len and pattern[p_idx] == '*') {
            star_p = p_idx;
            star_t = t_idx;
            p_idx += 1;
        } else if (star_p) |sp| {
            p_idx = sp + 1;
            star_t += 1;
            t_idx = star_t;
        } else {
            return false;
        }
    }

    // Check remaining pattern (should only be stars)
    while (p_idx < pattern.len and pattern[p_idx] == '*') {
        p_idx += 1;
    }

    return p_idx == pattern.len;
}

test "pattern matching" {
    try std.testing.expect(matchPattern("*.txt", "file.txt"));
    try std.testing.expect(matchPattern("file.*", "file.txt"));
    try std.testing.expect(matchPattern("*", "anything"));
    try std.testing.expect(matchPattern("build*", "build"));
    try std.testing.expect(matchPattern("build*", "build test"));
    try std.testing.expect(!matchPattern("*.txt", "file.doc"));
}

test "policy engine defaults" {
    const allocator = std.testing.allocator;
    var engine = try PolicyEngine.init(allocator);
    defer engine.deinit();

    // Safe commands should be allowed
    try std.testing.expectEqual(Decision.allow, engine.evaluate("ls", "-la"));
    try std.testing.expectEqual(Decision.allow, engine.evaluate("cat", "file.txt"));
    try std.testing.expectEqual(Decision.allow, engine.evaluate("zig", "build"));

    // Dangerous commands should be denied
    try std.testing.expectEqual(Decision.deny, engine.evaluate("sudo", "rm -rf /"));

    // Destructive commands should prompt
    try std.testing.expectEqual(Decision.prompt, engine.evaluate("rm", "file.txt"));
}
