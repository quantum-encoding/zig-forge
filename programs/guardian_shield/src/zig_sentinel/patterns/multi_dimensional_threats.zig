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
// multi_dimensional_threats.zig - Patterns That Span Multiple Dimensions
//
// Purpose: Define threats that require correlation across syscalls + resources + network
// Architecture: Uses MultiDimensionalDetector for convergence detection
// Philosophy: Single dimension is suspicion. All dimensions is truth.
//

const std = @import("std");
const grimoire = @import("../grimoire.zig");
const mdd = @import("../multi_dimensional_detector.zig");
const crypto_mining = @import("crypto_mining.zig");

/// ═══════════════════════════════════════════════════════════════════════════
/// PATTERN 1: GPU Crypto Miner (Multi-Dimensional)
/// ═══════════════════════════════════════════════════════════════════════════
///
/// This is the EVOLVED pattern. It combines:
///   - Dimension 1: Syscall ritual (grimoire.zig)
///   - Dimension 2: Resource gluttony (resource monitor)
///   - Dimension 3: Network tithe (network monitor)
///

/// Mining pool ports (Stratum protocol)
const MINING_POOL_PORTS = [_]u16{ 3333, 4444, 5555, 9999, 14444, 45560, 45700 };

/// Mining pool domain patterns
const MINING_POOL_DOMAINS = [_][]const u8{
    "pool.",       // pool.minexmr.com
    ".nanopool.",  // xmr-eu1.nanopool.org
    ".f2pool.",    // stratum.f2pool.com
    ".antpool.",   // stratum-btc.antpool.com
    "mining",      // any domain with "mining"
    "stratum",     // stratum servers
};

pub const crypto_miner_gpu_multidim = mdd.MultiDimensionalPattern{
    .id_hash = grimoire.GrimoirePattern.hashName("crypto_miner_gpu_md"),
    .name = grimoire.GrimoirePattern.makeName("crypto_miner_gpu_md"),
    .severity = .critical,

    // Dimension 1: The Syscall Ritual
    .syscall_pattern = &crypto_mining.crypto_miner_gpu,

    // Dimension 2: The Resource Gluttony
    .resource_constraints = mdd.ResourceConstraints{
        .min_sustained_cpu = 90.0,       // >90% CPU sustained
        .max_cpu_variance = 5.0,         // <5% variance (machine-like)
        .min_memory_mb = 500,            // >500MB memory
        .min_thread_count = 4,           // >4 threads
        .min_observation_sec = 10,       // 10 second observation window
    },

    // Dimension 3: The Network Tithe
    .network_constraints = mdd.NetworkConstraints{
        .forbidden_ports = &MINING_POOL_PORTS,
        .forbidden_domain_patterns = &MINING_POOL_DOMAINS,
        .min_connection_duration_sec = 5,
    },

    .description = "GPU cryptocurrency miner - multi-dimensional detection (syscalls + resources + network)",
    .enabled = true,
};

/// ═══════════════════════════════════════════════════════════════════════════
/// PATTERN 2: CPU Crypto Miner (Multi-Dimensional)
/// ═══════════════════════════════════════════════════════════════════════════

pub const crypto_miner_cpu_multidim = mdd.MultiDimensionalPattern{
    .id_hash = grimoire.GrimoirePattern.hashName("crypto_miner_cpu_md"),
    .name = grimoire.GrimoirePattern.makeName("crypto_miner_cpu_md"),
    .severity = .high,

    .syscall_pattern = &crypto_mining.crypto_miner_cpu,

    .resource_constraints = mdd.ResourceConstraints{
        .min_sustained_cpu = 85.0,       // Slightly lower for CPU-only
        .max_cpu_variance = 8.0,         // Slightly higher variance allowed
        .min_memory_mb = 200,            // Less memory than GPU
        .min_thread_count = 2,           // Fewer threads
        .min_observation_sec = 15,       // Longer observation
    },

    .network_constraints = mdd.NetworkConstraints{
        .forbidden_ports = &MINING_POOL_PORTS,
        .forbidden_domain_patterns = &MINING_POOL_DOMAINS,
        .min_connection_duration_sec = 5,
    },

    .description = "CPU cryptocurrency miner - multi-dimensional detection",
    .enabled = true,
};

/// ═══════════════════════════════════════════════════════════════════════════
/// PATTERN 3: Ransomware (Multi-Dimensional)
/// ═══════════════════════════════════════════════════════════════════════════
///
/// Behavior:
///   - Syscalls: Rapid file read/write/unlink sequence
///   - Resources: High CPU (encryption), massive disk I/O
///   - Network: Connection to C2 server, key exfiltration
///

// Ransomware syscall pattern (simplified - would need more sophistication)
const ransomware_syscall_pattern = grimoire.GrimoirePattern{
    .id_hash = grimoire.GrimoirePattern.hashName("ransomware_file_crypto"),
    .name = grimoire.GrimoirePattern.makeName("ransomware_file_crypto"),
    .step_count = 6,
    .severity = .critical,
    .max_sequence_window_ms = 1000,

    .steps = [_]grimoire.PatternStep{
        // Rapid file operations
        .{ .syscall_nr = grimoire.Syscall.openat, .max_time_delta_us = 0 },
        .{ .syscall_nr = grimoire.Syscall.read, .max_time_delta_us = 100_000 },
        .{ .syscall_nr = grimoire.Syscall.write, .max_time_delta_us = 100_000 },
        .{ .syscall_nr = grimoire.Syscall.close, .max_time_delta_us = 50_000 },
        .{ .syscall_nr = grimoire.Syscall.openat, .max_time_delta_us = 50_000 },
        .{ .syscall_nr = grimoire.Syscall.write, .max_time_delta_us = 100_000 },
    },
    .whitelisted_binaries = null,
};

pub const ransomware_multidim = mdd.MultiDimensionalPattern{
    .id_hash = grimoire.GrimoirePattern.hashName("ransomware_md"),
    .name = grimoire.GrimoirePattern.makeName("ransomware_md"),
    .severity = .critical,

    .syscall_pattern = &ransomware_syscall_pattern,

    .resource_constraints = mdd.ResourceConstraints{
        .min_sustained_cpu = 60.0,       // High CPU for encryption
        .max_cpu_variance = 15.0,        // More variable than miner
        .min_memory_mb = 100,
        .min_thread_count = 1,
        .min_observation_sec = 5,
    },

    // Network: C2 connection (would need specific ports/domains)
    .network_constraints = null, // Optional - ransomware might be offline

    .description = "Ransomware file encryption - multi-dimensional detection",
    .enabled = true,
};

/// ═══════════════════════════════════════════════════════════════════════════
/// ALL MULTI-DIMENSIONAL PATTERNS
/// ═══════════════════════════════════════════════════════════════════════════

pub const MULTI_DIMENSIONAL_PATTERNS = [_]mdd.MultiDimensionalPattern{
    crypto_miner_gpu_multidim,
    crypto_miner_cpu_multidim,
    ransomware_multidim,
};

pub const PATTERN_COUNT = MULTI_DIMENSIONAL_PATTERNS.len;
