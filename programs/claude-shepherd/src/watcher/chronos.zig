//! Chronos Log Watcher for claude-shepherd
//!
//! Monitors chronos log files for Claude Code activity.
//! Parses timestamps, PIDs, and task information to track active instances.

const std = @import("std");
const State = @import("../state.zig").State;

// C library imports for getenv and file operations
const c = @cImport({
    @cInclude("stdlib.h");
    @cInclude("fcntl.h");
    @cInclude("unistd.h");
});

fn getenvCompat(name: []const u8) ?[]const u8 {
    var name_buf: [256]u8 = undefined;
    if (name.len >= name_buf.len) return null;
    @memcpy(name_buf[0..name.len], name);
    name_buf[name.len] = 0;
    const ptr = c.getenv(@ptrCast(&name_buf));
    if (ptr) |p| {
        return std.mem.sliceTo(p, 0);
    }
    return null;
}
const ClaudeInstance = @import("../state.zig").ClaudeInstance;

// C functions
extern "c" fn time(t: ?*i64) i64;
extern "c" fn lseek(fd: c_int, offset: i64, whence: c_int) i64;
const SEEK_SET: c_int = 0;

// Stat structure (simplified, just need ino)
const Stat = extern struct {
    st_dev: u64,
    st_ino: u64,
    st_nlink: u64,
    st_mode: u32,
    st_uid: u32,
    st_gid: u32,
    __pad0: u32,
    st_rdev: u64,
    st_size: i64,
    st_blksize: i64,
    st_blocks: i64,
    st_atime: i64,
    st_atime_nsec: i64,
    st_mtime: i64,
    st_mtime_nsec: i64,
    st_ctime: i64,
    st_ctime_nsec: i64,
    __unused: [3]i64,
};
extern "c" fn fstat(fd: c_int, buf: *Stat) c_int;

/// Parsed chronos log entry
pub const ChronosEntry = struct {
    timestamp: i64,
    source: []const u8,
    message: []const u8,
    tick: u64,
    working_dir: []const u8,
    base_dir: []const u8,
    pid: u32,
    event_type: EventType,

    pub const EventType = enum {
        start,
        tool_call,
        tool_completion,
        permission_request,
        user_input,
        completion,
        unknown,
    };
};

pub const ChronosWatcher = struct {
    allocator: std.mem.Allocator,
    state: *State,
    log_path: []const u8,
    last_position: u64,
    last_inode: u64,
    known_pids: std.AutoHashMapUnmanaged(u32, bool),

    const DEFAULT_LOG_PATH = "/var/log/chronos";
    const CLAUDE_LOG_PATTERN = "claude-code";

    pub fn init(allocator: std.mem.Allocator, state: *State) !ChronosWatcher {
        // Determine log path from environment or default
        const log_path = getenvCompat("CHRONOS_LOG_PATH") orelse DEFAULT_LOG_PATH;

        return ChronosWatcher{
            .allocator = allocator,
            .state = state,
            .log_path = log_path,
            .last_position = 0,
            .last_inode = 0,
            .known_pids = .{},
        };
    }

    pub fn deinit(self: *ChronosWatcher) void {
        self.known_pids.deinit(self.allocator);
    }

    /// Poll for new log entries
    pub fn poll(self: *ChronosWatcher) !void {
        // Find current log file
        const fd = self.findCurrentLog() catch {
            return; // No log file available
        };
        defer _ = c.close(fd);

        // Check if file rotated (inode changed) using fstat
        var stat: Stat = undefined;
        if (fstat(@intCast(fd), &stat) != 0) return;
        if (stat.st_ino != self.last_inode) {
            self.last_position = 0;
            self.last_inode = stat.st_ino;
        }

        // Seek to last position
        _ = lseek(@intCast(fd), @intCast(self.last_position), SEEK_SET);

        // Read new entries
        var buf: [8192]u8 = undefined;
        while (true) {
            const n_raw = c.read(fd, &buf, buf.len);
            if (n_raw <= 0) break;
            const n: usize = @intCast(n_raw);

            // Process lines
            var start: usize = 0;
            for (buf[0..n], 0..) |ch, i| {
                if (ch == '\n') {
                    const line = buf[start..i];
                    self.processLine(line) catch {};
                    start = i + 1;
                }
            }

            self.last_position += n;
        }

        // Check for dead processes
        try self.cleanupDeadProcesses();
    }

    fn findCurrentLog(self: *ChronosWatcher) !c_int {
        // Try to open the main chronos log directory
        var path_buf: [512]u8 = undefined;

        // First try today's date-based log
        const timestamp = time(null);
        const days_since_epoch = @divFloor(timestamp, 86400);
        _ = days_since_epoch;

        // Try common log locations
        const paths = [_][]const u8{
            self.log_path,
            "/tmp/chronos.log",
            "/var/log/chronos/current.log",
        };

        for (paths) |path| {
            const path_z = std.fmt.bufPrintZ(&path_buf, "{s}", .{path}) catch continue;
            const fd = c.open(@ptrCast(path_z.ptr), c.O_RDONLY, @as(c_uint, 0));
            if (fd >= 0) return fd;
        }

        return error.NoLogFile;
    }

    fn processLine(self: *ChronosWatcher, line: []const u8) !void {
        // Parse chronos log format:
        // [CHRONOS] TIMESTAMP::SOURCE::MESSAGE::TICK-NNNN::[WORKING_DIR]::[BASE_DIR]::PID-NNNN
        if (!std.mem.startsWith(u8, line, "[CHRONOS]")) {
            return;
        }

        // Check if this is a claude-code entry
        if (std.mem.indexOf(u8, line, "claude-code") == null) {
            return;
        }

        // Extract PID
        const pid = self.extractPid(line) orelse return;

        // Extract event type and message
        const event_type = self.detectEventType(line);

        // Extract working directory
        const working_dir = self.extractWorkingDir(line) orelse "/tmp";

        // Extract task description from message
        const message = self.extractMessage(line) orelse "Unknown task";

        // Update state based on event type
        switch (event_type) {
            .start => {
                // New Claude instance started
                try self.state.addInstance(pid, message, working_dir);
                try self.known_pids.put(self.allocator, pid, true);
            },
            .completion => {
                // Claude instance completed
                self.state.updateInstance(pid, .completed);
                _ = self.known_pids.remove(pid);
            },
            .permission_request => {
                // Permission request detected
                const cmd = self.extractCommand(line) orelse "unknown";
                const args = self.extractArgs(line) orelse "";
                _ = try self.state.addPermissionRequest(pid, cmd, args, message);
            },
            .tool_call, .tool_completion, .user_input => {
                // Activity - update last_activity timestamp
                self.state.updateInstance(pid, .running);
            },
            .unknown => {},
        }
    }

    fn detectEventType(self: *ChronosWatcher, line: []const u8) ChronosEntry.EventType {
        _ = self;

        if (std.mem.indexOf(u8, line, "→ start") != null or
            std.mem.indexOf(u8, line, "starting") != null)
        {
            return .start;
        }

        if (std.mem.indexOf(u8, line, "→ complete") != null or
            std.mem.indexOf(u8, line, "→ done") != null or
            std.mem.indexOf(u8, line, "finished") != null)
        {
            return .completion;
        }

        if (std.mem.indexOf(u8, line, "permission") != null or
            std.mem.indexOf(u8, line, "Permission") != null or
            std.mem.indexOf(u8, line, "approval") != null)
        {
            return .permission_request;
        }

        if (std.mem.indexOf(u8, line, "tool-call") != null or
            std.mem.indexOf(u8, line, "→ tool") != null)
        {
            return .tool_call;
        }

        if (std.mem.indexOf(u8, line, "tool-completion") != null or
            std.mem.indexOf(u8, line, "tool completed") != null)
        {
            return .tool_completion;
        }

        if (std.mem.indexOf(u8, line, "user-input") != null or
            std.mem.indexOf(u8, line, "user input") != null)
        {
            return .user_input;
        }

        return .unknown;
    }

    fn extractPid(self: *ChronosWatcher, line: []const u8) ?u32 {
        _ = self;

        // Look for PID-NNNN pattern
        const pid_marker = "PID-";
        const idx = std.mem.indexOf(u8, line, pid_marker) orelse return null;
        const start = idx + pid_marker.len;

        // Extract digits
        var end = start;
        while (end < line.len and line[end] >= '0' and line[end] <= '9') {
            end += 1;
        }

        if (end == start) return null;

        return std.fmt.parseInt(u32, line[start..end], 10) catch null;
    }

    fn extractWorkingDir(self: *ChronosWatcher, line: []const u8) ?[]const u8 {
        _ = self;

        // Look for ::[/path]:: pattern
        var i: usize = 0;
        while (i + 4 < line.len) {
            if (line[i] == ':' and line[i + 1] == ':' and line[i + 2] == '[' and line[i + 3] == '/') {
                const start = i + 3;
                var end = start;
                while (end < line.len and line[end] != ']') {
                    end += 1;
                }
                if (end > start) {
                    return line[start..end];
                }
            }
            i += 1;
        }

        return null;
    }

    fn extractMessage(self: *ChronosWatcher, line: []const u8) ?[]const u8 {
        _ = self;

        // Message is between second and third ::
        var count: usize = 0;
        var start: usize = 0;
        var i: usize = 0;

        while (i + 1 < line.len) {
            if (line[i] == ':' and line[i + 1] == ':') {
                count += 1;
                if (count == 2) {
                    start = i + 2;
                } else if (count == 3) {
                    if (i > start) {
                        return line[start..i];
                    }
                    break;
                }
                i += 2;
            } else {
                i += 1;
            }
        }

        return null;
    }

    fn extractCommand(self: *ChronosWatcher, line: []const u8) ?[]const u8 {
        _ = self;

        // Look for common command patterns
        const commands = [_][]const u8{ "rm", "mv", "cp", "sudo", "chmod", "git", "npm", "curl" };
        for (commands) |cmd| {
            if (std.mem.indexOf(u8, line, cmd) != null) {
                return cmd;
            }
        }
        return null;
    }

    fn extractArgs(self: *ChronosWatcher, line: []const u8) ?[]const u8 {
        _ = self;
        // TODO: Better args extraction
        return line;
    }

    fn cleanupDeadProcesses(self: *ChronosWatcher) !void {
        // Check if known PIDs are still running
        var dead_pids = std.ArrayListUnmanaged(u32).empty;
        defer dead_pids.deinit(self.allocator);

        var it = self.known_pids.iterator();
        while (it.next()) |entry| {
            const pid = entry.key_ptr.*;

            // Check if process exists using kill(pid, 0)
            if (!self.isProcessRunning(pid)) {
                try dead_pids.append(self.allocator, pid);
            }
        }

        // Remove dead processes from state
        for (dead_pids.items) |pid| {
            self.state.updateInstance(pid, .completed);
            self.state.removeInstance(pid);
            _ = self.known_pids.remove(pid);
        }
    }

    fn isProcessRunning(self: *ChronosWatcher, pid: u32) bool {
        _ = self;

        // Use kill(pid, 0) to check if process exists
        // This doesn't send any signal, just checks existence
        var path_buf: [64]u8 = undefined;
        const path = std.fmt.bufPrintZ(&path_buf, "/proc/{d}", .{pid}) catch return false;

        const fd = c.open(@ptrCast(path.ptr), c.O_RDONLY, @as(c_uint, 0));
        if (fd >= 0) {
            _ = c.close(fd);
            return true;
        }
        return false;
    }

    /// Manually register a Claude instance (for testing or manual tracking)
    pub fn registerInstance(self: *ChronosWatcher, pid: u32, task: []const u8, working_dir: []const u8) !void {
        try self.state.addInstance(pid, task, working_dir);
        try self.known_pids.put(self.allocator, pid, true);
    }

    /// Get count of tracked instances
    pub fn getTrackedCount(self: *ChronosWatcher) usize {
        return self.known_pids.count();
    }
};

test "chronos watcher init" {
    const allocator = std.testing.allocator;
    var state = try State.init(allocator);
    defer state.deinit();

    var watcher = try ChronosWatcher.init(allocator, &state);
    defer watcher.deinit();

    try std.testing.expectEqual(@as(usize, 0), watcher.getTrackedCount());
}

test "pid extraction" {
    const allocator = std.testing.allocator;
    var state = try State.init(allocator);
    defer state.deinit();

    var watcher = try ChronosWatcher.init(allocator, &state);
    defer watcher.deinit();

    const line = "[CHRONOS] 2025-01-05::claude-code::test::TICK-0001::[/home]::[/home]::PID-12345";
    const pid = watcher.extractPid(line);
    try std.testing.expect(pid != null);
    try std.testing.expectEqual(@as(u32, 12345), pid.?);
}
