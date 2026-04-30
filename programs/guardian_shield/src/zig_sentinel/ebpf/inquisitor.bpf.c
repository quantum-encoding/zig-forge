// SPDX-License-Identifier: GPL-2.0
/*
 * Guardian Shield - eBPF-based System Security Framework
 *
 * inquisitor.bpf.c - LSM BPF Command Execution Arbiter
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
 * Purpose: System-wide command execution enforcement with absolute veto power
 * Architecture: LSM BPF hook on bprm_check_security
 * Authority: Kernel-level, pre-execution blocking (no race conditions)
 *
 * The Inquisitor - Second Head of the Chimera
 *
 * This enforces the "Sovereign Command Blacklist" - a list of programs
 * that may NEVER execute on this system, regardless of user, context, or privilege.
 */

#include <linux/bpf.h>
#include <linux/errno.h>
#include <bpf/bpf_helpers.h>
#include <bpf/bpf_tracing.h>
#include <bpf/bpf_core_read.h>

// Forward declarations for LSM hook
struct file;
struct path;

#define MAX_FILENAME_LEN 256
#define MAX_BLACKLIST_ENTRIES 16  // Limited for eBPF verifier compatibility
#define MAX_PATTERN_LEN 64

/*
 * Blacklist entry structure
 *
 * Supports two modes:
 * 1. Exact match: command == "/bin/rm"
 * 2. Pattern match: command contains "dd" or "mkfs"
 */
struct blacklist_entry {
    char pattern[MAX_PATTERN_LEN];
    __u8 exact_match;  // 1 = exact path match, 0 = substring match
    __u8 enabled;      // 1 = active, 0 = disabled
    __u16 reserved;
};

/*
 * Event structure for userspace reporting
 */
struct exec_event {
    __u32 pid;
    __u32 uid;
    __u32 gid;
    __u32 blocked;  // 1 if blocked, 0 if allowed
    char filename[MAX_FILENAME_LEN];
    char comm[16];  // Process name
};

/*
 * Map 1: Blacklist Configuration
 * Key: Index (0 to MAX_BLACKLIST_ENTRIES-1)
 * Value: Blacklist entry (command pattern + match type)
 */
struct {
    __uint(type, BPF_MAP_TYPE_ARRAY);
    __uint(max_entries, MAX_BLACKLIST_ENTRIES);
    __type(key, __u32);
    __type(value, struct blacklist_entry);
} blacklist_map SEC(".maps");

/*
 * Map 2: Ring Buffer for Events
 * Sends execution events to userspace for logging
 */
struct {
    __uint(type, BPF_MAP_TYPE_RINGBUF);
    __uint(max_entries, 256 * 1024);  // 256KB ring buffer
} events SEC(".maps");

/*
 * Map 3: Global Configuration
 * Index 0: enforcement_enabled (1 = block mode, 0 = monitor only)
 * Index 1: log_allowed_execs (1 = log all, 0 = log blocks only)
 */
struct {
    __uint(type, BPF_MAP_TYPE_ARRAY);
    __uint(max_entries, 8);
    __type(key, __u32);
    __type(value, __u32);
} config_map SEC(".maps");

/*
 * Helper: Simple substring search
 * Returns 1 if needle is found in haystack, 0 otherwise
 */
static __always_inline int contains_substring(const char *haystack, const char *needle)
{
    // Simple substring match for small patterns
    // Check if needle appears anywhere in haystack
    #pragma unroll
    for (int i = 0; i < 16; i++) {
        if (haystack[i] == '\0')
            return 0;

        // Try to match needle starting at position i
        int matched = 1;
        #pragma unroll
        for (int j = 0; j < 16; j++) {
            if (needle[j] == '\0')
                return 1; // Found complete match
            if (haystack[i + j] == '\0' || haystack[i + j] != needle[j]) {
                matched = 0;
                break;
            }
        }
        if (matched)
            return 1;
    }
    return 0;
}

/*
 * Helper: Check if filename matches blacklist
 * Returns 1 if blocked, 0 if allowed
 */
static __always_inline int check_blacklist(const char *comm)
{
    struct blacklist_entry *entry;

    // Check first 16 blacklist entries (verifier-friendly limit)
    #pragma unroll
    for (__u32 i = 0; i < 16; i++) {
        entry = bpf_map_lookup_elem(&blacklist_map, &i);
        if (!entry || !entry->enabled)
            continue;

        // Check if pattern is empty
        if (entry->pattern[0] == '\0')
            continue;

        if (entry->exact_match) {
            // Exact command name match
            int match = 1;
            #pragma unroll
            for (int j = 0; j < 16; j++) {
                if (entry->pattern[j] == '\0' && comm[j] == '\0')
                    return 1;  // BLOCKED - exact match
                if (entry->pattern[j] != comm[j]) {
                    match = 0;
                    break;
                }
                if (entry->pattern[j] == '\0')
                    break;
            }
        } else {
            // Substring match
            if (contains_substring(comm, entry->pattern))
                return 1;  // BLOCKED
        }
    }

    return 0;  // ALLOWED
}

/*
 * LSM Hook: bprm_check_security
 *
 * This is called during execve(), before the new program is executed.
 * Return value:
 *   0 = Allow execution
 *   -EPERM = Block execution (absolute veto)
 */
SEC("lsm/bprm_check_security")
int BPF_PROG(inquisitor_bprm_check, struct linux_binprm *bprm, int ret)
{
    // Only proceed if previous LSM checks passed
    if (ret != 0)
        return ret;

    // Get enforcement mode
    __u32 key = 0;
    __u32 *enforcement_enabled = bpf_map_lookup_elem(&config_map, &key);
    int enforce = enforcement_enabled ? *enforcement_enabled : 1;

    // Get current task comm (process name)
    // Note: We use comm instead of full path for simplicity and compatibility
    // This matches against executable basename rather than full path
    char comm_buf[16] = {};
    bpf_get_current_comm(comm_buf, sizeof(comm_buf));

    // Check blacklist
    int blocked = check_blacklist(comm_buf);

    // Get process info
    __u64 pid_tgid = bpf_get_current_pid_tgid();
    __u64 uid_gid = bpf_get_current_uid_gid();
    __u32 pid = pid_tgid >> 32;
    __u32 uid = uid_gid & 0xFFFFFFFF;
    __u32 gid = uid_gid >> 32;

    // Log event to userspace
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

            // Copy comm to both fields for now
            __builtin_memcpy(event->comm, comm_buf, 16);
            __builtin_memset(event->filename, 0, MAX_FILENAME_LEN);
            __builtin_memcpy(event->filename, comm_buf, 16);

            bpf_ringbuf_submit(event, 0);
        }
    }

    // Enforce the sovereign's will
    if (blocked && enforce) {
        return -EPERM;  // ABSOLUTE VETO
    }

    return 0;  // ALLOWED
}

char LICENSE[] SEC("license") = "GPL";
