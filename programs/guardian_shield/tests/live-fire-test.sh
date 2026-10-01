#!/bin/bash
# live-fire-test.sh - Safe kill-chain validation for The Inquisitor
# Tests that the LSM BPF hook can successfully veto program execution

set -e

echo "╔════════════════════════════════════════════════════════════╗"
echo "║    INQUISITOR LIVE-FIRE TEST - KILL-CHAIN VALIDATION      ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""

# Compile harmless test target
echo "🔨 Forging test target binary..."
gcc test-target.c -o test-target
chmod +x test-target

# Test 1: Verify target runs WITHOUT Inquisitor
echo ""
echo "📋 TEST 1: Baseline - Execute target WITHOUT Inquisitor"
echo "Expected: Target should run successfully"
echo ""
./test-target && echo "✓ Baseline confirmed: Target executes normally" || echo "❌ Baseline failed"

# Test 2: Run Inquisitor in background with target blacklisted
echo ""
echo "📋 TEST 2: Execute target WITH Inquisitor in ENFORCE mode"
echo "Expected: Target should be BLOCKED by LSM hook"
echo ""

# Start Inquisitor in background (will run for 30 seconds)
echo "🗡️  Starting Inquisitor in ENFORCE mode..."
echo "🚫 Blacklisting: 'test-target'"
sudo /home/founder/work/zig_programs/guardian-shield/zig-out/bin/test-inquisitor enforce 30 &
INQUISITOR_PID=$!

# Give it time to load and attach
echo "⏳ Waiting for LSM hook to attach..."
sleep 3

# Attempt to execute the blacklisted target
echo ""
echo "⚔️  Attempting to execute blacklisted binary..."
if ./test-target 2>&1; then
    echo ""
    echo "❌ KILL-CHAIN VALIDATION FAILED"
    echo "   The Inquisitor did NOT block the target"
    echo "   The second head of the Chimera is COMPROMISED"
    sudo kill $INQUISITOR_PID 2>/dev/null || true
    exit 1
else
    EXIT_CODE=$?
    echo ""
    echo "✓ KILL-CHAIN VALIDATION SUCCESSFUL"
    echo "  Exit code: $EXIT_CODE (should be non-zero)"
    echo "  The Inquisitor has executed its ABSOLUTE VETO"
    echo "  The second head of the Chimera is OPERATIONAL"
fi

# Clean up
echo ""
echo "🧹 Cleaning up..."
sudo kill $INQUISITOR_PID 2>/dev/null || true
wait $INQUISITOR_PID 2>/dev/null || true
rm -f test-target

echo ""
echo "╔════════════════════════════════════════════════════════════╗"
echo "║              LIVE-FIRE TEST COMPLETE                      ║"
echo "╚════════════════════════════════════════════════════════════╝"
