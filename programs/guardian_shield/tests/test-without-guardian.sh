#!/bin/bash
# Test Inquisitor without Guardian Shield interference

set -e

if [ "$EUID" -ne 0 ]; then
    echo "ERROR: Must run as root (use sudo)"
    exit 1
fi

echo "═══════════════════════════════════════════════════════════"
echo "  TEST: Inquisitor without Guardian Shield"
echo "═══════════════════════════════════════════════════════════"
echo ""

# Temporarily disable LD_PRELOAD for this test
export LD_PRELOAD=""

echo "Starting Inquisitor in MONITOR mode (15 seconds)..."
echo ""

/home/founder/github_public/guardian-shield/zig-out/bin/test-inquisitor monitor 15 &
INQUISITOR_PID=$!

# Wait for attachment
sleep 3

echo ""
echo "Executing test-target (WITHOUT Guardian Shield)..."
/home/founder/github_public/guardian-shield/test-target
echo ""

echo "Waiting for monitoring to complete..."
wait $INQUISITOR_PID

echo ""
echo "═══════════════════════════════════════════════════════════"
echo "  Test Complete"
echo "═══════════════════════════════════════════════════════════"
echo ""
echo "If test-target appears in the log above, Guardian Shield was interfering."
echo "If test-target still doesn't appear, the issue is in the BPF program logic."
