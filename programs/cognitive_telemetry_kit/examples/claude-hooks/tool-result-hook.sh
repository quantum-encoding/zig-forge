#!/bin/bash
# Cognitive Telemetry Kit - Claude Code Tool Result Hook
# Auto-commits with CHRONOS timestamps and cognitive states

CHRONOS_STAMP="/usr/local/bin/chronos-stamp"
AGENT_ID="claude-code"

# Extract tool description from environment
TOOL_NAME="${CLAUDE_TOOL_NAME:-unknown}"
TOOL_INPUT="${CLAUDE_TOOL_INPUT:-}"

# Try to extract description from tool input JSON
if [ -n "$TOOL_INPUT" ]; then
    if command -v jq &> /dev/null; then
        TOOL_DESCRIPTION=$(echo "$TOOL_INPUT" | jq -r '.description // empty' 2>/dev/null)
    else
        TOOL_DESCRIPTION=$(echo "$TOOL_INPUT" | grep -oP '"description":\s*"\K[^"]+' 2>/dev/null || echo "")
    fi
else
    TOOL_DESCRIPTION=""
fi

# Only proceed if we're in a git repository
if ! git rev-parse --git-dir > /dev/null 2>&1; then
    exit 0
fi

# Get real-time cognitive state from database
# Find parent Claude process
CLAUDE_PID=$(ps -o ppid= $$ | xargs ps -o ppid= | xargs)
if [ -z "$CLAUDE_PID" ]; then
    CLAUDE_PID=$(pgrep -f "claude" | head -1)
fi
COGNITIVE_STATE=$(get-cognitive-state "$CLAUDE_PID" 2>/dev/null || echo "Active")

# Generate the 4th-dimensional timestamp using chronos-stamp
CHRONOS_OUTPUT=$("$CHRONOS_STAMP" "$AGENT_ID" "tool-completion" 2>&1 | grep '\[CHRONOS\]' | sed 's/^[[:space:]]*//' || echo "")

# If chronos-stamp failed, use fallback
if [ -z "$CHRONOS_OUTPUT" ]; then
    COMMIT_MSG="[FALLBACK] $(date -u +%Y-%m-%dT%H:%M:%S.%NZ)::$AGENT_ID::$COGNITIVE_STATE::tool-completion"
else
    # Inject cognitive state into CHRONOS output
    COMMIT_MSG=$(echo "$CHRONOS_OUTPUT" | sed "s/::${AGENT_ID}::TICK/::${AGENT_ID}::${COGNITIVE_STATE}::TICK/")
fi

# Append tool description if available
if [ -n "$TOOL_DESCRIPTION" ]; then
    COMMIT_MSG="$COMMIT_MSG - $TOOL_DESCRIPTION"
fi

# Stage all changes
git add . 2>/dev/null

# Check if there are changes to commit
if git diff --cached --quiet; then
    exit 0
fi

# Commit with the chronos-stamp message
git commit -m "$COMMIT_MSG" 2>/dev/null

exit 0

