// SPDX-License-Identifier: GPL-2.0
/*
 * Guardian Shield - eBPF-based System Security Framework
 *
 * inquisitor-simple.bpf.c - Simplified LSM BPF Command Execution Arbiter
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
 * Purpose: System-wide command execution enforcement (simplified for eBPF verifier)
 * Architecture: LSM BPF hook on bprm_check_security
 * Authority: Kernel-level, pre-execution blocking
 */

#include "vmlinux.h"
#include <bpf/bpf_helpers.h>
#include <bpf/bpf_tracing.h>
#include <bpf/bpf_core_read.h>

#define MAX_FILENAME_LEN 256
#define MAX_BLACKLIST_ENTRIES 8  // Small number for verifier
#define MAX_PATTERN_LEN 64
#define EPERM 1

/*
 * Blacklist entry structure (renamed to avoid conflict with vmlinux.h)
 */
struct inquisitor_blacklist_entry {
    char pattern[MAX_PATTERN_LEN];
    __u8 exact_match;
    __u8 enabled;
    __u16 reserved;
};

/*
 * Event structure for userspace reporting
 */
struct exec_event {
    __u32 pid;
    __u32 uid;
    __u32 gid;
    __u32 blocked;
    char filename[MAX_FILENAME_LEN];
    char comm[16];
};

/*
 * Map 1: Blacklist Configuration
 */
struct {
    __uint(type, BPF_MAP_TYPE_ARRAY);
    __uint(max_entries, MAX_BLACKLIST_ENTRIES);
    __type(key, __u32);
    __type(value, struct inquisitor_blacklist_entry);
} blacklist_map SEC(".maps");

/*
 * Map 2: Ring Buffer for Events
 */
struct {
    __uint(type, BPF_MAP_TYPE_RINGBUF);
    __uint(max_entries, 256 * 1024);
} events SEC(".maps");

/*
 * Map 3: Global Configuration
 */
struct {
    __uint(type, BPF_MAP_TYPE_ARRAY);
    __uint(max_entries, 8);
    __type(key, __u32);
    __type(value, __u32);
} config_map SEC(".maps");

/*
 * Helper: Compare two strings (bounded, no loops)
 * Returns 1 if strings match, 0 otherwise
 */
static __always_inline int str_equals(const char *a, const char *b)
{
    // Manually unrolled comparison (16 bytes max for comm)
    if (a[0] != b[0]) return 0;
    if (a[0] == '\0') return 1;
    if (a[1] != b[1]) return 0;
    if (a[1] == '\0') return 1;
    if (a[2] != b[2]) return 0;
    if (a[2] == '\0') return 1;
    if (a[3] != b[3]) return 0;
    if (a[3] == '\0') return 1;
    if (a[4] != b[4]) return 0;
    if (a[4] == '\0') return 1;
    if (a[5] != b[5]) return 0;
    if (a[5] == '\0') return 1;
    if (a[6] != b[6]) return 0;
    if (a[6] == '\0') return 1;
    if (a[7] != b[7]) return 0;
    if (a[7] == '\0') return 1;
    if (a[8] != b[8]) return 0;
    if (a[8] == '\0') return 1;
    if (a[9] != b[9]) return 0;
    if (a[9] == '\0') return 1;
    if (a[10] != b[10]) return 0;
    if (a[10] == '\0') return 1;
    if (a[11] != b[11]) return 0;
    if (a[11] == '\0') return 1;
    if (a[12] != b[12]) return 0;
    if (a[12] == '\0') return 1;
    if (a[13] != b[13]) return 0;
    if (a[13] == '\0') return 1;
    if (a[14] != b[14]) return 0;
    if (a[14] == '\0') return 1;
    if (a[15] != b[15]) return 0;
    return 1;
}

/*
 * Helper: Simple substring check - checks if needle is at start of haystack
 * Simplified to avoid complex nested conditions
 */
static __always_inline int str_contains(const char *haystack, const char *needle)
{
    // If needle is empty, no match
    if (needle[0] == '\0')
        return 0;

    // Check if needle matches at start of haystack
    if (haystack[0] != needle[0]) return 0;
    if (needle[1] == '\0') return 1;
    if (haystack[1] != needle[1]) return 0;
    if (needle[2] == '\0') return 1;
    if (haystack[2] != needle[2]) return 0;
    if (needle[3] == '\0') return 1;
    if (haystack[3] != needle[3]) return 0;
    if (needle[4] == '\0') return 1;
    if (haystack[4] != needle[4]) return 0;
    if (needle[5] == '\0') return 1;
    if (haystack[5] != needle[5]) return 0;
    if (needle[6] == '\0') return 1;
    if (haystack[6] != needle[6]) return 0;
    if (needle[7] == '\0') return 1;
    if (haystack[7] != needle[7]) return 0;

    // If we get here, at least 8 chars matched
    return 1;
}

/*
 * Helper: Check single blacklist entry
 */
static __always_inline int check_entry(const char *comm, __u32 idx)
{
    struct inquisitor_blacklist_entry *entry = bpf_map_lookup_elem(&blacklist_map, &idx);
    if (!entry || !entry->enabled || entry->pattern[0] == '\0')
        return 0;

    if (entry->exact_match)
        return str_equals(comm, entry->pattern);
    else
        return str_contains(comm, entry->pattern);
}

/*
 * LSM Hook: bprm_check_security
 */
SEC("lsm/bprm_check_security")
int BPF_PROG(inquisitor_bprm_check, struct linux_binprm *bprm, int ret)
{
    // DEBUG: Log that hook was called
    bpf_printk("LSM HOOK CALLED! ret=%d", ret);

    if (ret != 0) {
        bpf_printk("Early return: ret=%d", ret);
        return ret;
    }

    // Get enforcement mode
    __u32 key = 0;
    __u32 *enforcement_enabled = bpf_map_lookup_elem(&config_map, &key);
    int enforce = enforcement_enabled ? *enforcement_enabled : 1;

    // CRITICAL FIX: Get the program being executed from bprm->filename
    // bpf_get_current_comm() returns PARENT process name, not the program being executed!
    const char *filename_ptr = BPF_CORE_READ(bprm, filename);
    if (!filename_ptr)
        return 0;

    // Read filename from kernel memory
    char filename_full[256] = {};
    long read_result = bpf_probe_read_kernel_str(filename_full, sizeof(filename_full), filename_ptr);
    if (read_result < 0)
        return 0;

    // Extract basename (program name without path)
    char program_name[64] = {};
    int last_slash = -1;

    // Find last '/' to get basename
    #pragma unroll
    for (int i = 0; i < 255 && filename_full[i] != '\0'; i++) {
        if (filename_full[i] == '/') last_slash = i;
    }

    // Copy basename
    int copy_from = last_slash + 1;
    #pragma unroll
    for (int i = 0; i < 63; i++) {
        char c = filename_full[copy_from + i];
        if (c == '\0') break;
        program_name[i] = c;
    }
    program_name[63] = '\0';

    bpf_printk("Inquisitor: program='%s'", program_name);

    // Check blacklist using actual program name (not parent comm!)
    int blocked = 0;
    __u32 idx;

    idx = 0; if (check_entry(program_name, idx)) blocked = 1;
    if (!blocked) { idx = 1; if (check_entry(program_name, idx)) blocked = 1; }
    if (!blocked) { idx = 2; if (check_entry(program_name, idx)) blocked = 1; }
    if (!blocked) { idx = 3; if (check_entry(program_name, idx)) blocked = 1; }
    if (!blocked) { idx = 4; if (check_entry(program_name, idx)) blocked = 1; }
    if (!blocked) { idx = 5; if (check_entry(program_name, idx)) blocked = 1; }
    if (!blocked) { idx = 6; if (check_entry(program_name, idx)) blocked = 1; }
    if (!blocked) { idx = 7; if (check_entry(program_name, idx)) blocked = 1; }

    // Get process info
    __u64 pid_tgid = bpf_get_current_pid_tgid();
    __u64 uid_gid = bpf_get_current_uid_gid();
    __u32 pid = pid_tgid >> 32;
    __u32 uid = uid_gid & 0xFFFFFFFF;
    __u32 gid = uid_gid >> 32;

    // Log event to userspace if needed
    key = 1;
    __u32 *log_all = bpf_map_lookup_elem(&config_map, &key);
    int should_log = blocked || (log_all && *log_all);

    if (should_log) {
        struct exec_event *event = bpf_ringbuf_reserve(&events, sizeof(struct exec_event), 0);
        if (event) {
            event->pid = pid;
            event->uid = uid;
            event->gid = gid;
            event->blocked = blocked;

            __builtin_memcpy(event->comm, program_name, 16);
            __builtin_memset(event->filename, 0, MAX_FILENAME_LEN);
            __builtin_memcpy(event->filename, program_name, 64);

            bpf_ringbuf_submit(event, 0);
        }
    }

    // Enforce the sovereign's will
    if (blocked && enforce)
        return -EPERM;

    return 0;
}

char LICENSE[] SEC("license") = "GPL";
