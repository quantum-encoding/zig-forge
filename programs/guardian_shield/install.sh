#!/bin/bash
# Guardian Shield - Installation Script
# Installs libwarden.so system-wide with secure defaults

set -e

INSTALL_DIR="/usr/local/lib/security"
CONFIG_DIR="/etc/warden"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "╔════════════════════════════════════════════════════════════╗"
echo "║  Guardian Shield - Installation                           ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo "❌ This script must be run as root (use sudo)"
    exit 1
fi

# Check prerequisites
echo "[CHECK] Verifying prerequisites..."

if ! command -v zig &> /dev/null; then
    echo "❌ Zig compiler not found. Please install Zig first:"
    echo "   https://ziglang.org/download/"
    exit 1
fi

echo "✓ Zig compiler found: $(zig version)"
echo

# Build libwarden
echo "[BUILD] Compiling libwarden.so..."
cd "$SCRIPT_DIR"
zig build -Doptimize=ReleaseSafe

if [ ! -f "zig-out/lib/libwarden.so" ]; then
    echo "❌ Build failed - libwarden.so not found"
    exit 1
fi

echo "✓ Build successful"
echo

# Create directories
echo "[INSTALL] Creating directories..."
mkdir -p "$INSTALL_DIR"
mkdir -p "$INSTALL_DIR/backup"
mkdir -p "$CONFIG_DIR"
echo "✓ Directories created"
echo

# Backup existing installation
if [ -f "$INSTALL_DIR/libwarden.so" ]; then
    BACKUP_NAME="libwarden.so.backup.$(date +%Y%m%d_%H%M%S)"
    echo "[BACKUP] Backing up existing libwarden.so..."
    cp "$INSTALL_DIR/libwarden.so" "$INSTALL_DIR/backup/$BACKUP_NAME"
    echo "✓ Backed up to: $INSTALL_DIR/backup/$BACKUP_NAME"
    echo
fi

# Install library
echo "[INSTALL] Installing libwarden.so..."
cp zig-out/lib/libwarden.so "$INSTALL_DIR/libwarden.so"
chmod 644 "$INSTALL_DIR/libwarden.so"
echo "✓ Installed to: $INSTALL_DIR/libwarden.so"
echo

# Install configuration
if [ ! -f "$CONFIG_DIR/warden-config.json" ]; then
    echo "[CONFIG] Installing default configuration..."
    cp config/warden-config.example.json "$CONFIG_DIR/warden-config.json"
    chmod 644 "$CONFIG_DIR/warden-config.json"
    echo "✓ Installed config to: $CONFIG_DIR/warden-config.json"
    echo "⚠️  Please review and customize the configuration!"
else
    echo "[CONFIG] Configuration already exists at: $CONFIG_DIR/warden-config.json"
    echo "⚠️  To update, manually merge changes from: config/warden-config.example.json"
fi
echo

# Verify installation
echo "[VERIFY] Verifying installation..."
if nm -D "$INSTALL_DIR/libwarden.so" | grep -q "open\|unlink\|rename"; then
    echo "✓ Library symbols verified"
else
    echo "❌ Library verification failed"
    exit 1
fi
echo

echo "╔════════════════════════════════════════════════════════════╗"
echo "║  Installation Complete                                    ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo
echo "📍 Files installed:"
echo "   Library:  $INSTALL_DIR/libwarden.so"
echo "   Config:   $CONFIG_DIR/warden-config.json"
echo
echo "🔧 Next Steps:"
echo
echo "1. Review and customize the configuration:"
echo "   sudo nano $CONFIG_DIR/warden-config.json"
echo
echo "2. Enable protection by adding to your shell profile (~/.bashrc or ~/.zshrc):"
echo "   export LD_PRELOAD=\"$INSTALL_DIR/libwarden.so\""
echo
echo "3. Open a new terminal or run:"
echo "   source ~/.bashrc"
echo
echo "4. Test the protection:"
echo "   python3 -c \"import os; os.remove('/etc/passwd')\""
echo "   (Should see: [libwarden.so] 🛡️ BLOCKED unlink: /etc/passwd)"
echo
echo "📚 Documentation: $SCRIPT_DIR/README.md"
echo "⚙️  Configuration Guide: $SCRIPT_DIR/config/README.md"
echo
echo "⚠️  Security Note:"
echo "   The shield protects against accidental damage and basic attacks."
echo "   It is NOT a substitute for proper access controls and security practices."
echo
