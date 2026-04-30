#!/bin/bash
# Monitor BPF trace output during file operations
# This verifies if any BPF programs are generating trace output

set -e

if [ "$EUID" -ne 0 ]; then
    echo "ERROR: Must run as root (use sudo)"
    exit 1
fi

echo "Starting BPF trace monitoring..."
echo "Monitoring /sys/kernel/tracing/trace_pipe for 3 seconds..."
echo "Press Ctrl+C to stop early"
echo ""

# Start trace_pipe in background
cat /sys/kernel/tracing/trace_pipe &
PIPE_PID=$!

# Wait a moment for trace to start
sleep 1

# Trigger file operations
echo "Triggering test operations..."
cat /etc/passwd > /dev/null
ls /tmp > /dev/null
touch /tmp/bpf-test-file
rm /tmp/bpf-test-file

# Let traces propagate
sleep 2

# Stop monitoring
kill $PIPE_PID 2>/dev/null
wait $PIPE_PID 2>/dev/null || true

echo ""
echo "Trace monitoring complete"
