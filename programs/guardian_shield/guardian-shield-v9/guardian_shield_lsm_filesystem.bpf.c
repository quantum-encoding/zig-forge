// guardian_shield_lsm_filesystem.bpf.c
// LSM BPF program for comprehensive filesystem protection
// Addresses direct syscall bypass vulnerability
//
// Compile with: clang -O2 -g -target bpf -c guardian_shield_lsm_filesystem.bpf.c -o guardian_shield_lsm_filesystem.bpf.o

#include "vmlinux.h"
#include <bpf/bpf_helpers.h>
#include <bpf/bpf_tracing.h>
#include <bpf/bpf_core_read.h>

// License required for GPL-only BPF helpers
char LICENSE[] SEC("license") = "GPL";

// ===================================================================
// CONFIGURATION & CONSTANTS
// ===================================================================

#define MAX_PATH_LEN 256
#define MAX_COMM_LEN 16
#define MAX_PROTECTED_PATHS 100
#define MAX_ALLOWED_PROCESSES 1000

// Event types for violation logging
enum event_type {
    EVENT_UNLINK_BLOCKED = 1,
    EVENT_RENAME_BLOCKED = 2,
    EVENT_CHMOD_BLOCKED = 3,
    EVENT_CHOWN_BLOCKED = 4,
    EVENT_TRUNCATE_BLOCKED = 5,
    EVENT_LINK_BLOCKED = 6,
    EVENT_SYMLINK_BLOCKED = 7,
    EVENT_MKDIR_BLOCKED = 8,
    EVENT_RMDIR_BLOCKED = 9,
};

// ===================================================================
// DATA STRUCTURES
// ===================================================================

struct violation_event {
    u64 timestamp;
    u32 pid;
    u32 uid;
    u32 gid;
    char comm[MAX_COMM_LEN];
    u8 event_type;
    char path[MAX_PATH_LEN];
    char target_path[MAX_PATH_LEN]; // For rename/link operations
    int error_code;
};

struct path_rule {
    char prefix[MAX_PATH_LEN];
    u32 prefix_len;
    u8 action; // 0 = allow, 1 = block
};

struct process_rule {
    char comm[MAX_COMM_LEN];
    u8 exempt; // If 1, bypass all path checks
};

// ===================================================================
// BPF MAPS
// ===================================================================

// Ring buffer for high-performance event streaming to userspace
struct {
    __uint(type, BPF_MAP_TYPE_RINGBUF);
    __uint(max_entries, 256 * 1024); // 256KB ring buffer
} violation_events SEC(".maps");

// Protected path rules (populated from userspace)
struct {
    __uint(type, BPF_MAP_TYPE_ARRAY);
    __type(key, u32);
    __type(value, struct path_rule);
    __uint(max_entries, MAX_PROTECTED_PATHS);
} protected_paths SEC(".maps");

// Process allowlist (e.g., package managers, build tools)
struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __type(key, char[MAX_COMM_LEN]);
    __type(value, struct process_rule);
    __uint(max_entries, MAX_ALLOWED_PROCESSES);
} process_allowlist SEC(".maps");

// Statistics counters
struct {
    __uint(type, BPF_MAP_TYPE_ARRAY);
    __type(key, u32);
    __type(value, u64);
    __uint(max_entries, 10); // 10 different stat counters
} stats SEC(".maps");

enum stat_counter {
    STAT_TOTAL_CHECKS = 0,
    STAT_BLOCKED_OPS = 1,
    STAT_ALLOWED_OPS = 2,
    STAT_EXEMPT_PROCS = 3,
};

// ===================================================================
// HELPER FUNCTIONS
// ===================================================================

static __always_inline void increment_stat(u32 counter)
{
    u64 *val = bpf_map_lookup_elem(&stats, &counter);
    if (val) {
        __sync_fetch_and_add(val, 1);
    }
}

static __always_inline int str_len(const char *s)
{
    int len = 0;
    #pragma unroll
    for (int i = 0; i < MAX_PATH_LEN; i++) {
        if (s[i] == '\0')
            break;
        len++;
    }
    return len;
}

static __always_inline bool str_starts_with(const char *str, const char *prefix, u32 prefix_len)
{
    #pragma unroll
    for (u32 i = 0; i < prefix_len && i < MAX_PATH_LEN; i++) {
        if (str[i] != prefix[i])
            return false;
        if (str[i] == '\0')
            return (i >= prefix_len - 1);
    }
    return true;
}

static __always_inline bool is_process_exempt(void)
{
    char comm[MAX_COMM_LEN];
    bpf_get_current_comm(&comm, sizeof(comm));
    
    struct process_rule *rule = bpf_map_lookup_elem(&process_allowlist, &comm);
    if (rule && rule->exempt) {
        increment_stat(STAT_EXEMPT_PROCS);
        return true;
    }
    return false;
}

static __always_inline bool is_protected_path(const char *path)
{
    u32 path_len = str_len(path);
    
    // Iterate through protected path rules
    #pragma unroll
    for (u32 i = 0; i < MAX_PROTECTED_PATHS; i++) {
        struct path_rule *rule = bpf_map_lookup_elem(&protected_paths, &i);
        if (!rule || rule->prefix_len == 0)
            continue;
        
        if (str_starts_with(path, rule->prefix, rule->prefix_len)) {
            if (rule->action == 1) { // Block
                return true;
            }
        }
    }
    
    return false;
}

static __always_inline void log_violation(
    u8 event_type,
    const char *path,
    const char *target_path,
    int error_code)
{
    struct violation_event *event;
    
    event = bpf_ringbuf_reserve(&violation_events, sizeof(*event), 0);
    if (!event)
        return;
    
    event->timestamp = bpf_ktime_get_ns();
    event->pid = bpf_get_current_pid_tgid() >> 32;
    event->uid = bpf_get_current_uid_gid() & 0xFFFFFFFF;
    event->gid = bpf_get_current_uid_gid() >> 32;
    bpf_get_current_comm(&event->comm, sizeof(event->comm));
    event->event_type = event_type;
    event->error_code = error_code;
    
    // Copy paths safely
    bpf_probe_read_kernel_str(event->path, sizeof(event->path), path);
    if (target_path) {
        bpf_probe_read_kernel_str(event->target_path, sizeof(event->target_path), target_path);
    }
    
    bpf_ringbuf_submit(event, 0);
    increment_stat(STAT_BLOCKED_OPS);
}

// Helper to get dentry path (simplified)
static __always_inline void get_dentry_path(struct dentry *dentry, char *buf, size_t size)
{
    const char *name = BPF_CORE_READ(dentry, d_name.name);
    if (name) {
        bpf_probe_read_kernel_str(buf, size, name);
    }
}

// ===================================================================
// LSM BPF HOOKS
// ===================================================================

// 1. FILE UNLINK - Prevent deletion of protected files
SEC("lsm/inode_unlink")
int BPF_PROG(restrict_unlink, struct inode *dir, struct dentry *dentry)
{
    increment_stat(STAT_TOTAL_CHECKS);
    
    // Check if process is exempt (e.g., package managers)
    if (is_process_exempt()) {
        increment_stat(STAT_ALLOWED_OPS);
        return 0;
    }
    
    // Get file path from dentry
    char path[MAX_PATH_LEN];
    get_dentry_path(dentry, path, sizeof(path));
    
    // Check if path is protected
    if (is_protected_path(path)) {
        log_violation(EVENT_UNLINK_BLOCKED, path, NULL, -EACCES);
        return -EACCES;
    }
    
    increment_stat(STAT_ALLOWED_OPS);
    return 0;
}

// 2. FILE RENAME - Prevent moving/renaming protected files
SEC("lsm/inode_rename")
int BPF_PROG(restrict_rename,
             struct inode *old_dir, struct dentry *old_dentry,
             struct inode *new_dir, struct dentry *new_dentry)
{
    increment_stat(STAT_TOTAL_CHECKS);
    
    if (is_process_exempt()) {
        increment_stat(STAT_ALLOWED_OPS);
        return 0;
    }
    
    char old_path[MAX_PATH_LEN];
    char new_path[MAX_PATH_LEN];
    get_dentry_path(old_dentry, old_path, sizeof(old_path));
    get_dentry_path(new_dentry, new_path, sizeof(new_path));
    
    // Block if either source or dest is protected
    if (is_protected_path(old_path) || is_protected_path(new_path)) {
        log_violation(EVENT_RENAME_BLOCKED, old_path, new_path, -EACCES);
        return -EACCES;
    }
    
    increment_stat(STAT_ALLOWED_OPS);
    return 0;
}

// 3. FILE PERMISSION CHANGE - Prevent chmod on protected files
SEC("lsm/inode_setattr")
int BPF_PROG(restrict_chmod, struct dentry *dentry, struct iattr *attr)
{
    increment_stat(STAT_TOTAL_CHECKS);
    
    if (is_process_exempt()) {
        increment_stat(STAT_ALLOWED_OPS);
        return 0;
    }
    
    // Only check if changing permissions
    if (!(attr->ia_valid & ATTR_MODE)) {
        increment_stat(STAT_ALLOWED_OPS);
        return 0;
    }
    
    char path[MAX_PATH_LEN];
    get_dentry_path(dentry, path, sizeof(path));
    
    if (is_protected_path(path)) {
        log_violation(EVENT_CHMOD_BLOCKED, path, NULL, -EPERM);
        return -EPERM;
    }
    
    increment_stat(STAT_ALLOWED_OPS);
    return 0;
}

// 4. FILE TRUNCATE - Prevent data destruction
SEC("lsm/file_truncate")
int BPF_PROG(restrict_truncate, struct file *file)
{
    increment_stat(STAT_TOTAL_CHECKS);
    
    if (is_process_exempt()) {
        increment_stat(STAT_ALLOWED_OPS);
        return 0;
    }
    
    struct dentry *dentry = BPF_CORE_READ(file, f_path.dentry);
    char path[MAX_PATH_LEN];
    get_dentry_path(dentry, path, sizeof(path));
    
    if (is_protected_path(path)) {
        log_violation(EVENT_TRUNCATE_BLOCKED, path, NULL, -EACCES);
        return -EACCES;
    }
    
    increment_stat(STAT_ALLOWED_OPS);
    return 0;
}

// 5. HARD LINK CREATION - Prevent privilege escalation via hardlinks
SEC("lsm/inode_link")
int BPF_PROG(restrict_link,
             struct dentry *old_dentry,
             struct inode *dir,
             struct dentry *new_dentry)
{
    increment_stat(STAT_TOTAL_CHECKS);
    
    if (is_process_exempt()) {
        increment_stat(STAT_ALLOWED_OPS);
        return 0;
    }
    
    char old_path[MAX_PATH_LEN];
    char new_path[MAX_PATH_LEN];
    get_dentry_path(old_dentry, old_path, sizeof(old_path));
    get_dentry_path(new_dentry, new_path, sizeof(new_path));
    
    // Block hardlinks to/from protected paths
    if (is_protected_path(old_path) || is_protected_path(new_path)) {
        log_violation(EVENT_LINK_BLOCKED, old_path, new_path, -EPERM);
        return -EPERM;
    }
    
    increment_stat(STAT_ALLOWED_OPS);
    return 0;
}

// 6. SYMBOLIC LINK CREATION - Prevent symlink attacks
SEC("lsm/inode_symlink")
int BPF_PROG(restrict_symlink,
             struct inode *dir,
             struct dentry *dentry,
             const char *old_name)
{
    increment_stat(STAT_TOTAL_CHECKS);
    
    if (is_process_exempt()) {
        increment_stat(STAT_ALLOWED_OPS);
        return 0;
    }
    
    char new_path[MAX_PATH_LEN];
    get_dentry_path(dentry, new_path, sizeof(new_path));
    
    // Block symlinks pointing to or from protected paths
    if (is_protected_path(new_path) || is_protected_path(old_name)) {
        log_violation(EVENT_SYMLINK_BLOCKED, new_path, old_name, -EACCES);
        return -EACCES;
    }
    
    increment_stat(STAT_ALLOWED_OPS);
    return 0;
}

// 7. DIRECTORY CREATION - Prevent PATH injection
SEC("lsm/inode_mkdir")
int BPF_PROG(restrict_mkdir,
             struct inode *dir,
             struct dentry *dentry,
             umode_t mode)
{
    increment_stat(STAT_TOTAL_CHECKS);
    
    if (is_process_exempt()) {
        increment_stat(STAT_ALLOWED_OPS);
        return 0;
    }
    
    char path[MAX_PATH_LEN];
    get_dentry_path(dentry, path, sizeof(path));
    
    if (is_protected_path(path)) {
        log_violation(EVENT_MKDIR_BLOCKED, path, NULL, -EACCES);
        return -EACCES;
    }
    
    increment_stat(STAT_ALLOWED_OPS);
    return 0;
}

// 8. DIRECTORY REMOVAL - Prevent critical directory deletion
SEC("lsm/inode_rmdir")
int BPF_PROG(restrict_rmdir, struct inode *dir, struct dentry *dentry)
{
    increment_stat(STAT_TOTAL_CHECKS);
    
    if (is_process_exempt()) {
        increment_stat(STAT_ALLOWED_OPS);
        return 0;
    }
    
    char path[MAX_PATH_LEN];
    get_dentry_path(dentry, path, sizeof(path));
    
    if (is_protected_path(path)) {
        log_violation(EVENT_RMDIR_BLOCKED, path, NULL, -EACCES);
        return -EACCES;
    }
    
    increment_stat(STAT_ALLOWED_OPS);
    return 0;
}

// ===================================================================
// INITIALIZATION
// ===================================================================

// Optional: Can be used to set default policies from userspace
SEC("lsm.s/init")
int BPF_PROG(guardian_shield_init)
{
    // Initialize statistics
    u32 key;
    u64 zero = 0;
    
    for (key = 0; key < 10; key++) {
        bpf_map_update_elem(&stats, &key, &zero, BPF_ANY);
    }
    
    return 0;
}
