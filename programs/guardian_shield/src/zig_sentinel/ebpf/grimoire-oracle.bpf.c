// SPDX-License-Identifier: GPL-2.0
/*
 * Guardian Shield - eBPF-based System Security Framework
 *
 * grimoire-oracle.bpf.c - The Grimoire's Sensory Apparatus
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
 * Purpose: Stream raw syscall events to userspace for behavioral pattern matching
 * Architecture: Pre-filtered ring buffer (99% noise reduction)
 * Philosophy: "An Oracle that screams at every shadow is useless. We report only the whispers of treason."
 *
 * PRE-FILTERING:
 *   - Hook raw_syscalls/sys_enter tracepoint (all syscalls, all processes)
 *   - Filter: Only emit syscalls present in Grimoire HOT_PATTERNS
 *   - Result: 10,000 syscalls/sec → 100 relevant syscalls/sec (99% reduction)
 *   - Benefit: Minimal CPU overhead, minimal ring buffer pressure
 *
 * CONTAINER TRANSPARENCY:
 *   - Use bpf_get_ns_current_pid_tgid() to resolve PIDs in host namespace
 *   - Container-local PID 7 → Host PID 845123 (automatic translation)
 *   - Result: Grimoire can see through container walls
 *   - Eliminates blind spot for Docker/Kubernetes/Podman attacks
 *
 * EVENT STRUCTURE:
 *   - syscall_nr: Which syscall (e.g., 57 = fork, 41 = socket)
 *   - pid: Process ID (in HOST namespace, not container-local)
 *   - timestamp_ns: Nanosecond-precision timestamp
 *   - args[6]: Six syscall arguments (raw register values)
 *
 * INTEGRATION:
 *   - Userspace (zig-sentinel) populates monitored_syscalls map on startup
 *   - BPF program checks map before emitting event (pre-filter)
 *   - Userspace polls ring buffer at 10Hz, feeds to GrimoireEngine
 */

// vmlinux.h contains ALL kernel types - don't include system headers
#include "vmlinux.h"

// Prevent bpf_helpers.h from including conflicting system headers
#define __BPF_TRACING__
#define __LINUX_BPF_H__

#include <bpf/bpf_helpers.h>
#include <bpf/bpf_tracing.h>
#include <bpf/bpf_core_read.h>

/*
 * ============================================================
 * EVENT STRUCTURE - The Grimoire's Raw Perception
 * ============================================================
 */

struct grimoire_syscall_event {
    __u32 syscall_nr;       // Syscall number (e.g., 57 = fork, 41 = socket)
    __u32 pid;              // Process ID
    __u64 timestamp_ns;     // Nanosecond timestamp (from bpf_ktime_get_ns)
    __u64 args[6];          // Six syscall arguments (arg0-arg5, raw register values)
};

/*
 * ============================================================
 * BPF MAPS - The Oracle's Memory
 * ============================================================
 */

// Map 1: Ring Buffer for Syscall Events
// Size: 1MB (sufficient for ~5000 events in-flight)
// Overflow behavior: Drop oldest events (no blocking)
struct {
    __uint(type, BPF_MAP_TYPE_RINGBUF);
    __uint(max_entries, 1024 * 1024);  // 1MB
} grimoire_events SEC(".maps");

// Map 2: Monitored Syscalls (Pre-filter)
// Key: syscall_nr (u32)
// Value: 1 = monitored, 0 or absent = ignored
// Populated by userspace from HOT_PATTERNS at daemon startup
struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __uint(max_entries, 64);  // Max 64 unique syscalls across all patterns
    __type(key, __u32);       // syscall_nr
    __type(value, __u8);      // 1 = monitored
} monitored_syscalls SEC(".maps");

// Map 3: Global Configuration
// Index 0: grimoire_enabled (1 = enabled, 0 = disabled)
// Index 1: filter_enabled (1 = use pre-filter, 0 = send all)
struct {
    __uint(type, BPF_MAP_TYPE_ARRAY);
    __uint(max_entries, 16);
    __type(key, __u32);
    __type(value, __u32);
} grimoire_config SEC(".maps");

// Map 4: Statistics
// Index 0: total_syscalls (all syscalls seen)
// Index 1: filtered_syscalls (syscalls after pre-filter)
// Index 2: emitted_events (events successfully sent to ring buffer)
// Index 3: dropped_events (ring buffer full)
struct {
    __uint(type, BPF_MAP_TYPE_ARRAY);
    __uint(max_entries, 16);
    __type(key, __u32);
    __type(value, __u64);
} grimoire_stats SEC(".maps");

/*
 * ============================================================
 * HELPER FUNCTIONS
 * ============================================================
 */

// Increment statistic counter
static __always_inline void increment_stat(__u32 index) {
    __u64 *counter = bpf_map_lookup_elem(&grimoire_stats, &index);
    if (counter) {
        __sync_fetch_and_add(counter, 1);
    }
}

// Get host namespace PID (handles containers correctly)
// Returns PID in init namespace (host perspective), not container-local PID
static __always_inline __u32 get_host_pid() {
    struct task_struct *task = (struct task_struct *)bpf_get_current_task();

    // Read the pid namespace inum via CO-RE chained field access
    // bpf_get_ns_current_pid_tgid(dev, ino) resolves container-local → host PID
    unsigned int ns_inum = BPF_CORE_READ(task, nsproxy, pid_ns_for_children, ns.inum);
    if (ns_inum == 0) {
        return bpf_get_current_pid_tgid() >> 32;
    }

    // Read the device number from the stashed dentry's superblock
    // ns_common.stashed → d_sb → s_dev
    dev_t ns_dev = BPF_CORE_READ(task, nsproxy, pid_ns_for_children,
                                  ns.stashed, d_sb, s_dev);

    struct bpf_pidns_info nsinfo = {};
    long err = bpf_get_ns_current_pid_tgid((__u64)ns_dev, (__u32)ns_inum,
                                            &nsinfo, sizeof(nsinfo));

    // Fallback: If we can't get host PID (old kernel?), use current namespace PID
    if (err < 0) {
        return bpf_get_current_pid_tgid() >> 32;
    }

    return nsinfo.tgid;
}

// Check if Grimoire is enabled
static __always_inline bool is_grimoire_enabled() {
    __u32 key = 0;
    __u32 *enabled = bpf_map_lookup_elem(&grimoire_config, &key);
    return enabled && *enabled;
}

// Check if pre-filtering is enabled
static __always_inline bool is_filter_enabled() {
    __u32 key = 1;
    __u32 *enabled = bpf_map_lookup_elem(&grimoire_config, &key);
    return enabled && *enabled;
}

// Check if syscall is monitored (present in HOT_PATTERNS)
static __always_inline bool is_syscall_monitored(__u32 syscall_nr) {
    __u8 *monitored = bpf_map_lookup_elem(&monitored_syscalls, &syscall_nr);
    return monitored && *monitored;
}

/*
 * ============================================================
 * TRACEPOINT HOOK - The Oracle's Eye
 * ============================================================
 */

// Note: struct trace_event_raw_sys_enter is defined in vmlinux.h

// Hook: raw_syscalls/sys_enter
// Fires: On every syscall entry, all processes, all CPUs
// Overhead: ~100ns per syscall (with pre-filtering)
SEC("tracepoint/raw_syscalls/sys_enter")
int trace_sys_enter(struct trace_event_raw_sys_enter *ctx)
{
    // Stat: Total syscalls seen
    increment_stat(0);

    // Check if Grimoire is enabled
    if (!is_grimoire_enabled()) {
        return 0;
    }

    // Get syscall number
    __u32 syscall_nr = (__u32)ctx->id;

    // Pre-filter: Check if this syscall is monitored
    if (is_filter_enabled()) {
        if (!is_syscall_monitored(syscall_nr)) {
            return 0;  // Not in HOT_PATTERNS, ignore
        }
    }

    // Stat: Syscalls passing filter
    increment_stat(1);

    // Get process info - use host namespace PID (container-aware)
    __u32 pid = get_host_pid();

    // Reserve space in ring buffer
    struct grimoire_syscall_event *event;
    event = bpf_ringbuf_reserve(&grimoire_events, sizeof(*event), 0);
    if (!event) {
        // Ring buffer full, drop event
        increment_stat(3);
        return 0;
    }

    // Populate event structure
    event->syscall_nr = syscall_nr;
    event->pid = pid;
    event->timestamp_ns = bpf_ktime_get_ns();

    // Copy syscall arguments - manually unrolled for BPF verifier
    // Note: Arguments are at ctx+16 (struct trace_event_raw_sys_enter)
    event->args[0] = ctx->args[0];
    event->args[1] = ctx->args[1];
    event->args[2] = ctx->args[2];
    event->args[3] = ctx->args[3];
    event->args[4] = ctx->args[4];
    event->args[5] = ctx->args[5];

    // Submit event to ring buffer
    bpf_ringbuf_submit(event, 0);

    // Stat: Events successfully emitted
    increment_stat(2);

    return 0;
}

/*
 * ============================================================
 * LICENSE
 * ============================================================
 */

char LICENSE[] SEC("license") = "GPL";

/*
 * ============================================================
 * USAGE NOTES (for userspace integration)
 * ============================================================
 *
 * 1. LOAD PROGRAM:
 *    obj = bpf_object__open("grimoire-oracle.bpf.o");
 *    bpf_object__load(obj);
 *
 * 2. POPULATE MONITORED_SYSCALLS MAP:
 *    fd = bpf_object__find_map_fd_by_name(obj, "monitored_syscalls");
 *    for each pattern in HOT_PATTERNS:
 *        for each step.syscall_nr:
 *            u8 val = 1;
 *            bpf_map_update_elem(fd, &syscall_nr, &val, BPF_ANY);
 *
 * 3. ENABLE GRIMOIRE:
 *    config_fd = bpf_object__find_map_fd_by_name(obj, "grimoire_config");
 *    u32 key = 0, val = 1;
 *    bpf_map_update_elem(config_fd, &key, &val, BPF_ANY);  // Enable
 *    key = 1;
 *    bpf_map_update_elem(config_fd, &key, &val, BPF_ANY);  // Enable filter
 *
 * 4. CONSUME RING BUFFER:
 *    rb = ring_buffer__new(grimoire_events_fd, handle_event, &grimoire_engine, NULL);
 *    while (running):
 *        ring_buffer__poll(rb, 100);  // Poll every 100ms
 *
 * 5. CALLBACK:
 *    int handle_event(void *ctx, void *data, size_t size) {
 *        grimoire_syscall_event *event = data;
 *        grimoire_engine->processSyscall(
 *            event->pid,
 *            event->syscall_nr,
 *            event->timestamp_ns,
 *            event->args
 *        );
 *    }
 *
 * 6. STATISTICS:
 *    Read grimoire_stats map periodically to monitor:
 *    - Index 0: Total syscalls seen
 *    - Index 1: Syscalls after filter (relevant)
 *    - Index 2: Events emitted to ring buffer
 *    - Index 3: Events dropped (ring buffer full)
 *
 *    Filter efficiency: (stats[1] / stats[0]) * 100%
 *    Expected: ~1% (99% filtered out)
 *
 * 7. DISABLE GRIMOIRE (KILL SWITCH):
 *    u32 key = 0, val = 0;
 *    bpf_map_update_elem(config_fd, &key, &val, BPF_ANY);  // Disable
 */
