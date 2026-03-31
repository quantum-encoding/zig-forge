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
// crypto_mining.zig - The Incantation of the Forbidden Miner
//
// Purpose: Detect cryptocurrency mining malware via behavioral patterns
// Detection: Multi-dimensional (syscalls + resource usage + network)
// Philosophy: The miner cannot hide its hunger for computation
//

const std = @import("std");
const grimoire = @import("../grimoire.zig");

/// ═══════════════════════════════════════════════════════════════════════════
/// PATTERN 1: GPU Crypto Miner (OpenCL/CUDA)
/// ═══════════════════════════════════════════════════════════════════════════
///
/// Behavior: Opens GPU device, allocates massive memory, spawns workers, connects to pool
/// Detection: GPU access + huge memory + worker threads + network connection
/// MITRE ATT&CK: T1496 (Resource Hijacking)
///
pub const crypto_miner_gpu = grimoire.GrimoirePattern{
    .id_hash = grimoire.GrimoirePattern.hashName("crypto_miner_gpu"),
    .name = grimoire.GrimoirePattern.makeName("crypto_miner_gpu"),
    .step_count = 6,
    .severity = .critical,
    .max_sequence_window_ms = 10_000, // 10 seconds to complete ritual

    .steps = [_]grimoire.PatternStep{
        // Step 1: Open GPU device (DRI or NVIDIA)
        .{
            .syscall_nr = grimoire.Syscall.openat,
            .process_relationship = .same_process,
            .max_time_delta_us = 0,
            .max_step_distance = 100,
            .arg_constraints = [_]?grimoire.ArgConstraint{
                // Path contains "/dev/dri" or "/dev/nvidia"
                .{
                    .arg_index = 1,
                    .constraint_type = .str_contains,
                    .value = .{ .str = grimoire.GrimoirePattern.makeConstraintStr("/dev/dri") }
                },
                null,
            },
        },

        // Step 2: Allocate huge GPU memory (>500MB)
        .{
            .syscall_nr = grimoire.Syscall.mmap,
            .process_relationship = .same_process,
            .max_time_delta_us = 5_000_000, // within 5 seconds
            .max_step_distance = 200,
            .arg_constraints = [_]?grimoire.ArgConstraint{
                // Size > 500MB (512 * 1024 * 1024 = 536870912)
                .{
                    .arg_index = 1,
                    .constraint_type = .greater_than,
                    .value = .{ .num = 536_870_912 }
                },
                null,
            },
        },

        // Step 3-5: Spawn multiple worker threads rapidly
        .{
            .syscall_nr = grimoire.Syscall.clone,
            .process_relationship = .same_process,
            .max_time_delta_us = 2_000_000,
            .max_step_distance = 50,
        },
        .{
            .syscall_nr = grimoire.Syscall.clone,
            .process_relationship = .same_process,
            .max_time_delta_us = 1_000_000,
            .max_step_distance = 20,
        },
        .{
            .syscall_nr = grimoire.Syscall.clone,
            .process_relationship = .same_process,
            .max_time_delta_us = 1_000_000,
            .max_step_distance = 20,
        },

        // Step 6: Connect to network (mining pool)
        .{
            .syscall_nr = grimoire.Syscall.connect,
            .process_relationship = .same_process,
            .max_time_delta_us = 5_000_000,
            .max_step_distance = 100,
        },
    },

    .whitelisted_binaries = null, // No legitimate binaries match this pattern
};

/// ═══════════════════════════════════════════════════════════════════════════
/// PATTERN 2: CPU-Only Crypto Miner (XMRig-style)
/// ═══════════════════════════════════════════════════════════════════════════
///
/// Behavior: Reads CPU info, spawns worker threads (one per core), connects to pool
/// Detection: CPU enumeration + rapid thread spawning + network
///
pub const crypto_miner_cpu = grimoire.GrimoirePattern{
    .id_hash = grimoire.GrimoirePattern.hashName("crypto_miner_cpu"),
    .name = grimoire.GrimoirePattern.makeName("crypto_miner_cpu"),
    .step_count = 6,
    .severity = .high,
    .max_sequence_window_ms = 5_000,

    .steps = [_]grimoire.PatternStep{
        // Step 1: Read CPU capabilities
        .{
            .syscall_nr = grimoire.Syscall.openat,
            .max_time_delta_us = 0,
            .max_step_distance = 50,
            .arg_constraints = [_]?grimoire.ArgConstraint{
                .{
                    .arg_index = 1,
                    .constraint_type = .str_equals,
                    .value = .{ .str = grimoire.GrimoirePattern.makeConstraintStr("/proc/cpuinfo") }
                },
                null,
            },
        },

        // Step 2-5: Spawn worker threads (rapid succession)
        .{
            .syscall_nr = grimoire.Syscall.clone,
            .max_time_delta_us = 2_000_000,
            .max_step_distance = 30,
        },
        .{
            .syscall_nr = grimoire.Syscall.clone,
            .max_time_delta_us = 500_000,
            .max_step_distance = 10,
        },
        .{
            .syscall_nr = grimoire.Syscall.clone,
            .max_time_delta_us = 500_000,
            .max_step_distance = 10,
        },
        .{
            .syscall_nr = grimoire.Syscall.clone,
            .max_time_delta_us = 500_000,
            .max_step_distance = 10,
        },

        // Step 6: Connect to mining pool
        .{
            .syscall_nr = grimoire.Syscall.connect,
            .max_time_delta_us = 3_000_000,
            .max_step_distance = 100,
        },
    },

    .whitelisted_binaries = null,
};

/// ═══════════════════════════════════════════════════════════════════════════
/// PATTERN 3: Stealth Miner (Process Injection)
/// ═══════════════════════════════════════════════════════════════════════════
///
/// Behavior: Injects into existing process, then starts mining
/// Detection: ptrace + memory allocation + worker spawning
///
pub const crypto_miner_injected = grimoire.GrimoirePattern{
    .id_hash = grimoire.GrimoirePattern.hashName("crypto_miner_injected"),
    .name = grimoire.GrimoirePattern.makeName("crypto_miner_injected"),
    .step_count = 6,
    .severity = .critical,
    .max_sequence_window_ms = 15_000,

    .steps = [_]grimoire.PatternStep{
        // Step 1: Attach to target process
        .{
            .syscall_nr = grimoire.Syscall.ptrace,
            .max_time_delta_us = 0,
            .max_step_distance = 50,
        },

        // Step 2: Allocate memory in target
        .{
            .syscall_class = .process_create, // process_vm_writev or similar
            .max_time_delta_us = 2_000_000,
            .max_step_distance = 50,
        },

        // Step 3: Open GPU device (if GPU mining)
        .{
            .syscall_nr = grimoire.Syscall.openat,
            .max_time_delta_us = 3_000_000,
            .max_step_distance = 100,
            .arg_constraints = [_]?grimoire.ArgConstraint{
                .{
                    .arg_index = 1,
                    .constraint_type = .str_contains,
                    .value = .{ .str = grimoire.GrimoirePattern.makeConstraintStr("/dev/dri") }
                },
                null,
            },
        },

        // Step 4-5: Spawn workers
        .{
            .syscall_nr = grimoire.Syscall.clone,
            .max_time_delta_us = 2_000_000,
            .max_step_distance = 50,
        },
        .{
            .syscall_nr = grimoire.Syscall.clone,
            .max_time_delta_us = 1_000_000,
            .max_step_distance = 20,
        },

        // Step 6: Connect to pool
        .{
            .syscall_nr = grimoire.Syscall.connect,
            .max_time_delta_us = 5_000_000,
            .max_step_distance = 100,
        },
    },

    .whitelisted_binaries = null,
};

/// ═══════════════════════════════════════════════════════════════════════════
/// RESOURCE-BASED DETECTION (Companion to syscall patterns)
/// ═══════════════════════════════════════════════════════════════════════════

/// Resource usage thresholds for crypto miner detection
pub const ResourceThresholds = struct {
    /// CPU usage percentage (sustained)
    cpu_threshold: f32 = 90.0,

    /// CPU usage variance (low variance = constant load)
    cpu_variance_threshold: f32 = 5.0,

    /// Memory usage in MB
    memory_mb_threshold: u64 = 500,

    /// GPU usage percentage (if available)
    gpu_threshold: f32 = 85.0,

    /// Minimum observation time (seconds) to avoid false positives
    min_observation_time_sec: u32 = 10,
};

/// Process resource metrics
pub const ProcessMetrics = struct {
    pid: u32,
    cpu_percent: f32,
    mem_mb: u64,
    gpu_percent: f32,
    thread_count: u32,
    network_connections: u32,
    timestamp_sec: u64,
};

/// Check if process matches crypto miner resource profile
pub fn isMinerResourceProfile(
    metrics: []const ProcessMetrics,
    thresholds: ResourceThresholds,
) bool {
    if (metrics.len == 0) return false;

    // Need minimum observation time
    const observation_time = metrics[metrics.len - 1].timestamp_sec - metrics[0].timestamp_sec;
    if (observation_time < thresholds.min_observation_time_sec) {
        return false;
    }

    // Calculate average CPU usage
    var cpu_sum: f32 = 0;
    for (metrics) |m| {
        cpu_sum += m.cpu_percent;
    }
    const cpu_avg = cpu_sum / @as(f32, @floatFromInt(metrics.len));

    // Calculate CPU variance
    var variance_sum: f32 = 0;
    for (metrics) |m| {
        const diff = m.cpu_percent - cpu_avg;
        variance_sum += diff * diff;
    }
    const cpu_variance = @sqrt(variance_sum / @as(f32, @floatFromInt(metrics.len)));

    // Check thresholds
    const high_cpu = cpu_avg >= thresholds.cpu_threshold;
    const constant_load = cpu_variance <= thresholds.cpu_variance_threshold;
    const high_memory = metrics[metrics.len - 1].mem_mb >= thresholds.memory_mb_threshold;

    return high_cpu and constant_load and high_memory;
}

/// ═══════════════════════════════════════════════════════════════════════════
/// NETWORK-BASED DETECTION
/// ═══════════════════════════════════════════════════════════════════════════

/// Common mining pool ports
pub const MINING_POOL_PORTS = [_]u16{
    3333,  // Stratum (most common)
    4444,  // Alternative Stratum
    5555,  // Some pools
    8080,  // HTTP mining proxies
    9999,  // Alternative protocol
    14444, // Monero-specific
    45560, // Zcash pools
    45700, // Ravencoin
};

/// Check if port is commonly used by mining pools
pub fn isMiningPoolPort(port: u16) bool {
    for (MINING_POOL_PORTS) |mining_port| {
        if (port == mining_port) return true;
    }
    return false;
}

/// Known mining pool domain patterns
pub const MINING_POOL_DOMAINS = [_][]const u8{
    "pool.",        // pool.minexmr.com, pool.supportxmr.com
    ".nanopool.",   // xmr-eu1.nanopool.org
    ".f2pool.",     // stratum.f2pool.com
    ".antpool.",    // stratum-btc.antpool.com
    "mining",       // any domain with "mining"
    "stratum",      // stratum servers
};

/// Check if domain matches known mining pool patterns
pub fn isMiningPoolDomain(domain: []const u8) bool {
    for (MINING_POOL_DOMAINS) |pattern| {
        if (std.mem.indexOf(u8, domain, pattern) != null) {
            return true;
        }
    }
    return false;
}
