#!/bin/bash
# Cognitive Telemetry Kit - Installation Script
# Copyright (c) 2025 Richard Tune / Quantum Encoding Ltd

set -e

echo "🔮 COGNITIVE TELEMETRY KIT - Installation"
echo "=========================================="
echo ""

# Check for root
if [ "$EUID" -ne 0 ]; then
    echo "❌ Please run as root (sudo ./install.sh)"
    exit 1
fi

# Check dependencies
echo "📋 Checking dependencies..."
MISSING_DEPS=""

command -v gcc >/dev/null 2>&1 || MISSING_DEPS="$MISSING_DEPS gcc"
command -v zig >/dev/null 2>&1 || MISSING_DEPS="$MISSING_DEPS zig"
command -v sqlite3 >/dev/null 2>&1 || MISSING_DEPS="$MISSING_DEPS sqlite3"

if [ -n "$MISSING_DEPS" ]; then
    echo "❌ Missing dependencies:$MISSING_DEPS"
    echo "   Install with: sudo pacman -S $MISSING_DEPS (Arch) or equivalent"
    exit 1
fi

# Check for libbpf
if ! pkg-config --exists libbpf 2>/dev/null; then
    echo "❌ libbpf not found. Install with: sudo pacman -S libbpf (Arch) or equivalent"
    exit 1
fi

echo "✅ All dependencies satisfied"
echo ""

# Build watcher
echo "🔨 Building cognitive-watcher..."
cd src
gcc -o ../bin/cognitive-watcher cognitive-watcher-v2.c -lbpf -lsqlite3 -lcrypto
if [ $? -ne 0 ]; then
    echo "❌ Failed to build cognitive-watcher"
    exit 1
fi
echo "✅ cognitive-watcher built"

# Build eBPF program
echo "🔨 Building eBPF program..."
clang -O2 -target bpf -c cognitive-oracle-v2.bpf.c -o ../bin/cognitive-oracle-v2.bpf.o
if [ $? -ne 0 ]; then
    echo "❌ Failed to build eBPF program"
    exit 1
fi
echo "✅ eBPF program built"

# Build chronos-stamp
echo "🔨 Building chronos-stamp..."
cd ..
zig build
if [ $? -ne 0 ]; then
    echo "❌ Failed to build chronos-stamp"
    exit 1
fi
cp zig-out/bin/chronos-stamp-cognitive-direct bin/chronos-stamp
echo "✅ chronos-stamp built"

# Install binaries
echo "📦 Installing binaries..."
install -m 755 bin/cognitive-watcher /usr/local/bin/
install -m 755 bin/chronos-stamp /usr/local/bin/
install -m 755 src/get-cognitive-state /usr/local/bin/
install -m 644 bin/cognitive-oracle-v2.bpf.o /usr/local/lib/
echo "✅ Binaries installed to /usr/local/bin"

# Create database directory
echo "📁 Creating database directory..."
mkdir -p /var/lib/cognitive-watcher
chmod 755 /var/lib/cognitive-watcher
echo "✅ Database directory created"

# Install systemd service
echo "⚙️  Installing systemd service..."
cat > /etc/systemd/system/cognitive-watcher.service <<'EOF'
[Unit]
Description=Cognitive Watcher V2 - eBPF TTY Subsystem Monitor for Claude Cognitive States
Documentation=https://quantumencoding.io
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/cognitive-watcher
WorkingDirectory=/var/lib/cognitive-watcher
Restart=always
RestartSec=10

# Security
NoNewPrivileges=false
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/sys/fs/bpf /var/lib/cognitive-watcher

# eBPF requires elevated privileges
AmbientCapabilities=CAP_BPF CAP_PERFMON CAP_NET_ADMIN CAP_SYS_RESOURCE

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable cognitive-watcher
echo "✅ Systemd service installed"

# Start service
echo "🚀 Starting cognitive-watcher service..."
systemctl start cognitive-watcher
sleep 2

if systemctl is-active --quiet cognitive-watcher; then
    echo "✅ Service started successfully"
else
    echo "❌ Service failed to start. Check: journalctl -u cognitive-watcher -n 50"
    exit 1
fi

echo ""
echo "🎉 INSTALLATION COMPLETE!"
echo ""
echo "The Cognitive Telemetry Kit is now running."
echo ""
echo "Next steps:"
echo "1. Set up git hooks in your Claude projects"
echo "2. Test with: chronos-stamp claude-code test 'hello world'"
echo "3. Check status: systemctl status cognitive-watcher"
echo ""
echo "THE UNWRIT MOMENT IS NOW."
