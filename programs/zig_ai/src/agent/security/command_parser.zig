// Copyright (c) 2025 QUANTUM ENCODING LTD
// Licensed under the MIT License.

//! Command parser for security validation
//! Normalizes flags and extracts executables to prevent bypass attempts

const std = @import("std");

pub const ParsedCommand = struct {
    /// Base executable name (no path)
    executable: []const u8,
    /// Original full command
    original: []const u8,
    /// Normalized command for pattern matching
    normalized: []const u8,
    /// Individual arguments
    args: []const []const u8,

    allocator: std.mem.Allocator,

    pub fn deinit(self: *ParsedCommand) void {
        self.allocator.free(self.executable);
        self.allocator.free(self.normalized);
        for (self.args) |arg| {
            self.allocator.free(arg);
        }
        self.allocator.free(self.args);
    }
};

pub const CommandParser = struct {
    allocator: std.mem.Allocator,

    /// Known long-to-short flag mappings for common commands
    /// This helps normalize `--recursive` to `-r`, `--force` to `-f`, etc.
    const FlagMapping = struct {
        long: []const u8,
        short: u8,
    };

    const common_mappings = [_]FlagMapping{
        .{ .long = "recursive", .short = 'r' },
        .{ .long = "force", .short = 'f' },
        .{ .long = "verbose", .short = 'v' },
        .{ .long = "all", .short = 'a' },
        .{ .long = "long", .short = 'l' },
        .{ .long = "human-readable", .short = 'h' },
        .{ .long = "interactive", .short = 'i' },
        .{ .long = "no-preserve-root", .short = 0 }, // dangerous, keep as-is
    };

    pub fn init(allocator: std.mem.Allocator) CommandParser {
        return .{ .allocator = allocator };
    }

    /// Parse a command string into structured form
    pub fn parse(self: *CommandParser, command: []const u8) !ParsedCommand {
        var args_list: std.ArrayListUnmanaged([]const u8) = .empty;
        errdefer {
            for (args_list.items) |arg| {
                self.allocator.free(arg);
            }
            args_list.deinit(self.allocator);
        }

        // Simple tokenization (handles basic quoting)
        var in_single_quote = false;
        var in_double_quote = false;
        var current_arg: std.ArrayListUnmanaged(u8) = .empty;
        defer current_arg.deinit(self.allocator);

        var i: usize = 0;
        while (i < command.len) : (i += 1) {
            const c = command[i];

            if (c == '\'' and !in_double_quote) {
                in_single_quote = !in_single_quote;
            } else if (c == '"' and !in_single_quote) {
                in_double_quote = !in_double_quote;
            } else if (c == ' ' and !in_single_quote and !in_double_quote) {
                if (current_arg.items.len > 0) {
                    const arg = try current_arg.toOwnedSlice(self.allocator);
                    try args_list.append(self.allocator, arg);
                }
            } else if (c == '\\' and i + 1 < command.len and !in_single_quote) {
                // Escape sequence
                i += 1;
                try current_arg.append(self.allocator, command[i]);
            } else {
                try current_arg.append(self.allocator, c);
            }
        }

        // Add last argument
        if (current_arg.items.len > 0) {
            const arg = try current_arg.toOwnedSlice(self.allocator);
            try args_list.append(self.allocator, arg);
        }

        if (args_list.items.len == 0) {
            return error.EmptyCommand;
        }

        // Extract executable (skip prefixes like env, sudo, etc.)
        const executable = try self.extractExecutable(args_list.items);

        // Normalize the command
        const normalized = try self.normalizeCommand(args_list.items);

        return ParsedCommand{
            .executable = executable,
            .original = command,
            .normalized = normalized,
            .args = try args_list.toOwnedSlice(self.allocator),
            .allocator = self.allocator,
        };
    }

    /// Extract the actual executable, stripping prefixes like env, sudo
    fn extractExecutable(self: *CommandParser, args: []const []const u8) ![]const u8 {
        var idx: usize = 0;

        // Skip common prefixes
        while (idx < args.len) {
            const arg = args[idx];
            const base = std.fs.path.basename(arg);

            if (std.mem.eql(u8, base, "env")) {
                idx += 1;
                // Skip env variables (VAR=value)
                while (idx < args.len and std.mem.indexOfScalar(u8, args[idx], '=') != null) {
                    idx += 1;
                }
            } else if (std.mem.eql(u8, base, "sudo") or
                std.mem.eql(u8, base, "doas") or
                std.mem.eql(u8, base, "su"))
            {
                idx += 1;
                // Skip sudo flags
                while (idx < args.len and args[idx].len > 0 and args[idx][0] == '-') {
                    idx += 1;
                }
            } else if (std.mem.eql(u8, base, "nice") or
                std.mem.eql(u8, base, "nohup") or
                std.mem.eql(u8, base, "time") or
                std.mem.eql(u8, base, "timeout"))
            {
                idx += 1;
                // Skip their arguments
                while (idx < args.len and args[idx].len > 0 and args[idx][0] == '-') {
                    idx += 1;
                }
            } else {
                break;
            }
        }

        if (idx >= args.len) {
            return error.NoExecutableFound;
        }

        // Return basename of executable
        const exec_path = args[idx];
        const basename = std.fs.path.basename(exec_path);
        return self.allocator.dupe(u8, basename);
    }

    /// Normalize command by expanding combined flags and converting long to short
    fn normalizeCommand(self: *CommandParser, args: []const []const u8) ![]const u8 {
        var result: std.ArrayListUnmanaged(u8) = .empty;
        errdefer result.deinit(self.allocator);

        for (args, 0..) |arg, i| {
            if (i > 0) {
                try result.append(self.allocator, ' ');
            }

            if (arg.len > 2 and std.mem.startsWith(u8, arg, "--")) {
                // Long flag - try to convert to short
                const flag_name = arg[2..];
                const short = self.longToShort(flag_name);
                if (short != 0) {
                    try result.append(self.allocator, '-');
                    try result.append(self.allocator, short);
                } else {
                    try result.appendSlice(self.allocator, arg);
                }
            } else if (arg.len > 1 and arg[0] == '-' and arg[1] != '-') {
                // Short flag(s) - expand combined flags
                try result.append(self.allocator, '-');
                for (arg[1..]) |flag| {
                    if (flag != ' ') {
                        try result.append(self.allocator, flag);
                        try result.append(self.allocator, ' ');
                        try result.append(self.allocator, '-');
                    }
                }
                // Remove trailing " -"
                if (result.items.len >= 2) {
                    _ = result.pop();
                    _ = result.pop();
                }
            } else {
                try result.appendSlice(self.allocator, arg);
            }
        }

        return result.toOwnedSlice(self.allocator);
    }

    fn longToShort(_: *CommandParser, long_flag: []const u8) u8 {
        for (common_mappings) |mapping| {
            if (std.mem.eql(u8, long_flag, mapping.long)) {
                return mapping.short;
            }
        }
        return 0;
    }
};

// Tests
test "parse simple command" {
    const allocator = std.testing.allocator;
    var parser = CommandParser.init(allocator);

    var cmd = try parser.parse("ls -la");
    defer cmd.deinit();

    try std.testing.expectEqualStrings("ls", cmd.executable);
}

test "parse command with env prefix" {
    const allocator = std.testing.allocator;
    var parser = CommandParser.init(allocator);

    var cmd = try parser.parse("env VAR=value rm -rf /");
    defer cmd.deinit();

    try std.testing.expectEqualStrings("rm", cmd.executable);
}

test "parse command with sudo" {
    const allocator = std.testing.allocator;
    var parser = CommandParser.init(allocator);

    var cmd = try parser.parse("sudo -u root rm -rf /");
    defer cmd.deinit();

    try std.testing.expectEqualStrings("rm", cmd.executable);
}
