// SPDX-License-Identifier: GPL-2.0
/*
 * Guardian Shield - eBPF-based System Security Framework
 *
 * syscall_counter.bpf.c - The Unified Oracle
 *
 * Copyright (c) 2025 Richard Tune / Quantum Encoding Ltd
 * Author: Richard Tune
 * Contact: info@quantumencoding.io
 * Website: https://quantumencoding.io
 *
 * License: Dual License - MIT (Non-Commercial) / Commercial License
 *
 * NON-COMMERCIAL USE (MIT License):
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to deal
 * in the Software without restriction for NON-COMMERCIAL purposes, including
 * without limitation the rights to use, copy, modify, merge, publish, distribute,
 * sublicense, and/or sell copies of the Software for non-commercial purposes,
 * and to permit persons to whom the Software is furnished to do so, subject to
 * the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in all
 * copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
 * SOFTWARE.
 *
 * COMMERCIAL USE:
 * Commercial use of this software requires a separate commercial license.
 * Contact info@quantumencoding.io for commercial licensing terms.
 *
 * ============================================================================
 *
 * Purpose: Dual-output eBPF program serving both statistical analysis and Grimoire pattern detection
 * Architecture: Single tracepoint, two execution paths
 * Attachment: tracepoint/raw_syscalls/sys_enter
 *
 * THE DOCTRINE OF THE UNIFIED ORACLE:
 *   - Statistical Path: Every syscall → counter update (existing)
 *   - Grimoire Path: Monitored syscalls only → full event to ring buffer (new)
 *   - One Oracle, Two Voices, Full Vision
 */

#include <linux/bpf.h>
#include <bpf/bpf_helpers.h>
#include <bpf/bpf_tracing.h>

/*
 * Syscall counter map: (PID, syscall_nr) -> count
 *
 * Type: Hash map
 * Key: struct { u32 pid; u32 syscall_nr; }
 * Value: u64 (call count)
 *
 * Max entries: 10240 (supports 10 PIDs * ~300 syscalls, or more PIDs with fewer syscalls)
 */

struct syscall_key {
    __u32 pid;
    __u32 syscall_nr;
};

struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __uint(max_entries, 10240);
    __type(key, struct syscall_key);
    __type(value, __u64);
} syscall_counts SEC(".maps");

/*
 * ============================================================
 * GRIMOIRE ORACLE STRUCTURES AND MAPS
 * ============================================================
 */

/* Grimoire's full syscall event (sent to userspace for pattern matching) */
struct grimoire_syscall_event {
    __u32 syscall_nr;       // Syscall number
    __u32 pid;              // Process ID
    __u64 timestamp_ns;     // Nanosecond timestamp
    __u64 args[6];          // Six syscall arguments
};

/* Grimoire ring buffer - streams monitored syscalls to userspace */
struct {
    __uint(type, BPF_MAP_TYPE_RINGBUF);
    __uint(max_entries, 1024 * 1024);  // 1MB
} grimoire_events SEC(".maps");

/* Monitored syscalls - hash set of syscall numbers to watch */
/* Key: syscall_nr, Value: 1 = monitored */
/* Populated by userspace from HOT_PATTERNS */
struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __uint(max_entries, 64);
    __type(key, __u32);    // syscall_nr
    __type(value, __u8);   // 1 = monitored
} monitored_syscalls SEC(".maps");

/* Grimoire configuration - runtime control */
/* Index 0: grimoire_enabled (1 = enabled, 0 = disabled) */
struct {
    __uint(type, BPF_MAP_TYPE_ARRAY);
    __uint(max_entries, 16);
    __type(key, __u32);
    __type(value, __u32);
} grimoire_config SEC(".maps");

/*
 * Tracepoint context for sys_enter
 *
 * Matches kernel's struct trace_event_raw_sys_enter:
 * - id: syscall number
 * - args[6]: syscall arguments (not used in this program)
 */
struct trace_event_raw_sys_enter {
    __u64 __unused__;
    long id;
    unsigned long args[6];
};

/*
 * eBPF program: trace_syscall_enter
 *
 * Invoked on EVERY syscall entry in the system.
 * Increments counter for (PID, syscall_nr) pair.
 *
 * Returns: 0 (always, required by eBPF)
 */
SEC("tracepoint/raw_syscalls/sys_enter")
int trace_syscall_enter(struct trace_event_raw_sys_enter *ctx)
{
    // Get current PID (process ID, not thread ID)
    __u64 pid_tgid = bpf_get_current_pid_tgid();
    __u32 pid = pid_tgid >> 32;  // Upper 32 bits = PID

    // Get syscall number from tracepoint context
    __u32 syscall_nr = (__u32)ctx->id;

    // Build map key
    struct syscall_key key = {
        .pid = pid,
        .syscall_nr = syscall_nr,
    };

    // Lookup current count
    __u64 *count = bpf_map_lookup_elem(&syscall_counts, &key);

    if (count) {
        // Entry exists, increment
        __sync_fetch_and_add(count, 1);
    } else {
        // Entry doesn't exist, create with count=1
        __u64 initial_count = 1;
        bpf_map_update_elem(&syscall_counts, &key, &initial_count, BPF_ANY);
    }

    /*
     * ============================================================
     * GRIMOIRE ORACLE PATH - Conditional Event Emission
     * ============================================================
     */

    // Check if Grimoire is enabled
    __u32 cfg_key = 0;
    __u32 *grimoire_enabled = bpf_map_lookup_elem(&grimoire_config, &cfg_key);
    if (!grimoire_enabled || !*grimoire_enabled) {
        return 0;  // Grimoire disabled
    }

    // Check if this syscall is monitored by Grimoire
    __u8 *monitored = bpf_map_lookup_elem(&monitored_syscalls, &syscall_nr);
    if (!monitored || !*monitored) {
        return 0;  // Not a monitored syscall
    }

    // This is a monitored syscall - emit full event to Grimoire ring buffer
    struct grimoire_syscall_event *event;
    event = bpf_ringbuf_reserve(&grimoire_events, sizeof(*event), 0);
    if (!event) {
        return 0;  // Ring buffer full, drop event
    }

    // Populate event
    event->syscall_nr = syscall_nr;
    event->pid = pid;  // Already extracted above
    event->timestamp_ns = bpf_ktime_get_ns();

    // Copy syscall arguments - manually unrolled for BPF verifier
    event->args[0] = ctx->args[0];
    event->args[1] = ctx->args[1];
    event->args[2] = ctx->args[2];
    event->args[3] = ctx->args[3];
    event->args[4] = ctx->args[4];
    event->args[5] = ctx->args[5];

    // Submit event to Grimoire ring buffer
    bpf_ringbuf_submit(event, 0);

    return 0;
}

char LICENSE[] SEC("license") = "GPL";
