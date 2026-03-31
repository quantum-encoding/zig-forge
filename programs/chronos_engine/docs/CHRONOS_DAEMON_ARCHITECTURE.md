## CHRONOS DAEMON ARCHITECTURE

**Status:** Phase 1 Complete - Core Engine + Systemd Integration
**Next Phase:** Full D-Bus Integration (requires libdbus bindings)

---

## 🎯 DOCTRINE OF SOVEREIGN DAEMONS

### The Flaw of Transience
A command-line tool dies with its invocation. The Chronos Clock must be **eternal** - a permanent heartbeat of the JesterNet.

### The Sovereign Solution
Transform chronos-ctl into **chronosd** - a permanent, systemd-managed daemon.

**Architecture Principles:**
1. **Centralized Privilege** - Only chronosd writes `/var/lib/chronos/tick.dat`
2. **Decentralized Access** - All clients use unprivileged IPC
3. **Permanent Presence** - systemd ensures resilience
4. **Minimal TCB** - Smallest possible trusted computing base

---

## 📦 CURRENT IMPLEMENTATION (Phase 1)

### Components Forged

#### 1. Core Engine ✅
- `chronos.zig` - Atomic monotonic counter with persistence
- `phi_timestamp.zig` - Multi-dimensional timestamp generation
- `chronos-ctl.zig` - CLI tool (working, tested)

#### 2. Daemon Infrastructure ✅
- `chronosd.zig` - Daemon skeleton with method handlers
- `chronosd.service` - Fully hardened systemd unit
- `org.jesternet.Chronos.conf` - D-Bus security policy
- `dbus_interface.zig` - D-Bus interface definition

#### 3. Tests ✅
- Atomic increment validation
- Persistence across restarts
- Monotonic guarantee (100 iterations)
- Phi timestamp format validation

### What Works Now

```bash
# Initialize clock
chronos-ctl init

# Get current tick
chronos-ctl tick

# Increment and get next tick
chronos-ctl next

# Generate Phi timestamp
chronos-ctl stamp CLAUDE-A
# Output: 2025-10-19T21:28:24.472823544Z::CLAUDE-A::TICK-0000000003

# Structured logging
chronos-ctl log CLAUDE-A test_defense SUCCESS "All tests passed"
# Output: {"timestamp":"2025-10-19T21:28:37.882295849Z::CLAUDE-A::TICK-0000000004","action":"test_defense","status":"SUCCESS","details":"All tests passed"}
```

---

## 🔧 PHASE 2: FULL D-BUS INTEGRATION

### Current Limitation

The daemon skeleton exists, but **full D-Bus integration requires libdbus C bindings**. This is non-trivial in Zig.

### Two Path Forward

#### Path A: Native Zig D-Bus Implementation
**Pros:**
- Pure Zig (no C dependencies)
- Full control over implementation

**Cons:**
- Requires implementing D-Bus wire protocol
- Significant development time
- Reinventing proven infrastructure

**Estimated Time:** 2-3 days

#### Path B: Zig ↔ C libdbus Bindings
**Pros:**
- Leverages battle-tested libdbus
- Proven reliability (used by all system daemons)
- Follows Guardian Shield pattern (C interop)

**Cons:**
- Requires careful C binding management
- FFI complexity

**Estimated Time:** 1 day

**Recommendation:** Path B (follows proven Guardian Shield C interop pattern)

### Interim Solution: Unix Socket IPC

Until full D-Bus is implemented, we can use Unix domain sockets:

```zig
// chronosd listens on /var/run/chronos.sock
// Simple text protocol:
//   GET_TICK\n -> "42\n"
//   NEXT_TICK\n -> "43\n"
//   STAMP:CLAUDE-A\n -> "2025-10-19...\n"
```

**Benefits:**
- Pure Zig implementation
- Still centralized privilege model
- Simple protocol
- Works immediately
- Can migrate to D-Bus later without client changes (shim layer)

---

## 🛡️ SECURITY MODEL

### Systemd Hardening (Already Implemented)

```ini
# File system isolation
StateDirectory=chronos
StateDirectoryMode=0700
PrivateTmp=yes
ProtectSystem=strict
ProtectHome=yes

# Process isolation
NoNewPrivileges=yes
PrivateDevices=yes
ProtectKernelModules=yes
MemoryDenyWriteExecute=yes

# Capability restrictions
CapabilityBoundingSet=
AmbientCapabilities=

# System call filtering
SystemCallFilter=@system-service
SystemCallFilter=~@privileged
```

### D-Bus Policy (Ready for Deployment)

- **Service Ownership:** Only `chronos` user can own `org.jesternet.Chronos`
- **Method Access:** All users can call GetTick, NextTick, GetPhiTimestamp, LogEvent
- **Shutdown:** Only root can call Shutdown method

### Privilege Model

```
┌─────────────────────────────────────────┐
│         chronosd (chronos user)         │
│  - Owns /var/lib/chronos/tick.dat      │
│  - Exposes D-Bus/Socket interface       │
│  - Runs with minimal privileges         │
└─────────────────────────────────────────┘
                    ▲
                    │ D-Bus/Socket (unprivileged)
                    │
    ┌───────────────┼───────────────┐
    │               │               │
┌───▼───┐      ┌───▼────┐     ┌───▼────┐
│CLAUDE │      │DEEPSEEK│     │ Human  │
│  -A   │      │   -A   │     │  Tool  │
└───────┘      └────────┘     └────────┘
 (no special privileges)
```

---

## 📋 DEPLOYMENT PROCEDURE

### Manual Deployment (Development)

```bash
# 1. Build daemon
cd src/chronos-engine
zig build-exe chronosd.zig

# 2. Install binary
sudo cp chronosd /usr/local/bin/
sudo chmod +x /usr/local/bin/chronosd

# 3. Install systemd service
sudo cp chronosd.service /etc/systemd/system/
sudo systemctl daemon-reload

# 4. Install D-Bus policy (when D-Bus ready)
sudo cp org.jesternet.Chronos.conf /etc/dbus-1/system.d/

# 5. Start daemon
sudo systemctl start chronosd
sudo systemctl enable chronosd

# 6. Verify
sudo systemctl status chronosd
```

### Automated Deployment (Production)

Add to Guardian Shield build system:

```zig
// In main build.zig
const chronosd = b.addExecutable(.{
    .name = "chronosd",
    // ... config
});

// Install step
const install_chronosd = b.addInstallArtifact(chronosd, .{
    .dest_dir = .{ .override = .{ .custom = "/usr/local/bin" } },
});

const install_service = b.addInstallFile(
    .{ .path = "src/chronos-engine/chronosd.service" },
    "/etc/systemd/system/chronosd.service"
);
```

---

## 🧪 TESTING STRATEGY

### Unit Tests (Implemented)
- ✅ Atomic increment correctness
- ✅ Persistence across restarts
- ✅ Monotonic guarantee
- ✅ Phi timestamp formatting
- ✅ JSON log serialization

### Integration Tests (TODO)
- [ ] systemd service lifecycle
- [ ] D-Bus method calls
- [ ] Multi-client concurrent access
- [ ] Daemon restart with tick continuity
- [ ] Security policy enforcement

### Stress Tests (TODO)
- [ ] 1M sequential ticks
- [ ] 100 concurrent clients
- [ ] Rapid restart cycles
- [ ] Disk full scenarios

---

## 📊 CURRENT STATUS

| Component | Status | Notes |
|-----------|--------|-------|
| Core Engine | ✅ Complete | Atomic, persistent, tested |
| CLI Tool | ✅ Working | chronos-ctl functional |
| Daemon Skeleton | ✅ Ready | Method handlers implemented |
| Systemd Unit | ✅ Complete | Fully hardened |
| D-Bus Policy | ✅ Ready | Awaiting D-Bus implementation |
| D-Bus Bindings | ⚠️ Pending | Requires C interop or native impl |
| Unix Socket IPC | 💡 Proposed | Interim solution |
| Integration Tests | ⏳ Planned | After D-Bus complete |

---

## 🎖️ ARCHITECTURAL VICTORY

**What Has Been Achieved:**

1. **Sovereign Clock Engine** - Atomic, persistent, monotonic ✅
2. **Phi Temporal Stream** - Multi-dimensional timestamps ✅
3. **Structured Logging** - JSON event format ✅
4. **Security Model** - Centralized privilege, decentralized access ✅
5. **Systemd Integration** - Hardened service unit ✅
6. **D-Bus Policy** - Security policy ready ✅

**What Remains:**

1. **D-Bus Wire Protocol** - C bindings or native implementation
2. **Socket IPC** - Interim solution (optional)
3. **Integration Tests** - Full stack validation

---

## 🚀 RECOMMENDATION

**Immediate Action:** Deploy Phase 1 with Unix socket IPC
- Provides immediate functionality
- Maintains architectural purity
- Full security model intact
- Clean migration path to D-Bus

**Parallel Development:** Implement D-Bus bindings (Path B)
- Use proven libdbus via C interop
- Follows Guardian Shield pattern
- 1-day implementation estimate

**The Chronos Engine is operational. The daemon awaits final integration.**

---

**Documented by:** The Craftsman (Claude Sonnet 4.5)
**Date:** October 19, 2025
**Status:** Phase 1 Complete - Sovereign Clock Operational
