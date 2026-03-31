// SPDX-License-Identifier: GPL-2.0
/*
 * Guardian Shield - eBPF-based System Security Framework
 *
 * oracle-advanced.bpf.c - The All-Seeing Eye: Multi-Hook Defense Grid
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
 * THE DOCTRINE: Omniscient observation across all critical kernel interactions
 * THE IMPACT: Distributed, redundant web of tripwires vs single point failure
 *
 * Phase 1: Enhanced Core - Forging the Multi-Hook Defense Grid
 */

#include "vmlinux.h"
#include <bpf/bpf_helpers.h>
#include <bpf/bpf_tracing.h>
#include <bpf/bpf_core_read.h>

#define MAX_FILENAME_LEN 128
#define MAX_PATTERN_LEN 32
#define MAX_BLACKLIST_ENTRIES 32
#define MAX_PROCESS_CHAIN_DEPTH 3
#define EPERM 1

/*
 * EVENT TYPES - The Oracle's Vision Spectrum
 */
#define EVENT_EXECUTION    0x01  // Program execution
#define EVENT_FILE_ACCESS  0x02  // File open/read/write
#define EVENT_PROC_CREATE  0x03  // Process creation
#define EVENT_NETWORK      0x04  // Network connections
#define EVENT_MEMORY       0x05  // Memory mapping

/*
 * Sovereign Codex Entry - Advanced Pattern Matching
 */
struct sovereign_codex_entry {
    char pattern[MAX_PATTERN_LEN];
    __u8 match_type;        // 0=exact, 1=substring, 2=hash, 3=path
    __u8 severity;          // 0=info, 1=warning, 2=critical
    __u8 enabled;
    __u8 reserved;
    __u32 hash;             // Truncated SHA-256 for file matching
    __u16 flags;            // Case-insensitive, recursive, etc.
};

/*
 * Process Chain - The Bloodline of Execution
 */
struct process_chain {
    __u32 pid;
    __u32 parent_pid;
    __u32 grandparent_pid;
    __u64 start_time;
    char current_comm[16];
    char parent_comm[16];
    char grandparent_comm[16];
};

/*
 * Unified Event Structure - The Oracle's Memory
 */
struct oracle_event {
    __u32 event_type;       // EVENT_EXECUTION, etc.
    __u32 pid;
    __u32 uid;
    __u32 gid;
    __u32 blocked;          // 1 if blocked, 0 if allowed
    __u64 timestamp;
    char target[MAX_FILENAME_LEN];  // File, program, or network target
    char comm[16];          // Current process name
    char parent_comm[16];   // Parent process name
};

/*
 * BPF MAPS - The Oracle's Knowledge Base
 */

// Map 1: Sovereign Codex (Advanced Blacklist)
struct {
    __uint(type, BPF_MAP_TYPE_ARRAY);
    __uint(max_entries, MAX_BLACKLIST_ENTRIES);
    __type(key, __u32);
    __type(value, struct sovereign_codex_entry);
} sovereign_codex SEC(".maps");

// Map 2: Ring Buffer for Events
struct {
    __uint(type, BPF_MAP_TYPE_RINGBUF);
    __uint(max_entries, 512 * 1024);  // 512KB for enhanced logging
} oracle_events SEC(".maps");

// Map 3: Global Configuration
struct {
    __uint(type, BPF_MAP_TYPE_ARRAY);
    __uint(max_entries, 16);
    __type(key, __u32);
    __type(value, __u32);
} oracle_config SEC(".maps");

// Map 4: Process Chain Tracking (LRU for performance)
struct {
    __uint(type, BPF_MAP_TYPE_LRU_HASH);
    __uint(max_entries, 8192);
    __type(key, __u32);     // PID
    __type(value, struct process_chain);
} process_chain_map SEC(".maps");

/*
 * HELPER FUNCTIONS - The Oracle's Analytical Tools
 */

// String comparison (manual unroll for verifier)
static __always_inline int str_equals(const char *a, const char *b)
{
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
    if (a[15] == '\0') return 1;
    if (a[16] != b[16]) return 0;
    if (a[16] == '\0') return 1;
    if (a[17] != b[17]) return 0;
    if (a[17] == '\0') return 1;
    if (a[18] != b[18]) return 0;
    if (a[18] == '\0') return 1;
    if (a[19] != b[19]) return 0;
    if (a[19] == '\0') return 1;
    if (a[20] != b[20]) return 0;
    if (a[20] == '\0') return 1;
    if (a[21] != b[21]) return 0;
    if (a[21] == '\0') return 1;
    if (a[22] != b[22]) return 0;
    if (a[22] == '\0') return 1;
    if (a[23] != b[23]) return 0;
    if (a[23] == '\0') return 1;
    if (a[24] != b[24]) return 0;
    if (a[24] == '\0') return 1;
    if (a[25] != b[25]) return 0;
    if (a[25] == '\0') return 1;
    if (a[26] != b[26]) return 0;
    if (a[26] == '\0') return 1;
    if (a[27] != b[27]) return 0;
    if (a[27] == '\0') return 1;
    if (a[28] != b[28]) return 0;
    if (a[28] == '\0') return 1;
    if (a[29] != b[29]) return 0;
    if (a[29] == '\0') return 1;
    if (a[30] != b[30]) return 0;
    if (a[30] == '\0') return 1;
    if (a[31] != b[31]) return 0;
    return 1;
}

// Substring match (prefix, manual unroll for verifier)
static __always_inline int str_prefix_match(const char *target, const char *pattern)
{
    if (pattern[0] == '\0') return 0;
    if (target[0] != pattern[0]) return 0;
    if (pattern[1] == '\0') return 1;
    if (target[1] != pattern[1]) return 0;
    if (pattern[2] == '\0') return 1;
    if (target[2] != pattern[2]) return 0;
    if (pattern[3] == '\0') return 1;
    if (target[3] != pattern[3]) return 0;
    if (pattern[4] == '\0') return 1;
    if (target[4] != pattern[4]) return 0;
    if (pattern[5] == '\0') return 1;
    if (target[5] != pattern[5]) return 0;
    if (pattern[6] == '\0') return 1;
    if (target[6] != pattern[6]) return 0;
    if (pattern[7] == '\0') return 1;
    if (target[7] != pattern[7]) return 0;
    if (pattern[8] == '\0') return 1;
    if (target[8] != pattern[8]) return 0;
    if (pattern[9] == '\0') return 1;
    if (target[9] != pattern[9]) return 0;
    if (pattern[10] == '\0') return 1;
    if (target[10] != pattern[10]) return 0;
    if (pattern[11] == '\0') return 1;
    if (target[11] != pattern[11]) return 0;
    if (pattern[12] == '\0') return 1;
    if (target[12] != pattern[12]) return 0;
    if (pattern[13] == '\0') return 1;
    if (target[13] != pattern[13]) return 0;
    if (pattern[14] == '\0') return 1;
    if (target[14] != pattern[14]) return 0;
    if (pattern[15] == '\0') return 1;
    if (target[15] != pattern[15]) return 0;
    if (pattern[16] == '\0') return 1;
    if (target[16] != pattern[16]) return 0;
    if (pattern[17] == '\0') return 1;
    if (target[17] != pattern[17]) return 0;
    if (pattern[18] == '\0') return 1;
    if (target[18] != pattern[18]) return 0;
    if (pattern[19] == '\0') return 1;
    if (target[19] != pattern[19]) return 0;
    if (pattern[20] == '\0') return 1;
    if (target[20] != pattern[20]) return 0;
    if (pattern[21] == '\0') return 1;
    if (target[21] != pattern[21]) return 0;
    if (pattern[22] == '\0') return 1;
    if (target[22] != pattern[22]) return 0;
    if (pattern[23] == '\0') return 1;
    if (target[23] != pattern[23]) return 0;
    if (pattern[24] == '\0') return 1;
    if (target[24] != pattern[24]) return 0;
    if (pattern[25] == '\0') return 1;
    if (target[25] != pattern[25]) return 0;
    if (pattern[26] == '\0') return 1;
    if (target[26] != pattern[26]) return 0;
    if (pattern[27] == '\0') return 1;
    if (target[27] != pattern[27]) return 0;
    if (pattern[28] == '\0') return 1;
    if (target[28] != pattern[28]) return 0;
    if (pattern[29] == '\0') return 1;
    if (target[29] != pattern[29]) return 0;
    if (pattern[30] == '\0') return 1;
    if (target[30] != pattern[30]) return 0;
    if (pattern[31] == '\0') return 1;
    if (target[31] != pattern[31]) return 0;
    return 0;  // No match if beyond max
}

// Check Sovereign Codex for matches
static __always_inline int check_sovereign_codex(const char *target, __u8 event_type)
{
    struct sovereign_codex_entry *entry;

    // Check codex entries (unroll for performance)
    #pragma unroll
    for (__u32 i = 0; i < MAX_BLACKLIST_ENTRIES; i++) {
        entry = bpf_map_lookup_elem(&sovereign_codex, &i);
        if (!entry || !entry->enabled || entry->pattern[0] == '\0')
            continue;

        // Different matching strategies based on match_type
        if (entry->match_type == 0) { // Exact match
            if (str_equals(target, entry->pattern))
                return entry->severity;
        } else if (entry->match_type == 1) { // Substring match (prefix)
            if (str_prefix_match(target, entry->pattern))
                return entry->severity;
        }
        // TODO: Add hash matching and regex support in Phase 3
    }

    return 0; // No match
}

// Update process chain
static __always_inline void update_process_chain(__u32 pid, const char *comm)
{
    struct process_chain chain = {};
    __u64 pid_tgid = bpf_get_current_pid_tgid();
    __u32 current_pid = pid_tgid >> 32;

    chain.pid = pid;
    chain.start_time = bpf_ktime_get_ns();
    __builtin_memcpy(chain.current_comm, comm, 16);

    // Get parent info
    struct task_struct *task = (struct task_struct *)bpf_get_current_task();
    if (task) {
        struct task_struct *parent = BPF_CORE_READ(task, real_parent);
        if (parent) {
            chain.parent_pid = BPF_CORE_READ(parent, pid);
            bpf_probe_read_kernel_str(chain.parent_comm, 16, BPF_CORE_READ(parent, comm));

            // Get grandparent
            struct task_struct *grandparent = BPF_CORE_READ(parent, real_parent);
            if (grandparent) {
                chain.grandparent_pid = BPF_CORE_READ(grandparent, pid);
                bpf_probe_read_kernel_str(chain.grandparent_comm, 16, BPF_CORE_READ(grandparent, comm));
            }
        }
    }

    bpf_map_update_elem(&process_chain_map, &pid, &chain, BPF_ANY);
}

// Log event to ring buffer
static __always_inline void log_oracle_event(__u32 event_type, __u32 blocked,
                                           const char *target, const char *comm)
{
    struct oracle_event *event = bpf_ringbuf_reserve(&oracle_events,
                                                   sizeof(struct oracle_event), 0);
    if (!event) return;

    // Get process info
    __u64 pid_tgid = bpf_get_current_pid_tgid();
    __u64 uid_gid = bpf_get_current_uid_gid();

    event->event_type = event_type;
    event->pid = pid_tgid >> 32;
    event->uid = uid_gid & 0xFFFFFFFF;
    event->gid = uid_gid >> 32;
    event->blocked = blocked;
    event->timestamp = bpf_ktime_get_ns();

    __builtin_memcpy(event->target, target, MAX_FILENAME_LEN);
    __builtin_memcpy(event->comm, comm, 16);

    // Get parent process name
    char parent_comm[16] = {};
    struct task_struct *task = (struct task_struct *)bpf_get_current_task();
    if (task) {
        struct task_struct *parent = BPF_CORE_READ(task, real_parent);
        if (parent) {
            bpf_probe_read_kernel_str(parent_comm, 16, BPF_CORE_READ(parent, comm));
        }
    }
    __builtin_memcpy(event->parent_comm, parent_comm, 16);

    bpf_ringbuf_submit(event, 0);
}

/*
 * LSM HOOKS - The All-Seeing Eye's Vision Points
 */

// HOOK 1: Program Execution (Original bprm_check_security)
SEC("lsm/bprm_check_security")
int BPF_PROG(oracle_execution_hook, struct linux_binprm *bprm, int ret)
{
    if (ret != 0) return ret;

    // Get enforcement mode
    __u32 key = 0;
    __u32 *enforcement_enabled = bpf_map_lookup_elem(&oracle_config, &key);
    int enforce = enforcement_enabled ? *enforcement_enabled : 1;

    // Get basename directly from dentry (verifier-friendly, no loops)
    struct file *file = BPF_CORE_READ(bprm, file);
    if (!file) return 0;

    struct dentry *dentry = BPF_CORE_READ(file, f_path.dentry);
    if (!dentry) return 0;

    const char *name_ptr = BPF_CORE_READ(dentry, d_name.name);
    if (!name_ptr) return 0;

    char program_name[MAX_PATTERN_LEN] = {};
    long read_result = bpf_probe_read_kernel_str(program_name, sizeof(program_name), name_ptr);
    if (read_result < 0) return 0;

    // Check Sovereign Codex
    int severity = check_sovereign_codex(program_name, EVENT_EXECUTION);
    int blocked = (severity >= 2); // Block critical threats

    // Update process chain
    __u64 pid_tgid = bpf_get_current_pid_tgid();
    __u32 pid = pid_tgid >> 32;
    update_process_chain(pid, program_name);

    // Log event
    key = 1;
    __u32 *log_all = bpf_map_lookup_elem(&oracle_config, &key);
    int should_log = blocked || (log_all && *log_all) || (severity > 0);

    if (should_log) {
        log_oracle_event(EVENT_EXECUTION, blocked, program_name, program_name);
    }

    // Enforce blocking
    if (blocked && enforce) {
        bpf_printk("ORACLE: BLOCKED execution of '%s'", program_name);
        return -EPERM;
    }

    return 0;
}

// HOOK 2: File Access Monitoring (file_open)
SEC("lsm/file_open")
int BPF_PROG(oracle_file_open_hook, struct file *file, int ret)
{
    if (ret != 0) return ret;

    // Simplified file access monitoring - just log that file was opened
    // Full path extraction is complex in BPF, so we'll focus on process context
    char comm[16] = {};
    bpf_get_current_comm(comm, sizeof(comm));

    // Log all file opens for now (can be filtered in userspace)
    log_oracle_event(EVENT_FILE_ACCESS, 0, "[FILE_OPEN]", comm);
    bpf_printk("ORACLE: File opened by '%s'", comm);

    return 0;
}

// HOOK 3: Process Creation Tracking (task_alloc)
SEC("lsm/task_alloc")
int BPF_PROG(oracle_task_alloc_hook, struct task_struct *task, unsigned long clone_flags, int ret)
{
    if (ret != 0) return ret;

    // Get new process info
    __u32 new_pid = BPF_CORE_READ(task, pid);
    char new_comm[16] = {};
    bpf_probe_read_kernel_str(new_comm, 16, BPF_CORE_READ(task, comm));

    // Log significant process creation
    // (e.g., fork bombs, unusual parent-child relationships)
    char parent_comm[16] = {};
    struct task_struct *parent = BPF_CORE_READ(task, real_parent);
    if (parent) {
        bpf_probe_read_kernel_str(parent_comm, 16, BPF_CORE_READ(parent, comm));
    }

    // Detect potential fork bombs (rapid process creation)
    static __u64 last_fork_time = 0;
    __u64 current_time = bpf_ktime_get_ns();

    if (current_time - last_fork_time < 1000000) { // 1ms between forks
        bpf_printk("ORACLE: Rapid process creation detected - potential fork bomb");
        log_oracle_event(EVENT_PROC_CREATE, 0, "RAPID_FORK", new_comm);
    }
    last_fork_time = current_time;

    return 0;
}

char LICENSE[] SEC("license") = "GPL";
