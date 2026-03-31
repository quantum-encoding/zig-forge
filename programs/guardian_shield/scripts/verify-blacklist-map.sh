#!/bin/bash
# Verify blacklist map contents while Inquisitor is running

set -e

if [ "$EUID" -ne 0 ]; then
    echo "ERROR: Must run as root (use sudo)"
    exit 1
fi

INQUISITOR_BIN="/home/founder/github_public/guardian-shield/zig-out/bin/test-inquisitor"

echo "═══════════════════════════════════════════════════════════"
echo "  VERIFY: Blacklist Map Contents"
echo "═══════════════════════════════════════════════════════════"
echo ""

# Start Inquisitor in enforce mode
echo "Starting Inquisitor in ENFORCE mode (background, 30 seconds)..."
$INQUISITOR_BIN enforce 30 &
INQUISITOR_PID=$!

# Wait for attachment and map population
echo "Waiting 3 seconds for maps to populate..."
sleep 3

# Check if Inquisitor is still running
if ! kill -0 $INQUISITOR_PID 2>/dev/null; then
    echo "❌ Inquisitor failed to start!"
    exit 1
fi

echo "✓ Inquisitor running (PID: $INQUISITOR_PID)"
echo ""

# Find the blacklist_map
echo "Finding blacklist_map..."
MAP_ID=$(bpftool map list | grep blacklist_map | awk '{print $1}' | tr -d ':')

if [ -z "$MAP_ID" ]; then
    echo "❌ blacklist_map not found!"
    kill $INQUISITOR_PID 2>/dev/null || true
    exit 1
fi

echo "✓ Found blacklist_map (ID: $MAP_ID)"
echo ""

# Dump map contents
echo "═══════════════════════════════════════════════════════════"
echo "BLACKLIST MAP CONTENTS:"
echo "═══════════════════════════════════════════════════════════"
bpftool map dump id $MAP_ID

echo ""
echo "═══════════════════════════════════════════════════════════"
echo "CONFIG MAP CONTENTS:"
echo "═══════════════════════════════════════════════════════════"
CONFIG_MAP_ID=$(bpftool map list | grep config_map | awk '{print $1}' | tr -d ':')
if [ -n "$CONFIG_MAP_ID" ]; then
    bpftool map dump id $CONFIG_MAP_ID
else
    echo "(config_map not found)"
fi

echo ""
echo "Stopping Inquisitor..."
kill $INQUISITOR_PID 2>/dev/null || true
wait $INQUISITOR_PID 2>/dev/null || true

echo "✓ Complete"
