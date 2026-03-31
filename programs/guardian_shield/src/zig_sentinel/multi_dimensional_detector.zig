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
// multi_dimensional_detector.zig - The Correlation Engine
//
// Purpose: Coordinate detection across multiple behavioral dimensions
// Architecture: Central oracle that correlates syscalls + resources + network
// Philosophy: A single dimension is suspicion. All dimensions is truth.
//
// THE DOCTRINE OF DIMENSIONAL CONVERGENCE:
//   - Syscall dimension alone: MONITOR (potential false positive)
//   - Resource dimension alone: MONITOR (could be legitimate computation)
//   - Network dimension alone: MONITOR (could be normal application)
//   - TWO dimensions converge: HIGH SUSPICION (flag for investigation)
//   - THREE dimensions converge: ABSOLUTE VERDICT (terminate immediately)
//

const std = @import("std");
const grimoire = @import("grimoire.zig");

/// Evidence dimension type
pub const Dimension = enum(u8) {
    syscall,    // Sequential syscall pattern matched
    resource,   // Resource usage fingerprint matched
    network,    // Network behavior fingerprint matched
};

/// Multi-dimensional evidence for a process
pub const ProcessEvidence = struct {
    pid: u32,

    // Dimensional evidence flags
    syscall_match: bool = false,
    resource_match: bool = false,
    network_match: bool = false,

    // Evidence details
    syscall_pattern_id: ?u64 = null,
    syscall_pattern_name: ?[]const u8 = null,
    syscall_match_timestamp: u64 = 0,

    resource_cpu_avg: f32 = 0,
    resource_cpu_variance: f32 = 0,
    resource_mem_mb: u64 = 0,
    resource_thread_count: u32 = 0,

    network_connections: std.ArrayList(NetworkConnection),
    network_suspicious_port: ?u16 = null,
    network_suspicious_domain: ?[]const u8 = null,

    // Temporal tracking
    first_evidence_timestamp: u64 = 0,
    last_evidence_timestamp: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, pid: u32) ProcessEvidence {
        return .{
            .pid = pid,
            .network_connections = std.ArrayList(NetworkConnection).init(allocator),
        };
    }

    pub fn deinit(self: *ProcessEvidence) void {
        self.network_connections.deinit();
    }

    /// Count how many dimensions have evidence
    pub fn getDimensionCount(self: *const ProcessEvidence) u8 {
        var count: u8 = 0;
        if (self.syscall_match) count += 1;
        if (self.resource_match) count += 1;
        if (self.network_match) count += 1;
        return count;
    }

    /// Get confidence level based on dimension count
    pub fn getConfidenceLevel(self: *const ProcessEvidence) ConfidenceLevel {
        return switch (self.getDimensionCount()) {
            0 => .none,
            1 => .low,
            2 => .high,
            3 => .absolute,
            else => .none,
        };
    }
};

/// Confidence level in detection
pub const ConfidenceLevel = enum(u8) {
    none = 0,       // No evidence
    low = 1,        // Single dimension (monitor only)
    high = 2,       // Dual dimension (flag for investigation)
    absolute = 3,   // Triple dimension (terminate immediately)
};

/// Network connection record
pub const NetworkConnection = struct {
    local_port: u16,
    remote_addr: []const u8,
    remote_port: u16,
    state: []const u8,
    timestamp: u64,
};

/// Resource usage constraints
pub const ResourceConstraints = struct {
    /// Minimum sustained CPU usage (percentage)
    min_sustained_cpu: f32 = 90.0,

    /// Maximum CPU variance (low variance = machine-like)
    max_cpu_variance: f32 = 5.0,

    /// Minimum memory usage (MB)
    min_memory_mb: u64 = 500,

    /// Minimum thread count
    min_thread_count: u32 = 4,

    /// Minimum observation window (seconds)
    min_observation_sec: u32 = 10,
};

/// Network behavior constraints
pub const NetworkConstraints = struct {
    /// Forbidden ports (e.g., mining pool ports)
    forbidden_ports: []const u16,

    /// Forbidden domain patterns (e.g., "pool.", ".nanopool.")
    forbidden_domain_patterns: []const []const u8,

    /// Minimum connection duration (seconds)
    min_connection_duration_sec: u32 = 5,
};

/// Multi-dimensional pattern definition
pub const MultiDimensionalPattern = struct {
    /// Pattern ID and name
    id_hash: u64,
    name: [32]u8,

    /// Severity level
    severity: grimoire.Severity,

    /// Syscall pattern (the ritual)
    syscall_pattern: *const grimoire.GrimoirePattern,

    /// Resource constraints (the gluttony) - optional
    resource_constraints: ?ResourceConstraints = null,

    /// Network constraints (the tithe) - optional
    network_constraints: ?NetworkConstraints = null,

    /// Description
    description: []const u8,

    /// Enabled flag
    enabled: bool = true,
};

/// Multi-dimensional correlation engine
pub const MultiDimensionalDetector = struct {
    const Self = @This();

    allocator: std.mem.Allocator,

    /// Evidence database (PID → ProcessEvidence)
    evidence: std.AutoHashMap(u32, ProcessEvidence),

    /// Multi-dimensional patterns
    patterns: []const MultiDimensionalPattern,

    /// Resource usage history (for variance calculation)
    resource_history: std.AutoHashMap(u32, std.ArrayList(ResourceSnapshot)),

    /// Debug mode
    debug_mode: bool,

    /// Enforcement mode
    enforce_mode: bool,

    pub fn init(
        allocator: std.mem.Allocator,
        patterns: []const MultiDimensionalPattern,
        debug_mode: bool,
        enforce_mode: bool,
    ) !Self {
        return Self{
            .allocator = allocator,
            .evidence = std.AutoHashMap(u32, ProcessEvidence).init(allocator),
            .patterns = patterns,
            .resource_history = std.AutoHashMap(u32, std.ArrayList(ResourceSnapshot)).init(allocator),
            .debug_mode = debug_mode,
            .enforce_mode = enforce_mode,
        };
    }

    pub fn deinit(self: *Self) void {
        var evidence_iter = self.evidence.iterator();
        while (evidence_iter.next()) |entry| {
            entry.value_ptr.deinit();
        }
        self.evidence.deinit();

        var history_iter = self.resource_history.iterator();
        while (history_iter.next()) |entry| {
            entry.value_ptr.deinit();
        }
        self.resource_history.deinit();
    }

    /// Record syscall pattern match (Dimension 1)
    pub fn recordSyscallMatch(
        self: *Self,
        pid: u32,
        pattern: *const grimoire.GrimoirePattern,
        timestamp_us: u64,
    ) !void {
        const gop = try self.evidence.getOrPut(pid);
        if (!gop.found_existing) {
            gop.value_ptr.* = ProcessEvidence.init(self.allocator, pid);
            gop.value_ptr.first_evidence_timestamp = timestamp_us;
        }

        gop.value_ptr.syscall_match = true;
        gop.value_ptr.syscall_pattern_id = pattern.id_hash;
        gop.value_ptr.syscall_pattern_name = std.mem.sliceTo(&pattern.name, 0);
        gop.value_ptr.syscall_match_timestamp = timestamp_us;
        gop.value_ptr.last_evidence_timestamp = timestamp_us;

        if (self.debug_mode) {
            std.debug.print("[DIMENSION 1/3] PID {d}: Syscall pattern matched '{s}'\n", .{
                pid,
                std.mem.sliceTo(&pattern.name, 0),
            });
        }

        // Check if we now have multi-dimensional convergence
        try self.checkConvergence(pid);
    }

    /// Record resource usage match (Dimension 2)
    pub fn recordResourceMatch(
        self: *Self,
        pid: u32,
        snapshot: ResourceSnapshot,
        timestamp_us: u64,
    ) !void {
        const gop = try self.evidence.getOrPut(pid);
        if (!gop.found_existing) {
            gop.value_ptr.* = ProcessEvidence.init(self.allocator, pid);
            gop.value_ptr.first_evidence_timestamp = timestamp_us;
        }

        gop.value_ptr.resource_match = true;
        gop.value_ptr.resource_cpu_avg = snapshot.cpu_percent;
        gop.value_ptr.resource_cpu_variance = snapshot.cpu_variance;
        gop.value_ptr.resource_mem_mb = snapshot.mem_mb;
        gop.value_ptr.resource_thread_count = snapshot.thread_count;
        gop.value_ptr.last_evidence_timestamp = timestamp_us;

        if (self.debug_mode) {
            std.debug.print("[DIMENSION 2/3] PID {d}: Resource fingerprint matched (CPU: {d:.1f}%, variance: {d:.1f}%)\n", .{
                pid,
                snapshot.cpu_percent,
                snapshot.cpu_variance,
            });
        }

        // Add to history
        const history_gop = try self.resource_history.getOrPut(pid);
        if (!history_gop.found_existing) {
            history_gop.value_ptr.* = std.ArrayList(ResourceSnapshot).init(self.allocator);
        }
        try history_gop.value_ptr.append(snapshot);

        // Check convergence
        try self.checkConvergence(pid);
    }

    /// Record network behavior match (Dimension 3)
    pub fn recordNetworkMatch(
        self: *Self,
        pid: u32,
        connection: NetworkConnection,
        suspicious_port: ?u16,
        suspicious_domain: ?[]const u8,
        timestamp_us: u64,
    ) !void {
        const gop = try self.evidence.getOrPut(pid);
        if (!gop.found_existing) {
            gop.value_ptr.* = ProcessEvidence.init(self.allocator, pid);
            gop.value_ptr.first_evidence_timestamp = timestamp_us;
        }

        gop.value_ptr.network_match = true;
        gop.value_ptr.network_suspicious_port = suspicious_port;
        gop.value_ptr.network_suspicious_domain = suspicious_domain;
        gop.value_ptr.last_evidence_timestamp = timestamp_us;

        try gop.value_ptr.network_connections.append(connection);

        if (self.debug_mode) {
            if (suspicious_port) |port| {
                std.debug.print("[DIMENSION 3/3] PID {d}: Network fingerprint matched (port {d})\n", .{ pid, port });
            } else if (suspicious_domain) |domain| {
                std.debug.print("[DIMENSION 3/3] PID {d}: Network fingerprint matched (domain: {s})\n", .{ pid, domain });
            }
        }

        // Check convergence
        try self.checkConvergence(pid);
    }

    /// Check if multiple dimensions have converged for a PID
    fn checkConvergence(self: *Self, pid: u32) !void {
        const evidence = self.evidence.get(pid) orelse return;

        const dimension_count = evidence.getDimensionCount();
        const confidence = evidence.getConfidenceLevel();

        if (dimension_count >= 2) {
            // HIGH or ABSOLUTE confidence - issue verdict
            try self.issueVerdict(pid, evidence, confidence);
        }
    }

    /// Issue multi-dimensional verdict
    fn issueVerdict(
        self: *Self,
        pid: u32,
        evidence: ProcessEvidence,
        confidence: ConfidenceLevel,
    ) !void {
        const pattern_name = evidence.syscall_pattern_name orelse "unknown";

        switch (confidence) {
            .absolute => {
                // ALL THREE DIMENSIONS MATCHED
                std.log.err("🚨 MULTI-DIMENSIONAL VERDICT: ABSOLUTE CONFIDENCE", .{});
                std.log.err("   PID: {d}", .{pid});
                std.log.err("   Pattern: {s}", .{pattern_name});
                std.log.err("   Evidence:", .{});
                std.log.err("     [✓] Syscall ritual matched", .{});
                std.log.err("     [✓] Resource gluttony detected (CPU: {d:.1f}%, variance: {d:.1f}%)", .{
                    evidence.resource_cpu_avg,
                    evidence.resource_cpu_variance,
                });

                if (evidence.network_suspicious_port) |port| {
                    std.log.err("     [✓] Network tithe to forbidden port {d}", .{port});
                } else if (evidence.network_suspicious_domain) |domain| {
                    std.log.err("     [✓] Network tithe to forbidden domain: {s}", .{domain});
                }

                if (self.enforce_mode) {
                    std.log.err("⚔️  ENFORCEMENT: Terminating process {d}", .{pid});
                    try self.terminateProcess(pid);
                } else {
                    std.log.warn("⚠️  Monitor mode: Would terminate PID {d}", .{pid});
                }
            },

            .high => {
                // TWO DIMENSIONS MATCHED
                std.log.warn("⚠️  MULTI-DIMENSIONAL ALERT: HIGH SUSPICION", .{});
                std.log.warn("   PID: {d}", .{pid});
                std.log.warn("   Pattern: {s}", .{pattern_name});
                std.log.warn("   Evidence count: 2/3 dimensions", .{});

                if (evidence.syscall_match) std.log.warn("     [✓] Syscall ritual", .{});
                if (evidence.resource_match) std.log.warn("     [✓] Resource gluttony", .{});
                if (evidence.network_match) std.log.warn("     [✓] Network tithe", .{});

                std.log.warn("   Recommendation: Investigate PID {d}", .{pid});
            },

            else => {},
        }

        // Log to JSON
        try self.logVerdictJSON(pid, evidence, confidence);
    }

    /// Terminate a process
    fn terminateProcess(self: *Self, pid: u32) !void {
        _ = self;

        // Send SIGKILL
        const result = std.posix.kill(pid, std.posix.SIG.KILL);
        if (result) |_| {
            std.log.info("✅ Process {d} terminated successfully", .{pid});
        } else |err| {
            std.log.err("❌ Failed to terminate PID {d}: {}", .{ pid, err });
            return err;
        }
    }

    /// Log verdict to JSON file
    fn logVerdictJSON(
        self: *Self,
        pid: u32,
        evidence: ProcessEvidence,
        confidence: ConfidenceLevel,
    ) !void {
        const pattern_name = evidence.syscall_pattern_name orelse "unknown";

        const json = try std.fmt.allocPrint(
            self.allocator,
            \\{{"timestamp_us": {d}, "pid": {d}, "pattern": "{s}", "confidence": "{s}", "dimensions": {d}, "syscall": {}, "resource": {}, "network": {}, "action": "{s}"}}
            \\
        ,
            .{
                evidence.last_evidence_timestamp,
                pid,
                pattern_name,
                @tagName(confidence),
                evidence.getDimensionCount(),
                evidence.syscall_match,
                evidence.resource_match,
                evidence.network_match,
                if (self.enforce_mode and confidence == .absolute) "terminated" else "logged",
            },
        );
        defer self.allocator.free(json);

        const log_file = try std.Io.Dir.cwd().createFile(
            "/var/log/zig-sentinel/multi_dimensional_verdicts.json",
            .{ .truncate = false },
        );
        defer log_file.close();

        try log_file.seekFromEnd(0);
        _ = try log_file.write(json);
    }
};

/// Resource usage snapshot
pub const ResourceSnapshot = struct {
    cpu_percent: f32,
    cpu_variance: f32,
    mem_mb: u64,
    thread_count: u32,
    timestamp_us: u64,
};
