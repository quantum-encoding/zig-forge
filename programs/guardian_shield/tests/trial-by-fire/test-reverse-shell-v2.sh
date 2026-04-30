#!/bin/bash
# Trial by Fire V2 - Simple test of updated reverse_shell_classic pattern
# Tests the 6-step pattern: socket() → connect() → dup2(2,1,0) → execve()

set -e

echo "═══════════════════════════════════════════════════════════════"
echo "⚔️  TRIAL BY FIRE V2: Testing Updated Reverse Shell Pattern"
echo "═══════════════════════════════════════════════════════════════"
echo ""

TEST_DIR="/tmp/trial-by-fire"
mkdir -p "$TEST_DIR"
cd /home/founder/github_public/guardian-shield

# Cleanup
sudo pkill -9 zig-sentinel 2>/dev/null || true
pkill -9 nc 2>/dev/null || true
sleep 1

echo "Step 1: Starting listener on port 4444..."
nc -l -p 4444 > "$TEST_DIR/listener.log" 2>&1 &
LISTENER_PID=$!
echo "   Listener PID: $LISTENER_PID"
sleep 2

# Verify listener
if netstat -tuln | grep -q ":4444.*LISTEN"; then
    echo "   ✅ Listener active"
else
    echo "   ❌ Listener failed to start!"
    exit 1
fi

echo ""
echo "Step 2: Starting Guardian with enforcement mode..."
sudo ./zig-out/bin/zig-sentinel \
    --enable-grimoire \
    --grimoire-enforce \
    --duration=60 \
    > "$TEST_DIR/guardian-v2.log" 2>&1 &
GUARDIAN_PID=$!
echo "   Guardian PID: $GUARDIAN_PID"
echo "   Waiting 5 seconds for initialization..."
sleep 5

echo ""
echo "Step 3: Executing Metasploit payload..."
echo "   Payload: $TEST_DIR/reverse_shell.elf"

# Execute payload and capture PID
"$TEST_DIR/reverse_shell.elf" > "$TEST_DIR/payload-v2.log" 2>&1 &
PAYLOAD_PID=$!
echo "   Payload PID: $PAYLOAD_PID"
echo "   Waiting 5 seconds for detection..."
sleep 5

echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "RESULTS"
echo "═══════════════════════════════════════════════════════════════"
echo ""

# Check if payload is still alive
if ps -p $PAYLOAD_PID > /dev/null 2>&1; then
    echo "⚠️  Payload still running (PID $PAYLOAD_PID)"
    PAYLOAD_ALIVE=true
else
    echo "✅ Payload terminated (PID $PAYLOAD_PID no longer exists)"
    PAYLOAD_ALIVE=false
fi

echo ""
echo "Checking Guardian logs for detection..."

# Check for GRIMOIRE MATCH
if strings "$TEST_DIR/guardian-v2.log" | grep -q "GRIMOIRE MATCH.*reverse_shell"; then
    echo "✅ PATTERN DETECTED!"
    strings "$TEST_DIR/guardian-v2.log" | grep "GRIMOIRE MATCH.*reverse_shell" | head -3
else
    echo "❌ NO PATTERN MATCH"
fi

echo ""

# Check for termination
if strings "$TEST_DIR/guardian-v2.log" | grep -q "TERMINATED PID $PAYLOAD_PID"; then
    echo "✅ PAYLOAD TERMINATED BY GRIMOIRE"
else
    echo "⚠️  No termination logged for PID $PAYLOAD_PID"
fi

echo ""
echo "Checking listener for connection..."
if [ -s "$TEST_DIR/listener.log" ]; then
    echo "⚠️  Listener received data (attack may have succeeded)"
    head -5 "$TEST_DIR/listener.log"
else
    echo "✅ No connection received (attack blocked)"
fi

# Cleanup
echo ""
echo "Cleaning up..."
kill -9 $LISTENER_PID 2>/dev/null || true
if [ "$PAYLOAD_ALIVE" = true ]; then
    kill -9 $PAYLOAD_PID 2>/dev/null || true
fi
sudo kill -INT $GUARDIAN_PID 2>/dev/null || true
sleep 1

echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "Test logs saved to $TEST_DIR/"
echo "═══════════════════════════════════════════════════════════════"
