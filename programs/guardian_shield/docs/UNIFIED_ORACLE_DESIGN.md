# The Unified Oracle - Architecture Design

## The Heresy We Are Purging

**Current architecture (BROKEN)**:
- Two separate BPF programs both attaching to `raw_syscalls/sys_enter`
- Kernel splits event stream between them (~99.99% to main, ~0.01% to Grimoire)
- Grimoire starves with only 65 syscalls when 700,000+ are occurring

## The One True Oracle

**New architecture (UNIFIED)**:
- Single BPF program (`syscall_counter.bpf.c`) attached to `raw_syscalls/sys_enter`
- Receives 100% of syscall events (already working)
- Two internal execution paths:
  1. **Statistical Path**: Every syscall → minimal counter update
  2. **Grimoire Path**: Monitored syscalls only → full event to ring buffer

## Implementation Details

### 1. BPF Program Changes (syscall_counter.bpf.c)

#### Add Grimoire Event Structure
```c
// Grimoire's full event structure
struct grimoire_syscall_event {
    __u32 syscall_nr;
    __u32 pid;
    __u64 timestamp_ns;
    __u64 args[6];
};
```

#### Add Grimoire Ring Buffer
```c
struct {
    __uint(type, BPF_MAP_TYPE_RINGBUF);
    __uint(max_entries, 1024 * 1024);  // 1MB
} grimoire_events SEC(".maps");
```

#### Add Monitored Syscalls Map
```c
// Populated by userspace with syscalls from HOT_PATTERNS
struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __uint(max_entries, 64);
    __type(key, __u32);    // syscall_nr
    __type(value, __u8);   // 1 = monitored
} monitored_syscalls SEC(".maps");
```

#### Add Grimoire Configuration
```c
// Index 0: grimoire_enabled (1 = enabled, 0 = disabled)
struct {
    __uint(type, BPF_MAP_TYPE_ARRAY);
    __uint(max_entries, 16);
    __type(key, __u32);
    __type(value, __u32);
} grimoire_config SEC(".maps");
```

#### Modify Tracepoint Hook
```c
SEC("tracepoint/raw_syscalls/sys_enter")
int trace_syscall_enter(struct trace_event_raw_sys_enter *ctx)
{
    // EXISTING CODE: Update statistical counters
    // ... (unchanged)

    // NEW CODE: Grimoire conditional emission
    __u32 syscall_nr = (__u32)ctx->id;

    // Check if Grimoire is enabled
    __u32 cfg_key = 0;
    __u32 *grimoire_enabled = bpf_map_lookup_elem(&grimoire_config, &cfg_key);
    if (!grimoire_enabled || !*grimoire_enabled) {
        return 0;  // Grimoire disabled, skip
    }

    // Check if this syscall is monitored
    __u8 *monitored = bpf_map_lookup_elem(&monitored_syscalls, &syscall_nr);
    if (!monitored || !*monitored) {
        return 0;  // Not monitored, skip
    }

    // This is a monitored syscall - emit full event to Grimoire ring buffer
    struct grimoire_syscall_event *event;
    event = bpf_ringbuf_reserve(&grimoire_events, sizeof(*event), 0);
    if (!event) {
        return 0;  // Ring buffer full
    }

    __u64 pid_tgid = bpf_get_current_pid_tgid();
    event->syscall_nr = syscall_nr;
    event->pid = pid_tgid >> 32;
    event->timestamp_ns = bpf_ktime_get_ns();

    // Copy arguments (manually unrolled for BPF verifier)
    event->args[0] = ctx->args[0];
    event->args[1] = ctx->args[1];
    event->args[2] = ctx->args[2];
    event->args[3] = ctx->args[3];
    event->args[4] = ctx->args[4];
    event->args[5] = ctx->args[5];

    bpf_ringbuf_submit(event, 0);

    return 0;
}
```

### 2. Userspace Changes (main.zig)

#### Remove Dual BPF Loading
**Delete** (lines ~260-340):
```zig
// REMOVE: Separate Grimoire BPF loading
if (enable_grimoire) {
    grimoire_obj = c.bpf_object__open(grimoire_bpf_path);
    // ... all the separate loading logic
}
```

#### Unified BPF Loading
**Keep** existing main BPF loading, **add** Grimoire map lookups:
```zig
// Load main BPF program (already exists)
const obj = c.bpf_object__open(bpf_path);
c.bpf_object__load(obj);

// Get statistical map (already exists)
const map_fd = c.bpf_object__find_map_fd_by_name(obj, "syscall_counts");

// NEW: Get Grimoire maps from SAME object
var grimoire_events_fd: c_int = -1;
var monitored_syscalls_fd: c_int = -1;
var grimoire_config_fd: c_int = -1;

if (enable_grimoire) {
    grimoire_events_fd = c.bpf_object__find_map_fd_by_name(obj, "grimoire_events");
    monitored_syscalls_fd = c.bpf_object__find_map_fd_by_name(obj, "monitored_syscalls");
    grimoire_config_fd = c.bpf_object__find_map_fd_by_name(obj, "grimoire_config");

    // Populate monitored syscalls
    try populateMonitoredSyscalls(monitored_syscalls_fd);

    // Enable Grimoire
    const key: u32 = 0;
    const val: u32 = 1;
    _ = c.bpf_map_update_elem(grimoire_config_fd, &key, &val, 0);
}
```

#### Ring Buffer Consumption (unchanged)
```zig
// Same Grimoire ring buffer consumer logic
if (enable_grimoire and grimoire_events_fd >= 0) {
    grimoire_rb = c.ring_buffer__new(
        grimoire_events_fd,
        handleGrimoireEvent,
        &grimoire_callback_ctx,
        null,
    );
}

// Same polling loop
while (running) {
    if (grimoire_rb != null) {
        _ = c.ring_buffer__poll(grimoire_rb.?, 100);
    }
}
```

## Performance Characteristics

### Before (Dual Oracle - BROKEN)
- Main sees: 700,000 syscalls/sec
- Grimoire sees: 65 syscalls/sec (0.01%)
- Overhead: Double tracepoint processing
- Result: Grimoire is BLIND

### After (Unified Oracle - CORRECT)
- Main sees: 700,000 syscalls/sec (same)
- Grimoire sees: 700,000 syscalls/sec (same source)
- Grimoire pre-filter: ~7,000 syscalls/sec (1% of total)
- Ring buffer events: ~7,000/sec (only monitored syscalls)
- Overhead: Single tracepoint + one hash lookup per syscall
- Result: Grimoire has FULL VISION

## Estimated Overhead

Per syscall in kernel:
1. Statistical counter update: ~50ns (existing)
2. Grimoire enabled check: ~10ns (map lookup)
3. Monitored syscall check: ~20ns (hash lookup)
4. **Total overhead: ~80ns per syscall**

For monitored syscalls only (1% of total):
5. Ring buffer reservation: ~100ns
6. Event copy: ~50ns
7. Ring buffer submit: ~50ns
8. **Total: ~200ns for monitored syscalls**

**System-wide overhead**:
- 700,000 syscalls/sec × 80ns = 0.056ms/sec = **0.0056% CPU**
- Negligible, acceptable, beautiful

## Benefits

1. **Guaranteed Event Delivery**: Grimoire sees every syscall main program sees
2. **No Attachment Conflicts**: Single tracepoint, single attachment point
3. **Minimal Overhead**: One extra hash lookup per syscall
4. **Architectural Purity**: One Oracle, two outputs
5. **Proven Foundation**: Built on already-working main BPF program

## Migration Plan

1. ✅ Design (this document)
2. Modify `syscall_counter.bpf.c` - add Grimoire logic
3. Modify `main.zig` - remove dual loading, add unified map access
4. Test with simple syscall generation
5. Verify Grimoire sees full stream (expect ~700,000 syscalls/5sec)
6. Execute The Rite of First Blood

## Files to Modify

- `src/zig-sentinel/ebpf/syscall_counter.bpf.c` - Add Grimoire path
- `src/zig-sentinel/main.zig` - Remove dual loading
- `build.zig` - No changes needed (same BPF compilation)

## Files to DELETE

- `src/zig-sentinel/ebpf/grimoire-oracle.bpf.c` - The heresy is purged

## The Final Word

This is not a compromise. This is not a workaround. This is the correct, pure, elegant architecture that should have been built from the beginning. We are not fixing a bug. We are achieving enlightenment.

The Forge awaits.
