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
// outputs.zig - Alert output and integration system for zig-sentinel
//
// Purpose: Fan out alerts to multiple outputs (syslog, auditd, metrics, logs, webhooks)
// Architecture: Interface-based design with error resilience
//

const std = @import("std");
const anomaly = @import("anomaly.zig");
const net = std.net;
const fs = std.fs;
const Io = std.Io;
const http = std.http;

/// Output interface - all outputs must implement these methods
pub const Output = struct {
    const Self = @This();

    /// Pointer to the concrete implementation
    ptr: *anyopaque,

    /// Virtual function table
    vtable: *const VTable,

    pub const VTable = struct {
        /// Send an alert to this output
        send: *const fn (ptr: *anyopaque, alert: anomaly.Alert) anyerror!void,

        /// Flush any buffered output
        flush: *const fn (ptr: *anyopaque) anyerror!void,

        /// Close and cleanup the output
        deinit: *const fn (ptr: *anyopaque) void,
    };

    pub fn send(self: Self, alert: anomaly.Alert) !void {
        return self.vtable.send(self.ptr, alert);
    }

    pub fn flush(self: Self) !void {
        return self.vtable.flush(self.ptr);
    }

    pub fn deinit(self: Self) void {
        self.vtable.deinit(self.ptr);
    }
};

/// Output manager - coordinates multiple outputs
pub const OutputManager = struct {
    const Self = @This();

    outputs: std.ArrayList(Output),
    allocator: std.mem.Allocator,

    /// Error counters per output type
    syslog_errors: u64 = 0,
    json_errors: u64 = 0,
    auditd_errors: u64 = 0,
    prometheus_errors: u64 = 0,
    webhook_errors: u64 = 0,

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .outputs = std.ArrayList(Output).empty,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.outputs.items) |output| {
            output.deinit();
        }
        self.outputs.deinit(self.allocator);
    }

    /// Register an output
    pub fn addOutput(self: *Self, output: Output) !void {
        try self.outputs.append(self.allocator, output);
    }

    /// Send alert to all registered outputs
    pub fn sendAlert(self: *Self, alert: anomaly.Alert) void {
        for (self.outputs.items) |output| {
            output.send(alert) catch |err| {
                // Don't crash on output errors, just log
                std.debug.print("⚠️  Output error: {any}\n", .{err});
            };
        }
    }

    /// Send multiple alerts
    pub fn sendAlerts(self: *Self, alerts: []const anomaly.Alert) void {
        for (alerts) |alert| {
            self.sendAlert(alert);
        }
    }

    /// Flush all outputs
    pub fn flushAll(self: *Self) void {
        for (self.outputs.items) |output| {
            output.flush() catch {};
        }
    }
};

/// Syslog output (RFC 5424 format over UDP)
pub const SyslogOutput = struct {
    const Self = @This();

    socket: ?std.net.Stream,
    address: std.net.Address,
    facility: u8,
    allocator: std.mem.Allocator,

    pub const Facility = enum(u8) {
        kern = 0,
        user = 1,
        mail = 2,
        daemon = 3,
        auth = 4,
        syslog = 5,
        local0 = 16,
        local1 = 17,
        local2 = 18,
        local3 = 19,
        local4 = 20,
        local5 = 21,
        local6 = 22,
        local7 = 23,
    };

    pub fn init(
        allocator: std.mem.Allocator,
        host: []const u8,
        port: u16,
        facility: Facility,
    ) !Self {
        const address = try std.net.Address.parseIp(host, port);

        return .{
            .socket = null,
            .address = address,
            .facility = @intFromEnum(facility),
            .allocator = allocator,
        };
    }

    pub fn output(self: *Self) Output {
        return .{
            .ptr = self,
            .vtable = &.{
                .send = send,
                .flush = flush,
                .deinit = deinit,
            },
        };
    }

    fn send(ptr: *anyopaque, alert: anomaly.Alert) !void {
        const self: *Self = @ptrCast(@alignCast(ptr));

        // Lazy socket creation
        if (self.socket == null) {
            self.socket = try std.net.tcpConnectToAddress(self.address);
        }

        // RFC 5424 priority: (facility * 8) + severity
        const severity: u8 = switch (alert.severity) {
            .debug => 7,
            .info => 6,
            .warning => 4,
            .high => 3,
            .critical => 2,
        };
        const priority = (self.facility * 8) + severity;

        // RFC 5424 format: <PRI>VERSION TIMESTAMP HOSTNAME APP-NAME PROCID MSGID SD MSG
        const hostname = "zig-sentinel";
        const appname = "zig-sentinel";
        const procid = alert.pid;

        const message = try std.fmt.allocPrint(
            self.allocator,
            "<{d}>1 - {s} {s} {d} - - {s}\n",
            .{ priority, hostname, appname, procid, alert.message },
        );
        defer self.allocator.free(message);

        if (self.socket) |socket| {
            _ = try socket.write(message);
        }
    }

    fn flush(_: *anyopaque) !void {
        // Syslog is unbuffered
    }

    fn deinit(ptr: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        if (self.socket) |socket| {
            socket.close();
        }
    }
};

/// JSON log file output with rotation
pub const JsonLogOutput = struct {
    const Self = @This();

    file: ?Io.File,
    path: []const u8,
    max_size: usize,
    current_size: usize,
    allocator: std.mem.Allocator,

    pub fn init(
        allocator: std.mem.Allocator,
        path: []const u8,
        max_size: usize,
    ) !Self {
        return .{
            .file = null,
            .path = path,
            .max_size = max_size,
            .current_size = 0,
            .allocator = allocator,
        };
    }

    pub fn output(self: *Self) Output {
        return .{
            .ptr = self,
            .vtable = &.{
                .send = send,
                .flush = flush,
                .deinit = deinit,
            },
        };
    }

    fn send(ptr: *anyopaque, alert: anomaly.Alert) !void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const io = Io.Threaded.global_single_threaded.io();

        // Lazy file creation
        if (self.file == null) {
            self.file = try Io.Dir.cwd().createFile(io, self.path, .{});
        }

        // Check rotation
        if (self.current_size >= self.max_size) {
            try self.rotate();
        }

        // Format as JSON
        const json = try std.fmt.allocPrint(
            self.allocator,
            \\{{"timestamp":{d},"severity":"{s}","type":"{s}","pid":{d},"syscall":{d},"observed":{d},"expected":{d:.2},"stddev":{d:.2},"z_score":{d:.2},"message":"{s}"}}
            \\
        ,
            .{
                alert.timestamp,
                @tagName(alert.severity),
                @tagName(alert.anomaly_type),
                alert.pid,
                alert.syscall_nr,
                alert.observed,
                alert.expected,
                alert.stddev,
                alert.z_score,
                alert.message,
            },
        );
        defer self.allocator.free(json);

        if (self.file) |file| {
            file.writeStreamingAll(io, json) catch return error.WriteError;
            self.current_size += json.len;
        }
    }

    fn rotate(self: *Self) !void {
        const io = Io.Threaded.global_single_threaded.io();
        if (self.file) |file| {
            file.close(io);
        }

        // Rename current file to .old
        const old_path = try std.fmt.allocPrint(
            self.allocator,
            "{s}.old",
            .{self.path},
        );
        defer self.allocator.free(old_path);

        Io.Dir.cwd().rename(io, self.path, old_path) catch {};

        // Create new file
        self.file = try Io.Dir.cwd().createFile(io, self.path, .{});
        self.current_size = 0;
    }

    fn flush(ptr: *anyopaque) !void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const io = Io.Threaded.global_single_threaded.io();
        if (self.file) |file| {
            file.sync(io) catch return error.SyncError;
        }
    }

    fn deinit(ptr: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const io = Io.Threaded.global_single_threaded.io();
        if (self.file) |file| {
            file.close(io);
        }
    }
};

/// Prometheus metrics exporter (HTTP server on :9091/metrics)
pub const PrometheusOutput = struct {
    const Self = @This();

    // Metric counters
    total_alerts: std.atomic.Value(u64),
    alerts_by_severity: [5]std.atomic.Value(u64),

    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Self {
        var alerts_by_severity: [5]std.atomic.Value(u64) = undefined;
        for (&alerts_by_severity) |*counter| {
            counter.* = std.atomic.Value(u64).init(0);
        }

        return .{
            .total_alerts = std.atomic.Value(u64).init(0),
            .alerts_by_severity = alerts_by_severity,
            .allocator = allocator,
        };
    }

    pub fn output(self: *Self) Output {
        return .{
            .ptr = self,
            .vtable = &.{
                .send = send,
                .flush = flush,
                .deinit = deinit,
            },
        };
    }

    fn send(ptr: *anyopaque, alert: anomaly.Alert) !void {
        const self: *Self = @ptrCast(@alignCast(ptr));

        // Update metrics atomically
        _ = self.total_alerts.fetchAdd(1, .monotonic);
        _ = self.alerts_by_severity[alert.severity.priority()].fetchAdd(1, .monotonic);
    }

    /// Generate Prometheus metrics text format
    pub fn generateMetrics(self: *Self) ![]const u8 {
        return try std.fmt.allocPrint(
            self.allocator,
            \\# HELP zig_sentinel_alerts_total Total number of alerts generated
            \\# TYPE zig_sentinel_alerts_total counter
            \\zig_sentinel_alerts_total {d}
            \\# HELP zig_sentinel_alerts_by_severity Alerts by severity level
            \\# TYPE zig_sentinel_alerts_by_severity counter
            \\zig_sentinel_alerts_by_severity{{severity="debug"}} {d}
            \\zig_sentinel_alerts_by_severity{{severity="info"}} {d}
            \\zig_sentinel_alerts_by_severity{{severity="warning"}} {d}
            \\zig_sentinel_alerts_by_severity{{severity="high"}} {d}
            \\zig_sentinel_alerts_by_severity{{severity="critical"}} {d}
            \\
        ,
            .{
                self.total_alerts.load(.monotonic),
                self.alerts_by_severity[0].load(.monotonic),
                self.alerts_by_severity[1].load(.monotonic),
                self.alerts_by_severity[2].load(.monotonic),
                self.alerts_by_severity[3].load(.monotonic),
                self.alerts_by_severity[4].load(.monotonic),
            },
        );
    }

    fn flush(_: *anyopaque) !void {
        // Metrics are atomic, no flush needed
    }

    fn deinit(_: *anyopaque) void {
        // No resources to clean up
    }
};

/// Auditd output (Unix socket to /var/run/auditd.sock)
pub const AuditdOutput = struct {
    const Self = @This();

    socket: ?std.net.Stream,
    socket_path: []const u8,
    allocator: std.mem.Allocator,

    pub fn init(
        allocator: std.mem.Allocator,
        socket_path: []const u8,
    ) !Self {
        return .{
            .socket = null,
            .socket_path = socket_path,
            .allocator = allocator,
        };
    }

    pub fn output(self: *Self) Output {
        return .{
            .ptr = self,
            .vtable = &.{
                .send = send,
                .flush = flush,
                .deinit = deinit,
            },
        };
    }

    fn send(ptr: *anyopaque, alert: anomaly.Alert) !void {
        const self: *Self = @ptrCast(@alignCast(ptr));

        // Lazy socket connection
        if (self.socket == null) {
            const addr = try std.net.Address.initUnix(self.socket_path);
            self.socket = try std.net.Stream.connectUnixSocket(self.socket_path);
            _ = addr;
        }

        // Auditd message format: type=USER_AVC msg=audit(timestamp:serial): ...
        const message = try std.fmt.allocPrint(
            self.allocator,
            "type=USER_AVC msg=audit({d}.000:1): zig_sentinel anomaly_type={s} severity={s} pid={d} syscall={d} z_score={d:.2}\n",
            .{
                alert.timestamp,
                @tagName(alert.anomaly_type),
                @tagName(alert.severity),
                alert.pid,
                alert.syscall_nr,
                alert.z_score,
            },
        );
        defer self.allocator.free(message);

        if (self.socket) |socket| {
            _ = try socket.write(message);
        }
    }

    fn flush(_: *anyopaque) !void {
        // Unix socket is unbuffered
    }

    fn deinit(ptr: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        if (self.socket) |socket| {
            socket.close();
        }
    }
};

/// Webhook output (HTTP POST to external endpoint)
pub const WebhookOutput = struct {
    const Self = @This();

    url: []const u8,
    client: std.http.Client,
    allocator: std.mem.Allocator,

    pub fn init(
        allocator: std.mem.Allocator,
        url: []const u8,
    ) !Self {
        return .{
            .url = url,
            .client = std.http.Client{ .allocator = allocator },
            .allocator = allocator,
        };
    }

    pub fn output(self: *Self) Output {
        return .{
            .ptr = self,
            .vtable = &.{
                .send = send,
                .flush = flush,
                .deinit = deinit,
            },
        };
    }

    fn send(ptr: *anyopaque, alert: anomaly.Alert) !void {
        const self: *Self = @ptrCast(@alignCast(ptr));

        // Format alert as JSON payload
        const payload = try std.fmt.allocPrint(
            self.allocator,
            \\{{"timestamp":{d},"severity":"{s}","type":"{s}","pid":{d},"syscall":{d},"z_score":{d:.2},"message":"{s}"}}
        ,
            .{
                alert.timestamp,
                @tagName(alert.severity),
                @tagName(alert.anomaly_type),
                alert.pid,
                alert.syscall_nr,
                alert.z_score,
                alert.message,
            },
        );
        defer self.allocator.free(payload);

        // Parse URL
        const uri = try std.Uri.parse(self.url);

        // Create HTTP request
        var req = try self.client.open(.POST, uri, .{
            .server_header_buffer = try self.allocator.alloc(u8, 4096),
        });
        defer req.deinit();
        defer self.allocator.free(req.server_header_buffer.?);

        req.transfer_encoding = .{ .content_length = payload.len };

        try req.send();
        try req.writeAll(payload);
        try req.finish();

        // Wait for response (but ignore it)
        try req.wait();
    }

    fn flush(_: *anyopaque) !void {
        // HTTP is synchronous
    }

    fn deinit(ptr: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.client.deinit();
    }
};
