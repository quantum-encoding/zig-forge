#!/bin/bash
# debug-inquisitor.sh - Debug why the Inquisitor isn't blocking

echo "🔍 INQUISITOR DEBUG SESSION"
echo ""

# Start Inquisitor in background with LOG ALL enabled
echo "Starting Inquisitor with FULL LOGGING enabled..."
sudo zig-out/bin/test-inquisitor monitor 10 &
INQUISITOR_PID=$!

sleep 3

echo ""
echo "Executing test-target while monitoring..."
./test-target

echo ""
echo "Waiting for Inquisitor to finish logging..."
wait $INQUISITOR_PID

echo ""
echo "Debug session complete."
