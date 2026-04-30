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


// SPDX-License-Identifier: GPL-2.0
//
// correlation.zig - File I/O Correlation Monitor for zig-sentinel V5.0
//
// Purpose: Detect data exfiltration via syscall sequence analysis
// Algorithm: Stateful tracking of NETWORK → READ_SENSITIVE_FILE → NETWORK pattern
//
// Threat Model: "Cunning Exfiltration"
//   1. Process opens network connection (socket, connect)
//   2. Process reads sensitive local file (open, read)
//   3. Process writes data to network (write, sendto)
//
// This sequence is the signature of data exfiltration.

const std = @import("std");
const time_compat = @import("time_compat.zig");
const baseline = @import("baseline.zig");

/// Version identifier
pub const VERSION = "5.0.0";

/// Maximum time window for sequence detection (milliseconds)
pub const SEQUENCE_TIMEOUT_MS: u64 = 5000; // 5 seconds

/// Syscall numbers (x86_64)
pub const Syscall = struct {
    pub const socket: u32 = 41;
    pub const connect: u32 = 42;
    pub const open: u32 = 2;
    pub const openat: u32 = 257;
    pub const read: u32 = 0;
    pub const write: u32 = 1;
    pub const sendto: u32 = 44;
    pub const sendmsg: u32 = 46;
    pub const close: u32 = 3;
};

/// Sequence stage tracking
pub const ExfiltrationStage = enum(u8) {
    idle = 0,               // No activity
    network_opened = 1,     // Stage 1: socket() or connect() called
    file_read = 2,          // Stage 2: read() on sensitive file
    data_sent = 3,          // Stage 3: write() to network socket (ALERT!)
};

/// Severity levels for correlation alerts
pub const CorrelationSeverity = enum {
    info,
    warning,
    high,
    critical,

    pub fn priority(self: CorrelationSeverity) u8 {
        return switch (self) {
            .info => 1,
            .warning => 2,
            .high => 3,
            .critical => 4,
        };
    }
};

/// Network socket information
pub const SocketInfo = struct {
    fd: i32,                    // File descriptor
    remote_ip: ?[4]u8,          // Remote IP (if available)
    remote_port: ?u16,          // Remote port
    opened_at: u64,             // Timestamp (milliseconds)
};

/// Sensitive file read tracking
pub const FileReadInfo = struct {
    path: []const u8,           // File path
    fd: i32,                    // File descriptor
    bytes_read: u64,            // Total bytes read
    read_at: u64,               // Timestamp (milliseconds)
    is_sensitive: bool,         // Whether file is in sensitive paths list
};

/// Process state for correlation tracking
pub const ProcessState = struct {
    pid: u32,
    comm: [16]u8,               // Process name (from /proc/[pid]/comm)

    // Current stage in exfiltration sequence
    stage: ExfiltrationStage,

    // Network sockets opened by this process
    open_sockets: std.AutoHashMap(i32, SocketInfo),

    // Files read by this process (recent history)
    recent_reads: std.ArrayList(FileReadInfo),

    // Sequence scoring
    sequence_score: u32,        // Cumulative score (100+ = alert)
    sequence_start_time: u64,   // When sequence started

    // Allocator
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, pid: u32) ProcessState {
        return .{
            .pid = pid,
            .comm = [_]u8{0} ** 16,
            .stage = .idle,
            .open_sockets = std.AutoHashMap(i32, SocketInfo).init(allocator),
            .recent_reads = std.ArrayList(FileReadInfo).empty,
            .sequence_score = 0,
            .sequence_start_time = 0,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ProcessState) void {
        self.open_sockets.deinit();
        // Free file paths in recent_reads
        for (self.recent_reads.items) |read_info| {
            self.allocator.free(read_info.path);
        }
        self.recent_reads.deinit(self.allocator);
    }

    /// Check if sequence has timed out
    pub fn isSequenceExpired(self: *const ProcessState, current_time: u64) bool {
        if (self.sequence_start_time == 0) return false;
        return (current_time - self.sequence_start_time) > SEQUENCE_TIMEOUT_MS;
    }

    /// Reset sequence tracking
    pub fn resetSequence(self: *ProcessState) void {
        self.stage = .idle;
        self.sequence_score = 0;
        self.sequence_start_time = 0;
    }
};

/// Correlation alert structure
pub const CorrelationAlert = struct {
    timestamp: i64,
    severity: CorrelationSeverity,
    pid: u32,
    comm: [16]u8,

    // Sequence details
    stage: ExfiltrationStage,
    sequence_score: u32,

    // Network details
    socket_fd: ?i32,
    remote_ip: ?[4]u8,
    remote_port: ?u16,

    // File details
    sensitive_file: ?[]const u8,
    bytes_read: u64,
    bytes_sent: u64,

    // Human-readable message
    message: []const u8,
    message_is_owned: bool,

    pub fn deinit(self: CorrelationAlert, allocator: std.mem.Allocator) void {
        if (self.message_is_owned) {
            allocator.free(self.message);
        }
        if (self.sensitive_file) |path| {
            allocator.free(path);
        }
    }

    /// Format alert as string for display
    pub fn format(self: CorrelationAlert, allocator: std.mem.Allocator) ![]const u8 {
        const severity_str = switch (self.severity) {
            .info => "INFO",
            .warning => "WARNING",
            .high => "HIGH",
            .critical => "CRITICAL",
        };

        const stage_str = switch (self.stage) {
            .idle => "IDLE",
            .network_opened => "NETWORK_OPENED",
            .file_read => "FILE_READ",
            .data_sent => "EXFILTRATION",
        };

        var ip_str_buf: [16]u8 = undefined;
        const ip_str = if (self.remote_ip) |ip|
            try std.fmt.bufPrint(&ip_str_buf, "{d}.{d}.{d}.{d}", .{ ip[0], ip[1], ip[2], ip[3] })
        else
            "unknown";

        const file_str = self.sensitive_file orelse "N/A";

        return try std.fmt.allocPrint(
            allocator,
            "[{d}] {s}/{s} PID={d} comm={s} | File={s} ({d} bytes) → Network={s}:{d} ({d} bytes) | {s}",
            .{
                self.timestamp,
                severity_str,
                stage_str,
                self.pid,
                std.mem.sliceTo(&self.comm, 0),
                file_str,
                self.bytes_read,
                ip_str,
                self.remote_port orelse 0,
                self.bytes_sent,
                self.message,
            },
        );
    }
};

/// Sensitive file path patterns
pub const SENSITIVE_PATHS = [_][]const u8{
    "/home/", // Will check if path contains .ssh/, .aws/, etc.
    "/root/.ssh/",
    "/root/.aws/",
    "/etc/passwd",
    "/etc/shadow",
    "/etc/ssh/",
    ".ssh/id_rsa",
    ".ssh/id_ed25519",
    ".ssh/id_ecdsa",
    ".aws/credentials",
    ".env",
    ".npmrc",
    ".gitconfig",
    ".docker/config.json",
    ".kube/config",
};

/// Check if a file path is sensitive
pub fn isSensitiveFile(path: []const u8) bool {
    for (SENSITIVE_PATHS) |pattern| {
        if (std.mem.indexOf(u8, path, pattern)) |_| {
            return true;
        }
    }
    return false;
}

/// Correlation engine configuration
pub const CorrelationConfig = struct {
    /// Enable correlation monitoring
    enabled: bool,

    /// Score thresholds for alerting
    alert_threshold: u32,           // Score >= this triggers alert (default: 100)

    /// Sequence timeout (ms)
    sequence_timeout_ms: u64,

    /// Minimum bytes to consider exfiltration
    min_exfil_bytes: u64,

    /// Enable automatic process termination on detection
    auto_terminate: bool,

    /// Correlation alert log path
    log_path: []const u8,

    pub fn init() CorrelationConfig {
        return .{
            .enabled = true,
            .alert_threshold = 100,
            .sequence_timeout_ms = SEQUENCE_TIMEOUT_MS,
            .min_exfil_bytes = 512,     // At least 512 bytes
            .auto_terminate = false,    // Requires explicit opt-in
            .log_path = "/var/log/zig-sentinel/correlation_alerts.json",
        };
    }
};

/// Correlation monitoring engine
pub const CorrelationEngine = struct {
    const Self = @This();

    config: CorrelationConfig,
    allocator: std.mem.Allocator,

    // Process state tracking (keyed by PID)
    process_states: std.AutoHashMap(u32, ProcessState),

    // Alert statistics
    total_alerts: u64,
    alerts_by_stage: [4]u64,        // [idle, network_opened, file_read, data_sent]
    processes_terminated: u64,

    pub fn init(allocator: std.mem.Allocator, config: CorrelationConfig) Self {
        return .{
            .config = config,
            .allocator = allocator,
            .process_states = std.AutoHashMap(u32, ProcessState).init(allocator),
            .total_alerts = 0,
            .alerts_by_stage = [_]u64{0} ** 4,
            .processes_terminated = 0,
        };
    }

    pub fn deinit(self: *Self) void {
        // Clean up all process states
        var iter = self.process_states.iterator();
        while (iter.next()) |entry| {
            var state = entry.value_ptr;
            state.deinit();
        }
        self.process_states.deinit();
    }

    /// Get or create process state
    fn getOrCreateState(self: *Self, pid: u32) !*ProcessState {
        const gop = try self.process_states.getOrPut(pid);
        if (!gop.found_existing) {
            gop.value_ptr.* = ProcessState.init(self.allocator, pid);
        }
        return gop.value_ptr;
    }

    /// Handle socket() syscall - Stage 1
    pub fn onSocket(self: *Self, pid: u32, fd: i32) !?CorrelationAlert {
        var state = try self.getOrCreateState(pid);
        const current_time = time_compat.milliTimestamp();

        // Record socket opening
        try state.open_sockets.put(fd, SocketInfo{
            .fd = fd,
            .remote_ip = null,
            .remote_port = null,
            .opened_at = @intCast(current_time),
        });

        // Advance to network_opened stage
        if (state.stage == .idle) {
            state.stage = .network_opened;
            state.sequence_score += 30;
            state.sequence_start_time = @intCast(current_time);
        }

        return null; // No alert yet
    }

    /// Handle connect() syscall - Stage 1 enhancement
    pub fn onConnect(self: *Self, pid: u32, fd: i32, ip: [4]u8, port: u16) !?CorrelationAlert {
        var state = try self.getOrCreateState(pid);

        // Update socket info with remote details
        if (state.open_sockets.getPtr(fd)) |socket_info| {
            socket_info.remote_ip = ip;
            socket_info.remote_port = port;
        }

        // Boost score for external connection
        if (!isLocalIP(ip)) {
            state.sequence_score += 20;
        }

        return null;
    }

    /// Handle open()/openat() syscall - Check if sensitive
    pub fn onOpen(self: *Self, pid: u32, path: []const u8, fd: i32) !?CorrelationAlert {
        var state = try self.getOrCreateState(pid);
        const current_time = time_compat.milliTimestamp();

        const is_sensitive = isSensitiveFile(path);

        // Record file read
        const path_copy = try self.allocator.dupe(u8, path);
        try state.recent_reads.append(self.allocator, FileReadInfo{
            .path = path_copy,
            .fd = fd,
            .bytes_read = 0,
            .read_at = @intCast(current_time),
            .is_sensitive = is_sensitive,
        });

        // If sensitive file and we have an open network socket: HIGH ALERT
        if (is_sensitive and state.open_sockets.count() > 0) {
            if (state.stage == .network_opened) {
                state.stage = .file_read;
                state.sequence_score += 40;

                // Generate warning-level alert
                return try self.generateAlert(state, .warning);
            }
        }

        return null;
    }

    /// Handle read() syscall - Track bytes read
    pub fn onRead(self: *Self, pid: u32, fd: i32, bytes: u64) !?CorrelationAlert {
        var state = try self.getOrCreateState(pid);

        // Find the file being read
        for (state.recent_reads.items) |*read_info| {
            if (read_info.fd == fd) {
                read_info.bytes_read += bytes;
                break;
            }
        }

        return null;
    }

    /// Handle write()/sendto() syscall - Stage 3 (EXFILTRATION!)
    pub fn onWrite(self: *Self, pid: u32, fd: i32, bytes: u64) !?CorrelationAlert {
        var state = try self.getOrCreateState(pid);
        const current_time = time_compat.milliTimestamp();

        // Check if sequence has expired
        if (state.isSequenceExpired(@intCast(current_time))) {
            state.resetSequence();
            return null;
        }

        // Is this write going to a network socket?
        if (state.open_sockets.contains(fd)) {
            // Writing to network socket!

            // Check if we recently read a sensitive file
            var has_sensitive_read = false;
            var total_bytes_read: u64 = 0;
            for (state.recent_reads.items) |read_info| {
                if (read_info.is_sensitive) {
                    has_sensitive_read = true;
                    total_bytes_read += read_info.bytes_read;
                }
            }

            if (has_sensitive_read and state.stage == .file_read) {
                // FULL EXFILTRATION SEQUENCE DETECTED!
                state.stage = .data_sent;
                state.sequence_score += 30;

                // Check if bytes match (data likely being exfiltrated)
                if (bytes >= self.config.min_exfil_bytes or
                    (total_bytes_read > 0 and bytes >= total_bytes_read / 2)) {
                    state.sequence_score += 50; // Bonus score for byte correlation
                }

                // Generate CRITICAL alert
                if (state.sequence_score >= self.config.alert_threshold) {
                    const alert = try self.generateAlert(state, .critical);

                    // Auto-terminate if configured
                    if (self.config.auto_terminate) {
                        try self.terminateProcess(pid);
                        self.processes_terminated += 1;
                    }

                    // Reset sequence for this process
                    state.resetSequence();

                    return alert;
                }
            }
        }

        return null;
    }

    /// Handle close() syscall - Clean up tracking
    pub fn onClose(self: *Self, pid: u32, fd: i32) !void {
        if (self.process_states.getPtr(pid)) |state| {
            // Remove from open sockets
            _ = state.open_sockets.remove(fd);

            // Remove from recent reads
            var i: usize = 0;
            while (i < state.recent_reads.items.len) {
                if (state.recent_reads.items[i].fd == fd) {
                    const removed = state.recent_reads.swapRemove(i);
                    self.allocator.free(removed.path);
                } else {
                    i += 1;
                }
            }
        }
    }

    /// Generate correlation alert
    fn generateAlert(self: *Self, state: *ProcessState, severity: CorrelationSeverity) !CorrelationAlert {
        const current_time = time_compat.timestamp();

        // Find most recent sensitive file read
        var sensitive_file: ?[]const u8 = null;
        var bytes_read: u64 = 0;
        for (state.recent_reads.items) |read_info| {
            if (read_info.is_sensitive) {
                sensitive_file = try self.allocator.dupe(u8, read_info.path);
                bytes_read = read_info.bytes_read;
                break;
            }
        }

        // Find network socket details
        var socket_fd: ?i32 = null;
        var remote_ip: ?[4]u8 = null;
        var remote_port: ?u16 = null;
        var sock_iter = state.open_sockets.iterator();
        if (sock_iter.next()) |entry| {
            const sock_info = entry.value_ptr.*;
            socket_fd = sock_info.fd;
            remote_ip = sock_info.remote_ip;
            remote_port = sock_info.remote_port;
        }

        // Generate message
        const stage_name = switch (state.stage) {
            .network_opened => "Network connection established",
            .file_read => "Sensitive file read detected",
            .data_sent => "DATA EXFILTRATION DETECTED",
            else => "Suspicious sequence",
        };

        const message = try std.fmt.allocPrint(
            self.allocator,
            "{s}: score={d}/100",
            .{ stage_name, state.sequence_score },
        );

        const alert = CorrelationAlert{
            .timestamp = current_time,
            .severity = severity,
            .pid = state.pid,
            .comm = state.comm,
            .stage = state.stage,
            .sequence_score = state.sequence_score,
            .socket_fd = socket_fd,
            .remote_ip = remote_ip,
            .remote_port = remote_port,
            .sensitive_file = sensitive_file,
            .bytes_read = bytes_read,
            .bytes_sent = 0, // Will be filled by caller
            .message = message,
            .message_is_owned = true,
        };

        // Update statistics
        self.total_alerts += 1;
        self.alerts_by_stage[@intFromEnum(state.stage)] += 1;

        return alert;
    }

    /// Terminate a process (requires root)
    fn terminateProcess(self: *Self, pid: u32) !void {
        _ = self;
        const result = std.posix.kill(@intCast(pid), std.posix.SIG.KILL);
        _ = result catch |err| {
            std.debug.print("⚠️  Failed to terminate PID {d}: {any}\n", .{ pid, err });
            return error.TerminateFailed;
        };
        std.debug.print("🔴 AUTO-TERMINATED PID {d} (exfiltration detected)\n", .{pid});
    }

    /// Display correlation statistics
    pub fn displayStats(self: *Self) void {
        std.debug.print("🔗 Correlation Engine Statistics:\n", .{});
        std.debug.print("   Total alerts:          {d}\n", .{self.total_alerts});
        std.debug.print("   Network opened:        {d}\n", .{self.alerts_by_stage[1]});
        std.debug.print("   File read (sensitive): {d}\n", .{self.alerts_by_stage[2]});
        std.debug.print("   Exfiltration detected: {d}\n", .{self.alerts_by_stage[3]});
        if (self.config.auto_terminate) {
            std.debug.print("   Processes terminated:  {d}\n", .{self.processes_terminated});
        }
        std.debug.print("   Active processes:      {d}\n", .{self.process_states.count()});
    }
};

/// Check if IP is local/loopback
fn isLocalIP(ip: [4]u8) bool {
    // 127.0.0.0/8 (loopback)
    if (ip[0] == 127) return true;
    // 10.0.0.0/8 (private)
    if (ip[0] == 10) return true;
    // 172.16.0.0/12 (private)
    if (ip[0] == 172 and ip[1] >= 16 and ip[1] <= 31) return true;
    // 192.168.0.0/16 (private)
    if (ip[0] == 192 and ip[1] == 168) return true;
    return false;
}

// ============================================================
// Tests
// ============================================================

test "correlation: detect exfiltration sequence" {
    const allocator = std.testing.allocator;

    var config = CorrelationConfig.init();
    config.alert_threshold = 100;

    var engine = CorrelationEngine.init(allocator, config);
    defer engine.deinit();

    const pid: u32 = 12345;

    // Stage 1: Open network socket
    _ = try engine.onSocket(pid, 5);

    // Stage 1b: Connect to external IP
    _ = try engine.onConnect(pid, 5, [4]u8{ 203, 0, 113, 42 }, 443);

    // Stage 2: Open sensitive file
    _ = try engine.onOpen(pid, "/home/user/.ssh/id_rsa", 6);

    // Stage 2b: Read from file
    _ = try engine.onRead(pid, 6, 4096);

    // Stage 3: Write to network socket (EXFILTRATION!)
    const alert = try engine.onWrite(pid, 5, 4096);

    // Should generate CRITICAL alert
    try std.testing.expect(alert != null);
    if (alert) |a| {
        try std.testing.expectEqual(CorrelationSeverity.critical, a.severity);
        try std.testing.expectEqual(ExfiltrationStage.data_sent, a.stage);
        a.deinit(allocator);
    }
}

test "correlation: sensitive file detection" {
    try std.testing.expect(isSensitiveFile("/home/user/.ssh/id_rsa"));
    try std.testing.expect(isSensitiveFile("/root/.aws/credentials"));
    try std.testing.expect(isSensitiveFile("/etc/passwd"));
    try std.testing.expect(!isSensitiveFile("/tmp/harmless.txt"));
}
