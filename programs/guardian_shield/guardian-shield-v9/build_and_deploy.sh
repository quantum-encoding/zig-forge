#!/usr/bin/env bash
# build_and_deploy.sh
# Comprehensive Guardian Shield build and deployment script

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Configuration
KERNEL_VERSION=$(uname -r)
KERNEL_MIN_VERSION="5.7"
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="${PROJECT_ROOT}/build"
BPF_DIR="${PROJECT_ROOT}/src/ebpf"
OUTPUT_DIR="${PROJECT_ROOT}/zig-out/bin"

echo -e "${GREEN}Guardian Shield V9.0 Build System${NC}"
echo "================================================"

# ===================================================================
# PREREQUISITE CHECKS
# ===================================================================

check_prerequisites() {
    echo -e "${YELLOW}[1/8] Checking prerequisites...${NC}"
    
    # Check kernel version
    CURRENT_VERSION=$(uname -r | cut -d. -f1,2)
    if ! awk -v current="$CURRENT_VERSION" -v min="$KERNEL_MIN_VERSION" \
        'BEGIN { exit (current < min) }'; then
        echo -e "${RED}ERROR: Kernel version $CURRENT_VERSION < $KERNEL_MIN_VERSION${NC}"
        echo "LSM BPF requires kernel 5.7 or later"
        exit 1
    fi
    echo "  ✓ Kernel version: $KERNEL_VERSION"
    
    # Check for LSM BPF support
    if ! grep -q "bpf" /sys/kernel/security/lsm 2>/dev/null; then
        echo -e "${YELLOW}WARNING: LSM BPF not enabled in kernel${NC}"
        echo "  Add 'lsm=...,bpf' to kernel boot parameters"
        echo "  Edit /etc/default/grub and run update-grub"
    else
        echo "  ✓ LSM BPF enabled"
    fi
    
    # Check required tools
    local tools=("clang" "llc" "bpftool" "zig")
    for tool in "${tools[@]}"; do
        if ! command -v "$tool" &> /dev/null; then
            echo -e "${RED}ERROR: $tool not found${NC}"
            echo "Install with: sudo apt install clang llvm libbpf-dev bpftool"
            exit 1
        fi
        echo "  ✓ $tool installed"
    done
    
    # Check libbpf
    if ! pkg-config --exists libbpf; then
        echo -e "${RED}ERROR: libbpf not found${NC}"
        echo "Install with: sudo apt install libbpf-dev"
        exit 1
    fi
    echo "  ✓ libbpf development files"
    
    # Check for vmlinux.h
    if [ ! -f "${BPF_DIR}/vmlinux.h" ]; then
        echo -e "${YELLOW}WARNING: vmlinux.h not found${NC}"
        echo "  Generating vmlinux.h from running kernel..."
        mkdir -p "${BPF_DIR}"
        bpftool btf dump file /sys/kernel/btf/vmlinux format c > "${BPF_DIR}/vmlinux.h"
        echo "  ✓ Generated vmlinux.h"
    else
        echo "  ✓ vmlinux.h present"
    fi
}

# ===================================================================
# BUILD EBPF PROGRAMS
# ===================================================================

build_ebpf_programs() {
    echo -e "${YELLOW}[2/8] Building eBPF programs...${NC}"
    
    mkdir -p "${BUILD_DIR}"
    
    local bpf_sources=(
        "guardian_shield_lsm_filesystem.bpf.c"
        "guardian_shield_lsm_memory.bpf.c"
    )
    
    for src in "${bpf_sources[@]}"; do
        local basename="${src%.bpf.c}"
        local obj="${BUILD_DIR}/${basename}.bpf.o"
        
        echo "  Compiling $src..."
        
        clang -g -O2 -target bpf \
            -D__TARGET_ARCH_x86 \
            -I"${BPF_DIR}" \
            -c "${PROJECT_ROOT}/${src}" \
            -o "$obj" || {
            echo -e "${RED}ERROR: Failed to compile $src${NC}"
            exit 1
        }
        
        echo "  ✓ $obj"
    done
}

# ===================================================================
# BUILD USERSPACE LOADER
# ===================================================================

build_userspace() {
    echo -e "${YELLOW}[3/8] Building userspace loader...${NC}"
    
    zig build-exe "${PROJECT_ROOT}/guardian_shield_loader.zig" \
        -lbpf -lelf -lz \
        --output-dir "${BUILD_DIR}" \
        --name guardian_shield_loader || {
        echo -e "${RED}ERROR: Failed to build userspace loader${NC}"
        exit 1
    }
    
    echo "  ✓ guardian_shield_loader"
}

# ===================================================================
# GENERATE DEFAULT CONFIGURATION
# ===================================================================

generate_config() {
    echo -e "${YELLOW}[4/8] Generating default configuration...${NC}"
    
    cat > "${BUILD_DIR}/guardian_shield.json" <<'EOF'
{
  "protected_paths": [
    "/etc",
    "/usr/bin",
    "/usr/sbin",
    "/usr/local/bin",
    "/usr/local/sbin",
    "/lib",
    "/lib64",
    "/boot",
    "/root/.ssh",
    "/var/lib/dpkg",
    "/var/lib/rpm"
  ],
  "exempt_processes": [
    "dpkg",
    "apt",
    "apt-get",
    "yum",
    "dnf",
    "pacman",
    "systemd",
    "systemctl",
    "install",
    "git",
    "make",
    "gcc",
    "clang",
    "zig",
    "cargo",
    "rustc"
  ],
  "allowed_debuggers": [
    "gdb",
    "lldb",
    "strace",
    "ltrace"
  ],
  "whitelisted_suid": [
    "/usr/bin/sudo",
    "/usr/bin/su",
    "/usr/bin/passwd",
    "/usr/bin/newgrp",
    "/usr/bin/chsh",
    "/usr/bin/chfn"
  ],
  "log_file": "/var/log/guardian_shield.log",
  "verbose": true
}
EOF
    
    echo "  ✓ guardian_shield.json"
}

# ===================================================================
# INSTALL BINARIES
# ===================================================================

install_binaries() {
    echo -e "${YELLOW}[5/8] Installing binaries...${NC}"
    
    # Create installation directories
    sudo mkdir -p /usr/local/lib/guardian_shield
    sudo mkdir -p /usr/local/bin
    sudo mkdir -p /etc/guardian_shield
    
    # Install BPF objects
    sudo cp "${BUILD_DIR}"/*.bpf.o /usr/local/lib/guardian_shield/
    echo "  ✓ Installed BPF objects to /usr/local/lib/guardian_shield/"
    
    # Install loader
    sudo cp "${BUILD_DIR}/guardian_shield_loader" /usr/local/bin/
    sudo chmod 755 /usr/local/bin/guardian_shield_loader
    echo "  ✓ Installed loader to /usr/local/bin/"
    
    # Install configuration (don't overwrite existing)
    if [ ! -f /etc/guardian_shield/config.json ]; then
        sudo cp "${BUILD_DIR}/guardian_shield.json" /etc/guardian_shield/config.json
        echo "  ✓ Installed config to /etc/guardian_shield/config.json"
    else
        echo "  ⚠ Config exists, skipping: /etc/guardian_shield/config.json"
    fi
}

# ===================================================================
# CREATE SYSTEMD SERVICE
# ===================================================================

create_systemd_service() {
    echo -e "${YELLOW}[6/8] Creating systemd service...${NC}"
    
    cat > /tmp/guardian-shield.service <<'EOF'
[Unit]
Description=Guardian Shield LSM BPF Security Framework
After=network.target
Wants=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/guardian_shield_loader /etc/guardian_shield/config.json --verbose
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal

# Security hardening
NoNewPrivileges=false
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/var/log

[Install]
WantedBy=multi-user.target
EOF
    
    sudo mv /tmp/guardian-shield.service /etc/systemd/system/
    sudo chmod 644 /etc/systemd/system/guardian-shield.service
    sudo systemctl daemon-reload
    
    echo "  ✓ Created systemd service"
}

# ===================================================================
# RUN TESTS
# ===================================================================

run_tests() {
    echo -e "${YELLOW}[7/8] Running tests...${NC}"
    
    # Basic smoke test - load and unload
    echo "  Testing BPF program loading..."
    
    cd "${BUILD_DIR}"
    
    # Test filesystem BPF
    if bpftool prog load guardian_shield_lsm_filesystem.bpf.o /sys/fs/bpf/test_fs 2>/dev/null; then
        echo "  ✓ Filesystem BPF loads successfully"
        sudo rm /sys/fs/bpf/test_fs 2>/dev/null || true
    else
        echo -e "${RED}  ✗ Failed to load filesystem BPF${NC}"
        exit 1
    fi
    
    # Test memory BPF
    if bpftool prog load guardian_shield_lsm_memory.bpf.o /sys/fs/bpf/test_mem 2>/dev/null; then
        echo "  ✓ Memory BPF loads successfully"
        sudo rm /sys/fs/bpf/test_mem 2>/dev/null || true
    else
        echo -e "${RED}  ✗ Failed to load memory BPF${NC}"
        exit 1
    fi
}

# ===================================================================
# DISPLAY NEXT STEPS
# ===================================================================

display_next_steps() {
    echo -e "${YELLOW}[8/8] Build complete!${NC}"
    echo ""
    echo -e "${GREEN}Next Steps:${NC}"
    echo "  1. Review configuration:"
    echo "     sudo nano /etc/guardian_shield/config.json"
    echo ""
    echo "  2. Start the service:"
    echo "     sudo systemctl start guardian-shield"
    echo ""
    echo "  3. Enable on boot:"
    echo "     sudo systemctl enable guardian-shield"
    echo ""
    echo "  4. Monitor violations:"
    echo "     sudo journalctl -u guardian-shield -f"
    echo "     sudo tail -f /var/log/guardian_shield.log"
    echo ""
    echo "  5. Check status:"
    echo "     sudo systemctl status guardian-shield"
    echo "     sudo bpftool prog list | grep guardian_shield"
    echo ""
    echo -e "${GREEN}Testing:${NC}"
    echo "  Run the Crucible test suite:"
    echo "     cd crucible && ./run-crucible.sh --full"
    echo ""
    echo -e "${YELLOW}WARNING:${NC} This is a security-critical system."
    echo "Test thoroughly in a development environment first!"
}

# ===================================================================
# MAIN EXECUTION
# ===================================================================

main() {
    check_prerequisites
    build_ebpf_programs
    build_userspace
    generate_config
    
    # Only install if --install flag is provided
    if [[ "${1:-}" == "--install" ]]; then
        install_binaries
        create_systemd_service
        echo ""
        echo -e "${GREEN}Installation complete!${NC}"
    else
        echo ""
        echo -e "${YELLOW}Build complete. Files in ${BUILD_DIR}${NC}"
        echo "Run with --install to install system-wide"
    fi
    
    run_tests
    display_next_steps
}

# ===================================================================
# SCRIPT ENTRY POINT
# ===================================================================

main "$@"
