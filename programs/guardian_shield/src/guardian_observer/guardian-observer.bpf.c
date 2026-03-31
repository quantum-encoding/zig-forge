// SPDX-License-Identifier: GPL-2.0
/*
 * Guardian Observer - eBPF Syscall Monitor for AI Agents
 * PHASE 3: KPROBE FLANKING MANEUVER
 *
 * Intercepts critical syscalls from AI agent processes to detect:
 * - Destructive commands
 * - Hallucinated library calls
 * - Pathological patterns
 * - Unauthorized file access
 *
 * Part of The Guardian Protocol
 * Copyright (c) 2025 Richard Tune / Quantum Encoding Ltd
 */

#include "vmlinux.h"
#include <bpf/bpf_helpers.h>
#include <bpf/bpf_tracing.h>
#include <bpf/bpf_core_read.h>

#define TASK_COMM_LEN 16
#define MAX_FILENAME_LEN 256
#define MAX_ARGS_LEN 512

/* Event types */
enum event_type {
    EVENT_EXEC = 1,
    EVENT_OPEN = 2,
    EVENT_UNLINK = 3,
    EVENT_RENAME = 4,
    EVENT_WRITE = 5,
};

/* Syscall event structure */
struct syscall_event {
    __u32 pid;
    __u32 ppid;
    __u32 uid;
    __u32 event_type;
    __u64 timestamp_ns;
    char comm[TASK_COMM_LEN];
    char filename[MAX_FILENAME_LEN];
    char args[MAX_ARGS_LEN];
    __u32 flags;
    __u32 mode;
} __attribute__((packed));

/* Ring buffer for streaming events to userspace */
struct {
    __uint(type, BPF_MAP_TYPE_RINGBUF);
    __uint(max_entries, 256 * 1024); // 256KB ring buffer
} events SEC(".maps");

/* Map to track AI agent processes (PID -> 1 if agent) */
struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __uint(max_entries, 1024);
    __type(key, __u32);    // PID
    __type(value, __u32);  // 1 if this is an agent process
} agent_processes SEC(".maps");

/* Helper to check if process is an AI agent */
static __always_inline int is_agent_process(__u32 pid)
{
    __u32 *is_agent = bpf_map_lookup_elem(&agent_processes, &pid);
    if (is_agent && *is_agent == 1) {
        return 1;
    }
    return 0;
}

/* Helper to get parent PID - hard-coded offsets for verifier safety */
static __always_inline __u32 get_ppid(void)
{
    struct task_struct *task = (struct task_struct *)bpf_get_current_task();
    if (!task) return 0;

    struct task_struct *parent;
    // Hard-coded offset for task->real_parent (2720 from your kernel layout)
    if (bpf_probe_read_kernel(&parent, sizeof(struct task_struct*), (void *)task + 2720) != 0) return 0;

    __u32 ppid;
    // Hard-coded offset for task->tgid (2708 from your kernel layout)
    if (bpf_probe_read_kernel(&ppid, sizeof(__u32), (void *)parent + 2708) != 0) return 0;

    return ppid;
}

/* Helper to populate common event fields */
static __always_inline void populate_event_common(struct syscall_event *event, __u32 event_type)
{
    __u64 id = bpf_get_current_pid_tgid();
    event->pid = id >> 32;
    event->ppid = get_ppid();
    event->uid = bpf_get_current_uid_gid() & 0xFFFFFFFF;
    event->event_type = event_type;
    event->timestamp_ns = bpf_ktime_get_ns();
    bpf_get_current_comm(&event->comm, sizeof(event->comm));
}

/* KPROBE: Intercept execve syscall */
SEC("kprobe/__x64_sys_execve")
int BPF_KPROBE(kprobe_execve, struct pt_regs *regs)
{
    __u64 id = bpf_get_current_pid_tgid();
    __u32 pid = id >> 32;

    // Only monitor agent processes
    if (!is_agent_process(pid)) {
        return 0;
    }

    struct syscall_event *event;
    event = bpf_ringbuf_reserve(&events, sizeof(*event), 0);
    if (!event) {
        return 0;
    }

    populate_event_common(event, EVENT_EXEC);

    // filename is first parameter to execve
    const char *filename = (const char *)PT_REGS_PARM1(regs);
    bpf_probe_read_user_str(&event->filename, sizeof(event->filename), filename);

    // argv is second parameter
    const char **argv = (const char **)PT_REGS_PARM2(regs);
    const char *arg0 = NULL;
    bpf_probe_read_user(&arg0, sizeof(arg0), argv);
    if (arg0) {
        bpf_probe_read_user_str(&event->args, sizeof(event->args), arg0);
    } else {
        event->args[0] = '\0';
    }

    bpf_ringbuf_submit(event, 0);
    return 0;
}

/* KPROBE: Intercept openat syscall */
SEC("kprobe/__x64_sys_openat")
int BPF_KPROBE(kprobe_openat, struct pt_regs *regs)
{
    __u64 id = bpf_get_current_pid_tgid();
    __u32 pid = id >> 32;

    if (!is_agent_process(pid)) {
        return 0;
    }

    struct syscall_event *event;
    event = bpf_ringbuf_reserve(&events, sizeof(*event), 0);
    if (!event) {
        return 0;
    }

    populate_event_common(event, EVENT_OPEN);

    // openat(dirfd, pathname, flags, mode)
    // filename is second parameter
    const char *filename = (const char *)PT_REGS_PARM2(regs);
    bpf_probe_read_user_str(&event->filename, sizeof(event->filename), filename);

    // flags is third parameter
    event->flags = (__u32)PT_REGS_PARM3(regs);
    // mode is fourth parameter
    event->mode = (__u32)PT_REGS_PARM4(regs);

    event->args[0] = '\0';

    bpf_ringbuf_submit(event, 0);
    return 0;
}

/* KPROBE: Intercept unlink syscall */
SEC("kprobe/__x64_sys_unlink")
int BPF_KPROBE(kprobe_unlink, struct pt_regs *regs)
{
    __u64 id = bpf_get_current_pid_tgid();
    __u32 pid = id >> 32;

    if (!is_agent_process(pid)) {
        return 0;
    }

    struct syscall_event *event;
    event = bpf_ringbuf_reserve(&events, sizeof(*event), 0);
    if (!event) {
        return 0;
    }

    populate_event_common(event, EVENT_UNLINK);

    // filename is first parameter
    const char *filename = (const char *)PT_REGS_PARM1(regs);
    bpf_probe_read_user_str(&event->filename, sizeof(event->filename), filename);

    event->args[0] = '\0';
    event->flags = 0;
    event->mode = 0;

    bpf_ringbuf_submit(event, 0);
    return 0;
}

/* KPROBE: Intercept rename syscall */
SEC("kprobe/__x64_sys_rename")
int BPF_KPROBE(kprobe_rename, struct pt_regs *regs)
{
    __u64 id = bpf_get_current_pid_tgid();
    __u32 pid = id >> 32;

    if (!is_agent_process(pid)) {
        return 0;
    }

    struct syscall_event *event;
    event = bpf_ringbuf_reserve(&events, sizeof(*event), 0);
    if (!event) {
        return 0;
    }

    populate_event_common(event, EVENT_RENAME);

    // oldname is first parameter
    const char *oldname = (const char *)PT_REGS_PARM1(regs);
    bpf_probe_read_user_str(&event->filename, sizeof(event->filename), oldname);

    // newname is second parameter
    const char *newname = (const char *)PT_REGS_PARM2(regs);
    bpf_probe_read_user_str(&event->args, sizeof(event->args), newname);

    event->flags = 0;
    event->mode = 0;

    bpf_ringbuf_submit(event, 0);
    return 0;
}

char LICENSE[] SEC("license") = "GPL";
