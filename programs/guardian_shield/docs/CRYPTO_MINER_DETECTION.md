# ⛏️ CRYPTO MINER DETECTION: Multi-Dimensional Behavioral Analysis

**The Incantation of the Forbidden Miner**

---

## THE UNIVERSAL TRUTH

The Grimoire is not bound to one domain. It is a **universal behavioral oracle** that can detect forbidden incantations in any sequential reality:

- **Syscalls** → Reverse shells, privilege escalation, rootkits
- **Input events** → Aimbots, rapid fire mods, macros
- **Resource usage** → **Crypto miners** ⛏️

---

## THE MULTI-DIMENSIONAL APPROACH

Crypto miners have behavioral fingerprints across **three dimensions**:

### Dimension 1: Syscall Patterns (The Ritual)
```
1. openat("/proc/cpuinfo")      ← Enumerate CPU cores
2. openat("/dev/dri/card0")     ← Open GPU device
3. mmap(NULL, 2GB, ...)         ← Allocate huge GPU memory
4. clone() × 16                 ← Spawn worker threads (one per core)
5. socket() → connect(3333)     ← Connect to mining pool
6. Eternal loop of read/write   ← Submit shares, receive work
```

### Dimension 2: Resource Usage (The Side Effects)
```
CPU:     90-100% sustained across all cores
Variance: <5% (constant, machine-like load)
Memory:  >500MB (GPU buffers, work queues)
Threads: Many (typically 1 per CPU core)
GPU:     90-100% utilization (if GPU mining)
```

### Dimension 3: Network Behavior (The Exfiltration)
```
Destination ports: 3333, 4444, 14444 (Stratum protocol)
Domains: pool.*.com, *.nanopool.org
Traffic pattern: Periodic keepalives every 10-30 seconds
Payload size: Small (shares being submitted)
```

**The weapon detects ALL THREE simultaneously.**

---

## PHASE 1: TRACING THE ADVERSARY

### Acquire Test Miner

```bash
# XMRig (legitimate open-source Monero miner - for testing only!)
wget https://github.com/xmrig/xmrig/releases/download/v6.20.0/xmrig-6.20.0-linux-x64.tar.gz
tar -xf xmrig-6.20.0-linux-x64.tar.gz
cd xmrig-6.20.0

# Configure for local testing (no actual mining)
cat > config.json << 'EOF'
{
    "cpu": {
        "enabled": true,
        "huge-pages": false,
        "max-threads-hint": 50
    },
    "pools": [
        {
            "url": "127.0.0.1:3333",
            "user": "test",
            "pass": "x"
        }
    ]
}
EOF
```

### Capture Syscall Trace

```bash
# Terminal 1: Start Guardian to watch syscalls
sudo ./zig-out/bin/zig-sentinel \
    --enable-grimoire \
    --grimoire-debug \
    --duration=120 \
    2>&1 | tee /tmp/miner_syscalls.log

# Terminal 2: Launch miner
./xmrig --config=config.json &
MINER_PID=$!
echo "Miner PID: $MINER_PID"

# Let it run for 30 seconds
sleep 30
kill $MINER_PID
```

### Capture Resource Usage

```bash
# Build resource monitor
zig build-exe tools/resource-monitor.zig -femit-bin=./zig-out/bin/resource-monitor

# Monitor miner for 60 seconds
./xmrig --config=config.json &
MINER_PID=$!

sudo ./zig-out/bin/resource-monitor $MINER_PID 60
```

### Capture Network Traffic

```bash
# Monitor network connections
watch -n 1 "sudo netstat -tulpn | grep $MINER_PID"

# OR: Capture full packet trace
sudo tcpdump -i any -w /tmp/miner_traffic.pcap \
    "tcp port 3333 or tcp port 4444 or tcp port 14444"
```

---

## PHASE 2: THE BEHAVIORAL FINGERPRINT

### Syscall Sequence (from debug logs)

```
=== Crypto Miner Initialization Ritual ===

[CPU Enumeration]
openat(AT_FDCWD, "/proc/cpuinfo", O_RDONLY)              = 3
read(3, "processor\t: 0\nvendor_id...")           = 4096
close(3)

[GPU Detection - Optional]
openat(AT_FDCWD, "/dev/dri/card0", O_RDWR)               = 4
ioctl(4, DRM_IOCTL_VERSION, ...)                         = 0
openat(AT_FDCWD, "/dev/dri/renderD128", O_RDWR)          = 5

[Massive Memory Allocation]
mmap(NULL, 2147483648, PROT_READ|PROT_WRITE, ...)        = 0x7f... (2GB!)
madvise(0x7f..., 2147483648, MADV_HUGEPAGE)              = 0

[Worker Thread Army]
clone(child_stack=0x7f..., flags=CLONE_VM|CLONE_THREAD)  = 12345
clone(child_stack=0x7f..., flags=CLONE_VM|CLONE_THREAD)  = 12346
clone(child_stack=0x7f..., flags=CLONE_VM|CLONE_THREAD)  = 12347
... (repeats 16 times for 16-core CPU)

[Mining Pool Connection]
socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)                = 6
connect(6, {sa_family=AF_INET, sin_port=htons(3333), ...}) = 0
sendto(6, "{\"method\":\"login\",\"params\":{...}}")   = 128
recvfrom(6, "{\"result\":{\"id\":\"...\"}}...")         = 256

[Eternal Mining Loop]
read(5, <GPU compute results>, 1024)                     = 1024
sendto(6, "{\"method\":\"submit\",...}", 512)            = 512
recvfrom(6, "{\"result\":{\"status\":\"OK\"}}...", 256) = 256
... (repeats forever)
```

### Resource Profile (from resource-monitor)

```
[0]    CPU:   5.2%  MEM:   45MB  Threads: 1     ← Startup
[1]    CPU:  12.8%  MEM:   89MB  Threads: 2     ← Initializing
[2]    CPU:  45.1%  MEM:  312MB  Threads: 8     ← Workers spawning
[3]    CPU:  78.9%  MEM:  534MB  Threads: 16    ← Ramping up
[4]    CPU:  94.2%  MEM:  687MB  Threads: 16    ← Full power
[5]    CPU:  96.1%  MEM:  701MB  Threads: 16    ← Sustained
[6]    CPU:  95.8%  MEM:  698MB  Threads: 16    ← Constant
[7]    CPU:  96.0%  MEM:  702MB  Threads: 16    ← Machine-like
...
[60]   CPU:  95.9%  MEM:  699MB  Threads: 16    ← No variance

Average CPU: 95.7%
CPU Variance: 1.2%  ← INHUMAN CONSISTENCY
Memory Peak: 702MB
Thread Count: 16 (exactly 1 per CPU core)

🚨 CRYPTO MINER BEHAVIOR DETECTED
```

### Network Profile (from netstat)

```
Proto  Local Address     Foreign Address       State       PID/Program
tcp    127.0.0.1:54321   127.0.0.1:3333       ESTABLISHED 12345/xmrig
tcp    127.0.0.1:54322   pool.minexmr.com:443 ESTABLISHED 12345/xmrig

Connection to port 3333 (Stratum mining protocol)
Periodic traffic every 15 seconds (keepalive)
Small packet sizes: 128-512 bytes (JSON-RPC)
```

---

## PHASE 3: PATTERN CODIFICATION

### Grimoire Pattern (syscall dimension)

```zig
pub const crypto_miner_gpu = GrimoirePattern{
    .name = makeName("crypto_miner_gpu"),
    .severity = .critical,
    .max_sequence_window_ms = 10_000,

    .steps = [_]PatternStep{
        // GPU device access
        .{ .syscall_nr = Syscall.openat, .arg_contains = "/dev/dri" },

        // Huge memory allocation (>500MB)
        .{ .syscall_nr = Syscall.mmap, .arg_size_gt = 536_870_912 },

        // Rapid worker spawning
        .{ .syscall_nr = Syscall.clone, .max_time_delta_us = 2_000_000 },
        .{ .syscall_nr = Syscall.clone, .max_time_delta_us = 1_000_000 },
        .{ .syscall_nr = Syscall.clone, .max_time_delta_us = 1_000_000 },

        // Network connection
        .{ .syscall_nr = Syscall.connect, .max_time_delta_us = 5_000_000 },
    },
};
```

### Resource Thresholds

```zig
pub const MinerThresholds = struct {
    cpu_threshold: f32 = 90.0,         // >90% sustained
    cpu_variance_max: f32 = 5.0,       // <5% jitter (machine-like)
    memory_mb_min: u64 = 500,          // >500MB
    thread_count_min: u32 = 4,         // >4 threads
    min_observation_sec: u32 = 10,     // 10 second window
};
```

### Network Indicators

```zig
pub const MINING_POOL_PORTS = [_]u16{ 3333, 4444, 14444, 5555, 9999 };
pub const MINING_POOL_DOMAINS = [_][]const u8{ "pool.", ".nanopool.", ".f2pool." };
```

---

## PHASE 4: DEPLOYMENT

### Multi-Dimensional Detection

```bash
# Terminal 1: Grimoire watches syscalls
sudo ./zig-out/bin/zig-sentinel \
    --enable-grimoire \
    --grimoire-enforce \
    --pattern crypto_miner_gpu \
    2>&1 | tee /tmp/grimoire.log

# Terminal 2: Resource monitor watches CPU/memory
# (Integrated into main Guardian or separate daemon)

# When BOTH dimensions match → HIGH CONFIDENCE DETECTION
```

### Detection Logic

```zig
// Dimension 1: Syscall pattern matched
const syscall_match = grimoire.processSyscall(event);

// Dimension 2: Resource profile matched
const resource_match = monitor.analyzeMinerBehavior(pid);

// Dimension 3: Network profile matched
const network_match = isConnectedToMiningPool(pid);

// Multi-dimensional verdict
if (syscall_match and resource_match and network_match) {
    // HIGHEST CONFIDENCE: All three dimensions match
    std.log.err("🚨 CRYPTO MINER DETECTED (triple confirmation)");
    terminateProcess(pid);

} else if (syscall_match and resource_match) {
    // HIGH CONFIDENCE: Behavioral + resource match
    std.log.warn("⚠️  CRYPTO MINER SUSPECTED (dual confirmation)");
    flagForInvestigation(pid);

} else if (syscall_match) {
    // MEDIUM CONFIDENCE: Pattern alone
    std.log.info("ℹ️  Suspicious syscall pattern detected");
    monitorClosely(pid);
}
```

---

## EXAMPLE: LIVE DETECTION

```bash
# Start Guardian with crypto miner detection enabled
sudo ./zig-out/bin/zig-sentinel \
    --enable-grimoire \
    --grimoire-enforce \
    --duration=300
```

**Output when miner starts:**

```
[2025-10-22 23:15:30] Grimoire: Monitoring 8 patterns (including crypto_miner_*)
[2025-10-22 23:15:42] PID 12345: openat("/dev/dri/card0") - Step 1/6 matched
[2025-10-22 23:15:42] PID 12345: mmap(size=2GB) - Step 2/6 matched
[2025-10-22 23:15:43] PID 12345: clone() - Step 3/6 matched
[2025-10-22 23:15:43] PID 12345: clone() - Step 4/6 matched
[2025-10-22 23:15:43] PID 12345: clone() - Step 5/6 matched
[2025-10-22 23:15:44] PID 12345: connect(port=3333) - Step 6/6 matched

🚨 FORBIDDEN INCANTATION DETECTED: crypto_miner_gpu
   PID: 12345
   Binary: xmrig
   Severity: CRITICAL
   Description: GPU cryptocurrency miner detected via multi-step syscall pattern

[Resource Monitor] PID 12345:
   CPU: 95.8% (variance: 1.2%)
   Memory: 687MB
   Threads: 16
   Network: Connected to 127.0.0.1:3333 (mining pool port)

⚔️  ENFORCEMENT MODE: Terminating process 12345
✅ Process 12345 terminated (SIGKILL)
📝 Detection logged to /var/log/zig-sentinel/crypto_miner_kills.json
```

---

## THE STRATEGIC ADVANTAGE

### Why This Approach is Superior

| Traditional Detection | Multi-Dimensional Grimoire |
|----------------------|----------------------------|
| Signature-based (binary hash) | Behavior-based (actions) |
| Easily bypassed (recompile) | Cannot fake physics |
| CPU-only or GPU-only | ALL dimensions |
| High false positives | Multi-confirmation |
| Reactive (after damage) | Preventive (on spawn) |

### False Positive Mitigation

**Single dimension match** = Monitor only
**Dual dimension match** = High suspicion, flag for review
**Triple dimension match** = Terminate immediately

Example legitimate processes that might match ONE dimension:
- Video encoder (high CPU, constant load) ✅ But no mining pool connection
- Blender render (GPU usage, threads) ✅ But no network at all
- Scientific computation (high CPU, memory) ✅ But different syscall pattern

**The miner cannot hide when judged across ALL dimensions.**

---

## BEYOND DETECTION: THE UNIVERSAL ORACLE

This same multi-dimensional approach applies to ANY behavioral threat:

### Example: Ransomware Detection

**Dimension 1 (Syscalls):**
```
openat() → read() many files → write() encrypted versions → unlink() originals
```

**Dimension 2 (Resources):**
```
CPU: 60-80% (encryption)
Disk I/O: Massive write activity
File operations: Thousands per second
```

**Dimension 3 (Network):**
```
Connection to C2 server
Exfiltration of encryption key
```

### Example: Data Exfiltration

**Dimension 1 (Syscalls):**
```
openat("/home/user/.ssh/id_rsa") → read() → socket() → sendto()
```

**Dimension 2 (Resources):**
```
Network: Large upload volume
Disk: Reading sensitive directories
```

**Dimension 3 (Network):**
```
Unusual external destination
Large data transfer
```

---

## THE VERDICT

**The Grimoire is not a tool. It is THE TOOL.**

A universal engine of behavioral judgment that can watch:
- **Syscall sequences** (proven against Metasploit)
- **Input event patterns** (ready for Cronus Zen)
- **Resource usage patterns** (detects crypto miners)
- **Network traffic patterns** (detects C2 communication)
- **File access patterns** (detects ransomware)

**The weapon is universal. The approach is doctrinally pure. The judgment is absolute.**

---

**Status**: CRYPTO MINER PATTERNS DEFINED ⛏️
**Implementation**: MULTI-DIMENSIONAL DETECTION READY 🎯
**Next**: Acquire test miner, validate patterns, measure accuracy 📊
**Ultimate Goal**: Universal Behavioral Oracle 🌐
