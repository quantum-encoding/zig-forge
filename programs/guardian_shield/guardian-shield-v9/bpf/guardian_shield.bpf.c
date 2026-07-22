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
#include <bpf/bpf_endian.h>

char LICENSE[] SEC("license") = "GPL";

// ===================================================================
// CONSTANTS (vmlinux.h does not provide UAPI constants)
// ===================================================================

// MAX_PATH_LEN is 128 (power of two - required for the & (MAX_PATH_LEN-1) mask
// on variable-offset writes into the per-CPU recon_buf). A protected prefix
// always sits at the START of the reconstructed path, so 128 bytes is more than
// enough to hold prefix + boundary char for matching.
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

// Socket address families (not in vmlinux.h)
#define AF_INET   2
#define AF_INET6 10

// Dangerous capabilities (uapi/linux/capability.h)
#define CAP_DAC_OVERRIDE     1
#define CAP_DAC_READ_SEARCH  2
#define CAP_SETUID           7
#define CAP_SYS_MODULE      16
#define CAP_SYS_RAWIO       17
#define CAP_SYS_PTRACE      19
#define CAP_SYS_ADMIN       21
#define CAP_SYS_BOOT        22
#define CAP_BPF             39   // load BPF progs/maps (kernel >= 5.8)

// READING_MODULE comes from enum kernel_read_file_id in vmlinux.h (== 2).

// container_of (struct mount <- struct vfsmount) is provided by bpf_helpers.h.
// The offset is taken from the host's own vmlinux.h (generated from THIS
// kernel's BTF), so it is exact for this kernel. Field READS below still go
// through CO-RE relocations.

// ===================================================================
// PROCESS-TREE TAGGING
// ===================================================================

#define TAG_AGENT   1   // AI-agent subtree (restricted in agent-containment mode)
#define TAG_EXEMPT  2   // explicitly exempt (overrides inherited AGENT)
#define TAG_TRUSTED 3   // fully trusted (loader + allowlisted tools). The ONLY
                        // tag NOT restricted under hardening_mode; may call bpf().
#define TAG_TAINTED 4   // build-tool subtree (npm/pip/cargo/... and everything it
                        // spawns). Denied READ of the credential AssetMap - the
                        // supply-chain credential-harvest block. Inherited+sticky.

struct proc_tag {
    __u8  tag;         // TAG_AGENT | TAG_EXEMPT | TAG_TRUSTED | TAG_TAINTED
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
    EV_CREATE = 10,    // new-file creation (path_mknod)
    EV_CRED_READ = 11, // tainted/agent open of a credential AssetMap path
    EV_TAINTED_CONNECT = 12, // tainted/agent connect() to a non-allowlisted dest
    EV_PTRACE = 20,
    EV_DEV_MEM = 21,
    EV_MODULE_LOAD = 22,
    EV_CAPABILITY = 23,
    EV_MOUNT = 24,
    EV_BPF = 25,       // bpf() syscall blocked (anti-tamper, hardening mode)
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
    __u8  _pad;
    // Bitmask of the operations this prefix guards, bit (EV_x - 1). It fits in
    // the old padding, so the map layout and size are unchanged. OPS_ALL is the
    // pre-mask behaviour (guard everything); a narrower mask is the "working
    // directory" posture (deny destroy, allow create/write); 0 is an explicit
    // FREE hole punched under a broader guarded prefix.
    __u16 ops;
};

#define OPS_ALL 0xFFFF

// EV_* (1..10) -> op bit. Every filesystem hook already passes its EV_ code to
// fs_guard_dentry, so the mask is DERIVED here rather than plumbed through all
// nine hook signatures.
static __always_inline __u16 ev_op_bit(__u8 ev)
{
    if (ev == 0 || ev > 16)
        return 0;
    return (__u16)1 << (ev - 1);
}

struct {
    __uint(type, BPF_MAP_TYPE_LPM_TRIE);
    __type(key, struct path_lpm_key);
    __type(value, struct path_rule);
    __uint(max_entries, MAX_PROTECTED_PATHS);
    __uint(map_flags, BPF_F_NO_PREALLOC);   // required for LPM_TRIE
} protected_paths SEC(".maps");

// Credential AssetMap (crown jewels: ~/.ssh, ~/.aws, gcloud/gh tokens, ...). A
// SEPARATE trie from protected_paths - it gates READS (not just writes) and only
// for TAINTED/AGENT subtrees, independent of agent/hardening posture.
struct {
    __uint(type, BPF_MAP_TYPE_LPM_TRIE);
    __type(key, struct path_lpm_key);
    __type(value, struct path_rule);
    __uint(max_entries, MAX_PROTECTED_PATHS);
    __uint(map_flags, BPF_F_NO_PREALLOC);
} credential_paths SEC(".maps");

// Egress allowlist (IPv4). LPM trie keyed on {prefixlen_bits, 4 addr bytes in
// NETWORK byte order} - a tainted/agent connect() to a dest matching a stored
// CIDR is allowed; anything else (public C2 / webhook) is denied. The loader
// seeds the private/loopback/link-local/CGNAT ranges by default + operator CIDRs.
struct egress_lpm_key {
    __u32 prefixlen;   // bits
    __u8  addr[4];     // network byte order (MSB first)
};

struct {
    __uint(type, BPF_MAP_TYPE_LPM_TRIE);
    __type(key, struct egress_lpm_key);
    __type(value, __u8);
    __uint(max_entries, 512);
    __uint(map_flags, BPF_F_NO_PREALLOC);
} egress_allow SEC(".maps");

// Agent-launcher basenames (exec classifier). Populated from config.
struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __type(key, char[MAX_EXE_NAME]);
    __type(value, __u8);
    __uint(max_entries, 512);
} agent_exe_names SEC(".maps");

// Regenerable-output directory basenames (node_modules, .astro, .vite, ...).
// If ANY component of a path is one of these, destructive ops are allowed even
// inside a guarded tree. This is COMPONENT matching, not prefix matching: the
// LPM trie can only express a literal prefix, so per-site holes would have to be
// enumerated and re-enumerated whenever the tree changes. Matching the basename
// expresses the actual property - "this is build output, it is reproducible" -
// at any depth, including directories that do not exist yet.
struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __type(key, char[MAX_EXE_NAME]);
    __type(value, __u8);
    __uint(max_entries, 64);
} free_basenames SEC(".maps");

// Build-tool launcher basenames (npm/pip/cargo/...). exec of one taints the
// whole install subtree (TAG_TAINTED, inherited + sticky).
struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __type(key, char[MAX_EXE_NAME]);
    __type(value, __u8);
    __uint(max_entries, 512);
} build_exe_names SEC(".maps");

// Operator exempt exe FULL PATHS. exec of one of these tags the pid EXEMPT
// (overrides inherited AGENT). Keyed on path, not comm.
struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __type(key, char[MAX_EXE_PATH]);
    __type(value, __u8);
    __uint(max_entries, 512);
} exempt_exes SEC(".maps");

// Trusted exe FULL PATHS. exec of one of these tags the pid TRUSTED - the only
// tag not restricted under hardening_mode, and the only one allowed to call
// bpf() while the anti-tamper hook is active. MUST include the loader's own exe
// so it can load/pin/unpin. Keyed on path (not comm -> not prctl-forgeable).
struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __type(key, char[MAX_EXE_PATH]);
    __type(value, __u8);
    __uint(max_entries, 512);
} trusted_exes SEC(".maps");

// Trusted exe INODE identities {ino, dev}. A relative-path exec of the trusted
// loader (e.g. `./guardian_shield_loader --unpin`) yields a relative
// bprm->filename that does NOT match the absolute trusted_exes entry, which
// would leave the operator's own teardown un-trusted (and blocked by the
// anti-tamper hooks). Matching the exe's inode makes trust independent of the
// invocation path, and cannot be forged with a string.
struct exe_id {
    __u64 ino;
    __u32 dev;
    __u32 _pad;
};

struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __type(key, struct exe_id);
    __type(value, __u8);
    __uint(max_entries, 512);
} trusted_inodes SEC(".maps");

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
    STAT_FREE_ALLOW = 7,   // op allowed because a path component was a free basename
};

// Runtime config (single entry). The loader flips `ready` after policy load.
struct gs_config {
    __u8 ready;          // 0 until maps populated; hooks no-op while 0
    __u8 enforce_fs;     // block filesystem violations
    __u8 enforce_mem;    // block ptrace / dev-mem / module-load
    __u8 enforce_priv;   // block dangerous caps / mounts (off by default)
    __u8 log_only;       // 1 = log but never return -EPERM (dry run)
    __u8 hardening_mode; // 0 = agent-containment (default); 1 = default-deny for
                         // everyone except TAG_TRUSTED, + self-protection hooks
    __u8 enforce_cred_read; // 1 = deny TAINTED/AGENT reads of credential_paths
                            // (supply-chain harvest block; on by default)
    __u8 enforce_egress; // 1 = deny TAINTED/AGENT connect() to non-allowlisted
                         // public dests (exfil block; on by default)
};

struct {
    __uint(type, BPF_MAP_TYPE_ARRAY);
    __type(key, __u32);
    __type(value, struct gs_config);
    __uint(max_entries, 1);
} runtime_cfg SEC(".maps");

// Path reconstruction must satisfy two verifier rules at once:
//   - bpf_loop()'s callback context MUST be PTR_TO_STACK, and
//   - variable-offset byte writes are only legal into a PTR_TO_MAP_VALUE.
// So we split the two: a small fixed-layout control struct on the STACK (the
// bpf_loop ctx, only constant-offset field accesses), and a per-CPU MAP buffer
// that holds the dentry pointer stack + the assembled path bytes (all the
// variable-offset, masked writes target this map value).

// data[] is OVER-SIZED by one max component so a masked write at index <=127 of
// up to MAX_COMPONENT_LEN bytes (127 + 64 = 191) is provably in-bounds from two
// INDEPENDENT bounds (masked index <=127, clamped length <=64) without the
// verifier needing to prove index+len <= logical length. Logical path length is
// still capped at MAX_PATH_LEN-1 for matching; the tail is slack.
#define RECON_DATA_LEN (MAX_PATH_LEN + MAX_COMPONENT_LEN)

struct recon_buf {
    __u64 dstack[MAX_DENTRY_DEPTH];   // collected dentry pointers (leaf..root)
    __u8  data[RECON_DATA_LEN];       // assembled absolute path (+slack tail)
    __u8  has_free;                   // some component matched free_basenames
    __u8  _pad[7];
};

struct {
    __uint(type, BPF_MAP_TYPE_PERCPU_ARRAY);
    __type(key, __u32);
    __type(value, struct recon_buf);
    __uint(max_entries, 1);
} recon_buf_map SEC(".maps");

static __always_inline struct recon_buf *get_recon_buf(void)
{
    __u32 z = 0;
    return bpf_map_lookup_elem(&recon_buf_map, &z);
}

// Small STACK control struct = the bpf_loop context. Kernel pointers are stored
// as __u64 (fixed-offset scalars) and cast back to typed locals in the callback.
struct walk_ctx {
    __u64 d;           // current dentry
    __u64 mnt;         // current struct mount
    __u64 mnt_root;    // current mount's root dentry
    __u32 n;           // components collected
    __u32 off;         // emit offset
    __u8  done;
    __u8  has_free;    // a component matched free_basenames (regenerable dir)
    __u8  _pad[2];
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

// Core policy posture. In agent-containment mode (default) only AI-agent
// subtrees are restricted; in hardening mode EVERYONE except TAG_TRUSTED is
// restricted (default-deny against human attackers / dropped binaries too).
static __always_inline bool is_restricted(struct gs_config *cfg, __u8 tag)
{
    if (cfg->hardening_mode)
        return tag != TAG_TRUSTED;
    return tag == TAG_AGENT;
}

// True when a self-protection hook (bpf/module/mount/dev-mem) should block this
// caller purely because hardening mode is on and it is not trusted.
static __always_inline bool hardening_block(struct gs_config *cfg, __u8 tag)
{
    return cfg->hardening_mode && tag != TAG_TRUSTED;
}

// ===================================================================
// PATH RECONSTRUCTION
// ===================================================================

// Path reconstruction uses bpf_loop() (kernel >= 5.17) so the verifier costs
// each walk O(1). The bpf_loop context is a small STACK walk_ctx; all the
// variable-offset writes go into the per-CPU recon_buf MAP value.

// Phase 1: collect dentry components leaf..root, crossing mount points.
static long collect_cb(__u32 i, void *c)
{
    struct walk_ctx *ctx = c;
    if (ctx->done)
        return 1;

    struct recon_buf *buf = get_recon_buf();
    if (!buf) {
        ctx->done = 1;
        return 1;
    }

    // Cast stored __u64 back to typed locals; BPF_CORE_READ goes through these
    // locals (real kernel types), never through a struct field, so CO-RE
    // relocates correctly.
    struct dentry *d = (struct dentry *)ctx->d;
    struct mount *m = (struct mount *)ctx->mnt;
    struct dentry *mnt_root = (struct dentry *)ctx->mnt_root;

    struct dentry *parent = BPF_CORE_READ(d, d_parent);

    if (d == mnt_root) {
        struct mount *pmnt = BPF_CORE_READ(m, mnt_parent);
        if (m == pmnt) {                     // global root
            ctx->done = 1;
            return 1;
        }
        ctx->d = (__u64)(long)BPF_CORE_READ(m, mnt_mountpoint);
        ctx->mnt = (__u64)(long)pmnt;
        ctx->mnt_root = (__u64)(long)BPF_CORE_READ(pmnt, mnt.mnt_root);
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
    buf->dstack[n & (MAX_DENTRY_DEPTH - 1)] = (__u64)(long)d;  // var-off write into MAP value: OK
    ctx->n = n + 1;
    ctx->d = (__u64)(long)parent;
    return 0;
}

// Phase 2: emit root..leaf as "/component" segments into recon_buf->data.
static long emit_cb(__u32 k, void *c)
{
    struct walk_ctx *ctx = c;
    if (k >= ctx->n)
        return 1;

    struct recon_buf *buf = get_recon_buf();
    if (!buf)
        return 1;

    __u32 sidx = ctx->n - 1 - k;
    struct dentry *cd = (struct dentry *)buf->dstack[sidx & (MAX_DENTRY_DEPTH - 1)];
    __u32 nlen = BPF_CORE_READ(cd, d_name.len);
    const unsigned char *nm = BPF_CORE_READ(cd, d_name.name);

    __u32 off = ctx->off;
    if (off >= MAX_PATH_LEN - 1)             // logical buffer full - stop
        return 1;

    // '/' separator. idx in [0,127] (mask) < RECON_DATA_LEN (192).
    __u32 idx = off & (MAX_PATH_LEN - 1);
    buf->data[idx] = '/';
    off++;

    // Is this component a regenerable-output directory? Checked HERE because
    // emit_cb already holds the component name - re-parsing the assembled path
    // later would mean a second variable-offset scan, which is exactly the
    // shape that blows up the verifier. d_name.name is NUL-terminated, so the
    // fixed-size _str read is bounded and verifier-friendly.
    if (!ctx->has_free && nlen > 0) {
        char cname[MAX_EXE_NAME] = {};
        long r = bpf_probe_read_kernel_str(cname, sizeof(cname), nm);
        if (r > 0 && bpf_map_lookup_elem(&free_basenames, cname))
            ctx->has_free = 1;
    }

    // Component copy. Two INDEPENDENT bounds make the access provably in-range:
    //   didx = off & 127  -> [0,127]     and     nlen <= MAX_COMPONENT_LEN (64)
    //   didx + nlen <= 127 + 64 = 191 < RECON_DATA_LEN (192).
    if (nlen > MAX_COMPONENT_LEN)
        nlen = MAX_COMPONENT_LEN;
    __u32 didx = off & (MAX_PATH_LEN - 1);
    if (nlen > 0)
        bpf_probe_read_kernel(&buf->data[didx], nlen, nm);
    off += nlen;

    if (off > MAX_PATH_LEN - 1)              // cap LOGICAL length (tail is slack)
        off = MAX_PATH_LEN - 1;
    ctx->off = off;
    return 0;
}

// Mount-aware absolute path reconstruction. Assembles the path into the per-CPU
// recon_buf and returns {buf via *out_buf, length}. The caller must consume the
// buffer before the next reconstruct_path() call (they share the per-CPU slot).
static __always_inline __u32 reconstruct_path(struct dentry *dentry,
                                              struct vfsmount *vfsmnt,
                                              struct recon_buf **out_buf)
{
    struct walk_ctx ctx = {};
    // BPF_CORE_READ through a LOCAL typed pointer (relocates against struct mount).
    struct mount *m = container_of(vfsmnt, struct mount, mnt);
    ctx.d = (__u64)(long)dentry;
    ctx.mnt = (__u64)(long)m;
    ctx.mnt_root = (__u64)(long)BPF_CORE_READ(m, mnt.mnt_root);

    bpf_loop(MAX_DENTRY_DEPTH, collect_cb, &ctx, 0);
    bpf_loop(MAX_DENTRY_DEPTH, emit_cb, &ctx, 0);

    struct recon_buf *buf = get_recon_buf();
    if (!buf)
        return 0;

    __u32 off = ctx.off;
    if (off == 0) {                          // path was the root itself
        buf->data[0] = '/';
        off = 1;
    }
    buf->data[off & (MAX_PATH_LEN - 1)] = '\0';
    buf->has_free = ctx.has_free;
    *out_buf = buf;
    return off;
}

// LPM lookup + boundary check. Protected prefixes are stored WITHOUT a trailing
// slash; a path is protected iff a stored prefix P matches AND path[len(P)] is
// either '/' (subtree) or end-of-string (the protected dir itself). This
// rejects sibling false positives (e.g. "/etcfoo" vs prefix "/etc").
// __noinline (bpf2bpf call): keeps the 132-byte LPM key in this function's own
// stack frame instead of inflating every caller hook's frame.
// `op` is the ev_op_bit() of the operation being attempted, or 0 to ask "is this
// path guarded at all" regardless of operation.
//
// NOTE the override semantics: the LPM trie returns the LONGEST matching prefix,
// and if that entry does not guard `op` we return false WITHOUT falling back to a
// shorter prefix. That is deliberate - it is what lets a specific subtree punch a
// hole in a broader guard (e.g. ${HOME} blocks unlink/rename, but
// ${HOME}/work/scratch sets ops=0 and is freely destroyable).
static __noinline bool path_is_protected(__u8 *path, __u32 len, __u16 op)
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
    if (op && !(rule->ops & op))
        return false;                        // guarded, but not for THIS op

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

// Same longest-prefix + boundary check against the credential AssetMap trie.
// Separate bpf2bpf function because the map reference must be known to the
// verifier at the lookup site (a map can't be passed as a generic pointer).
static __noinline bool cred_is_protected(__u8 *path, __u32 len)
{
    struct path_lpm_key key;
    __builtin_memset(&key, 0, sizeof(key));

    if (len >= MAX_PATH_LEN)
        len = MAX_PATH_LEN - 1;
    key.prefixlen = len * 8;
    if (len > 0)
        bpf_probe_read_kernel(key.data, len, path);

    struct path_rule *rule = bpf_map_lookup_elem(&credential_paths, &key);
    if (!rule || rule->action != 1)
        return false;

    __u32 mlen = rule->prefix_len;
    if (mlen >= len)
        return true;
    if (mlen < MAX_PATH_LEN) {
        __u8 c = path[mlen & (MAX_PATH_LEN - 1)];
        if (c == '/' || c == '\0')
            return true;
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
// Returns 0 (allow) or -EPERM (block). Restricted set depends on posture:
// agent-containment => AI-agent subtrees; hardening => everyone but TAG_TRUSTED.
static __always_inline int fs_guard_dentry(struct dentry *dentry,
                                           struct vfsmount *vfsmnt,
                                           struct dentry *tdentry,
                                           struct vfsmount *tvfsmnt,
                                           __u8 ev)
{
    struct gs_config *cfg = get_config();
    if (!cfg || !cfg->ready || !cfg->enforce_fs)
        return 0;
    __u8 tag = current_tag();
    if (!is_restricted(cfg, tag))
        return 0;

    bump(STAT_FS_CHECKS);

    struct recon_buf *buf = 0;
    __u32 len = reconstruct_path(dentry, vfsmnt, &buf);
    if (!buf)
        return 0;
    bool hit = path_is_protected(buf->data, len, ev_op_bit(ev));
    // Regenerable output (node_modules/.astro/...) inside a guarded tree: allow,
    // but COUNT it. A hole you cannot observe is indistinguishable from having
    // no guard at all - and this is the counter that later justifies (or
    // refutes) widening the basename set. Counted rather than logged on purpose:
    // a single `npm ci` touches thousands of files and would drown the feed.
    if (hit && buf->has_free) {
        bump(STAT_FREE_ALLOW);
        hit = false;
    }

    // Secondary path (rename dst / link dst). path_is_protected copies out of
    // the buffer immediately, so it is safe to reuse the per-CPU slot here.
    bool thit = false;
    if (!hit && tdentry) {
        struct recon_buf *tbuf = 0;
        __u32 tlen = reconstruct_path(tdentry, tvfsmnt, &tbuf);
        if (tbuf) {
            thit = path_is_protected(tbuf->data, tlen, ev_op_bit(ev));
            if (thit && tbuf->has_free) {
                bump(STAT_FREE_ALLOW);
                thit = false;
            }
            len = tlen;
            buf = tbuf;
        }
    }

    if (hit || thit) {
        __u8 enforced = cfg->log_only ? 0 : 1;
        log_violation(ev, tag, enforced, buf->data, len, 0, 0, 0, 0);
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

    // The full exe path is the key for the trusted / exempt allowlists; one
    // helper call fills a zeroed key buffer (no parsing loop).
    char full[MAX_EXE_PATH];
    __builtin_memset(full, 0, sizeof(full));
    if (filename)
        bpf_probe_read_kernel_str(full, sizeof(full), filename);

    // 1a) Trusted full-path override (highest privilege; the only tag not
    // restricted under hardening_mode, and the only one allowed to call bpf()).
    __u8 *tr = bpf_map_lookup_elem(&trusted_exes, full);
    // 1b) ...OR trusted by exe inode identity, so the loader trusts itself even
    // when invoked by a relative path (teardown must not depend on path match).
    if (!tr) {
        struct inode *ei = BPF_CORE_READ(bprm, file, f_inode);
        if (ei) {
            struct exe_id id = {};
            id.ino = BPF_CORE_READ(ei, i_ino);
            id.dev = BPF_CORE_READ(ei, i_sb, s_dev);
            tr = bpf_map_lookup_elem(&trusted_inodes, &id);
        }
    }
    if (tr) {
        struct proc_tag t = {};
        t.tag = TAG_TRUSTED;
        t.root_tgid = tgid;
        t.since_ns = bpf_ktime_get_ns();
        bpf_map_update_elem(&agent_pids, &tgid, &t, BPF_ANY);
        return 0;
    }

    // 2) Operator exempt full-path override (overrides inherited AGENT).
    __u8 *ex = bpf_map_lookup_elem(&exempt_exes, full);
    if (ex) {
        struct proc_tag t = {};
        t.tag = TAG_EXEMPT;
        t.root_tgid = tgid;
        t.since_ns = bpf_ktime_get_ns();
        bpf_map_update_elem(&agent_pids, &tgid, &t, BPF_ANY);
        return 0;
    }

    // 3) Agent-launcher basename match. Take the basename DIRECTLY from the exe
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
        return 0;
    }

    // 4) Build-tool taint. Tagging the launcher (npm/pip/cargo/...) taints the
    // whole install subtree: TAG_TAINTED is inherited on fork and sticky across
    // exec, so the postinstall's `node bundle.js` and anything it spawns (curl,
    // trufflehog) stay tainted. TRUSTED/EXEMPT already returned above; do not
    // override an inherited AGENT tag.
    __u8 *is_build = bpf_map_lookup_elem(&build_exe_names, base);
    if (is_build) {
        struct proc_tag *cur = bpf_map_lookup_elem(&agent_pids, &tgid);
        if (!cur || cur->tag != TAG_AGENT) {
            struct proc_tag t = {};
            t.tag = TAG_TAINTED;
            t.root_tgid = tgid;
            t.since_ns = bpf_ktime_get_ns();
            bpf_map_update_elem(&agent_pids, &tgid, &t, BPF_ANY);
        }
        return 0;
    }
    // else: inherited tag (if any) stays in place -> tainted/agent subtree
    // persists across this exec.
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

// NEW-FILE CREATION. file_open's write gate catches opening EXISTING files for
// write, but open(O_CREAT) of a NEW file creates a fresh (negative) dentry and
// does not go through the existing-inode write path - so a non-trusted attacker
// could DROP a new authorized_keys / sudoers.d / ~/.claude file even though it
// cannot touch existing ones. path_mknod fires for regular-file creation (incl.
// the O_CREAT open path when CONFIG_SECURITY_PATH=y) plus device/fifo nodes. The
// new `dentry` is under `dir`, so reconstruct from it exactly like the others.
SEC("lsm/path_mknod")
int BPF_PROG(gs_path_mknod, const struct path *dir, struct dentry *dentry, umode_t mode, unsigned int dev)
{
    struct vfsmount *mnt = BPF_CORE_READ(dir, mnt);
    return fs_guard_dentry(dentry, mnt, 0, 0, EV_CREATE);
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
    __u8 tag = current_tag();
    if (!is_restricted(cfg, tag))
        return 0;

    __u8 buf[MAX_PATH_LEN];
    long r = bpf_d_path((struct path *)path, (char *)buf, MAX_PATH_LEN);
    if (r <= 0)
        return 0;
    __u32 len = (__u32)r - 1;                // r includes trailing NUL
    // NOTE: no free-basename exemption here. This hook takes its path from
    // bpf_d_path() rather than the dentry walk, so it never sees the individual
    // components, and re-scanning the assembled buffer for them would mean a
    // second variable-offset pass - the exact shape that caused the verifier
    // complexity blow-ups during v9 bring-up. In practice this is not a gap:
    // the recommended guard set is unlink+rmdir, and TRUNCATE/OPEN_WRITE are
    // not in it. It only matters if you guard a build tree with block:["*"],
    // which is documented as unsupported for that reason.
    if (path_is_protected(buf, len, ev_op_bit(EV_TRUNCATE))) {
        __u8 enforced = cfg->log_only ? 0 : 1;
        log_violation(EV_TRUNCATE, tag, enforced, buf, len, 0, 0, 0, 0);
        bump(STAT_FS_BLOCKED);
        if (cfg->log_only)
            return 0;
        return -EPERM;
    }
    return 0;
}

// ===================================================================
// file_open: (0) credential-harvest guard - deny ANY open (incl. read-only) of a
// credential AssetMap path by a TAINTED (build-tool) or AGENT subtree; (a) block
// restricted write/truncate opens on protected paths; (b) /dev/mem protection.
// ===================================================================

SEC("lsm/file_open")
int BPF_PROG(gs_file_open, struct file *file)
{
    struct gs_config *cfg = get_config();
    if (!cfg || !cfg->ready)
        return 0;

    __u8 tag = current_tag();
    bool restricted = is_restricted(cfg, tag);

    // ---- (0) credential-read harvest block (supply-chain defense) ----
    // ALWAYS-ON for TAINTED/AGENT subtrees, independent of agent/hardening
    // posture. file_open fires for every open incl. O_RDONLY, so this catches
    // the postinstall reading ~/.aws / ~/.ssh to exfiltrate. A normal/trusted/
    // untainted process reading its own creds is unaffected.
    if (cfg->enforce_cred_read && (tag == TAG_TAINTED || tag == TAG_AGENT)) {
        __u8 cbuf[MAX_PATH_LEN];
        long cr = bpf_d_path(&file->f_path, (char *)cbuf, MAX_PATH_LEN);
        if (cr > 0) {
            __u32 clen = (__u32)cr - 1;
            if (cred_is_protected(cbuf, clen)) {
                log_violation(EV_CRED_READ, tag, cfg->log_only ? 0 : 1, cbuf, clen, 0, 0, 0, 0);
                bump(STAT_FS_BLOCKED);
                if (!cfg->log_only)
                    return -EPERM;
            }
        }
    }

    // ---- (b) /dev/mem, /dev/kmem, /dev/port ----
    // Active for restricted callers when the mem domain is on (agent mode) or in
    // hardening mode (non-trusted).
    if (restricted && (cfg->enforce_mem || hardening_block(cfg, tag))) {
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
    if (cfg->enforce_fs && restricted) {
        unsigned int flags = BPF_CORE_READ(file, f_flags);
        bool writing = (flags & O_ACCMODE) == O_WRONLY ||
                       (flags & O_ACCMODE) == O_RDWR ||
                       (flags & O_TRUNC) || (flags & O_CREAT);
        if (writing) {
            __u8 buf[MAX_PATH_LEN];
            long r = bpf_d_path(&file->f_path, (char *)buf, MAX_PATH_LEN);
            if (r > 0) {
                __u32 len = (__u32)r - 1;
    // NOTE: no free-basename exemption here. This hook takes its path from
    // bpf_d_path() rather than the dentry walk, so it never sees the individual
    // components, and re-scanning the assembled buffer for them would mean a
    // second variable-offset pass - the exact shape that caused the verifier
    // complexity blow-ups during v9 bring-up. In practice this is not a gap:
    // the recommended guard set is unlink+rmdir, and TRUNCATE/OPEN_WRITE are
    // not in it. It only matters if you guard a build tree with block:["*"],
    // which is documented as unsupported for that reason.
                if (path_is_protected(buf, len, ev_op_bit(EV_OPEN_WRITE))) {
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

// ptrace anti-injection.
//   - Agent-containment mode: an AGENT subtree may not ptrace ANYTHING (an agent
//     injecting into any process is the threat we contain).
//   - Hardening mode: a non-trusted process may not ptrace a TRUSTED target
//     (protect the loader / trusted tools from injection). It is deliberately
//     NOT a blanket ban on all non-trusted ptrace - that would break
//     strace/gdb/debuggers for the developer against ordinary processes.
SEC("lsm/ptrace_access_check")
int BPF_PROG(gs_ptrace, struct task_struct *child, unsigned int mode)
{
    struct gs_config *cfg = get_config();
    if (!cfg || !cfg->ready)
        return 0;
    __u8 tag = current_tag();

    bool block = false;
    if (cfg->enforce_mem && tag == TAG_AGENT) {
        block = true;                        // agent containment: source-based
    } else if (cfg->hardening_mode && tag != TAG_TRUSTED) {
        // target-based: only block ptracing a TRUSTED process.
        __u32 target_tgid = BPF_CORE_READ(child, tgid);
        struct proc_tag *tp = bpf_map_lookup_elem(&agent_pids, &target_tgid);
        if (tp && tp->tag == TAG_TRUSTED)
            block = true;
    }
    if (!block)
        return 0;

    __u32 target = BPF_CORE_READ(child, pid);
    log_violation(EV_PTRACE, tag, cfg->log_only ? 0 : 1, 0, 0, 0, 0, target, 0);
    bump(STAT_MEM_BLOCKED);
    return cfg->log_only ? 0 : -EPERM;
}

// kernel module load via kernel_read_file(READING_MODULE) - rootkit vector.
SEC("lsm/kernel_read_file")
int BPF_PROG(gs_kernel_read_file, struct file *file, enum kernel_read_file_id id, bool contents)
{
    struct gs_config *cfg = get_config();
    if (!cfg || !cfg->ready)
        return 0;
    if (id != READING_MODULE)
        return 0;
    __u8 tag = current_tag();
    bool block = (cfg->enforce_mem && tag == TAG_AGENT) || hardening_block(cfg, tag);
    if (!block)
        return 0;
    log_violation(EV_MODULE_LOAD, tag, cfg->log_only ? 0 : 1, 0, 0, 0, 0, 0, 0);
    bump(STAT_MEM_BLOCKED);
    return cfg->log_only ? 0 : -EACCES;
}

// ANTI-TAMPER: bpf() syscall. In hardening mode, any non-trusted caller is
// denied - this stops an attacker (even root) using bpf()/bpftool to detach the
// shield's LSM links, or to manipulate its maps/progs. The trusted loader is
// TAG_TRUSTED so it can still load, pin, and unpin. Only enforces once `ready`
// is set (the initial load happens before this hook is attached).
SEC("lsm/bpf")
int BPF_PROG(gs_bpf, int cmd, union bpf_attr *attr, unsigned int size)
{
    struct gs_config *cfg = get_config();
    if (!cfg || !cfg->ready || !cfg->hardening_mode)
        return 0;
    __u8 tag = current_tag();
    if (tag == TAG_TRUSTED)
        return 0;
    log_violation(EV_BPF, tag, cfg->log_only ? 0 : 1, 0, 0, 0, 0, 0, (__u32)cmd);
    bump(STAT_MEM_BLOCKED);
    return cfg->log_only ? 0 : -EPERM;
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

    // Hardening mode: for non-trusted callers deny a NARROW set only -
    // CAP_SYS_MODULE and CAP_BPF (module / bpf tamper). Deliberately NOT
    // CAP_SYS_ADMIN (too broad - would brick normal root operation).
    if (hardening_block(cfg, tag) && (cap == CAP_SYS_MODULE || cap == CAP_BPF)) {
        log_violation(EV_CAPABILITY, tag, cfg->log_only ? 0 : 1, 0, 0, 0, 0, 0, (__u32)cap);
        bump(STAT_MEM_BLOCKED);
        if (!cfg->log_only)
            return -EPERM;
        return 0;
    }

    // Agent-containment mode: dangerous caps for AGENT subtrees (enforce_priv).
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

// mount operations (container-escape / overlay-tamper hardening). Blocked for
// AGENT subtrees when enforce_priv, and for any non-trusted caller in hardening.
SEC("lsm/sb_mount")
int BPF_PROG(gs_sb_mount, const char *dev_name, const struct path *path,
             const char *type, unsigned long flags, void *data)
{
    struct gs_config *cfg = get_config();
    if (!cfg || !cfg->ready)
        return 0;
    __u8 tag = current_tag();
    bool block = (cfg->enforce_priv && tag == TAG_AGENT) || hardening_block(cfg, tag);
    if (!block)
        return 0;
    log_violation(EV_MOUNT, tag, cfg->log_only ? 0 : 1, 0, 0, 0, 0, 0, 0);
    bump(STAT_MEM_BLOCKED);
    return cfg->log_only ? 0 : -EPERM;
}

SEC("lsm/move_mount")
int BPF_PROG(gs_move_mount, const struct path *from_path, const struct path *to_path)
{
    struct gs_config *cfg = get_config();
    if (!cfg || !cfg->ready)
        return 0;
    __u8 tag = current_tag();
    bool block = (cfg->enforce_priv && tag == TAG_AGENT) || hardening_block(cfg, tag);
    if (!block)
        return 0;
    log_violation(EV_MOUNT, tag, cfg->log_only ? 0 : 1, 0, 0, 0, 0, 0, 1);
    bump(STAT_MEM_BLOCKED);
    return cfg->log_only ? 0 : -EPERM;
}

// ===================================================================
// EGRESS GUARD (supply-chain exfil block)
// ===================================================================

// True if an IPv6 address is loopback (::1), link-local (fe80::/10), or ULA
// (fc00::/7) - i.e. not a routable public destination.
static __always_inline bool v6_is_local(const __u8 *a)
{
    if (a[0] == 0xfe && (a[1] & 0xc0) == 0x80)   // fe80::/10 link-local
        return true;
    if ((a[0] & 0xfe) == 0xfc)                   // fc00::/7 unique-local
        return true;
    // ::1 loopback (and :: unspecified -> treat as local)
    bool high_zero = true;
#pragma unroll
    for (int i = 0; i < 15; i++)
        if (a[i] != 0)
            high_zero = false;
    if (high_zero && (a[15] == 1 || a[15] == 0))
        return true;
    return false;
}

// Outbound connect guard: a TAINTED (build-tool) or AGENT subtree may only
// connect to allowlisted destinations (private/loopback/link-local/CGNAT +
// operator CIDRs). A connect to any other (public) dest -> log EV_TAINTED_CONNECT
// and, if enforce_egress, -EPERM. Runs BEFORE the connect completes, so the
// verdict is independent of network reachability. Normal/trusted/untainted
// processes are unaffected (the user's browser/curl keep working). AF_UNIX and
// other local families are ignored.
SEC("lsm/socket_connect")
int BPF_PROG(gs_socket_connect, struct socket *sock, struct sockaddr *address, int addrlen)
{
    struct gs_config *cfg = get_config();
    if (!cfg || !cfg->ready)
        return 0;
    __u8 tag = current_tag();
    if (tag != TAG_TAINTED && tag != TAG_AGENT)
        return 0;

    __u16 fam = BPF_CORE_READ(address, sa_family);

    if (fam == AF_INET) {
        struct sockaddr_in *sin = (struct sockaddr_in *)address;
        __be32 daddr = BPF_CORE_READ(sin, sin_addr.s_addr);   // network byte order
        __be16 dport = BPF_CORE_READ(sin, sin_port);

        struct egress_lpm_key key = {};
        key.prefixlen = 32;
        __builtin_memcpy(key.addr, &daddr, 4);                // MSB-first bytes
        if (bpf_map_lookup_elem(&egress_allow, &key))
            return 0;                                         // allowlisted

        __u8 enforced = (cfg->enforce_egress && !cfg->log_only) ? 1 : 0;
        log_violation(EV_TAINTED_CONNECT, tag, enforced, 0, 0, 0, 0,
                      bpf_ntohs(dport), bpf_ntohl(daddr));
        bump(STAT_MEM_BLOCKED);
        if (cfg->enforce_egress && !cfg->log_only)
            return -EPERM;
        return 0;
    }

    if (fam == AF_INET6) {
        struct sockaddr_in6 *sin6 = (struct sockaddr_in6 *)address;
        __u8 a[16] = {};
        BPF_CORE_READ_INTO(&a, sin6, sin6_addr);
        __be16 dport = BPF_CORE_READ(sin6, sin6_port);
        if (v6_is_local(a))
            return 0;                                         // local v6 allowed

        // NOTE: no operator IPv6 allowlist in v1 - global v6 dests are treated as
        // public. aux carries family marker 6 (the 128-bit addr does not fit).
        __u8 enforced = (cfg->enforce_egress && !cfg->log_only) ? 1 : 0;
        log_violation(EV_TAINTED_CONNECT, tag, enforced, 0, 0, 0, 0,
                      bpf_ntohs(dport), 6);
        bump(STAT_MEM_BLOCKED);
        if (cfg->enforce_egress && !cfg->log_only)
            return -EPERM;
        return 0;
    }

    return 0;   // AF_UNIX / AF_NETLINK / other: local IPC, never blocked
}
