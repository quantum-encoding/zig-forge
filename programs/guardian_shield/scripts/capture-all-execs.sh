#!/bin/bash
# Capture ALL executions and see what comm test-target has

set -e

if [ "$EUID" -ne 0 ]; then
    echo "ERROR: Must run as root (use sudo)"
    exit 1
fi

export LD_PRELOAD=""

echo "═══════════════════════════════════════════════════════════"
echo "  CAPTURE: All Executions"
echo "═══════════════════════════════════════════════════════════"
echo ""

# Start Inquisitor in monitor mode (logs ALL)
echo "Starting Inquisitor (logs all execs for 10 seconds)..."
/home/founder/github_public/guardian-shield/zig-out/bin/test-inquisitor monitor 10 > /tmp/inquisitor-full-log.txt 2>&1 &
INQUISITOR_PID=$!

sleep 2

echo ""
echo "Executing various commands to generate events..."
echo ""

# Execute test-target multiple ways
echo "[1] Executing: /home/founder/github_public/guardian-shield/test-target"
/home/founder/github_public/guardian-shield/test-target

echo ""
echo "[2] Executing: ./test-target (from guardian-shield dir)"
cd /home/founder/github_public/guardian-shield
./test-target

echo ""
echo "[3] Executing: ../guardian-shield/test-target (from parent dir)"
cd /home/founder/github_public
./guardian-shield/test-target

echo ""
echo "Waiting for monitoring to complete..."
wait $INQUISITOR_PID

echo ""
echo "═══════════════════════════════════════════════════════════"
echo "  FULL LOG:"
echo "═══════════════════════════════════════════════════════════"
cat /tmp/inquisitor-full-log.txt

echo ""
echo "═══════════════════════════════════════════════════════════"
echo "  ANALYSIS:"
echo "═══════════════════════════════════════════════════════════"
echo ""
echo "Events containing 'test':"
grep -i test /tmp/inquisitor-full-log.txt || echo "(none found)"

echo ""
echo "All ALLOWED events:"
grep "ALLOWED" /tmp/inquisitor-full-log.txt || echo "(none found)"

rm /tmp/inquisitor-full-log.txt
