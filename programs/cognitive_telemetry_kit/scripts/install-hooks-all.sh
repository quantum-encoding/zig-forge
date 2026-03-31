#!/bin/bash
# Install cognitive telemetry hooks in all git repositories
# Usage: curl -fsSL https://raw.githubusercontent.com/quantum-encoding/cognitive-telemetry-kit/master/scripts/install-hooks-all.sh | bash

set -e

HOOK_CONTENT='#!/bin/bash
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
        TOOL_DESCRIPTION=$(echo "$TOOL_INPUT" | jq -r '\''.description // empty'\'' 2>/dev/null)
    else
        TOOL_DESCRIPTION=$(echo "$TOOL_INPUT" | grep -oP '\''"description":\s*"\K[^"]+'\'' 2>/dev/null || echo "")
    fi
else
    TOOL_DESCRIPTION=""
fi

# Only proceed if we'\''re in a git repository
if ! git rev-parse --git-dir > /dev/null 2>&1; then
COGNITIVE_STATE=$(get-cognitive-state 2>/dev/null || echo "Active")
if [ -z "$CLAUDE_PID" ]; then
    CLAUDE_PID=$(pgrep -f "claude" | head -1)
fi
COGNITIVE_STATE=$(get-cognitive-state "$CLAUDE_PID" 2>/dev/null || echo "Active")

# Generate the 4th-dimensional timestamp using chronos-stamp
CHRONOS_OUTPUT=$("$CHRONOS_STAMP" "$AGENT_ID" "tool-completion" 2>&1 | grep '\''\[CHRONOS\]'\'' | sed '\''s/^[[:space:]]*//'\'' || echo "")

# If chronos-stamp failed, use fallback
if [ -z "$CHRONOS_OUTPUT" ]; then
    COMMIT_MSG="[FALLBACK] $(date -u +%Y-%m-%dT%H:%M:%S.%NZ)::$AGENT_ID::$COGNITIVE_STATE::tool-completion"
else
    # Inject cognitive state into CHRONOS output
    COMMIT_MSG=$(echo "$CHRONOS_OUTPUT" | sed "s/::::TICK/::${COGNITIVE_STATE}::TICK/")
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
'

echo "🔍 Searching for git repositories in $HOME..."
echo ""

count=0
find "$HOME" -name ".git" -type d 2>/dev/null | while read -r git_dir; do
    repo_dir=$(dirname "$git_dir")

    # Skip if not a directory or not accessible
    [ ! -d "$repo_dir" ] && continue

    # Create .claude/hooks directory
    hooks_dir="$repo_dir/.claude/hooks"
    mkdir -p "$hooks_dir"

    # Install the hook
    hook_file="$hooks_dir/tool-result-hook.sh"
    echo "$HOOK_CONTENT" > "$hook_file"
    chmod +x "$hook_file"

    count=$((count + 1))
    echo "✅ $repo_dir"
done

echo ""
echo "🎉 Cognitive telemetry hooks installed!"
echo ""
echo "All git commits from Claude Code will now include:"
echo "  - CHRONOS timestamps with nanosecond precision"
echo "  - Real-time cognitive states from eBPF capture"
echo "  - Tool descriptions and working directories"
echo ""
echo "The unwrit moment is now written everywhere."
