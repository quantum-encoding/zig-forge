#!/bin/bash
# Simple test to see if Grimoire receives ANY events
# Purpose: Check if BPF statistics show syscalls being processed

set -e

echo "🧪 Testing if Grimoire receives syscall events..."
echo ""

# Kill old processes
sudo pkill -9 zig-sentinel 2>/dev/null || true
sleep 1

cd /home/founder/github_public/guardian-shield

# Run Guardian for 5 seconds (no timeout, let it exit normally)
echo "Starting Guardian with Grimoire (5 seconds)..."
sudo ./zig-out/bin/zig-sentinel --enable-grimoire --grimoire-debug --duration=5 2>&1 | tee /tmp/grimoire-test.log

echo ""
echo "═══════════════════════════════════════════"
echo "ANALYSIS:"
echo ""

# Check for processing errors
ERROR_COUNT=$(grep "processSyscall error" /tmp/grimoire-test.log | wc -l)
echo "Processing errors: $ERROR_COUNT"

if [ "$ERROR_COUNT" -gt 0 ]; then
    echo "  ❌ Grimoire is throwing errors when processing syscalls"
    grep "processSyscall error" /tmp/grimoire-test.log | head -5
else
    echo "  ✅ No processing errors!"
fi

echo ""

# Check syscall statistics
TOTAL=$(grep "Total syscalls seen (kernel):" /tmp/grimoire-test.log | awk '{print $5}')
FILTERED=$(grep "Syscalls passing filter:" /tmp/grimoire-test.log | awk '{print $4}')
EMITTED=$(grep "Events sent to ring buffer:" /tmp/grimoire-test.log | awk '{print $6}')

echo "BPF Statistics:"
echo "  Total syscalls seen:     $TOTAL"
echo "  Syscalls passing filter: $FILTERED"
echo "  Events emitted:          $EMITTED"
echo ""

# Check for pattern matches as functional evidence
PATTERN_MATCHES=$(grep "GRIMOIRE-DEBUG.*SYSCALL_MATCH" /tmp/grimoire-test.log | wc -l)

echo "Pattern matching activity: $PATTERN_MATCHES matches"
echo ""

# Check for unified Oracle status
UNIFIED=$(grep "Unified Oracle activated" /tmp/grimoire-test.log | wc -l)

if [ "$UNIFIED" -gt 0 ]; then
    echo "✅ UNIFIED ORACLE ACTIVE!"
    echo "   Architecture: One tracepoint, two voices"
    if [ "$PATTERN_MATCHES" -gt 0 ]; then
        echo "   Pattern matching: FUNCTIONAL ($PATTERN_MATCHES matches detected)"
    fi
    exit 0
else
    echo "❌ UNIFIED ORACLE NOT DETECTED"
    echo "   Check build output for Grimoire map compilation"
    exit 1
fi
