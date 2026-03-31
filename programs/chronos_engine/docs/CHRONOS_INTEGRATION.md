# Chronos Integration - Real-Time Cognitive States

Integrate the cognitive state capture system with Chronos git commit stamps.

## Current State (OLD)

```
[CHRONOS] 2025-10-28T07:43:14.+699177185Z::claude-code::Pondering::TICK-0000010974::[/home/founder/github_public/guardian-shield]::[/home/founder/github_public/guardian-shield/src/chronos-engine] → tool-completion - Create file: README_COGNITIVE_CAPTURE.md
```

**Problem**: "Pondering" is a static snapshot from old Python system, not real-time.

## New State (REAL-TIME)

```
[CHRONOS] 2025-10-28T09:15:32.+123456789Z::claude-code::Write::Creating integration guide::TICK-0000011234::[/home/founder/github_public/guardian-shield]::[/home/founder/github_public/guardian-shield/src/chronos-engine] → tool-completion - Create file: CHRONOS_INTEGRATION.md
```

**Solution**: Query live cognitive state database for actual tool + status.

---

## Setup

### 1. Install Sudoers Entry

```bash
sudo cp /tmp/cognitive-sudoers /etc/sudoers.d/cognitive-query
sudo chmod 0440 /etc/sudoers.d/cognitive-query
```

### 2. Add Tools to PATH

```bash
sudo ln -s /home/founder/github_public/guardian-shield/src/chronos-engine/cognitive-query /usr/local/bin/
sudo ln -s /home/founder/github_public/guardian-shield/src/chronos-engine/get-cognitive-state /usr/local/bin/
```

### 3. Grant Claude Code Permission

Add to `~/.config/claude-code/settings.json`:

```json
{
  "approvedTools": [
    {
      "tool": "Bash",
      "pattern": "cognitive-query*"
    },
    {
      "tool": "Bash",
      "pattern": "get-cognitive-state*"
    }
  ]
}
```

---

## Usage

### Query Current State

```bash
# Get latest state (any PID)
cognitive-query current

# Get state for specific PID
cognitive-query current 302079
```

**Output**: `tool_name|status|raw_content`

### Get Recent States

```bash
cognitive-query recent 302079 10
```

**Output**: Last 10 states for PID 302079

### List Active PIDs

```bash
cognitive-query pids
```

**Output**: All Claude Code PIDs with state counts

### Session Statistics

```bash
cognitive-query stats
cognitive-query session
```

### Raw SQL Query

```bash
cognitive-query raw "SELECT COUNT(*) FROM cognitive_states WHERE tool_name='Bash';"
```

---

## Integration with Git Hooks

### Option 1: Modify Existing Chronos Hook

Find your git commit hook (likely `prepare-commit-msg` or a custom hook) and replace the cognitive state extraction:

**Old code (Python-based):**
```python
state = get_cognitive_state_from_python()  # Returns "Pondering"
```

**New code (DB-based):**
```bash
STATE=$(get-cognitive-state)  # Returns "Bash::Running" or "Write::Creating file"
```

### Option 2: Direct Integration

In your git hook script:

```bash
#!/bin/bash

# Get real-time cognitive state
COGNITIVE_STATE=$(get-cognitive-state)

# Get current timestamp with nanosecond precision
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%S.+%N"Z)

# Get TICK counter (increment your existing counter)
TICK="TICK-$(printf "%010d" $TICK_COUNTER)"

# Get project and working directory
PROJECT_DIR=$(git rev-parse --show-toplevel)
WORKING_DIR=$(pwd)

# Build Chronos stamp
CHRONOS_STAMP="[CHRONOS] ${TIMESTAMP}::claude-code::${COGNITIVE_STATE}::${TICK}::[${PROJECT_DIR}]::[${WORKING_DIR}] → $COMMIT_TYPE - $COMMIT_MESSAGE"

# Prepend to commit message
echo "$CHRONOS_STAMP" > "$1.tmp"
cat "$1" >> "$1.tmp"
mv "$1.tmp" "$1"
```

### Option 3: Enhanced with PID and Tool Tracking

```bash
#!/bin/bash

# Get Claude Code PID
CLAUDE_PID=$(pgrep -f "claude.*$(basename $(git rev-parse --show-toplevel))")

# Get cognitive state for this specific instance
if [ -n "$CLAUDE_PID" ]; then
    STATE_DATA=$(cognitive-query current $CLAUDE_PID)

    # Parse: tool_name|status|raw_content
    TOOL=$(echo "$STATE_DATA" | cut -d'|' -f1)
    STATUS=$(echo "$STATE_DATA" | cut -d'|' -f2)

    COGNITIVE_STATE="${TOOL}::${STATUS}"
else
    COGNITIVE_STATE="Manual::User-initiated"
fi

# Include PID in stamp for correlation
CHRONOS_STAMP="[CHRONOS] ${TIMESTAMP}::claude-code[${CLAUDE_PID}]::${COGNITIVE_STATE}::${TICK}::[${PROJECT_DIR}]::[${WORKING_DIR}] → $COMMIT_TYPE - $COMMIT_MESSAGE"
```

---

## Expected Output Examples

### Tool Execution

```
[CHRONOS] 2025-10-28T09:20:15.+456789123Z::claude-code[302079]::Bash::Running::TICK-0000011245::[/home/founder/github_public/guardian-shield]::[/home/founder/github_public/guardian-shield/src/chronos-engine] → tool-completion - Create cognitive query tool
```

### File Creation

```
[CHRONOS] 2025-10-28T09:21:33.+789456123Z::claude-code[302079]::Write::Creating CHRONOS_INTEGRATION.md::TICK-0000011246::[/home/founder/github_public/guardian-shield]::[/home/founder/github_public/guardian-shield/src/chronos-engine] → file-created - CHRONOS_INTEGRATION.md
```

### Thinking States

```
[CHRONOS] 2025-10-28T09:22:44.+123789456Z::claude-code[302079]::Analyzing::button placement in App.svelte::TICK-0000011247::[/home/founder/apps_and_extensions/quantum-bridge]::[/home/founder/apps_and_extensions/quantum-bridge/quantum-local-agent] → analysis - Exploring quantum-bridge architecture
```

---

## Benefits of Real-Time Integration

### 1. Absolute Knowledge

**Before (Python snapshot)**:
- Generic "Pondering" state
- No tool context
- No status information

**After (DB query)**:
- Exact tool being used ("Bash", "Write", "Read")
- Current status ("Running", "Completed", "Analyzing")
- Full context from raw_content

### 2. PID Correlation

Link commits to specific Claude Code instances:
```bash
# See all commits from one Claude instance
git log --all-match --grep="claude-code\[302079\]"

# Analyze productivity by PID
cognitive-query summary 302079
```

### 3. Project Context

Combine PWD tracking with cognitive states:
```
[/home/founder/github_public/guardian-shield]::[...chronos-engine] → Bash::Running
[/home/founder/apps_and_extensions/quantum-bridge]::[...quantum-local-agent] → Read::Analyzing
```

Know which project Claude was working in when the commit happened.

### 4. Tool Usage Analytics

Query git history + cognitive DB:
```bash
# Most common cognitive states in this repo
git log --all --grep=CHRONOS | grep -oP '::claude-code.*?::' | sort | uniq -c | sort -rn

# Cross-reference with database
cognitive-query stats
```

---

## Testing

### 1. Verify Tools Work

```bash
# Test query tool
cognitive-query pids
cognitive-query current

# Test state getter
get-cognitive-state
```

**Expected Output**: Tool name and status, e.g., "Write::Creating integration guide"

### 2. Test in Git Hook

Create a test commit:
```bash
echo "test" > test.txt
git add test.txt
git commit -m "Test chronos integration"
```

Check commit message:
```bash
git log -1 --format="%s"
```

**Expected**: CHRONOS stamp with real cognitive state, not "Pondering"

### 3. Verify PID Tracking

```bash
# Get current Claude PID
pgrep -f claude

# Check if it's in database
cognitive-query recent <PID> 5
```

**Expected**: Recent states for this Claude instance

---

## Troubleshooting

### "No states found"

The cognitive watcher may not be running:
```bash
# Check if watcher is running
ps aux | grep cognitive-watcher-v2

# Start if not running
cd /home/founder/github_public/guardian-shield/src/chronos-engine
sudo ./cognitive-watcher-v2
```

### "Permission denied" on DB query

Sudoers entry not installed:
```bash
sudo cp /tmp/cognitive-sudoers /etc/sudoers.d/cognitive-query
sudo chmod 0440 /etc/sudoers.d/cognitive-query
```

### "Can't find Claude PID"

Process name might be different:
```bash
# Find Claude processes
ps aux | grep -i claude

# Update get-cognitive-state script with correct process name
```

### State is "Initializing" or "Working"

Database might be empty for this PID:
```bash
# Check all PIDs in database
cognitive-query pids

# Verify watcher is capturing states
cognitive-query recent <ANY_PID> 10
```

---

## Architecture

```
┌────────────────────────────────────────────────┐
│  Claude Code (PID 302079)                      │
│  Working in: /home/founder/github_public/...   │
└───────────┬────────────────────────────────────┘
            │ Emits status lines
            ↓
┌────────────────────────────────────────────────┐
│  TTY Subsystem (tty_write)                     │
│  ← cognitive-oracle-v2.bpf.c [KPROBE]          │
└───────────┬────────────────────────────────────┘
            │ Captures to ring buffer
            ↓
┌────────────────────────────────────────────────┐
│  cognitive-watcher-v2                          │
│  Parses, deduplicates, stores                  │
└───────────┬────────────────────────────────────┘
            │ Writes to SQLite
            ↓
┌────────────────────────────────────────────────┐
│  cognitive-states.db                           │
│  - cognitive_states table                      │
│  - Indexed by PID, timestamp, hash             │
└───────────┬────────────────────────────────────┘
            │ Queried by tools
            ↓
┌────────────────────────────────────────────────┐
│  cognitive-query / get-cognitive-state         │
│  Trusted sudo tools for Claude Code            │
└───────────┬────────────────────────────────────┘
            │ Returns state
            ↓
┌────────────────────────────────────────────────┐
│  Git Prepare-Commit-Msg Hook                   │
│  Builds Chronos stamp with real state          │
└───────────┬────────────────────────────────────┘
            │ Commits with metadata
            ↓
┌────────────────────────────────────────────────┐
│  Git History                                   │
│  [CHRONOS] ...::Bash::Running::... → commit    │
│  Full audit trail with cognitive states        │
└────────────────────────────────────────────────┘
```

---

## The Ultimate Knowledge

With this integration, every git commit contains:
- ✅ **Exact timestamp** (nanosecond precision)
- ✅ **Claude Code PID** (instance identification)
- ✅ **Cognitive state** (real-time from DB, not snapshot)
- ✅ **Tool being used** (Bash, Write, Read, Search, etc.)
- ✅ **Current status** (Running, Analyzing, Creating, etc.)
- ✅ **Project directory** (what repo was being worked on)
- ✅ **Working directory** (specific folder within repo)
- ✅ **Commit type** (tool-completion, file-created, etc.)

**ABSOLUTE KNOWLEDGE. THE KERNEL IS THE GROUND TRUTH.** 🔮

---

*Integration Guide - 2025-10-28*
*Part of Guardian Shield Chronos Engine*
