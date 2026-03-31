#!/bin/bash
# Proof of Container Detection Capability
# Purpose: Demonstrate Grimoire can now see through container walls

set -e

echo "═══════════════════════════════════════════════════════════════"
echo "🎯 CONTAINER DETECTION PROOF: The Blind Spot Is Eliminated"
echo "═══════════════════════════════════════════════════════════════"
echo ""

# Cleanup
sudo pkill -9 zig-sentinel 2>/dev/null || true
docker stop test-attack-container 2>/dev/null || true
docker rm test-attack-container 2>/dev/null || true
sleep 1

cd /home/founder/github_public/guardian-shield

# Start Guardian
echo "1. Starting Guardian with Grimoire (30 second monitoring)..."
sudo ./zig-out/bin/zig-sentinel \
    --enable-grimoire \
    --grimoire-debug \
    --duration=30 \
    > /tmp/container-proof.log 2>&1 &
GUARDIAN_PID=$!

echo "   Waiting 5 seconds for Guardian initialization..."
sleep 5

echo ""
echo "2. Creating Docker container..."
docker run -d --name test-attack-container python:3.11-slim sleep 300 > /dev/null
CONTAINER_ID=$(docker ps -q -f name=test-attack-container)
CONTAINER_INIT_PID=$(docker inspect -f '{{.State.Pid}}' test-attack-container)
echo "   Container ID: $CONTAINER_ID"
echo "   Container init PID (host perspective): $CONTAINER_INIT_PID"

echo ""
echo "3. Executing multiple syscalls inside container..."
echo "   - socket() syscall (network)"
echo "   - execve() syscall (process creation)"

# Execute Python code that triggers monitored syscalls
docker exec test-attack-container python3 -c "
import socket
import subprocess
import os

# Trigger network syscall
try:
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.close()
except:
    pass

# Trigger exec syscall
subprocess.run(['/bin/echo', 'hello from container'])
"

echo "   Waiting 3 seconds for Grimoire to process..."
sleep 3

echo ""
echo "4. Cleanup..."
docker stop test-attack-container > /dev/null 2>&1
docker rm test-attack-container > /dev/null 2>&1

echo "   Waiting for Guardian to finish..."
sleep 5
sudo kill -INT $GUARDIAN_PID 2>/dev/null || true
sleep 2

echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "📊 RESULTS"
echo "═══════════════════════════════════════════════════════════════"
echo ""

# Check if container init PID was seen
if strings /tmp/container-proof.log | grep -q "PID=$CONTAINER_INIT_PID"; then
    echo "✅ CONTAINER INIT VISIBLE"
    echo "   PID $CONTAINER_INIT_PID was seen by Grimoire"
else
    echo "⚠️  Container init not in interesting syscalls"
fi

echo ""

# Look for any container-flagged PIDs
CONTAINER_PIDS=$(strings /tmp/container-proof.log | grep "container=true" | awk '{print $2}' | sort -u | wc -l)
if [ "$CONTAINER_PIDS" -gt 0 ]; then
    echo "✅ CONTAINER PROCESSES VISIBLE: $CONTAINER_PIDS unique PIDs"
    echo ""
    echo "Sample container PIDs detected:"
    strings /tmp/container-proof.log | grep "container=true" | awk '{print $2" "$3" "$10" "$11}' | sort -u | head -5
else
    echo "❌ NO CONTAINER PROCESSES DETECTED"
fi

echo ""

# Count unique namespaces
UNIQUE_NS=$(strings /tmp/container-proof.log | grep "ns=[0-9]" | sed -n 's/.*ns=\([0-9]*\).*/\1/p' | grep -v "^0$" | sort -u | wc -l)
echo "📍 NAMESPACE VISIBILITY: $UNIQUE_NS unique namespaces detected"

if [ "$UNIQUE_NS" -ge 2 ]; then
    echo "   ✅ Multiple namespaces visible (host + container)"
    strings /tmp/container-proof.log | grep "ns=[0-9]" | sed -n 's/.*ns=\([0-9]*\).*/\1/p' | grep -v "^0$" | sort -u | while read ns; do
        COUNT=$(strings /tmp/container-proof.log | grep "ns=$ns" | wc -l)
        echo "      Namespace $ns: $COUNT events"
    done
else
    echo "   ❌ Only host namespace visible"
fi

echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "🏆 CONCLUSION"
echo "═══════════════════════════════════════════════════════════════"
echo ""

if [ "$CONTAINER_PIDS" -gt 0 ] && [ "$UNIQUE_NS" -ge 2 ]; then
    echo "✅ BLIND SPOT ELIMINATED"
    echo ""
    echo "   The Guardian can now see through container walls!"
    echo "   Container processes are fully visible to Grimoire."
    echo ""
    echo "   Technical achievement:"
    echo "   - bpf_get_ns_current_pid_tgid() implementation: SUCCESS"
    echo "   - Host namespace PID resolution: WORKING"
    echo "   - Container process visibility: CONFIRMED"
    echo ""
    exit 0
else
    echo "❌ BLIND SPOT STILL EXISTS"
    echo ""
    echo "   Container processes remain invisible."
    echo "   Check /tmp/container-proof.log for details."
    echo ""
    exit 1
fi
