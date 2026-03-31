# Chronos Integration with Claude Code

## Automatic Timestamping for All Agent Actions

This integration makes Claude Code (and any other agent) automatically generate Phi timestamps for every action, creating a complete temporal audit trail.

## Installation

```bash
# chronos-stamp is already installed at /usr/local/bin/chronos-stamp
# chronos-ctl is already installed at /usr/local/bin/chronos-ctl
# chronosd service is already running via systemd
```

## Usage

### Manual Stamping

```bash
# Generate a timestamp for an agent
chronos-stamp AGENT-ID

# Generate a timestamp with action description
chronos-stamp AGENT-ID "Action description"

# Examples:
chronos-stamp CLAUDE-CODE "Starting code analysis"
chronos-stamp GEMINI-AGENT "Processing request"
chronos-stamp HUMAN-FOUNDER "Reviewing code"
```

**Output Format:**
```
[CHRONOS] 2025-10-19T23:16:53.+77382201Z::CLAUDE-CODE::TICK-0000000009 → Action
```

### Automatic Integration with Claude Code

#### Option 1: Post-Tool Hook (Recommended)

Add to your Claude Code settings to automatically timestamp every tool execution:

**Location:** `~/.config/claude-code/settings.json` (or equivalent)

```json
{
  "hooks": {
    "post-tool": "chronos-stamp CLAUDE-CODE \"$TOOL_NAME\""
  }
}
```

This will append a Chronos timestamp after every tool call:

```
● Bash(cat > file.txt)
  ⎿  File created
     [CHRONOS] 2025-10-19T23:16:53.077382201Z::CLAUDE-CODE::TICK-0000000009 → Bash
```

#### Option 2: Custom Slash Command

Create a slash command for manual timestamping:

**Location:** `~/.claude/commands/stamp.md`

```markdown
Execute: chronos-stamp CLAUDE-CODE "$@"
```

**Usage:**
```
/stamp "Completed code review"
```

#### Option 3: Session Logger

Create a wrapper script that timestamps the entire session:

```bash
#!/bin/bash
# session-wrapper.sh

echo "[CHRONOS] Session started: $(chronos-stamp CLAUDE-CODE 'Session start')"

# Your work here...

echo "[CHRONOS] Session ended: $(chronos-stamp CLAUDE-CODE 'Session end')"
```

## Integration Examples

### Bash Scripts

```bash
#!/bin/bash
# Any script can now timestamp actions

chronos-stamp DEPLOYMENT-SCRIPT "Starting deployment"

# ... deployment logic ...

chronos-stamp DEPLOYMENT-SCRIPT "Deployment complete"
```

### Zig Programs

```zig
// Use chronos_logger.zig for programmatic integration
const logger = try ChronosLogger.init(allocator, "MY-AGENT");
defer logger.deinit();

const timestamp = try logger.log("action", "SUCCESS", "");
std.debug.print("Action completed: {s}\n", .{timestamp});
```

### Python/Other Languages

```python
import subprocess

def chronos_stamp(agent_id, action=""):
    result = subprocess.run(
        ["chronos-stamp", agent_id, action],
        capture_output=True,
        text=True
    )
    return result.stdout.strip()

# Usage
chronos_stamp("PYTHON-AGENT", "Processing data")
```

## Use Cases

### 1. Context Transfer to Gemini

When pasting chat logs to Gemini, the Phi timestamps provide temporal ordering:

```
[CHRONOS] 2025-10-19T23:14:00.123456789Z::CLAUDE-CODE::TICK-0000000001 → Started task
[CHRONOS] 2025-10-19T23:15:30.987654321Z::CLAUDE-CODE::TICK-0000000005 → Completed task
```

Gemini can now understand: "This happened at TICK-1, that happened at TICK-5"

### 2. Multi-Agent Coordination

Different agents working on the same system can coordinate:

```
[CHRONOS] ...::CLAUDE-CODE::TICK-0000000010 → Modified file A
[CHRONOS] ...::GEMINI-AGENT::TICK-0000000011 → Read file A
[CHRONOS] ...::HUMAN-FOUNDER::TICK-0000000012 → Approved changes
```

### 3. Audit Trail

Every action gets a cryptographically-ordered timestamp:

```bash
# All actions are now in the temporal stream
grep CHRONOS session.log | sort
```

### 4. Temporal Debugging

When debugging, you know the exact sequence:

```
[CHRONOS] TICK-0000000100 → Deployed version 1.0
[CHRONOS] TICK-0000000150 → Bug reported
[CHRONOS] TICK-0000000200 → Deployed fix 1.1
```

## Phi Timestamp Format

```
2025-10-19T23:16:53.+77382201Z::AGENT-ID::TICK-0000000010
│                                │         │
│                                │         └─ Monotonic tick counter
│                                └─────────── Agent identifier
└──────────────────────────────────────────── UTC timestamp (nanosecond precision)
```

**Properties:**
- **UTC**: Universal time coordination
- **Nanosecond precision**: Sub-microsecond accuracy
- **Agent ID**: Who performed the action
- **Monotonic Tick**: Never decreases, survives restarts
- **Global ordering**: TICK-5 always happened before TICK-6

## Architecture

```
┌─────────────────────────────────────┐
│  Claude Code / Gemini / Any Agent   │
│                                     │
│  chronos-stamp AGENT-ID "action"    │
└────────────┬────────────────────────┘
             │
             ▼
      ┌──────────────┐
      │ chronos-ctl  │  (CLI wrapper)
      └──────┬───────┘
             │
             ▼
      ┌──────────────┐
      │   D-Bus IPC  │  org.jesternet.Chronos
      └──────┬───────┘
             │
             ▼
      ┌──────────────┐
      │  chronosd    │  (systemd service)
      │              │  User: chronos
      │              │  /var/lib/chronos/tick.dat
      └──────────────┘
```

**Security:**
- Only `chronosd` writes the tick file (centralized authority)
- All clients use unprivileged D-Bus calls (decentralized access)
- systemd enforces security hardening

## Troubleshooting

### chronos-stamp returns empty output

```bash
# Check if daemon is running
systemctl status chronosd

# Check if D-Bus service is available
dbus-send --system --print-reply \
  --dest=org.jesternet.Chronos \
  /org/jesternet/Chronos \
  org.jesternet.Chronos.GetTick
```

### Permission denied

```bash
# chronos-stamp requires no special permissions
# It uses D-Bus which is accessible to all users
```

### Timestamps not incrementing

```bash
# Check current tick
chronos-ctl tick

# Force increment
chronos-ctl next
```

## Advanced: LogEvent Method

For structured logging with full metadata:

```bash
# Coming soon: chronos-log command
# Will use the LogEvent D-Bus method for JSON-structured logs
```

## Files

- `/usr/local/bin/chronos-stamp` - Timestamping wrapper (bash)
- `/usr/local/bin/chronos-ctl` - Full CLI tool (compiled Zig)
- `/usr/local/bin/chronosd-dbus` - Daemon (systemd service)
- `/var/lib/chronos/tick.dat` - Persistent tick file
- `src/chronos-engine/chronos_logger.zig` - Zig library for programmatic use

## Next Steps

1. **Configure Claude Code hooks** to auto-stamp every action
2. **Integrate with Gemini** by including timestamps in context
3. **Build multi-agent workflows** using temporal coordination
4. **Create audit tools** that parse CHRONOS timestamps

**The Sovereign Clock now timestamps your every move, creating an immutable temporal record.**

## Four-Dimensional Chronicle Update

**NEW FORMAT (v2.0):** The Phi timestamp now includes spatial and session context.

### Format Evolution

**v1.0 (Temporal only):**
```
[CHRONOS] 2025-10-19T23:28:20.180661314Z::CLAUDE-CODE::TICK-0000000011 → Action
```

**v2.0 (Spatial-temporal sovereignty):**
```
[CHRONOS] 2025-10-19T23:45:18.726242726Z::CLAUDE-CODE::TICK-0000000019::[/home/founder/.claude/projects/-home-founder-github-public-guardian-shield]::[/home/founder/github_public/guardian-shield] → Action
```

### The Four Dimensions

1. **UTC** - Universal timestamp (nanosecond precision)
2. **AGENT** - Who performed the action
3. **TICK** - Monotonic global ordering
4. **SESSION** - Which battlespace (Claude Code project)
5. **PWD** - Where in the battlespace

### Claude Code Hook Configuration

To enable full spatial-temporal awareness, set the `CLAUDE_PROJECT_DIR` environment variable:

**~/.config/claude-code/settings.json** (or equivalent):
```json
{
  "hooks": {
    "post-tool": "export CLAUDE_PROJECT_DIR=\"$CLAUDE_PROJECT_ROOT\"; chronos-stamp CLAUDE-CODE"
  }
}
```

If Claude Code exposes project root differently, adapt the variable name.

### Manual Usage with Session Context

```bash
# Set your session context
export CLAUDE_PROJECT_DIR="/home/founder/.claude/projects/-home-founder-github-public-guardian-shield"

# Now all timestamps include session
chronos-stamp CLAUDE-CODE "Working in guardian-shield project"
# Output: [CHRONOS] ...::TICK-N::[.../guardian-shield]::[/current/pwd] → Working in guardian-shield project
```

### Multi-Session Synthesis Example

When pasting to Gemini from two parallel sessions:

**Session A (guardian-shield):**
```
[CHRONOS] ...::TICK-100::[.../guardian-shield]::[.../src/chronos] → Modified chronos.zig
[CHRONOS] ...::TICK-102::[.../guardian-shield]::[.../src/chronos] → Compiled binary
```

**Session B (another-project):**
```
[CHRONOS] ...::TICK-101::[.../another-project]::[.../tests] → Running tests
[CHRONOS] ...::TICK-103::[.../another-project]::[.../tests] → Tests passed
```

Gemini can now understand:
- These are **two parallel sessions** (different SESSION paths)
- They're **interleaved in time** (TICK-100, TICK-101, TICK-102, TICK-103)
- Each has its **own spatial context** (different PWDs within different sessions)

### Fallback Behavior

If `CLAUDE_PROJECT_DIR` is not set:
```
[CHRONOS] ...::TICK-N::[UNKNOWN-SESSION]::[/current/pwd] → Action
```

The timestamp is still valid, but loses session context.
