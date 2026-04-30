//! Guardian Shield - eBPF-based Threat Detection Engine
//!
//! Zig Sentinel: Multi-dimensional behavioral threat detection with eBPF
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

const std = @import("std");
const time_compat = @import("time_compat.zig");
const baseline = @import("baseline.zig");
const anomaly = @import("anomaly.zig");
const outputs = @import("outputs.zig");
const correlation = @import("correlation.zig");
const grimoire = @import("grimoire.zig");

const c = @cImport({
    @cInclude("bpf/libbpf.h");
    @cInclude("bpf/bpf.h");
    @cInclude("linux/perf_event.h");
    @cInclude("sys/syscall.h");
    @cInclude("fcntl.h");
    @cInclude("unistd.h");
});

const VERSION = "6.0.0-grimoire"; // Phase 6: Sovereign Grimoire - Behavioral Pattern Detection

// Grimoire Oracle event structure (matches grimoire-oracle.bpf.c)
const GrimoireSyscallEvent = extern struct {
    syscall_nr: u32,
    pid: u32,
    timestamp_ns: u64,
    args: [6]u64,
};

// Context for Grimoire ring buffer callback
const GrimoireCallbackContext = struct {
    engine: *grimoire.GrimoireEngine,
    log_path: []const u8,
    enforce: bool,
    allocator: std.mem.Allocator,
};

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.c_allocator;

    // Parse command-line arguments using Args.Iterator for Zig 0.16.2187+
    var args_list: std.ArrayListUnmanaged([]const u8) = .empty;
    defer args_list.deinit(allocator);
    var args_iter = std.process.Args.Iterator.init(init.minimal.args);
    while (args_iter.next()) |arg| {
        try args_list.append(allocator, arg);
    }
    const args = args_list.items;

    if (args.len < 2) {
        printUsage(args[0]);
        return;
    }

    // Argument parsing (Phase 3: added detection options)
    var duration_seconds: u32 = 10;
    var attach_pid: ?i32 = null;
    var learning_period_seconds: u32 = 300; // Default: 5 minutes
    var enable_learning: bool = true;
    var baseline_path: []const u8 = "/var/lib/zig-sentinel/baselines";
    const auto_save_interval: u32 = 60; // Auto-save every 60 seconds
    var enable_detection: bool = true;  // Enable anomaly detection
    var detection_threshold: f64 = 3.0; // 3σ threshold (99.7% confidence)
    var load_baselines: bool = true;    // Load existing baselines on startup

    // Phase 4: Output configuration
    var enable_syslog: bool = false;
    var syslog_host: []const u8 = "127.0.0.1";
    var syslog_port: u16 = 514;
    var enable_json_log: bool = false;
    var json_log_path: []const u8 = "/var/log/zig-sentinel/alerts.json";
    _ = 10 * 1024 * 1024; // json_log_max_size: reserved for future use
    var enable_auditd: bool = false;
    var auditd_socket: []const u8 = "/var/run/auditd.sock";
    var enable_prometheus: bool = false;
    var prometheus_port: u16 = 9091;
    var enable_webhook: bool = false;
    var webhook_url: []const u8 = "";

    // Emoji Guardian configuration
    var enable_emoji_scan: bool = false;
    var emoji_log_path: []const u8 = "/var/log/zig-sentinel/emoji_anomalies.json";

    // V5.0: Correlation Engine configuration
    var enable_correlation: bool = false;
    var correlation_threshold: u32 = 100;
    var correlation_timeout_ms: u64 = 5000;
    var min_exfil_bytes: u64 = 512;
    var auto_terminate: bool = false;
    var correlation_log_path: []const u8 = "/var/log/zig-sentinel/correlation_alerts.json";

    // V6.0: Sovereign Grimoire configuration
    var enable_grimoire: bool = false;
    var grimoire_enforce: bool = false;  // Shadow mode by default
    var grimoire_debug: bool = false;    // Debug logging disabled by default
    var grimoire_log_path: []const u8 = "/var/log/zig-sentinel/grimoire_alerts.json";

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--version")) {
            std.debug.print("zig-sentinel version {s}\n", .{VERSION});
            return;
        } else if (std.mem.eql(u8, arg, "--help")) {
            printUsage(args[0]);
            return;
        } else if (std.mem.startsWith(u8, arg, "--duration=")) {
            const value = arg[11..];
            duration_seconds = try std.fmt.parseInt(u32, value, 10);
        } else if (std.mem.startsWith(u8, arg, "--attach-pid=")) {
            const value = arg[13..];
            attach_pid = try std.fmt.parseInt(i32, value, 10);
        } else if (std.mem.startsWith(u8, arg, "--learning-period=")) {
            const value = arg[18..];
            learning_period_seconds = try std.fmt.parseInt(u32, value, 10);
        } else if (std.mem.eql(u8, arg, "--no-learning")) {
            enable_learning = false;
        } else if (std.mem.startsWith(u8, arg, "--baseline-path=")) {
            baseline_path = arg[16..];
        } else if (std.mem.eql(u8, arg, "--no-detection")) {
            enable_detection = false;
        } else if (std.mem.startsWith(u8, arg, "--detection-threshold=")) {
            const value = arg[22..];
            detection_threshold = try std.fmt.parseFloat(f64, value);
        } else if (std.mem.eql(u8, arg, "--no-load-baselines")) {
            load_baselines = false;
        } else if (std.mem.eql(u8, arg, "--enable-syslog")) {
            enable_syslog = true;
        } else if (std.mem.startsWith(u8, arg, "--syslog-host=")) {
            syslog_host = arg[14..];
        } else if (std.mem.startsWith(u8, arg, "--syslog-port=")) {
            const value = arg[14..];
            syslog_port = try std.fmt.parseInt(u16, value, 10);
        } else if (std.mem.eql(u8, arg, "--enable-json-log")) {
            enable_json_log = true;
        } else if (std.mem.startsWith(u8, arg, "--json-log-path=")) {
            json_log_path = arg[16..];
        } else if (std.mem.eql(u8, arg, "--enable-auditd")) {
            enable_auditd = true;
        } else if (std.mem.startsWith(u8, arg, "--auditd-socket=")) {
            auditd_socket = arg[16..];
        } else if (std.mem.eql(u8, arg, "--enable-prometheus")) {
            enable_prometheus = true;
        } else if (std.mem.startsWith(u8, arg, "--prometheus-port=")) {
            const value = arg[18..];
            prometheus_port = try std.fmt.parseInt(u16, value, 10);
        } else if (std.mem.startsWith(u8, arg, "--webhook-url=")) {
            webhook_url = arg[14..];
            enable_webhook = true;
        } else if (std.mem.eql(u8, arg, "--enable-emoji-scan")) {
            enable_emoji_scan = true;
        } else if (std.mem.startsWith(u8, arg, "--emoji-log-path=")) {
            emoji_log_path = arg[17..];
        } else if (std.mem.eql(u8, arg, "--enable-correlation")) {
            enable_correlation = true;
        } else if (std.mem.startsWith(u8, arg, "--correlation-threshold=")) {
            const value = arg[24..];
            correlation_threshold = try std.fmt.parseInt(u32, value, 10);
        } else if (std.mem.startsWith(u8, arg, "--correlation-timeout=")) {
            const value = arg[22..];
            correlation_timeout_ms = try std.fmt.parseInt(u64, value, 10);
        } else if (std.mem.startsWith(u8, arg, "--min-exfil-bytes=")) {
            const value = arg[18..];
            min_exfil_bytes = try std.fmt.parseInt(u64, value, 10);
        } else if (std.mem.eql(u8, arg, "--auto-terminate")) {
            auto_terminate = true;
        } else if (std.mem.startsWith(u8, arg, "--correlation-log=")) {
            correlation_log_path = arg[18..];
        } else if (std.mem.eql(u8, arg, "--enable-grimoire")) {
            enable_grimoire = true;
        } else if (std.mem.eql(u8, arg, "--grimoire-enforce")) {
            grimoire_enforce = true;
        } else if (std.mem.eql(u8, arg, "--grimoire-debug")) {
            grimoire_debug = true;
        } else if (std.mem.startsWith(u8, arg, "--grimoire-log=")) {
            grimoire_log_path = arg[15..];
        }
    }

    std.debug.print("\n", .{});
    std.debug.print("🔭 zig-sentinel v{s} - The Watchtower\n", .{VERSION});
    std.debug.print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n", .{});
    if (attach_pid) |pid| {
        std.debug.print("📍 Monitoring PID: {d}\n", .{pid});
    } else {
        std.debug.print("📍 Monitoring: All processes\n", .{});
    }
    std.debug.print("⏱️  Duration: {d} seconds\n", .{duration_seconds});
    if (enable_learning) {
        std.debug.print("📚 Learning period: {d} seconds\n", .{learning_period_seconds});
        std.debug.print("💾 Baseline storage: {s}/\n", .{baseline_path});
    } else {
        std.debug.print("⚡ Learning disabled (detection-only mode)\n", .{});
    }
    if (enable_detection) {
        std.debug.print("🚨 Anomaly detection: ENABLED (threshold: {d:.1}σ)\n", .{detection_threshold});
    } else {
        std.debug.print("🚨 Anomaly detection: DISABLED\n", .{});
    }
    if (enable_emoji_scan) {
        std.debug.print("🛡️  Emoji Guardian: ENABLED\n", .{});
        std.debug.print("📝 Emoji forensics: {s}\n", .{emoji_log_path});
    }
    if (enable_correlation) {
        std.debug.print("🔗 Correlation Engine (V5): ENABLED\n", .{});
        std.debug.print("📊 Alert threshold: {d} points\n", .{correlation_threshold});
        std.debug.print("⏱️  Sequence window: {d}ms\n", .{correlation_timeout_ms});
        std.debug.print("📏 Min exfil bytes: {d}\n", .{min_exfil_bytes});
        if (auto_terminate) {
            std.debug.print("⚠️  Auto-terminate: ENABLED (processes will be killed on detection)\n", .{});
        }
        std.debug.print("📝 Correlation log: {s}\n", .{correlation_log_path});
    }
    if (enable_grimoire) {
        std.debug.print("📖 Sovereign Grimoire (V6): ENABLED\n", .{});
        std.debug.print("🛡️  Pattern detection: {d} patterns in L1 cache\n", .{grimoire.HOT_PATTERNS.len});
        if (grimoire_enforce) {
            std.debug.print("⚔️  Enforcement: ACTIVE (processes will be terminated on pattern match)\n", .{});
        } else {
            std.debug.print("👁️  Shadow mode: ACTIVE (detection only, no enforcement)\n", .{});
        }
        std.debug.print("📝 Grimoire log: {s}\n", .{grimoire_log_path});
    }
    std.debug.print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n\n", .{});

    // Load eBPF program
    std.debug.print("🔧 Loading eBPF program...\n", .{});

    const bpf_obj_path = "src/zig-sentinel/ebpf/syscall_counter.bpf.o";

    // Note: Skipping libbpf_set_print for now due to va_list complexity in Zig 0.16
    // Errors will be printed to stderr by libbpf automatically

    const obj = c.bpf_object__open(bpf_obj_path) orelse {
        std.debug.print("❌ Failed to open eBPF object: {s}\n", .{bpf_obj_path});
        std.debug.print("   Make sure the file exists and you have permissions.\n", .{});
        return error.BPFOpenFailed;
    };
    defer c.bpf_object__close(obj);

    if (c.bpf_object__load(obj) != 0) {
        std.debug.print("❌ Failed to load eBPF object into kernel\n", .{});
        std.debug.print("   This requires root privileges (CAP_BPF).\n", .{});
        std.debug.print("   Try: sudo ./zig-out/bin/zig-sentinel --duration=10\n", .{});
        return error.BPFLoadFailed;
    }

    std.debug.print("✅ eBPF program loaded successfully\n", .{});

    // Find the tracepoint program
    const prog = c.bpf_object__find_program_by_name(obj, "trace_syscall_enter") orelse {
        std.debug.print("❌ Failed to find program: trace_syscall_enter\n", .{});
        return error.ProgramNotFound;
    };

    // Attach to tracepoint
    std.debug.print("🔗 Attaching to tracepoint: raw_syscalls/sys_enter\n", .{});

    const link = c.bpf_program__attach(prog) orelse {
        std.debug.print("❌ Failed to attach eBPF program\n", .{});
        return error.AttachFailed;
    };
    defer _ = c.bpf_link__destroy(link);

    std.debug.print("✅ eBPF program attached\n\n", .{});

    // UNIFIED ORACLE: Grimoire maps are now in the main BPF program
    // No separate BPF loading - the main tracepoint serves both purposes
    var grimoire_events_fd: c_int = -1;
    var monitored_syscalls_fd: c_int = -1;
    var grimoire_config_fd: c_int = -1;

    if (enable_grimoire) {
        std.debug.print("🔧 Activating Grimoire Oracle (Unified Architecture)...\n", .{});

        // Get Grimoire maps from the SAME BPF object as statistics
        grimoire_events_fd = c.bpf_object__find_map_fd_by_name(obj, "grimoire_events");
        monitored_syscalls_fd = c.bpf_object__find_map_fd_by_name(obj, "monitored_syscalls");
        grimoire_config_fd = c.bpf_object__find_map_fd_by_name(obj, "grimoire_config");

        if (grimoire_events_fd < 0 or monitored_syscalls_fd < 0 or grimoire_config_fd < 0) {
            std.debug.print("❌ Failed to find Grimoire maps in unified BPF program\n", .{});
            std.debug.print("   Ensure syscall_counter.bpf.c has Grimoire maps compiled in\n", .{});
            return error.GrimoireBPFMapNotFound;
        }

        std.debug.print("✅ Grimoire maps located in unified Oracle\n", .{});

        // Populate monitored_syscalls map from HOT_PATTERNS
        try populateMonitoredSyscalls(monitored_syscalls_fd);

        // Enable Grimoire in the unified BPF program
        const key: u32 = 0;
        const val: u32 = 1;
        _ = c.bpf_map_update_elem(grimoire_config_fd, &key, &val, c.BPF_ANY);

        const syscall_count = countMonitoredSyscalls();
        std.debug.print("📖 Grimoire monitoring {d} unique syscalls from {d} patterns\n", .{
            syscall_count,
            grimoire.HOT_PATTERNS.len,
        });
        std.debug.print("✅ Unified Oracle activated (one tracepoint, two voices)\n\n", .{});
    }

    // Find the map
    const map = c.bpf_object__find_map_by_name(obj, "syscall_counts") orelse {
        std.debug.print("❌ Failed to find map: syscall_counts\n", .{});
        return error.MapNotFound;
    };

    const map_fd = c.bpf_map__fd(map);
    if (map_fd < 0) {
        std.debug.print("❌ Failed to get map FD\n", .{});
        return error.MapFDInvalid;
    }

    // Initialize baseline learning context
    var baseline_ctx = baseline.BaselineContext.init(
        allocator,
        learning_period_seconds,
        baseline_path,
    );
    defer baseline_ctx.deinit();

    // Load existing baselines if requested
    if (load_baselines) {
        const loaded = try baseline.loadAllBaselines(&baseline_ctx);
        if (loaded > 0) {
            std.debug.print("📖 Loaded baselines for {d} processes ({d} patterns)\n",
                .{ loaded, baseline_ctx.baselines.count() });
            baseline_ctx.is_learning = false; // Skip learning if we have baselines
        }
    }

    // Initialize anomaly detection engine
    var detection_config = anomaly.DetectionConfig.init();
    detection_config.threshold_sigma = detection_threshold;
    detection_config.enable_emoji_scan = enable_emoji_scan;
    detection_config.emoji_log_path = emoji_log_path;
    var detector = anomaly.AnomalyDetector.init(allocator, detection_config);
    defer detector.deinit();

    // Initialize alert queue (100 alerts/min, burst of 10)
    var alert_queue = anomaly.AlertQueue.init(allocator, 100, 10);
    defer alert_queue.deinit();

    // V5.0: Initialize correlation engine
    var correlation_config = correlation.CorrelationConfig.init();
    correlation_config.enabled = enable_correlation;
    correlation_config.alert_threshold = correlation_threshold;
    correlation_config.sequence_timeout_ms = correlation_timeout_ms;
    correlation_config.min_exfil_bytes = min_exfil_bytes;
    correlation_config.auto_terminate = auto_terminate;
    correlation_config.log_path = correlation_log_path;

    var corr_engine = correlation.CorrelationEngine.init(allocator, correlation_config);
    defer corr_engine.deinit();

    // V6.0: Initialize Grimoire pattern detection engine
    var grimoire_engine = try grimoire.GrimoireEngine.init(allocator, grimoire_debug);
    defer grimoire_engine.deinit();

    // Setup Grimoire ring buffer consumer
    var grimoire_callback_ctx = GrimoireCallbackContext{
        .engine = &grimoire_engine,
        .log_path = grimoire_log_path,
        .enforce = grimoire_enforce,
        .allocator = allocator,
    };

    var grimoire_rb: ?*c.ring_buffer = null;
    if (enable_grimoire and grimoire_events_fd >= 0) {
        grimoire_rb = c.ring_buffer__new(
            grimoire_events_fd,
            handleGrimoireEvent,
            &grimoire_callback_ctx,
            null,
        );
        if (grimoire_rb == null) {
            std.debug.print("⚠️  Failed to create Grimoire ring buffer consumer\n", .{});
        } else {
            std.debug.print("✅ Grimoire ring buffer consumer ready\n", .{});
        }
    }
    defer {
        if (grimoire_rb) |rb| c.ring_buffer__free(rb);
    }

    if (enable_learning and baseline_ctx.is_learning) {
        std.debug.print("📚 Learning mode: Establishing behavioral baselines...\n\n", .{});
    } else if (enable_detection) {
        std.debug.print("🚨 Detection mode: Monitoring for anomalies...\n\n", .{});
    } else {
        std.debug.print("📊 Collecting syscall statistics...\n\n", .{});
    }

    // Monitor for specified duration with periodic updates
    const start_time = time_compat.milliTimestamp();
    const end_time = start_time + @as(i64, duration_seconds) * 1000;
    var last_update_time = start_time;
    var last_save_time = start_time;
    const update_interval_ms: i64 = 1000; // Update every 1 second
    const save_interval_ms: i64 = @as(i64, auto_save_interval) * 1000;

    while (time_compat.milliTimestamp() < end_time) {
        // Sleep 100ms using linux.nanosleep
        _ = std.os.linux.nanosleep(&std.os.linux.timespec{ .sec = 0, .nsec = 100_000_000 }, null);

        // Poll Grimoire ring buffer (10Hz polling rate)
        if (enable_grimoire and grimoire_rb != null) {
            const events_processed = c.ring_buffer__poll(grimoire_rb.?, 100); // 100ms timeout
            if (events_processed < 0) {
                std.debug.print("\n⚠️  Grimoire ring buffer poll error\n", .{});
            }
        }

        const current_time = time_compat.milliTimestamp();

        // Periodic update (every second)
        if (current_time - last_update_time >= update_interval_ms) {
            if (enable_learning and baseline_ctx.is_learning) {
                // Update baselines with current syscall counts
                try updateBaselines(&baseline_ctx, map_fd);
                baseline_ctx.checkLearningComplete();
                baseline_ctx.displayProgress();
            } else if (enable_detection) {
                // Anomaly detection mode
                const alerts_detected = try detectAnomalies(
                    &baseline_ctx,
                    &detector,
                    &alert_queue,
                    map_fd,
                );

                // Display progress with alert count
                const elapsed = @divTrunc(current_time - start_time, 1000);
                if (enable_grimoire and grimoire_engine.total_matches > 0) {
                    std.debug.print("\r⏱️  Elapsed: {d}/{d}s | 🚨 Alerts: {d} | 📖 Grimoire: {d}   ",
                        .{ elapsed, duration_seconds, detector.total_alerts, grimoire_engine.total_matches });
                } else if (alerts_detected > 0) {
                    std.debug.print("\r⏱️  Elapsed: {d}/{d}s | 🚨 Alerts: {d}   ",
                        .{ elapsed, duration_seconds, detector.total_alerts });
                } else {
                    std.debug.print("\r⏱️  Elapsed: {d}/{d}s | ✅ No anomalies   ",
                        .{ elapsed, duration_seconds });
                }

                // Update baselines in detection mode (adaptive learning)
                if (enable_learning) {
                    try updateBaselines(&baseline_ctx, map_fd);
                }
            } else {
                const elapsed = @divTrunc(current_time - start_time, 1000);
                std.debug.print("\r⏱️  Elapsed: {d}/{d}s", .{ elapsed, duration_seconds });
            }

            last_update_time = current_time;
        }

        // Periodic auto-save
        if (enable_learning and current_time - last_save_time >= save_interval_ms) {
            try baseline.saveAllBaselines(&baseline_ctx);
            last_save_time = current_time;
        }
    }

    std.debug.print("\n\n", .{});

    // Final save of baselines
    if (enable_learning) {
        try baseline.saveAllBaselines(&baseline_ctx);
    }

    // Display alert summary if detection was enabled
    if (enable_detection and detector.total_alerts > 0) {
        std.debug.print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n", .{});
        detector.displayStats();
        std.debug.print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n\n", .{});
    }

    // V5.0: Display correlation statistics
    if (enable_correlation and corr_engine.total_alerts > 0) {
        std.debug.print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n", .{});
        corr_engine.displayStats();
        std.debug.print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n\n", .{});
    }

    // V6.0: Display Grimoire statistics
    if (enable_grimoire and grimoire_engine.total_matches > 0) {
        std.debug.print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n", .{});
        grimoire_engine.displayStats();
        std.debug.print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n\n", .{});
    }

    // Display queued alerts (both anomaly and correlation)
    if (enable_detection and detector.total_alerts > 0) {

        // Display queued alerts
        const queued_alerts = alert_queue.drain();
        if (queued_alerts.len > 0) {
            std.debug.print("📋 Recent Alerts:\n\n", .{});
            const display_count = @min(10, queued_alerts.len);

            // Display first 10 alerts
            for (queued_alerts[0..display_count]) |alert| {
                const formatted = try alert.format(allocator);
                defer allocator.free(formatted);
                std.debug.print("{s}\n", .{formatted});
                alert.deinit(allocator);
            }

            // Free remaining alerts that weren't displayed
            for (queued_alerts[display_count..]) |alert| {
                alert.deinit(allocator);
            }

            if (queued_alerts.len > 10) {
                std.debug.print("\n... and {d} more alerts (use --duration for longer monitoring)\n", .{queued_alerts.len - 10});
            }

            std.debug.print("\n", .{});
        }
    }

    // Read and display results
    try displayResults(allocator, map_fd, attach_pid, &baseline_ctx, enable_learning);

    // Grimoire statistics are now integrated into the main syscall statistics
    // The unified Oracle architecture eliminates separate BPF stats
    if (enable_grimoire) {
        std.debug.print("\n📊 Grimoire Unified Oracle:\n", .{});
        std.debug.print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n", .{});
        std.debug.print("   Status: ACTIVE (one tracepoint, full syscall vision)\n", .{});
        std.debug.print("   Architecture: Unified (statistical + behavioral)\n", .{});
        std.debug.print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n", .{});
    }

    std.debug.print("\n✅ Monitoring complete\n\n", .{});
}

/// Detect anomalies by comparing current counts to baselines
fn detectAnomalies(
    baseline_ctx: *baseline.BaselineContext,
    detector: *anomaly.AnomalyDetector,
    alert_queue: *anomaly.AlertQueue,
    map_fd: c_int,
) !usize {
    var alerts_this_cycle: usize = 0;

    var key: extern struct {
        pid: u32,
        syscall_nr: u32,
    } = undefined;
    var next_key: @TypeOf(key) = undefined;
    var value: u64 = undefined;

    // Iterate through BPF map
    if (c.bpf_map_get_next_key(map_fd, null, &next_key) == 0) {
        key = next_key;

        while (true) {
            if (c.bpf_map_lookup_elem(map_fd, &key, &value) == 0) {
                const baseline_key = baseline.BaselineKey{
                    .pid = key.pid,
                    .syscall_nr = key.syscall_nr,
                };

                // Check if we have a baseline for this (PID, syscall) pair
                if (baseline_ctx.getBaseline(baseline_key)) |stats| {
                    // Detect anomaly
                    if (detector.detectAnomaly(baseline_key, value, stats)) |alert| {
                        // Enqueue alert (rate limited)
                        if (alert_queue.enqueue(alert)) {
                            alerts_this_cycle += 1;
                        } else {
                            // Alert was rate limited, free its message
                            alert.deinit(baseline_ctx.allocator);
                        }
                    }
                }
            }

            if (c.bpf_map_get_next_key(map_fd, &key, &next_key) != 0) {
                break;
            }
            key = next_key;
        }
    }

    return alerts_this_cycle;
}

/// Update baselines with current syscall counts from BPF map
fn updateBaselines(ctx: *baseline.BaselineContext, map_fd: c_int) !void {
    var key: extern struct {
        pid: u32,
        syscall_nr: u32,
    } = undefined;
    var next_key: @TypeOf(key) = undefined;
    var value: u64 = undefined;

    // Iterate through BPF map
    if (c.bpf_map_get_next_key(map_fd, null, &next_key) == 0) {
        key = next_key;

        while (true) {
            if (c.bpf_map_lookup_elem(map_fd, &key, &value) == 0) {
                const baseline_key = baseline.BaselineKey{
                    .pid = key.pid,
                    .syscall_nr = key.syscall_nr,
                };
                try ctx.updateBaseline(baseline_key, value);
            }

            if (c.bpf_map_get_next_key(map_fd, &key, &next_key) != 0) {
                break;
            }
            key = next_key;
        }
    }
}

fn displayResults(
    allocator: std.mem.Allocator,
    map_fd: c_int,
    filter_pid: ?i32,
    ctx: *baseline.BaselineContext,
    show_baselines: bool,
) !void {
    std.debug.print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n", .{});
    std.debug.print("📈 Syscall Statistics\n", .{});
    std.debug.print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n\n", .{});

    // Iterate through map entries
    var key: extern struct {
        pid: u32,
        syscall_nr: u32,
    } = undefined;
    var next_key: @TypeOf(key) = undefined;
    var value: u64 = undefined;

    // Track totals per PID
    var pid_totals = std.AutoHashMap(u32, u64).init(allocator);
    defer pid_totals.deinit();

    // Collect all entries
    var entries = std.ArrayList(struct {
        pid: u32,
        syscall_nr: u32,
        count: u64,
    }){};
    defer entries.deinit(allocator);

    // Get first key
    if (c.bpf_map_get_next_key(map_fd, null, &next_key) == 0) {
        key = next_key;

        while (true) {
            // Lookup value
            if (c.bpf_map_lookup_elem(map_fd, &key, &value) == 0) {
                // Filter by PID if specified
                if (filter_pid == null or filter_pid.? == @as(i32, @intCast(key.pid))) {
                    try entries.append(allocator, .{
                        .pid = key.pid,
                        .syscall_nr = key.syscall_nr,
                        .count = value,
                    });

                    // Update PID total
                    const total = pid_totals.get(key.pid) orelse 0;
                    try pid_totals.put(key.pid, total + value);
                }
            }

            // Get next key
            if (c.bpf_map_get_next_key(map_fd, &key, &next_key) != 0) {
                break;
            }
            key = next_key;
        }
    }

    if (entries.items.len == 0) {
        std.debug.print("⚠️  No syscalls captured (try longer duration or check PID)\n", .{});
        return;
    }

    // Sort by count (descending)
    std.mem.sort(@TypeOf(entries.items[0]), entries.items, {}, struct {
        fn lessThan(_: void, a: @TypeOf(entries.items[0]), b: @TypeOf(entries.items[0])) bool {
            return a.count > b.count;
        }
    }.lessThan);

    // Display top 20 entries
    const display_count = @min(20, entries.items.len);

    std.debug.print("Top {d} syscalls (by frequency):\n\n", .{display_count});
    std.debug.print("{s:<8} {s:<15} {s:>12}\n", .{ "PID", "SYSCALL", "COUNT" });
    std.debug.print("{s}\n", .{"─" ** 40});

    for (entries.items[0..display_count]) |entry| {
        const syscall_name = getSyscallName(entry.syscall_nr);
        std.debug.print("{d:<8} {s:<15} {d:>12}", .{ entry.pid, syscall_name, entry.count });

        // Show baseline stats if available
        if (show_baselines) {
            const baseline_key = baseline.BaselineKey{
                .pid = entry.pid,
                .syscall_nr = entry.syscall_nr,
            };
            if (ctx.getBaseline(baseline_key)) |stats| {
                std.debug.print("  | μ={d:.1} σ={d:.1}", .{ stats.mean, stats.stddev() });
            }
        }
        std.debug.print("\n", .{});
    }

    // Display per-PID totals
    std.debug.print("\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n", .{});
    std.debug.print("📊 Per-Process Totals\n\n", .{});

    var pid_iter = pid_totals.iterator();
    while (pid_iter.next()) |kv| {
        std.debug.print("PID {d}: {d} total syscalls\n", .{ kv.key_ptr.*, kv.value_ptr.* });
    }

    // Display baseline summary if learning was enabled
    if (show_baselines and ctx.baselines.count() > 0) {
        std.debug.print("\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n", .{});
        std.debug.print("📚 Baseline Learning Summary\n\n", .{});
        std.debug.print("Total baseline patterns learned: {d}\n", .{ctx.baselines.count()});
        std.debug.print("Unique processes monitored: {d}\n", .{pid_totals.count()});
        std.debug.print("Baseline storage: {s}/\n", .{ctx.storage_path});
    }
}

fn getSyscallName(nr: u32) []const u8 {
    // Common x86_64 syscalls (Phase 1: minimal set)
    return switch (nr) {
        0 => "read",
        1 => "write",
        2 => "open",
        3 => "close",
        4 => "stat",
        5 => "fstat",
        8 => "lseek",
        9 => "mmap",
        10 => "mprotect",
        11 => "munmap",
        12 => "brk",
        16 => "ioctl",
        21 => "access",
        39 => "getpid",
        56 => "clone",
        57 => "fork",
        59 => "execve",
        60 => "exit",
        61 => "wait4",
        63 => "uname",
        78 => "getdents",
        79 => "getcwd",
        217 => "getdents64",
        231 => "exit_group",
        257 => "openat",
        262 => "newfstatat",
        else => {
            // Return syscall number as string for unknown syscalls
            return std.fmt.allocPrint(std.heap.page_allocator, "sys_{d}", .{nr}) catch "unknown";
        },
    };
}

// ============================================================
// Grimoire Integration Functions
// ============================================================

/// Populate monitored_syscalls BPF map from HOT_PATTERNS
fn populateMonitoredSyscalls(map_fd: c_int) !void {
    const val: u8 = 1; // 1 = monitored

    var count: usize = 0;
    var seen = std.AutoHashMap(u32, void).init(std.heap.page_allocator);
    defer seen.deinit();

    // Iterate through all patterns
    for (&grimoire.HOT_PATTERNS) |*pattern| {
        // Iterate through all steps in this pattern
        for (pattern.steps[0..pattern.step_count]) |*step| {
            // If step has a specific syscall number, add it to monitored set
            if (step.syscall_nr) |syscall_nr| {
                const key: u32 = syscall_nr;
                _ = c.bpf_map_update_elem(map_fd, &key, &val, c.BPF_ANY);
                count += 1;

                // Track unique syscalls for debug output
                if (!seen.contains(syscall_nr)) {
                    try seen.put(syscall_nr, {});
                    std.debug.print("   → syscall {d} added to BPF map\n", .{syscall_nr});
                }
            }
        }
    }

    std.debug.print("📌 Populated {d} syscall entries in monitored_syscalls map\n", .{count});
}

/// Count unique syscalls across all HOT_PATTERNS
fn countMonitoredSyscalls() usize {
    var seen = std.AutoHashMap(u32, void).init(std.heap.page_allocator);
    defer seen.deinit();

    for (&grimoire.HOT_PATTERNS) |*pattern| {
        for (pattern.steps[0..pattern.step_count]) |*step| {
            if (step.syscall_nr) |nr| {
                seen.put(nr, {}) catch {};
            }
        }
    }

    return seen.count();
}

/// Ring buffer callback for Grimoire events
fn handleGrimoireEvent(ctx: ?*anyopaque, data: ?*anyopaque, size: usize) callconv(.c) c_int {
    _ = size;

    // Cast context
    const callback_ctx = @as(*GrimoireCallbackContext, @ptrCast(@alignCast(ctx orelse return 0)));

    // Cast data to event
    const event_ptr = @as(*const GrimoireSyscallEvent, @ptrCast(@alignCast(data orelse return 0)));
    const event = event_ptr.*;

    // Process through Grimoire engine
    const match_result = callback_ctx.engine.processSyscall(
        event.pid,
        event.syscall_nr,
        event.timestamp_ns,
        event.args,
    ) catch |err| {
        std.debug.print("⚠️  Grimoire processSyscall error: {any}\n", .{err});
        return 0;
    };

    // If pattern matched
    if (match_result) |result| {
        // Log to console
        const pattern_name = std.mem.sliceTo(&result.pattern.name, 0);

        // Debug: Print severity as raw byte to diagnose corruption (unsafe cast to see memory)
        const severity_ptr: *const u8 = @ptrCast(&result.pattern.severity);
        const severity_byte = severity_ptr.*;
        const severity_names = [_][]const u8{ "debug", "info", "warning", "high", "critical" };
        const severity_str = if (severity_byte < severity_names.len) severity_names[severity_byte] else "CORRUPTED";

        std.debug.print("\n🚨 GRIMOIRE MATCH: {s} (PID={d}, severity={s} [0x{x}])\n", .{
            pattern_name,
            result.pid,
            severity_str,
            severity_byte,
        });

        // Audit log to JSON
        logGrimoireMatch(
            callback_ctx.allocator,
            result,
            callback_ctx.log_path,
            callback_ctx.enforce,
        ) catch |err| {
            std.debug.print("⚠️  Failed to log Grimoire match: {any}\n", .{err});
        };

        // Enforce if enabled (use safe byte comparison to avoid enum corruption crash)
        const is_critical = severity_byte == 4; // 4 = critical in Severity enum
        if (callback_ctx.enforce and is_critical) {
            std.debug.print("⚔️  Enforcement mode: Terminating PID {d}...\n", .{result.pid});
            const kill_result = std.posix.kill(@intCast(result.pid), std.posix.SIG.KILL);
            _ = kill_result catch |err| {
                std.debug.print("⚠️  Failed to terminate PID {d}: {any}\n", .{result.pid, err});
            };
            std.debug.print("⚔️  TERMINATED PID {d} (pattern: {s})\n", .{
                result.pid,
                pattern_name,
            });
        }
    }

    return 0;
}

/// Log Grimoire pattern match to JSON file
fn logGrimoireMatch(
    allocator: std.mem.Allocator,
    result: grimoire.MatchResult,
    log_path: []const u8,
    enforced: bool,
) !void {
    // Create log directory if it doesn't exist
    const log_dir = std.fs.path.dirname(log_path) orelse "/var/log/zig-sentinel";
    var log_dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    if (log_dir.len >= log_dir_buf.len) return error.NameTooLong;
    @memcpy(log_dir_buf[0..log_dir.len], log_dir);
    log_dir_buf[log_dir.len] = 0;
    const mkdir_result = std.c.mkdir(@ptrCast(&log_dir_buf), 0o755);
    if (mkdir_result < 0) {
        const err = std.posix.errno(mkdir_result);
        if (err != .EXIST) return error.MkdirFailed;
    }

    // Create null-terminated path for file open
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    if (log_path.len >= path_buf.len) return error.NameTooLong;
    @memcpy(path_buf[0..log_path.len], log_path);
    path_buf[log_path.len] = 0;

    // Open log file in append mode (create if needed)
    const fd = c.open(@ptrCast(&path_buf), c.O_WRONLY | c.O_CREAT | c.O_APPEND, @as(c_uint, 0o644));
    if (fd < 0) return error.OpenFailed;
    defer _ = c.close(fd);

    // Format JSON log entry
    const pattern_name = std.mem.sliceTo(&result.pattern.name, 0);
    // Safe severity conversion (avoid @tagName crash on corrupted values)
    const severity_ptr: *const u8 = @ptrCast(&result.pattern.severity);
    const severity_byte = severity_ptr.*;
    const severity_names = [_][]const u8{ "debug", "info", "warning", "high", "critical" };
    const severity_str = if (severity_byte < severity_names.len) severity_names[severity_byte] else "corrupted";

    const json = try std.fmt.allocPrint(allocator,
        \\{{"timestamp": {d}, "pattern_id": "0x{x}", "pattern_name": "{s}", "severity": "{s}", "pid": {d}, "action": "{s}"}}
        \\
    , .{
        result.timestamp_ns,
        result.pattern.id_hash,
        pattern_name,
        severity_str,
        result.pid,
        if (enforced) "terminated" else "logged",
    });
    defer allocator.free(json);

    const write_result = c.write(fd, json.ptr, json.len);
    if (write_result < 0) return error.WriteError;
}

fn printUsage(prog_name: []const u8) void {
    std.debug.print("\n", .{});
    std.debug.print("🔭 zig-sentinel v{s} - eBPF-based Anomaly Detection\n", .{VERSION});
    std.debug.print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n", .{});
    std.debug.print("\nUsage: {s} [options]\n\n", .{prog_name});
    std.debug.print("Options:\n", .{});
    std.debug.print("  --duration=N                Monitor for N seconds (default: 10)\n", .{});
    std.debug.print("  --attach-pid=PID            Only monitor specific PID\n", .{});
    std.debug.print("  --learning-period=N         Learning period in seconds (default: 300)\n", .{});
    std.debug.print("  --no-learning               Disable baseline learning\n", .{});
    std.debug.print("  --baseline-path=PATH        Baseline storage directory\n", .{});
    std.debug.print("                              (default: /var/lib/zig-sentinel/baselines)\n", .{});
    std.debug.print("  --detection-threshold=N     Z-score threshold for anomalies (default: 3.0)\n", .{});
    std.debug.print("  --no-detection              Disable anomaly detection\n", .{});
    std.debug.print("  --no-load-baselines         Don't load existing baselines\n", .{});
    std.debug.print("  --enable-emoji-scan         Enable emoji steganography detection\n", .{});
    std.debug.print("  --emoji-log-path=PATH       Emoji anomaly log file\n", .{});
    std.debug.print("                              (default: /var/log/zig-sentinel/emoji_anomalies.json)\n", .{});
    std.debug.print("\n  V5.0 Correlation Engine Options:\n", .{});
    std.debug.print("  --enable-correlation        Enable syscall sequence correlation (exfiltration detection)\n", .{});
    std.debug.print("  --correlation-threshold=N   Alert score threshold (default: 100)\n", .{});
    std.debug.print("  --correlation-timeout=MS    Sequence window in milliseconds (default: 5000)\n", .{});
    std.debug.print("  --min-exfil-bytes=N         Minimum bytes for exfiltration alert (default: 512)\n", .{});
    std.debug.print("  --auto-terminate            Kill processes on exfiltration detection (DANGEROUS!)\n", .{});
    std.debug.print("  --correlation-log=PATH      Correlation alert log file\n", .{});
    std.debug.print("                              (default: /var/log/zig-sentinel/correlation_alerts.json)\n", .{});
    std.debug.print("\n  V6.0 Sovereign Grimoire Options:\n", .{});
    std.debug.print("  --enable-grimoire           Enable behavioral pattern detection (5 patterns in L1 cache)\n", .{});
    std.debug.print("  --grimoire-enforce          Enable enforcement mode (terminate on match, default: shadow mode)\n", .{});
    std.debug.print("  --grimoire-debug            Enable verbose debug logging (syscall tracing)\n", .{});
    std.debug.print("  --grimoire-log=PATH         Grimoire alert log file\n", .{});
    std.debug.print("                              (default: /var/log/zig-sentinel/grimoire_alerts.json)\n", .{});
    std.debug.print("\n  General Options:\n", .{});
    std.debug.print("  --version                   Print version\n", .{});
    std.debug.print("  --help                      Show this help\n", .{});
    std.debug.print("\nExamples:\n", .{});
    std.debug.print("  # Phase 1: Basic monitoring (no learning, no detection)\n", .{});
    std.debug.print("  sudo {s} --duration=30 --no-learning --no-detection\n", .{prog_name});
    std.debug.print("\n  # Phase 2: Learn baselines for 5 minutes\n", .{});
    std.debug.print("  sudo {s} --duration=300 --learning-period=300\n", .{prog_name});
    std.debug.print("\n  # Phase 3: Detect anomalies using learned baselines\n", .{});
    std.debug.print("  sudo {s} --duration=60 --baseline-path=/tmp/sentinel-test\n", .{prog_name});
    std.debug.print("\n  # Phase 3: Stricter detection (2σ threshold)\n", .{});
    std.debug.print("  sudo {s} --detection-threshold=2.0\n", .{prog_name});
    std.debug.print("\n  # Phase 4: Enable Emoji Guardian (steganography detection)\n", .{});
    std.debug.print("  sudo {s} --duration=60 --enable-emoji-scan\n", .{prog_name});
    std.debug.print("\n  # Phase 5: Enable Correlation Engine (exfiltration detection)\n", .{});
    std.debug.print("  sudo {s} --duration=60 --enable-correlation\n", .{prog_name});
    std.debug.print("\n  # Phase 5: Stricter correlation threshold with auto-terminate (DANGEROUS!)\n", .{});
    std.debug.print("  sudo {s} --enable-correlation --correlation-threshold=120 --auto-terminate\n", .{prog_name});
    std.debug.print("\n  # Phase 6: Enable Grimoire (pattern detection, shadow mode)\n", .{});
    std.debug.print("  sudo {s} --duration=3600 --enable-grimoire\n", .{prog_name});
    std.debug.print("\n  # Phase 6: Grimoire with enforcement (EXPERIMENTAL!)\n", .{});
    std.debug.print("  sudo {s} --enable-grimoire --grimoire-enforce\n", .{prog_name});
    std.debug.print("\nNote: Requires root privileges (CAP_BPF) to load eBPF programs.\n\n", .{});
}
