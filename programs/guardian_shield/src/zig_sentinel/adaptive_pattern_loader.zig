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
// adaptive_pattern_loader.zig - Hardware-Aware Pattern Selection
//
// Purpose: Automatically select and load patterns based on detected hardware capabilities
// Architecture: Detects hardware → Selects profile → Loads appropriate pattern set
// Philosophy: The weapon adapts to its vessel
//

const std = @import("std");
const grimoire = @import("grimoire.zig");
const hardware_detector = @import("hardware_detector.zig");

/// Pattern loading result
pub const LoadResult = struct {
    /// Number of patterns loaded
    patterns_loaded: u32,

    /// Total memory consumed (bytes)
    memory_used: u64,

    /// Hardware profile used
    profile_name: []const u8,

    /// Features enabled
    features: Features,
};

/// Runtime features enabled
pub const Features = struct {
    multi_dimensional: bool = false,
    input_sovereignty: bool = false,
    resource_monitoring: bool = false,
    resource_monitoring_interval_sec: u32 = 0,
    network_monitoring: bool = false,
    network_monitoring_interval_sec: u32 = 0,
    xdp_layer: bool = false,
    dpdk_layer: bool = false,
};

/// Pattern priority entry
pub const PatternPriority = struct {
    pattern: *const grimoire.GrimoirePattern,
    weight: u32,
    category: []const u8,
};

/// Adaptive pattern loader
pub const AdaptivePatternLoader = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    detector: hardware_detector.HardwareDetector,
    capabilities: ?hardware_detector.HardwareCapabilities,

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .detector = hardware_detector.HardwareDetector.init(allocator),
            .capabilities = null,
        };
    }

    pub fn deinit(self: *Self) void {
        self.detector.deinit();
    }

    /// Detect hardware and load appropriate patterns
    pub fn detectAndLoad(self: *Self) !LoadResult {
        // Step 1: Detect hardware
        const caps = try self.detector.detect();
        self.capabilities = caps;

        std.log.info("Hardware detected: {s} (tier {d})", .{
            caps.profile_name[0..caps.profile_name_len],
            caps.tier,
        });
        std.log.info("  CPU Cores: {d}, L3 Cache: {d}MB, Memory: {d}MB", .{
            caps.cpu_cores,
            caps.l3_cache_mb,
            caps.total_memory_mb,
        });

        // Step 2: Select loading strategy based on tier
        const strategy = self.selectLoadingStrategy(caps.tier);

        // Step 3: Load patterns according to strategy
        const result = try self.loadPatternsForStrategy(strategy, &caps);

        std.log.info("Pattern loading complete:", .{});
        std.log.info("  Patterns loaded: {d}", .{result.patterns_loaded});
        std.log.info("  Memory used: {d} KB", .{result.memory_used / 1024});
        std.log.info("  Multi-dimensional: {}", .{result.features.multi_dimensional});

        return result;
    }

    /// Select loading strategy based on hardware tier
    fn selectLoadingStrategy(self: *Self, tier: u8) LoadingStrategy {
        _ = self;
        return switch (@as(hardware_detector.HardwareTier, @enumFromInt(tier))) {
            .embedded => .{
                .max_patterns = 5,
                .max_memory_mb = 1,
                .categories = &[_][]const u8{
                    "reverse_shell",
                    "privilege_escalation",
                    "fork_bomb",
                },
                .severity_filter = &[_]grimoire.Severity{.critical},
                .features = Features{
                    .multi_dimensional = false,
                    .input_sovereignty = false,
                    .resource_monitoring = false,
                    .network_monitoring = false,
                },
            },

            .laptop => .{
                .max_patterns = 20,
                .max_memory_mb = 30,
                .categories = &[_][]const u8{
                    "reverse_shell",
                    "privilege_escalation",
                    "fork_bomb",
                    "crypto_mining",
                },
                .severity_filter = &[_]grimoire.Severity{ .critical, .high },
                .features = Features{
                    .multi_dimensional = true,
                    .input_sovereignty = false,
                    .resource_monitoring = true,
                    .resource_monitoring_interval_sec = 5,
                    .network_monitoring = false,
                },
            },

            .server => .{
                .max_patterns = 1000,
                .max_memory_mb = 150,
                .categories = &[_][]const u8{
                    "reverse_shell",
                    "privilege_escalation",
                    "fork_bomb",
                    "crypto_mining",
                    "ransomware",
                    "data_exfiltration",
                    "rootkit",
                    "container_escape",
                },
                .severity_filter = &[_]grimoire.Severity{ .critical, .high, .warning },
                .features = Features{
                    .multi_dimensional = true,
                    .input_sovereignty = false,
                    .resource_monitoring = true,
                    .resource_monitoring_interval_sec = 2,
                    .network_monitoring = true,
                    .network_monitoring_interval_sec = 5,
                },
            },

            .c4d_instance => .{
                .max_patterns = 100000,
                .max_memory_mb = 15000,
                .categories = &[_][]const u8{"all"}, // Load everything
                .severity_filter = &[_]grimoire.Severity{ .critical, .high, .warning, .info, .debug },
                .features = Features{
                    .multi_dimensional = true,
                    .input_sovereignty = true,
                    .resource_monitoring = true,
                    .resource_monitoring_interval_sec = 1,
                    .network_monitoring = true,
                    .network_monitoring_interval_sec = 1,
                    .xdp_layer = true,
                    .dpdk_layer = true,
                },
            },
        };
    }

    /// Load patterns according to strategy
    fn loadPatternsForStrategy(
        self: *Self,
        strategy: LoadingStrategy,
        caps: *const hardware_detector.HardwareCapabilities,
    ) !LoadResult {
        _ = caps;
        _ = self;

        // For now, return simulated result
        // In real implementation, this would:
        // 1. Enumerate all available patterns
        // 2. Filter by category and severity
        // 3. Sort by priority/weight
        // 4. Select top N patterns within memory constraints
        // 5. Load into Grimoire engine

        var result = LoadResult{
            .patterns_loaded = 0,
            .memory_used = 0,
            .profile_name = undefined,
            .features = strategy.features,
        };

        // Simulate loading patterns
        const patterns_to_load = @min(strategy.max_patterns, grimoire.HOT_PATTERNS.len);
        result.patterns_loaded = @intCast(patterns_to_load);

        // Estimate memory usage (1.5KB per pattern average)
        result.memory_used = @as(u64, patterns_to_load) * 1536;

        // Set profile name
        result.profile_name = if (strategy.max_patterns <= 5)
            "embedded"
        else if (strategy.max_patterns <= 20)
            "laptop"
        else if (strategy.max_patterns <= 1000)
            "server"
        else
            "c4d_instance";

        return result;
    }

    /// Get recommended command line flags for detected hardware
    pub fn getRecommendedFlags(self: *Self) ![]const u8 {
        if (self.capabilities == null) {
            _ = try self.detector.detect();
        }

        const caps = self.capabilities.?;
        const profile = caps.profile_name[0..caps.profile_name_len];

        if (std.mem.eql(u8, profile, "embedded")) {
            return try std.fmt.allocPrint(
                self.allocator,
                "--enable-grimoire --pattern-limit 5 --severity critical",
                .{},
            );
        } else if (std.mem.eql(u8, profile, "laptop")) {
            return try std.fmt.allocPrint(
                self.allocator,
                "--enable-grimoire --enable-multi-dimensional --pattern-limit 20 --severity critical,high --resource-monitor-interval 5",
                .{},
            );
        } else if (std.mem.eql(u8, profile, "server")) {
            return try std.fmt.allocPrint(
                self.allocator,
                "--enable-grimoire --enable-multi-dimensional --pattern-limit 1000 --severity critical,high,medium --resource-monitor-interval 2 --network-monitor-interval 5",
                .{},
            );
        } else if (std.mem.eql(u8, profile, "c4d_instance")) {
            return try std.fmt.allocPrint(
                self.allocator,
                "--enable-grimoire --enable-multi-dimensional --enable-input-sovereignty --enable-xdp --enable-dpdk --pattern-limit 100000 --severity all --resource-monitor-interval 1 --network-monitor-interval 1 --threat-feed-enabled",
                .{},
            );
        }

        return try std.fmt.allocPrint(
            self.allocator,
            "--enable-grimoire",
            .{},
        );
    }

    /// Print configuration guide for detected hardware
    pub fn printConfigurationGuide(self: *Self) !void {
        if (self.capabilities == null) {
            self.capabilities = try self.detector.detect();
        }

        const caps = self.capabilities.?;

        hardware_detector.HardwareDetector.printCapabilities(&caps);

        std.debug.print("═══════════════════════════════════════════════════════════\n", .{});
        std.debug.print("RECOMMENDED COMMAND LINE\n", .{});
        std.debug.print("═══════════════════════════════════════════════════════════\n", .{});
        std.debug.print("\n", .{});

        const flags = try self.getRecommendedFlags();
        defer self.allocator.free(flags);

        std.debug.print("sudo ./zig-out/bin/zig-sentinel {s}\n", .{flags});
        std.debug.print("\n", .{});
    }
};

/// Loading strategy for a hardware tier
const LoadingStrategy = struct {
    max_patterns: u32,
    max_memory_mb: u32,
    categories: []const []const u8,
    severity_filter: []const grimoire.Severity,
    features: Features,
};

/// Export function to get adaptive configuration
pub fn getAdaptiveConfig(allocator: std.mem.Allocator) !LoadResult {
    var loader = AdaptivePatternLoader.init(allocator);
    defer loader.deinit();

    return try loader.detectAndLoad();
}

/// Test adaptive pattern loading
pub fn main() !void {
    const allocator = std.heap.c_allocator;

    var loader = AdaptivePatternLoader.init(allocator);
    defer loader.deinit();

    std.debug.print("═══════════════════════════════════════════════════════════\n", .{});
    std.debug.print("  GUARDIAN SHIELD - ADAPTIVE PATTERN LOADER\n", .{});
    std.debug.print("═══════════════════════════════════════════════════════════\n", .{});
    std.debug.print("\n", .{});

    // Print configuration guide
    try loader.printConfigurationGuide();

    // Detect and load patterns
    std.debug.print("═══════════════════════════════════════════════════════════\n", .{});
    std.debug.print("LOADING PATTERNS\n", .{});
    std.debug.print("═══════════════════════════════════════════════════════════\n", .{});
    std.debug.print("\n", .{});

    const result = try loader.detectAndLoad();

    std.debug.print("✅ Pattern loading complete\n", .{});
    std.debug.print("\n", .{});
    std.debug.print("Summary:\n", .{});
    std.debug.print("  Profile: {s}\n", .{result.profile_name});
    std.debug.print("  Patterns: {d}\n", .{result.patterns_loaded});
    std.debug.print("  Memory: {d} KB\n", .{result.memory_used / 1024});
    std.debug.print("\n", .{});
    std.debug.print("Features Enabled:\n", .{});
    std.debug.print("  Multi-Dimensional: {}\n", .{result.features.multi_dimensional});
    std.debug.print("  Input Sovereignty: {}\n", .{result.features.input_sovereignty});
    std.debug.print("  Resource Monitoring: {}\n", .{result.features.resource_monitoring});
    if (result.features.resource_monitoring) {
        std.debug.print("    Interval: {d}s\n", .{result.features.resource_monitoring_interval_sec});
    }
    std.debug.print("  Network Monitoring: {}\n", .{result.features.network_monitoring});
    if (result.features.network_monitoring) {
        std.debug.print("    Interval: {d}s\n", .{result.features.network_monitoring_interval_sec});
    }
    std.debug.print("  XDP Layer: {}\n", .{result.features.xdp_layer});
    std.debug.print("  DPDK Layer: {}\n", .{result.features.dpdk_layer});
    std.debug.print("\n", .{});
}
