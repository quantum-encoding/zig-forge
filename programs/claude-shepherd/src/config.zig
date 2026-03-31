//! Configuration loading and management for claude-shepherd

const std = @import("std");
const posix = std.posix;

pub const Config = struct {
    log_level: LogLevel = .info,
    chronos_log_path: []const u8 = "/var/log/chronos",
    socket_path: []const u8 = "/tmp/claude-shepherd.sock",
    poll_interval_ms: u32 = 100,
    max_concurrent_claudes: u32 = 8,
    auto_approve_timeout_ms: u32 = 30000,

    pub const LogLevel = enum {
        debug,
        info,
        warn,
        @"error",
    };

    pub fn load(allocator: std.mem.Allocator, path: ?[]const u8) !Config {
        const config_path = path orelse blk: {
            // Default: ~/.config/claude-shepherd/config.json
            const home = std.posix.getenv("HOME") orelse "/tmp";
            break :blk try std.fmt.allocPrint(allocator, "{s}/.config/claude-shepherd/config.json", .{home});
        };
        defer if (path == null) allocator.free(config_path);

        // Try to read config file
        const file = std.fs.cwd().openFile(config_path, .{}) catch {
            // Return defaults if file doesn't exist
            return Config{};
        };
        defer file.close();

        var buf: [8192]u8 = undefined;
        const n = file.read(&buf) catch return Config{};
        if (n == 0) return Config{};

        // Parse JSON manually (simplified)
        var cfg = Config{};

        // Look for poll_interval_ms
        if (std.mem.indexOf(u8, buf[0..n], "\"poll_interval_ms\":")) |idx| {
            const start = idx + 19;
            var end = start;
            while (end < n and (buf[end] >= '0' and buf[end] <= '9')) : (end += 1) {}
            if (end > start) {
                cfg.poll_interval_ms = std.fmt.parseInt(u32, buf[start..end], 10) catch 100;
            }
        }

        // Look for max_concurrent_claudes
        if (std.mem.indexOf(u8, buf[0..n], "\"max_concurrent_claudes\":")) |idx| {
            const start = idx + 25;
            var end = start;
            while (end < n and (buf[end] >= '0' and buf[end] <= '9')) : (end += 1) {}
            if (end > start) {
                cfg.max_concurrent_claudes = std.fmt.parseInt(u32, buf[start..end], 10) catch 8;
            }
        }

        return cfg;
    }

    pub fn save(self: *const Config, allocator: std.mem.Allocator, path: []const u8) !void {
        _ = allocator;
        // Serialize config to JSON and write to file
        var buf: [2048]u8 = undefined;
        const json = std.fmt.bufPrint(&buf,
            \\{{
            \\  "log_level": "{s}",
            \\  "chronos_log_path": "{s}",
            \\  "socket_path": "{s}",
            \\  "poll_interval_ms": {d},
            \\  "max_concurrent_claudes": {d},
            \\  "auto_approve_timeout_ms": {d}
            \\}}
        , .{
            @tagName(self.log_level),
            self.chronos_log_path,
            self.socket_path,
            self.poll_interval_ms,
            self.max_concurrent_claudes,
            self.auto_approve_timeout_ms,
        }) catch return error.OutOfMemory;

        // Ensure parent directory exists
        const dir_end = std.mem.lastIndexOf(u8, path, "/");
        if (dir_end) |end| {
            const dir_path = path[0..end];
            std.fs.cwd().makePath(dir_path) catch {};
        }

        var file = try std.fs.cwd().createFile(path, .{});
        defer file.close();
        try file.writeAll(json);
    }
};

pub const PolicyConfig = struct {
    always_allow: std.ArrayListUnmanaged(Rule) = .empty,
    always_prompt: std.ArrayListUnmanaged(Rule) = .empty,
    auto_approve: std.ArrayListUnmanaged(AutoApprove) = .empty,

    pub const Rule = struct {
        cmd: []const u8,
        args: ?[]const u8 = null,
        pattern: ?[]const u8 = null,
        condition: ?[]const u8 = null,
        reason: ?[]const u8 = null,
    };

    pub const AutoApprove = struct {
        pattern: []const u8,
        scope: Scope = .session,
        count: ?u32 = null,

        pub const Scope = enum {
            session,
            permanent,
            count_limited,
        };
    };

    pub fn load(allocator: std.mem.Allocator) !PolicyConfig {
        var cfg = PolicyConfig{};

        // Default always_allow rules
        try cfg.always_allow.append(allocator, .{ .cmd = "zig", .args = "build *" });
        try cfg.always_allow.append(allocator, .{ .cmd = "cat" });
        try cfg.always_allow.append(allocator, .{ .cmd = "ls" });
        try cfg.always_allow.append(allocator, .{ .cmd = "tree" });
        try cfg.always_allow.append(allocator, .{ .cmd = "find" });
        try cfg.always_allow.append(allocator, .{ .cmd = "head" });
        try cfg.always_allow.append(allocator, .{ .cmd = "tail" });
        try cfg.always_allow.append(allocator, .{ .pattern = "./zig-out/bin/*" });

        // Default always_prompt rules
        try cfg.always_prompt.append(allocator, .{ .cmd = "rm", .reason = "destructive operation" });
        try cfg.always_prompt.append(allocator, .{ .cmd = "sudo", .reason = "privilege escalation" });
        try cfg.always_prompt.append(allocator, .{ .cmd = "mv", .args = "dest_outside_project", .reason = "file movement" });

        return cfg;
    }

    pub fn deinit(self: *PolicyConfig, allocator: std.mem.Allocator) void {
        self.always_allow.deinit(allocator);
        self.always_prompt.deinit(allocator);
        self.auto_approve.deinit(allocator);
    }
};

pub const QueueConfig = struct {
    pending_tasks: std.ArrayListUnmanaged(Task) = .empty,
    pre_responses: std.StringHashMapUnmanaged([]const u8) = .empty,

    pub const Task = struct {
        id: u64,
        prompt: []const u8,
        status: Status,
        depends_on: ?u64 = null,
        pre_response: ?[]const u8 = null,

        pub const Status = enum {
            queued,
            running,
            completed,
            failed,
        };
    };

    pub fn load(allocator: std.mem.Allocator) !QueueConfig {
        _ = allocator;
        return QueueConfig{};
    }

    pub fn deinit(self: *QueueConfig, allocator: std.mem.Allocator) void {
        self.pending_tasks.deinit(allocator);
        self.pre_responses.deinit(allocator);
    }
};

test "Config defaults" {
    const cfg = Config{};
    try std.testing.expectEqual(@as(u32, 100), cfg.poll_interval_ms);
    try std.testing.expectEqual(@as(u32, 8), cfg.max_concurrent_claudes);
}
