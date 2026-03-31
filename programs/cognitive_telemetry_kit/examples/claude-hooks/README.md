# Claude Code Hooks - Cognitive Telemetry Integration

This directory contains example hooks for integrating Cognitive Telemetry Kit with Claude Code's hook system.

## What Are Claude Code Hooks?

Claude Code supports per-project hooks that execute during various lifecycle events. These hooks allow you to automate actions based on Claude's activities.

## tool-result-hook.sh

This hook runs **after every tool execution** and automatically creates git commits with CHRONOS timestamps and real-time cognitive states.

### Installation

#### Per-Project Installation

1. Copy the hook to your project:
   ```bash
   mkdir -p .claude/hooks
   cp tool-result-hook.sh .claude/hooks/
   chmod +x .claude/hooks/tool-result-hook.sh
   ```

2. The hook will automatically activate when Claude Code runs in this directory.

#### System-Wide Installation

To install the hook in **all your git repositories**:

```bash
# Download and run the installer
curl -fsSL https://raw.githubusercontent.com/quantum-encoding/cognitive-telemetry-kit/master/scripts/install-hooks-all.sh | bash
```

Or manually using the installer from this kit:

```bash
cd cognitive-telemetry-kit
sudo ./scripts/install.sh
install-cognitive-hooks-all  # This installs hooks in all repos
```

### What It Does

Every time Claude Code completes a tool operation (Read, Write, Edit, Bash, etc.), the hook:

1. **Detects the Claude process** - Finds the parent Claude Code PID
2. **Queries cognitive state** - Retrieves current state from the cognitive-watcher database
3. **Generates CHRONOS timestamp** - Creates 4D timestamp with nanosecond precision
4. **Injects cognitive state** - Embeds the state into the timestamp
5. **Creates git commit** - Automatically commits with full telemetry

### Example Commit Messages

```
[CHRONOS] 2025-10-28T11:12:09.910123620Z::claude-code::Verifying git commits::TICK-0000011391::[/home/user/project]::[/home/user/project] → tool-completion - Write file: src/main.rs

[CHRONOS] 2025-10-28T08:26:02.194633125Z::claude-code::Channelling::TICK-0000011061::[/home/user/project]::[/home/user/project] → tool-completion - Read file: README.md

[CHRONOS] 2025-10-28T08:25:19.152773507Z::claude-code::Pondering::TICK-0000011059::[/home/user/project]::[/home/user/project] → tool-completion - Run command: cargo test
```

### Configuration

Edit the hook to customize:

```bash
# Change the agent identifier
AGENT_ID="claude-code"  # or "my-custom-agent"

# Disable auto-commit (just log instead)
# Comment out the git commit line and add:
# echo "$COMMIT_MSG" >> /tmp/cognitive-log.txt
```

### Requirements

- Cognitive Telemetry Kit installed (`cognitive-watcher` running)
- `chronos-stamp` in PATH (installed to `/usr/local/bin/chronos-stamp`)
- `get-cognitive-state` in PATH (installed to `/usr/local/bin/get-cognitive-state`)
- Git repository

### Troubleshooting

#### Hook not running

Check Claude Code's hook execution:
```bash
# Add debug output to the hook
echo "Hook triggered at $(date)" >> /tmp/hook-debug.log
```

#### Empty cognitive states

Verify the watcher is capturing states:
```bash
# Check if cognitive-watcher is running
systemctl status cognitive-watcher

# Check database for recent states
sqlite3 /var/lib/cognitive-watcher/cognitive-states.db \
  "SELECT pid, raw_content FROM cognitive_states ORDER BY id DESC LIMIT 5;"

# Test extraction manually
get-cognitive-state $(pgrep -f claude | head -1)
```

#### PID detection failing

The hook uses two methods:
1. Traverses parent process tree to find Claude
2. Falls back to `pgrep -f claude` if tree traversal fails

If both fail, cognitive state will default to "Active".

### Advanced Usage

#### Custom State Processing

Modify the hook to trigger different actions based on cognitive state:

```bash
if [[ "$COGNITIVE_STATE" == "Pondering" ]]; then
    # Claude is uncertain - inject additional context
    echo "Detected uncertainty, checking knowledge base..."
fi

if [[ "$COGNITIVE_STATE" == "Channelling" ]]; then
    # Claude is confident - proceed normally
    echo "High confidence operation"
fi
```

#### Multi-Instance Environments

The hook automatically handles multiple concurrent Claude instances via PID isolation. Each instance's commits will have distinct PIDs and cognitive states.

#### Integration with CI/CD

To disable hooks in CI environments:

```bash
# Add at the top of the hook
if [ -n "$CI" ]; then
    exit 0
fi
```

### Philosophy

This hook transforms git history into **cognitive archaeology**. Every commit becomes a window into:
- What Claude was thinking
- When the thought occurred (nanosecond precision)
- What action was being performed
- Where in the codebase it happened

Future developers can trace not just **what** changed, but **why** and under what cognitive context.

---

**The unwrit moment is now written.**
