#!/bin/bash
# Simplified test - just check if blocking works, no trace monitoring

set -e

if [ "$EUID" -ne 0 ]; then
    echo "ERROR: Must run as root (use sudo)"
    exit 1
fi

INQUISITOR_BIN="/home/founder/github_public/guardian-shield/zig-out/bin/test-inquisitor"
TEST_TARGET="/home/founder/github_public/guardian-shield/test-target"

echo "═══════════════════════════════════════════════════════════"
echo "  SIMPLE BLOCKING TEST"
echo "═══════════════════════════════════════════════════════════"
echo ""

# Start Inquisitor in enforce mode
echo "Starting Inquisitor in ENFORCE mode (background, 60 seconds)..."
$INQUISITOR_BIN enforce 60 &
INQUISITOR_PID=$!

# Wait for attachment
echo "Waiting 3 seconds for LSM hook to attach..."
sleep 3

# Check if Inquisitor is still running
if ! kill -0 $INQUISITOR_PID 2>/dev/null; then
    echo "❌ Inquisitor failed to start!"
    exit 1
fi

echo "✓ Inquisitor running (PID: $INQUISITOR_PID)"
echo ""

# Check what BPF programs are loaded
echo "Checking loaded LSM BPF programs:"
bpftool prog list | grep -i lsm || echo "  (No LSM programs found)"
echo ""

# Check what links exist
echo "Checking BPF links:"
bpftool link list | grep -i lsm || echo "  (No LSM links found)"
echo ""

# Try to execute test-target
echo "═══════════════════════════════════════════════════════════"
echo "ATTEMPTING TO EXECUTE test-target"
echo "═══════════════════════════════════════════════════════════"
echo ""

if $TEST_TARGET 2>&1; then
    echo ""
    echo "❌ FAILURE: test-target was NOT blocked"
    RESULT="FAIL"
else
    EXIT_CODE=$?
    echo ""
    if [ $EXIT_CODE -eq 1 ]; then
        echo "✓ SUCCESS: test-target was BLOCKED (exit code 1 = EPERM)"
        RESULT="SUCCESS"
    else
        echo "⚠️  UNKNOWN: test-target failed with exit code $EXIT_CODE"
        RESULT="UNKNOWN"
    fi
fi

echo ""
echo "Stopping Inquisitor..."
kill $INQUISITOR_PID 2>/dev/null || true
wait $INQUISITOR_PID 2>/dev/null || true

echo ""
echo "═══════════════════════════════════════════════════════════"
echo "  RESULT: $RESULT"
echo "═══════════════════════════════════════════════════════════"
