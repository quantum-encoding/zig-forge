//! Guardian Shield - Input Sovereignty Module
//!
//! input-guardian.zig - The Sovereign Input Monitor
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
//!
//! Purpose: Monitor USB HID input devices and detect forbidden behavioral incantations
//! Architecture: Grimoire pattern matching engine adapted for input event streams
//! Philosophy: Judge the hands, not the mind
//!
//! THE DOCTRINE:
//!   We do not scan memory. We do not inspect files. We do not violate privacy.
//!   We observe only the player's input behavior.
//!   If hands perform physically impossible actions → judgment is passed.

const std = @import("std");
const time_compat = @import("time_compat.zig");
const patterns = @import("patterns/gaming_cheats.zig");

/// Linux input event structure (from linux/input.h)
pub const InputEvent = extern struct {
    /// Event timestamp
    time: extern struct {
        tv_sec: i64,
        tv_usec: i64,
    },

    /// Event type (EV_KEY, EV_REL, EV_ABS, etc.)
    type: u16,

    /// Specific code (button number, axis, etc.)
    code: u16,

    /// Value (button state, axis position, etc.)
    value: i32,

    /// Get timestamp in microseconds
    pub fn getTimestampUs(self: *const InputEvent) u64 {
        return @as(u64, @intCast(self.time.tv_sec)) * 1_000_000 + @as(u64, @intCast(self.time.tv_usec));
    }
};

/// Pattern match state
const MatchState = struct {
    /// Current step in pattern
    current_step: usize,

    /// Timestamp of first event in sequence (microseconds)
    first_timestamp_us: u64,

    /// Timestamp of last matched event (microseconds)
    last_timestamp_us: u64,

    /// Number of events since last match
    events_since_last: u32,

    pub fn init() MatchState {
        return .{
            .current_step = 0,
            .first_timestamp_us = 0,
            .last_timestamp_us = 0,
            .events_since_last = 0,
        };
    }

    pub fn reset(self: *MatchState) void {
        self.current_step = 0;
        self.first_timestamp_us = 0,
        self.last_timestamp_us = 0;
        self.events_since_last = 0;
    }
};

/// Pattern match result
pub const MatchResult = struct {
    matched: bool,
    pattern: ?*const patterns.InputPattern,
    timestamp_us: u64,
};

/// Input Guardian Engine
pub const InputGuardian = struct {
    const Self = @This();

    /// Allocator
    allocator: std.mem.Allocator,

    /// Pattern match states (one per pattern)
    match_states: []MatchState,

    /// Debug mode (print all events)
    debug_mode: bool,

    /// Enforcement mode (take action on detection)
    enforce_mode: bool,

    /// Event counter
    event_count: u64,

    pub fn init(allocator: std.mem.Allocator, debug_mode: bool, enforce_mode: bool) !Self {
        const match_states = try allocator.alloc(MatchState, patterns.PATTERN_COUNT);
        for (match_states) |*state| {
            state.* = MatchState.init();
        }

        return Self{
            .allocator = allocator,
            .match_states = match_states,
            .debug_mode = debug_mode,
            .enforce_mode = enforce_mode,
            .event_count = 0,
        };
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.match_states);
    }

    /// Process a single input event
    pub fn processEvent(self: *Self, event: *const InputEvent) !?MatchResult {
        self.event_count += 1;

        if (self.debug_mode) {
            std.debug.print("[{d:12}] Event: type={d} code={d:3} value={d:5}\n", .{
                event.getTimestampUs(),
                event.type,
                event.code,
                event.value,
            });
        }

        // Ignore sync events
        if (event.type == @intFromEnum(patterns.InputEventType.EV_SYN)) {
            return null;
        }

        const timestamp_us = event.getTimestampUs();

        // Check all patterns
        for (patterns.GAMING_CHEAT_PATTERNS, 0..) |pattern, pattern_idx| {
            if (!pattern.enabled) continue;

            var state = &self.match_states[pattern_idx];

            // Check if pattern window expired
            if (state.current_step > 0) {
                const time_since_first = timestamp_us - state.first_timestamp_us;
                const max_window_us = pattern.max_sequence_window_ms * 1000;

                if (time_since_first > max_window_us) {
                    // Pattern expired, reset
                    if (self.debug_mode) {
                        std.debug.print("  Pattern '{s}' expired ({d}us > {d}us)\n", .{
                            std.mem.sliceTo(&pattern.name, 0),
                            time_since_first,
                            max_window_us,
                        });
                    }
                    state.reset();
                }
            }

            // Try to match next step
            const step = pattern.steps[state.current_step];

            // Check event type
            if (step.event_type) |expected_type| {
                if (event.type != @intFromEnum(expected_type)) {
                    state.events_since_last += 1;
                    continue;
                }
            }

            // Check code
            if (step.code) |expected_code| {
                if (event.code != expected_code) {
                    state.events_since_last += 1;
                    continue;
                }
            }

            // Check value
            if (step.value) |expected_value| {
                if (event.value != expected_value) {
                    state.events_since_last += 1;
                    continue;
                }
            }

            // Check timing constraints
            if (state.current_step > 0) {
                const time_delta = timestamp_us - state.last_timestamp_us;

                // Check max time delta
                if (step.max_time_delta_us > 0 and time_delta > step.max_time_delta_us) {
                    if (self.debug_mode) {
                        std.debug.print("  Pattern '{s}' step {d}: time delta too large ({d}us > {d}us)\n", .{
                            std.mem.sliceTo(&pattern.name, 0),
                            state.current_step,
                            time_delta,
                            step.max_time_delta_us,
                        });
                    }
                    state.reset();
                    state.events_since_last = 0;
                    continue;
                }

                // Check min time delta (detect TOO FAST = inhuman)
                if (step.min_time_delta_us > 0 and time_delta < step.min_time_delta_us) {
                    if (self.debug_mode) {
                        std.debug.print("  Pattern '{s}' step {d}: time delta too small ({d}us < {d}us)\n", .{
                            std.mem.sliceTo(&pattern.name, 0),
                            state.current_step,
                            time_delta,
                            step.min_time_delta_us,
                        });
                    }
                    state.reset();
                    state.events_since_last = 0;
                    continue;
                }

                // Check step distance
                if (step.max_step_distance > 0 and state.events_since_last > step.max_step_distance) {
                    if (self.debug_mode) {
                        std.debug.print("  Pattern '{s}' step {d}: step distance too large ({d} > {d})\n", .{
                            std.mem.sliceTo(&pattern.name, 0),
                            state.current_step,
                            state.events_since_last,
                            step.max_step_distance,
                        });
                    }
                    state.reset();
                    state.events_since_last = 0;
                    continue;
                }
            }

            // Step matched!
            state.current_step += 1;
            state.last_timestamp_us = timestamp_us;
            state.events_since_last = 0;

            if (state.current_step == 1) {
                state.first_timestamp_us = timestamp_us;
            }

            if (self.debug_mode) {
                std.debug.print("  ✓ Pattern '{s}' step {d}/{d} matched\n", .{
                    std.mem.sliceTo(&pattern.name, 0),
                    state.current_step,
                    pattern.steps.len,
                });
            }

            // Check if pattern complete
            if (state.current_step >= pattern.steps.len) {
                const sequence_duration = timestamp_us - state.first_timestamp_us;

                std.log.err("🚨 FORBIDDEN INCANTATION DETECTED: {s}", .{std.mem.sliceTo(&pattern.name, 0)});
                std.log.err("   Severity: {s}", .{@tagName(pattern.severity)});
                std.log.err("   Sequence duration: {d}ms", .{sequence_duration / 1000});
                std.log.err("   Description: {s}", .{pattern.description});

                // Reset state for next detection
                state.reset();

                // Return match result
                return MatchResult{
                    .matched = true,
                    .pattern = &pattern,
                    .timestamp_us = timestamp_us,
                };
            }
        }

        return null;
    }

    /// Monitor an input device
    pub fn monitorDevice(self: *Self, device_path: []const u8, duration_sec: ?u32) !void {
        std.log.info("Opening input device: {s}", .{device_path});

        const fd = try std.posix.open(device_path, .{ .ACCMODE = .RDONLY }, 0);
        defer _ = std.c.close(fd);

        std.log.info("Input Guardian activated", .{});
        std.log.info("Monitoring {d} patterns", .{patterns.PATTERN_COUNT});
        if (self.enforce_mode) {
            std.log.warn("ENFORCEMENT MODE: Detections will trigger actions", .{});
        } else {
            std.log.info("Monitor mode: Detections logged only", .{});
        }

        const start_time = time_compat.milliTimestamp();

        while (true) {
            // Check if duration exceeded
            if (duration_sec) |dur| {
                const elapsed = @divTrunc(time_compat.milliTimestamp() - start_time, 1000);
                if (elapsed >= dur) {
                    std.log.info("Duration limit reached ({d}s)", .{dur});
                    break;
                }
            }

            var event: InputEvent = undefined;
            const bytes_read = try std.posix.read(fd, std.mem.asBytes(&event));

            if (bytes_read != @sizeOf(InputEvent)) {
                std.log.err("Incomplete read: {d} bytes", .{bytes_read});
                continue;
            }

            // Process event
            if (try self.processEvent(&event)) |result| {
                if (result.matched) {
                    // Pattern matched!
                    try self.handleDetection(result);
                }
            }
        }

        std.log.info("Input Guardian shutdown", .{});
        std.log.info("Total events processed: {d}", .{self.event_count});
    }

    /// Handle a pattern detection
    fn handleDetection(self: *Self, result: MatchResult) !void {
        const pattern = result.pattern.?;

        // Log to JSON
        try self.logDetectionJSON(result);

        if (self.enforce_mode) {
            // In a real game client, this would:
            // 1. Disconnect the player
            // 2. Send ban report to server
            // 3. Display message to player

            std.log.warn("⚔️  ENFORCEMENT: Player would be disconnected", .{});

            // For now, just log
            std.log.warn("   Pattern: {s}", .{std.mem.sliceTo(&pattern.name, 0)});
            std.log.warn("   Action: BAN_RECOMMENDED", .{});
        }
    }

    /// Log detection to JSON file
    fn logDetectionJSON(self: *Self, result: MatchResult) !void {
        _ = self;

        const pattern = result.pattern.?;

        // Create JSON log entry
        const json_log = try std.fmt.allocPrint(self.allocator,
            \\{{"timestamp_us": {d}, "pattern_id": "0x{x:0>16}", "pattern_name": "{s}", "severity": "{s}", "action": "{s}"}}
            \\
        , .{
            result.timestamp_us,
            pattern.id_hash,
            std.mem.sliceTo(&pattern.name, 0),
            @tagName(pattern.severity),
            if (self.enforce_mode) "enforce" else "logged",
        });
        defer self.allocator.free(json_log);

        // Write to log file
        const log_file = try std.Io.Dir.cwd().createFile("/tmp/input-guardian-alerts.json", .{ .truncate = false });
        defer log_file.close();

        try log_file.seekFromEnd(0);
        _ = try log_file.write(json_log);

        std.log.info("Detection logged to /tmp/input-guardian-alerts.json", .{});
    }
};

/// Main entry point
pub fn main() !void {
    const allocator = std.heap.c_allocator;

    // Parse command line arguments
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var device_path: ?[]const u8 = null;
    var duration_sec: ?u32 = null;
    var debug_mode = false;
    var enforce_mode = false;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (std.mem.eql(u8, arg, "--device")) {
            i += 1;
            if (i >= args.len) {
                std.log.err("--device requires a path", .{});
                return error.InvalidArgument;
            }
            device_path = args[i];
        } else if (std.mem.eql(u8, arg, "--duration")) {
            i += 1;
            if (i >= args.len) {
                std.log.err("--duration requires a number", .{});
                return error.InvalidArgument;
            }
            duration_sec = try std.fmt.parseInt(u32, args[i], 10);
        } else if (std.mem.eql(u8, arg, "--debug")) {
            debug_mode = true;
        } else if (std.mem.eql(u8, arg, "--enforce")) {
            enforce_mode = true;
        } else if (std.mem.eql(u8, arg, "--help")) {
            try printUsage();
            return;
        } else {
            std.log.err("Unknown argument: {s}", .{arg});
            return error.InvalidArgument;
        }
    }

    if (device_path == null) {
        std.log.err("--device is required", .{});
        try printUsage();
        return error.MissingArgument;
    }

    // Print header
    try printHeader();

    // Initialize guardian
    var guardian = try InputGuardian.init(allocator, debug_mode, enforce_mode);
    defer guardian.deinit();

    // Monitor device
    try guardian.monitorDevice(device_path.?, duration_sec);
}

fn printHeader() !void {
    const stderr = std.io.getStdErr().writer();
    try stderr.print(
        \\═══════════════════════════════════════════════════════════════
        \\⚖️  THE INPUT GUARDIAN: Sovereign Behavioral Monitor
        \\═══════════════════════════════════════════════════════════════
        \\
        \\We do not scan memory. We do not inspect files.
        \\We observe only the player's hands.
        \\If hands perform the forbidden incantation → judgment is passed.
        \\
        \\
    , .{});
}

fn printUsage() !void {
    const stderr = std.io.getStdErr().writer();
    try stderr.print(
        \\Usage: input-guardian [OPTIONS]
        \\
        \\OPTIONS:
        \\  --device PATH       Input device to monitor (e.g., /dev/input/event5)
        \\  --duration SECONDS  Monitor for N seconds (optional, default: infinite)
        \\  --debug             Enable debug mode (print all events)
        \\  --enforce           Enable enforcement mode (take action on detection)
        \\  --help              Show this help message
        \\
        \\EXAMPLES:
        \\  # Monitor gamepad in debug mode
        \\  sudo ./input-guardian --device /dev/input/event5 --debug
        \\
        \\  # Monitor for 60 seconds with enforcement
        \\  sudo ./input-guardian --device /dev/input/event5 --duration 60 --enforce
        \\
        \\
    , .{});
}
