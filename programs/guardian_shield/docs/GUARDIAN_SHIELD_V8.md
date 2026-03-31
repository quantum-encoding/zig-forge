# Guardian Shield V8.0 - Path Fortress

## Overview

Guardian Shield V8.0 represents a major evolution in filesystem protection. The "Path Fortress" release introduces comprehensive defense against path hijacking attacks, runtime configuration management, and a powerful CLI for protecting your projects.

## What's New in V8.0

### Path Hijacking Defense (8 New Syscall Interceptors)

V8.0 intercepts **17 syscalls** (up from 9 in V7.2), adding critical protections against sophisticated attacks:

| Syscall | Attack Vector Blocked |
|---------|----------------------|
| `symlink` / `symlinkat` | Symlink hijacking - attacker creates symlink to malicious binary |
| `link` / `linkat` | Hardlink privilege escalation - preserving vulnerable setuid binaries |
| `truncate` / `ftruncate` | Data destruction - zeroing files when delete is blocked |
| `mkdir` / `mkdirat` | Path injection - creating directories in PATH locations |

### wardenctl CLI

New command-line tool for runtime configuration management:

```bash
wardenctl <command> [options]
```

### SIGHUP Hot-Reload

Update configuration without restarting protected processes:

```bash
wardenctl reload
# or manually:
kill -HUP <pid>
```

### Protection Templates

Quick-apply common protection patterns with a single command.

---

## Installation

```bash
cd /path/to/guardian_shield
sudo ./deploy.sh
```

This will:
1. Build libwarden.so and wardenctl
2. Verify all 17 syscall exports
3. Install to `/usr/local/lib/security/` and `/usr/local/bin/`

---

## wardenctl Command Reference

### Protect Current Directory

```bash
# Protect current working directory with read-only template
wardenctl add -p . --read-only

# Protect current directory with custom flags
wardenctl add -p . --no-delete --no-move
```

### Protection Templates

Templates provide pre-configured protection profiles:

| Template | Flags | Use Case |
|----------|-------|----------|
| `--template safe` | `--no-delete --no-move` | Prevent accidental deletion/move |
| `--template dev` | `--no-delete --no-move --no-truncate` | Development projects |
| `--template readonly` | `--read-only` | Full immutability |
| `--template production` | `--read-only` + process restrictions | Production deployments |

```bash
# Protect project with "dev" template
wardenctl add -p /home/user/myproject --template dev

# Protect with "safe" template (blocks delete and move only)
wardenctl add -p . --template safe
```

### All Commands

```bash
# Add protected path
wardenctl add --path /some/path [flags]
wardenctl add -p . --template dev           # Current directory with template

# Remove protected path (requires sudo)
sudo wardenctl remove --path /some/path

# List all protected paths
wardenctl list

# Reload config in running processes
wardenctl reload

# Show status and protected process count
wardenctl status
wardenctl status --verbose                   # Show process names

# Test if operation would be blocked
wardenctl test /etc/passwd delete
wardenctl test /home/user/project all

# Show version
wardenctl version

# Show help
wardenctl help
```

### Protection Flags

| Flag | Blocks | Description |
|------|--------|-------------|
| `--no-delete` | unlink, unlinkat, rmdir | Prevent file/directory deletion |
| `--no-move` | rename, renameat | Prevent moving/renaming |
| `--no-truncate` | truncate, ftruncate | Prevent zeroing file contents |
| `--no-write` | open_write | Prevent opening files for writing |
| `--no-symlink` | symlink, symlinkat, symlink_target | Block symlink creation |
| `--no-link` | link, linkat | Block hardlink creation |
| `--no-mkdir` | mkdir, mkdirat | Block directory creation |
| `--read-only` | All of the above | Complete immutability |

### Examples

```bash
# Protect a Git repository from accidental deletion
wardenctl add -p ~/projects/myrepo --no-delete --no-move

# Make config directory completely read-only
wardenctl add -p /etc/myapp --read-only

# Protect against symlink attacks on /usr/local/bin
wardenctl add -p /usr/local/bin --no-symlink --no-link

# Test what happens when trying to delete /etc/passwd
wardenctl test /etc/passwd delete
# Output: ❌ Operation 'delete' would be BLOCKED

# Check current protection status
wardenctl status --verbose
```

---

## Protection Templates (Profiles)

### Built-in Templates

#### Template: `safe`
Basic protection against accidental damage.
```
--no-delete --no-move
```
Use case: Everyday project protection

#### Template: `dev`
Development environment protection.
```
--no-delete --no-move --no-truncate
```
Use case: Source code, build artifacts

#### Template: `readonly`
Complete immutability.
```
--read-only
```
Use case: Configuration files, certificates, production data

#### Template: `production`
Maximum security with process awareness.
```
--read-only + block untrusted processes
```
Use case: Production deployments, sensitive systems

### Quick Start with Templates

```bash
# Start a new project and protect it immediately
cd ~/projects
mkdir myproject && cd myproject
git init
wardenctl add -p . --template dev

# From now on, this directory is protected:
# - Cannot delete files
# - Cannot move/rename files
# - Cannot truncate files
# - But CAN create new files and modify existing ones

# To remove protection (requires sudo):
sudo wardenctl remove -p .
```

---

## How It Works

### LD_PRELOAD Interception

Guardian Shield uses `LD_PRELOAD` to intercept syscalls before they reach the kernel:

```
Application → glibc → libwarden.so → Kernel
                          ↓
                    Check against
                    warden-config.json
                          ↓
                    Allow or Block
```

### Configuration File

Protection rules are stored in `/etc/warden/warden-config.json`:

```json
{
  "protection": {
    "protected_paths": [
      {
        "path": "/etc/",
        "description": "System configuration",
        "block_operations": ["unlink", "rmdir", "open_write", "symlink", "link"]
      }
    ],
    "whitelisted_paths": [
      {
        "path": "/tmp/",
        "description": "Temporary files always allowed"
      }
    ]
  }
}
```

### Hot-Reload Mechanism

1. Edit configuration (or use `wardenctl add/remove`)
2. Run `wardenctl reload`
3. SIGHUP sent to all processes with libwarden.so loaded
4. Each process atomically swaps to new config

---

## Security Model

### Privilege Escalation Protection

Removing protection requires `sudo`:

```bash
# This fails without sudo
wardenctl remove -p /protected/path
# Error: Permission denied - sudo required to remove protection

# This works
sudo wardenctl remove -p /protected/path
```

### Process Exemptions

Trusted build tools bypass checks for performance:
- `rustc`, `cargo`, `zig`, `gcc`, `g++`
- `make`, `cmake`, `go`, `java`, `javac`

### Attack Vectors Blocked

| Attack | How V8.0 Stops It |
|--------|-------------------|
| Symlink hijacking | `symlink` interceptor blocks creation in protected paths |
| Hardlink privilege escalation | `link` interceptor prevents hardlinks to protected files |
| Data destruction via truncate | `truncate` interceptor blocks zeroing protected files |
| PATH injection via mkdir | `mkdir` interceptor blocks directory creation in PATH |
| Dotfile poisoning | Process-specific restrictions on `.bashrc`, `.zshrc` |
| /tmp execution | `execve` interceptor blocks execution from /tmp |

---

## Troubleshooting

### Check if Protection is Active

```bash
echo $LD_PRELOAD
# Should show: /usr/local/lib/security/libwarden.so

wardenctl status
# Shows: 🛡️ N process(es) protected by Guardian Shield
```

### View Blocked Operations

Protected processes print to stderr when operations are blocked:
```
[libwarden.so] 🛡️ BLOCKED unlink: /etc/passwd
```

### Test Without Blocking

```bash
wardenctl test /some/path operation
```

### Temporarily Disable (Development Only)

```bash
# For a single command:
env -u LD_PRELOAD some_command

# For a shell session:
unset LD_PRELOAD
```

---

## Version History

### V8.0 - Path Fortress (Current)
- 8 new syscall interceptors (symlink, link, truncate, mkdir families)
- wardenctl CLI for runtime management
- SIGHUP hot-reload
- Protection templates
- Granular permission flags

### V7.2 - Process Exemptions
- Build tool exemptions for performance
- Living Citadel directory protection

### V7.1 - Process-Aware Security
- Per-process restrictions
- Dotfile protection
- /tmp execution blocking

---

## Files

| File | Purpose |
|------|---------|
| `/usr/local/lib/security/libwarden.so` | Core protection library |
| `/usr/local/bin/wardenctl` | CLI management tool |
| `/etc/warden/warden-config.json` | Configuration file |
| `~/.config/warden/` | User-specific overrides (optional) |

---

## License

Guardian Shield is dual-licensed:
- **MIT License** for non-commercial use
- **Commercial License** for commercial deployments

Contact: info@quantumencoding.io
