#!/bin/bash
# Helper: Start netcat listener for reverse shell testing
# Purpose: Listen for incoming reverse shell connections
# Usage: Run in separate terminal before executing attack

PORT="${1:-4444}"

echo "👂 Starting listener on port $PORT..."
echo "   Waiting for reverse shell connection..."
echo "   (Press Ctrl+C to stop)"
echo ""

if command -v ncat &> /dev/null; then
    ncat -lvp "$PORT"
elif command -v nc &> /dev/null; then
    nc -lvp "$PORT"
else
    echo "❌ No netcat variant found (ncat/nc)"
    exit 1
fi
