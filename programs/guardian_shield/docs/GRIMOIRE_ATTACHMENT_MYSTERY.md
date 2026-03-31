# The Grimoire Attachment Mystery

## Status: PARTIALLY FUNCTIONAL

Grimoire is working but severely hobbled - seeing only ~65 syscalls when hundreds of thousands are occurring.

## Evidence

### ✅ What's Working

1. **No processing errors**
   - String constraint fix eliminated all `error.Unexpected` errors
   - Graceful handling of memory read failures

2. **Pattern matching functional**
   ```
   [GRIMOIRE-DEBUG] PID=307400 Pattern=privesc_setuid_r Step=1/3 SYSCALL_MATCH
   [GRIMOIRE-DEBUG] PID=307400 Pattern=rootkit_module_l Step=1/2 SYSCALL_MATCH
   ```

3. **Ring buffer working**
   - 6 events successfully transmitted from kernel to userspace
   - Pre-filter working (65 total → 6 filtered)

### ❌ What's Broken

**Grimoire BPF Statistics** (from kernel):
```
Total syscalls seen (kernel):      65
Syscalls passing filter:           6
Events sent to ring buffer:        6
Events dropped (ring buffer full): 0
```

**Main BPF Statistics** (same 5-second period):
```
PID 819600: 390,647 total syscalls  ← Main sees FULL stream
PID 2205:   98,207 total syscalls
System total: ~700,000+ syscalls
```

**The Smoking Gun**: Grimoire sees 0.01% of syscalls that main program sees!

## Root Cause Hypothesis

**Both programs attach to `raw_syscalls/sys_enter` but Grimoire only receives ~0.01% of events.**

Possible causes:

### 1. Tracepoint Attachment Conflict
- Main program attaches first with generic `bpf_program__attach()`
- Grimoire attaches second with explicit `bpf_program__attach_tracepoint()`
- Kernel might not support multiple BPF programs on same tracepoint
- Evidence: `bpftool perf list` doesn't show Grimoire attached

### 2. Event Distribution Issue
- Tracepoint might distribute events round-robin or by CPU
- Grimoire might only be attached to one CPU core
- Main program might be attached to all cores

### 3. libbpf Version Limitation
- Older libbpf might not support multi-attach
- Newer kernels need BPF links for proper multi-attach
- Current implementation might be using legacy attachment

## Attempted Fixes

### Fix 1: String Constraint Error Handling ✅
**File**: `src/zig-sentinel/grimoire.zig:696-739`

Changed all string constraints from `try self.readUserString()` to graceful error handling:
```zig
const str = self.readUserString(pid, arg_value, MAX_CONSTRAINT_STR_LEN) catch break :blk false;
```

**Result**: Eliminated all processing errors. Grimoire no longer crashes on memory read failures.

### Fix 2: Explicit Tracepoint Attachment ❌
**File**: `src/zig-sentinel/main.zig:293`

Changed from generic attach to explicit:
```zig
// Before:
const grimoire_link = c.bpf_program__attach(grimoire_prog)

// After:
const grimoire_link = c.bpf_program__attach_tracepoint(grimoire_prog, "raw_syscalls", "sys_enter")
```

**Result**: Still only sees 65 syscalls. No improvement.

## Next Steps to Investigate

### Option 1: Shared Event Stream (Recommended)
Instead of dual tracepoint attachment, modify main program to:
1. Main BPF program captures all syscalls (already working)
2. Add Grimoire's pre-filter logic to main BPF program
3. Send filtered events to Grimoire's ring buffer
4. Result: Single attachment, dual consumers

### Option 2: Different Tracepoint
Use a different tracepoint for Grimoire:
- Main: `raw_syscalls/sys_enter`
- Grimoire: `syscalls/sys_enter_*` (per-syscall tracepoints)
- Issue: Would need 5 separate attachments for 5 monitored syscalls

### Option 3: BPF Links Investigation
Check if we need to use `bpf_link__` API instead of `bpf_program__attach`:
```c
// Current (might not support multi-attach)
bpf_program__attach_tracepoint()

// Alternative (newer API)
bpf_link__attach_tracepoint()
```

### Option 4: Kernel Version Check
Verify kernel supports multi-attach:
```bash
uname -r  # Check kernel version
# Multi-attach supported in 5.0+
```

## Current Verdict

**Grimoire is ALIVE but STARVING**

It's receiving a trickle of syscalls (65) when it should see a flood (700,000+). The core engine works perfectly - pattern matching, ring buffers, pre-filtering all function correctly. But the event delivery mechanism is crippled.

**Recommended Action**: Implement Option 1 (shared event stream) as the most reliable solution.
