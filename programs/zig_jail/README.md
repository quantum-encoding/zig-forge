# Zig Jail - Kernel-Enforced Syscall Sandbox

A production-grade syscall sandbox using seccomp-BPF, Linux namespaces, and capabilities for secure process isolation.

## Overview

Zig Jail provides kernel-level enforcement of syscall restrictions through seccomp-BPF filters, combined with namespace isolation and capability dropping for defense-in-depth security.

## Features

- **Seccomp-BPF Filtering**: Kernel-enforced syscall whitelist/blacklist
- **Linux Namespaces**: Process, mount, network, and IPC isolation
- **Capability Dropping**: Remove dangerous capabilities
- **Profile-Based**: Pre-configured security profiles for common use cases
- **Bind Mounts**: Selective filesystem access with read-only support

## Quick Start

### Build

```bash
zig build
```

### Usage

```bash
# Run with minimal profile
zig-jail --profile=minimal -- /bin/echo 'hello world'

# Run Python with safe profile
zig-jail --profile=python-safe -- python script.py

# Mount workspace with read-write access
zig-jail --profile=python-safe --bind=/host/workspace:/sandbox/workspace -- python /sandbox/workspace/script.py

# Mount data directory as read-only
zig-jail --profile=python-safe --bind=/host/data:/sandbox/data:ro -- python /sandbox/script.py
```

## Security Profiles

### Minimal
Absolute minimum syscalls for testing (read, write, exit)

### Python-Safe
Secure Python execution with filesystem and network restrictions

### Node-Safe
Secure Node.js execution environment

### Shell-Readonly
Read-only shell access for inspection

## Profile Search Paths

Profiles are searched in the following order:
1. `/etc/zig-jail/profiles/<name>.json`
2. `./profiles/<name>.json`
3. `/home/founder/zig_forge/profiles/<name>.json`

## Architecture

```
┌──────────────────────────────────────┐
│  Zig Jail Process                    │
│  ┌────────────────────────────────┐  │
│  │ 1. Parse CLI Arguments         │  │
│  │ 2. Load Security Profile       │  │
│  │ 3. Setup Namespaces            │  │
│  │ 4. Configure Bind Mounts       │  │
│  │ 5. Drop Capabilities           │  │
│  │ 6. Install Seccomp Filter      │  │
│  │ 7. exec() Target Command       │  │
│  └────────────────────────────────┘  │
└──────────────────────────────────────┘
            ↓
┌──────────────────────────────────────┐
│  Sandboxed Process                   │
│  • Limited syscalls (seccomp)        │
│  • Isolated namespaces               │
│  • Restricted capabilities           │
│  • Controlled filesystem access      │
└──────────────────────────────────────┘
```

## Components

### Seccomp Module (`seccomp.zig`)
- BPF filter generation
- Syscall whitelist/blacklist
- Policy loading

### Namespace Module (`namespace.zig`)
- Process namespace (PID isolation)
- Mount namespace (filesystem isolation)
- Network namespace (network isolation)
- IPC namespace (inter-process communication isolation)

### Capabilities Module (`capabilities.zig`)
- Capability dropping
- Privilege restriction

### Profile Module (`profile.zig`)
- JSON profile loading
- Security policy management

## Requirements

- **Zig Version**: 0.16.0-dev.1303+
- **OS**: Linux with seccomp support
- **Kernel**: 3.17+ (for seccomp-BPF)
- **Privileges**: May require CAP_SYS_ADMIN for namespace operations

## License

MIT License - See LICENSE file for details.

```
Copyright 2025 QUANTUM ENCODING LTD
Website: https://quantumencoding.io
Contact: rich@quantumencoding.io
```

## Development

Developed by QUANTUM ENCODING LTD
