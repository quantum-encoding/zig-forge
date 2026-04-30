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
// anomaly.zig - Anomaly detection engine for zig-sentinel
//
// Purpose: Real-time Z-score based anomaly detection
// Algorithm: Statistical deviation detection with configurable thresholds
//

const std = @import("std");
const time_compat = @import("time_compat.zig");
const baseline = @import("baseline.zig");
const emoji_sanitizer = @import("emoji_sanitizer.zig");

/// Alert severity levels (ordered by priority)
pub const Severity = enum {
    debug,
    info,
    warning,
    high,
    critical,

    /// Convert to numeric priority for comparison
    pub fn priority(self: Severity) u8 {
        return switch (self) {
            .debug => 0,
            .info => 1,
            .warning => 2,
            .high => 3,
            .critical => 4,
        };
    }

    /// Check if severity meets minimum threshold
    pub fn meetsThreshold(self: Severity, minimum: Severity) bool {
        return self.priority() >= minimum.priority();
    }
};

/// Anomaly type classification
pub const AnomalyType = enum {
    syscall_rate_spike,     // Sudden increase in syscall frequency
    syscall_rate_drop,      // Sudden decrease (process hanging?)
    new_syscall,            // Process using syscall for first time
    unknown_process,        // New PID without baseline
};

/// Anomaly alert structure
pub const Alert = struct {
    /// Timestamp when alert was generated (Unix epoch seconds)
    timestamp: i64,

    /// Alert severity
    severity: Severity,

    /// Anomaly type
    anomaly_type: AnomalyType,

    /// Process ID
    pid: u32,

    /// Syscall number
    syscall_nr: u32,

    /// Observed value (actual syscall count)
    observed: u64,

    /// Expected value (baseline mean)
    expected: f64,

    /// Standard deviation
    stddev: f64,

    /// Calculated Z-score
    z_score: f64,

    /// Process command name (enrichment data)
    comm: ?[]const u8,

    /// User ID (enrichment data)
    uid: ?u32,

    /// Human-readable message (owned, must be freed)
    message: []const u8,

    /// Whether this message is dynamically allocated
    message_is_owned: bool = true,

    /// Free the alert's message if it's dynamically allocated
    pub fn deinit(self: Alert, allocator: std.mem.Allocator) void {
        if (self.message_is_owned) {
            allocator.free(self.message);
        }
    }

    /// Format alert as string for display
    pub fn format(
        self: Alert,
        allocator: std.mem.Allocator,
    ) ![]const u8 {
        const severity_str = switch (self.severity) {
            .debug => "DEBUG",
            .info => "INFO",
            .warning => "WARN",
            .high => "HIGH",
            .critical => "CRIT",
        };

        const anomaly_str = switch (self.anomaly_type) {
            .syscall_rate_spike => "SPIKE",
            .syscall_rate_drop => "DROP",
            .new_syscall => "NEW",
            .unknown_process => "UNKNOWN",
        };

        return try std.fmt.allocPrint(
            allocator,
            "[{d}] {s}/{s} PID={d} syscall={d} obs={d} exp={d:.1} z={d:.2} | {s}",
            .{
                self.timestamp,
                severity_str,
                anomaly_str,
                self.pid,
                self.syscall_nr,
                self.observed,
                self.expected,
                self.z_score,
                self.message,
            },
        );
    }
};

/// Anomaly detection configuration
pub const DetectionConfig = struct {
    /// Z-score threshold for anomaly detection (default: 3.0 = 99.7% confidence)
    threshold_sigma: f64,

    /// Minimum observations required before detecting anomalies
    min_samples: u64,

    /// Severity mapping based on Z-score magnitude
    severity_thresholds: struct {
        warning: f64,  // Default: 3.0σ
        high: f64,     // Default: 5.0σ
        critical: f64, // Default: 10.0σ
    },

    /// Minimum severity to generate alerts
    minimum_severity: Severity,

    /// Enable emoji steganography detection in alert messages
    enable_emoji_scan: bool,

    /// Path for emoji anomaly forensic logs
    emoji_log_path: []const u8,

    pub fn init() DetectionConfig {
        return .{
            .threshold_sigma = 3.0,
            .min_samples = 10,
            .severity_thresholds = .{
                .warning = 3.0,
                .high = 5.0,
                .critical = 10.0,
            },
            .minimum_severity = .warning,
            .enable_emoji_scan = false,
            .emoji_log_path = "/var/log/zig-sentinel/emoji_anomalies.json",
        };
    }

    /// Determine severity based on Z-score magnitude
    pub fn determineSeverity(self: DetectionConfig, z_score: f64) Severity {
        const abs_z = @abs(z_score);
        if (abs_z >= self.severity_thresholds.critical) return .critical;
        if (abs_z >= self.severity_thresholds.high) return .high;
        if (abs_z >= self.severity_thresholds.warning) return .warning;
        return .info;
    }
};

/// Anomaly detection engine
pub const AnomalyDetector = struct {
    const Self = @This();

    /// Configuration
    config: DetectionConfig,

    /// Alert history for deduplication (keyed by (PID, syscall))
    /// Maps to last alert timestamp
    alert_history: std.AutoHashMap(baseline.BaselineKey, i64),

    /// Deduplication window (seconds)
    dedup_window_seconds: i64,

    /// Total alerts generated
    total_alerts: u64,

    /// Alerts by severity
    alerts_by_severity: [5]u64, // [debug, info, warning, high, critical]

    /// Emoji Guardian statistics
    emoji_scans_performed: u64,
    emoji_anomalies_detected: u64,
    emoji_messages_sanitized: u64,

    /// Allocator
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, config: DetectionConfig) Self {
        return .{
            .config = config,
            .alert_history = std.AutoHashMap(baseline.BaselineKey, i64).init(allocator),
            .dedup_window_seconds = 60, // 60 seconds
            .total_alerts = 0,
            .alerts_by_severity = [_]u64{0} ** 5,
            .emoji_scans_performed = 0,
            .emoji_anomalies_detected = 0,
            .emoji_messages_sanitized = 0,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        self.alert_history.deinit();
    }

    /// Check if observation is anomalous based on baseline
    pub fn detectAnomaly(
        self: *Self,
        key: baseline.BaselineKey,
        observed: u64,
        stats: baseline.BaselineStats,
    ) ?Alert {
        // Require minimum samples before detecting anomalies
        if (stats.count < self.config.min_samples) {
            return null;
        }

        // Calculate Z-score
        const observed_f64 = @as(f64, @floatFromInt(observed));
        const stddev_val = stats.stddev();

        // Avoid division by zero (constant baseline = no anomaly)
        if (stddev_val < 0.01) {
            return null;
        }

        const z_score = (observed_f64 - stats.mean) / stddev_val;

        // Check if Z-score exceeds threshold
        if (@abs(z_score) < self.config.threshold_sigma) {
            return null;
        }

        // Determine severity
        const severity = self.config.determineSeverity(z_score);

        // Check minimum severity threshold
        if (!severity.meetsThreshold(self.config.minimum_severity)) {
            return null;
        }

        // Check deduplication
        const current_time = time_compat.timestamp();
        if (self.alert_history.get(key)) |last_alert_time| {
            if (current_time - last_alert_time < self.dedup_window_seconds) {
                return null; // Duplicate alert, suppress
            }
        }

        // Update alert history
        self.alert_history.put(key, current_time) catch {
            // If we can't update history, still generate alert
        };

        // Determine anomaly type
        const anomaly_type: AnomalyType = if (z_score > 0)
            .syscall_rate_spike
        else
            .syscall_rate_drop;

        // Generate alert message (allocate on heap, will be freed when alert is processed)
        const raw_message = std.fmt.allocPrint(
            self.allocator,
            "Syscall rate anomaly: observed={d}, expected={d:.1}±{d:.1} ({d:.1}σ deviation)",
            .{ observed, stats.mean, stddev_val, z_score },
        ) catch {
            // Fallback to static string if allocation fails
            return Alert{
                .timestamp = current_time,
                .severity = severity,
                .anomaly_type = anomaly_type,
                .pid = key.pid,
                .syscall_nr = key.syscall_nr,
                .observed = observed,
                .expected = stats.mean,
                .stddev = stddev_val,
                .z_score = z_score,
                .comm = null,
                .uid = null,
                .message = "Syscall rate anomaly (message allocation failed)",
                .message_is_owned = false, // Static string, don't free
            };
        };

        // 🛡️ EMOJI GUARDIAN: Scan and sanitize message for steganography
        const message = if (self.config.enable_emoji_scan) blk: {
            self.emoji_scans_performed += 1;

            // Scan for malicious emoji
            const anomalies = emoji_sanitizer.scanText(self.allocator, raw_message) catch {
                // If scanning fails, use raw message
                break :blk raw_message;
            };
            defer self.allocator.free(anomalies);

            if (anomalies.len > 0) {
                // Malicious emoji detected! Log and sanitize
                self.emoji_anomalies_detected += anomalies.len;

                // Log to forensic file
                emoji_sanitizer.logAnomalies(
                    self.allocator,
                    anomalies,
                    self.config.emoji_log_path,
                    "zig-sentinel-alert",
                ) catch |err| {
                    std.debug.print("⚠️  Emoji Guardian: Failed to log anomalies: {any}\n", .{err});
                };

                // Sanitize the message
                const sanitized = emoji_sanitizer.sanitizeText(self.allocator, raw_message) catch {
                    // If sanitization fails, use raw message
                    break :blk raw_message;
                };

                // Free raw message and use sanitized version
                self.allocator.free(raw_message);
                self.emoji_messages_sanitized += 1;
                break :blk sanitized;
            } else {
                // No emoji anomalies, use raw message
                break :blk raw_message;
            }
        } else raw_message;

        // Create alert
        const alert = Alert{
            .timestamp = current_time,
            .severity = severity,
            .anomaly_type = anomaly_type,
            .pid = key.pid,
            .syscall_nr = key.syscall_nr,
            .observed = observed,
            .expected = stats.mean,
            .stddev = stddev_val,
            .z_score = z_score,
            .comm = null, // Will be enriched later
            .uid = null,  // Will be enriched later
            .message = message,
            .message_is_owned = true, // Allocated, must be freed
        };

        // Update statistics
        self.total_alerts += 1;
        self.alerts_by_severity[severity.priority()] += 1;

        return alert;
    }

    /// Get alert statistics summary
    pub fn getStats(self: *Self) struct {
        total: u64,
        debug: u64,
        info: u64,
        warning: u64,
        high: u64,
        critical: u64,
    } {
        return .{
            .total = self.total_alerts,
            .debug = self.alerts_by_severity[0],
            .info = self.alerts_by_severity[1],
            .warning = self.alerts_by_severity[2],
            .high = self.alerts_by_severity[3],
            .critical = self.alerts_by_severity[4],
        };
    }

    /// Display alert statistics
    pub fn displayStats(self: *Self) void {
        const stats = self.getStats();
        std.debug.print("🚨 Alert Statistics:\n", .{});
        std.debug.print("   Total:    {d}\n", .{stats.total});
        std.debug.print("   Critical: {d}\n", .{stats.critical});
        std.debug.print("   High:     {d}\n", .{stats.high});
        std.debug.print("   Warning:  {d}\n", .{stats.warning});
        std.debug.print("   Info:     {d}\n", .{stats.info});
        std.debug.print("   Debug:    {d}\n", .{stats.debug});

        // 🛡️ EMOJI GUARDIAN: Display steganography detection stats
        if (self.config.enable_emoji_scan) {
            std.debug.print("\n🛡️  Emoji Guardian Statistics:\n", .{});
            std.debug.print("   Messages scanned:     {d}\n", .{self.emoji_scans_performed});
            std.debug.print("   Emoji anomalies:      {d}\n", .{self.emoji_anomalies_detected});
            std.debug.print("   Messages sanitized:   {d}\n", .{self.emoji_messages_sanitized});
            if (self.emoji_anomalies_detected > 0) {
                std.debug.print("   Forensic log:         {s}\n", .{self.config.emoji_log_path});
            }
        }
    }
};

/// Alert queue for buffering and rate limiting
pub const AlertQueue = struct {
    const Self = @This();

    /// Maximum alerts per minute
    max_alerts_per_minute: u32,

    /// Token bucket for rate limiting
    tokens: f64,

    /// Maximum burst size
    burst_size: u32,

    /// Last refill time
    last_refill_time: i64,

    /// Alert buffer
    alerts: std.ArrayList(Alert),

    /// Allocator
    allocator: std.mem.Allocator,

    pub fn init(
        allocator: std.mem.Allocator,
        max_alerts_per_minute: u32,
        burst_size: u32,
    ) Self {
        return .{
            .max_alerts_per_minute = max_alerts_per_minute,
            .tokens = @as(f64, @floatFromInt(burst_size)),
            .burst_size = burst_size,
            .last_refill_time = time_compat.timestamp(),
            .alerts = std.ArrayList(Alert).empty,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        // Free alert messages
        for (self.alerts.items) |alert| {
            alert.deinit(self.allocator);
        }
        self.alerts.deinit(self.allocator);
    }

    /// Refill token bucket based on elapsed time
    fn refillTokens(self: *Self) void {
        const current_time = time_compat.timestamp();
        const elapsed = current_time - self.last_refill_time;

        if (elapsed > 0) {
            const tokens_per_second = @as(f64, @floatFromInt(self.max_alerts_per_minute)) / 60.0;
            const new_tokens = @as(f64, @floatFromInt(elapsed)) * tokens_per_second;
            self.tokens = @min(
                self.tokens + new_tokens,
                @as(f64, @floatFromInt(self.burst_size)),
            );
            self.last_refill_time = current_time;
        }
    }

    /// Try to enqueue an alert (returns false if rate limited)
    pub fn enqueue(self: *Self, alert: Alert) bool {
        self.refillTokens();

        if (self.tokens >= 1.0) {
            self.tokens -= 1.0;
            self.alerts.append(self.allocator, alert) catch return false;
            return true;
        }

        // Rate limited
        return false;
    }

    /// Drain all alerts from queue
    pub fn drain(self: *Self) []Alert {
        const items = self.alerts.items;
        self.alerts.clearRetainingCapacity();
        return items;
    }

    /// Get current queue size
    pub fn size(self: *Self) usize {
        return self.alerts.items.len;
    }
};
