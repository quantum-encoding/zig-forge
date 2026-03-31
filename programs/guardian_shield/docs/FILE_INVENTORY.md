# Guardian Shield - File Inventory

**Purpose:** Complete catalog of repository files and their functions
**Last Updated:** October 19, 2025

---

## 📚 Core Documentation

### Root Level

| File | Purpose | Status |
|------|---------|--------|
| `README.md` | Main repository documentation | ✅ Current |
| `CHIMERA-PROTOCOL-STATUS.md` | Complete operational status and campaign history | ✅ Current |
| `CRITICAL-BUG-ANALYSIS.md` | Root cause analysis of Inquisitor bug | ✅ Archive |
| `BPF-FIX-INSTRUCTIONS.md` | Technical implementation guide for BPF fix | ✅ Archive |
| `VAULT-CONCEPT.md` | Design document for third security layer | 📋 Planned |
| `FILE_INVENTORY.md` | This file - complete repository catalog | ✅ Current |
| `RELEASE_CHECKLIST.md` | Release readiness verification (100/100) | ✅ Current |
| `ZIG_TRANSMUTATION_STATUS.md` | Zig conversion status and quality assessment | ✅ Current |
| `ZIG_0.16_COMPLIANCE_REPORT.md` | Detailed Zig 0.16 API compliance audit | ✅ Current |

### docs/

| File | Purpose | Status |
|------|---------|--------|
| `docs/README.md` | Detailed component documentation | ✅ Current |
| `docs/RELEASE_NOTES.md` | Version history and changelog | ✅ Current |
| `docs/BUILD_NOTES.md` | Build system documentation | ✅ Current |
| `docs/ZIG_SENTINEL_V5_DESIGN.md` | Zig sentinel architecture | ✅ Archive |
| `docs/ZIG_SENTINEL_V5_COMPLETION_REPORT.md` | V5 completion status | ✅ Archive |
| `docs/SCRIPTORIUM_PROTOCOL.md` | Documentation methodology | ✅ Archive |
| `docs/EMOJI_GUARDIAN_INTEGRATION.md` | Emoji output system design | ✅ Archive |

---

## 🛡️ The Warden (User-Space Component)

### Source Files

| File | Purpose | Language |
|------|---------|----------|
| `guardian_shield.c` | Main LD_PRELOAD library source | C |
| `libwarden.so` | Compiled library (generated) | Binary |

### Configuration

| File | Purpose |
|------|---------|
| `config/warden-config.json` | Production configuration |
| `config/warden-config.example.json` | Template configuration |
| `config/warden-config-v7.1.json` | V7.1 specific config |
| `config/warden-config-docker-test.json` | Docker test configuration |
| `config/README.md` | Configuration documentation |

---

## 🗡️ The Inquisitor (Kernel-Space Component)

### eBPF Programs

| File | Purpose | Status |
|------|---------|--------|
| `src/zig-sentinel/ebpf/inquisitor-simple.bpf.c` | **Production** LSM BPF program | ✅ Operational |
| `src/zig-sentinel/ebpf/inquisitor-simple.bpf.o` | Compiled eBPF object | Generated |
| `src/zig-sentinel/ebpf/inquisitor.bpf.c` | Original (complex) version | 📦 Archive |
| `src/zig-sentinel/ebpf/syscall_counter.bpf.c` | Example syscall counter | 📦 Archive |
| `src/zig-sentinel/ebpf/test-file-open.bpf.c` | LSM hook test program | 🧪 Test |
| `src/zig-sentinel/ebpf/vmlinux.h` | Kernel type definitions (BTF) | Generated |

### Userspace Loader (Zig)

| File | Purpose | Status |
|------|---------|--------|
| `src/zig-sentinel/inquisitor.zig` | Main Inquisitor implementation | ✅ Operational |
| `src/zig-sentinel/test-inquisitor.zig` | Test harness / CLI interface | ✅ Operational |
| `zig-out/bin/test-inquisitor` | Compiled binary | Generated |

### Supporting Files

| File | Purpose |
|------|---------|
| `build.zig` | Zig build configuration |
| `build.zig.zon` | Zig package configuration |

---

## 🧪 Testing & Validation

### Test Programs

| File | Purpose | Language |
|------|---------|----------|
| `test-target.c` | Harmless binary for testing blocks | C |
| `test-target` | Compiled test target | Binary |
| `test_simple.c` | Simple Warden test program | C |
| `test-lsm-attach.c` | LSM attachment test | C |
| `test-file-open-loader.c` | File open hook test | C |

### Test Scripts

| File | Purpose | Status |
|------|---------|--------|
| `live-fire-test.sh` | Comprehensive Warden test suite | ✅ Operational |
| `simple-blocking-test.sh` | Minimal Inquisitor blocking test | ✅ Operational |
| `capture-all-execs.sh` | Capture all exec events for analysis | ✅ Operational |
| `test-without-guardian.sh` | Test without LD_PRELOAD interference | ✅ Operational |

---

## 🔍 Debugging Tools

### Debug Scripts (Created During Inquisitor Campaign)

| File | Purpose | Status |
|------|---------|--------|
| `debug-test-target-blocking.sh` | Test target blocking with trace capture | ✅ Operational |
| `trace-test-target.sh` | Monitor BPF trace during execution | ✅ Operational |
| `verify-blacklist-map.sh` | Inspect kernel BPF maps | ✅ Operational |
| `monitor-bpf-trace.sh` | General BPF trace monitoring | ✅ Operational |

### Oracle Protocol (Historical)

| File | Purpose | Status |
|------|---------|--------|
| `oracle-probe.c` | Systematic LSM hook reconnaissance | 📦 Archive |
| `oracle-probe-template.bpf.c` | Template for hook testing | 📦 Archive |
| `run-oracle.sh` | Oracle execution script | 📦 Archive |
| `oracle-report.txt` | Oracle reconnaissance results | Generated |

**Note:** Oracle Protocol diagnosed "zero viable hooks" (incorrect). Kept for historical reference.

---

## ⚙️ Installation & Deployment

### Installation Scripts

| File | Purpose | Status |
|------|---------|--------|
| `install.sh` | Main installation script | ✅ Operational |
| `uninstall.sh` | Removal script | ✅ Operational |
| `deploy.sh` | Deployment automation | ✅ Operational |

### System Configuration

| File | Purpose |
|------|---------|
| `fix-audit-rate-limit.sh` | Audit system configuration fix |
| `/etc/ld.so.preload` | System-wide LD_PRELOAD config (created by install) |
| `/etc/warden/warden-config.json` | Runtime Warden configuration |

---

## 🐳 Docker Support

### Docker Files

| File | Purpose | Status |
|------|---------|--------|
| `docker_setup_v6.sh` | V6 Docker setup | 📦 Archive |
| `run_v6_docker_test.sh` | V6 Docker test runner | 📦 Archive |
| `scripts/run_v6_simple.sh` | Simple V6 test | 📦 Archive |
| `scripts/test_v6_citadel.sh` | V6 Citadel test | 📦 Archive |

---

## 📋 Build System

### Build Files

| File | Purpose |
|------|---------|
| `Makefile` | Warden build configuration |
| `build.zig` | Inquisitor build configuration |
| `.gitignore` | Git ignore rules |

### Generated Artifacts

| Path | Contents |
|------|----------|
| `zig-out/` | Zig build artifacts |
| `zig-cache/` | Zig build cache |
| `.zig-cache/` | Additional Zig cache |
| `*.o` | Compiled object files |
| `*.so` | Shared libraries |

---

## 🔧 Configuration

### Claude Code Settings

| File | Purpose |
|------|---------|
| `.claude/settings.local.json` | Claude Code IDE configuration |

---

## 📊 File Organization Summary

### By Status

- **✅ Operational:** Core system files, currently in use
- **🧪 Test:** Testing and validation files
- **🔍 Debug:** Debugging and diagnostic tools
- **📦 Archive:** Historical files, kept for reference
- **📋 Planned:** Future implementation designs
- **Generated:** Build artifacts, auto-generated

### By Component

```
guardian-shield/
├── Core Documentation (6 files)
├── The Warden (2 source + 5 config)
├── The Inquisitor (6 eBPF + 3 Zig)
├── Testing Suite (7 test programs)
├── Debug Tools (8 debug scripts)
├── Installation (4 scripts)
├── Documentation Archive (8 docs)
└── Build System (3 configs)
```

---

## 🗑️ Cleanup Recommendations

### Safe to Remove (If Desired)

**Oracle Protocol artifacts:**
- `oracle-probe.c`
- `oracle-probe-template.bpf.c`
- `run-oracle.sh`
- `oracle-report.txt`

**Reason:** Historical reconnaissance tool with incorrect diagnosis. Kept for documentation purposes only.

**V6 Docker files:**
- `docker_setup_v6.sh`
- `run_v6_docker_test.sh`
- `scripts/run_v6_*`

**Reason:** Superseded by current implementation.

### Keep Everything

All files serve either:
1. Operational purpose (core system)
2. Testing/debugging purpose (validation)
3. Historical/educational purpose (documentation)

**Recommendation:** Keep all files for complete repository history.

---

## 🎯 Key Files for Release

### Must Have

1. `README.md` - Entry point
2. `CHIMERA-PROTOCOL-STATUS.md` - System status
3. `libwarden.so` / `guardian_shield.c` - The Warden
4. `src/zig-sentinel/` - The Inquisitor
5. `config/warden-config.example.json` - Configuration template
6. `install.sh` / `uninstall.sh` - Installation
7. `docs/README.md` - Detailed documentation

### Recommended

8. `CRITICAL-BUG-ANALYSIS.md` - Implementation insights
9. `VAULT-CONCEPT.md` - Future roadmap
10. Test scripts for validation
11. Debug scripts for troubleshooting

---

## 📝 Notes

**Repository State:** Production-ready with comprehensive documentation

**Known Generated Files:**
- `*.o`, `*.so` - Build artifacts
- `zig-out/`, `zig-cache/` - Build directories
- `vmlinux.h` - Generated from kernel BTF

**Required for Compilation:**
- Full `src/` directory tree
- All `.zig` and `.c` source files
- Build configuration files

---

**Inventory Compiled:** October 19, 2025
**Total Files Documented:** 60+ files
**Repository Status:** ✅ RELEASE READY

🛡️ **The Chimera Protocol Documentation Complete** 🛡️
