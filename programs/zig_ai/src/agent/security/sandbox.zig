// Copyright (c) 2025 QUANTUM ENCODING LTD
// Licensed under the MIT License.

//! Platform-agnostic sandbox abstraction
//! Combines path validation, command validation, and platform-specific enforcement

const std = @import("std");
const builtin = @import("builtin");
const path_validator = @import("path_validator.zig");
const command_validator = @import("command_validator.zig");

pub const SandboxError = error{
    PathOutsideSandbox,
    PathNotWritable,
    CommandNotAllowed,
    BannedPatternMatch,
    SandboxInitFailed,
    UnsupportedPlatform,
    OutOfMemory,
};

pub const SandboxConfig = struct {
    root: []const u8,
    writable_paths: []const []const u8 = &.{},
    readonly_paths: []const []const u8 = &.{},
    allow_network: bool = false,
    allowed_commands: []const []const u8 = &.{},
    banned_patterns: []const []const u8 = &.{},
};

pub const Sandbox = struct {
    allocator: std.mem.Allocator,
    config: SandboxConfig,
    path_val: path_validator.PathValidator,
    cmd_val: command_validator.CommandValidator,
    platform: Platform,

    pub const Platform = enum {
        linux,
        macos,
        other,

        pub fn current() Platform {
            return switch (builtin.os.tag) {
                .linux => .linux,
                .macos => .macos,
                else => .other,
            };
        }
    };

    pub fn init(allocator: std.mem.Allocator, config: SandboxConfig) !Sandbox {
        const path_val = try path_validator.PathValidator.init(
            allocator,
            config.root,
            config.writable_paths,
            config.readonly_paths,
        );
        errdefer path_val.deinit();

        const cmd_val = command_validator.CommandValidator.init(
            allocator,
            config.allowed_commands,
            config.banned_patterns,
        );

        return Sandbox{
            .allocator = allocator,
            .config = config,
            .path_val = path_val,
            .cmd_val = cmd_val,
            .platform = Platform.current(),
        };
    }

    pub fn deinit(self: *Sandbox) void {
        self.path_val.deinit();
    }

    /// Validate a path is within sandbox, return canonical path
    /// Caller owns returned memory
    pub fn validatePath(self: *Sandbox, path: []const u8) ![]const u8 {
        return self.path_val.validatePath(path) catch |err| {
            return switch (err) {
                path_validator.PathError.PathOutsideSandbox => SandboxError.PathOutsideSandbox,
                path_validator.PathError.PathContainsNullByte => SandboxError.PathOutsideSandbox,
                else => SandboxError.OutOfMemory,
            };
        };
    }

    /// Check if path is writable
    pub fn isWritable(self: *const Sandbox, canonical_path: []const u8) bool {
        return self.path_val.isWritable(canonical_path);
    }

    /// Validate path and ensure it's writable
    pub fn validateWritablePath(self: *Sandbox, path: []const u8) ![]const u8 {
        const canonical = try self.validatePath(path);
        errdefer self.allocator.free(canonical);

        if (!self.isWritable(canonical)) {
            self.allocator.free(canonical);
            return SandboxError.PathNotWritable;
        }

        return canonical;
    }

    /// Validate a command against security rules
    pub fn validateCommand(self: *Sandbox, command: []const u8) !void {
        self.cmd_val.validate(command) catch |err| {
            return switch (err) {
                command_validator.CommandError.CommandNotAllowed => SandboxError.CommandNotAllowed,
                command_validator.CommandError.BannedPatternMatch => SandboxError.BannedPatternMatch,
                else => SandboxError.CommandNotAllowed,
            };
        };
    }

    /// Get sandbox root path
    pub fn getRoot(self: *const Sandbox) []const u8 {
        return self.path_val.canonical_root;
    }

    /// Get platform-specific enforcement info
    pub fn getPlatformInfo(self: *const Sandbox) []const u8 {
        return switch (self.platform) {
            .linux => "zig_jail (seccomp + namespaces)",
            .macos => "libmacwarden (DYLD interposition) - TOCTOU possible",
            .other => "no enforcement (validation only)",
        };
    }

    /// Check if platform has strong isolation (kernel-level)
    pub fn hasStrongIsolation(self: *const Sandbox) bool {
        return self.platform == .linux;
    }
};

// Default banned patterns for dangerous operations
pub const default_banned_patterns = [_][]const u8{
    "rm -rf /",
    "rm -rf ~",
    "rm -rf /*",
    "rm -r -f /",
    "rm -r -f ~",
    "dd if=/dev/*",
    "mkfs*",
    "> /dev/*",
    ":(){ :|:& };:",
    "chmod 777 /",
    "chmod -R 777 /",
    "chown -R * /",
    "curl*|*sh",
    "wget*|*sh",
    "sudo *",
    "su -",
    "su root",
};

// Default safe commands for basic file operations
pub const default_allowed_commands = [_][]const u8{
    "ls",
    "cat",
    "head",
    "tail",
    "grep",
    "find",
    "wc",
    "diff",
    "file",
    "stat",
    "pwd",
    "echo",
    "printf",
    "sort",
    "uniq",
    "cut",
    "tr",
    "sed",
    "awk",
};

// Tests
test "sandbox path validation" {
    const allocator = std.testing.allocator;

    var sandbox = try Sandbox.init(allocator, .{
        .root = "/tmp/test-sandbox",
    });
    defer sandbox.deinit();

    // Paths within sandbox should work (after creation)
    // Note: This test assumes /tmp exists
}

test "sandbox command validation" {
    const allocator = std.testing.allocator;

    var sandbox = try Sandbox.init(allocator, .{
        .root = "/tmp/test",
        .allowed_commands = &default_allowed_commands,
        .banned_patterns = &default_banned_patterns,
    });
    defer sandbox.deinit();

    // ls should be allowed
    try sandbox.validateCommand("ls -la");

    // rm should not be allowed (not in whitelist)
    try std.testing.expectError(SandboxError.CommandNotAllowed, sandbox.validateCommand("rm file.txt"));
}
