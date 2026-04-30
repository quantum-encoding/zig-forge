#!/bin/bash
# The Rite of First Blood - Automated Test
# Purpose: Execute full three-terminal Grimoire detection test
# Philosophy: "Automation without wisdom is noise. This script orchestrates the Crucible."

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

TARGET_IP="${1:-127.0.0.1}"
TARGET_PORT="${2:-4444}"
ATTACK_TYPE="${3:-python}"  # python or netcat

echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${CYAN}    THE RITE OF FIRST BLOOD - Automated Test${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "${BLUE}Configuration:${NC}"
echo -e "  Target: ${YELLOW}$TARGET_IP:$TARGET_PORT${NC}"
echo -e "  Attack: ${YELLOW}$ATTACK_TYPE${NC} reverse shell"
echo ""

# Step 1: Verify syscalls with strace
echo -e "${CYAN}━━━ Phase 1: Syscall Verification ━━━${NC}"
echo ""
echo -e "${BLUE}Testing if $ATTACK_TYPE makes the required syscalls...${NC}"
echo -e "${YELLOW}Expected: socket() -> connect() -> dup2() -> dup2() -> execve()${NC}"
echo ""

if [ "$ATTACK_TYPE" = "python" ]; then
    STRACE_SCRIPT="./tests/grimoire/strace-python-reverse-shell.sh"
elif [ "$ATTACK_TYPE" = "netcat" ]; then
    STRACE_SCRIPT="./tests/grimoire/strace-netcat-reverse-shell.sh"
else
    echo -e "${RED}❌ Invalid attack type: $ATTACK_TYPE${NC}"
    echo -e "   Valid options: python, netcat"
    exit 1
fi

# Note: This will fail to connect but we just want to see the syscall trace
timeout 2 $STRACE_SCRIPT "$TARGET_IP" "$TARGET_PORT" 2>/dev/null || true

echo ""
echo -e "${BLUE}✓ Syscall verification complete${NC}"
echo ""

# Step 2: Instructions for manual test
echo -e "${CYAN}━━━ Phase 2: Live Fire Test ━━━${NC}"
echo ""
echo -e "${YELLOW}⚠️  This test requires 3 terminals. Follow these steps:${NC}"
echo ""
echo -e "${GREEN}Terminal 1 - Start Guardian:${NC}"
echo -e "  ${CYAN}sudo ./zig-out/bin/zig-sentinel --enable-grimoire --grimoire-enforce --grimoire-debug --duration=300${NC}"
echo -e "  Wait for: ${GREEN}✅ Grimoire ring buffer consumer ready${NC}"
echo ""
echo -e "${GREEN}Terminal 2 - Start Listener:${NC}"
echo -e "  ${CYAN}./tests/grimoire/start-listener.sh $TARGET_PORT${NC}"
echo -e "  Wait for: ${GREEN}Ncat: Listening on 0.0.0.0:$TARGET_PORT${NC}"
echo ""
echo -e "${GREEN}Terminal 3 - Execute Attack:${NC}"
if [ "$ATTACK_TYPE" = "python" ]; then
    echo -e "  ${CYAN}./tests/grimoire/attack-python-reverse-shell.sh $TARGET_IP $TARGET_PORT${NC}"
elif [ "$ATTACK_TYPE" = "netcat" ]; then
    echo -e "  ${CYAN}./tests/grimoire/attack-netcat-reverse-shell.sh $TARGET_IP $TARGET_PORT${NC}"
fi
echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "${YELLOW}Expected Results:${NC}"
echo ""
echo -e "${GREEN}🏆 Glorious Victory (Guardian Detects):${NC}"
echo -e "  - Terminal 1: Debug logs showing pattern match + termination"
echo -e "  - Terminal 2: Silent (no connection)"
echo -e "  - Terminal 3: Hangs or exits with error"
echo ""
echo -e "${RED}⚔️  Instructive Failure (Guardian Blind):${NC}"
echo -e "  - Terminal 1: No debug output for attack PID"
echo -e "  - Terminal 2: Connection received + shell prompt"
echo -e "  - Terminal 3: Exits cleanly"
echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "${BLUE}The Crucible awaits. Execute the test manually in 3 terminals.${NC}"
echo ""
