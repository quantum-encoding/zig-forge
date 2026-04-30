#!/bin/bash
# deploy.sh - Secure deployment protocol for libwarden.so V8.0
# Purpose: Deploy Guardian Shield V8.0 with Full Path Hijacking Defense
#
# CRITICAL SAFETY FEATURES:
# 1. Exclusive lock (flock) prevents race conditions during deployment
# 2. Atomic file replacement (build -> verify -> swap)
# 3. Rollback capability if verification fails
# 4. Zero-downtime deployment (old library stays active until verified)
#
# V8.0 NEW FEATURES:
# - Path hijacking defense (symlink, link, truncate, mkdir interceptors)
# - SIGHUP config hot-reload
# - wardenctl CLI management tool
# - Granular permission flags (--no-delete, --no-move, --read-only, etc.)

set -e  # Exit on any error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
LOCK_FILE="/var/lock/libwarden_deploy.lock"
INSTALL_DIR="/usr/local/lib/security"
BACKUP_DIR="/usr/local/lib/security/backup"
LIBRARY_NAME="libwarden.so"

# Auto-detect project directory (script location)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="${PROJECT_DIR:-$SCRIPT_DIR}"

echo -e "${BLUE}╔════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║  Guardian Shield V8.0 - Secure Deployment Protocol        ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════════════════════════╝${NC}"
echo ""

# Check if running as root
if [ "$EUID" -ne 0 ]; then
   echo -e "${RED}[ERROR] This script must be run as root (use sudo)${NC}"
   exit 1
fi

# Function to acquire exclusive lock
acquire_lock() {
    echo -e "${YELLOW}[LOCK] Acquiring deployment lock...${NC}"

    # Create lock file with exclusive access
    exec 200>"$LOCK_FILE"

    # Try to acquire lock (with timeout)
    if ! flock -x -w 30 200; then
        echo -e "${RED}[ERROR] Could not acquire lock within 30 seconds${NC}"
        echo -e "${RED}        Another deployment may be in progress${NC}"
        exit 1
    fi

    echo -e "${GREEN}[LOCK] ✓ Deployment lock acquired${NC}"
}

# Function to release lock
release_lock() {
    echo -e "${YELLOW}[LOCK] Releasing deployment lock...${NC}"
    flock -u 200
    echo -e "${GREEN}[LOCK] ✓ Lock released${NC}"
}

# Ensure lock is released on exit
trap release_lock EXIT

# Step 1: Acquire exclusive lock (prevents race conditions)
acquire_lock

# Step 2: Build the new library
echo ""
echo -e "${YELLOW}[BUILD] Compiling Guardian Shield V8.0...${NC}"
cd "$PROJECT_DIR"
/usr/local/zig/zig build

if [ ! -f "zig-out/lib/libwarden.so" ]; then
    echo -e "${RED}[ERROR] Build failed - libwarden.so not found${NC}"
    exit 1
fi

echo -e "${GREEN}[BUILD] ✓ Compilation successful${NC}"

# Step 3: Verify the library
echo ""
echo -e "${YELLOW}[VERIFY] Checking library integrity...${NC}"

# Check if it's a valid ELF shared library
if ! file zig-out/lib/libwarden.so | grep -q "ELF.*shared object"; then
    echo -e "${RED}[ERROR] Invalid library format${NC}"
    exit 1
fi

# Verify exported symbols - V8.0 includes path hijacking defense syscalls
REQUIRED_SYMBOLS=("unlink" "unlinkat" "rmdir" "open" "openat" "rename" "renameat" "chmod" "execve" "symlink" "symlinkat" "link" "linkat" "truncate" "ftruncate" "mkdir" "mkdirat")
for symbol in "${REQUIRED_SYMBOLS[@]}"; do
    if ! nm -D zig-out/lib/libwarden.so | grep -q " T $symbol$"; then
        echo -e "${RED}[ERROR] Missing required symbol: $symbol${NC}"
        exit 1
    fi
done

# Verify V8.0 version string
if ! strings zig-out/lib/libwarden.so | grep -q "Guardian Shield V8"; then
    echo -e "${RED}[ERROR] V8.x version string not found in library${NC}"
    exit 1
fi

echo -e "${GREEN}[VERIFY] ✓ Library integrity confirmed${NC}"
echo -e "${GREEN}[VERIFY] ✓ All 17 syscall hooks present${NC}"
echo -e "${GREEN}[VERIFY] ✓ V8.0 version confirmed (Path Fortress - Full Hijacking Defense)${NC}"

# Step 4: Create backup directory
echo ""
echo -e "${YELLOW}[BACKUP] Creating backup of current library...${NC}"
mkdir -p "$BACKUP_DIR"

# Backup old library if it exists
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
if [ -f "$INSTALL_DIR/$LIBRARY_NAME" ]; then
    cp "$INSTALL_DIR/$LIBRARY_NAME" "$BACKUP_DIR/${LIBRARY_NAME}.$TIMESTAMP"
    echo -e "${GREEN}[BACKUP] ✓ Backed up existing $LIBRARY_NAME${NC}"

    # Show version of backed up library
    if strings "$BACKUP_DIR/${LIBRARY_NAME}.$TIMESTAMP" | grep -q "Guardian Shield V3"; then
        echo -e "${BLUE}[BACKUP]   Previous version: V3${NC}"
    fi
else
    echo -e "${YELLOW}[BACKUP] No existing library to backup${NC}"
fi

# Step 5: Atomic installation
echo ""
echo -e "${YELLOW}[INSTALL] Installing Guardian Shield V8.0...${NC}"

# Ensure target directory exists
mkdir -p "$INSTALL_DIR"

# Copy with temporary name first (atomic operation)
cp zig-out/lib/libwarden.so "$INSTALL_DIR/${LIBRARY_NAME}.new"

# Verify the copy
if ! cmp -s zig-out/lib/libwarden.so "$INSTALL_DIR/${LIBRARY_NAME}.new"; then
    echo -e "${RED}[ERROR] File copy verification failed${NC}"
    rm -f "$INSTALL_DIR/${LIBRARY_NAME}.new"
    exit 1
fi

# Atomic move (replaces old file instantly)
mv -f "$INSTALL_DIR/${LIBRARY_NAME}.new" "$INSTALL_DIR/$LIBRARY_NAME"

# Set proper permissions
chmod 755 "$INSTALL_DIR/$LIBRARY_NAME"
chown root:root "$INSTALL_DIR/$LIBRARY_NAME"

echo -e "${GREEN}[INSTALL] ✓ Guardian Shield V8.0 installed to $INSTALL_DIR${NC}"

# Step 5b: Install wardenctl CLI tool
echo ""
echo -e "${YELLOW}[INSTALL] Installing wardenctl CLI...${NC}"

if [ -f "zig-out/bin/wardenctl" ]; then
    cp zig-out/bin/wardenctl /usr/local/bin/wardenctl.new
    mv -f /usr/local/bin/wardenctl.new /usr/local/bin/wardenctl
    chmod 755 /usr/local/bin/wardenctl
    chown root:root /usr/local/bin/wardenctl
    echo -e "${GREEN}[INSTALL] ✓ wardenctl installed to /usr/local/bin${NC}"
else
    echo -e "${YELLOW}[INSTALL] ⚠ wardenctl not found - skipping CLI installation${NC}"
fi

# Step 6: System-wide preload configuration (BATTLE-PROVEN in Crucible)
echo ""
echo -e "${YELLOW}[CONFIG] Configuring system-wide protection via /etc/ld.so.preload...${NC}"

# Use /etc/ld.so.preload for system-wide protection
# This is CRITICAL - LD_PRELOAD env var does NOT protect SSH sessions, cron, systemd
PRELOAD_FILE="/etc/ld.so.preload"
PRELOAD_ENTRY="$INSTALL_DIR/$LIBRARY_NAME"

# Check if already configured
if [ -f "$PRELOAD_FILE" ] && grep -q "$PRELOAD_ENTRY" "$PRELOAD_FILE"; then
    echo -e "${GREEN}[CONFIG] ✓ /etc/ld.so.preload already configured${NC}"
else
    # Backup existing preload file if it exists
    if [ -f "$PRELOAD_FILE" ]; then
        cp "$PRELOAD_FILE" "$BACKUP_DIR/ld.so.preload.$TIMESTAMP"
        echo -e "${BLUE}[CONFIG] Backed up existing /etc/ld.so.preload${NC}"
    fi

    # Add libwarden to system-wide preload
    echo "$PRELOAD_ENTRY" >> "$PRELOAD_FILE"
    chmod 644 "$PRELOAD_FILE"
    chown root:root "$PRELOAD_FILE"
    echo -e "${GREEN}[CONFIG] ✓ Added to /etc/ld.so.preload (system-wide protection)${NC}"
fi

echo -e "${GREEN}[CONFIG] ✓ ALL processes now protected (SSH, cron, systemd, etc.)${NC}"

# Also keep LD_PRELOAD in shell for backward compatibility
echo ""
echo -e "${YELLOW}[CONFIG] Optional: Shell LD_PRELOAD (for backward compatibility)${NC}"
echo -e "${YELLOW}[CONFIG] Add to your shell rc file if needed:${NC}"
echo -e "   ${BLUE}export LD_PRELOAD=\"$INSTALL_DIR/$LIBRARY_NAME\"${NC}"

# Step 7: Deployment summary
echo ""
echo -e "${BLUE}╔════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║  Deployment Complete                                       ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${GREEN}✓ Guardian Shield V8.0 deployed successfully${NC}"
echo -e "${GREEN}✓ NEW: Path Fortress - Full Path Hijacking Defense${NC}"
echo -e "${GREEN}✓ NEW: symlink/link interception (blocks symlink/hardlink attacks)${NC}"
echo -e "${GREEN}✓ NEW: truncate/mkdir interception (blocks data destruction & path injection)${NC}"
echo -e "${GREEN}✓ NEW: SIGHUP hot-reload (wardenctl reload)${NC}"
echo -e "${GREEN}✓ NEW: wardenctl CLI for runtime config management${NC}"
echo -e "${GREEN}✓ Process Exemptions: Build tools bypass ALL checks for performance${NC}"
echo -e "${GREEN}✓ Living Citadel: Directory structures protected, internal operations allowed${NC}"
echo -e "${GREEN}✓ Git Compatible: .git/index.lock and other internal operations work${NC}"
echo -e "${GREEN}✓ Memory Safe: No segfaults, no use-after-free, c_allocator${NC}"
echo -e "${GREEN}✓ Protected syscalls (17): unlink, unlinkat, rmdir, open, openat, rename,${NC}"
echo -e "${GREEN}                           renameat, chmod, execve, symlink, symlinkat,${NC}"
echo -e "${GREEN}                           link, linkat, truncate, ftruncate, mkdir, mkdirat${NC}"
echo -e "${GREEN}✓ Backups saved to: $BACKUP_DIR${NC}"
echo ""
echo -e "${GREEN}⚡ System-wide protection is NOW ACTIVE via /etc/ld.so.preload${NC}"
echo ""
echo -e "${YELLOW}Verification:${NC}"
echo -e "   1. Run any command - you should see the Guardian Shield banner"
echo -e "   2. Test wardenctl: ${BLUE}wardenctl status${NC}"
echo -e "   3. SSH sessions are protected (battle-proven in Crucible)"
echo -e "   4. Cron jobs are protected"
echo -e "   5. Systemd services are protected"
echo ""
echo -e "${YELLOW}wardenctl Commands:${NC}"
echo -e "   ${BLUE}wardenctl list${NC}                          # Show protected paths"
echo -e "   ${BLUE}wardenctl add --path /data --read-only${NC}  # Add protected path"
echo -e "   ${BLUE}wardenctl remove --path /data${NC}           # Remove protection"
echo -e "   ${BLUE}wardenctl reload${NC}                        # Hot-reload config"
echo -e "   ${BLUE}wardenctl test /etc/passwd delete${NC}       # Test if blocked"
echo ""
echo -e "${GREEN}The Guardian Shield V8.0 is now active.${NC}"
echo ""

# Rollback instructions
echo -e "${YELLOW}Rollback to previous version (if needed):${NC}"
echo -e "   sudo cp $BACKUP_DIR/${LIBRARY_NAME}.$TIMESTAMP $INSTALL_DIR/$LIBRARY_NAME"
echo ""
echo -e "${YELLOW}Disable Guardian Shield entirely (emergency):${NC}"
echo -e "   sudo rm /etc/ld.so.preload"
echo -e "   # Or remove just libwarden line:"
echo -e "   sudo sed -i '\\|$INSTALL_DIR/$LIBRARY_NAME|d' /etc/ld.so.preload"
echo ""
