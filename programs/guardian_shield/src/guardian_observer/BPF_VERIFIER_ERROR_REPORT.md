# BPF Verifier Error Report - Guardian Observer

## Problem Summary

eBPF program fails to load with verifier error: `R1 invalid mem access 'scalar'` at instruction 107.

The verifier is rejecting our attempt to read the parent PID from `task_struct->real_parent->tgid`.

## Error Details

```
103: (85) call bpf_get_current_task_btf#158   ; R0_w=trusted_ptr_task_struct() refs=4
104: (7b) *(u64 *)(r10 -8) = r0       ; R0_w=trusted_ptr_task_struct() R10=fp0 fp-8_w=trusted_ptr_task_struct() refs=4
105: (79) r3 = *(u64 *)(r10 -8)       ; R3_w=trusted_ptr_task_struct() R10=fp0 fp-8_w=trusted_ptr_task_struct() refs=4
106: (b7) r1 = 2720                   ; R1_w=2720 refs=4
107: (79) r1 = *(u64 *)(r1 +0)
R1 invalid mem access 'scalar'
processed 101 insns (limit 1000000) max_states_per_insn 0 total_states 5 peak_states 5 mark_read 4
```

## Relevant Code

### Current Implementation (BROKEN)

```c
/* Helper to get parent PID - simplified to avoid verifier issues */
static __always_inline __u32 get_ppid(void)
{
    struct task_struct *task = (struct task_struct *)bpf_get_current_task_btf();
    return BPF_CORE_READ(task, real_parent, tgid);
}
```

Called from tracepoint handler:
```c
SEC("tp/syscalls/sys_enter_execve")
int trace_execve(struct trace_event_raw_sys_enter *ctx)
{
    // ... event setup ...

    event->uid = bpf_get_current_uid_gid() & 0xFFFFFFFF;
    event->ppid = get_ppid();  // <-- THIS FAILS VERIFICATION

    bpf_get_current_comm(&event->comm, sizeof(event->comm));

    // ... rest of handler ...
}
```

## What We've Tried

1. **Using `bpf_get_current_task()` + cast** - Verifier rejected: scalar treated as pointer
2. **Using `bpf_get_current_task_btf()`** - Still rejected at instruction 107
3. **Chained `BPF_CORE_READ(task, real_parent, tgid)`** - Current attempt, still failing

## Verifier Analysis

- Instruction 103: `bpf_get_current_task_btf()` returns `trusted_ptr_task_struct()` ✅
- Instruction 104-105: Store and reload from stack - pointer preserved ✅
- Instruction 106: Load offset `2720` (offset of `real_parent` in `task_struct`) into R1
- Instruction 107: Try to dereference R1 as pointer ❌ **FAILS - R1 is scalar, not pointer**

The issue is that `BPF_CORE_READ` is being compiled in a way that loads the offset as a scalar value instead of properly dereferencing through the trusted pointer.

## Build Environment

- Kernel: Linux 6.17.5-arch1-1
- Clang target: bpf
- libbpf: Latest from /usr/include/bpf
- BPF CO-RE: Enabled with `-g` flag
- vmlinux.h: Generated from `/sys/kernel/btf/vmlinux`

## Required Solution

Need a BPF verifier-compliant way to read `current_task->real_parent->tgid` that:
1. Uses the trusted pointer from `bpf_get_current_task_btf()`
2. Properly chains pointer dereferences through CO-RE
3. Satisfies verifier's pointer tracking requirements

## Question for Grok

**How do we correctly read `task->real_parent->tgid` in an eBPF program using BPF CO-RE that will pass the verifier?**

The verifier understands we have a `trusted_ptr_task_struct()` but rejects our attempt to traverse the pointer chain to get the parent's PID.

## Files Attached

- `guardian-observer.bpf.c` - Full eBPF program source
- `guardian-observer.c` - Userspace loader
- Verifier error log (above)

## Success Criteria

Program should:
1. Load without verifier errors
2. Successfully attach to syscall tracepoints
3. Read parent PID for each monitored process
4. Submit events to ring buffer for userspace processing
