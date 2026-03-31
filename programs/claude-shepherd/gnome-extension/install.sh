#!/bin/bash
#
# Install Claude Shepherd GNOME Extension
#

set -e

EXTENSION_UUID="claude-shepherd@quantum-forge"
EXTENSION_DIR="$HOME/.local/share/gnome-shell/extensions/$EXTENSION_UUID"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SOURCE_DIR="$SCRIPT_DIR/$EXTENSION_UUID"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

echo "Installing Claude Shepherd GNOME Extension..."

# Create extension directory
mkdir -p "$EXTENSION_DIR"

# Copy extension files
cp -r "$SOURCE_DIR"/* "$EXTENSION_DIR/"

echo "Extension installed to: $EXTENSION_DIR"

# Check if gnome-extensions command exists
if command -v gnome-extensions &> /dev/null; then
    echo ""
    echo "Enabling extension..."
    gnome-extensions enable "$EXTENSION_UUID" 2>/dev/null || true
    echo ""
    echo "Extension enabled. You may need to restart GNOME Shell:"
    echo "  - Press Alt+F2, type 'r', and press Enter (X11)"
    echo "  - Or log out and back in (Wayland)"
else
    echo ""
    echo "Please enable the extension manually:"
    echo "  gnome-extensions enable $EXTENSION_UUID"
    echo ""
    echo "Or use GNOME Extensions app / Extension Manager"
fi

# Ask about system-wide installation
echo ""
read -p "Install binaries system-wide? (requires sudo) [y/N] " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo "Installing binaries to /usr/local/bin..."
    sudo cp "$PROJECT_DIR/zig-out/bin/claude-shepherd" /usr/local/bin/
    sudo cp "$PROJECT_DIR/zig-out/bin/claude-shepherd-ebpf" /usr/local/bin/
    sudo cp "$PROJECT_DIR/zig-out/bin/shepherd" /usr/local/bin/
    sudo cp "$PROJECT_DIR/zig-out/bin/shepherd.bpf.o" /usr/local/lib/ 2>/dev/null || true

    # Install PolicyKit policy for eBPF mode
    if [ -f "$SCRIPT_DIR/org.quantum-forge.claude-shepherd.policy" ]; then
        echo "Installing PolicyKit policy..."
        sudo cp "$SCRIPT_DIR/org.quantum-forge.claude-shepherd.policy" /usr/share/polkit-1/actions/
    fi

    echo "System-wide installation complete!"
    echo ""
    echo "You can now start the daemon from anywhere:"
    echo "  claude-shepherd -d           # Polling mode"
    echo "  sudo claude-shepherd-ebpf -d # eBPF mode (or use GUI button)"
else
    echo ""
    echo "Skipping system-wide installation."
    echo ""
    echo "Make sure claude-shepherd daemon is in your PATH:"
    echo "  export PATH=\"\$PATH:$PROJECT_DIR/zig-out/bin\""
fi

echo ""
echo "Usage:"
echo "  - Click the panel icon to see status"
echo "  - Use 'Start (Polling Mode)' for no-root operation"
echo "  - Use 'Start (eBPF Mode)' for kernel-level monitoring (will prompt for password)"
echo ""
echo "CLI commands:"
echo "  shepherd status        # Show status"
echo "  shepherd policy list   # List permission rules"
echo "  shepherd queue \"task\" # Queue a task"
