#!/bin/bash
# Show what syscalls are actually monitored by Grimoire
# Purpose: Debug the BPF pre-filter to understand what syscalls reach userspace

echo "🔍 Starting Guardian briefly to capture monitored syscalls list..."
echo ""

timeout 3 sudo ./zig-out/bin/zig-sentinel --enable-grimoire --duration=2 2>&1 | \
    grep -A 20 "→ syscall" | \
    grep "→ syscall"

echo ""
echo "Expected syscalls for reverse_shell_classic pattern:"
echo "   socket  = 41"
echo "   dup2    = 33"
echo "   execve  = 59"
echo ""
