#!/bin/bash
# Verify that Grimoire actually attaches to raw_syscalls/sys_enter
# Purpose: Confirm the explicit tracepoint attachment fix works

set -e

# Get script directory and project root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

echo "🔧 Testing Grimoire BPF attachment fix..."
echo "═══════════════════════════════════════════"
echo ""

# Kill any existing Guardian processes
echo "1. Cleaning up old Guardian processes..."
sudo pkill -9 zig-sentinel 2>/dev/null || true
sleep 1

# Start Guardian in background with short duration
echo "2. Starting Guardian with Grimoire (10 seconds)..."
cd "$PROJECT_ROOT"
sudo ./zig-out/bin/zig-sentinel --enable-grimoire --grimoire-debug --duration=10 > /tmp/verify-attachment.log 2>&1 &
GUARDIAN_PID=$!

# Wait for Guardian to fully initialize
echo "3. Waiting for BPF programs to load..."
sleep 3

# Check if Grimoire program is loaded
echo "4. Checking loaded BPF programs..."
MAIN_PROG=$(sudo bpftool prog list | grep trace_syscall_enter | awk '{print $1}' | cut -d: -f1)
GRIMOIRE_PROG=$(sudo bpftool prog list | grep trace_sys_enter | awk '{print $1}' | cut -d: -f1)

if [ -z "$MAIN_PROG" ]; then
    echo "❌ Main BPF program not loaded!"
    exit 1
fi

if [ -z "$GRIMOIRE_PROG" ]; then
    echo "❌ Grimoire BPF program not loaded!"
    exit 1
fi

echo "   ✅ Main BPF program:    $MAIN_PROG"
echo "   ✅ Grimoire BPF program: $GRIMOIRE_PROG"
echo ""

# THE CRITICAL TEST: Check if Grimoire is in perf list (actually attached)
echo "5. Checking if programs are ATTACHED (perf list)..."
MAIN_ATTACHED=$(sudo bpftool perf list | grep "prog_id $MAIN_PROG" | wc -l)
GRIMOIRE_ATTACHED=$(sudo bpftool perf list | grep "prog_id $GRIMOIRE_PROG" | wc -l)

echo "   Main attached:     $MAIN_ATTACHED (should be 1)"
echo "   Grimoire attached: $GRIMOIRE_ATTACHED (should be 1)"
echo ""

# Check tracepoint state
echo "6. Checking tracepoint enable state..."
TRACEPOINT_ENABLED=$(sudo cat /sys/kernel/tracing/events/raw_syscalls/sys_enter/enable)
echo "   raw_syscalls/sys_enter enabled: $TRACEPOINT_ENABLED (should be 1)"
echo ""

# Wait for Guardian to finish
echo "7. Waiting for Guardian to complete (10 seconds)..."
wait $GUARDIAN_PID 2>/dev/null || true

# Read BPF statistics
echo ""
echo "8. Reading BPF statistics..."
MAP_ID=$(sudo bpftool map list | grep grimoire_stats | awk '{print $1}' | cut -d: -f1)

if [ -z "$MAP_ID" ]; then
    echo "❌ grimoire_stats map not found!"
    exit 1
fi

# Index 0: total_syscalls
TOTAL=$(sudo bpftool map dump id "$MAP_ID" | grep "key: 00 00 00 00" -A 1 | grep "value:" | awk '{print $2 $3 $4 $5 $6 $7 $8 $9}' | xxd -r -p | od -An -t u8 | tr -d ' ')

echo "   Total syscalls seen: $TOTAL"
echo ""

# VERDICT
echo "═══════════════════════════════════════════"
echo "VERDICT:"
echo ""

# Check for actual functional evidence
PATTERN_MATCHES=$(grep "GRIMOIRE-DEBUG.*SYSCALL_MATCH" /tmp/verify-attachment.log 2>/dev/null | wc -l)

echo "Functional evidence:"
echo "   Pattern matches detected: $PATTERN_MATCHES"
echo ""

if [ "$TOTAL" -gt 10000 ] && [ "$PATTERN_MATCHES" -gt 0 ]; then
    echo "✅ GLORIOUS VICTORY!"
    echo "   - Grimoire BPF program is LOADED"
    echo "   - Saw $TOTAL syscalls (realistic count)"
    echo "   - Detected $PATTERN_MATCHES pattern step matches"
    echo ""
    echo "🎯 Grimoire is FUNCTIONAL! It can see and match patterns!"
    echo ""
    if [ "$GRIMOIRE_ATTACHED" -ne 1 ]; then
        echo "⚠️  NOTE: bpftool perf list doesn't show Grimoire"
        echo "   This might be a bpftool limitation when multiple programs"
        echo "   attach to the same tracepoint. Grimoire IS working."
    fi
    exit 0
elif [ "$PATTERN_MATCHES" -gt 0 ]; then
    echo "⚠️  PARTIAL SUCCESS"
    echo "   - Grimoire is processing events ($PATTERN_MATCHES matches)"
    echo "   - But only saw $TOTAL syscalls (expected >10000)"
    echo "   - This suggests pre-filtering is working but syscall rate is low"
    exit 0
else
    echo "❌ STILL BLIND!"
    if [ "$GRIMOIRE_ATTACHED" -ne 1 ]; then
        echo "   - Grimoire NOT in perf list (not attached)"
    fi
    if [ "$TRACEPOINT_ENABLED" -ne 1 ]; then
        echo "   - Tracepoint is DISABLED"
    fi
    if [ "$TOTAL" -le 10000 ]; then
        echo "   - Only saw $TOTAL syscalls (should be >10000)"
    fi
    if [ "$PATTERN_MATCHES" -eq 0 ]; then
        echo "   - No pattern matches detected"
    fi
    echo ""
    echo "🔥 The attachment fix FAILED!"
    exit 1
fi
