// SPDX-License-Identifier: GPL-2.0
//
// shepherd.bpf.c - eBPF program for claude-shepherd
//
// Monitors Claude Code instances via kernel hooks:
// - kprobe/tty_write: Captures terminal output
// - tracepoint/sched/sched_process_exec: Detects new processes
// - tracepoint/sched/sched_process_exit: Detects process termination
//
// Events are sent to userspace via ring buffer for real-time processing.

#include "vmlinux.h"
#include <bpf/bpf_helpers.h>
#include <bpf/bpf_tracing.h>
#include <bpf/bpf_core_read.h>

#define MAX_BUFFER_SIZE 256
#define MAX_COMM_SIZE 16
#define RINGBUF_SIZE (256 * 1024)

// Event types
enum shepherd_event_type {
    EVENT_TTY_WRITE = 1,
    EVENT_PROCESS_EXEC = 2,
    EVENT_PROCESS_EXIT = 3,
    EVENT_PERMISSION_REQUEST = 4,
};

// Event structure sent to userspace
struct shepherd_event {
    __u32 event_type;
    __u32 pid;
    __u64 timestamp_ns;
    char comm[MAX_COMM_SIZE];
    __u32 buf_size;
    __u32 exit_code;
    char buffer[MAX_BUFFER_SIZE];
} __attribute__((packed));

// Per-PID state for quick lookups
struct pid_state {
    __u32 pid;
    __u64 start_time_ns;
    __u64 last_activity_ns;
    __u32 status;  // 0=unknown, 1=running, 2=waiting_permission
    char task[64];
    char working_dir[128];
};

// Ring buffer for events
struct {
    __uint(type, BPF_MAP_TYPE_RINGBUF);
    __uint(max_entries, RINGBUF_SIZE);
} events SEC(".maps");

// Hash map for per-PID state (direct access)
struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __uint(max_entries, 256);
    __type(key, __u32);
    __type(value, struct pid_state);
} pid_states SEC(".maps");

// Configuration array
struct {
    __uint(type, BPF_MAP_TYPE_ARRAY);
    __uint(max_entries, 4);
    __type(key, __u32);
    __type(value, __u64);
} shepherd_config SEC(".maps");

// Config keys
#define CONFIG_ENABLED 0
#define CONFIG_EVENT_COUNT 1

// Check if process name matches "claude"
static __always_inline int is_claude_process(const char *comm)
{
    // Match "claude" or "claude-code" or similar
    if (comm[0] == 'c' && comm[1] == 'l' && comm[2] == 'a' &&
        comm[3] == 'u' && comm[4] == 'd' && comm[5] == 'e') {
        return 1;
    }
    // Also match "node" (Claude runs as Node.js)
    if (comm[0] == 'n' && comm[1] == 'o' && comm[2] == 'd' && comm[3] == 'e') {
        return 1;
    }
    return 0;
}

// Check if this is a permission-related output
static __always_inline int is_permission_request(const char *buf, __u32 len)
{
    // Look for permission-related keywords
    // "Allow", "Deny", "permission", "approve"
    for (__u32 i = 0; i < len && i < MAX_BUFFER_SIZE - 8; i++) {
        if (buf[i] == 'A' && buf[i+1] == 'l' && buf[i+2] == 'l' &&
            buf[i+3] == 'o' && buf[i+4] == 'w') {
            return 1;
        }
        if (buf[i] == 'p' && buf[i+1] == 'e' && buf[i+2] == 'r' &&
            buf[i+3] == 'm' && buf[i+4] == 'i') {
            return 1;
        }
    }
    return 0;
}

// Hook: TTY write - captures terminal output
SEC("kprobe/tty_write")
int probe_tty_write(struct pt_regs *ctx)
{
    // Check if monitoring is enabled
    __u32 key = CONFIG_ENABLED;
    __u64 *enabled = bpf_map_lookup_elem(&shepherd_config, &key);
    if (!enabled || *enabled == 0) {
        return 0;
    }

    // Get process info
    char comm[MAX_COMM_SIZE];
    bpf_get_current_comm(&comm, sizeof(comm));

    // Filter non-Claude processes
    if (!is_claude_process(comm)) {
        return 0;
    }

    __u32 pid = bpf_get_current_pid_tgid() >> 32;
    __u64 ts = bpf_ktime_get_ns();

    // Get iov_iter from kernel (arg2 of tty_write)
    struct iov_iter *iter = (struct iov_iter *)PT_REGS_PARM2(ctx);
    if (!iter) {
        return 0;
    }

    // Reserve space in ring buffer
    struct shepherd_event *event = bpf_ringbuf_reserve(&events, sizeof(*event), 0);
    if (!event) {
        return 0;
    }

    // Fill event
    event->event_type = EVENT_TTY_WRITE;
    event->pid = pid;
    event->timestamp_ns = ts;
    event->exit_code = 0;
    __builtin_memcpy(event->comm, comm, MAX_COMM_SIZE);

    // Try to read buffer content
    const void *ubuf = NULL;
    size_t count = 0;

    // Read iter structure
    struct iov_iter iter_copy;
    if (bpf_probe_read_kernel(&iter_copy, sizeof(iter_copy), iter) == 0) {
        count = iter_copy.count;
        if (count > MAX_BUFFER_SIZE) {
            count = MAX_BUFFER_SIZE;
        }

        // Try ubuf first (user buffer)
        ubuf = iter_copy.ubuf;
        if (ubuf) {
            bpf_probe_read_user(event->buffer, count, ubuf);
        }
    }

    event->buf_size = count;

    // Check for permission request
    if (is_permission_request(event->buffer, count)) {
        event->event_type = EVENT_PERMISSION_REQUEST;

        // Update PID state
        struct pid_state *state = bpf_map_lookup_elem(&pid_states, &pid);
        if (state) {
            state->status = 2;  // waiting_permission
            state->last_activity_ns = ts;
        }
    }

    // Update per-PID state
    struct pid_state *state = bpf_map_lookup_elem(&pid_states, &pid);
    if (state) {
        state->last_activity_ns = ts;
    }

    // Increment event counter
    key = CONFIG_EVENT_COUNT;
    __u64 *count_ptr = bpf_map_lookup_elem(&shepherd_config, &key);
    if (count_ptr) {
        __sync_fetch_and_add(count_ptr, 1);
    }

    bpf_ringbuf_submit(event, 0);
    return 0;
}

// Hook: Process exec - detect new Claude instances
SEC("tracepoint/sched/sched_process_exec")
int trace_exec(struct trace_event_raw_sched_process_exec *ctx)
{
    __u32 key = CONFIG_ENABLED;
    __u64 *enabled = bpf_map_lookup_elem(&shepherd_config, &key);
    if (!enabled || *enabled == 0) {
        return 0;
    }

    char comm[MAX_COMM_SIZE];
    bpf_get_current_comm(&comm, sizeof(comm));

    if (!is_claude_process(comm)) {
        return 0;
    }

    __u32 pid = bpf_get_current_pid_tgid() >> 32;
    __u64 ts = bpf_ktime_get_ns();

    // Reserve event
    struct shepherd_event *event = bpf_ringbuf_reserve(&events, sizeof(*event), 0);
    if (!event) {
        return 0;
    }

    event->event_type = EVENT_PROCESS_EXEC;
    event->pid = pid;
    event->timestamp_ns = ts;
    event->exit_code = 0;
    event->buf_size = 0;
    __builtin_memcpy(event->comm, comm, MAX_COMM_SIZE);

    // Create PID state entry
    struct pid_state new_state = {
        .pid = pid,
        .start_time_ns = ts,
        .last_activity_ns = ts,
        .status = 1,  // running
    };
    bpf_map_update_elem(&pid_states, &pid, &new_state, BPF_ANY);

    bpf_ringbuf_submit(event, 0);
    return 0;
}

// Hook: Process exit - detect terminated Claude instances
SEC("tracepoint/sched/sched_process_exit")
int trace_exit(struct trace_event_raw_sched_process_template *ctx)
{
    __u32 key = CONFIG_ENABLED;
    __u64 *enabled = bpf_map_lookup_elem(&shepherd_config, &key);
    if (!enabled || *enabled == 0) {
        return 0;
    }

    __u32 pid = bpf_get_current_pid_tgid() >> 32;

    // Check if we were tracking this PID
    struct pid_state *state = bpf_map_lookup_elem(&pid_states, &pid);
    if (!state) {
        return 0;
    }

    __u64 ts = bpf_ktime_get_ns();

    // Reserve event
    struct shepherd_event *event = bpf_ringbuf_reserve(&events, sizeof(*event), 0);
    if (!event) {
        return 0;
    }

    char comm[MAX_COMM_SIZE];
    bpf_get_current_comm(&comm, sizeof(comm));

    event->event_type = EVENT_PROCESS_EXIT;
    event->pid = pid;
    event->timestamp_ns = ts;
    event->exit_code = 0;  // Would need task_struct access for real exit code
    event->buf_size = 0;
    __builtin_memcpy(event->comm, comm, MAX_COMM_SIZE);

    // Remove PID state
    bpf_map_delete_elem(&pid_states, &pid);

    bpf_ringbuf_submit(event, 0);
    return 0;
}

char LICENSE[] SEC("license") = "GPL";
