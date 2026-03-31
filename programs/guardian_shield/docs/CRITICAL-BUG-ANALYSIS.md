# CRITICAL BUG: Inquisitor Not Blocking Executions

## Root Cause Analysis

**Date:** October 19, 2025
**Status:** ROOT CAUSE IDENTIFIED
**Severity:** CRITICAL - Complete failure of blocking functionality

---

## The Bug

The Inquisitor LSM BPF program uses `bpf_get_current_comm()` to identify the program being executed:

```c
// inquisitor-simple.bpf.c:176-177
char comm[16] = {};
bpf_get_current_comm(comm, sizeof(comm));
```

**THE PROBLEM:** At the time `bprm_check_security` LSM hook fires, the current task's `comm` field **still contains the PARENT process name**, not the program being executed.

---

## Evidence

### Trace Output Showing the Bug:
```
Executing test-target...
BPF trace: Inquisitor: checking comm='trace-test-targ'
```

When the script `trace-test-target.sh` executes the binary `/home/founder/.../test-target`:
- **Expected:** comm='test-target'
- **Actual:** comm='trace-test-targ' (the shell script name, truncated to 15 chars)

### Event Log Evidence:
```
✓ ALLOWED: pid=74584 command='trace-test-targ'  (script)
✓ ALLOWED: pid=74585 command='gnome-shell'       (other process)
```

**test-target NEVER appears in logs** even though it executes successfully.

---

## Why This Happens

The LSM hook `bprm_check_security` fires **during** `execve()` before the new program fully replaces the current process:

1. Parent process (e.g., bash script) calls `fork()`
2. Child process calls `execve("/path/to/test-target", ...)`
3. Kernel starts loading test-target
4. **`bprm_check_security` fires HERE** ← We are here
5. Task's `comm` field updated to "test-target"
6. New program starts execution

At step 4, `current->comm` still shows the parent's name, not test-target!

---

## The Fix

### What to Change:
Replace `bpf_get_current_comm()` with extraction from `bprm->filename`.

### Correct Implementation:
```c
// Get filename from bprm structure
const char *filename_ptr = BPF_CORE_READ(bprm, filename);
if (!filename_ptr)
    return 0;

// Read filename from kernel memory
char filename_full[256] = {};
long ret_read = bpf_probe_read_kernel_str(filename_full, sizeof(filename_full), filename_ptr);
if (ret_read < 0)
    return 0;

// Extract basename (last path component)
char program_name[64] = {};
extract_basename_from_path(filename_full, program_name, sizeof(program_name));

// NOW use program_name for blacklist matching
```

### Helper Function Needed:
```c
static __always_inline void extract_basename_from_path(const char *path, char *basename, int max_len)
{
    int last_slash_pos = -1;

    // Find last '/' character (manual loop, unrolled for verifier)
    #pragma unroll
    for (int i = 0; i < 255; i++) {
        if (path[i] == '\0') break;
        if (path[i] == '/') last_slash_pos = i;
    }

    // Copy basename (characters after last slash)
    int src_pos = last_slash_pos + 1;
    #pragma unroll
    for (int i = 0; i < max_len - 1; i++) {
        if (path[src_pos + i] == '\0') break;
        basename[i] = path[src_pos + i];
    }
    basename[max_len - 1] = '\0';
}
```

---

## Testing the Fix

### Test 1: Monitor Mode
```bash
sudo /path/to/test-inquisitor monitor 10 &
sleep 2
/path/to/test-target
```

**Expected after fix:**
```
✓ ALLOWED: command='test-target'
```

### Test 2: Enforce Mode
```bash
sudo /path/to/test-inquisitor enforce 30 &
sleep 2
/path/to/test-target
```

**Expected after fix:**
```
🚫 BLOCKED: command='test-target' (Operation not permitted)
```

test-target should NOT execute.

---

## Files to Modify

1. `/home/founder/github_public/guardian-shield/src/zig-sentinel/ebpf/inquisitor-simple.bpf.c`
   - Lines 175-177: Replace `bpf_get_current_comm()` logic
   - Add `extract_basename_from_path()` helper function
   - Update blacklist matching to use extracted program name

2. Recompile:
   ```bash
   cd /home/founder/github_public/guardian-shield/src/zig-sentinel/ebpf
   clang -target bpf -D__TARGET_ARCH_x86 -O2 -g -Wall \
         -I/usr/include -I/usr/include/x86_64-linux-gnu \
         -c inquisitor-simple.bpf.c -o inquisitor-simple.bpf.o
   ```

3. Rebuild Zig binary:
   ```bash
   cd /home/founder/github_public/guardian-shield
   zig build
   ```

---

## Impact

**Before Fix:**
- ❌ Blocks NOTHING (blacklist completely non-functional)
- ✓ Hook fires and logs parent processes
- ✓ Infrastructure works (maps, ring buffers, attach)

**After Fix:**
- ✓ Will correctly identify programs being executed
- ✓ Blacklist matching will work
- ✓ test-target will be blocked when blacklisted
- ✓ The Inquisitor will function as designed

---

## Oracle Protocol Verdict: CORRECTED

The Oracle Protocol initially concluded **"ZERO VIABLE HOOKS"** because it used `bpf_printk()` detection with a short test window.

**Actual truth:** LSM BPF hooks ARE viable - the issue was purely in application logic (using wrong field for program identification).

**Lesson learned:** Direct empirical testing (ring buffer events) > indirect detection (bpf_printk + grep).

---

Generated: October 19, 2025
The Refiner: Claude (Sonnet 4.5)
