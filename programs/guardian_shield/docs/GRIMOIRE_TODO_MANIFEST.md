# Grimoire Phase 2 - TODO Manifest

**Purpose**: Outstanding implementation tasks for Grimoire behavioral pattern detection engine
**For**: Grok AI implementation
**Test Build**: After Grok completes these TODOs

---

## 🎯 Priority 1: Core Pattern Matching (Critical for Phase 2)

### File: `src/zig-sentinel/grimoire.zig`

**Line 583**: Implement syscall_class matching
```zig
// TODO: Check syscall_class
// Current: Always returns true for class-based matching
// Need: Implement network, file_read, file_write, process_create, etc. classification
```
**Location**: `src/zig-sentinel/grimoire.zig:583`
**Context**: Inside `processSyscall()` function, syscall matching logic
**Impact**: HIGH - Without this, patterns using syscall_class (PATTERN 3, 4, 5) won't work correctly

---

**Line 608**: Implement argument constraint validation
```zig
// TODO: Check argument constraints
// Current: Argument constraints are defined but not validated
// Need: Implement equals, not_equals, greater_than, less_than, bitmask_set, bitmask_clear
```
**Location**: `src/zig-sentinel/grimoire.zig:608`
**Context**: Inside `processSyscall()` function, after syscall and time/distance checks
**Impact**: CRITICAL - Without this, patterns can't validate syscall arguments (e.g., dup2 fd checks)

---

## 🎯 Priority 2: Whitelist Support (Reduce False Positives)

### File: `src/zig-sentinel/grimoire.zig`

**Line 161-163**: Add external whitelist lookup
```zig
/// TODO Phase 2: Add whitelist support via external lookup table
/// whitelisted_processes: Would make struct too large (>256 bytes)
/// whitelisted_binaries: Would make struct too large (>256 bytes)
```
**Location**: `src/zig-sentinel/grimoire.zig:161-163`
**Context**: Inside `GrimoirePattern` struct definition
**Impact**: HIGH - Needed to prevent false positives on legitimate tools
**Solution**: Create external HashMap or array for process/binary whitelists, checked before pattern matching

---

**Line 284**: Fork bomb whitelist
```zig
// TODO Phase 2: Whitelist build tools (make, gcc, cargo, zig)
```
**Location**: `src/zig-sentinel/grimoire.zig:284`
**Context**: PATTERN 2 (fork_bomb_rapid)
**Impact**: MEDIUM - Build tools legitimately fork rapidly

---

**Line 327**: Privilege escalation whitelist
```zig
// TODO Phase 2: Whitelist setuid programs (sudo, su, passwd, pkexec)
```
**Location**: `src/zig-sentinel/grimoire.zig:327`
**Context**: PATTERN 3 (privesc_setuid_root)
**Impact**: HIGH - sudo/su are legitimate setuid usage

---

**Line 373**: Credential exfiltration whitelist
```zig
// TODO Phase 2: Whitelist SSH tools (ssh, ssh-agent, ssh-add, scp)
```
**Location**: `src/zig-sentinel/grimoire.zig:373`
**Context**: PATTERN 4 (cred_exfil_ssh_key)
**Impact**: HIGH - SSH tools legitimately read SSH keys

---

**Line 405**: Rootkit detection whitelist
```zig
// TODO Phase 2: Whitelist module loaders (modprobe, insmod, systemd-modules-load)
```
**Location**: `src/zig-sentinel/grimoire.zig:405`
**Context**: PATTERN 5 (rootkit_module_load)
**Impact**: MEDIUM - System module loaders are legitimate

---

## 🎯 Priority 3: Path Filtering (Improve Specificity)

### File: `src/zig-sentinel/grimoire.zig`

**Line 302**: Privilege escalation path filtering
```zig
// Step 1: Open sensitive file (any file - TODO: add path filtering)
```
**Location**: `src/zig-sentinel/grimoire.zig:302`
**Context**: PATTERN 3 (privesc_setuid_root), Step 1
**Impact**: HIGH - Should only trigger on /etc/shadow, /etc/passwd, /root/, etc.
**Note**: Requires implementing path_prefix or similar constraint type (removed due to struct size)

---

**Line 351**: Credential exfiltration path filtering
```zig
// Step 2: Open sensitive file (SSH key, AWS creds, etc.) - TODO: add path filtering
```
**Location**: `src/zig-sentinel/grimoire.zig:351`
**Context**: PATTERN 4 (cred_exfil_ssh_key), Step 2
**Impact**: HIGH - Should only trigger on ~/.ssh/, ~/.aws/, credentials files
**Note**: Critical for reducing false positives

---

**Line 391**: Rootkit detection path filtering
```zig
// Step 1: Open .ko file - TODO: add path filtering
```
**Location**: `src/zig-sentinel/grimoire.zig:391`
**Context**: PATTERN 5 (rootkit_module_load), Step 1
**Impact**: MEDIUM - Should only trigger on *.ko files
**Note**: Could check filename extension

---

## 🎯 Priority 4: Other Component TODOs

### File: `src/zig-http-sentinel/filter_engine.zig`

**Line 213**: JSON audit logging
```zig
// TODO: Implement JSON audit logging
```
**Location**: `src/zig-http-sentinel/filter_engine.zig:213`
**Context**: HTTP sentinel filter engine
**Impact**: LOW - Not critical for Grimoire, but useful for audit trail

---

### File: `src/zig-sentinel/oracle-advanced.zig`

**Line 263**: Hash calculation for process tracking
```zig
entry.hash = 0; // TODO: Calculate hash in Phase 3
```
**Location**: `src/zig-sentinel/oracle-advanced.zig:263`
**Context**: Oracle advanced eBPF integration
**Impact**: LOW - Deferred to Phase 3

---

### File: `src/zig-sentinel/ebpf/oracle-advanced.bpf.c`

**Line 269**: BPF-side hash matching
```zig
// TODO: Add hash matching and regex support in Phase 3
```
**Location**: `src/zig-sentinel/ebpf/oracle-advanced.bpf.c:269`
**Context**: eBPF kernel-side filtering
**Impact**: LOW - Deferred to Phase 3, optimization only

---

## 📋 Implementation Guidance for Grok

### For Priority 1 (Critical):

1. **Syscall Class Matching** (`grimoire.zig:583`)
   - Create `isSyscallInClass()` function
   - Match syscall_nr against predefined class sets
   - Classes: network (socket, connect, bind, etc.), file_read (open, read, openat), etc.

2. **Argument Constraints** (`grimoire.zig:608`)
   - Iterate through `step.arg_constraints`
   - For each constraint, validate `args[constraint.arg_index]` against `constraint.value`
   - Support all constraint types: equals, not_equals, greater_than, less_than, bitmask_set, bitmask_clear

### For Priority 2 (High):

3. **External Whitelist System** (`grimoire.zig:161`)
   - Add `process_whitelist: std.StringHashMap(bool)` to `GrimoireEngine` struct
   - Create `isProcessWhitelisted(pid: u32, pattern_index: usize)` function
   - Load whitelists from config or compile-time arrays
   - Check whitelist before pattern matching starts

### For Priority 3 (Medium):

4. **Path Filtering** (multiple locations)
   - Option A: Add back `string_value` to `ArgConstraint` with external storage
   - Option B: Create separate path filter function with pattern-specific logic
   - Validate file paths against sensitive path lists

---

## 🧪 Test Plan (After Implementation)

1. **Build Test**: `zig build` should succeed with no errors
2. **Unit Tests**: `zig test src/zig-sentinel/grimoire.zig`
3. **Integration Test**: Wire Grimoire into zig-sentinel main loop
4. **Live Fire Test**: Test with actual reverse shell, fork bomb, etc.

---

## 📊 Estimated Impact

| TODO | Priority | LOC | Complexity | FP Reduction |
|------|----------|-----|------------|--------------|
| Syscall class matching | P1 | ~50 | Medium | 20% |
| Argument constraints | P1 | ~100 | High | 40% |
| External whitelist | P2 | ~150 | Medium | 80% |
| Path filtering | P3 | ~200 | High | 60% |

**Total Estimated**: ~500 LOC, 2-3 hours for experienced Zig developer

---

*Generated by Claude Code for Grok AI implementation*
*Next session: Test build and integration with zig-sentinel*
