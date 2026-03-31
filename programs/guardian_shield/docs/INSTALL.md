# Guardian Shield - Installation Guide

> **Guardian Shield V7.2**: eBPF-based System Security Framework with Living Citadel + Process-Aware Security

## Overview

Guardian Shield provides kernel-level protection for critical system paths through LD_PRELOAD syscall interception. This guide will walk you through installation, configuration, and customization.

## Prerequisites

### Required Tools

1. **Zig Compiler** (0.11.0 or later)
   ```bash
   # Install from https://ziglang.org/download/
   # Recommended location: /usr/local/zig/
   ```

2. **System Requirements**
   - Linux kernel 2.6+ (for eBPF features: 4.4+)
   - Root access (sudo) for installation
   - Basic build tools (file, nm, strings, cmp)

3. **Optional: Configuration Tools**
   - JSON viewer/editor for config customization
   - Text editor for shell rc file modifications

---

## Quick Start Installation

### 1. Clone the Repository

```bash
git clone https://github.com/your-org/guardian-shield.git
cd guardian-shield
```

### 2. Build Guardian Shield

```bash
/usr/local/zig/zig build
```

This compiles:
- `libwarden.so` - Core syscall interception library
- `libwarden-fork.so` - Fork bomb protection
- `zig-sentinel` - eBPF threat detection engine

### 3. Deploy (Root Required)

```bash
sudo ./deploy.sh
```

The deployment script will:
- ✅ Build the library with verification
- ✅ Backup existing installation (if present)
- ✅ Install to `/usr/local/lib/security/`
- ✅ Verify library integrity and symbols
- ✅ Provide LD_PRELOAD configuration instructions

### 4. Activate Protection

Add to your shell configuration file:

**Bash** (`~/.bashrc`):
```bash
export LD_PRELOAD="/usr/local/lib/security/libwarden.so"
```

**Zsh** (`~/.zshrc`):
```zsh
export LD_PRELOAD="/usr/local/lib/security/libwarden.so"
```

**Fish** (`~/.config/fish/config.fish`):
```fish
set -x LD_PRELOAD "/usr/local/lib/security/libwarden.so"
```

Then reload your shell:
```bash
source ~/.bashrc  # or ~/.zshrc for zsh
```

### 5. Verify Installation

Open a new terminal and check:
```bash
echo $LD_PRELOAD
# Should output: /usr/local/lib/security/libwarden.so
```

You should see the activation message:
```
[libwarden.so] 🛡️ Guardian Shield V7.2 active (Process Exemptions for Build Tools)
```

---

## Configuration

### Default Protection

Out of the box, Guardian Shield protects:
- **System paths**: `/etc/`, `/boot/`, `/sys/`, `/proc/`
- **System binaries**: `/usr/bin/`, `/usr/lib/`
- **Block devices**: `/dev/sda`, `/dev/nvme`, `/dev/vd`

### Configuration File Locations

1. **Production**: `/etc/warden/warden-config.json`
2. **Development**: `./config/warden-config.json` (project directory)

Guardian Shield checks these locations in order and uses the first found.

### Customizing Protection

#### Option 1: Use Example Config as Base

```bash
# Copy example config
sudo mkdir -p /etc/warden
sudo cp config/warden-config-v7.1.json /etc/warden/warden-config.json

# Edit with your paths
sudo nano /etc/warden/warden-config.json
```

#### Option 2: Add Your Paths

The example configs are minimal and only protect system-critical paths. To add your own:

**Whitelist User Directories** (allow operations):
```json
{
  "protection": {
    "whitelisted_paths": [
      {
        "path": "/home/username/tmp/",
        "description": "User temporary directory"
      },
      {
        "path": "/home/username/sandbox/",
        "description": "Safe experimentation area"
      },
      {
        "path": "/home/username/projects/*/build/",
        "description": "Build artifacts (Zig, Rust, etc.)"
      }
    ]
  }
}
```

**Protect Project Directories** (Living Citadel - V7.0+):
```json
{
  "directory_protection": {
    "enabled": true,
    "protected_roots": [
      "/home/username/projects",
      "/home/username/github",
      "/home/username/work"
    ],
    "protected_patterns": [
      "**/.git"
    ]
  }
}
```

**Living Citadel** protects directory *structures* (prevents deletion/renaming of directories) while allowing normal file operations inside them.

### Advanced: Process-Aware Security (V7.1+)

Restrict specific processes (like untrusted AI agents):

```json
{
  "process_restrictions": {
    "enabled": true,
    "restricted_processes": [
      {
        "name": "untrusted-agent",
        "restrictions": {
          "block_tmp_write": true,
          "block_tmp_execute": true,
          "block_dotfile_write": true,
          "monitored_dotfiles": [".bashrc", ".zshrc", ".ssh/config"]
        }
      }
    ]
  }
}
```

---

## Testing Protection

### Test 1: System Path Protection

```bash
# This should be BLOCKED:
rm /etc/hostname
# Expected: 🛡️ BLOCKED: rm: cannot remove '/etc/hostname': Operation not permitted
```

### Test 2: Normal Operations

```bash
# This should work normally:
touch /tmp/test.txt
rm /tmp/test.txt
# Expected: No blocking, operations succeed
```

### Test 3: Directory Protection (V7.0+)

```bash
# If you added /home/username/projects to protected_roots:
rm -rf ~/projects/my-project/
# Expected: 🛡️ BLOCKED (directory structure protected)

# But this works:
rm ~/projects/my-project/some-file.txt
# Expected: File deleted normally (internal operations allowed)
```

---

## Build Tool Performance (V7.2+)

**NEW in V7.2**: Build tools are fully exempt from all checks for maximum performance.

Exempt processes:
- `rustc`, `cargo`
- `zig`
- `gcc`, `g++`, `clang`
- `make`, `cmake`, `ninja`
- `go`, `javac`, `java`

These processes bypass ALL Guardian Shield checks, eliminating any performance overhead during compilation.

---

## Rollback / Uninstallation

### Rollback to Previous Version

After deployment, backups are saved with timestamps:
```bash
sudo cp /usr/local/lib/security/backup/libwarden.so.YYYYMMDD_HHMMSS \
        /usr/local/lib/security/libwarden.so
source ~/.bashrc
```

### Complete Uninstallation

1. Remove LD_PRELOAD from your shell rc file
2. Remove the library:
   ```bash
   sudo rm /usr/local/lib/security/libwarden.so
   sudo rm /etc/warden/warden-config.json  # optional
   ```
3. Reload shell:
   ```bash
   source ~/.bashrc
   ```

---

## Troubleshooting

### Issue: "Guardian Shield not active" after sourcing

**Check**:
```bash
echo $LD_PRELOAD
```

**Fix**: Ensure the path is correct and the file exists:
```bash
ls -l /usr/local/lib/security/libwarden.so
```

### Issue: Build tools are slow (V7.1 or earlier)

**Solution**: Upgrade to V7.2 with Process Exemptions:
```bash
git pull origin master
sudo ./deploy.sh
```

### Issue: Legitimate operations are blocked

**Solution**: Add paths to `whitelisted_paths` in `/etc/warden/warden-config.json`

### Issue: Git operations failing

**Check**: Guardian Shield V7.0+ includes git compatibility (`.git/index.lock` is whitelisted)

**If still blocked**: Add your git worktree to `whitelisted_paths`:
```json
{
  "path": "/home/username/projects/",
  "description": "Git repositories"
}
```

### Issue: False positives from process restrictions

**Solution**: Disable or adjust `process_restrictions` in config:
```json
{
  "process_restrictions": {
    "enabled": false
  }
}
```

---

## Standard Tool Locations

If using Guardian Shield's companion tools (summon_agent, AI_CONDUCTOR), they expect:

- **Zig compiler**: `/usr/local/zig/zig`
- **libwarden.so**: `/usr/local/lib/security/libwarden.so`
- **Config file**: `/etc/warden/warden-config.json`

These are the standard locations used by Guardian Shield ecosystem tools.

---

## Security Notes

1. **Root Requirement**: Installation requires root for:
   - Writing to `/usr/local/lib/security/`
   - Setting proper ownership (root:root)
   - Setting permissions (755)

2. **LD_PRELOAD Scope**: Protection is active only for processes in shells where `LD_PRELOAD` is set

3. **Not a Silver Bullet**: Guardian Shield provides syscall-level protection but is not a complete security solution. Use defense-in-depth strategies.

4. **Kernel eBPF**: Full eBPF threat detection (`zig-sentinel`) requires kernel 4.4+ and may need additional privileges

---

## Support

- **Issues**: https://github.com/your-org/guardian-shield/issues
- **Documentation**: https://github.com/your-org/guardian-shield/docs
- **License**: MIT (see LICENSE file)

---

## Version History

- **V7.2**: Process Exemptions for build tools (zero overhead compilation)
- **V7.1**: Process-Aware Security ("Whitelist of the Damned")
- **V7.0**: Living Citadel (directory structure protection)
- **V3.0**: Multi-dimensional threat correlation
- **V1.0**: Core syscall interception

---

**Guardian Shield** - Kernel-level protection for the modern threat landscape.

© 2025 Richard Tune / Quantum Encoding Ltd
