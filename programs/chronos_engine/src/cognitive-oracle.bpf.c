// SPDX-License-Identifier: GPL-2.0
/*
 * Guardian Shield - Chronos Cognitive Oracle
 *
 * cognitive-oracle.bpf.c - The Watcher's Eye
 *
 * Copyright (c) 2025 Richard Tune / Quantum Encoding Ltd
 * Author: Richard Tune
 * Contact: info@quantumencoding.io
 * Website: https://quantumencoding.io
 *
 * License: Dual License - MIT (Non-Commercial) / Commercial License
 *
 * ============================================================================
 *
 * Purpose: Intercept terminal output from claude-code processes to capture
 *          cognitive state transitions in real-time at kernel level
 *
 * Architecture: write() syscall interception → kernel-space filtering → ring buffer
 *
 * Philosophy: "The Watcher does not poll. The Watcher does not read cache files.
 *             The Watcher intercepts the neural whispers at the speed of thought."
 *
 * THE DOCTRINE OF DIRECT INTERCEPTION:
 *   - Hook write() syscalls for claude-code processes only
 *   - Filter for stdout/stderr
 *   - Pass raw buffer to userspace for parsing (kernel sees, userspace interprets)
 *   - Result: Real-time cognitive awareness with zero polling overhead
 *
 * EVENT STRUCTURE:
 *   - pid: claude-code process ID
 *   - timestamp_ns: Nanosecond-precision timestamp
 *   - fd: File descriptor (1 or 2)
 *   - buf_size: Actual size of data written
 *   - buffer: Raw write buffer (capped at MAX_BUF_SIZE)
 *
 * INTEGRATION:
 *   - conductor-daemon loads this eBPF program alongside grimoire-oracle
 *   - cognitive-watcher consumes cognitive_events ring buffer and parses state
 *   - cognitive-watcher forwards parsed state to chronosd-cognitive via D-Bus
 */

#include "vmlinux.h"
#include <bpf/bpf_helpers.h>
#include <bpf/bpf_tracing.h>
#include <bpf/bpf_core_read.h>

/*
 * ============================================================
 * CONSTANTS
 * ============================================================
 */

#define MAX_COMM_LEN 16
#define MAX_BUF_SIZE 256  // Optimized size

/*
 * ============================================================
 * EVENT STRUCTURE - The Raw Whisper
 * ============================================================
 */

struct cognitive_event {
    __u32 pid;                  // Process ID
    __u32 timestamp_ns;         // Nanosecond timestamp (reduced)
    __u32 fd;                   // File descriptor
    __u32 buf_size;             // Actual write size (reduced)
    char comm[MAX_COMM_LEN];    // Process name
    char buffer[MAX_BUF_SIZE];  // Raw write buffer
} __attribute__((packed));

/*
 * ============================================================
 * BPF MAPS
 * ============================================================
 */

// Ring Buffer for Cognitive Events
struct {
    __uint(type, BPF_MAP_TYPE_RINGBUF);
    __uint(max_entries, 256 * 1024);  // 256KB
} cognitive_events SEC(".maps");

// Configuration Map
// Index 0: cognitive_oracle_enabled (1 = enabled, 0 = disabled)
struct {
    __uint(type, BPF_MAP_TYPE_ARRAY);
    __uint(max_entries, 16);
    __type(key, __u32);
    __type(value, __u32);
} cognitive_config SEC(".maps");

// Statistics
// Index 0: total_writes_intercepted
// Index 1: claude_writes_detected
// Index 2: events_emitted
struct {
    __uint(type, BPF_MAP_TYPE_ARRAY);
    __uint(max_entries, 16);
    __type(key, __u32);
    __type(value, __u64);
} cognitive_stats SEC(".maps");

/*
 * ============================================================
 * HELPER FUNCTIONS
 * ============================================================
 */

static __always_inline void increment_stat(__u32 index) {
    __u64 *counter = bpf_map_lookup_elem(&cognitive_stats, &index);
    if (counter) {
        __sync_fetch_and_add(counter, 1);
    }
}

static __always_inline bool is_cognitive_oracle_enabled() {
    __u32 key = 0;
    __u32 *enabled = bpf_map_lookup_elem(&cognitive_config, &key);
    return enabled && *enabled;
}

// Check if process is Claude Code CLI
static __always_inline bool is_claude_process() {
    char comm[MAX_COMM_LEN];
    bpf_get_current_comm(&comm, sizeof(comm));

    // Check for "claude" (the actual binary name)
    const char *target = "claude\0";
    bool match = true;
    #pragma unroll
    for (int i = 0; i < 6; i++) {
        if (comm[i] != target[i]) {
            match = false;
            break;
        }
    }
    return match;
}

/*
 * ============================================================
 * TRACEPOINT HOOK - The Cognitive Oracle's Ear
 * ============================================================
 */

SEC("tracepoint/syscalls/sys_enter_write")
int trace_write_enter(struct trace_event_raw_sys_enter *ctx)
{
    increment_stat(0);  // total_writes_intercepted

    if (!is_cognitive_oracle_enabled()) {
        return 0;
    }

    // Only intercept Claude Code processes (node)
    if (!is_claude_process()) {
        return 0;
    }

    increment_stat(1);  // claude_writes_detected

    // Get write() arguments
    // write(fd, buf, count)
    __u32 fd = (__u32)ctx->args[0];
    const void *buf = (const void *)ctx->args[1];
    __u64 count = ctx->args[2];

    // DEBUG: Capture ALL file descriptors to find which one Claude uses
    // (Normally we'd filter for stdout/stderr only)

    // Cap the buffer size
    __u32 read_size = count < MAX_BUF_SIZE ? (__u32)count : MAX_BUF_SIZE;

    // Reserve ring buffer space
    struct cognitive_event *event = bpf_ringbuf_reserve(&cognitive_events, sizeof(*event), 0);
    if (!event) {
        return 0;  // Ring buffer full
    }

    // Populate event
    event->pid = bpf_get_current_pid_tgid() >> 32;
    event->timestamp_ns = (__u32)bpf_ktime_get_ns();
    event->fd = fd;
    event->buf_size = read_size;

    // Copy comm
    bpf_get_current_comm(&event->comm, sizeof(event->comm));

    // Copy buffer from userspace
    long ret = bpf_probe_read_user(&event->buffer, read_size, buf);
    if (ret != 0) {
        bpf_ringbuf_discard(event, 0);
        return 0;
    }

    // Null-terminate if space allows
    if (read_size < MAX_BUF_SIZE) {
        event->buffer[read_size] = 0;
    }

    // Submit event
    bpf_ringbuf_submit(event, 0);

    increment_stat(2);  // events_emitted

    return 0;
}

char LICENSE[] SEC("license") = "GPL";
