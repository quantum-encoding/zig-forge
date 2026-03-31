# Grimoire eBPF Integration Guide

**Purpose**: Wire `grimoire-oracle.bpf.c` into `zig-sentinel` main loop
**Status**: Ready for implementation
**Estimated effort**: 2-3 hours

---

## OVERVIEW

The Grimoire Oracle (`grimoire-oracle.bpf.c`) is now complete. This document provides the exact code changes needed to integrate it with `zig-sentinel`.

**Architecture**:
```
Kernel Space                    Userspace (zig-sentinel)
┌─────────────────────┐        ┌──────────────────────┐
│ raw_syscalls/       │        │  GrimoireEngine      │
│ sys_enter           │        │  .processSyscall()   │
│ tracepoint          │        │                      │
└──────┬──────────────┘        └─────▲────────────────┘
       │                              │
       │  grimoire_syscall_event      │ ring_buffer__poll()
       │  {syscall_nr, pid,           │
       │   timestamp_ns, args[6]}     │
       ▼                              │
┌─────────────────────┐        ┌─────┴────────────────┐
│ Pre-filter:         │        │ Ring Buffer Consumer │
│ monitored_syscalls  ├────────▶ handle_grimoire_evt()│
│ (99% reduction)     │        │                      │
└─────────────────────┘        └──────────────────────┘
       │
       ▼
┌─────────────────────┐
│ grimoire_events     │
│ (ring buffer, 1MB)  │
└─────────────────────┘
```

---

## STEP 1: Add eBPF Event Structure to main.zig

Add this near the top of `main.zig` after other C imports:

```zig
// Grimoire Oracle event structure (matches grimoire-oracle.bpf.c)
const GrimoireSyscallEvent = extern struct {
    syscall_nr: u32,
    pid: u32,
    timestamp_ns: u64,
    args: [6]u64,
};
```

---

## STEP 2: Load Grimoire eBPF Program

Modify the eBPF loading section in `main()`:

```zig
// Current code loads syscall_counter.bpf.o
// Add this AFTER existing BPF load, when enable_grimoire is true

var grimoire_obj: ?*c.bpf_object = null;
var grimoire_events_fd: c_int = -1;
var monitored_syscalls_fd: c_int = -1;
var grimoire_config_fd: c_int = -1;

if (enable_grimoire) {
    std.debug.print("🔧 Loading Grimoire Oracle eBPF program...\n", .{});

    const grimoire_bpf_path = "src/zig-sentinel/ebpf/grimoire-oracle.bpf.o";
    grimoire_obj = c.bpf_object__open(grimoire_bpf_path) orelse {
        std.debug.print("❌ Failed to open Grimoire eBPF object: {s}\n", .{grimoire_bpf_path});
        return error.GrimoireBPFOpenFailed;
    };

    if (c.bpf_object__load(grimoire_obj.?) != 0) {
        std.debug.print("❌ Failed to load Grimoire eBPF program\n", .{});
        if (grimoire_obj) |obj| c.bpf_object__close(obj);
        return error.GrimoireBPFLoadFailed;
    }

    std.debug.print("✅ Grimoire Oracle loaded successfully\n", .{});

    // Get map file descriptors
    grimoire_events_fd = c.bpf_object__find_map_fd_by_name(grimoire_obj.?, "grimoire_events");
    monitored_syscalls_fd = c.bpf_object__find_map_fd_by_name(grimoire_obj.?, "monitored_syscalls");
    grimoire_config_fd = c.bpf_object__find_map_fd_by_name(grimoire_obj.?, "grimoire_config");

    if (grimoire_events_fd < 0 or monitored_syscalls_fd < 0 or grimoire_config_fd < 0) {
        std.debug.print("❌ Failed to find Grimoire BPF maps\n", .{});
        if (grimoire_obj) |obj| c.bpf_object__close(obj);
        return error.GrimoireBPFMapNotFound;
    }

    // Populate monitored_syscalls map from HOT_PATTERNS
    try populateMonitoredSyscalls(monitored_syscalls_fd);

    // Enable Grimoire
    var key: u32 = 0;
    var val: u32 = 1;
    _ = c.bpf_map_update_elem(grimoire_config_fd, &key, &val, c.BPF_ANY); // Enable Grimoire
    key = 1;
    _ = c.bpf_map_update_elem(grimoire_config_fd, &key, &val, c.BPF_ANY); // Enable pre-filter

    std.debug.print("📖 Grimoire monitoring {d} syscalls from HOT_PATTERNS\n", .{
        countMonitoredSyscalls(),
    });
}

defer {
    if (grimoire_obj) |obj| c.bpf_object__close(obj);
}
```

---

## STEP 3: Add Helper Functions

Add these functions before `main()`:

```zig
/// Populate monitored_syscalls BPF map from HOT_PATTERNS
fn populateMonitoredSyscalls(map_fd: c_int) !void {
    const val: u8 = 1; // 1 = monitored

    // Iterate through all patterns
    for (grimoire.HOT_PATTERNS) |*pattern| {
        // Iterate through all steps in this pattern
        for (pattern.steps[0..pattern.step_count]) |*step| {
            // If step has a specific syscall number, add it to monitored set
            if (step.syscall_nr) |syscall_nr| {
                const key: u32 = syscall_nr;
                _ = c.bpf_map_update_elem(map_fd, &key, &val, c.BPF_ANY);
            }
            // TODO: Handle syscall_class (e.g., .network, .file_read)
            // For now, only exact syscall numbers are monitored
        }
    }
}

/// Count unique syscalls across all HOT_PATTERNS
fn countMonitoredSyscalls() usize {
    var seen = std.AutoHashMap(u32, void).init(std.heap.page_allocator);
    defer seen.deinit();

    for (grimoire.HOT_PATTERNS) |*pattern| {
        for (pattern.steps[0..pattern.step_count]) |*step| {
            if (step.syscall_nr) |nr| {
                seen.put(nr, {}) catch {};
            }
        }
    }

    return seen.count();
}

/// Ring buffer callback for Grimoire events
fn handleGrimoireEvent(ctx: ?*anyopaque, data: ?*anyopaque, size: usize) callconv(.C) c_int {
    _ = size;

    // Cast context to GrimoireEngine pointer
    const engine_ptr = @as(*grimoire.GrimoireEngine, @ptrCast(@alignCast(ctx)));

    // Cast data to GrimoireSyscallEvent
    const event_ptr = @as(*const GrimoireSyscallEvent, @ptrCast(@alignCast(data)));
    const event = event_ptr.*;

    // Process through Grimoire engine
    const match_result = engine_ptr.processSyscall(
        event.pid,
        event.syscall_nr,
        event.timestamp_ns,
        event.args,
    ) catch |err| {
        std.debug.print("⚠️  Grimoire processSyscall error: {any}\n", .{err});
        return 0;
    };

    // If pattern matched
    if (match_result) |result| {
        // Log to console (TODO: add JSON logging)
        const pattern_name = std.mem.sliceTo(&result.pattern.name, 0);
        std.debug.print("\n🚨 GRIMOIRE MATCH: {s} (PID={d}, severity={s})\n", .{
            pattern_name,
            result.pid,
            @tagName(result.pattern.severity),
        });

        // TODO: Log to grimoire_log_path (JSON format)
        // TODO: If grimoire_enforce, terminate process

        // For now, just log match count
        return 0;
    }

    return 0;
}
```

---

## STEP 4: Add Ring Buffer Polling to Main Loop

Modify the main monitoring loop to poll Grimoire ring buffer:

```zig
// After initializing Grimoire engine, before main loop:

var grimoire_rb: ?*c.ring_buffer = null;
if (enable_grimoire and grimoire_events_fd >= 0) {
    grimoire_rb = c.ring_buffer__new(
        grimoire_events_fd,
        handleGrimoireEvent,
        &grimoire_engine,  // Pass engine as context
        null,
    );
    if (grimoire_rb == null) {
        std.debug.print("⚠️  Failed to create Grimoire ring buffer\n", .{});
    }
}
defer {
    if (grimoire_rb) |rb| c.ring_buffer__free(rb);
}

// Inside the main while loop, add:

// Poll Grimoire ring buffer
if (enable_grimoire and grimoire_rb != null) {
    const events_processed = c.ring_buffer__poll(grimoire_rb.?, 100); // Poll with 100ms timeout
    if (events_processed < 0) {
        std.debug.print("⚠️  Grimoire ring buffer poll error\n", .{});
    }
}
```

---

## STEP 5: Update Display Stats

Modify the existing stats display to show Grimoire stats when active:

```zig
// In the periodic update section:

if (enable_grimoire and grimoire_engine.total_matches > 0) {
    std.debug.print("\r⏱️  Elapsed: {d}/{d}s | 📖 Grimoire: {d} matches   ",
        .{ elapsed, duration_seconds, grimoire_engine.total_matches });
} else if (enable_detection and detector.total_alerts > 0) {
    // ... existing anomaly display ...
}
```

---

## STEP 6: Add Grimoire Statistics Display

This is already implemented in Phase 2a, but verify it's called:

```zig
// At the end of monitoring, after other stats:

if (enable_grimoire and grimoire_engine.total_matches > 0) {
    std.debug.print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n", .{});
    grimoire_engine.displayStats();
    std.debug.print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n\n", .{});
}
```

---

## STEP 7: Add Audit Logging (TODO)

Create audit logging function:

```zig
fn logGrimoireMatch(
    allocator: std.mem.Allocator,
    result: grimoire.MatchResult,
    grimoire_log_path: []const u8,
    enforced: bool,
) !void {
    // Open log file in append mode
    const file = try std.fs.openFileAbsolute(grimoire_log_path, .{
        .mode = .write_only,
        .lock = .exclusive,
    });
    defer file.close();

    try file.seekFromEnd(0);

    // Format JSON log entry
    const pattern_name = std.mem.sliceTo(&result.pattern.name, 0);
    const json = try std.fmt.allocPrint(allocator,
        \\{{"timestamp": {d}, "pattern_id": "0x{x}", "pattern_name": "{s}", "severity": "{s}", "pid": {d}, "action": "{s}"}}
        \\
    , .{
        result.timestamp_ns,
        result.pattern.id_hash,
        pattern_name,
        @tagName(result.pattern.severity),
        result.pid,
        if (enforced) "terminated" else "logged",
    });
    defer allocator.free(json);

    try file.writeAll(json);
}
```

Then call it in `handleGrimoireEvent()`:

```zig
if (match_result) |result| {
    // ... existing logging ...

    // Write to audit log
    logGrimoireMatch(
        std.heap.page_allocator,
        result,
        grimoire_log_path,  // Need to pass this through context
        grimoire_enforce,
    ) catch |err| {
        std.debug.print("⚠️  Failed to log Grimoire match: {any}\n", .{err});
    };

    // Enforce if enabled
    if (grimoire_enforce) {
        const kill_result = std.posix.kill(@intCast(result.pid), std.posix.SIG.KILL);
        _ = kill_result catch |err| {
            std.debug.print("⚠️  Failed to terminate PID {d}: {any}\n", .{result.pid, err});
        };
        std.debug.print("⚔️  TERMINATED PID {d} (pattern match: {s})\n", .{
            result.pid,
            std.mem.sliceTo(&result.pattern.name, 0),
        });
    }
}
```

---

## COMPILATION

Compile the eBPF program:

```bash
cd src/zig-sentinel/ebpf
make clean
make

# Should output:
# ✓ Compiled: grimoire-oracle.bpf.o
```

Verify:
```bash
ls -lh grimoire-oracle.bpf.o
# Should be ~20-30KB
```

---

## TESTING

### Test 1: Shadow Mode (No Enforcement)

```bash
sudo ./zig-out/bin/zig-sentinel --duration=60 --enable-grimoire
```

**Expected output**:
```
🔭 zig-sentinel v6.0.0-grimoire - The Watchtower
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
📖 Sovereign Grimoire (V6): ENABLED
🛡️  Pattern detection: 5 patterns in L1 cache
👁️  Shadow mode: ACTIVE (detection only, no enforcement)
📝 Grimoire log: /var/log/zig-sentinel/grimoire_alerts.json
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

🔧 Loading eBPF program...
✅ eBPF program loaded successfully
🔧 Loading Grimoire Oracle eBPF program...
✅ Grimoire Oracle loaded successfully
📖 Grimoire monitoring 12 syscalls from HOT_PATTERNS

⏱️  Elapsed: 10/60s | 📖 Grimoire: 0 matches
```

### Test 2: Trigger Fork Bomb Pattern

In another terminal:
```bash
# Simple fork bomb (will be caught by pattern)
bash -c ':(){ :|:& };:'
```

**Expected**:
```
🚨 GRIMOIRE MATCH: fork_bomb_rapid (PID=12345, severity=critical)
```

### Test 3: Check Statistics

After test completes:
```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
📖 Grimoire Engine Statistics:
   Patterns checked:   125420
   Total matches:      1
   Critical:           1
   High:               0
   Warning:            0
   Active processes:   234
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

### Test 4: Check BPF Stats

```bash
sudo bpftool map dump name grimoire_stats

# Expected output:
key: 0  value: 1245680  # Total syscalls seen
key: 1  value: 12456    # Syscalls after filter (~1%)
key: 2  value: 12456    # Events emitted
key: 3  value: 0        # Dropped events (should be 0)
```

**Filter efficiency**: 12456 / 1245680 = 1.0% (99% filtered) ✅

---

## PERFORMANCE VALIDATION

Expected overhead after integration:

| Metric | Without Grimoire | With Grimoire (filtered) | Delta |
|--------|------------------|-------------------------|-------|
| CPU Usage | 2.0% | 2.1% | +0.1% ✅ |
| Ring Buffer Events/sec | 0 | ~100 | +100 |
| Memory | 50MB | 51MB | +1MB ✅ |
| BPF Overhead | 0ns | ~50ns/syscall | +50ns |

**Acceptable if**:
- CPU overhead < 1%
- Ring buffer drops = 0
- Pattern matching < 100µs per event

---

## TROUBLESHOOTING

### Issue: BPF Load Fails

```
❌ Failed to load Grimoire eBPF program
```

**Solutions**:
1. Check kernel version: `uname -r` (need 5.8+)
2. Check BTF support: `ls /sys/kernel/btf/vmlinux`
3. Run with `sudo` (requires CAP_BPF)
4. Check dmesg: `sudo dmesg | tail`

### Issue: No Events Received

```
⏱️  Elapsed: 60/60s | 📖 Grimoire: 0 matches
```

**Checklist**:
1. Verify monitored_syscalls populated: `bpftool map dump name monitored_syscalls`
2. Verify grimoire_config enabled: `bpftool map dump name grimoire_config`
3. Check ring buffer: `bpftool map dump name grimoire_events`
4. Trigger known pattern (fork bomb) to test

### Issue: Too Many Events (Ring Buffer Full)

```
⚠️  Grimoire ring buffer poll error
```

**Solutions**:
1. Check stats: `bpftool map dump name grimoire_stats` (key 3 = drops)
2. Increase ring buffer size in grimoire-oracle.bpf.c (1MB → 4MB)
3. Reduce polling interval in main loop (100ms → 50ms)
4. Check pre-filter efficiency (should be ~99%)

---

## NEXT STEPS

After successful integration:

1. **30-Day Shadow Mode** - Monitor false positive rate
2. **Tune Whitelists** - Add site-specific trusted processes
3. **Enable Enforcement** - Only after FP rate < 0.01%
4. **Add JSON Logging** - Complete audit trail
5. **Tier 2 Patterns** - Load from encrypted config

---

**Status**: Ready for integration ✅
**Estimated Time**: 2-3 hours
**Risk Level**: Low (shadow mode by default)

*"The Oracle's eyes are open. The Grimoire awaits its first whisper."*
