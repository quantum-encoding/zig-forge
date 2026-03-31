#!/bin/bash
# Guardian Shield - Uninstallation Script

set -e

INSTALL_DIR="/usr/local/lib/security"
CONFIG_DIR="/etc/warden"

echo "╔════════════════════════════════════════════════════════════╗"
echo "║  Guardian Shield - Uninstallation                         ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo "❌ This script must be run as root (use sudo)"
    exit 1
fi

# Warn user
echo "⚠️  This will remove Guardian Shield from your system."
echo
read -p "Are you sure you want to continue? (yes/no): " -r
echo

if [[ ! $REPLY =~ ^[Yy][Ee][Ss]$ ]]; then
    echo "Uninstallation cancelled."
    exit 0
fi

# Remove LD_PRELOAD from shell configs
echo "[CLEANUP] Checking shell configurations..."
for user_home in /home/*; do
    if [ -f "$user_home/.bashrc" ]; then
        if grep -q "LD_PRELOAD.*libwarden.so" "$user_home/.bashrc"; then
            echo "⚠️  Found LD_PRELOAD in $user_home/.bashrc"
            echo "   Please manually remove or comment out the line:"
            echo "   export LD_PRELOAD=\"$INSTALL_DIR/libwarden.so\""
        fi
    fi
done
echo

# Backup config before removal
if [ -f "$CONFIG_DIR/warden-config.json" ]; then
    BACKUP_NAME="warden-config.json.backup.$(date +%Y%m%d_%H%M%S)"
    echo "[BACKUP] Backing up configuration..."
    mkdir -p "$INSTALL_DIR/backup"
    cp "$CONFIG_DIR/warden-config.json" "$INSTALL_DIR/backup/$BACKUP_NAME"
    echo "✓ Config backed up to: $INSTALL_DIR/backup/$BACKUP_NAME"
    echo
fi

# Remove library
if [ -f "$INSTALL_DIR/libwarden.so" ]; then
    echo "[REMOVE] Removing libwarden.so..."
    rm -f "$INSTALL_DIR/libwarden.so"
    echo "✓ Removed: $INSTALL_DIR/libwarden.so"
fi

# Remove configuration
if [ -f "$CONFIG_DIR/warden-config.json" ]; then
    echo "[REMOVE] Removing configuration..."
    rm -f "$CONFIG_DIR/warden-config.json"
    echo "✓ Removed: $CONFIG_DIR/warden-config.json"

    # Remove config directory if empty
    if [ -z "$(ls -A "$CONFIG_DIR")" ]; then
        rmdir "$CONFIG_DIR"
        echo "✓ Removed empty directory: $CONFIG_DIR"
    fi
fi

echo
echo "╔════════════════════════════════════════════════════════════╗"
echo "║  Uninstallation Complete                                  ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo
echo "✓ Guardian Shield has been removed"
echo
echo "⚠️  Important:"
echo "   1. Open a new terminal or unset LD_PRELOAD:"
echo "      unset LD_PRELOAD"
echo
echo "   2. Remove LD_PRELOAD from your shell config if present"
echo
echo "   3. Backups are preserved at: $INSTALL_DIR/backup/"
echo
