#!/bin/bash
# Test JSON Log Purification
# Purpose: Verify pattern_name corruption is fixed

set -e

echo "═══════════════════════════════════════════════════════════════"
echo "🔥 THE PURIFICATION TEST: Chronicle Integrity Verification"
echo "═══════════════════════════════════════════════════════════════"
echo ""

# Cleanup
sudo pkill -9 zig-sentinel 2>/dev/null || true
sudo rm -f /var/log/zig-sentinel/grimoire_alerts.json
sleep 1

cd /home/founder/github_public/guardian-shield

echo "1. Starting Guardian with Grimoire (20 seconds)..."
sudo ./zig-out/bin/zig-sentinel \
    --enable-grimoire \
    --duration=20 \
    > /tmp/purification-test.log 2>&1 &
GUARDIAN_PID=$!

echo "   Waiting 5 seconds for initialization..."
sleep 5

echo ""
echo "2. Triggering fork bomb pattern (rapid fork test)..."
# Simple fork bomb trigger (will be detected and logged)
bash -c 'for i in {1..15}; do (sleep 0.001 &); done' 2>/dev/null || true

echo "   Waiting for detection..."
sleep 3

echo ""
echo "3. Waiting for Guardian to finish..."
sleep 15

echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "📊 CHRONICLE INTEGRITY ANALYSIS"
echo "═══════════════════════════════════════════════════════════════"
echo ""

# Check if log file exists
if [ ! -f /var/log/zig-sentinel/grimoire_alerts.json ]; then
    echo "❌ FAILURE: No alerts logged"
    echo "   Expected: /var/log/zig-sentinel/grimoire_alerts.json"
    exit 1
fi

# Count total log entries
TOTAL_ENTRIES=$(wc -l < /var/log/zig-sentinel/grimoire_alerts.json)
echo "Total log entries: $TOTAL_ENTRIES"

if [ "$TOTAL_ENTRIES" -eq 0 ]; then
    echo "⚠️  WARNING: No pattern matches detected"
    echo "   This test requires at least one pattern match"
    exit 1
fi

echo ""
echo "Recent log entries:"
tail -5 /var/log/zig-sentinel/grimoire_alerts.json
echo ""

# Check for corruption
CORRUPTED=$(grep -c '�' /var/log/zig-sentinel/grimoire_alerts.json || echo "0")

if [ "$CORRUPTED" -gt 0 ]; then
    echo "❌ PURIFICATION FAILED"
    echo "   Found $CORRUPTED corrupted entries with invalid characters"
    echo ""
    echo "Sample corrupted entry:"
    grep '�' /var/log/zig-sentinel/grimoire_alerts.json | head -1
    echo ""
    exit 1
else
    echo "✅ NO MEMORY CORRUPTION DETECTED"
fi

# Validate JSON format
echo ""
echo "Validating JSON format..."
if python3 -c "import json, sys; [json.loads(line) for line in open('/var/log/zig-sentinel/grimoire_alerts.json')]" 2>/dev/null; then
    echo "✅ ALL ENTRIES ARE VALID JSON"
else
    echo "❌ JSON PARSING FAILED"
    echo "   Some entries are malformed"
    exit 1
fi

# Check pattern names are readable
echo ""
echo "Pattern names detected:"
python3 << 'EOF'
import json
with open('/var/log/zig-sentinel/grimoire_alerts.json') as f:
    for line in f:
        entry = json.loads(line)
        name = entry.get('pattern_name', '')
        severity = entry.get('severity', '')
        pid = entry.get('pid', '')

        # Check if pattern name contains only printable ASCII
        if all(32 <= ord(c) <= 126 or c in '\t\n' for c in name):
            print(f"  ✅ {name:30s} | severity={severity:10s} | PID={pid}")
        else:
            print(f"  ❌ CORRUPTED: {repr(name)}")
            import sys
            sys.exit(1)
EOF

echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "🎯 PURIFICATION RESULT"
echo "═══════════════════════════════════════════════════════════════"
echo ""
echo "✅ THE CHRONICLE IS PURE"
echo ""
echo "   The Immutable Chronicle speaks truth."
echo "   Pattern names are readable and uncorrupted."
echo "   JSON logs are valid and parseable."
echo ""
echo "   The heresy has been purged. The logs are sacred once more."
echo ""
