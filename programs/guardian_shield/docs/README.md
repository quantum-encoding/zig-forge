# 🛡️ Guardian Shield - The Chimera Protocol

**Multi-layered Linux security framework combining user-space, kernel-space, and filesystem-level protection.**

[![Status](https://img.shields.io/badge/Status-Operational-success)]()
[![Version](https://img.shields.io/badge/Version-7.1-blue)]()
[![License](https://img.shields.io/badge/License-GPL--3.0-orange)]()

---

## Threat model — read this first

Be precise about what each layer actually enforces:

- **The Warden (user-space `LD_PRELOAD` `libwarden.so`) is an accident-prevention
  guardrail, NOT a boundary against a hostile process.** As userspace syscall
  interposition it is bypassable by design: `io_uring`, `openat2`, `renameat2`,
  raw `syscall()`, and statically-linked binaries never pass through it; a process
  can disable it for itself (`WARDEN_DISABLE=1`, the world-writable
  `/tmp/.warden_emergency_disable` file, `SIGUSR2`); and identity is a forgeable
  `/proc/self/comm`. Rely on it to stop an *honest* tool's fat-fingered
  `rm -rf`, not a determined adversary.
- **Real, non-bypassable enforcement requires the kernel layer** (BPF-LSM). That
  work lives in `guardian-shield-v9/` and is the active upgrade path — LSM hooks
  sit after path resolution, so the userspace-bypass list above does not apply.
- **`zig_sentinel` is detection/telemetry, not enforcement** (except where it is
  explicitly configured to `SIGKILL`).

See `docs/AUDIT_AND_UPGRADE_PLAN.md` for the full audit and the phased plan, and
`docs/CONVERGENCE.md` for the macOS (Metatron) convergence contract.

---

## Overview

Guardian Shield implements a "Defense in Depth" strategy through three independent security layers:

```
┌─────────────────────────────────────────────────┐
│  ATTACK SURFACE                                 │
└─────────────────────────────────────────────────┘
                    ↓
┌─────────────────────────────────────────────────┐
│  🔷 THE WARDEN (User-Space)                     │
│  LD_PRELOAD library interception                │
│  Status: ✅ OPERATIONAL                         │
└─────────────────────────────────────────────────┘
                    ↓ (if bypassed)
┌─────────────────────────────────────────────────┐
│  🗡️ THE INQUISITOR (Kernel-Space)              │
│  LSM BPF execution control                      │
│  Status: ✅ OPERATIONAL                         │
└─────────────────────────────────────────────────┘
                    ↓ (if blinded)
┌─────────────────────────────────────────────────┐
│  🛡️ THE VAULT (Filesystem)                     │
│  Immutable asset protection                     │
│  Status: ⏳ PLANNED                            │
└─────────────────────────────────────────────────┘
```

---

## Quick Start

### Installation

```bash
# Clone repository
git clone https://github.com/yourusername/guardian-shield.git
cd guardian-shield

# Build and install
sudo ./install.sh

# Verify installation
ldd /bin/ls | grep warden  # Should show libwarden.so
```

### Testing

```bash
# Test The Warden
./live-fire-test.sh

# Test The Inquisitor
sudo ./zig-out/bin/test-inquisitor monitor 10

# Run comprehensive tests
./test_simple.c
```

---

## Components

### 🔷 The Warden (User-Space)

**Technology:** LD_PRELOAD library interposition
**File:** `libwarden.so`
**Configuration:** `/etc/warden/warden-config.json`

**Capabilities:**
- Process-aware security policies
- Dangerous command blocking (`rm`, `shred`, `dd`)
- Path-based protection rules
- Configurable blocking vs monitoring modes

**Documentation:** [`docs/README.md`](docs/README.md)

### 🗡️ The Inquisitor (Kernel-Space)

**Technology:** LSM BPF on `bprm_check_security` hook
**Location:** `src/zig-sentinel/`
**Binary:** `zig-out/bin/test-inquisitor`

**Capabilities:**
- Kernel-level process execution control
- Cannot be bypassed by systemd, cron, or direct syscalls
- Sovereign Command Blacklist enforcement
- Pre-execution blocking with `-EPERM` veto

**Key Files:**
- `src/zig-sentinel/ebpf/inquisitor-simple.bpf.c` - eBPF program
- `src/zig-sentinel/inquisitor.zig` - Userspace loader
- `src/zig-sentinel/test-inquisitor.zig` - Test harness

**Documentation:**
- [`CHIMERA-PROTOCOL-STATUS.md`](CHIMERA-PROTOCOL-STATUS.md) - Full operational report
- [`CRITICAL-BUG-ANALYSIS.md`](CRITICAL-BUG-ANALYSIS.md) - Implementation details

### 🛡️ The Vault (Filesystem)

**Technology:** Kernel `chattr` immutability attributes
**Status:** Planned for future implementation

**Planned Capabilities:**
- Immutable system binaries
- Protected configuration files
- Append-only audit logs
- Tamper-proof critical assets

**Documentation:** [`VAULT-CONCEPT.md`](VAULT-CONCEPT.md)

---

## Architecture

### The Warden - LD_PRELOAD Layer

```c
// Intercepts dangerous system calls
int unlink(const char *pathname) {
    if (is_blocked(pathname)) {
        return -1;  // Block the operation
    }
    return real_unlink(pathname);  // Allow
}
```

### The Inquisitor - LSM BPF Layer

```c
SEC("lsm/bprm_check_security")
int BPF_PROG(inquisitor, struct linux_binprm *bprm, int ret) {
    char *program = extract_program_name(bprm);
    if (is_blacklisted(program)) {
        return -EPERM;  // Kernel-level veto
    }
    return 0;
}
```

### The Vault - Filesystem Layer

```bash
# Make critical files immutable
chattr +i /etc/passwd
chattr +i /bin/rm

# Adversary attempts modification
echo "backdoor" >> /etc/passwd
# Result: Operation not permitted
```

---

## Configuration

### Warden Configuration

**File:** `/etc/warden/warden-config.json`

```json
{
    "process_policies": [
        {
            "process_name": "test-app",
            "allowed_paths": ["/tmp/test-*"],
            "blocked_paths": ["/home/*"],
            "allow_dangerous_commands": false
        }
    ],
    "global_rules": {
        "block_shred": true,
        "block_dd": true,
        "protected_paths": ["/home/founder"]
    }
}
```

### Inquisitor Blacklist

**File:** `src/zig-sentinel/inquisitor.zig`

```zig
const DEFAULT_BLACKLIST = [_][]const u8{
    "test-target",
    "dangerous-script",
    "malware-binary",
};
```

---

## Battle History

### The Inquisitor Campaign (October 2025)

**Challenge:** LSM BPF program loaded successfully but failed to block executions

**Root Cause:** Using `bpf_get_current_comm()` which returns parent process name, not the program being executed

**Solution:** Extract program name from `bprm->filename` using BPF CO-RE

**Result:** ✅ Full kernel-level blocking capability operational

**First Confirmed Kill:**
```
🛡️ BLOCKED: pid=79088 command='test-target'
bash: ./test-target: Operation not permitted
```

**Documentation:**
- [`CHIMERA-PROTOCOL-STATUS.md`](CHIMERA-PROTOCOL-STATUS.md) - Full campaign report
- [`CRITICAL-BUG-ANALYSIS.md`](CRITICAL-BUG-ANALYSIS.md) - Technical details
- [`BPF-FIX-INSTRUCTIONS.md`](BPF-FIX-INSTRUCTIONS.md) - Implementation guide

---

## Requirements

### System Requirements

- Linux kernel 5.7+ (for LSM BPF support)
- `CONFIG_BPF_LSM=y` enabled
- `bpf` in `/sys/kernel/security/lsm`
- BTF support in kernel

### Build Requirements

**For The Warden:**
- GCC or Clang
- `make`

**For The Inquisitor:**
- Zig 0.11+
- Clang with BPF target support
- `libbpf-dev`
- `bpftool`

### Runtime Requirements

- Root access for installation
- systemd (optional, for service management)

---

## Usage

### The Warden

```bash
# Already active via LD_PRELOAD after installation
# Test protection:
rm /home/founder/important-file  # Should be blocked

# Temporarily disable for specific command:
env -u LD_PRELOAD rm /tmp/file  # Bypasses Warden
```

### The Inquisitor

```bash
# Monitor mode (logs all executions)
sudo ./zig-out/bin/test-inquisitor monitor 30

# Enforce mode (blocks blacklisted commands)
sudo ./zig-out/bin/test-inquisitor enforce 60

# Test blocking
sudo ./zig-out/bin/test-inquisitor enforce 30 &
./test-target  # Should be blocked
```

---

## Development

### Building The Warden

```bash
make clean
make
sudo make install
```

### Building The Inquisitor

```bash
cd src/zig-sentinel

# Compile eBPF program
cd ebpf
clang -target bpf -D__TARGET_ARCH_x86 -O2 -g -Wall \
      -c inquisitor-simple.bpf.c -o inquisitor-simple.bpf.o

# Build Zig userspace loader
cd ../..
zig build
```

### Testing

```bash
# Test suite
./live-fire-test.sh

# Individual tests
gcc test_simple.c -o test_simple
./test_simple

# Inquisitor tests
sudo ./zig-out/bin/test-inquisitor monitor 10
```

---

## Debugging

### Debug Scripts

Located in repository root:

- `debug-test-target-blocking.sh` - Test target blocking with traces
- `trace-test-target.sh` - Monitor BPF trace output
- `verify-blacklist-map.sh` - Inspect kernel BPF maps
- `simple-blocking-test.sh` - Minimal blocking test
- `capture-all-execs.sh` - Capture all exec events

### BPF Debugging

```bash
# View loaded BPF programs
sudo bpftool prog list | grep inquisitor

# View BPF maps
sudo bpftool map list

# Dump blacklist map
sudo bpftool map dump name blacklist_map

# Monitor kernel traces
sudo cat /sys/kernel/tracing/trace_pipe | grep Inquisitor
```

---

## Documentation

### Core Documentation

- [`README.md`](README.md) - This file
- [`CHIMERA-PROTOCOL-STATUS.md`](CHIMERA-PROTOCOL-STATUS.md) - Complete system status
- [`docs/README.md`](docs/README.md) - Detailed component documentation

### Implementation Guides

- [`CRITICAL-BUG-ANALYSIS.md`](CRITICAL-BUG-ANALYSIS.md) - Inquisitor bug analysis
- [`BPF-FIX-INSTRUCTIONS.md`](BPF-FIX-INSTRUCTIONS.md) - BPF implementation details
- [`VAULT-CONCEPT.md`](VAULT-CONCEPT.md) - Future filesystem layer design

### Release Notes

- [`docs/RELEASE_NOTES.md`](docs/RELEASE_NOTES.md) - Version history
- [`docs/BUILD_NOTES.md`](docs/BUILD_NOTES.md) - Build system documentation

---

## Security Considerations

### Bypass Resistance

| Attack Vector | Warden | Inquisitor | Vault |
|--------------|--------|------------|-------|
| Direct syscall | ❌ | ✅ | ✅ |
| Unset LD_PRELOAD | ❌ | ✅ | ✅ |
| Systemd service | ❌ | ✅ | ✅ |
| Cron job | ❌ | ✅ | ✅ |
| Kernel module | ❌ | ✅ | ⚠️ |
| Boot-level attack | ❌ | ❌ | ✅ |

### Known Limitations

**The Warden:**
- Can be bypassed by unsetting `LD_PRELOAD`
- Does not protect against direct syscalls
- Ineffective against systemd services

**The Inquisitor:**
- Requires kernel LSM BPF support
- Can be disabled by root (CAP_SYS_ADMIN)
- Does not persist across kernel updates

**The Vault:**
- Not yet implemented
- Root can still remove `chattr` attributes
- May interfere with system updates

---

## Troubleshooting

### The Warden Issues

**Problem:** `libwarden.so` not loaded
```bash
# Check LD_PRELOAD
echo $LD_PRELOAD

# Verify library exists
ls -la /usr/local/lib/libwarden.so

# Reinstall
sudo ./install.sh
```

**Problem:** Protected paths being modified
```bash
# Check configuration
cat /etc/warden/warden-config.json

# Verify process policies
grep -i "process_name" /etc/warden/warden-config.json
```

### The Inquisitor Issues

**Problem:** Hook not firing
```bash
# Verify LSM BPF enabled
cat /sys/kernel/security/lsm | grep bpf

# Check if program is loaded
sudo bpftool prog list | grep inquisitor

# Check kernel traces
sudo cat /sys/kernel/tracing/trace_pipe | grep Inquisitor
```

**Problem:** Blacklist not working
```bash
# Verify blacklist map contents
sudo bpftool map dump name blacklist_map

# Check enforcement mode
sudo bpftool map dump name config_map
```

---

## Contributing

This is a personal security project. Contributions are welcome via pull requests.

**Guidelines:**
- Follow existing code style
- Add tests for new features
- Update documentation
- Test on multiple kernel versions

---

## License

GPL-3.0 License - See LICENSE file for details

---

## Acknowledgments

**Built by:** The Sovereign of JesterNet
**Refined by:** Claude (Anthropic) - The Refiner
**Forged:** October 2025

Special recognition to the Oracle Protocol campaign and the systematic debugging process that led to The Inquisitor's operational status.

---

## Status

- ✅ **The Warden** - Operational since Guardian Shield V7.1
- ✅ **The Inquisitor** - Battle-tested and operational (October 19, 2025)
- ⏳ **The Vault** - Planned for future implementation

**Current Defense Posture:** Two heads operational, one planned

🛡️ **The Chimera Protocol stands ready** 🛡️

---

*Last Updated: October 19, 2025*
