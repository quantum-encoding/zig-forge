// SPDX-License-Identifier: GPL-2.0
/*
 * Guardian Shield - Chronos Cognitive Oracle V2
 *
 * cognitive-oracle-v2.bpf.c - The Phantom Hunter
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
 * THE SECOND CAMPAIGN: TERMINAL SUBSYSTEM INTERCEPTION
 *
 * Purpose: Intercept terminal output at the kernel TTY layer to capture
 *          cognitive state strings that bypass write() syscalls
 *
 * Architecture: kprobe on tty_write() → kernel-space filtering → ring buffer
 *
 * Philosophy: "The phantom does not walk through the gate we watch.
 *             So we must watch the very air it breathes through."
 *
 * THE DOCTRINE OF TTY INTERCEPTION:
 *   - Hook tty_write() kernel function with kprobe
 *   - Filter for Claude Code process writes
 *   - Capture raw terminal buffer before display
 *   - Pass to userspace for cognitive state extraction
 *
 * WHY THIS APPROACH:
 *   - ALL terminal output passes through tty_write(), regardless of syscall
 *   - ioctl(), writev(), pwrite() all eventually call tty_write()
 *   - We capture the data at the lowest level before display
 *   - No userspace mechanism can hide from this
 *
 * EVENT STRUCTURE:
 *   - pid: Claude Code process ID
 *   - timestamp_ns: Nanosecond-precision timestamp
 *   - tty_name: Terminal device name (e.g., "pts/10")
 *   - buf_size: Actual size of data written
 *   - buffer: Raw terminal buffer (capped at MAX_BUF_SIZE)
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
#define MAX_BUF_SIZE 256
#define MAX_TTY_NAME 32

/*
 * ============================================================
 * EVENT STRUCTURE - The Phantom's Whisper
 * ============================================================
 */

struct cognitive_event_v2 {
    __u32 pid;
    __u32 timestamp_ns;
    __u32 buf_size;
    __u32 _padding;
    char comm[MAX_COMM_LEN];
    char tty_name[MAX_TTY_NAME];
    char buffer[MAX_BUF_SIZE];
} __attribute__((packed));

/*
 * ============================================================
 * BPF MAPS
 * ============================================================
 */

// Ring Buffer for Cognitive Events V2
struct {
    __uint(type, BPF_MAP_TYPE_RINGBUF);
    __uint(max_entries, 256 * 1024);
} cognitive_events_v2 SEC(".maps");

// Configuration Map
struct {
    __uint(type, BPF_MAP_TYPE_ARRAY);
    __uint(max_entries, 16);
    __type(key, __u32);
    __type(value, __u32);
} cognitive_config_v2 SEC(".maps");

// Latest State Per PID - THE UNWRIT MOMENT
// This map allows instant access to the most recent cognitive state
// without consuming from the ring buffer
struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __uint(max_entries, 256);
    __type(key, __u32);  // PID
    __type(value, struct cognitive_event_v2);
} latest_state_by_pid SEC(".maps");

// Statistics
struct {
    __uint(type, BPF_MAP_TYPE_ARRAY);
    __uint(max_entries, 16);
    __type(key, __u32);
    __type(value, __u64);
} cognitive_stats_v2 SEC(".maps");

/*
 * ============================================================
 * HELPER FUNCTIONS
 * ============================================================
 */

static __always_inline void increment_stat(int idx) {
    __u32 key = idx;
    __u64 *value = bpf_map_lookup_elem(&cognitive_stats_v2, &key);
    if (value) {
        __sync_fetch_and_add(value, 1);
    }
}

static __always_inline bool is_cognitive_oracle_enabled() {
    __u32 key = 0;
    __u32 *enabled = bpf_map_lookup_elem(&cognitive_config_v2, &key);
    return enabled && *enabled;
}

// Check if current process is Claude Code
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
 * KPROBE HOOK - The Phantom Hunter
 * ============================================================
 */

SEC("kprobe/tty_write")
int probe_tty_write(struct pt_regs *ctx)
{
    increment_stat(0);  // total_tty_writes_seen

    if (!is_cognitive_oracle_enabled()) {
        return 0;
    }

    // Only intercept Claude Code processes
    if (!is_claude_process()) {
        return 0;
    }

    increment_stat(1);  // claude_tty_writes_detected

    /*
     * tty_write() function signature (kernel/drivers/tty/tty_io.c):
     *   static ssize_t tty_write(struct kiocb *iocb, struct iov_iter *from)
     *
     * For kprobe, we access arguments via PT_REGS_PARM macros
     */

    // Get function arguments
    struct kiocb *iocb = (struct kiocb *)PT_REGS_PARM1(ctx);
    struct iov_iter *from = (struct iov_iter *)PT_REGS_PARM2(ctx);

    if (!iocb || !from) {
        return 0;
    }

    // Extract file and tty info
    struct file *file;
    bpf_probe_read_kernel(&file, sizeof(file), &iocb->ki_filp);
    if (!file) {
        return 0;
    }

    // Get TTY structure
    struct tty_struct *tty;
    bpf_probe_read_kernel(&tty, sizeof(tty), &file->private_data);
    if (!tty) {
        return 0;
    }

    // Reserve ring buffer space
    struct cognitive_event_v2 *event = bpf_ringbuf_reserve(&cognitive_events_v2, sizeof(*event), 0);
    if (!event) {
        return 0;  // Ring buffer full
    }

    // Fill event metadata
    event->pid = bpf_get_current_pid_tgid() >> 32;
    event->timestamp_ns = bpf_ktime_get_ns();
    bpf_get_current_comm(&event->comm, sizeof(event->comm));

    // Skip TTY name extraction for now (complex pointer dereferencing causes verifier issues)
    // Just mark as "tty" to indicate this came from TTY subsystem
    __builtin_memcpy(event->tty_name, "tty", 4);

    // Extract buffer from iov_iter
    // iov_iter is a union that can contain different buffer types
    // We need to check iter_type and handle accordingly

    // Get the count (size of data)
    size_t count;
    bpf_probe_read_kernel(&count, sizeof(count), &from->count);

    event->buf_size = 0;  // Default to 0

    if (count > 0) {
        __u32 read_size = count < MAX_BUF_SIZE ? (__u32)count : MAX_BUF_SIZE;

        // Get iter_type to determine which union member is active
        u8 iter_type;
        bpf_probe_read_kernel(&iter_type, sizeof(iter_type), &from->iter_type);

        // Try different buffer types based on iter_type
        // Common types: ITER_IOVEC=0, ITER_KVEC=1, ITER_BVEC=2, ITER_UBUF=5

        void *buf_ptr = NULL;

        // First try ubuf (single user buffer - most common for TTY)
        bpf_probe_read_kernel(&buf_ptr, sizeof(buf_ptr), &from->ubuf);

        if (buf_ptr) {
            // Try kernel read first
            long ret = bpf_probe_read_kernel(event->buffer, read_size, buf_ptr);
            if (ret == 0) {
                event->buf_size = read_size;
            } else {
                // Try user read if kernel read failed
                ret = bpf_probe_read_user(event->buffer, read_size, buf_ptr);
                if (ret == 0) {
                    event->buf_size = read_size;
                }
            }
        } else {
            // Fallback: try kvec
            const struct kvec *kvec;
            bpf_probe_read_kernel(&kvec, sizeof(kvec), &from->kvec);

            if (kvec) {
                void *iov_base;
                bpf_probe_read_kernel(&iov_base, sizeof(iov_base), &kvec->iov_base);

                if (iov_base) {
                    long ret = bpf_probe_read_kernel(event->buffer, read_size, iov_base);
                    if (ret == 0) {
                        event->buf_size = read_size;
                    }
                }
            }
        }
    }

    increment_stat(2);  // events_emitted

    // Update latest state map - THE UNWRIT MOMENT
    // This allows instant access without consuming from ring buffer
    __u32 pid_key = event->pid;
    bpf_map_update_elem(&latest_state_by_pid, &pid_key, event, BPF_ANY);

    // Submit event to ring buffer
    bpf_ringbuf_submit(event, 0);

    return 0;
}

char LICENSE[] SEC("license") = "GPL";
