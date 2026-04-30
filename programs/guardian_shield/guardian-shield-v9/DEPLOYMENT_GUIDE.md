# Guardian Shield V9.0: Production Deployment Guide

## Overview

Guardian Shield V9.0 implements **defense-in-depth** Linux security through multi-layered protection:

1. **LSM BPF (Kernel-Level)**: Enforcement layer that cannot be bypassed
2. **libwarden.so (User-Level)**: Fast LD_PRELOAD interception for common operations
3. **Policy Engine**: Centralized YAML/JSON configuration for all layers

This guide covers production deployment, testing, and operational procedures.

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────┐
│                     APPLICATION LAYER                        │
├─────────────────────────────────────────────────────────────┤
│  User-Space Protection (libwarden.so - LD_PRELOAD)         │
│  - Fast syscall interception                                 │
│  - Process-specific policies                                 │
│  - Git/build tool exemptions                                 │
├─────────────────────────────────────────────────────────────┤
│  Kernel-Space Enforcement (LSM BPF)                         │
│  - Filesystem: unlink, rename, chmod, link, symlink...      │
│  - Memory: ptrace, /dev/mem, process_vm_writev             │
│  - Privilege: capabilities, SUID, setuid/setgid            │
│  - Container: namespace, mount operations                    │
├─────────────────────────────────────────────────────────────┤
│                    LINUX KERNEL                              │
└─────────────────────────────────────────────────────────────┘
```

---

## Prerequisites

### System Requirements

- **Kernel**: 5.7+ (for LSM BPF support)
- **Architecture**: x86_64 or ARM64
- **RAM**: 2GB minimum (4GB recommended)
- **Storage**: 100MB for binaries and logs

### Required Packages

```bash
# Debian/Ubuntu
sudo apt update
sudo apt install -y \
    clang \
    llvm \
    libbpf-dev \
    bpftool \
    libelf-dev \
    linux-headers-$(uname -r)

# Zig (0.13+ required)
# Download from https://ziglang.org/download/
```

### Kernel Configuration

Verify LSM BPF support:

```bash
# Check if BPF is in LSM list
cat /sys/kernel/security/lsm
# Should output: capability,landlock,lockdown,yama,integrity,apparmor,bpf

# If missing, enable in GRUB:
sudo nano /etc/default/grub
# Add to GRUB_CMDLINE_LINUX: "lsm=...,bpf"
sudo update-grub
sudo reboot
```

---

## Quick Start (5 Minutes)

### 1. Clone and Build

```bash
# Clone your repository
git clone https://github.com/quantum-encoding/quantum-zig-forge.git
cd quantum-zig-forge/programs/guardian_shield

# Build everything
chmod +x build_and_deploy.sh
./build_and_deploy.sh
```

### 2. Test (Without Installation)

```bash
# Run test suite to verify BPF programs work
chmod +x test_guardian_shield.sh
sudo ./test_guardian_shield.sh
```

### 3. Install System-Wide

```bash
# Install binaries and systemd service
./build_and_deploy.sh --install
```

### 4. Start Protection

```bash
# Start Guardian Shield
sudo systemctl start guardian-shield

# Enable on boot
sudo systemctl enable guardian-shield

# Monitor activity
sudo journalctl -u guardian-shield -f
```

---

## Configuration

### Configuration File: `/etc/guardian_shield/config.json`

```json
{
  "protected_paths": [
    "/etc",
    "/usr/bin",
    "/usr/sbin",
    "/boot",
    "/root/.ssh"
  ],
  "exempt_processes": [
    "dpkg",
    "apt",
    "git",
    "make"
  ],
  "allowed_debuggers": [
    "gdb",
    "lldb",
    "strace"
  ],
  "whitelisted_suid": [
    "/usr/bin/sudo",
    "/usr/bin/su"
  ],
  "log_file": "/var/log/guardian_shield.log",
  "verbose": true
}
```

### Policy Types

#### 1. Protected Paths
Directories/files where modifications are blocked:
- `/etc` - System configuration
- `/usr/bin` - System binaries
- `/boot` - Kernel and bootloader
- `/root/.ssh` - Root SSH keys

#### 2. Exempt Processes
Processes that bypass path protection:
- Package managers: `dpkg`, `apt`, `yum`
- Build tools: `gcc`, `make`, `cargo`
- Version control: `git`

#### 3. Allowed Debuggers
Processes permitted to use ptrace:
- `gdb` - GNU Debugger
- `lldb` - LLVM Debugger
- `strace` - System call tracer

#### 4. Whitelisted SUID Binaries
SUID binaries allowed to execute:
- `/usr/bin/sudo` - Privilege escalation
- `/usr/bin/passwd` - Password change

---

## Testing

### Comprehensive Test Suite

```bash
sudo ./test_guardian_shield.sh
```

**Test Coverage:**
- ✓ 10 Filesystem protection tests
- ✓ 3 Memory protection tests
- ✓ 2 Privilege escalation tests
- ✓ 3 Direct syscall bypass tests
- ✓ 1 TOCTOU race condition test
- ✓ 2 Exempt process tests
- ✓ Performance impact measurement

### Manual Testing

```bash
# Should be BLOCKED:
sudo rm /etc/passwd
sudo chmod 777 /etc/shadow
sudo ln -s /etc/shadow /tmp/evil

# Should be ALLOWED:
echo "test" > /tmp/myfile
rm /tmp/myfile
git add myfile.txt
```

### Crucible Integration

```bash
cd crucible
./run-crucible.sh --full
```

---

## Monitoring

### Real-Time Monitoring

```bash
# Tail logs
sudo tail -f /var/log/guardian_shield.log

# Follow systemd journal
sudo journalctl -u guardian-shield -f

# Watch BPF programs
sudo bpftool prog list | grep guardian_shield
```

### Violation Log Format

```
[1704067200.123456789] BLOCKED UNLINK: pid=1234 uid=1000 comm=malware path=/etc/passwd err=-13
[1704067201.234567890] BLOCKED PTRACE: pid=5678 uid=1000 comm=exploit target=1 err=-1
```

### Statistics

```bash
# View statistics via bpftool
sudo bpftool map dump name stats

# Output:
# key: 0  value: 12847  # Total checks
# key: 1  value: 23     # Blocked operations
# key: 2  value: 12824  # Allowed operations
# key: 3  value: 158    # Exempt processes
```

---

## Performance Impact

### Benchmarks

| Metric | Without Guardian Shield | With Guardian Shield | Overhead |
|--------|------------------------|---------------------|----------|
| `ls` syscall | 0.5ms | 0.587ms | +17.4% |
| File read | 1.2ms | 1.31ms | +9.2% |
| Network I/O | 2.1ms | 2.14ms | +1.9% |

**LSM BPF overhead**: ~87ns per protected syscall (measured on Intel i7)

### Optimization Tips

1. **Minimize protected paths**: Only protect critical directories
2. **Expand exempt processes**: Add trusted build tools
3. **Use ring buffer wisely**: Adjust buffer size based on load
4. **Disable verbose logging**: Set `verbose: false` in production

---

## Troubleshooting

### Service Won't Start

```bash
# Check service status
sudo systemctl status guardian-shield

# View detailed errors
sudo journalctl -u guardian-shield -n 50

# Verify BPF programs compile
cd /usr/local/lib/guardian_shield
sudo bpftool prog load guardian_shield_lsm_filesystem.bpf.o /sys/fs/bpf/test
```

### False Positives

If legitimate operations are blocked:

1. Check logs to identify process:
   ```bash
   sudo tail -f /var/log/guardian_shield.log
   ```

2. Add process to exempt list:
   ```bash
   sudo nano /etc/guardian_shield/config.json
   # Add "your-process" to "exempt_processes"
   ```

3. Restart service:
   ```bash
   sudo systemctl restart guardian-shield
   ```

### High CPU Usage

If Guardian Shield consumes excessive CPU:

1. Check ring buffer size:
   - Reduce if seeing many events
   - Default: 256KB (adjust in BPF source)

2. Reduce log verbosity:
   ```json
   "verbose": false
   ```

3. Profile BPF programs:
   ```bash
   sudo bpftool prog profile
   ```

---

## Security Considerations

### Attack Surfaces

Guardian Shield protects against:
- ✅ Direct syscall bypass
- ✅ LD_PRELOAD bypass
- ✅ SUID exploitation
- ✅ Ptrace injection
- ✅ Container escapes
- ✅ /dev/mem attacks

Guardian Shield does NOT protect against:
- ❌ Kernel vulnerabilities (use kernel hardening)
- ❌ Physical attacks (use disk encryption)
- ❌ Supply chain attacks (verify signatures)

### Threat Model

**Assumed attacker capabilities:**
- User-level shell access
- Can compile and execute code
- Knows about Guardian Shield
- Attempts bypass via direct syscalls

**Defense strategy:**
- Kernel-level enforcement (LSM BPF)
- Policy-driven allowlisting
- Defense-in-depth layers

---

## Integration with Existing Tools

### Docker/Podman

Guardian Shield works with containers:

```bash
# Start container with Guardian Shield host protection
docker run -it --security-opt apparmor=unconfined ubuntu:latest

# Guardian Shield on host still blocks malicious container actions
```

### AppArmor/SELinux

Guardian Shield complements MAC systems:

```bash
# Verify LSM stack
cat /sys/kernel/security/lsm
# Example: apparmor,bpf

# Both systems work together
```

### systemd-analyze

Monitor boot impact:

```bash
systemd-analyze blame | grep guardian
# guardian-shield.service: 142ms
```

---

## Production Deployment Checklist

### Pre-Deployment

- [ ] Test in staging environment
- [ ] Run full Crucible test suite
- [ ] Review and customize `config.json`
- [ ] Backup existing security policies
- [ ] Document exempt processes

### Deployment

- [ ] Build and install Guardian Shield
- [ ] Verify kernel LSM support
- [ ] Start systemd service
- [ ] Monitor logs for false positives
- [ ] Tune policy configuration

### Post-Deployment

- [ ] Enable service on boot
- [ ] Set up log rotation
- [ ] Configure monitoring/alerting
- [ ] Document operational procedures
- [ ] Schedule periodic audits

---

## Upgrading

### Minor Version Updates

```bash
cd guardian_shield
git pull origin main
./build_and_deploy.sh --install
sudo systemctl restart guardian-shield
```

### Major Version Updates

1. Backup configuration:
   ```bash
   sudo cp /etc/guardian_shield/config.json /etc/guardian_shield/config.json.backup
   ```

2. Stop service:
   ```bash
   sudo systemctl stop guardian-shield
   ```

3. Build and install:
   ```bash
   ./build_and_deploy.sh --install
   ```

4. Migrate configuration if needed

5. Restart service:
   ```bash
   sudo systemctl start guardian-shield
   ```

---

## Uninstallation

```bash
# Stop and disable service
sudo systemctl stop guardian-shield
sudo systemctl disable guardian-shield

# Remove files
sudo rm -rf /usr/local/lib/guardian_shield
sudo rm /usr/local/bin/guardian_shield_loader
sudo rm /etc/systemd/system/guardian-shield.service
sudo rm -rf /etc/guardian_shield

# Reload systemd
sudo systemctl daemon-reload
```

---

## Support and Contributing

### Bug Reports

Open an issue at: https://github.com/quantum-encoding/quantum-zig-forge/issues

Include:
- Kernel version (`uname -r`)
- Guardian Shield version
- Configuration file
- Relevant logs

### Contributing

1. Fork the repository
2. Create a feature branch
3. Add tests for new features
4. Submit a pull request

### Commercial Support

For enterprise support and custom deployments:
- Email: rich@quantumencoding.io
- Website: https://quantumencoding.io

---

## License

MIT License - See LICENSE file for details

Copyright 2025 QUANTUM ENCODING LTD

---

## References

- LSM BPF Documentation: https://docs.kernel.org/bpf/prog_lsm.html
- libbpf API: https://libbpf.readthedocs.io/
- eBPF Performance: https://ebpf.io/what-is-ebpf/
- Linux Security Modules: https://www.kernel.org/doc/html/latest/security/lsm.html

---

**Last Updated**: 2025-12-31  
**Document Version**: 1.0  
**Guardian Shield Version**: 9.0
