// guardian_shield.bpf.c
// Guardian Shield v9 - BPF-LSM kernel-level filesystem + memory enforcement.
//
// This single translation unit produces ONE BPF object containing three
// cooperating concerns that share maps:
//
//   1. Process-tree tracker (tp_btf: exec / fork / exit) -> agent_pids map.
//      Identity is a PID-tree tag, NOT bpf_get_current_comm (comm is a
//      15-char forgeable label defeated by prctl(PR_SET_NAME)). A process is
//      tagged AGENT when it execs a known agent-launcher binary; the tag is
//      inherited by every fork() child and survives exec() of any other
//      binary, so an agent cannot escape enforcement by spawning /bin/rm or
//      renaming itself.
//
//   2. Filesystem enforcement (lsm/path_* + lsm/file_open). Protected paths
//      are matched with an LPM trie (longest-prefix) after the ABSOLUTE path
//      is reconstructed. Reconstruction is mount-aware (crosses mount points)
//      because /home and /boot are separate mounts on the target host.
//      file_open and path_truncate use the GPL bpf_d_path() helper (allowed
//      on those hooks) which yields the fully canonical path and closes the
//      `..` / symlink / TOCTOU gap the userspace libwarden cannot.
//
//   3. Memory / privilege enforcement (lsm/ptrace_access_check, /dev/mem via
//      file_open, module load, dangerous capabilities, mount ops), all keyed
//      on the same agent_pids tag rather than comm.
//
// Enforcement is gated by a runtime config map: the loader populates all
// policy maps FIRST, then flips `ready`, so no hook enforces against an empty
// policy during load (fail-safe ordering).
//
// Compile: clang -O2 -g -target bpf -mcpu=v3 -c guardian_shield.bpf.c -o guardian_shield.bpf.o

#include "vmlinux.h"
#include <bpf/bpf_helpers.h>
#include <bpf/bpf_tracing.h>
#include <bpf/bpf_core_read.h>

char LICENSE[] SEC("license") = "GPL";

// ===================================================================
// CONSTANTS (vmlinux.h does not provide UAPI constants)
// ===================================================================

// MAX_PATH_LEN is 128, not 256: recon_ctx is passed to bpf_loop() as a STACK
// pointer, so it must fit the 512-byte BPF stack with room for the frame. A
// protected prefix always sits at the START of the reconstructed path, so 128
// bytes is more than enough to hold prefix + boundary char for matching.
#define MAX_PATH_LEN        128
#define MAX_COMPONENT_LEN   64
#define MAX_DENTRY_DEPTH    16     // power of two: index masking for verifier
#define MAX_EXE_NAME        64
#define MAX_EXE_PATH        256
#define MAX_PROTECTED_PATHS 1024
#define MAX_AGENT_PIDS      65536

#define EPERM   1
#define EACCES  13

#define O_WRONLY 00000001
#define O_RDWR   00000002
#define O_ACCMODE 00000003
#define O_CREAT  00000100
#define O_TRUNC  00001000

#define S_IFMT  0170000
#define S_IFCHR 0020000
#define S_ISUID 0004000
#define S_ISGID 0002000
#define S_ISCHR(m) (((m) & S_IFMT) == S_IFCHR)

// Kernel internal dev_t encoding (include/linux/kdev_t.h)
#define MINORBITS 20
#define MINORMASK ((1U << MINORBITS) - 1)
#define GS_MAJOR(dev) ((unsigned int)((dev) >> MINORBITS))
#define GS_MINOR(dev) ((unsigned int)((dev) & MINORMASK))

#define MEM_MAJOR 1
#define MEM_MINOR 1     // /dev/mem
#define KMEM_MINOR 2    // /dev/kmem
#define PORT_MINOR 4    // /dev/port

// Dangerous capabilities (uapi/linux/capability.h)
#define CAP_DAC_OVERRIDE     1
#define CAP_DAC_READ_SEARCH  2
#define CAP_SETUID           7
#define CAP_SYS_MODULE      16
#define CAP_SYS_RAWIO       17
#define CAP_SYS_PTRACE      19
#define CAP_SYS_ADMIN       21
#define CAP_SYS_BOOT        22

// READING_MODULE comes from enum kernel_read_file_id in vmlinux.h (== 2).

// container_of (struct mount <- struct vfsmount) is provided by bpf_helpers.h.
// The offset is taken from the host's own vmlinux.h (generated from THIS
// kernel's BTF), so it is exact for this kernel. Field READS below still go
// through CO-RE relocations.

// ===================================================================
// PROCESS-TREE TAGGING
// ===================================================================

#define TAG_AGENT  1   // restricted subtree
#define TAG_EXEMPT 2   // explicitly trusted (overrides inherited AGENT)

struct proc_tag {
    __u8  tag;         // TAG_AGENT | TAG_EXEMPT
    __u32 root_tgid;   // tgid of the subtree root that was first tagged
    __u64 since_ns;    // when tagged (monotonic)
};

// ===================================================================
// EVENTS
// ===================================================================

enum event_type {
    EV_UNLINK = 1,
    EV_RENAME = 2,
    EV_CHMOD = 3,
    EV_TRUNCATE = 4,
    EV_LINK = 5,
    EV_SYMLINK = 6,
    EV_MKDIR = 7,
    EV_RMDIR = 8,
    EV_OPEN_WRITE = 9,
    EV_PTRACE = 20,
    EV_DEV_MEM = 21,
    EV_MODULE_LOAD = 22,
    EV_CAPABILITY = 23,
    EV_MOUNT = 24,
};

struct violation_event {
    __u64 timestamp;
    __u32 pid;         // tgid
    __u32 tid;         // thread pid
    __u32 uid;
    __u32 gid;
    __u32 target_pid;  // ptrace target / mount / etc.
    __u32 aux;         // capability number, dev minor, etc.
    __u8  event_type;
    __u8  tag;         // acting process tag
    __u8  enforced;    // 1 = blocked, 0 = log-only
    __u8  _pad;
    char  comm[16];    // advisory only (NOT used for identity)
    char  path[MAX_PATH_LEN];
    char  target_path[MAX_PATH_LEN];
};

struct exec_event {
    __u32 pid;         // tgid
    __u32 tag;
    char  filename[MAX_EXE_PATH];
};

// ===================================================================
// MAPS
// ===================================================================

struct {
    __uint(type, BPF_MAP_TYPE_RINGBUF);
    __uint(max_entries, 256 * 1024);
} violation_events SEC(".maps");

struct {
    __uint(type, BPF_MAP_TYPE_RINGBUF);
    __uint(max_entries, 64 * 1024);
} exec_events SEC(".maps");

// PID-tree tags. Keyed by tgid (process id). Threads share their tgid entry.
struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __type(key, __u32);
    __type(value, struct proc_tag);
    __uint(max_entries, MAX_AGENT_PIDS);
} agent_pids SEC(".maps");

// Longest-prefix protected path trie. key = {prefixlen_bits, path bytes}.
struct path_lpm_key {
    __u32 prefixlen;             // in BITS (8 * strlen(prefix))
    __u8  data[MAX_PATH_LEN];
};

struct path_rule {
    __u32 prefix_len;            // in BYTES (for boundary check)
    __u8  action;                // 1 = block
    __u8  _pad[3];
};

struct {
    __uint(type, BPF_MAP_TYPE_LPM_TRIE);
    __type(key, struct path_lpm_key);
    __type(value, struct path_rule);
    __uint(max_entries, MAX_PROTECTED_PATHS);
    __uint(map_flags, BPF_F_NO_PREALLOC);   // required for LPM_TRIE
} protected_paths SEC(".maps");

// Agent-launcher basenames (exec classifier). Populated from config.
struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __type(key, char[MAX_EXE_NAME]);
    __type(value, __u8);
    __uint(max_entries, 512);
} agent_exe_names SEC(".maps");

// Operator exempt exe FULL PATHS. exec of one of these tags the pid EXEMPT
// (overrides inherited AGENT). Keyed on path, not comm.
struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __type(key, char[MAX_EXE_PATH]);
    __type(value, __u8);
    __uint(max_entries, 512);
} exempt_exes SEC(".maps");

struct {
    __uint(type, BPF_MAP_TYPE_ARRAY);
    __type(key, __u32);
    __type(value, __u64);
    __uint(max_entries, 24);
} stats SEC(".maps");

enum stat_counter {
    STAT_EXEC_SEEN = 0,
    STAT_AGENT_TAGGED = 1,
    STAT_FORK_INHERIT = 2,
    STAT_FS_CHECKS = 3,
    STAT_FS_BLOCKED = 4,
    STAT_MEM_BLOCKED = 5,
    STAT_PATH_TRUNC = 6,   // path reconstruction hit depth/length cap
};

// Runtime config (single entry). The loader flips `ready` after policy load.
struct gs_config {
    __u8 ready;          // 0 until maps populated; hooks no-op while 0
    __u8 enforce_fs;     // block filesystem violations
    __u8 enforce_mem;    // block ptrace / dev-mem / module-load
    __u8 enforce_priv;   // block dangerous caps / mounts (off by default)
    __u8 log_only;       // 1 = log but never return -EPERM (dry run)
};

struct {
    __uint(type, BPF_MAP_TYPE_ARRAY);
    __type(key, __u32);
    __type(value, struct gs_config);
    __uint(max_entries, 1);
} runtime_cfg SEC(".maps");

// Reconstruction context. Lives on the STACK (bpf_loop() requires its callback
// context to be PTR_TO_STACK, not a map value). Sized to fit the 512-byte BPF
// stack: 3 ptrs (24) + stack[16] (128) + 3 u32/u8 fields (12) + out[128] = 292.
struct recon_ctx {
    // walk state (phase 1)
    struct dentry *d;
    struct mount *mnt;
    struct dentry *mnt_root;
    struct dentry *stack[MAX_DENTRY_DEPTH];
    __u32 n;
    __u32 off;         // emit offset (phase 2)
    __u8 done;
    __u8 _pad[3];
    // output path
    __u8 out[MAX_PATH_LEN];
};

// ===================================================================
// SMALL HELPERS
// ===================================================================

static __always_inline void bump(enum stat_counter c)
{
    __u32 k = c;
    __u64 *v = bpf_map_lookup_elem(&stats, &k);
    if (v)
        __sync_fetch_and_add(v, 1);
}

static __always_inline struct gs_config *get_config(void)
{
    __u32 k = 0;
    return bpf_map_lookup_elem(&runtime_cfg, &k);
}

// Returns the acting process tag (0 if untagged / EXEMPT-not-agent).
static __always_inline __u8 current_tag(void)
{
    __u32 tgid = bpf_get_current_pid_tgid() >> 32;
    struct proc_tag *pt = bpf_map_lookup_elem(&agent_pids, &tgid);
    if (!pt)
        return 0;
    return pt->tag;
}

static __always_inline bool current_is_agent(void)
{
    return current_tag() == TAG_AGENT;
}

// ===================================================================
// PATH RECONSTRUCTION
// ===================================================================

// Path reconstruction uses bpf_loop() (kernel >= 5.17) so the verifier costs
// each walk O(1) instead of unrolling 16*64 per-byte iterations (which blew the
// 1M-insn limit). The two callbacks operate on a per-CPU recon_ctx (a bounded
// PTR_TO_MAP_VALUE), never on variable-offset stack slots.

// Phase 1: collect dentry components leaf..root, crossing mount points.
static long collect_cb(__u32 i, void *c)
{
    struct recon_ctx *ctx = c;
    if (ctx->done)
        return 1;

    // Load stored kernel pointers into LOCAL typed vars before any
    // BPF_CORE_READ. Reading through a map-value field (ctx->mnt) makes CO-RE
    // latch the relocation onto recon_ctx (no kernel BTF target) -> -EINVAL.
    struct dentry *d = ctx->d;
    struct mount *m = ctx->mnt;
    struct dentry *mnt_root = ctx->mnt_root;

    struct dentry *parent = BPF_CORE_READ(d, d_parent);

    if (d == mnt_root) {
        struct mount *pmnt = BPF_CORE_READ(m, mnt_parent);
        if (m == pmnt) {                     // global root
            ctx->done = 1;
            return 1;
        }
        ctx->d = BPF_CORE_READ(m, mnt_mountpoint);
        ctx->mnt = pmnt;
        ctx->mnt_root = BPF_CORE_READ(pmnt, mnt.mnt_root);
        return 0;                            // re-test mountpoint vs new root
    }
    if (d == parent) {                       // fs root without a mount parent
        ctx->done = 1;
        return 1;
    }

    __u32 n = ctx->n;
    if (n >= MAX_DENTRY_DEPTH) {
        bump(STAT_PATH_TRUNC);
        ctx->done = 1;
        return 1;
    }
    ctx->stack[n & (MAX_DENTRY_DEPTH - 1)] = d;
    ctx->n = n + 1;
    ctx->d = parent;
    return 0;
}

// Phase 2: emit root..leaf as "/component" segments into ctx->out (forward,
// monotonically increasing offset -> no variable-offset stack access).
static long emit_cb(__u32 k, void *c)
{
    struct recon_ctx *ctx = c;
    if (k >= ctx->n)
        return 1;

    __u32 idx = ctx->n - 1 - k;
    struct dentry *cd = ctx->stack[idx & (MAX_DENTRY_DEPTH - 1)];
    __u32 nlen = BPF_CORE_READ(cd, d_name.len);
    const unsigned char *nm = BPF_CORE_READ(cd, d_name.name);

    __u32 off = ctx->off;
    if (off < MAX_PATH_LEN - 1) {
        ctx->out[off] = '/';
        off++;
    }
    if (off < MAX_PATH_LEN - 1) {
        __u32 rem = MAX_PATH_LEN - 1 - off;  // >= 1 here
        if (nlen > rem)
            nlen = rem;
        if (nlen > MAX_COMPONENT_LEN)
            nlen = MAX_COMPONENT_LEN;
        if (nlen > 0)
            bpf_probe_read_kernel(&ctx->out[off], nlen, nm);
        off += nlen;
    }
    ctx->off = off;
    return 0;
}

// Mount-aware absolute path reconstruction into ctx->out. Returns byte length
// of the NUL-terminated C-string. `ctx` is a caller-owned STACK recon_ctx.
static __always_inline __u32 reconstruct_path(struct dentry *dentry,
                                              struct vfsmount *vfsmnt,
                                              struct recon_ctx *ctx)
{
    // BPF_CORE_READ through a LOCAL typed pointer, never through ctx->mnt (a
    // map-value field), so CO-RE relocates against struct mount, not recon_ctx.
    struct mount *m = container_of(vfsmnt, struct mount, mnt);
    ctx->d = dentry;
    ctx->mnt = m;
    ctx->mnt_root = BPF_CORE_READ(m, mnt.mnt_root);
    ctx->n = 0;
    ctx->off = 0;
    ctx->done = 0;

    bpf_loop(MAX_DENTRY_DEPTH, collect_cb, ctx, 0);
    bpf_loop(MAX_DENTRY_DEPTH, emit_cb, ctx, 0);

    __u32 off = ctx->off;
    if (off == 0) {                          // path was the root itself
        ctx->out[0] = '/';
        off = 1;
    }
    if (off < MAX_PATH_LEN)
        ctx->out[off] = '\0';
    ctx->off = off;
    return off;
}

// LPM lookup + boundary check. Protected prefixes are stored WITHOUT a trailing
// slash; a path is protected iff a stored prefix P matches AND path[len(P)] is
// either '/' (subtree) or end-of-string (the protected dir itself). This
// rejects sibling false positives (e.g. "/etcfoo" vs prefix "/etc").
// __noinline (bpf2bpf call): keeps the 132-byte LPM key in this function's own
// stack frame instead of inflating every caller hook's frame.
static __noinline bool path_is_protected(__u8 *path, __u32 len)
{
    struct path_lpm_key key;
    __builtin_memset(&key, 0, sizeof(key));

    if (len >= MAX_PATH_LEN)
        len = MAX_PATH_LEN - 1;
    key.prefixlen = len * 8;

    // Single bounded copy (len <= 255 <= sizeof(key.data)) - no loop.
    if (len > 0)
        bpf_probe_read_kernel(key.data, len, path);

    struct path_rule *rule = bpf_map_lookup_elem(&protected_paths, &key);
    if (!rule || rule->action != 1)
        return false;

    __u32 mlen = rule->prefix_len;
    if (mlen >= len)
        return true;                         // exact match (dir itself)
    if (mlen < MAX_PATH_LEN) {
        __u8 c = path[mlen & (MAX_PATH_LEN - 1)];
        if (c == '/' || c == '\0')
            return true;                     // proper subtree
    }
    return false;
}

// ===================================================================
// VIOLATION LOGGING
// ===================================================================

static __always_inline void log_violation(__u8 ev, __u8 tag, __u8 enforced,
                                           const __u8 *path, __u32 plen,
                                           const __u8 *tpath, __u32 tlen,
                                           __u32 target_pid, __u32 aux)
{
    struct violation_event *e = bpf_ringbuf_reserve(&violation_events, sizeof(*e), 0);
    if (!e)
        return;

    __u64 pt = bpf_get_current_pid_tgid();
    __u64 ug = bpf_get_current_uid_gid();

    e->timestamp = bpf_ktime_get_ns();
    e->pid = pt >> 32;
    e->tid = (__u32)pt;
    e->uid = (__u32)ug;
    e->gid = ug >> 32;
    e->target_pid = target_pid;
    e->aux = aux;
    e->event_type = ev;
    e->tag = tag;
    e->enforced = enforced;
    e->_pad = 0;
    bpf_get_current_comm(&e->comm, sizeof(e->comm));

    __builtin_memset(e->path, 0, sizeof(e->path));
    __builtin_memset(e->target_path, 0, sizeof(e->target_path));
    if (path && plen) {
        if (plen >= MAX_PATH_LEN)
            plen = MAX_PATH_LEN - 1;
        bpf_probe_read_kernel(e->path, plen, path);
    }
    if (tpath && tlen) {
        if (tlen >= MAX_PATH_LEN)
            tlen = MAX_PATH_LEN - 1;
        bpf_probe_read_kernel(e->target_path, tlen, tpath);
    }

    bpf_ringbuf_submit(e, 0);
}

// Common decision for a reconstructed-dentry filesystem hook.
// Returns 0 (allow) or -EPERM (block). Only AGENT-tagged subtrees are checked.
static __always_inline int fs_guard_dentry(struct dentry *dentry,
                                           struct vfsmount *vfsmnt,
                                           struct dentry *tdentry,
                                           struct vfsmount *tvfsmnt,
                                           __u8 ev)
{
    struct gs_config *cfg = get_config();
    if (!cfg || !cfg->ready || !cfg->enforce_fs)
        return 0;
    if (!current_is_agent())
        return 0;

    bump(STAT_FS_CHECKS);

    struct recon_ctx rc = {};

    __u32 len = reconstruct_path(dentry, vfsmnt, &rc);
    bool hit = path_is_protected(rc.out, len);

    // Secondary path (rename dst / link dst). Reuse the same ctx after the
    // first check.
    bool thit = false;
    if (!hit && tdentry) {
        __u32 tlen = reconstruct_path(tdentry, tvfsmnt, &rc);
        thit = path_is_protected(rc.out, tlen);
        len = tlen;
    }

    if (hit || thit) {
        __u8 enforced = cfg->log_only ? 0 : 1;
        log_violation(ev, TAG_AGENT, enforced, rc.out, len, 0, 0, 0, 0);
        bump(STAT_FS_BLOCKED);
        if (cfg->log_only)
            return 0;
        return -EPERM;
    }
    return 0;
}

// ===================================================================
// PROCESS-TREE TRACKER (tp_btf)
// ===================================================================

// exec: classify the new exe. exempt-path check first (override), then
// agent-launcher basename. If neither, keep any inherited tag (sticky).
SEC("tp_btf/sched_process_exec")
int BPF_PROG(gs_exec, struct task_struct *p, pid_t old_pid, struct linux_binprm *bprm)
{
    bump(STAT_EXEC_SEEN);

    __u32 tgid = BPF_CORE_READ(p, tgid);
    const char *filename = BPF_CORE_READ(bprm, filename);

    // 1) Operator exempt full-path override. The full exe path is the map key;
    // one helper call fills a zeroed key buffer (no parsing loop).
    char full[MAX_EXE_PATH];
    __builtin_memset(full, 0, sizeof(full));
    if (filename)
        bpf_probe_read_kernel_str(full, sizeof(full), filename);

    __u8 *ex = bpf_map_lookup_elem(&exempt_exes, full);
    if (ex) {
        struct proc_tag t = {};
        t.tag = TAG_EXEMPT;
        t.root_tgid = tgid;
        t.since_ns = bpf_ktime_get_ns();
        bpf_map_update_elem(&agent_pids, &tgid, &t, BPF_ANY);
        return 0;
    }

    // 2) Agent-launcher basename match. Take the basename DIRECTLY from the exe
    // dentry's leaf name (bprm->file->f_path.dentry->d_name) - the kernel
    // already isolated the last component, so there is no string scan and no
    // variable-offset access (which is what blew the verifier's 1M-insn limit).
    struct dentry *ed = BPF_CORE_READ(bprm, file, f_path.dentry);
    const unsigned char *leaf = BPF_CORE_READ(ed, d_name.name);
    char base[MAX_EXE_NAME];
    __builtin_memset(base, 0, sizeof(base));
    if (leaf)
        bpf_probe_read_kernel_str(base, sizeof(base), leaf);

    __u8 *is_agent = bpf_map_lookup_elem(&agent_exe_names, base);
    if (is_agent) {
        struct proc_tag t = {};
        t.tag = TAG_AGENT;
        t.root_tgid = tgid;
        t.since_ns = bpf_ktime_get_ns();
        bpf_map_update_elem(&agent_pids, &tgid, &t, BPF_ANY);
        bump(STAT_AGENT_TAGGED);

        struct exec_event *ee = bpf_ringbuf_reserve(&exec_events, sizeof(*ee), 0);
        if (ee) {
            ee->pid = tgid;
            ee->tag = TAG_AGENT;
            __builtin_memset(ee->filename, 0, sizeof(ee->filename));
            bpf_probe_read_kernel_str(ee->filename, sizeof(ee->filename), filename);
            bpf_ringbuf_submit(ee, 0);
        }
    }
    // else: inherited tag (if any) stays in place -> subtree remains tagged.
    return 0;
}

// fork: child tgid inherits parent's tag.
SEC("tp_btf/sched_process_fork")
int BPF_PROG(gs_fork, struct task_struct *parent, struct task_struct *child)
{
    __u32 ptgid = BPF_CORE_READ(parent, tgid);
    __u32 ctgid = BPF_CORE_READ(child, tgid);
    if (ptgid == ctgid)
        return 0;                            // thread clone: same tgid entry

    struct proc_tag *pt = bpf_map_lookup_elem(&agent_pids, &ptgid);
    if (!pt || !pt->tag)
        return 0;

    struct proc_tag t = {};
    t.tag = pt->tag;
    t.root_tgid = pt->root_tgid;
    t.since_ns = pt->since_ns;
    bpf_map_update_elem(&agent_pids, &ctgid, &t, BPF_ANY);
    bump(STAT_FORK_INHERIT);
    return 0;
}

// exit: drop the tag when the thread-group leader exits (process death).
SEC("tp_btf/sched_process_exit")
int BPF_PROG(gs_exit, struct task_struct *p)
{
    __u32 pid = BPF_CORE_READ(p, pid);
    __u32 tgid = BPF_CORE_READ(p, tgid);
    if (pid == tgid)
        bpf_map_delete_elem(&agent_pids, &tgid);
    return 0;
}

// ===================================================================
// FILESYSTEM ENFORCEMENT (lsm/path_*)
// ===================================================================

SEC("lsm/path_unlink")
int BPF_PROG(gs_path_unlink, const struct path *dir, struct dentry *dentry)
{
    struct vfsmount *mnt = BPF_CORE_READ(dir, mnt);
    return fs_guard_dentry(dentry, mnt, 0, 0, EV_UNLINK);
}

SEC("lsm/path_rmdir")
int BPF_PROG(gs_path_rmdir, const struct path *dir, struct dentry *dentry)
{
    struct vfsmount *mnt = BPF_CORE_READ(dir, mnt);
    return fs_guard_dentry(dentry, mnt, 0, 0, EV_RMDIR);
}

SEC("lsm/path_mkdir")
int BPF_PROG(gs_path_mkdir, const struct path *dir, struct dentry *dentry, umode_t mode)
{
    struct vfsmount *mnt = BPF_CORE_READ(dir, mnt);
    return fs_guard_dentry(dentry, mnt, 0, 0, EV_MKDIR);
}

SEC("lsm/path_symlink")
int BPF_PROG(gs_path_symlink, const struct path *dir, struct dentry *dentry, const char *old_name)
{
    struct vfsmount *mnt = BPF_CORE_READ(dir, mnt);
    return fs_guard_dentry(dentry, mnt, 0, 0, EV_SYMLINK);
}

SEC("lsm/path_link")
int BPF_PROG(gs_path_link, struct dentry *old_dentry, const struct path *new_dir, struct dentry *new_dentry)
{
    // Hardlinks cannot cross mounts: source and dest share new_dir's mount.
    struct vfsmount *mnt = BPF_CORE_READ(new_dir, mnt);
    return fs_guard_dentry(old_dentry, mnt, new_dentry, mnt, EV_LINK);
}

SEC("lsm/path_rename")
int BPF_PROG(gs_path_rename, const struct path *old_dir, struct dentry *old_dentry,
             const struct path *new_dir, struct dentry *new_dentry)
{
    struct vfsmount *omnt = BPF_CORE_READ(old_dir, mnt);
    struct vfsmount *nmnt = BPF_CORE_READ(new_dir, mnt);
    return fs_guard_dentry(old_dentry, omnt, new_dentry, nmnt, EV_RENAME);
}

SEC("lsm/path_chmod")
int BPF_PROG(gs_path_chmod, const struct path *path, umode_t mode)
{
    struct vfsmount *mnt = BPF_CORE_READ(path, mnt);
    struct dentry *dentry = BPF_CORE_READ(path, dentry);
    return fs_guard_dentry(dentry, mnt, 0, 0, EV_CHMOD);
}

// path_truncate: bpf_d_path IS allowed here -> canonical path.
SEC("lsm/path_truncate")
int BPF_PROG(gs_path_truncate, const struct path *path)
{
    struct gs_config *cfg = get_config();
    if (!cfg || !cfg->ready || !cfg->enforce_fs)
        return 0;
    if (!current_is_agent())
        return 0;

    __u8 buf[MAX_PATH_LEN];
    long r = bpf_d_path((struct path *)path, (char *)buf, MAX_PATH_LEN);
    if (r <= 0)
        return 0;
    __u32 len = (__u32)r - 1;                // r includes trailing NUL
    if (path_is_protected(buf, len)) {
        __u8 enforced = cfg->log_only ? 0 : 1;
        log_violation(EV_TRUNCATE, TAG_AGENT, enforced, buf, len, 0, 0, 0, 0);
        bump(STAT_FS_BLOCKED);
        if (cfg->log_only)
            return 0;
        return -EPERM;
    }
    return 0;
}

// ===================================================================
// file_open: (a) block agent write/truncate opens on protected paths using the
// canonical bpf_d_path; (b) /dev/mem family protection (memory domain).
// ===================================================================

SEC("lsm/file_open")
int BPF_PROG(gs_file_open, struct file *file)
{
    struct gs_config *cfg = get_config();
    if (!cfg || !cfg->ready)
        return 0;

    __u8 tag = current_tag();
    bool agent = (tag == TAG_AGENT);

    // ---- (b) /dev/mem, /dev/kmem, /dev/port ----
    if (cfg->enforce_mem && agent) {
        struct inode *inode = BPF_CORE_READ(file, f_inode);
        umode_t imode = BPF_CORE_READ(inode, i_mode);
        if (S_ISCHR(imode)) {
            dev_t dev = BPF_CORE_READ(inode, i_rdev);
            unsigned int maj = GS_MAJOR(dev);
            unsigned int minr = GS_MINOR(dev);
            if (maj == MEM_MAJOR &&
                (minr == MEM_MINOR || minr == KMEM_MINOR || minr == PORT_MINOR)) {
                log_violation(EV_DEV_MEM, tag, cfg->log_only ? 0 : 1, 0, 0, 0, 0, 0, minr);
                bump(STAT_MEM_BLOCKED);
                if (!cfg->log_only)
                    return -EPERM;
            }
        }
    }

    // ---- (a) write/truncate open on a protected path ----
    if (cfg->enforce_fs && agent) {
        unsigned int flags = BPF_CORE_READ(file, f_flags);
        bool writing = (flags & O_ACCMODE) == O_WRONLY ||
                       (flags & O_ACCMODE) == O_RDWR ||
                       (flags & O_TRUNC) || (flags & O_CREAT);
        if (writing) {
            __u8 buf[MAX_PATH_LEN];
            long r = bpf_d_path(&file->f_path, (char *)buf, MAX_PATH_LEN);
            if (r > 0) {
                __u32 len = (__u32)r - 1;
                if (path_is_protected(buf, len)) {
                    log_violation(EV_OPEN_WRITE, tag, cfg->log_only ? 0 : 1,
                                  buf, len, 0, 0, 0, flags);
                    bump(STAT_FS_BLOCKED);
                    if (!cfg->log_only)
                        return -EACCES;
                }
            }
        }
    }
    return 0;
}

// ===================================================================
// MEMORY / PRIVILEGE ENFORCEMENT
// ===================================================================

// ptrace: an AGENT-tagged process may not attach to any task (code injection).
SEC("lsm/ptrace_access_check")
int BPF_PROG(gs_ptrace, struct task_struct *child, unsigned int mode)
{
    struct gs_config *cfg = get_config();
    if (!cfg || !cfg->ready || !cfg->enforce_mem)
        return 0;
    __u8 tag = current_tag();
    if (tag != TAG_AGENT)
        return 0;
    __u32 target = BPF_CORE_READ(child, pid);
    log_violation(EV_PTRACE, tag, cfg->log_only ? 0 : 1, 0, 0, 0, 0, target, 0);
    bump(STAT_MEM_BLOCKED);
    return cfg->log_only ? 0 : -EPERM;
}

// kernel module load via kernel_read_file(READING_MODULE).
SEC("lsm/kernel_read_file")
int BPF_PROG(gs_kernel_read_file, struct file *file, enum kernel_read_file_id id, bool contents)
{
    struct gs_config *cfg = get_config();
    if (!cfg || !cfg->ready || !cfg->enforce_mem)
        return 0;
    if (id != READING_MODULE)
        return 0;
    __u8 tag = current_tag();
    if (tag != TAG_AGENT)
        return 0;
    log_violation(EV_MODULE_LOAD, tag, cfg->log_only ? 0 : 1, 0, 0, 0, 0, 0, 0);
    bump(STAT_MEM_BLOCKED);
    return cfg->log_only ? 0 : -EACCES;
}

// dangerous capabilities. enforce_priv defaults OFF (audit-only) to avoid
// bricking benign cap checks; when on, deny for AGENT subtrees.
SEC("lsm/capable")
int BPF_PROG(gs_capable, const struct cred *cred, struct user_namespace *ns,
             int cap, unsigned int opts)
{
    struct gs_config *cfg = get_config();
    if (!cfg || !cfg->ready)
        return 0;
    __u8 tag = current_tag();
    if (tag != TAG_AGENT)
        return 0;

    bool dangerous = false;
    switch (cap) {
    case CAP_SYS_ADMIN:
    case CAP_SYS_MODULE:
    case CAP_SYS_RAWIO:
    case CAP_SYS_PTRACE:
    case CAP_SYS_BOOT:
    case CAP_DAC_OVERRIDE:
    case CAP_DAC_READ_SEARCH:
        dangerous = true;
        break;
    }
    if (!dangerous)
        return 0;

    if (!cfg->enforce_priv) {
        // audit-only
        log_violation(EV_CAPABILITY, tag, 0, 0, 0, 0, 0, 0, (__u32)cap);
        return 0;
    }
    log_violation(EV_CAPABILITY, tag, cfg->log_only ? 0 : 1, 0, 0, 0, 0, 0, (__u32)cap);
    bump(STAT_MEM_BLOCKED);
    return cfg->log_only ? 0 : -EPERM;
}

// mount operations (container-escape hardening). enforce_priv gated.
SEC("lsm/sb_mount")
int BPF_PROG(gs_sb_mount, const char *dev_name, const struct path *path,
             const char *type, unsigned long flags, void *data)
{
    struct gs_config *cfg = get_config();
    if (!cfg || !cfg->ready || !cfg->enforce_priv)
        return 0;
    __u8 tag = current_tag();
    if (tag != TAG_AGENT)
        return 0;
    log_violation(EV_MOUNT, tag, cfg->log_only ? 0 : 1, 0, 0, 0, 0, 0, 0);
    bump(STAT_MEM_BLOCKED);
    return cfg->log_only ? 0 : -EPERM;
}

SEC("lsm/move_mount")
int BPF_PROG(gs_move_mount, const struct path *from_path, const struct path *to_path)
{
    struct gs_config *cfg = get_config();
    if (!cfg || !cfg->ready || !cfg->enforce_priv)
        return 0;
    __u8 tag = current_tag();
    if (tag != TAG_AGENT)
        return 0;
    log_violation(EV_MOUNT, tag, cfg->log_only ? 0 : 1, 0, 0, 0, 0, 0, 1);
    bump(STAT_MEM_BLOCKED);
    return cfg->log_only ? 0 : -EPERM;
}
