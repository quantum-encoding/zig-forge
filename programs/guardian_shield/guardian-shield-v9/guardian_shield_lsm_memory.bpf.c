// guardian_shield_lsm_memory.bpf.c
// LSM BPF program for memory-based attack prevention and privilege control
// Addresses: ptrace injection, /dev/mem access, kernel module loading, capability abuse

#include "vmlinux.h"
#include <bpf/bpf_helpers.h>
#include <bpf/bpf_tracing.h>
#include <bpf/bpf_core_read.h>

char LICENSE[] SEC("license") = "GPL";

// ===================================================================
// CONSTANTS
// ===================================================================

#define MAX_COMM_LEN 16
#define MAX_PATH_LEN 256

// Device major/minor numbers
#define MEM_MAJOR 1
#define MEM_MINOR 1      // /dev/mem
#define KMEM_MINOR 2     // /dev/kmem
#define PORT_MINOR 4     // /dev/port

// ===================================================================
// DATA STRUCTURES
// ===================================================================

struct memory_violation {
    u64 timestamp;
    u32 pid;
    u32 uid;
    char comm[MAX_COMM_LEN];
    u8 violation_type;
    u32 target_pid;      // For ptrace
    u32 capability;      // For capability checks
    char module_name[64]; // For module loading
};

enum violation_type {
    VIOL_PTRACE = 1,
    VIOL_PROCESS_VM = 2,
    VIOL_DEV_MEM = 3,
    VIOL_MODULE_LOAD = 4,
    VIOL_CAPABILITY = 5,
    VIOL_SUID_EXEC = 6,
};

// ===================================================================
// BPF MAPS
// ===================================================================

struct {
    __uint(type, BPF_MAP_TYPE_RINGBUF);
    __uint(max_entries, 256 * 1024);
} memory_violations SEC(".maps");

// Allowed debuggers (e.g., gdb, strace, lldb)
struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __type(key, char[MAX_COMM_LEN]);
    __type(value, u8);
    __uint(max_entries, 100);
} allowed_debuggers SEC(".maps");

// Privileged processes (can request dangerous capabilities)
struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __type(key, u32); // PID
    __type(value, u8);
    __uint(max_entries, 1000);
} privileged_processes SEC(".maps");

// Whitelisted SUID binaries
struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __type(key, char[MAX_PATH_LEN]);
    __type(value, u8);
    __uint(max_entries, 500);
} whitelisted_suid SEC(".maps");

// Statistics
struct {
    __uint(type, BPF_MAP_TYPE_ARRAY);
    __type(key, u32);
    __type(value, u64);
    __uint(max_entries, 20);
} memory_stats SEC(".maps");

// ===================================================================
// HELPER FUNCTIONS
// ===================================================================

static __always_inline void log_memory_violation(
    u8 viol_type,
    u32 target_pid,
    u32 capability,
    const char *module_name)
{
    struct memory_violation *event;
    
    event = bpf_ringbuf_reserve(&memory_violations, sizeof(*event), 0);
    if (!event)
        return;
    
    event->timestamp = bpf_ktime_get_ns();
    event->pid = bpf_get_current_pid_tgid() >> 32;
    event->uid = bpf_get_current_uid_gid() & 0xFFFFFFFF;
    bpf_get_current_comm(&event->comm, sizeof(event->comm));
    event->violation_type = viol_type;
    event->target_pid = target_pid;
    event->capability = capability;
    
    if (module_name) {
        bpf_probe_read_kernel_str(event->module_name, sizeof(event->module_name), module_name);
    }
    
    bpf_ringbuf_submit(event, 0);
}

static __always_inline bool is_allowed_debugger(void)
{
    char comm[MAX_COMM_LEN];
    bpf_get_current_comm(&comm, sizeof(comm));
    
    u8 *allowed = bpf_map_lookup_elem(&allowed_debuggers, &comm);
    return (allowed != NULL);
}

static __always_inline bool is_privileged_process(void)
{
    u32 pid = bpf_get_current_pid_tgid() >> 32;
    u8 *priv = bpf_map_lookup_elem(&privileged_processes, &pid);
    return (priv != NULL);
}

// ===================================================================
// LSM BPF HOOKS
// ===================================================================

// 1. PTRACE PROTECTION - Prevent code injection via ptrace
SEC("lsm/ptrace_access_check")
int BPF_PROG(restrict_ptrace, struct task_struct *child, unsigned int mode)
{
    // Allow if debugger is whitelisted
    if (is_allowed_debugger()) {
        return 0;
    }
    
    u32 tracer_pid = bpf_get_current_pid_tgid() >> 32;
    u32 target_pid = BPF_CORE_READ(child, pid);
    
    // Block all other ptrace attempts
    log_memory_violation(VIOL_PTRACE, target_pid, 0, NULL);
    return -EPERM;
}

// 2. PROCESS MEMORY WRITE - Prevent process_vm_writev injection
SEC("lsm/ptrace_traceme")
int BPF_PROG(restrict_traceme, struct task_struct *parent)
{
    // Even traceme can be abused for injection
    if (!is_allowed_debugger()) {
        u32 pid = bpf_get_current_pid_tgid() >> 32;
        log_memory_violation(VIOL_PROCESS_VM, pid, 0, NULL);
        return -EPERM;
    }
    return 0;
}

// 3. /dev/mem and /dev/kmem PROTECTION
SEC("lsm/file_open")
int BPF_PROG(restrict_dev_mem, struct file *file)
{
    struct inode *inode = BPF_CORE_READ(file, f_inode);
    umode_t mode = BPF_CORE_READ(inode, i_mode);
    
    // Only check character devices
    if (!S_ISCHR(mode))
        return 0;
    
    dev_t dev = BPF_CORE_READ(inode, i_rdev);
    unsigned int major = MAJOR(dev);
    unsigned int minor = MINOR(dev);
    
    // Block /dev/mem, /dev/kmem, /dev/port
    if (major == MEM_MAJOR && 
        (minor == MEM_MINOR || minor == KMEM_MINOR || minor == PORT_MINOR)) {
        
        // Only allow for privileged processes
        if (!is_privileged_process()) {
            log_memory_violation(VIOL_DEV_MEM, 0, 0, NULL);
            return -EPERM;
        }
    }
    
    return 0;
}

// 4. KERNEL MODULE LOADING - Prevent rootkit installation
SEC("lsm/kernel_module_request")
int BPF_PROG(restrict_module_request, char *kmod_name)
{
    // Only privileged processes can request module loading
    if (!is_privileged_process()) {
        log_memory_violation(VIOL_MODULE_LOAD, 0, 0, kmod_name);
        return -EPERM;
    }
    
    // TODO: Add module whitelist checking
    return 0;
}

SEC("lsm/kernel_read_file")
int BPF_PROG(restrict_kernel_read, struct file *file, 
             enum kernel_read_file_id id, bool contents)
{
    // Block module loading for non-privileged
    if (id == READING_MODULE) {
        if (!is_privileged_process()) {
            log_memory_violation(VIOL_MODULE_LOAD, 0, 0, NULL);
            return -EACCES;
        }
    }
    
    return 0;
}

// 5. CAPABILITY CHECKS - Prevent capability abuse
SEC("lsm/capable")
int BPF_PROG(restrict_capabilities, const struct cred *cred,
             struct user_namespace *ns, int cap, unsigned int opts)
{
    // List of dangerous capabilities
    bool is_dangerous = false;
    
    switch (cap) {
        case CAP_SYS_ADMIN:     // Can do almost anything
        case CAP_SYS_MODULE:    // Load kernel modules
        case CAP_SYS_RAWIO:     // Access /dev/mem, /dev/kmem
        case CAP_SYS_PTRACE:    // Ptrace any process
        case CAP_SYS_BOOT:      // Reboot system
        case CAP_DAC_OVERRIDE:  // Bypass file permissions
        case CAP_DAC_READ_SEARCH: // Bypass read permissions
            is_dangerous = true;
            break;
    }
    
    if (is_dangerous && !is_privileged_process()) {
        log_memory_violation(VIOL_CAPABILITY, 0, cap, NULL);
        return -EPERM;
    }
    
    return 0;
}

// 6. SUID BINARY EXECUTION - Control privileged execution
SEC("lsm/bprm_check_security")
int BPF_PROG(restrict_suid_exec, struct linux_binprm *bprm)
{
    struct file *file = BPF_CORE_READ(bprm, file);
    struct inode *inode = BPF_CORE_READ(file, f_inode);
    umode_t mode = BPF_CORE_READ(inode, i_mode);
    
    // Check if SUID or SGID
    if (!(mode & (S_ISUID | S_ISGID)))
        return 0;
    
    // Get binary path
    const char *pathname = BPF_CORE_READ(bprm, filename);
    
    // Check whitelist
    u8 *whitelisted = bpf_map_lookup_elem(&whitelisted_suid, pathname);
    if (whitelisted) {
        return 0;
    }
    
    // Block non-whitelisted SUID binaries
    log_memory_violation(VIOL_SUID_EXEC, 0, 0, pathname);
    return -EACCES;
}

// 7. SETUID/SETGID SYSCALLS - Prevent privilege escalation
SEC("lsm/task_setuid")
int BPF_PROG(restrict_setuid, uid_t id0, uid_t id1, uid_t id2, int flags)
{
    // Only allow if process is already privileged
    if (!is_privileged_process()) {
        u32 current_uid = bpf_get_current_uid_gid() & 0xFFFFFFFF;
        
        // Block if trying to escalate to root
        if (current_uid != 0 && (id0 == 0 || id1 == 0 || id2 == 0)) {
            log_memory_violation(VIOL_CAPABILITY, 0, CAP_SETUID, NULL);
            return -EPERM;
        }
    }
    
    return 0;
}

// ===================================================================
// NAMESPACE AND CONTAINER SECURITY
// ===================================================================

// 8. NAMESPACE OPERATIONS - Prevent container escapes
SEC("lsm/task_setns")
int BPF_PROG(restrict_namespace_enter, struct task_struct *task,
             struct ns_common *ns, int flags)
{
    u32 pid = bpf_get_current_pid_tgid() >> 32;
    u32 target_pid = BPF_CORE_READ(task, pid);
    
    // Block if trying to enter different namespace
    if (pid != target_pid && !is_privileged_process()) {
        log_memory_violation(VIOL_CAPABILITY, target_pid, CAP_SYS_ADMIN, NULL);
        return -EPERM;
    }
    
    return 0;
}

// 9. MOUNT OPERATIONS - Prevent mount-based escapes
SEC("lsm/move_mount")
int BPF_PROG(restrict_move_mount, const struct path *from_path,
             const struct path *to_path)
{
    // Only privileged processes can move mounts
    if (!is_privileged_process()) {
        log_memory_violation(VIOL_CAPABILITY, 0, CAP_SYS_ADMIN, NULL);
        return -EPERM;
    }
    
    return 0;
}

SEC("lsm/sb_mount")
int BPF_PROG(restrict_mount, const char *dev_name, const struct path *path,
             const char *type, unsigned long flags, void *data)
{
    // Only privileged processes can mount
    if (!is_privileged_process()) {
        log_memory_violation(VIOL_CAPABILITY, 0, CAP_SYS_ADMIN, NULL);
        return -EPERM;
    }
    
    return 0;
}

SEC("lsm/sb_umount")
int BPF_PROG(restrict_umount, struct vfsmount *mnt, int flags)
{
    // Only privileged processes can unmount
    if (!is_privileged_process()) {
        log_memory_violation(VIOL_CAPABILITY, 0, CAP_SYS_ADMIN, NULL);
        return -EPERM;
    }
    
    return 0;
}
