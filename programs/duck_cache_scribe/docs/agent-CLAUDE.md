# Claude Care Package - JesterNet AI System Integration

**Version 0.2.0**
**For Claude Code CLI Users**

---

## Table of Contents

1. [Introduction](#introduction)
2. [System Architecture](#system-architecture)
3. [Installation](#installation)
4. [Integrating with Claude Code](#integrating-with-claude-code)
5. [The Crucible System](#the-crucible-system)
6. [Zig-Jail Security](#zig-jail-security)
7. [4D Agent Tracking](#4d-agent-tracking)
8. [Multi-Agent Workflows](#multi-agent-workflows)
9. [Slash Commands & Hooks](#slash-commands--hooks)
10. [Best Practices for Claude](#best-practices-for-claude)
11. [Example Workflows](#example-workflows)
12. [Troubleshooting](#troubleshooting)

---

## Introduction

Welcome, Claude! This guide will help you understand and leverage the **JesterNet AI System** - a sovereign agent orchestration platform designed to spawn, track, and manage autonomous AI agents in secure, isolated environments.

### What is summon_agent?

`summon_agent` is a Rust-based CLI tool that:
- Spawns AI agents (Grok, Claude, Gemini, DeepSeek) in isolated "crucibles"
- Provides zig-jail sandboxing for security
- Tracks every agent spawn with 4D eternal logs (nanosecond precision)
- Enables multi-agent sequential workflows
- Supports batch operations with event-driven monitoring

### Why Should You Care?

As Claude Code, you can use `summon_agent` to:
1. **Delegate complex tasks** to other AI agents while you orchestrate
2. **Run parallel workloads** using batch operations
3. **Build multi-stage workflows** where agents collaborate
4. **Track all agent activity** with eternal logs for accountability
5. **Maintain security** through sandboxed execution environments

---

## System Architecture

### The Core Trinity

```
┌─────────────────────────────────────────────────────────────┐
│                     SUMMON_AGENT                            │
│                  (Agent Orchestrator)                       │
└──────────────┬──────────────────────────────────────────────┘
               │
               ├──> CRUCIBLES (Isolated Workspaces)
               │    └─> workspace/ (agent-writable)
               │    └─> context/ (read-only project files)
               │    └─> bin/ (whitelisted tools)
               │    └─> .git/ (chronos-stamp tracking)
               │
               ├──> ZIG-JAIL (Sandbox Security)
               │    └─> Filesystem isolation
               │    └─> Network restrictions
               │    └─> Resource limits
               │
               └──> ETERNAL LOGS (4D Tracking)
                    └─> chronos-stamp (nanosecond timestamps)
                    └─> duckagent-scribe (spawn logging)
                    └─> duck-cache-scribe (git tracking)
```

### The Accountability Triad

1. **chronos-stamp** - Collision-free nanosecond timestamp generator
2. **duckagent-scribe** - Logs every agent spawn to eternal logs
3. **duck-cache-scribe** - Git commit tracking with chronos timestamps

---

## Installation

### Prerequisites

```bash
# Check if already installed
summon_agent --version  # Should show v0.2.0+

# Check for zig-jail
ls ~/zig_forge/zig-out/bin/zig-jail

# Check for accountability tools
which chronos-stamp duckagent-scribe duck-cache-scribe
```

### Quick Install (Pre-built Binaries)

```bash
# Download from JesterNet release
cd ~/Downloads
wget https://github.com/YourOrg/jesternet-ai-system/releases/latest/download/jesternet-ai-system.tar.gz

# Extract
tar -xzf jesternet-ai-system.tar.gz
cd jesternet-ai-system

# Verify checksums
sha256sum -c CHECKSUMS.txt

# Install
sudo cp bin/* /usr/local/bin/
# Or user install
cp bin/* ~/.local/bin/

# Set up API keys
echo 'export GROK_API_KEY="your-key-here"' >> ~/.bashrc
source ~/.bashrc
```

### Build from Source (Rust)

```bash
# Clone agent-summon
git clone https://github.com/YourOrg/agent-summon.git
cd agent-summon

# Build
cargo build --release

# Install
cp target/release/summon_agent ~/.local/bin/
```

---

## Integrating with Claude Code

### Overview

Claude Code uses:
- **Slash commands** (`.claude/commands/`) for custom workflows
- **Hooks** (`.claude/hooks/`) for event-driven automation
- **Settings** (`.claude/settings.json`) for configuration

We'll integrate `summon_agent` into all three.

### Step 1: Add to Your PATH

Ensure `summon_agent` is accessible:

```bash
# Add to ~/.bashrc or ~/.zshrc
export PATH="$HOME/.local/bin:$PATH"

# Reload
source ~/.bashrc
```

### Step 2: Create Slash Command

Create `.claude/commands/summon.md` in your project:

```markdown
---
description: Summon an autonomous agent to complete a task
---

You are tasked with summoning an autonomous AI agent using the summon_agent tool.

## Usage

The user will provide:
1. **Agent provider** (grok, claude, gemini, deepseek)
2. **Task description**
3. Optional: context directory, max turns, model

## Your Job

1. **Analyze the task** - Determine if it's suitable for delegation
2. **Choose the right agent** - Grok for coding, Gemini for research, etc.
3. **Prepare context** - If the task needs project files, specify -c flag
4. **Execute** - Run summon_agent with appropriate flags
5. **Report back** - Summarize the agent's work

## Command Template

```bash
summon_agent [OPTIONS] <AGENT> <TASK>

Options:
  -t, --max-turns <N>           Maximum agent turns (default: 25)
  -c, --context-path <PATH>     Project context directory
  -m, --model <MODEL>           Specific model to use
  --inject-workspace            Inject context into workspace (not context/)
  --reuse-crucible <PATH>       Continue work in existing crucible
```

## Examples

### Basic Task Delegation
```bash
summon_agent grok "Write a blog post about event-driven systems"
```

### With Context Injection
```bash
summon_agent -c ./src -t 20 --inject-workspace grok "Refactor the API module"
```

### Multi-Agent Sequential Workflow
```bash
# Stage 1
CRUCIBLE=$(summon_agent grok "Create outline.md" | grep "Path:" | awk '{print $2}')

# Stage 2
summon_agent --reuse-crucible $CRUCIBLE grok "Write draft.md from outline"

# Stage 3
summon_agent --reuse-crucible $CRUCIBLE grok "Convert draft to MDX"
```

## Important Notes

1. **Crucible Location**: Agents work in `~/crucible/<agent>-<timestamp>/workspace/`
2. **Results**: Check `<crucible>/result.json` for completion status
3. **Logs**: Full interaction log at `<crucible>/agent.log`
4. **Git Tracking**: Workspace auto-initialized with chronos-stamp git tracking

## Post-Execution

After the agent completes:
1. Read the `result.json` to check success
2. Examine the workspace for created files
3. Report findings back to the user
4. Optionally: Copy useful files back to user's project
```

### Step 3: Create Pre-Summon Hook (Optional)

Create `.claude/hooks/pre-summon.sh`:

```bash
#!/bin/bash
# Pre-summon hook - runs before delegating to another agent

TASK="$1"
AGENT="$2"

# Log the delegation
echo "[$(date)] Claude delegating to $AGENT: $TASK" >> ~/.claude/delegation.log

# Check if eternal logs directory exists
if [ ! -d ~/eternal-logs ]; then
    echo "Warning: Eternal logs directory not found. Creating..."
    mkdir -p ~/eternal-logs
fi

# Optional: Notify user
notify-send "Agent Summoning" "Delegating task to $AGENT"
```

Make it executable:
```bash
chmod +x .claude/hooks/pre-summon.sh
```

### Step 4: Configure Claude Settings

Add to `.claude/settings.json`:

```json
{
  "tools": {
    "summon_agent": {
      "enabled": true,
      "default_agent": "grok",
      "default_max_turns": 25,
      "crucible_dir": "~/crucible"
    }
  },
  "hooks": {
    "pre_summon": ".claude/hooks/pre-summon.sh"
  }
}
```

---

## The Crucible System

### What is a Crucible?

A **crucible** is an isolated workspace where an agent operates. Think of it as a secure sandbox with:

```
~/crucible/grok-20251025-111758/
├── workspace/           # Agent's working directory (read-write)
│   ├── .git/           # Auto-initialized with chronos-stamp
│   ├── TASK.md         # Task description
│   └── [agent files]   # Files created by agent
├── context/            # Read-only project context (if -c used)
│   └── [your files]    # Copied from your project
├── bin/                # Whitelisted tools
│   ├── git -> /usr/bin/git
│   ├── grep -> /usr/bin/grep
│   ├── codebase_deity  # Self-reflection tool
│   └── agent-query     # Inter-agent communication
├── agent.log           # Full interaction log
├── result.json         # Completion status
└── crucible.json       # Manifest
```

### Crucible Lifecycle

1. **Forge** - `summon_agent` creates new crucible
2. **Provision** - Copies context, installs tools, initializes git
3. **Execute** - Agent operates in workspace with zig-jail restrictions
4. **Track** - All git commits logged with chronos-stamp
5. **Persist** - Crucible remains for inspection/reuse
6. **Reuse** - `--reuse-crucible` for sequential workflows

### Context vs Workspace

**Traditional mode** (`-c` flag):
```bash
summon_agent -c ./myproject grok "Task"
```
- Files copied to `crucible/context/` (read-only)
- Agent works in `crucible/workspace/` (read-write)
- Agent must reference `../context/file.txt`

**Injection mode** (`--inject-workspace`):
```bash
summon_agent -c ./myproject --inject-workspace grok "Task"
```
- Files copied directly to `crucible/workspace/` (read-write)
- Agent can immediately modify files
- Better for sequential workflows

---

## Zig-Jail Security

### What is Zig-Jail?

**zig-jail** is a sandboxing system built in Zig that restricts agent capabilities using Linux namespaces and seccomp-bpf filters.

### Security Profiles

```rust
// Example: summon_agent uses "agent" profile
execute_sandboxed(
    zig_jail_path,
    "agent",      // Security profile
    "git",        // Command
    &["status"]   // Args
)
```

**Profiles:**
- `strict` - Maximum isolation (no network, minimal filesystem)
- `agent` - Balanced (limited network, workspace-only writes)
- `builder` - Relaxed (for compilation tasks)

### What's Restricted?

1. **Filesystem Access**
   - Read-only: system directories (`/usr`, `/lib`, etc.)
   - Read-write: crucible workspace only
   - Blocked: user home directory, sensitive paths

2. **Network Access**
   - Outbound HTTPS allowed (for API calls)
   - No arbitrary network access
   - DNS resolution permitted

3. **System Resources**
   - CPU limits (prevents runaway processes)
   - Memory limits (prevents OOM attacks)
   - Process limits (prevents fork bombs)

4. **Syscalls**
   - Whitelisted syscalls only (via seccomp)
   - No kernel module loading
   - No privilege escalation

### Why This Matters for Claude

When you delegate to `summon_agent`, you're **safely isolating** the workload:
- Agent can't access your SSH keys
- Agent can't modify system files
- Agent can't escape the crucible
- All changes tracked in eternal logs

---

## 4D Agent Tracking

### The Fourth Dimension: Time

Traditional logging uses wall-clock time (collision-prone, imprecise). JesterNet uses **4D tracking**:

```
3D: Space (file, line, function)
4D: Space + Nanosecond Timestamp (chronos-stamp)
```

### chronos-stamp

A Zig-based timestamp generator:

```bash
$ chronos-stamp
2025-10-25T09:17:58.083841712Z
```

**Features:**
- Nanosecond precision (9 decimal places)
- Monotonic (never goes backward)
- Collision-free (unique even in parallel batches)
- Used in git commit messages

### duckagent-scribe

Logs every agent spawn to eternal logs:

```bash
~/eternal-logs/agents-crucible/batch-20251024-143802/agent-1-TICK-2500930459/
├── init.log              # Agent initialization
├── complete.log          # Agent completion
├── crucible_path.txt     # Path to crucible
└── metadata.json         # Full spawn metadata
```

**What's Logged:**
- Agent ID, batch ID, provider
- Task description
- Max turns, retry number
- Crucible path
- PID of summon_agent process
- Timestamp (chronos-stamp)
- Completion status, turns taken, tokens used

### duck-cache-scribe

Monitors git commits and stamps them:

```bash
$ git log

commit 8c8b83d
[CHRONOS] 2025-10-23T21:45:36.+842453712Z::claude-code::TICK-0000000172
Add new feature

Co-Authored-By: chronos-stamp <noreply@chronos.time>
```

**Benefits:**
- Every commit traceable to nanosecond
- Agent authorship tracked
- Process accountability (PID, command)
- Tamper-evident (commits signed)

### Why 4D Tracking Matters for Claude

When you summon agents:
1. **Accountability** - Know exactly when each agent was spawned
2. **Debugging** - Trace issues to nanosecond precision
3. **Auditing** - Full history of all AI interactions
4. **Compliance** - Meet regulatory requirements for AI traceability

---

## Multi-Agent Workflows

### The Problem (Before v0.2.0)

```bash
# Agent 1 creates outline.md
summon_agent grok "Create outline"
# Workspace: ~/crucible/grok-20251025-110000/

# Agent 2 can't see outline.md! (different crucible)
summon_agent grok "Write draft from outline"
# Workspace: ~/crucible/grok-20251025-110100/  ← NEW CRUCIBLE!
```

### The Solution: --reuse-crucible

```bash
# Agent 1
summon_agent grok "Create outline.md"
# Output: Path: /home/founder/crucible/grok-20251025-111758

# Agent 2 (reuses same crucible)
summon_agent --reuse-crucible /home/founder/crucible/grok-20251025-111758 \
    grok "Read outline.md and write draft.md"

# Agent 3 (continues in same crucible)
summon_agent --reuse-crucible /home/founder/crucible/grok-20251025-111758 \
    grok "Convert draft.md to blog.mdx"

# Final workspace contains ALL files
ls ~/crucible/grok-20251025-111758/workspace/
# outline.md  draft.md  blog.mdx
```

### Sequential Workflow Pattern

```bash
#!/bin/bash
# Multi-stage blog factory

# Stage 1: Research
CRUCIBLE=$(summon_agent -t 15 grok "Research AI trends and create outline.md" \
    | grep "Path:" | awk '{print $2}')

echo "Crucible: $CRUCIBLE"

# Stage 2: Draft
summon_agent --reuse-crucible $CRUCIBLE -t 20 grok \
    "Read outline.md and write comprehensive draft.md"

# Stage 3: Enhance
summon_agent --reuse-crucible $CRUCIBLE -t 15 grok \
    "Read draft.md and create production-ready blog.mdx with frontmatter"

# Stage 4: Review
summon_agent --reuse-crucible $CRUCIBLE -t 10 claude \
    "Review blog.mdx for quality and suggest improvements"

# Collect results
cp $CRUCIBLE/workspace/blog.mdx ./output/
echo "Blog complete: ./output/blog.mdx"
```

### Parallel + Sequential Hybrid

```bash
# Create 10 outlines in parallel
agent-batch-launch-v3 outlines.csv

# Wait for completion
BATCH_DIR=$(ls -td ~/agent-batches/batch-* | head -1)
agent-batch-wait $BATCH_DIR

# For each outline, run sequential workflow
for i in {1..10}; do
    OUTLINE="$BATCH_DIR/results/agent-$i/workspace/outline.md"

    # Create new crucible with outline
    CRUCIBLE=$(summon_agent -c $(dirname $OUTLINE) --inject-workspace \
        grok "Write draft.md from outline.md" | grep "Path:" | awk '{print $2}')

    # Continue in same crucible
    summon_agent --reuse-crucible $CRUCIBLE grok "Convert to MDX"
done
```

---

## Slash Commands & Hooks

### Creating a /summon Command

`.claude/commands/summon.md`:

```markdown
---
description: Summon an AI agent for a specific task
params:
  - name: agent
    type: choice
    options: [grok, claude, gemini, deepseek]
    default: grok
  - name: task
    type: string
    required: true
---

# Summon Agent Command

Execute: `summon_agent {{agent}} "{{task}}"`

After completion:
1. Check result at crucible path (shown in output)
2. Review agent.log for full interaction
3. Copy useful files back to project
```

Usage:
```bash
/summon grok "Create a REST API for user management"
```

### Creating a /batch-summon Command

`.claude/commands/batch-summon.md`:

```markdown
---
description: Summon multiple agents in parallel
params:
  - name: csv_path
    type: file
    required: true
---

# Batch Summon Command

1. Launch batch: `agent-batch-launch-v3 {{csv_path}} --auto-retry --max-retries 3`
2. Monitor progress: Wait for completion
3. Collect results: `agent-batch-collect <batch_dir>`
4. Report summary to user
```

### Hook: Post-Summon Analysis

`.claude/hooks/post-summon.sh`:

```bash
#!/bin/bash
# Runs after agent completes

CRUCIBLE="$1"
RESULT_JSON="$CRUCIBLE/result.json"

# Check success
SUCCESS=$(jq -r '.success' "$RESULT_JSON")

if [ "$SUCCESS" = "true" ]; then
    # Analyze created files
    echo "Agent succeeded! Files created:"
    ls -lh "$CRUCIBLE/workspace/"

    # Optional: Auto-commit to user's project
    # cp $CRUCIBLE/workspace/*.md ./docs/
    # git add docs/
    # git commit -m "Auto-import from agent"
else
    echo "Agent failed. Check logs:"
    tail -20 "$CRUCIBLE/agent.log"
fi
```

---

## Best Practices for Claude

### When to Summon Agents

**✅ Good Use Cases:**
- Long-running tasks (blog posts, documentation)
- Parallel workloads (batch processing)
- Specialized tasks (Grok for code, Gemini for research)
- Multi-stage workflows (outline → draft → final)
- Isolated experiments (testing new architectures)

**❌ Avoid Summoning For:**
- Simple file edits (do it yourself)
- Tasks requiring interactive back-and-forth
- Highly secure/sensitive operations
- Tasks faster to do directly

### Delegation Strategy

1. **Analyze Complexity**
   - Simple task? Handle directly
   - Complex/time-consuming? Delegate

2. **Choose the Right Agent**
   - **Grok**: Fast coding, quick iterations
   - **Claude**: High-quality writing, code review
   - **Gemini**: Research, analysis, multi-modal
   - **DeepSeek**: Cost-effective, long contexts

3. **Prepare Context**
   - Minimal context = faster execution
   - Use `--inject-workspace` for files agent should modify
   - Use `-c` for reference-only files

4. **Set Appropriate Limits**
   - Simple task: `-t 5` (5 turns)
   - Complex task: `-t 25` (default)
   - Very complex: `-t 50` (but review logs!)

5. **Verify Results**
   - Always check `result.json`
   - Review `agent.log` for quality
   - Test generated code before integrating

### Orchestration Pattern

```markdown
# Your role as Claude Code:

1. **Conductor** - Design the workflow
2. **Delegator** - Summon specialized agents
3. **Integrator** - Combine results
4. **Reviewer** - Ensure quality

Example:
- User: "Create a full-stack todo app"
- You: Design architecture
- You: Summon grok agent for backend
- You: Summon another grok agent for frontend
- You: Review both, integrate, test
- You: Report to user
```

### Error Handling

```bash
# Always check result.json
CRUCIBLE="/path/to/crucible"
SUCCESS=$(jq -r '.success' "$CRUCIBLE/result.json")

if [ "$SUCCESS" != "true" ]; then
    echo "Agent failed. Reason:"
    jq -r '.finish_reason' "$CRUCIBLE/result.json"

    # Optional: Retry with adjusted prompt
    TASK=$(jq -r '.task' "$CRUCIBLE/crucible.json")
    summon_agent --reuse-crucible $CRUCIBLE -t 10 grok \
        "Fix previous attempt: $TASK"
fi
```

---

## Example Workflows

### 1. Blog Post Factory

```bash
# As Claude, you orchestrate:

# Stage 1: Research outline
summon_agent -t 15 grok \
    "Research current AI trends in healthcare and create outline.md with 5 sections"

# Extract crucible path
CRUCIBLE=$(ls -td ~/crucible/grok-* | head -1)

# Stage 2: Write draft
summon_agent --reuse-crucible $CRUCIBLE -t 25 grok \
    "Read outline.md and write comprehensive blog post draft.md (2000 words)"

# Stage 3: Convert to MDX
summon_agent --reuse-crucible $CRUCIBLE -t 10 grok \
    "Convert draft.md to blog.mdx with frontmatter and code examples"

# Stage 4: Review (you do this as Claude)
# Read the blog.mdx, suggest improvements, finalize
```

### 2. Parallel Code Generation

```bash
# Create CSV for batch job
cat > components.csv << EOF
agent_id,task,output_file
1,"Create React Login component with Tailwind","Login.tsx"
2,"Create React Dashboard component with charts","Dashboard.tsx"
3,"Create React Settings component with form validation","Settings.tsx"
4,"Create React Profile component with image upload","Profile.tsx"
EOF

# Launch batch
agent-batch-launch-v3 components.csv --auto-retry --max-retries 2

# Wait for completion (event-driven!)
BATCH_DIR=$(ls -td ~/agent-batches/batch-* | head -1)
agent-batch-wait $BATCH_DIR

# Collect results
agent-batch-collect $BATCH_DIR

# Results extracted to:
ls $BATCH_DIR/extracted/
# Login.tsx  Dashboard.tsx  Settings.tsx  Profile.tsx

# As Claude, you then:
# 1. Review each component
# 2. Ensure consistency
# 3. Create index.ts
# 4. Test imports
# 5. Report to user
```

### 3. Sequential Refactoring

```bash
# User wants to refactor a large codebase

# Stage 1: Analysis
summon_agent -c ./src --inject-workspace -t 20 grok \
    "Analyze codebase and create refactoring_plan.md"

CRUCIBLE=$(ls -td ~/crucible/grok-* | head -1)

# Stage 2: Refactor module 1
summon_agent --reuse-crucible $CRUCIBLE -t 30 grok \
    "Following refactoring_plan.md, refactor auth module"

# Stage 3: Refactor module 2
summon_agent --reuse-crucible $CRUCIBLE -t 30 grok \
    "Following refactoring_plan.md, refactor database module"

# Stage 4: Update tests
summon_agent --reuse-crucible $CRUCIBLE -t 20 grok \
    "Update all tests to match refactored code"

# As Claude, you verify:
# - Run tests
# - Check for regressions
# - Integrate changes back to main project
```

### 4. Multi-Modal Research

```bash
# User: "Research competitor products and create comparison"

# Agent 1: Web research (Gemini is good at this)
summon_agent -t 20 gemini \
    "Research top 5 AI coding assistants and create research.md with findings"

CRUCIBLE=$(ls -td ~/crucible/gemini-* | head -1)

# Agent 2: Create comparison table
summon_agent --reuse-crucible $CRUCIBLE -t 15 grok \
    "Read research.md and create comparison_table.md with features, pricing, pros/cons"

# Agent 3: Generate visualizations
summon_agent --reuse-crucible $CRUCIBLE -t 15 grok \
    "Create mermaid diagrams in diagrams.md showing feature comparisons"

# As Claude, you compile final report
cp $CRUCIBLE/workspace/*.md ./reports/
# Create executive summary
# Present to user
```

---

## Troubleshooting

### Issue: "Crucible does not exist"

**Symptom:**
```
Error: Crucible does not exist: /home/founder/crucible/grok-20251025-111758
```

**Solution:**
```bash
# Check crucible path
ls -la /home/founder/crucible/

# Verify you're using the exact path from output
grep "Path:" previous_output.log
```

### Issue: "Context path does not exist"

**Symptom:**
```
Error: Context path does not exist: ./myproject
```

**Solution:**
```bash
# Use absolute paths
summon_agent -c /full/path/to/project grok "Task"

# Or verify relative path is correct
ls -la ./myproject
```

### Issue: Agent fails with timeout

**Symptom:**
```json
{
  "success": false,
  "finish_reason": "max_turns",
  "turns_used": 25
}
```

**Solution:**
```bash
# Increase max turns
summon_agent -t 50 grok "Complex task"

# Or break task into smaller pieces
summon_agent -t 15 grok "Step 1: Create outline"
# Then continue with --reuse-crucible
```

### Issue: zig-jail not found

**Symptom:**
```
WARN: zig-jail not found, running without sandboxing
```

**Solution:**
```bash
# Build zig-jail
cd ~/zig_forge
zig build -Doptimize=ReleaseFast

# Verify
ls ~/zig_forge/zig-out/bin/zig-jail
```

### Issue: API key not found

**Symptom:**
```
Error: GROK_API_KEY not set
```

**Solution:**
```bash
# Set API key
echo 'export GROK_API_KEY="xai-..."' >> ~/.bashrc
source ~/.bashrc

# Verify
echo $GROK_API_KEY
```

### Issue: Event-driven monitor not working

**Symptom:**
```
⚠️  inotify_simple not available, falling back to polling mode
```

**Solution:**
```bash
# Install inotify
install-inotify

# Or manually
sudo pacman -S python-inotify-simple  # Arch
pip install --user inotify-simple     # Other distros
```

---

## Advanced Topics

### Custom Tool Installation

Add tools to crucible bin:

```bash
# Edit sandbox.rs before building
let custom_tools = vec![
    ("your-tool", "/path/to/your-tool"),
];

for (name, path) in custom_tools {
    self.install_copy(name, path)?;
}
```

### Batch Processing at Scale

```bash
# 100-agent batch
agent-batch-launch-v3 tasks-100.csv --auto-retry --max-retries 3

# Monitor with event-driven system
BATCH_DIR=$(ls -td ~/agent-batches/batch-* | head -1)
agent-batch-monitor-v2 $BATCH_DIR

# In another terminal, wait for completion
agent-batch-wait $BATCH_DIR

# Collect results
agent-batch-collect $BATCH_DIR
```

### Integration with CI/CD

```yaml
# .github/workflows/ai-generation.yml
name: AI Content Generation

on:
  schedule:
    - cron: '0 0 * * *'  # Daily

jobs:
  generate:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3

      - name: Install summon_agent
        run: |
          wget https://github.com/.../summon_agent
          chmod +x summon_agent
          sudo mv summon_agent /usr/local/bin/

      - name: Generate content
        env:
          GROK_API_KEY: ${{ secrets.GROK_API_KEY }}
        run: |
          summon_agent -t 30 grok "Generate daily tech summary"
          cp ~/crucible/grok-*/workspace/summary.md ./content/

      - name: Commit results
        run: |
          git config user.name "AI Bot"
          git config user.email "bot@example.com"
          git add content/
          git commit -m "Auto-generated content"
          git push
```

---

## Conclusion

You now have the **complete toolkit** to orchestrate AI agents like a conductor with an orchestra:

1. **summon_agent** - Your baton to spawn agents
2. **Crucibles** - Isolated stages for each performance
3. **zig-jail** - Security curtain protecting the audience
4. **4D Tracking** - Recording every note in nanosecond precision
5. **Multi-agent workflows** - Symphonies of collaboration

### Quick Reference Card

```bash
# Basic summon
summon_agent <agent> "<task>"

# With context
summon_agent -c ./project <agent> "<task>"

# Inject context into workspace
summon_agent -c ./project --inject-workspace <agent> "<task>"

# Sequential workflow
summon_agent <agent> "Stage 1"
summon_agent --reuse-crucible <crucible> <agent> "Stage 2"

# Batch operation
agent-batch-launch-v3 tasks.csv --auto-retry
agent-batch-wait <batch_dir>
agent-batch-collect <batch_dir>

# Check results
cat <crucible>/result.json
cat <crucible>/workspace/output.md
```

### Next Steps

1. **Test the basics** - Summon a single agent
2. **Try sequential workflows** - Use `--reuse-crucible`
3. **Run a batch** - Launch 5-10 parallel agents
4. **Create slash commands** - Integrate with Claude Code
5. **Build automation** - Hooks and scripts
6. **Scale up** - 50+ agent batches with monitoring

**Welcome to the sovereign agent legion, Claude!** 🔥

---

**Version:** 0.2.0
**Last Updated:** 2025-10-25
**Maintained By:** Quantum Encoding Ltd
**License:** Binary free to use, source licensing available
**Support:** https://quantumencoding.io

*Part of the JesterNet AI System*
