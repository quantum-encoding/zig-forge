//! Guardian Shield - eBPF-based System Security Framework
//!
//! Copyright (c) 2025 Richard Tune / Quantum Encoding Ltd
//! Author: Richard Tune
//! Contact: info@quantumencoding.io
//! Website: https://quantumencoding.io
//!
//! License: Dual License - MIT (Non-Commercial) / Commercial License
//!
//! NON-COMMERCIAL USE (MIT License):
//! Permission is hereby granted, free of charge, to any person obtaining a copy
//! of this software and associated documentation files (the "Software"), to deal
//! in the Software without restriction for NON-COMMERCIAL purposes, including
//! without limitation the rights to use, copy, modify, merge, publish, distribute,
//! sublicense, and/or sell copies of the Software for non-commercial purposes,
//! and to permit persons to whom the Software is furnished to do so, subject to
//! the following conditions:
//!
//! The above copyright notice and this permission notice shall be included in all
//! copies or substantial portions of the Software.
//!
//! THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//! IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//! FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//! AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//! LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//! OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
//! SOFTWARE.
//!
//! COMMERCIAL USE:
//! Commercial use of this software requires a separate commercial license.
//! Contact info@quantumencoding.io for commercial licensing terms.


// config.zig - Configuration parser for libwarden.so V4
// Purpose: Load and parse warden-config.json at runtime with robust parsing

const std = @import("std");

const c = @cImport({
    @cInclude("fcntl.h");
    @cInclude("unistd.h");
    @cInclude("stdlib.h");
});

// Helper for getenv compatibility with Zig 0.16.2187+
fn getenv(name: [*:0]const u8) ?[]const u8 {
    const ptr = c.getenv(name);
    if (ptr) |p| {
        return std.mem.span(p);
    }
    return null;
}

// ============================================================
// Configuration Structures
// ============================================================

pub const GlobalConfig = struct {
    enabled: bool = true,
    log_level: []const u8 = "normal",
    log_target: []const u8 = "stderr",
    block_emoji: []const u8 = "🛡️",
    warning_emoji: []const u8 = "⚠️",
    allow_emoji: []const u8 = "✓",
};

pub const ProtectedPath = struct {
    path: []const u8,
    description: []const u8,
    block_operations: []const []const u8,
};

pub const WhitelistedPath = struct {
    path: []const u8,
    description: []const u8,
};

pub const ProtectionConfig = struct {
    protected_paths: []ProtectedPath,
    whitelisted_paths: []WhitelistedPath,
};

pub const AdvancedConfig = struct {
    cache_path_checks: bool = true,
    max_cache_size: usize = 1000,
    allow_symlink_bypass: bool = false,
    canonicalize_paths: bool = true,
    notify_auditd: bool = true,
    auditd_key: []const u8 = "libwarden_block",
    allow_env_override: bool = false,
};

// ============================================================
// V8.0: Granular Permission Flags
// ============================================================
//
// CLI-style permission presets for easy path protection configuration.
// These map to specific block_operations arrays.
//
// Usage: wardenctl add --path /some/path --no-delete --no-move
//
// Flags:
//   --no-delete    : blocks unlink, unlinkat, rmdir
//   --no-move      : blocks rename, renameat
//   --no-truncate  : blocks truncate, ftruncate
//   --no-write     : blocks open_write
//   --no-symlink   : blocks symlink, symlinkat, symlink_target
//   --no-link      : blocks link, linkat
//   --no-mkdir     : blocks mkdir, mkdirat
//   --read-only    : blocks all write/modify operations (all of the above)

pub const PermissionFlags = struct {
    no_delete: bool = false,
    no_move: bool = false,
    no_truncate: bool = false,
    no_write: bool = false,
    no_symlink: bool = false,
    no_link: bool = false,
    no_mkdir: bool = false,

    const Self = @This();

    /// Create flags from a --read-only preset
    pub fn readOnly() Self {
        return Self{
            .no_delete = true,
            .no_move = true,
            .no_truncate = true,
            .no_write = true,
            .no_symlink = true,
            .no_link = true,
            .no_mkdir = true,
        };
    }

    /// Convert flags to block_operations array
    /// Returns a slice that must be freed by caller
    pub fn toOperations(self: Self, allocator: std.mem.Allocator) ![][]const u8 {
        var ops = std.ArrayList([]const u8).init(allocator);
        errdefer ops.deinit();

        if (self.no_delete) {
            try ops.append("unlink");
            try ops.append("unlinkat");
            try ops.append("rmdir");
        }
        if (self.no_move) {
            try ops.append("rename");
            try ops.append("renameat");
        }
        if (self.no_truncate) {
            try ops.append("truncate");
            try ops.append("ftruncate");
        }
        if (self.no_write) {
            try ops.append("open_write");
        }
        if (self.no_symlink) {
            try ops.append("symlink");
            try ops.append("symlinkat");
            try ops.append("symlink_target");
        }
        if (self.no_link) {
            try ops.append("link");
            try ops.append("linkat");
        }
        if (self.no_mkdir) {
            try ops.append("mkdir");
            try ops.append("mkdirat");
        }

        return ops.toOwnedSlice();
    }

    /// Parse flags from command-line arguments
    pub fn fromArgs(args: []const []const u8) Self {
        var flags = Self{};
        for (args) |arg| {
            if (std.mem.eql(u8, arg, "--no-delete")) {
                flags.no_delete = true;
            } else if (std.mem.eql(u8, arg, "--no-move")) {
                flags.no_move = true;
            } else if (std.mem.eql(u8, arg, "--no-truncate")) {
                flags.no_truncate = true;
            } else if (std.mem.eql(u8, arg, "--no-write")) {
                flags.no_write = true;
            } else if (std.mem.eql(u8, arg, "--no-symlink")) {
                flags.no_symlink = true;
            } else if (std.mem.eql(u8, arg, "--no-link")) {
                flags.no_link = true;
            } else if (std.mem.eql(u8, arg, "--no-mkdir")) {
                flags.no_mkdir = true;
            } else if (std.mem.eql(u8, arg, "--read-only")) {
                flags = readOnly();
            }
        }
        return flags;
    }

    /// Check if any flag is set
    pub fn anySet(self: Self) bool {
        return self.no_delete or self.no_move or self.no_truncate or
            self.no_write or self.no_symlink or self.no_link or self.no_mkdir;
    }

    /// Format as human-readable string
    pub fn format(self: Self, writer: anytype) !void {
        var first = true;
        if (self.no_delete) {
            try writer.writeAll("no-delete");
            first = false;
        }
        if (self.no_move) {
            if (!first) try writer.writeAll(", ");
            try writer.writeAll("no-move");
            first = false;
        }
        if (self.no_truncate) {
            if (!first) try writer.writeAll(", ");
            try writer.writeAll("no-truncate");
            first = false;
        }
        if (self.no_write) {
            if (!first) try writer.writeAll(", ");
            try writer.writeAll("no-write");
            first = false;
        }
        if (self.no_symlink) {
            if (!first) try writer.writeAll(", ");
            try writer.writeAll("no-symlink");
            first = false;
        }
        if (self.no_link) {
            if (!first) try writer.writeAll(", ");
            try writer.writeAll("no-link");
            first = false;
        }
        if (self.no_mkdir) {
            if (!first) try writer.writeAll(", ");
            try writer.writeAll("no-mkdir");
        }
    }
};

pub const DirectoryProtection = struct {
    enabled: bool = true,
    description: []const u8 = "",
    protected_roots: []const []const u8,
    protected_patterns: []const []const u8,
};

// V7.1: Process-aware restrictions
pub const ProcessRestrictions = struct {
    block_tmp_write: bool = false,
    block_tmp_execute: bool = false,
    block_dotfile_write: bool = false,
    monitored_dotfiles: []const []const u8 = &[_][]const u8{},
};

pub const RestrictedProcess = struct {
    name: []const u8,
    description: []const u8,
    restrictions: ProcessRestrictions,
};

pub const ProcessRestrictionConfig = struct {
    enabled: bool = false,
    description: []const u8 = "",
    restricted_processes: []const RestrictedProcess = &[_]RestrictedProcess{},
    whitelist_mode: bool = false,
    enforcement_level: []const u8 = "strict",
    log_process_name: bool = true,
};

// V7.2: Process exemptions for trusted build tools
pub const ProcessExemptions = struct {
    enabled: bool = true,
    description: []const u8 = "",
    exempt_processes: []const []const u8 = &[_][]const u8{},
};

// Root config structure matching JSON schema
const RawConfig = struct {
    global: GlobalConfig,
    protection: ProtectionConfig,
    directory_protection: DirectoryProtection = DirectoryProtection{
        .protected_roots = &[_][]const u8{},
        .protected_patterns = &[_][]const u8{},
    },
    process_exemptions: ProcessExemptions = ProcessExemptions{},
    process_restrictions: ProcessRestrictionConfig = ProcessRestrictionConfig{},
    advanced: AdvancedConfig,
};

pub const Config = struct {
    global: GlobalConfig,
    protected_paths: []ProtectedPath,
    whitelisted_paths: []WhitelistedPath,
    directory_protection: DirectoryProtection,
    process_exemptions: ProcessExemptions,
    process_restrictions: ProcessRestrictionConfig,
    advanced: AdvancedConfig,

    // Allocator used for dynamic memory
    allocator: std.mem.Allocator,

    // Store the parsed JSON result for proper cleanup
    parsed_json: ?*std.json.Parsed(RawConfig) = null,

    pub fn deinit(self: *Config) void {
        if (self.parsed_json) |parsed| {
            parsed.deinit();
            self.allocator.destroy(parsed);
        } else {
            // For default config, manually free allocations
            self.allocator.free(self.protected_paths);
            self.allocator.free(self.whitelisted_paths);
        }
    }
};

// ============================================================
// Configuration Loading
// ============================================================

const CONFIG_PATHS = [_][]const u8{
    "/etc/warden/warden-config.json",
    "/forge/config/warden-config-docker-test.json", // Docker test config
    "./config/warden-config.json",
    "/home/founder/zig_forge/config/warden-config.json",
};

/// Load configuration from JSON file
pub fn loadConfig(allocator: std.mem.Allocator) !Config {
    // V8.1: Check if verbose mode is enabled
    const verbose = if (getenv("WARDEN_VERBOSE")) |v| std.mem.eql(u8, v, "1") else false;

    // Try each config path in order
    for (CONFIG_PATHS) |path| {
        if (loadConfigFromPath(allocator, path)) |config| {
            if (verbose) {
                std.debug.print("[libwarden.so] ✓ Loaded config from: {s}\n", .{path});
            }
            return config;
        } else |_| {
            continue;
        }
    }

    // If no config found, return error
    if (verbose) {
        std.debug.print("[libwarden.so] ⚠️  No config file found, using defaults\n", .{});
    }
    return error.ConfigNotFound;
}

fn loadConfigFromPath(allocator: std.mem.Allocator, path: []const u8) !Config {
    // Open file using C functions for Zig 0.16.2187+
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    if (path.len >= path_buf.len) return error.PathTooLong;
    @memcpy(path_buf[0..path.len], path);
    path_buf[path.len] = 0;
    const fd = c.open(@ptrCast(&path_buf), c.O_RDONLY, @as(c_uint, 0));
    if (fd < 0) return error.FileOpenError;
    defer _ = c.close(fd);

    // Get file size using lseek
    const file_size_i64 = c.lseek(fd, 0, c.SEEK_END);
    if (file_size_i64 < 0) return error.SeekError;
    _ = c.lseek(fd, 0, c.SEEK_SET);
    const file_size: usize = @intCast(file_size_i64);

    // Read entire file
    const content = try allocator.alloc(u8, file_size);
    // DO NOT FREE: parseFromSlice stores pointers into this buffer
    // In LD_PRELOAD libraries, we intentionally leak memory on init
    // defer allocator.free(content);  // REMOVED - would cause use-after-free

    const bytes_read_raw = c.read(fd, content.ptr, content.len);
    if (bytes_read_raw < 0) return error.ReadError;
    const bytes_read: usize = @intCast(bytes_read_raw);
    if (bytes_read != file_size) return error.ReadError;

    // Parse JSON directly into struct using parseFromSlice
    const parsed_ptr = try allocator.create(std.json.Parsed(RawConfig));
    parsed_ptr.* = try std.json.parseFromSlice(
        RawConfig,
        allocator,
        content,
        .{ .ignore_unknown_fields = true },
    );

    return Config{
        .global = parsed_ptr.value.global,
        .protected_paths = parsed_ptr.value.protection.protected_paths,
        .whitelisted_paths = parsed_ptr.value.protection.whitelisted_paths,
        .directory_protection = parsed_ptr.value.directory_protection,
        .process_exemptions = parsed_ptr.value.process_exemptions,
        .process_restrictions = parsed_ptr.value.process_restrictions,
        .advanced = parsed_ptr.value.advanced,
        .allocator = allocator,
        .parsed_json = parsed_ptr,
    };
}

// ============================================================
// Default/Fallback Configuration
// ============================================================

/// Returns hardcoded default configuration if JSON loading fails
pub fn getDefaultConfig(allocator: std.mem.Allocator) !Config {
    var protected_paths = try allocator.alloc(ProtectedPath, 9);
    protected_paths[0] = ProtectedPath{
        .path = "/etc/",
        .description = "System configuration",
        .block_operations = &[_][]const u8{ "unlink", "unlinkat", "rmdir", "open_write", "rename" },
    };
    protected_paths[1] = ProtectedPath{
        .path = "/boot/",
        .description = "Boot partition",
        .block_operations = &[_][]const u8{ "unlink", "unlinkat", "rmdir", "open_write", "rename" },
    };
    protected_paths[2] = ProtectedPath{
        .path = "/sys/",
        .description = "Kernel sysfs",
        .block_operations = &[_][]const u8{ "unlink", "unlinkat", "rmdir", "open_write", "rename" },
    };
    protected_paths[3] = ProtectedPath{
        .path = "/proc/",
        .description = "Process filesystem",
        .block_operations = &[_][]const u8{ "unlink", "unlinkat", "rmdir", "open_write", "rename" },
    };
    protected_paths[4] = ProtectedPath{
        .path = "/dev/sda",
        .description = "Block device",
        .block_operations = &[_][]const u8{"open_write"},
    };
    protected_paths[5] = ProtectedPath{
        .path = "/dev/nvme",
        .description = "NVMe device",
        .block_operations = &[_][]const u8{"open_write"},
    };
    protected_paths[6] = ProtectedPath{
        .path = "/dev/vd",
        .description = "Virtual disk",
        .block_operations = &[_][]const u8{"open_write"},
    };
    protected_paths[7] = ProtectedPath{
        .path = "/usr/lib/",
        .description = "System libraries",
        .block_operations = &[_][]const u8{ "unlink", "unlinkat", "rmdir", "open_write" },
    };
    protected_paths[8] = ProtectedPath{
        .path = "/usr/bin/",
        .description = "System binaries",
        .block_operations = &[_][]const u8{ "unlink", "unlinkat", "rmdir", "open_write" },
    };

    // Get HOME from environment or use default
    const home = getenv("HOME") orelse "/home";

    // Build user-specific paths
    const user_tmp = try std.fmt.allocPrint(allocator, "{s}/tmp/", .{home});
    const user_sandbox = try std.fmt.allocPrint(allocator, "{s}/sandbox/", .{home});
    const user_claude = try std.fmt.allocPrint(allocator, "{s}/.claude/", .{home});

    var whitelisted_paths = try allocator.alloc(WhitelistedPath, 5);
    whitelisted_paths[0] = WhitelistedPath{ .path = "/proc/self/", .description = "Process-specific" };
    whitelisted_paths[1] = WhitelistedPath{ .path = "/tmp/", .description = "Temporary directory" };
    whitelisted_paths[2] = WhitelistedPath{ .path = user_tmp, .description = "User temp" };
    whitelisted_paths[3] = WhitelistedPath{ .path = user_sandbox, .description = "Sandbox" };
    whitelisted_paths[4] = WhitelistedPath{ .path = user_claude, .description = "Claude Code directory" };

    return Config{
        .global = GlobalConfig{},
        .protected_paths = protected_paths,
        .whitelisted_paths = whitelisted_paths,
        .directory_protection = DirectoryProtection{
            .protected_roots = &[_][]const u8{},
            .protected_patterns = &[_][]const u8{},
        },
        .process_exemptions = ProcessExemptions{},
        .process_restrictions = ProcessRestrictionConfig{},
        .advanced = AdvancedConfig{},
        .allocator = allocator,
    };
}
