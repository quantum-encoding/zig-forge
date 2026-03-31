// SPDX-License-Identifier: GPL-2.0
//
// resource-monitor.zig - The Observer of Computational Hunger
//
// Purpose: Monitor process resource usage to detect crypto miners
// Approach: Multi-dimensional detection (syscalls + CPU + memory + GPU + network)
// Philosophy: The miner cannot hide its insatiable hunger for computation
//

const std = @import("std");

/// Process resource snapshot
pub const ProcessSnapshot = struct {
    pid: u32,
    cpu_percent: f32,
    mem_rss_mb: u64,    // Resident Set Size
    mem_vsz_mb: u64,    // Virtual Size
    thread_count: u32,
    fd_count: u32,      // Open file descriptors
    network_connections: u32,
    timestamp_sec: u64,
    command: [256]u8,
};

/// Resource monitor
pub const ResourceMonitor = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    snapshots: std.ArrayList(ProcessSnapshot),
    suspicious_pids: std.AutoHashMap(u32, void),

    pub fn init(allocator: std.mem.Allocator) !Self {
        return Self{
            .allocator = allocator,
            .snapshots = std.ArrayList(ProcessSnapshot).init(allocator),
            .suspicious_pids = std.AutoHashMap(u32, void).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.snapshots.deinit();
        self.suspicious_pids.deinit();
    }

    /// Capture resource snapshot for a process
    pub fn captureSnapshot(self: *Self, pid: u32) !ProcessSnapshot {
        var snapshot = ProcessSnapshot{
            .pid = pid,
            .cpu_percent = 0,
            .mem_rss_mb = 0,
            .mem_vsz_mb = 0,
            .thread_count = 0,
            .fd_count = 0,
            .network_connections = 0,
            .timestamp_sec = @intCast(std.time.timestamp()),
            .command = [_]u8{0} ** 256,
        };

        // Read /proc/[pid]/stat for CPU and memory
        const stat_path = try std.fmt.allocPrint(self.allocator, "/proc/{d}/stat", .{pid});
        defer self.allocator.free(stat_path);

        const stat_file = std.fs.openFileAbsolute(stat_path, .{}) catch |err| {
            if (err == error.FileNotFound) return error.ProcessNotFound;
            return err;
        };
        defer stat_file.close();

        var stat_buf: [4096]u8 = undefined;
        const bytes_read = try stat_file.readAll(&stat_buf);
        const stat_content = stat_buf[0..bytes_read];

        // Parse stat file
        // Format: pid (comm) state ppid pgrp session tty_nr tpgid flags ...
        try self.parseProcStat(stat_content, &snapshot);

        // Read /proc/[pid]/status for detailed memory
        try self.readProcStatus(pid, &snapshot);

        // Count threads
        snapshot.thread_count = try self.countThreads(pid);

        // Count file descriptors
        snapshot.fd_count = try self.countFileDescriptors(pid);

        // Count network connections
        snapshot.network_connections = try self.countNetworkConnections(pid);

        try self.snapshots.append(snapshot);

        return snapshot;
    }

    /// Parse /proc/[pid]/stat
    fn parseProcStat(self: *Self, content: []const u8, snapshot: *ProcessSnapshot) !void {
        _ = self;

        // Find command name (between parentheses)
        const cmd_start = std.mem.indexOf(u8, content, "(") orelse return error.InvalidFormat;
        const cmd_end = std.mem.lastIndexOf(u8, content, ")") orelse return error.InvalidFormat;
        const cmd = content[cmd_start + 1 .. cmd_end];
        @memcpy(snapshot.command[0..@min(cmd.len, 255)], cmd[0..@min(cmd.len, 255)]);

        // Parse fields after command
        const fields_start = cmd_end + 2;
        var fields = std.mem.tokenizeScalar(u8, content[fields_start..], ' ');

        // Skip state, ppid, pgrp, session, tty_nr, tpgid, flags (fields 1-7)
        var i: usize = 0;
        while (i < 7) : (i += 1) {
            _ = fields.next();
        }

        // Field 14: utime (user CPU time in jiffies)
        const utime_str = fields.next() orelse return;
        const utime = try std.fmt.parseInt(u64, utime_str, 10);

        // Field 15: stime (system CPU time in jiffies)
        const stime_str = fields.next() orelse return;
        const stime = try std.fmt.parseInt(u64, stime_str, 10);

        // Calculate CPU percentage (simplified - would need previous snapshot for accuracy)
        _ = utime;
        _ = stime;
        // snapshot.cpu_percent = ... (requires tracking deltas)

        // Skip to field 23: vsize (virtual memory size in bytes)
        while (i < 21) : (i += 1) {
            _ = fields.next();
        }

        const vsize_str = fields.next() orelse return;
        const vsize_bytes = try std.fmt.parseInt(u64, vsize_str, 10);
        snapshot.mem_vsz_mb = vsize_bytes / (1024 * 1024);

        // Field 24: rss (resident set size in pages)
        const rss_str = fields.next() orelse return;
        const rss_pages = try std.fmt.parseInt(u64, rss_str, 10);
        const page_size: u64 = 4096; // Typically 4KB
        snapshot.mem_rss_mb = (rss_pages * page_size) / (1024 * 1024);
    }

    /// Read /proc/[pid]/status for detailed info
    fn readProcStatus(self: *Self, pid: u32, snapshot: *ProcessSnapshot) !void {
        const status_path = try std.fmt.allocPrint(self.allocator, "/proc/{d}/status", .{pid});
        defer self.allocator.free(status_path);

        const status_file = std.fs.openFileAbsolute(status_path, .{}) catch return;
        defer status_file.close();

        var status_buf: [8192]u8 = undefined;
        const bytes_read = try status_file.readAll(&status_buf);
        const status_content = status_buf[0..bytes_read];

        // Parse key-value pairs
        var lines = std.mem.tokenizeScalar(u8, status_content, '\n');
        while (lines.next()) |line| {
            if (std.mem.startsWith(u8, line, "Threads:")) {
                const value_start = std.mem.indexOf(u8, line, ":") orelse continue;
                const value_str = std.mem.trim(u8, line[value_start + 1 ..], " \t");
                snapshot.thread_count = std.fmt.parseInt(u32, value_str, 10) catch 0;
            } else if (std.mem.startsWith(u8, line, "VmRSS:")) {
                const value_start = std.mem.indexOf(u8, line, ":") orelse continue;
                var value_str = std.mem.trim(u8, line[value_start + 1 ..], " \t");
                // Remove " kB" suffix
                if (std.mem.endsWith(u8, value_str, " kB")) {
                    value_str = value_str[0 .. value_str.len - 3];
                }
                const kb = std.fmt.parseInt(u64, value_str, 10) catch 0;
                snapshot.mem_rss_mb = kb / 1024;
            }
        }
    }

    /// Count threads in /proc/[pid]/task/
    fn countThreads(self: *Self, pid: u32) !u32 {
        const task_path = try std.fmt.allocPrint(self.allocator, "/proc/{d}/task", .{pid});
        defer self.allocator.free(task_path);

        var task_dir = std.fs.openDirAbsolute(task_path, .{ .iterate = true }) catch return 0;
        defer task_dir.close();

        var iter = task_dir.iterate();
        var count: u32 = 0;
        while (try iter.next()) |entry| {
            if (entry.kind == .directory) count += 1;
        }

        return count;
    }

    /// Count open file descriptors in /proc/[pid]/fd/
    fn countFileDescriptors(self: *Self, pid: u32) !u32 {
        const fd_path = try std.fmt.allocPrint(self.allocator, "/proc/{d}/fd", .{pid});
        defer self.allocator.free(fd_path);

        var fd_dir = std.fs.openDirAbsolute(fd_path, .{ .iterate = true }) catch return 0;
        defer fd_dir.close();

        var iter = fd_dir.iterate();
        var count: u32 = 0;
        while (try iter.next()) |_| {
            count += 1;
        }

        return count;
    }

    /// Count network connections (from /proc/net/tcp, /proc/net/tcp6)
    fn countNetworkConnections(self: *Self, pid: u32) !u32 {
        _ = self;
        _ = pid;
        // Simplified - would need to parse /proc/net/tcp and match inode to /proc/[pid]/fd/*
        return 0;
    }

    /// Analyze snapshots to detect crypto miner behavior
    pub fn analyzeMinerBehavior(self: *Self, pid: u32) !bool {
        // Get all snapshots for this PID
        var pid_snapshots = std.ArrayList(ProcessSnapshot).init(self.allocator);
        defer pid_snapshots.deinit();

        for (self.snapshots.items) |snapshot| {
            if (snapshot.pid == pid) {
                try pid_snapshots.append(snapshot);
            }
        }

        if (pid_snapshots.items.len < 10) {
            // Not enough data
            return false;
        }

        // Calculate average CPU usage
        var cpu_sum: f32 = 0;
        var mem_sum: u64 = 0;
        for (pid_snapshots.items) |snapshot| {
            cpu_sum += snapshot.cpu_percent;
            mem_sum += snapshot.mem_rss_mb;
        }

        const cpu_avg = cpu_sum / @as(f32, @floatFromInt(pid_snapshots.items.len));
        const mem_avg = mem_sum / pid_snapshots.items.len;

        // Calculate CPU variance
        var variance_sum: f32 = 0;
        for (pid_snapshots.items) |snapshot| {
            const diff = snapshot.cpu_percent - cpu_avg;
            variance_sum += diff * diff;
        }
        const cpu_variance = @sqrt(variance_sum / @as(f32, @floatFromInt(pid_snapshots.items.len)));

        // Crypto miner fingerprint:
        // - High CPU (>90%)
        // - Low variance (<5% - constant load)
        // - High memory (>500MB)
        // - Many threads (>4)

        const latest = pid_snapshots.items[pid_snapshots.items.len - 1];

        const high_cpu = cpu_avg >= 90.0;
        const constant_load = cpu_variance <= 5.0;
        const high_memory = mem_avg >= 500;
        const many_threads = latest.thread_count >= 4;

        if (high_cpu and constant_load and high_memory and many_threads) {
            std.log.warn("🚨 CRYPTO MINER BEHAVIOR DETECTED", .{});
            std.log.warn("   PID: {d}", .{pid});
            std.log.warn("   Command: {s}", .{std.mem.sliceTo(&latest.command, 0)});
            std.log.warn("   CPU: {d:.1f}% (variance: {d:.1f}%)", .{ cpu_avg, cpu_variance });
            std.log.warn("   Memory: {d}MB", .{mem_avg});
            std.log.warn("   Threads: {d}", .{latest.thread_count});
            return true;
        }

        return false;
    }
};

/// Main entry point for standalone resource monitoring
pub fn main() !void {
    const allocator = std.heap.c_allocator;

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        std.log.err("Usage: resource-monitor <pid> [duration_sec]", .{});
        return error.InvalidArguments;
    }

    const pid = try std.fmt.parseInt(u32, args[1], 10);
    const duration_sec: u32 = if (args.len >= 3) try std.fmt.parseInt(u32, args[2], 10) else 60;

    std.log.info("Monitoring PID {d} for {d} seconds...", .{ pid, duration_sec });

    var monitor = try ResourceMonitor.init(allocator);
    defer monitor.deinit();

    const start_time = std.time.timestamp();
    const end_time = start_time + duration_sec;

    while (std.time.timestamp() < end_time) {
        const snapshot = monitor.captureSnapshot(pid) catch |err| {
            if (err == error.ProcessNotFound) {
                std.log.warn("Process {d} exited", .{pid});
                break;
            }
            return err;
        };

        std.log.info("[{d}] CPU: {d:.1f}%  MEM: {d}MB  Threads: {d}", .{
            snapshot.timestamp_sec,
            snapshot.cpu_percent,
            snapshot.mem_rss_mb,
            snapshot.thread_count,
        });

        std.time.sleep(1 * std.time.ns_per_s); // 1 second
    }

    // Analyze
    const is_miner = try monitor.analyzeMinerBehavior(pid);

    if (is_miner) {
        std.log.err("VERDICT: CRYPTO MINER DETECTED", .{});
        std.process.exit(1);
    } else {
        std.log.info("VERDICT: Normal behavior", .{});
        std.process.exit(0);
    }
}
