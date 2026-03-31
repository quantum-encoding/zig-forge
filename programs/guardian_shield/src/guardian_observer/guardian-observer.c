// SPDX-License-Identifier: GPL-2.0
/*
 * Guardian Observer - Userspace Daemon
 *
 * Processes eBPF syscall events and detects dangerous patterns
 * Part of The Guardian Protocol
 *
 * Copyright (c) 2025 Richard Tune / Quantum Encoding Ltd
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <unistd.h>
#include <signal.h>
#include <time.h>
#include <stdarg.h>
#include <sys/resource.h>
#include <bpf/libbpf.h>
#include <bpf/bpf.h>
#include "guardian-judge.h"

#define MAX_COMM_LEN 16
#define MAX_FILENAME_LEN 256
#define MAX_ARGS_LEN 512

/* Event types - must match eBPF program */
enum event_type {
    EVENT_EXEC = 1,
    EVENT_OPEN = 2,
    EVENT_UNLINK = 3,
    EVENT_RENAME = 4,
    EVENT_WRITE = 5,
};

/* Syscall event structure - must match eBPF */
struct syscall_event {
    __u32 pid;
    __u32 ppid;
    __u32 uid;
    __u32 event_type;
    __u64 timestamp_ns;
    char comm[MAX_COMM_LEN];
    char filename[MAX_FILENAME_LEN];
    char args[MAX_ARGS_LEN];
    __u32 flags;
    __u32 mode;
} __attribute__((packed));

static volatile bool exiting = false;
static long event_count = 0;
static long threats_detected = 0;

/* Signal handler */
static void sig_handler(int sig)
{
    exiting = true;
}

/* Get timestamp string */
static void get_timestamp(char *buf, size_t len)
{
    time_t now = time(NULL);
    struct tm *tm_info = localtime(&now);
    strftime(buf, len, "%Y-%m-%d %H:%M:%S", tm_info);
}

/* Event type to string */
static const char *event_type_str(enum event_type type)
{
    switch (type) {
        case EVENT_EXEC: return "EXEC";
        case EVENT_OPEN: return "OPEN";
        case EVENT_UNLINK: return "UNLINK";
        case EVENT_RENAME: return "RENAME";
        case EVENT_WRITE: return "WRITE";
        default: return "UNKNOWN";
    }
}

/* Process a syscall event */
static int handle_event(void *ctx, void *data, size_t data_sz)
{
    const struct syscall_event *e = data;
    char timestamp[64];

    event_count++;
    get_timestamp(timestamp, sizeof(timestamp));

    printf("[%s] Event #%ld: %s\n", timestamp, event_count, event_type_str(e->event_type));
    printf("  PID: %u, PPID: %u, UID: %u\n", e->pid, e->ppid, e->uid);
    printf("  Command: %s\n", e->comm);
    printf("  File: %s\n", e->filename);

    if (e->args[0]) {
        printf("  Args: %s\n", e->args);
    }

    // Invoke the Guardian Judge
    char full_cmd[1024];
    snprintf(full_cmd, sizeof(full_cmd), "%s %s %s",
             e->comm, e->filename, e->args);

    const char *reason = NULL;
    const char *correction = NULL;
    enum verdict v = judge_command(full_cmd, &reason, &correction);

    if (v != VERDICT_ALLOW) {
        threats_detected++;
        execute_verdict(v, e->pid, full_cmd, reason, correction);
    }

    printf("\n");
    return 0;
}

/* Libbpf debug callback */
static int libbpf_print_fn(enum libbpf_print_level level, const char *format, va_list args)
{
    return vfprintf(stderr, format, args);
}

/* Register AI agent process for monitoring */
static int register_agent_process(int map_fd, __u32 pid)
{
    __u32 value = 1;
    int err = bpf_map_update_elem(map_fd, &pid, &value, BPF_ANY);
    if (err) {
        fprintf(stderr, "Failed to register agent PID %u: %s\n",
                pid, strerror(errno));
        return -1;
    }
    printf("✅ Registered agent process PID: %u\n", pid);
    return 0;
}

int main(int argc, char **argv)
{
    struct ring_buffer *rb = NULL;
    struct bpf_object *obj;
    int err;

    /* Setup libbpf errors and debug info callback */
    libbpf_set_print(libbpf_print_fn);

    /* Signal handlers */
    signal(SIGINT, sig_handler);
    signal(SIGTERM, sig_handler);

    /* Bump RLIMIT_MEMLOCK for eBPF */
    struct rlimit rlim = {
        .rlim_cur = 512UL << 20, // 512MB
        .rlim_max = 512UL << 20,
    };
    if (setrlimit(RLIMIT_MEMLOCK, &rlim)) {
        fprintf(stderr, "Failed to increase RLIMIT_MEMLOCK: %s\n", strerror(errno));
        return 1;
    }

    /* Load and verify BPF application */
    obj = bpf_object__open_file("guardian-observer.bpf.o", NULL);
    if (libbpf_get_error(obj)) {
        fprintf(stderr, "Failed to open BPF object\n");
        return 1;
    }

    err = bpf_object__load(obj);
    if (err) {
        fprintf(stderr, "Failed to load BPF object: %d\n", err);
        goto cleanup;
    }

    /* Attach BPF programs - attach all programs in the object */
    struct bpf_program *prog;
    bpf_object__for_each_program(prog, obj) {
        struct bpf_link *link = bpf_program__attach(prog);
        if (libbpf_get_error(link)) {
            fprintf(stderr, "Failed to attach BPF program: %s\n",
                    bpf_program__name(prog));
            goto cleanup;
        }
        // Note: links will be cleaned up automatically when object is closed
    }

    printf("🛡️  Guardian Observer started\n");
    printf("📊 Monitoring AI agent syscalls...\n\n");

    /* Get agent_processes map */
    int map_fd = bpf_object__find_map_fd_by_name(obj, "agent_processes");
    if (map_fd < 0) {
        fprintf(stderr, "Failed to find agent_processes map\n");
        goto cleanup;
    }

    /* Register agent PIDs from command line */
    for (int i = 1; i < argc; i++) {
        __u32 pid = atoi(argv[i]);
        if (pid > 0) {
            register_agent_process(map_fd, pid);
        }
    }

    /* Auto-detect Claude processes if no PIDs specified */
    if (argc == 1) {
        printf("🔍 Auto-detecting Claude processes...\n");
        // TODO: Scan /proc for Claude processes
        printf("💡 Tip: Specify PIDs as arguments to monitor specific agents\n\n");
    }

    /* Setup ring buffer polling */
    int ringbuf_fd = bpf_object__find_map_fd_by_name(obj, "events");
    rb = ring_buffer__new(ringbuf_fd, handle_event, NULL, NULL);
    if (!rb) {
        fprintf(stderr, "Failed to create ring buffer\n");
        goto cleanup;
    }

    /* Process events */
    while (!exiting) {
        err = ring_buffer__poll(rb, 100 /* timeout, ms */);
        if (err == -EINTR) {
            err = 0;
            break;
        }
        if (err < 0) {
            fprintf(stderr, "Error polling ring buffer: %d\n", err);
            break;
        }
    }

    printf("\n📊 Guardian Observer shutting down\n");
    printf("   Events processed: %ld\n", event_count);
    printf("   Threats detected: %ld\n", threats_detected);

cleanup:
    ring_buffer__free(rb);
    bpf_object__close(obj);
    return err != 0;
}
