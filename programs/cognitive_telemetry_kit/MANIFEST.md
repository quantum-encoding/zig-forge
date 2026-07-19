# Cognitive Telemetry Kit - Package Manifest

## Version
1.0.0 - "The Final Apotheosis"

## Release Date
October 28, 2025

> **Note (current layout).** This manifest below documents the original Linux
> eBPF capture package under `src/` only. The maintained kit is now the
> two-plane architecture in `README.md` → "Current architecture", built by the
> top-level `build.zig`. The actively-developed components are:
>
> | Component | Role |
> |---|---|
> | `chronos-ledger/` | Tamper-evident hash chain + RFC 8785 canonicaliser + ML-DSA-65 signing + C-ABI + detection engine (the crown jewel; see `chronos-ledger/DESIGN.md`) |
> | `chronos-hook/` | Global git `PostToolUse` hook: process-ancestry agent attribution, `[CHRONOS:<agent>]` tick, non-blocking ledger emit |
> | `ledger-daemon/` | Privileged UDS sink: chains + signs event bodies, appends NDJSON |
> | `ledger-verify/` | CLI: replays the NDJSON ledger through the shared detector (CI gate) |
> | `cognitive-tools/` | `cognitive-export` / `-stats` / `-query` over the SQLite DB |
> | `libcognitive-capture/` | macOS DYLD `write()` interposer → `/tmp/cognitive-state-<pid>` |
> | `get-cognitive-state/` | macOS reader of the capture file (used by chronos-hook) |
> | `cognitive-state-server/` | Linux-only in-memory D-Bus oracle over the DB |
> | `cognitive-ingest/` | Reads the capture file, inserts into SurrealDB over HTTP |
> | `src/` | **Legacy** Linux eBPF/C capture stack (below) — not built by the top-level `build.zig` |

## Package Contents

### Source Files (`src/`) — legacy Linux eBPF capture stack
- `cognitive-watcher-v2.c` - Userspace daemon (15KB)
- `cognitive-oracle-v2.bpf.c` - eBPF kernel program (8.5KB)
- `chronos-stamp-cognitive-direct.zig` - Timestamp generator (11KB)
- `chronos_client_dbus.zig` - DBus client for chronos daemon (7.8KB)
- `dbus_bindings.zig` - DBus FFI bindings (8.2KB)
- `get-cognitive-state` - State extraction script (3.8KB)
- `build.zig` - Zig build configuration (7.8KB)

### Configuration (`config/`)
- `cognitive-watcher.service` - Systemd service unit file

### Scripts (`scripts/`)
- `install.sh` - Automated installation script

### Documentation (`docs/`)
- `README.md` - Main documentation
- `LICENSE-GPL` - GPL-3.0 license for open source use
- `LICENSE-COMMERCIAL` - Commercial license terms
- `MANIFEST.md` - This file

### Binaries (`bin/`)
Pre-compiled binaries (created during installation):
- `cognitive-watcher` - Compiled from cognitive-watcher-v2.c
- `cognitive-oracle-v2.bpf.o` - Compiled eBPF object
- `chronos-stamp` - Compiled from chronos-stamp-cognitive-direct.zig

## System Requirements

### Operating System
- Linux kernel 5.10+ with eBPF support
- systemd-based distribution

### Dependencies
- libbpf (development headers)
- SQLite3
- Zig compiler 0.11.0+
- GCC
- clang (for eBPF compilation)

### Runtime Requirements
- Root/sudo access for installation
- eBPF capabilities (CAP_BPF, CAP_PERFMON, CAP_NET_ADMIN, CAP_SYS_RESOURCE)
- /var/lib/cognitive-watcher (created during installation)
- /usr/local/bin (for binaries)

## Installation

```bash
cd cognitive-telemetry-kit
sudo ./scripts/install.sh
```

## Verification

After installation:
```bash
# Service status
systemctl status cognitive-watcher

# Test chronos-stamp
chronos-stamp claude-code test "verification"

# Check database
sqlite3 /var/lib/cognitive-watcher/cognitive-states.db \
  "SELECT COUNT(*) FROM cognitive_states;"
```

## File Checksums (SHA256)

Generated during build. Verify with:
```bash
cd cognitive-telemetry-kit
sha256sum src/* config/* scripts/*
```

## Architecture

```
┌─────────────────────────────────────────────────────┐
│                  Claude Code Process                 │
│                                                       │
│  Status Line: > Verifying git commits (esc...)       │
└────────────────────┬────────────────────────────────┘
                     │ TTY Write
                     ↓
┌─────────────────────────────────────────────────────┐
│            Kernel (eBPF kprobe on tty_write)         │
│                                                       │
│         cognitive-oracle-v2.bpf.o                    │
└────────────────────┬────────────────────────────────┘
                     │ Ring Buffer
                     ↓
┌─────────────────────────────────────────────────────┐
│              Userspace Daemon                        │
│                                                       │
│           cognitive-watcher-v2                       │
│  - Consumes ring buffer events                       │
│  - No keyword filtering                              │
│  - Writes to SQLite database                         │
└────────────────────┬────────────────────────────────┘
                     │
                     ↓
┌─────────────────────────────────────────────────────┐
│          /var/lib/cognitive-watcher/                 │
│          cognitive-states.db                         │
│                                                       │
│  PID | Timestamp | Raw Content                       │
│  486529 | ... | > Verifying git commits (esc...)     │
│  459577 | ... | > Julienning (esc...)                │
└────────────────────┬────────────────────────────────┘
                     │
                     ↓
┌─────────────────────────────────────────────────────┐
│            get-cognitive-state                       │
│  - Queries database for PID                          │
│  - Filters for "(esc to interrupt" pattern           │
│  - Extracts cognitive state text                     │
└────────────────────┬────────────────────────────────┘
                     │
                     ↓
┌─────────────────────────────────────────────────────┐
│              chronos-stamp                           │
│  - Called by git hooks                               │
│  - Gets cognitive state                              │
│  - Injects into CHRONOS timestamp                    │
└────────────────────┬────────────────────────────────┘
                     │
                     ↓
┌─────────────────────────────────────────────────────┐
│               Git Commit Message                     │
│                                                       │
│  [CHRONOS] 2025-10-28T11:12:09...                    │
│  ::claude-code::Verifying git commits::TICK-...      │
└─────────────────────────────────────────────────────┘
```

## License

Dual-licensed under:
- GPL-3.0 (for individuals and open source)
- Commercial License (for Anthropic and commercial use)

See LICENSE-GPL and LICENSE-COMMERCIAL for details.

## Author

Richard Tune
Quantum Encoding Ltd
rich@quantumencoding.io

## Acknowledgments

Built in collaboration with Claude Code.
Codename: "The Final Apotheosis"

THE UNWRIT MOMENT IS NOW.
