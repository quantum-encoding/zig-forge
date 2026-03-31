/* SPDX-License-Identifier: (LGPL-2.1 OR BSD-2-Clause) */
/*
 * bpf_helpers.h - BPF helper function declarations
 *
 * Minimal version for Grimoire BPF compilation.
 * In production, use libbpf's bpf_helpers.h
 *
 * NOTE: This file must NOT include <linux/bpf.h> because vmlinux.h
 * already contains all BPF definitions. Including both causes conflicts.
 */

#ifndef __BPF_HELPERS_H
#define __BPF_HELPERS_H

/* BPF helper function IDs from vmlinux.h bpf_func_id enum */
/* These must match the kernel's BPF_FUNC_* definitions */

/* BPF helper function declarations */

/* Map operations */
static void *(*bpf_map_lookup_elem)(void *map, const void *key) = (void *) BPF_FUNC_map_lookup_elem;
static long (*bpf_map_update_elem)(void *map, const void *key, const void *value, __u64 flags) = (void *) BPF_FUNC_map_update_elem;
static long (*bpf_map_delete_elem)(void *map, const void *key) = (void *) BPF_FUNC_map_delete_elem;

/* Process/thread info */
static __u64 (*bpf_get_current_pid_tgid)(void) = (void *) BPF_FUNC_get_current_pid_tgid;
static __u64 (*bpf_get_current_uid_gid)(void) = (void *) BPF_FUNC_get_current_uid_gid;
static long (*bpf_get_current_comm)(void *buf, __u32 size) = (void *) BPF_FUNC_get_current_comm;

/* Time */
static __u64 (*bpf_ktime_get_ns)(void) = (void *) BPF_FUNC_ktime_get_ns;

/* Ring buffer (kernel 5.8+) */
static void *(*bpf_ringbuf_reserve)(void *ringbuf, __u64 size, __u64 flags) = (void *) BPF_FUNC_ringbuf_reserve;
static void (*bpf_ringbuf_submit)(void *data, __u64 flags) = (void *) BPF_FUNC_ringbuf_submit;
static void (*bpf_ringbuf_discard)(void *data, __u64 flags) = (void *) BPF_FUNC_ringbuf_discard;

/* Debugging */
static long (*bpf_trace_printk)(const char *fmt, __u32 fmt_size, ...) = (void *) BPF_FUNC_trace_printk;

/* Memory read helpers */
static long (*bpf_probe_read)(void *dst, __u32 size, const void *unsafe_ptr) = (void *) BPF_FUNC_probe_read;
static long (*bpf_probe_read_user)(void *dst, __u32 size, const void *unsafe_ptr) = (void *) BPF_FUNC_probe_read_user;
static long (*bpf_probe_read_kernel)(void *dst, __u32 size, const void *unsafe_ptr) = (void *) BPF_FUNC_probe_read_kernel;

/* Task helpers */
static __u64 (*bpf_get_current_task)(void) = (void *) BPF_FUNC_get_current_task;

/* Section definitions */
#define SEC(NAME) __attribute__((section(NAME), used))

/* License */
#define BPF_LICENSE(NAME) \
    char _license[] SEC("license") = NAME

/* Map definition macros */
#define __uint(name, val) int (*name)[val]
#define __type(name, val) typeof(val) *name
#define __array(name, val) typeof(val) *name[]

/* Always inline for BPF */
#ifndef __always_inline
#define __always_inline __attribute__((always_inline))
#endif

#endif /* __BPF_HELPERS_H */
