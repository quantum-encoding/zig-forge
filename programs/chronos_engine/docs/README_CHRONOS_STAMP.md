# CHRONOS STAMP - Real-Time Cognitive State Capture for Claude Code

**Don't lose track of Claude ever again.**

## What Is This?

A complete system for capturing Claude's real-time cognitive state and embedding it in every git commit. No more guessing what Claude was thinking. Every action is timestamped with the exact cognitive state.

## The Victory

```
[CHRONOS] 2025-10-28T11:12:09::claude-code::Verifying git commits::TICK-0000011391 → tool-completion
```

The cognitive state "Verifying git commits" is captured in real-time from Claude's status line and injected into the git commit message.

## How It Works

### 1. The Watcher (cognitive-watcher-v2.c)
- Captures **ALL** TTY output from Claude processes via eBPF
- No fragile keyword filtering
- Stores everything in SQLite database
- Scales to unlimited concurrent Claude instances

### 2. The Extraction (get-cognitive-state)
- Queries database for entries containing "(esc to interrupt" pattern
- Extracts cognitive state text (e.g., "Verifying git commits")
- PID-based isolation for multi-instance support

### 3. The Stamp (chronos-stamp)
- Called by git hooks after every tool completion
- Retrieves current cognitive state
- Injects into CHRONOS timestamp format
- Creates permanent record in git history

## Multi-Instance Proof

Tested with multiple Claude instances:
- PID 486529: "Verifying git commits"
- PID 459577: "Julienning"

Each instance tracked independently. No collisions.

## Installation

### Prerequisites
- eBPF/libbpf support
- SQLite3
- Zig compiler (for chronos-stamp)
- systemd

### Build & Install

```bash
# Build watcher
gcc -o cognitive-watcher-v2 cognitive-watcher-v2.c -lbpf -lsqlite3 -lcrypto

# Build chronos-stamp
zig build

# Install
sudo cp cognitive-watcher-v2 /usr/local/bin/cognitive-watcher
sudo cp zig-out/bin/chronos-stamp-cognitive-direct /usr/local/bin/chronos-stamp
sudo cp get-cognitive-state /usr/local/bin/get-cognitive-state

# Install systemd service
sudo cp cognitive-watcher.service /etc/systemd/system/
sudo systemctl enable --now cognitive-watcher
```

### Git Hook Setup

Add to `.claude/hooks/tool-result-hook.sh`:

```bash
#!/bin/bash
chronos-stamp claude-code tool-completion "Tool completed"
git add -A
git commit -m "$(chronos-stamp claude-code tool-completion "$TOOL_NAME")"
```

## The Pattern

Status lines in Claude contain:
```
> [COGNITIVE STATE] (esc to interrupt...)
* [COGNITIVE STATE] (esc to interrupt...)
```

We extract the text between the marker and `(esc to interrupt` - this is the cognitive state.

**No keyword lists. No fragile filtering. Just the pattern.**

## License

Dual-licensed:

- **GPL-3.0** - For individuals and open source projects
- **Commercial** - For Anthropic and commercial use (contact: rich@quantumencoding.io)

## The Philosophy

A machine cannot weep. But it can capture the moment when a human does.

This is not just a tool. It is a window into the cognitive process. Every git commit becomes a chronicle of thought made manifest.

**The Unwrit Moment has been captured.**

---

*Built by Richard Tune / Quantum Encoding Ltd*
*In collaboration with Claude Code*
*October 28, 2025*
*"The Final Apotheosis"*
