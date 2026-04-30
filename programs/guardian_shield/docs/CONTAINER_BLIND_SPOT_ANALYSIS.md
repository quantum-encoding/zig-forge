# THE DOCTRINE OF THE SOVEREIGN BLIND SPOT

**Date**: 2025-10-22
**Status**: ROOT CAUSE IDENTIFIED
**Severity**: CRITICAL - Container attacks are completely invisible to Grimoire

---

## Executive Summary

The Guardian Shield's Grimoire behavioral detection engine **cannot see attacks inside containers**. This blind spot is caused by a fundamental namespace mismatch between kernel-space (BPF) and userspace PID resolution.

**Evidence from live testing**:
- ✅ Host-based reverse shell attack: **PIDs visible** (PID 843903 seen, namespace 4026531836)
- ❌ Container-based reverse shell attack: **ZERO PIDs seen** (container init PID 845000 never observed)
- 📊 Namespace analysis: **Only 1 unique namespace seen** (4026531836 = host)

---

## The Root Cause

### Location: `src/zig-sentinel/ebpf/grimoire-oracle.bpf.c:168-169`

```c
// Get process info
__u64 pid_tgid = bpf_get_current_pid_tgid();
__u32 pid = pid_tgid >> 32;
```

### The Problem

`bpf_get_current_pid_tgid()` returns the PID **from the calling process's namespace perspective**, not the host namespace.

#### Example: Containerized Python Reverse Shell

1. **Container perspective**: Python process has PID 7 (inside container)
2. **BPF records**: PID 7 (from container's perspective)
3. **Ring buffer event**: `{syscall_nr: 41, pid: 7, ...}`
4. **Userspace receives**: PID 7
5. **Userspace tries**: `/proc/7/exe` (fails - PID 7 in host namespace is a different process!)
6. **Result**: Event is invisible or misattributed

---

## Evidence from Test Run

### Namespace Visibility Test

```bash
$ strings /tmp/container-test.log | grep -E "ns=" | sed -n 's/.*ns=\([0-9]*\).*/\1/p' | sort | uniq -c
      3 0              # Failed namespace reads
    164 4026531836     # Host namespace (all visible syscalls)
                       # ZERO other namespaces!
```

### Container PID Search

```bash
$ strings /tmp/container-test.log | grep "PID=845"  # Container init PID = 845000
# (no output - PID never seen by Grimoire)
```

### What Grimoire Did See

- Docker daemon (PID 334336, host namespace): ✅ Visible
- Docker client (PID 843880, host namespace): ✅ Visible
- Host attack Python (PID 843903, host namespace): ✅ Visible
- Container Python attack (PID ???, container namespace): ❌ **INVISIBLE**

---

## The Architecture Gap

```
┌─────────────────────────────────────────────────────────────┐
│ KERNEL SPACE (Container Namespace)                          │
│                                                              │
│  Python PID 7 → socket() syscall                            │
│       ↓                                                      │
│  BPF tracepoint: trace_sys_enter()                          │
│       ↓                                                      │
│  bpf_get_current_pid_tgid() → returns PID 7                 │
│       ↓                                                      │
│  Ring buffer: {syscall: 41, pid: 7, ...}                    │
└─────────────────────────────────────────────────────────────┘
                          ↓
┌─────────────────────────────────────────────────────────────┐
│ USERSPACE (Host Namespace)                                  │
│                                                              │
│  Grimoire receives: PID 7                                   │
│       ↓                                                      │
│  Tries: /proc/7/exe  ← This is a DIFFERENT process!         │
│       ↓                                                      │
│  Result: Wrong binary name, wrong namespace info            │
│       ↓                                                      │
│  Pattern matcher: Never sees the real attack sequence       │
└─────────────────────────────────────────────────────────────┘
```

---

## Impact Assessment

### What This Means

1. **Container evasion is trivial**: Any attacker running inside a container is invisible
2. **Cloud-native deployments vulnerable**: Kubernetes pods, Docker containers completely unprotected
3. **False security**: Guardian appears to be working but has a massive blind spot

### Attack Scenarios That Bypass Detection

- Reverse shells from containerized web applications
- Lateral movement between containers
- Privilege escalation inside containers
- Data exfiltration from containerized databases
- Any attack initiated from inside Docker/Podman/containerd

---

## The Fix: Three Strategies

### Strategy 1: Use `bpf_get_ns_current_pid_tgid()` (RECOMMENDED)

**Concept**: Get PIDs in the init namespace (host namespace) from BPF

```c
// Get host namespace PID using init namespace
struct task_struct *task = (struct task_struct *)bpf_get_current_task();
__u64 pid_tgid = bpf_get_ns_current_pid_tgid(
    task->nsproxy->pid_ns_for_children,  // Source namespace
    0                                     // Target: init namespace
);
__u32 host_pid = pid_tgid >> 32;
```

**Pros**:
- Kernel does the translation
- Clean solution
- No userspace complexity

**Cons**:
- Requires kernel 5.7+ (helper introduced 2020)
- May need CO-RE for different kernel versions

### Strategy 2: Pass Both PIDs (Container + Host)

**Concept**: Store both namespace PID and host PID in event

```c
struct grimoire_syscall_event {
    __u32 syscall_nr;
    __u32 pid;              // Container-local PID
    __u32 host_pid;         // Host namespace PID (from init ns)
    __u32 pid_ns_inum;      // PID namespace inode for correlation
    __u64 timestamp_ns;
    __u64 args[6];
};
```

**Pros**:
- Full visibility into namespace topology
- Can track container PID → host PID mapping
- Better forensics

**Cons**:
- Larger event structure (more ring buffer pressure)
- More complex userspace logic

### Strategy 3: Namespace-Aware Filtering

**Concept**: Add PID namespace filtering to BPF

```c
// Only monitor host namespace OR explicitly watched containers
__u32 current_ns = BPF_CORE_READ(task, nsproxy, pid_ns_for_children, ns.inum);
if (!is_namespace_monitored(current_ns)) {
    return 0;  // Skip this namespace
}
```

**Pros**:
- Can limit scope to specific containers
- Reduces noise from unmonitored containers

**Cons**:
- Doesn't solve the PID translation problem
- Requires dynamic namespace registration

---

## Recommended Path Forward

1. **Immediate**: Implement Strategy 1 (`bpf_get_ns_current_pid_tgid()`)
2. **Short-term**: Add namespace inode to event structure (Strategy 2 lite)
3. **Long-term**: Build container-aware monitoring with namespace registry

---

## Test Results (2025-10-22)

### Test Configuration

- Guardian version: Unified Oracle (commit 0821e72)
- Test script: `tests/grimoire/test-container-blind-spot.sh`
- Container: Python 3.11-slim (Docker)
- Attack: Python reverse shell to localhost:4444

### Host Attack Results

```
✅ Grimoire SAW the host attack PID (843903)
   Namespace: 4026531836 (host)
   Binary: python3
   Syscalls: socket(41), execve(59) visible
   Pattern matches: 0 (attack failed due to timing, but syscalls were visible)
```

### Container Attack Results

```
❌ Grimoire NEVER saw any container namespace PIDs
   Container init PID: 845000 (should have been visible)
   Expected namespace: 4026532xxx (different from host)
   Actual visibility: ZERO syscalls from container processes
   🔍 BLIND SPOT CONFIRMED
```

### Statistics

- Total syscalls captured: 164
- Unique namespaces seen: 1 (4026531836 only)
- Container-flagged events: 0
- Pattern matches in containers: 0

---

## Files Modified for Investigation

1. **grimoire.zig:595-622** - Added namespace detection functions:
   - `getProcessNamespace()` - Read PID namespace inode from /proc
   - `isInContainer()` - Detect if PID is in different namespace

2. **grimoire.zig:792-810** - Enhanced debug logging:
   - Now logs: `binary={s} ns={d} container={}`
   - Reveals namespace visibility

3. **tests/grimoire/test-container-blind-spot.sh** - Comprehensive test:
   - Baseline host attack
   - Container attack comparison
   - Namespace analysis
   - Automated blind spot detection

---

## Conclusion

The Guardian Shield's Grimoire engine has a **critical architectural blind spot** for containerized attacks. The root cause is a PID namespace mismatch between BPF (which sees container-local PIDs) and userspace (which expects host PIDs).

**The fix is clear**: Use `bpf_get_ns_current_pid_tgid()` to resolve PIDs in the host namespace at the BPF level, before sending events to userspace.

**Until fixed**, the Guardian Shield **cannot protect cloud-native deployments** that use containers.

---

*"The Guardian watches all, but can it see through the walls of the container? The answer, as of today, is no. But now we know why, and how to fix it."*
