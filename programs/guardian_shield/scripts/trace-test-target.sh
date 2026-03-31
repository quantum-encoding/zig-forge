#!/bin/bash
# Monitor BPF trace while executing test-target

set -e

if [ "$EUID" -ne 0 ]; then
    echo "ERROR: Must run as root (use sudo)"
    exit 1
fi

export LD_PRELOAD=""

echo "═══════════════════════════════════════════════════════════"
echo "  TRACE: test-target Execution"
echo "═══════════════════════════════════════════════════════════"
echo ""

# Clear trace buffer
echo > /sys/kernel/tracing/trace

# Start Inquisitor
echo "Starting Inquisitor in MONITOR mode..."
/home/founder/github_public/guardian-shield/zig-out/bin/test-inquisitor monitor 15 > /tmp/inquisitor.log 2>&1 &
INQUISITOR_PID=$!

sleep 3

echo "✓ Inquisitor running"
echo ""

# Start monitoring trace in background
echo "Starting trace monitoring..."
cat /sys/kernel/tracing/trace_pipe > /tmp/trace-output.txt &
TRACE_PID=$!

sleep 1

echo "✓ Trace monitoring active"
echo ""

# Execute test-target
echo "Executing test-target..."
/home/founder/github_public/guardian-shield/test-target
echo ""

# Execute bash for comparison
echo "Executing bash (for comparison)..."
bash -c "echo 'bash test'"
echo ""

# Wait for traces to propagate
sleep 2

# Stop trace monitoring
kill $TRACE_PID 2>/dev/null
wait $TRACE_PID 2>/dev/null || true

# Stop Inquisitor
kill $INQUISITOR_PID 2>/dev/null
wait $INQUISITOR_PID 2>/dev/null || true

echo ""
echo "═══════════════════════════════════════════════════════════"
echo "  BPF TRACE OUTPUT (last 50 lines):"
echo "═══════════════════════════════════════════════════════════"
tail -50 /tmp/trace-output.txt | grep -E "(Inquisitor|HOOK|test-target|bash)" || echo "(No relevant traces found)"

echo ""
echo "═══════════════════════════════════════════════════════════"
echo "  INQUISITOR EVENT LOG:"
echo "═══════════════════════════════════════════════════════════"
grep "ALLOWED" /tmp/inquisitor.log || echo "(No events logged)"

echo ""
echo "═══════════════════════════════════════════════════════════"
echo "  FULL TRACE OUTPUT:"
echo "═══════════════════════════════════════════════════════════"
cat /tmp/trace-output.txt | tail -100

rm -f /tmp/trace-output.txt /tmp/inquisitor.log
