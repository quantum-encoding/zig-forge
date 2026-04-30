#!/bin/bash
# Debug why test-target isn't being blocked by the Inquisitor
# This script monitors BPF trace output while testing enforcement

set -e

if [ "$EUID" -ne 0 ]; then
    echo "ERROR: Must run as root (use sudo)"
    exit 1
fi

INQUISITOR_BIN="/home/founder/github_public/guardian-shield/zig-out/bin/test-inquisitor"
TEST_TARGET="/home/founder/github_public/guardian-shield/test-target"
TRACE_PIPE="/sys/kernel/tracing/trace_pipe"

echo "═══════════════════════════════════════════════════════════"
echo "  DEBUG: Test Target Blocking Issue"
echo "═══════════════════════════════════════════════════════════"
echo ""

# Clear trace buffer (write to trace, not trace_pipe)
echo > /sys/kernel/tracing/trace

echo "[1] Starting Inquisitor in ENFORCE mode (30 seconds)..."
echo "    Blacklist: test-target (exact match)"
echo ""

# Start inquisitor in background
$INQUISITOR_BIN enforce 30 > /tmp/inquisitor-output.txt 2>&1 &
INQUISITOR_PID=$!

# Wait for inquisitor to attach
sleep 2

echo "[2] Monitoring trace_pipe for BPF debug messages..."
echo "    (Will show what comm value the BPF program sees)"
echo ""

# Start monitoring trace in background
tail -f "$TRACE_PIPE" | grep -E "(Inquisitor|HOOK|test-target)" &
TAIL_PID=$!

# Give tail a moment to start
sleep 1

echo "[3] Executing test-target..."
echo "    Running: $TEST_TARGET"
echo ""

# Try to execute test-target
if $TEST_TARGET 2>&1; then
    echo "⚠️  TEST-TARGET EXECUTED (Should have been blocked!)"
    BLOCKED=0
else
    EXIT_CODE=$?
    if [ $EXIT_CODE -eq 1 ]; then
        echo "✓ TEST-TARGET BLOCKED (Operation not permitted)"
        BLOCKED=1
    else
        echo "⚠️  TEST-TARGET FAILED (Exit code: $EXIT_CODE)"
        BLOCKED=2
    fi
fi

echo ""
echo "[4] Waiting for trace messages to propagate..."
sleep 2

# Stop monitoring
kill $TAIL_PID 2>/dev/null || true
wait $TAIL_PID 2>/dev/null || true

echo ""
echo "[5] Stopping Inquisitor..."
kill $INQUISITOR_PID 2>/dev/null || true
wait $INQUISITOR_PID 2>/dev/null || true

echo ""
echo "═══════════════════════════════════════════════════════════"
echo "  DIAGNOSIS"
echo "═══════════════════════════════════════════════════════════"

case $BLOCKED in
    0)
        echo "❌ FAILURE: test-target was NOT blocked"
        echo ""
        echo "Possible causes:"
        echo "1. comm value doesn't match 'test-target'"
        echo "2. Blacklist entry not loaded properly"
        echo "3. Enforcement not enabled"
        echo ""
        echo "Check trace output above to see actual comm value"
        ;;
    1)
        echo "✓ SUCCESS: test-target was blocked"
        ;;
    2)
        echo "⚠️  UNKNOWN: test-target failed with unexpected exit code"
        ;;
esac

echo ""
echo "Inquisitor output:"
cat /tmp/inquisitor-output.txt
rm /tmp/inquisitor-output.txt

echo ""
echo "═══════════════════════════════════════════════════════════"
