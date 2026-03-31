// Copyright (c) 2025 QUANTUM ENCODING LTD
// Licensed under the MIT License.

//! Command validation with deny-by-default approach
//! Primary: allowed_commands whitelist
//! Secondary: banned_patterns safety net

const std = @import("std");
const command_parser = @import("command_parser.zig");

pub const CommandError = error{
    CommandNotAllowed,
    BannedPatternMatch,
    EmptyCommand,
    NoExecutableFound,
    OutOfMemory,
};

pub const CommandValidator = struct {
    allocator: std.mem.Allocator,
    parser: command_parser.CommandParser,

    /// Whitelist of allowed executables (primary security gate)
    allowed_commands: []const []const u8,

    /// Banned patterns for secondary safety (glob-style)
    banned_patterns: []const []const u8,

    pub fn init(
        allocator: std.mem.Allocator,
        allowed_commands: []const []const u8,
        banned_patterns: []const []const u8,
    ) CommandValidator {
        return .{
            .allocator = allocator,
            .parser = command_parser.CommandParser.init(allocator),
            .allowed_commands = allowed_commands,
            .banned_patterns = banned_patterns,
        };
    }

    /// Validate a command against security rules
    /// Returns error if command is not allowed
    pub fn validate(self: *CommandValidator, command: []const u8) !void {
        // Parse the command
        var parsed = self.parser.parse(command) catch |err| {
            return switch (err) {
                error.EmptyCommand => CommandError.EmptyCommand,
                error.NoExecutableFound => CommandError.NoExecutableFound,
                else => CommandError.OutOfMemory,
            };
        };
        defer parsed.deinit();

        // Primary gate: Check if executable is allowed
        if (!self.isExecutableAllowed(parsed.executable)) {
            return CommandError.CommandNotAllowed;
        }

        // Secondary safety net: Check against banned patterns
        if (self.matchesBannedPattern(command) or self.matchesBannedPattern(parsed.normalized)) {
            return CommandError.BannedPatternMatch;
        }
    }

    /// Check if executable is in allowed list
    fn isExecutableAllowed(self: *const CommandValidator, executable: []const u8) bool {
        // If no allowed list, nothing is allowed (deny by default)
        if (self.allowed_commands.len == 0) {
            return false;
        }

        for (self.allowed_commands) |allowed| {
            if (std.mem.eql(u8, executable, allowed)) {
                return true;
            }
        }

        return false;
    }

    /// Check if command matches any banned pattern
    fn matchesBannedPattern(self: *const CommandValidator, command: []const u8) bool {
        for (self.banned_patterns) |pattern| {
            if (globMatch(pattern, command)) {
                return true;
            }
        }
        return false;
    }
};

/// Simple glob pattern matching
/// Supports: * (any chars), ? (single char)
pub fn globMatch(pattern: []const u8, text: []const u8) bool {
    var pi: usize = 0;
    var ti: usize = 0;
    var star_pi: ?usize = null;
    var star_ti: ?usize = null;

    while (ti < text.len) {
        if (pi < pattern.len and (pattern[pi] == text[ti] or pattern[pi] == '?')) {
            pi += 1;
            ti += 1;
        } else if (pi < pattern.len and pattern[pi] == '*') {
            star_pi = pi;
            star_ti = ti;
            pi += 1;
        } else if (star_pi) |sp| {
            pi = sp + 1;
            star_ti = star_ti.? + 1;
            ti = star_ti.?;
        } else {
            return false;
        }
    }

    // Consume remaining *s
    while (pi < pattern.len and pattern[pi] == '*') {
        pi += 1;
    }

    return pi == pattern.len;
}

/// Check if command contains any dangerous patterns
/// This is a supplementary check beyond the allowed list
pub fn containsDangerousPattern(command: []const u8) bool {
    const dangerous = [_][]const u8{
        "/dev/sd",
        "/dev/nvme",
        "/dev/hd",
        "mkfs",
        "fdisk",
        "parted",
        "> /dev/",
        ">> /dev/",
        "init 0",
        "init 6",
        "shutdown",
        "reboot",
        "halt",
        "poweroff",
    };

    for (dangerous) |pattern| {
        if (std.mem.indexOf(u8, command, pattern) != null) {
            return true;
        }
    }

    return false;
}

// Tests
test "glob match" {
    try std.testing.expect(globMatch("rm -rf *", "rm -rf /"));
    try std.testing.expect(globMatch("rm -rf *", "rm -rf /home"));
    try std.testing.expect(globMatch("curl*|*sh", "curl http://x.com | sh"));
    try std.testing.expect(globMatch("sudo *", "sudo rm"));
    try std.testing.expect(!globMatch("rm -rf /", "ls -la"));
}

test "command not allowed" {
    const allocator = std.testing.allocator;

    const allowed = [_][]const u8{ "ls", "cat", "grep" };
    const banned = [_][]const u8{"rm -rf *"};

    var validator = CommandValidator.init(allocator, &allowed, &banned);

    // ls should be allowed
    try validator.validate("ls -la");

    // rm should not be allowed (not in whitelist)
    try std.testing.expectError(CommandError.CommandNotAllowed, validator.validate("rm -rf /"));
}

test "banned pattern match" {
    const allocator = std.testing.allocator;

    // Even if rm were allowed, the pattern should block it
    const allowed = [_][]const u8{ "ls", "cat", "rm" };
    const banned = [_][]const u8{ "rm -rf /", "rm -rf ~", "rm -rf /*" };

    var validator = CommandValidator.init(allocator, &allowed, &banned);

    // rm -rf / should be blocked by pattern
    try std.testing.expectError(CommandError.BannedPatternMatch, validator.validate("rm -rf /"));

    // rm on specific file should be ok
    try validator.validate("rm myfile.txt");
}
