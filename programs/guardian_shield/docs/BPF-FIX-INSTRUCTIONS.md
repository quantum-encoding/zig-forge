# INQUISITOR BPF FIX - Implementation Instructions

## Critical Change Required

### Location:
`/home/founder/github_public/guardian-shield/src/zig-sentinel/ebpf/inquisitor-simple.bpf.c`

### Lines to Replace: 175-181

**CURRENT (BROKEN):**
```c
// Get current process name
char comm[16] = {};
bpf_get_current_comm(comm, sizeof(comm));

// Always log the comm to see what we're checking
bpf_printk("Inquisitor: checking comm='%s'", comm);
```

**REPLACE WITH (FIXED):**
```c
// Get the program being executed from bprm->filename
// Note: bpf_get_current_comm() returns PARENT process, not the program being executed!
const char *filename_ptr = BPF_CORE_READ(bprm, filename);
if (!filename_ptr)
    return 0;  // Can't determine filename, allow execution

// Read filename string from kernel memory
char filename_full[256] = {};
long read_result = bpf_probe_read_kernel_str(filename_full, sizeof(filename_full), filename_ptr);
if (read_result < 0)
    return 0;  // Read failed, allow execution

// Extract basename (program name without path)
char program_name[64] = {};
int last_slash = -1;

// Find last '/' to get basename
#pragma unroll
for (int i = 0; i < 255 && filename_full[i] != '\0'; i++) {
    if (filename_full[i] == '/') last_slash = i;
}

// Copy basename
int copy_from = last_slash + 1;
#pragma unroll
for (int i = 0; i < 63; i++) {
    char c = filename_full[copy_from + i];
    if (c == '\0') break;
    program_name[i] = c;
}
program_name[63] = '\0';

// Debug log the actual program name
bpf_printk("Inquisitor: executing program='%s'", program_name);

// ALSO get current comm for logging purposes
char comm[16] = {};
bpf_get_current_comm(comm, sizeof(comm));
bpf_printk("Inquisitor: parent comm='%s'", comm);
```

### Additional Changes:

**Line 187:** Change from `comm` to `program_name`:
```c
// OLD:
idx = 0; if (check_entry(comm, idx)) blocked = 1;

// NEW:
idx = 0; if (check_entry(program_name, idx)) blocked = 1;
```

**Do the same for lines 188-194** (all 8 unrolled blacklist checks).

**Line 216:** Update event logging:
```c
// OLD:
__builtin_memcpy(event->comm, comm, 16);

// NEW:
__builtin_memcpy(event->comm, program_name, 16);
```

**Line 218:** Update filename field too:
```c
// Change from:
__builtin_memcpy(event->filename, comm, 16);

// To:
__builtin_memcpy(event->filename, program_name, 64);
```

---

## Compile After Fix

```bash
cd /home/founder/github_public/guardian-shield/src/zig-sentinel/ebpf
clang -target bpf -D__TARGET_ARCH_x86 -O2 -g -Wall \
      -I/usr/include -I/usr/include/x86_64-linux-gnu \
      -c inquisitor-simple.bpf.c -o inquisitor-simple.bpf.o
```

If you get verifier errors, you may need to add more `#pragma unroll` directives or adjust loop bounds.

---

## Test After Fix

```bash
cd /home/founder/github_public/guardian-shield
zig build

# Test 1: Monitor mode - should now see 'test-target' in logs
sudo ./zig-out/bin/test-inquisitor monitor 10 &
sleep 2
./test-target

# Test 2: Enforce mode - should BLOCK test-target
sudo ./zig-out/bin/test-inquisitor enforce 30 &
sleep 2
./test-target  # Should fail with "Operation not permitted"
```

---

## Expected Results After Fix

✓ test-target appears in event logs with command='test-target'
✓ Blacklist matching works (test-target matches 'test-target' entry)
✓ Enforce mode blocks test-target execution
✓ The Inquisitor finally works as designed!
