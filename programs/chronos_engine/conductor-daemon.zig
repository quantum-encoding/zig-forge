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


// conductor-daemon.zig - The Strategic Commander's Sovereign Daemon
// Purpose: Consume oracle_events ring buffer and begin behavioral correlation
// Doctrine: "From The Oracle's Gaze comes The Conductor's Wisdom"
//
// Architecture:
//   - Ring buffer consumer for oracle_events
//   - Event correlation and behavioral analysis engine
//   - Chronos integration for sovereign timestamps
//   - D-Bus interface for system integration
//   - Unix socket for agent communication

const std = @import("std");
const linux = std.os.linux;
const chronos = @import("chronos.zig");
const chronos_logger = @import("chronos_logger.zig");
const phi = @import("phi_timestamp.zig");
const dbus = @import("dbus_interface.zig");
const protocol = @import("socket_protocol.zig");
const posix = std.posix;

/// Unix socket address helper (replaces std.net.Address.initUnix)
const UnixAddress = struct {
    addr: posix.sockaddr.un,

    pub fn init(path: []const u8) !UnixAddress {
        var addr: posix.sockaddr.un = .{
            .family = posix.AF.UNIX,
            .path = undefined,
        };
        if (path.len >= addr.path.len) return error.NameTooLong;
        @memcpy(addr.path[0..path.len], path);
        addr.path[path.len] = 0;
        return .{ .addr = addr };
    }

    pub fn any(self: *const UnixAddress) *const posix.sockaddr {
        return @ptrCast(&self.addr);
    }

    pub fn getOsSockLen(self: *const UnixAddress) posix.socklen_t {
        _ = self;
        return @sizeOf(posix.sockaddr.un);
    }
};

const c = @cImport({
    @cInclude("bpf/libbpf.h");
    @cInclude("bpf/bpf.h");
    @cInclude("linux/bpf.h");
    @cInclude("errno.h");
});

const VERSION = "1.0.0";
const MAX_FILENAME_LEN = 256;

/// Event Types - The Oracle's Vision Spectrum (must match eBPF side)
pub const EventType = enum(u32) {
    EXECUTION = 0x01,    // Program execution
    FILE_ACCESS = 0x02,  // File open/read/write
    PROC_CREATE = 0x03,  // Process creation
    NETWORK = 0x04,      // Network connections
    MEMORY = 0x05,       // Memory mapping
};

/// Unified Event Structure (must match eBPF side)
pub const OracleEvent = extern struct {
    event_type: u32,
    pid: u32,
    uid: u32,
    gid: u32,
    blocked: u32,
    timestamp: u64,
    target: [MAX_FILENAME_LEN]u8,
    comm: [16]u8,
    parent_comm: [16]u8,
};

/// Behavioral Correlation - The Conductor's Analytical Framework
const BehavioralCorrelation = struct {
    /// Process Execution Chain
    const ProcessChain = struct {
        pid: u32,
        parent_pid: u32,
        grandparent_pid: u32,
        start_time: u64,
        current_comm: [16]u8,
        parent_comm: [16]u8,
        grandparent_comm: [16]u8,
        execution_count: u32,
        suspicious_patterns: u32,
    };

    /// Behavioral Pattern
    const BehavioralPattern = struct {
        pattern_id: []const u8,
        description: []const u8,
        severity: Severity,
        detection_logic: []const u8,
        mitigation: []const u8,

        const Severity = enum {
            info,
            warning,
            critical,
        };
    };

    /// Correlation Rule
    const CorrelationRule = struct {
        rule_id: []const u8,
        event_types: []const EventType,
        time_window: u64, // nanoseconds
        threshold: u32,
        description: []const u8,
        action: []const u8,
    };
};

/// The Conductor Daemon - Sovereign Intelligence Engine
pub const ConductorDaemon = struct {
    clock: chronos.ChronosClock,
    allocator: std.mem.Allocator,
    running: std.atomic.Value(bool),
    oracle_events_fd: i32,
    logger: chronos_logger.ChronosLogger,

    // Behavioral Analysis State
    process_chains: std.AutoHashMap(u32, BehavioralCorrelation.ProcessChain),
    event_history: std.ArrayList(OracleEvent),
    correlation_rules: std.ArrayList(BehavioralCorrelation.CorrelationRule),

    pub fn init(allocator: std.mem.Allocator) !ConductorDaemon {
        // Initialize Chronos Clock
        const clock = try chronos.ChronosClock.init(allocator, "/tmp/chronos-tick.dat");

        // Initialize Chronos Logger
        const logger = try chronos_logger.ChronosLogger.init(allocator, "conductor-daemon");

        std.debug.print("🧠 THE CONDUCTOR DAEMON v{s} - Forging Sovereign Intelligence\n", .{VERSION});
        std.debug.print("   Agent: conductor-daemon\n", .{});
        std.debug.print("   Service: {s}\n", .{dbus.DBUS_SERVICE});
        std.debug.print("   Path: {s}\n", .{dbus.DBUS_PATH});

        return ConductorDaemon{
            .clock = clock,
            .allocator = allocator,
            .running = std.atomic.Value(bool).init(true),
            .oracle_events_fd = -1,
            .logger = logger,
            .process_chains = std.AutoHashMap(u32, BehavioralCorrelation.ProcessChain).init(allocator),
            .event_history = std.ArrayList(OracleEvent).empty,
            .correlation_rules = std.ArrayList(BehavioralCorrelation.CorrelationRule).empty,
        };
    }

    pub fn deinit(self: *ConductorDaemon) void {
        self.clock.deinit();
        self.logger.deinit();
        self.process_chains.deinit();
        self.event_history.deinit(self.allocator);
        self.correlation_rules.deinit(self.allocator);
        std.debug.print("🧠 Conductor Daemon shutdown complete\n", .{});
    }

    /// Connect to Oracle's ring buffer
    pub fn connectToOracle(self: *ConductorDaemon, oracle_events_fd: i32) void {
        self.oracle_events_fd = oracle_events_fd;
        std.debug.print("🔗 Connected to Oracle's ring buffer (fd={d})\n", .{oracle_events_fd});
    }

    /// Load behavioral correlation rules
    pub fn loadCorrelationRules(self: *ConductorDaemon) !void {
        std.debug.print("📜 Loading Behavioral Correlation Rules...\n", .{});

        const rules = [_]BehavioralCorrelation.CorrelationRule{
            .{
                .rule_id = "RAPID_EXECUTION",
                .event_types = &.{.EXECUTION},
                .time_window = 1_000_000_000, // 1 second
                .threshold = 10,
                .description = "Rapid program execution - potential fork bomb or malware",
                .action = "Alert security team, consider process termination",
            },
            .{
                .rule_id = "SENSITIVE_FILE_ACCESS",
                .event_types = &.{.FILE_ACCESS},
                .time_window = 5_000_000_000, // 5 seconds
                .threshold = 3,
                .description = "Multiple sensitive file accesses in short time",
                .action = "Investigate for data exfiltration",
            },
            .{
                .rule_id = "UNUSUAL_PROCESS_CHAIN",
                .event_types = &.{.PROC_CREATE, .EXECUTION},
                .time_window = 10_000_000_000, // 10 seconds
                .threshold = 5,
                .description = "Unusual parent-child process relationships",
                .action = "Analyze for privilege escalation or persistence",
            },
            .{
                .rule_id = "EXECUTION_AFTER_FILE_ACCESS",
                .event_types = &.{.FILE_ACCESS, .EXECUTION},
                .time_window = 2_000_000_000, // 2 seconds
                .threshold = 2,
                .description = "Program execution immediately after file access",
                .action = "Investigate for script execution or code injection",
            },
        };

        for (rules) |rule| {
            try self.correlation_rules.append(self.allocator, rule);
        }

        std.debug.print("✓ Loaded {d} behavioral correlation rules\n", .{rules.len});
    }

    /// Try to connect to Oracle events ring buffer
    /// Returns true if connected, false if not available
    pub fn tryConnectOracle(self: *ConductorDaemon) bool {
        // Try to open Oracle events BPF map
        // Path typically: /sys/fs/bpf/oracle_events
        const map_path = "/sys/fs/bpf/oracle_events";

        const fd = c.bpf_obj_get(@ptrCast(map_path));
        if (fd < 0) {
            // Oracle not loaded yet
            self.oracle_events_fd = -1;
            return false;
        }

        self.oracle_events_fd = @intCast(fd);
        return true;
    }

    /// Ring buffer event handler callback
    fn handleOracleEvent(ctx: ?*anyopaque, data: ?*anyopaque, size: c_ulong) callconv(.c) c_int {
        _ = size;
        if (data == null) return 0;

        const self: *ConductorDaemon = @ptrCast(@alignCast(ctx));
        const event: *OracleEvent = @ptrCast(@alignCast(data));

        // Process the event
        self.processEvent(event) catch |err| {
            std.debug.print("⚠️  Event processing error: {any}\n", .{err});
        };

        return 0;
    }

    /// Process individual Oracle event
    pub fn processEvent(self: *ConductorDaemon, event: *OracleEvent) !void {
        // Log event with Chronos timestamp
        const timestamp = try self.logger.stamp();
        defer self.allocator.free(timestamp);

        // Store event in history
        try self.event_history.append(self.allocator, event.*);

        // Update process chain
        try self.updateProcessChain(event);

        // Run behavioral correlation
        try self.runBehavioralCorrelation(event);

        // Log event details
        const target = std.mem.sliceTo(&event.target, 0);
        const comm = std.mem.sliceTo(&event.comm, 0);
        const parent_comm = std.mem.sliceTo(&event.parent_comm, 0);

        const event_types = [_][]const u8{ "UNKNOWN", "EXECUTION", "FILE_ACCESS", "PROC_CREATE", "NETWORK", "MEMORY" };
        const event_type_str = if (event.event_type < event_types.len)
            event_types[event.event_type] else "UNKNOWN";

        const action = if (event.blocked == 1) "BLOCKED" else "DETECTED";

        std.debug.print("[{s}] {s} [{s}]: pid={d} command='{s}' target='{s}' parent='{s}'\n", .{
            timestamp,
            action,
            event_type_str,
            event.pid,
            comm,
            target,
            parent_comm,
        });
    }

    /// Update process chain tracking
    fn updateProcessChain(self: *ConductorDaemon, event: *OracleEvent) !void {
        var chain = self.process_chains.get(event.pid) orelse BehavioralCorrelation.ProcessChain{
            .pid = event.pid,
            .parent_pid = 0,
            .grandparent_pid = 0,
            .start_time = event.timestamp,
            .current_comm = event.comm,
            .parent_comm = event.parent_comm,
            .grandparent_comm = std.mem.zeroes([16]u8),
            .execution_count = 0,
            .suspicious_patterns = 0,
        };

        chain.execution_count += 1;
        chain.current_comm = event.comm;

        try self.process_chains.put(event.pid, chain);
    }

    /// Run behavioral correlation analysis
    fn runBehavioralCorrelation(self: *ConductorDaemon, event: *OracleEvent) !void {
        const current_time = event.timestamp;

        for (self.correlation_rules.items) |rule| {
            var match_count: u32 = 0;

            // Check events within time window
            for (self.event_history.items) |past_event| {
                if (current_time - past_event.timestamp > rule.time_window) {
                    continue; // Outside time window
                }

                // Check if event type matches rule
                for (rule.event_types) |rule_event_type| {
                    if (@intFromEnum(rule_event_type) == past_event.event_type) {
                        match_count += 1;
                        break;
                    }
                }
            }

            // Check if threshold exceeded
            if (match_count >= rule.threshold) {
                try self.triggerBehavioralAlert(rule, match_count, event);
            }
        }
    }

    /// Trigger behavioral alert
    fn triggerBehavioralAlert(self: *ConductorDaemon, rule: BehavioralCorrelation.CorrelationRule,
                             match_count: u32, trigger_event: *OracleEvent) !void {
        const timestamp = try self.logger.stamp();
        defer self.allocator.free(timestamp);

        const target = std.mem.sliceTo(&trigger_event.target, 0);
        const comm = std.mem.sliceTo(&trigger_event.comm, 0);

        std.debug.print("🚨 BEHAVIORAL ALERT [{s}]: {s}\n", .{timestamp, rule.rule_id});
        std.debug.print("   Description: {s}\n", .{rule.description});
        std.debug.print("   Trigger: pid={d} command='{s}' target='{s}'\n", .{
            trigger_event.pid,
            comm,
            target,
        });
        std.debug.print("   Statistics: {d} matches in {d}ns window\n", .{
            match_count,
            rule.time_window,
        });
        std.debug.print("   Action: {s}\n", .{rule.action});
        std.debug.print("   ---\n", .{});

        // Log to Chronos
        _ = try self.logger.log(
            "behavioral_alert",
            "TRIGGERED",
            try std.fmt.allocPrint(self.allocator, "Rule: {s}, Matches: {d}, PID: {d}", .{
                rule.rule_id,
                match_count,
                trigger_event.pid,
            })
        );
    }

    /// Consume events from Oracle's ring buffer
    pub fn consumeOracleEvents(self: *ConductorDaemon, duration_seconds: u32) !void {
        if (self.oracle_events_fd < 0) {
            std.debug.print("❌ Not connected to Oracle's ring buffer\n", .{});
            return error.NotConnected;
        }

        std.debug.print("🧠 THE CONDUCTOR IS LISTENING - Behavioral Analysis Active\n", .{});
        std.debug.print("   Duration: {d} seconds\n", .{duration_seconds});
        std.debug.print("   Rules: {d} correlation rules loaded\n", .{self.correlation_rules.items.len});
        std.debug.print("   Process Chains: {d} processes tracked\n", .{self.process_chains.count()});
        std.debug.print("   ---\n", .{});

        const ring_buffer = c.ring_buffer__new(self.oracle_events_fd, handleOracleEvent, self, null) orelse {
            std.debug.print("❌ Failed to create ring buffer\n", .{});
            return error.RingBufferFailed;
        };
        defer c.ring_buffer__free(ring_buffer);

        const start_time = std.time.timestamp();
        while (std.time.timestamp() - start_time < duration_seconds) {
            const poll_result = c.ring_buffer__poll(ring_buffer, 100); // 100ms timeout
            if (poll_result < 0) {
                std.debug.print("❌ Ring buffer poll error: {d}\n", .{poll_result});
                return error.PollFailed;
            }
        }

        std.debug.print("🧠 Behavioral analysis complete\n", .{});
        std.debug.print("   Events Processed: {d}\n", .{self.event_history.items.len});
        std.debug.print("   Process Chains: {d}\n", .{self.process_chains.count()});
        std.debug.print("   ---\n", .{});
    }

    /// Run daemon with Unix socket server
    pub fn run(self: *ConductorDaemon) !void {
        const socket_path = protocol.FALLBACK_SOCKET_PATH;

        std.debug.print("🧠 Using socket path: {s}\n", .{socket_path});

        // Remove old socket if it exists (need null-terminated path for unlink)
        var socket_path_buf: [256]u8 = undefined;
        @memcpy(socket_path_buf[0..socket_path.len], socket_path);
        socket_path_buf[socket_path.len] = 0;
        _ = std.c.unlink(@ptrCast(&socket_path_buf));

        // Create Unix domain socket
        const sock_result = linux.socket(linux.AF.UNIX, linux.SOCK.STREAM, 0);
        if (@as(isize, @bitCast(sock_result)) < 0) return error.SocketCreateFailed;
        const sockfd: posix.fd_t = @intCast(sock_result);
        errdefer _ = std.c.close(sockfd);

        std.debug.print("🧠 Socket created, fd={d}\n", .{sockfd});

        const address = try UnixAddress.init(socket_path);
        std.debug.print("🧠 Address initialized\n", .{});

        const bind_result = linux.bind(sockfd, @ptrCast(&address.addr), address.getOsSockLen());
        if (@as(isize, @bitCast(bind_result)) < 0) return error.BindFailed;
        std.debug.print("🧠 Socket bound\n", .{});

        const listen_result = linux.listen(sockfd, 128); // backlog
        if (@as(isize, @bitCast(listen_result)) < 0) return error.ListenFailed;
        std.debug.print("🧠 Socket listening\n", .{});

        // Set socket permissions
        const fchmod_result = linux.fchmod(sockfd, 0o666);
        if (@as(isize, @bitCast(fchmod_result)) < 0) {
            std.debug.print("⚠️  Failed to set socket permissions\n", .{});
        }

        std.debug.print("🧠 Conductor Daemon v{s} running\n", .{VERSION});
        std.debug.print("   Socket: {s}\n", .{socket_path});
        std.debug.print("   Current tick: {d}\n", .{self.clock.getTick()});
        std.debug.print("   Ready for connections\n\n", .{});

        // Accept loop
        while (self.running.load(.acquire)) {
            var client_addr: linux.sockaddr = undefined;
            var client_addr_len: linux.socklen_t = @sizeOf(linux.sockaddr);

            const accept_result = linux.accept(sockfd, &client_addr, &client_addr_len);
            if (@as(isize, @bitCast(accept_result)) < 0) {
                std.debug.print("⚠️  Accept error\n", .{});
                continue;
            }
            const client_fd: posix.fd_t = @intCast(accept_result);

            // Handle connection in same thread
            self.handleConnectionFd(client_fd) catch |err| {
                std.debug.print("⚠️  Connection handler error: {any}\n", .{err});
            };
            _ = std.c.close(client_fd);
        }

        // Cleanup
        _ = std.c.close(sockfd);
        _ = std.c.unlink(@ptrCast(&socket_path_buf));
    }

    /// Write all bytes to fd
    fn writeAllFd(fd: posix.fd_t, data: []const u8) !void {
        var written: usize = 0;
        while (written < data.len) {
            const result = std.c.write(fd, data.ptr + written, data.len - written);
            if (result < 0) return error.WriteError;
            if (result == 0) return error.WriteError;
            written += @intCast(result);
        }
    }

    /// Handle a client connection using file descriptor
    fn handleConnectionFd(self: *ConductorDaemon, fd: posix.fd_t) !void {
        var buf: [protocol.MAX_MESSAGE_LEN]u8 = undefined;

        // Read command (line-delimited)
        const read_result = std.c.read(fd, &buf, buf.len);
        if (read_result <= 0) return; // EOF or error

        const bytes_read: usize = @intCast(read_result);
        const command_line = std.mem.trim(u8, buf[0..bytes_read], &std.ascii.whitespace);
        const cmd = protocol.Command.parse(command_line);

        switch (cmd) {
            .ping => {
                const response = try protocol.formatPong(self.allocator);
                defer self.allocator.free(response);
                try writeAllFd(fd, response);
            },

            .get_tick => {
                const tick = self.clock.getTick();
                const response = try protocol.formatOk(self.allocator, try std.fmt.allocPrint(self.allocator, "{d}", .{tick}));
                defer self.allocator.free(response);
                try writeAllFd(fd, response);
            },

            .next_tick => {
                const tick = try self.clock.nextTick();
                const response = try protocol.formatOk(self.allocator, try std.fmt.allocPrint(self.allocator, "{d}", .{tick}));
                defer self.allocator.free(response);
                try writeAllFd(fd, response);
            },

            .log => {
                // For now, just acknowledge log commands
                const response = try protocol.formatOk(self.allocator, "Logged");
                defer self.allocator.free(response);
                try writeAllFd(fd, response);
            },

            .status => {
                const status = try std.fmt.allocPrint(self.allocator,
                    "Conductor Status: Active\n" ++
                    "Events Processed: {d}\n" ++
                    "Process Chains: {d}\n" ++
                    "Correlation Rules: {d}\n" ++
                    "Current Tick: {d}", .{
                        self.event_history.items.len,
                        self.process_chains.count(),
                        self.correlation_rules.items.len,
                        self.clock.getTick(),
                    });
                defer self.allocator.free(status);

                const response = try protocol.formatOk(self.allocator, status);
                defer self.allocator.free(response);
                try writeAllFd(fd, response);
            },

            .stamp => {
                _ = protocol.parseStampArgs(command_line) orelse {
                    const response = try protocol.formatErr(self.allocator, "Invalid STAMP syntax");
                    defer self.allocator.free(response);
                    try writeAllFd(fd, response);
                    return;
                };

                const timestamp = try self.logger.stamp();
                defer self.allocator.free(timestamp);

                const response = try protocol.formatOk(self.allocator, timestamp);
                defer self.allocator.free(response);
                try writeAllFd(fd, response);
            },

            .shutdown => {
                std.debug.print("🧠 Shutdown command received\n", .{});
                const response = try protocol.formatOk(self.allocator, "Shutting down");
                defer self.allocator.free(response);
                try writeAllFd(fd, response);
                self.shutdown();
            },

            .unknown => {
                const response = try protocol.formatErr(self.allocator, "Unknown command");
                defer self.allocator.free(response);
                try writeAllFd(fd, response);
            },
        }
    }

    /// Shutdown daemon gracefully
    pub fn shutdown(self: *ConductorDaemon) void {
        std.debug.print("🧠 Conductor Daemon shutting down...\n", .{});
        self.running.store(false, .release);
    }
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    var daemon = try ConductorDaemon.init(allocator);
    defer daemon.deinit();

    // Load behavioral correlation rules
    try daemon.loadCorrelationRules();

    // Try to connect to Oracle events ring buffer
    const oracle_connected = daemon.tryConnectOracle();
    if (oracle_connected) {
        std.debug.print("✅ Oracle ring buffer connected (real-time threat intelligence)\n", .{});
    } else {
        std.debug.print("ℹ️  Running in basic mode (Oracle/eBPF not loaded)\n", .{});
        std.debug.print("   To enable: Load zig-sentinel with eBPF oracle\n", .{});
    }

    try daemon.run();
}
