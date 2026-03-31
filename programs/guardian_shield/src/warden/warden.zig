//! Guardian Shield V8.0 - Embeddable Protection Module
//!
//! This module provides programmatic control over Guardian Shield protection
//! for processes spawned from your application.
//!
//! Usage:
//! ```zig
//! const warden = @import("warden");
//!
//! pub fn main() !void {
//!     // Protect a directory before spawning untrusted code
//!     try warden.protect("/data/sensitive", .{ .read_only = true });
//!
//!     // Spawn child with inherited protection
//!     const child = try warden.spawnProtected(&.{"./untrusted-binary"}, .{
//!         .inherit_rules = true,
//!         .additional_rules = &.{
//!             .{ .path = "/tmp", .flags = .{ .no_execute = true } },
//!         },
//!     });
//!
//!     // Or use scoped protection
//!     {
//!         var guard = try warden.ScopedProtection.init("/secrets", .{ .read_only = true });
//!         defer guard.deinit();
//!         // ... do sensitive operations
//!     }
//! }
//! ```

const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;

const c = @cImport({
    @cInclude("fcntl.h");
    @cInclude("unistd.h");
});

/// Protection flags for a path
pub const ProtectionFlags = packed struct {
    no_delete: bool = false,
    no_move: bool = false,
    no_write: bool = false,
    no_truncate: bool = false,
    no_symlink: bool = false,
    no_hardlink: bool = false,
    no_mkdir: bool = false,
    no_execute: bool = false,
    read_only: bool = false, // Shorthand for no_write + no_delete + no_move + no_truncate
    _padding: u7 = 0,

    pub fn toConfigString(self: ProtectionFlags, buf: []u8) []const u8 {
        var written: usize = 0;

        const ops_list = [_]struct { flag: bool, name: []const u8 }{
            .{ .flag = self.read_only or self.no_delete, .name = "unlink" },
            .{ .flag = self.read_only or self.no_delete, .name = "unlinkat" },
            .{ .flag = self.read_only or self.no_delete, .name = "rmdir" },
            .{ .flag = self.read_only or self.no_write, .name = "open_write" },
            .{ .flag = self.read_only or self.no_move, .name = "rename" },
            .{ .flag = self.read_only or self.no_truncate, .name = "truncate" },
            .{ .flag = self.no_symlink, .name = "symlink" },
            .{ .flag = self.no_hardlink, .name = "link" },
            .{ .flag = self.no_mkdir, .name = "mkdir" },
        };

        var first = true;
        for (ops_list) |entry| {
            if (entry.flag) {
                if (!first) {
                    buf[written] = ',';
                    written += 1;
                }
                first = false;
                @memcpy(buf[written..][0..entry.name.len], entry.name);
                written += entry.name.len;
            }
        }
        return buf[0..written];
    }
};

/// A single protection rule
pub const ProtectionRule = struct {
    path: []const u8,
    flags: ProtectionFlags,
    description: ?[]const u8 = null,
};

/// Options for spawning protected child processes
pub const SpawnOptions = struct {
    inherit_rules: bool = true,
    additional_rules: ?[]const ProtectionRule = null,
    clear_parent_rules: bool = false,
    env: ?*const [*:0]const u8 = null,
    cwd: ?[]const u8 = null,
};

/// Runtime protection state
var runtime_rules: std.ArrayListUnmanaged(ProtectionRule) = .empty;
var initialized: bool = false;
var allocator: std.mem.Allocator = undefined;

/// Initialize the warden module
pub fn init(alloc: std.mem.Allocator) !void {
    if (initialized) return;
    allocator = alloc;
    runtime_rules = .{};
    initialized = true;
}

/// Deinitialize and free resources
pub fn deinit() void {
    if (!initialized) return;
    runtime_rules.deinit(allocator);
    initialized = false;
}

/// Add runtime protection for a path
/// This writes to a runtime config that libwarden reads
pub fn protect(path: []const u8, flags: ProtectionFlags) !void {
    if (!initialized) return error.NotInitialized;

    const rule = ProtectionRule{
        .path = try allocator.dupe(u8, path),
        .flags = flags,
    };
    try runtime_rules.append(allocator, rule);

    // Write to runtime config for libwarden to pick up
    try writeRuntimeConfig();

    // Signal libwarden to reload (SIGHUP)
    try signalReload();
}

/// Remove protection from a path
pub fn unprotect(path: []const u8) !void {
    if (!initialized) return error.NotInitialized;

    var i: usize = 0;
    while (i < runtime_rules.items.len) {
        if (std.mem.eql(u8, runtime_rules.items[i].path, path)) {
            allocator.free(runtime_rules.items[i].path);
            _ = runtime_rules.swapRemove(i);
        } else {
            i += 1;
        }
    }

    writeRuntimeConfig() catch {};
    signalReload() catch {};
}

/// Get current protection rules
pub fn getRules() []const ProtectionRule {
    if (!initialized) return &.{};
    return runtime_rules.items;
}

/// Spawn a child process with protection
pub fn spawnProtected(argv: []const []const u8, options: SpawnOptions) !std.process.Child {
    if (!initialized) return error.NotInitialized;

    // Build environment with LD_PRELOAD
    var env_map = std.process.EnvMap.init(allocator);
    defer env_map.deinit();

    // Copy current environment
    const current_env = std.process.getEnvMap(allocator) catch std.process.EnvMap.init(allocator);
    defer current_env.deinit();

    var iter = current_env.iterator();
    while (iter.next()) |entry| {
        try env_map.put(entry.key_ptr.*, entry.value_ptr.*);
    }

    // Ensure LD_PRELOAD is set
    const preload_path = "/usr/local/lib/security/libwarden.so";
    if (env_map.get("LD_PRELOAD")) |existing| {
        if (std.mem.indexOf(u8, existing, preload_path) == null) {
            var buf: [512]u8 = undefined;
            const new_preload = std.fmt.bufPrint(&buf, "{s}:{s}", .{ preload_path, existing }) catch preload_path;
            try env_map.put("LD_PRELOAD", new_preload);
        }
    } else {
        try env_map.put("LD_PRELOAD", preload_path);
    }

    // If additional rules specified, write them to a child-specific config
    if (options.additional_rules) |rules| {
        const pid = std.os.linux.getpid();
        var path_buf: [128]u8 = undefined;
        const child_config = std.fmt.bufPrint(&path_buf, "/tmp/warden-child-{d}.json", .{pid}) catch "/tmp/warden-child.json";
        try writeChildConfig(child_config, rules, options.inherit_rules);
        try env_map.put("WARDEN_CONFIG", child_config);
    }

    // Spawn the child
    var child = std.process.Child.init(argv, allocator);
    child.env_map = &env_map;
    if (options.cwd) |cwd| {
        child.cwd = cwd;
    }

    try child.spawn();
    return child;
}

/// Scoped protection - automatically removes protection when scope exits
pub const ScopedProtection = struct {
    path: []const u8,

    pub fn init(path: []const u8, flags: ProtectionFlags) !ScopedProtection {
        try protect(path, flags);
        return ScopedProtection{ .path = path };
    }

    pub fn deinit(self: *ScopedProtection) void {
        unprotect(self.path) catch {};
    }
};

/// Check if a path is currently protected
pub fn isProtected(path: []const u8) bool {
    if (!initialized) return false;

    for (runtime_rules.items) |rule| {
        if (std.mem.startsWith(u8, path, rule.path)) {
            return true;
        }
    }
    return false;
}

/// Check if an operation would be blocked
pub fn wouldBlock(path: []const u8, operation: Operation) bool {
    if (!initialized) return false;

    for (runtime_rules.items) |rule| {
        if (std.mem.startsWith(u8, path, rule.path)) {
            return switch (operation) {
                .delete => rule.flags.no_delete or rule.flags.read_only,
                .write => rule.flags.no_write or rule.flags.read_only,
                .move => rule.flags.no_move or rule.flags.read_only,
                .truncate => rule.flags.no_truncate or rule.flags.read_only,
                .symlink => rule.flags.no_symlink,
                .hardlink => rule.flags.no_hardlink,
                .mkdir => rule.flags.no_mkdir,
                .execute => rule.flags.no_execute,
            };
        }
    }
    return false;
}

pub const Operation = enum {
    delete,
    write,
    move,
    truncate,
    symlink,
    hardlink,
    mkdir,
    execute,
};

// ============================================================
// Internal functions
// ============================================================

fn writeToFd(fd: c_int, data: []const u8) void {
    _ = c.write(fd, data.ptr, data.len);
}

fn writeRuntimeConfig() !void {
    const runtime_config_path = "/tmp/warden-runtime.json";
    const fd = c.open(runtime_config_path, c.O_WRONLY | c.O_CREAT | c.O_TRUNC, @as(c_uint, 0o644));
    if (fd < 0) return error.OpenFailed;
    defer _ = c.close(fd);

    writeToFd(fd, "{\n");
    writeToFd(fd, "  \"_comment\": \"Runtime protection rules from embedded warden module\",\n");
    writeToFd(fd, "  \"runtime_rules\": [\n");

    for (runtime_rules.items, 0..) |rule, i| {
        if (i > 0) writeToFd(fd, ",\n");
        writeToFd(fd, "    {\n");

        var path_buf: [512]u8 = undefined;
        const path_line = std.fmt.bufPrint(&path_buf, "      \"path\": \"{s}\",\n", .{rule.path}) catch continue;
        writeToFd(fd, path_line);

        var ops_buf: [256]u8 = undefined;
        const ops = rule.flags.toConfigString(&ops_buf);
        var ops_line_buf: [512]u8 = undefined;
        const ops_line = std.fmt.bufPrint(&ops_line_buf, "      \"block_operations\": \"{s}\"", .{ops}) catch "";
        writeToFd(fd, ops_line);

        if (rule.description) |desc| {
            var desc_buf: [512]u8 = undefined;
            const desc_line = std.fmt.bufPrint(&desc_buf, ",\n      \"description\": \"{s}\"", .{desc}) catch "";
            writeToFd(fd, desc_line);
        }
        writeToFd(fd, "\n    }");
    }

    writeToFd(fd, "\n  ]\n}\n");
}

fn writeChildConfig(config_path: []const u8, rules: []const ProtectionRule, inherit: bool) !void {
    // Create null-terminated path
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    if (config_path.len >= path_buf.len) return error.NameTooLong;
    @memcpy(path_buf[0..config_path.len], config_path);
    path_buf[config_path.len] = 0;

    const fd = try std.posix.open(path_buf[0..config_path.len :0], .{
        .ACCMODE = .WRONLY,
        .CREAT = true,
        .TRUNC = true,
    }, 0o644);
    defer _ = std.c.close(fd);

    writeToFd(fd, "{\n");
    writeToFd(fd, "  \"_comment\": \"Child process protection rules\",\n");

    var inherit_buf: [64]u8 = undefined;
    const inherit_line = std.fmt.bufPrint(&inherit_buf, "  \"inherit_parent\": {s},\n", .{if (inherit) "true" else "false"}) catch "";
    writeToFd(fd, inherit_line);

    writeToFd(fd, "  \"protection\": {\n");
    writeToFd(fd, "    \"protected_paths\": [\n");

    for (rules, 0..) |rule, i| {
        if (i > 0) writeToFd(fd, ",\n");
        writeToFd(fd, "      {\n");

        var rule_path_buf: [512]u8 = undefined;
        const path_line = std.fmt.bufPrint(&rule_path_buf, "        \"path\": \"{s}\",\n", .{rule.path}) catch continue;
        writeToFd(fd, path_line);

        var ops_buf: [256]u8 = undefined;
        const ops = rule.flags.toConfigString(&ops_buf);
        var ops_line_buf: [512]u8 = undefined;
        const ops_line = std.fmt.bufPrint(&ops_line_buf, "        \"block_operations\": [\"{s}\"]", .{ops}) catch "";
        writeToFd(fd, ops_line);

        if (rule.description) |desc| {
            var desc_buf: [512]u8 = undefined;
            const desc_line = std.fmt.bufPrint(&desc_buf, ",\n        \"description\": \"{s}\"", .{desc}) catch "";
            writeToFd(fd, desc_line);
        }
        writeToFd(fd, "\n      }");
    }

    writeToFd(fd, "\n    ]\n  }\n}\n");
}

fn signalReload() !void {
    // Find processes with libwarden loaded and send SIGHUP
    // For now, just set an env flag that libwarden checks
    const reload_flag = "/tmp/warden-reload-flag";
    const fd = c.open(reload_flag, c.O_WRONLY | c.O_CREAT | c.O_TRUNC, @as(c_uint, 0o644));
    if (fd < 0) return;
    _ = c.close(fd);
}

// ============================================================
// Tests
// ============================================================

test "protection flags" {
    const flags = ProtectionFlags{ .read_only = true };
    var buf: [256]u8 = undefined;
    const ops = flags.toConfigString(&buf);
    try std.testing.expect(ops.len > 0);
}

test "init and deinit" {
    try init(std.testing.allocator);
    defer deinit();

    try protect("/test/path", .{ .no_delete = true });
    try std.testing.expect(isProtected("/test/path/file.txt"));
    try std.testing.expect(!isProtected("/other/path"));
}
