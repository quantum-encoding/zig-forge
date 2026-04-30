#!/bin/bash
# Show BPF statistics from Grimoire Oracle
# Purpose: Debug event flow to see if syscalls are being dropped

echo "🔍 Reading BPF statistics from grimoire_stats map..."
echo ""

# Find the BPF map ID for grimoire_stats
MAP_ID=$(sudo bpftool map list | grep grimoire_stats | awk '{print $1}' | cut -d: -f1)

if [ -z "$MAP_ID" ]; then
    echo "❌ grimoire_stats map not found. Is Guardian running?"
    exit 1
fi

echo "Found map ID: $MAP_ID"
echo ""

# Read statistics (array indices 0-3)
echo "Statistics:"
echo "─────────────────────────────────────"

# Index 0: total_syscalls
TOTAL=$(sudo bpftool map dump id "$MAP_ID" | grep "key: 00 00 00 00" -A 1 | grep "value:" | awk '{print $2 $3 $4 $5 $6 $7 $8 $9}' | xxd -r -p | od -An -t u8 | tr -d ' ')
echo "  Total syscalls seen:      $TOTAL"

# Index 1: filtered_syscalls
FILTERED=$(sudo bpftool map dump id "$MAP_ID" | grep "key: 01 00 00 00" -A 1 | grep "value:" | awk '{print $2 $3 $4 $5 $6 $7 $8 $9}' | xxd -r -p | od -An -t u8 | tr -d ' ')
echo "  Syscalls passing filter:  $FILTERED"

# Index 2: emitted_events
EMITTED=$(sudo bpftool map dump id "$MAP_ID" | grep "key: 02 00 00 00" -A 1 | grep "value:" | awk '{print $2 $3 $4 $5 $6 $7 $8 $9}' | xxd -r -p | od -An -t u8 | tr -d ' ')
echo "  Events sent to userspace: $EMITTED"

# Index 3: dropped_events
DROPPED=$(sudo bpftool map dump id "$MAP_ID" | grep "key: 03 00 00 00" -A 1 | grep "value:" | awk '{print $2 $3 $4 $5 $6 $7 $8 $9}' | xxd -r -p | od -An -t u8 | tr -d ' ')
echo "  Events dropped (full):    $DROPPED"

echo ""
echo "Filter efficiency: $FILTERED / $TOTAL = $(awk "BEGIN {printf \"%.2f%%\", ($FILTERED/$TOTAL)*100}")" 2>/dev/null || echo "N/A"
echo ""

if [ "$DROPPED" -gt 0 ]; then
    echo "⚠️  WARNING: $DROPPED events were dropped!"
    echo "   Ring buffer is too small or userspace is too slow"
fi
