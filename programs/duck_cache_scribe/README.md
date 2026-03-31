# DuckCache Scribe - The Eternal Chronicle

**"Accountability to the past through 4th-dimensional timestamps"**

[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
[![Zig](https://img.shields.io/badge/zig-0.16-orange.svg)](https://ziglang.org)

**Classification**: Chronos-Stamp Auto-Commit Daemon
**Purpose**: Temporal accountability through automated git commits with 4D timestamps

**Created by**: [Richard Tune](https://quantumencoding.io) / Quantum Encoding Ltd
**Contact**: info@quantumencoding.io
**Website**: https://quantumencoding.io

---

## 🕰️ What Is This?

`duckcache-scribe` is a **background daemon that automatically commits and pushes git changes** with **chronos-stamp timestamps**. Think of it as your personal historian that records every change with nanosecond precision.

### Key Features

- **4th-Dimensional Timestamps**: Every commit includes nanosecond-precision timestamps
- **Automatic Commit & Push**: Watches repository for changes (in

otify-based)
- **Debounce Protection**: Prevents commit storms with configurable delays
- **Zero Manual Git Operations**: Set it and forget it
- **Temporal Sovereignty**: Know exactly when every change occurred
- **Causal Tracing**: Reconstruct decision chains across time
- **Eternal Accountability**: Every change is permanently logged

---

## 📦 Installation

### Prerequisites

- **Zig 0.16+** (for building from source)
- **Git** (obviously)
- **chronos-stamp** binary in PATH
- **Linux** (uses inotify for file watching)

### Building from Source

```bash
# Clone repository
git clone https://github.com/quantum-encoding/duck-cache-scribe.git
cd duck-cache-scribe

# Build with Zig
zig build -Doptimize=ReleaseFast

# Binary location
./zig-out/bin/duckcache-scribe
```

### Installation (System-Wide)

```bash
# Build and copy to /usr/local/bin
zig build -Doptimize=ReleaseFast
sudo cp zig-out/bin/duckcache-scribe /usr/local/bin/

# Verify
duckcache-scribe --help
```

### Systemd Service (Recommended)

```bash
# Copy service file
sudo cp duckcache-scribe.service /etc/systemd/system/

# Edit service to match your paths
sudo nano /etc/systemd/system/duckcache-scribe.service

# Enable and start
sudo systemctl enable duckcache-scribe
sudo systemctl start duckcache-scribe

# Check status
sudo systemctl status duckcache-scribe
```

---

## ⚡ Quick Start

### 1. Create Configuration

Create `config.json` in the directory where you'll run the scribe:

```json
{
  "repo_path": "/path/to/your/git/repo",
  "remote_name": "origin",
  "branch_name": "master",
  "chronos_stamp_path": "/usr/local/bin/chronos-stamp",
  "agent_id": "claude-code",
  "debounce_ms": 5000
}
```

### 2. Run the Scribe

```bash
# Foreground (for testing)
duckcache-scribe

# Background (daemon mode)
nohup duckcache-scribe > /dev/null 2>&1 &

# Via systemd (recommended)
sudo systemctl start duckcache-scribe
```

### 3. Make Changes

```bash
cd /path/to/your/git/repo

# Make any change
echo "test" > test.txt

# Wait ~5 seconds...
# The scribe automatically commits and pushes with chronos-stamp!
```

### 4. View Chronos-Stamped History

```bash
git log --oneline
# [CHRONOS] 2025-10-24T13:45:23.842453712Z::claude-code::AUTO-COMMIT::[repo] → Changes detected
```

---

## 🏗️ Architecture

```
duckcache-scribe daemon
    │
    ├─> Load config.json
    ├─> Watch repo_path/entries/ (inotify)
    │
    └─> On file change detected:
        ├─> Check debounce (prevent commit storms)
        ├─> Execute chronos-stamp (get 4D timestamp)
        ├─> git add .
        ├─> git commit -m "[CHRONOS] ..."
        ├─> git push origin master
        └─> Continue watching...
```

### The Eternal Loop

```zig
while (true) {
    // 1. Watch for changes (inotify blocks until event)
    try watchForChanges(config.repo_path);

    // 2. Debounce (prevent commit storms)
    if (now - last_push_time < debounce_seconds) {
        continue;  // Too soon, wait longer
    }

    // 3. Commit and push with chronos-stamp
    try performGitPush(allocator, config);
    last_push_time = now;
}
```

---

## 🕰️ Chronos-Stamp Format

Every commit message follows the chronos-stamp format:

```
[CHRONOS] {timestamp}::{agent}::{action}::[context] → {message}
```

### Example Commits

```bash
[CHRONOS] 2025-10-24T13:22:45.842453712Z::claude-code::AUTO-COMMIT::[workspace] → Tool execution completed
[CHRONOS] 2025-10-24T13:22:46.918234156Z::agent-grok::TOOL-WRITE::[/src] → Created authentication.rs
[CHRONOS] 2025-10-24T13:22:47.001827493Z::summon-agent::BATCH-COMPLETE::[crucible] → 12 agents finished
```

### Timestamp Components

- **Date/Time**: ISO 8601 format (YYYY-MM-DDTHH:MM:SS)
- **Nanoseconds**: `.842453712` (9 digits, nanosecond precision)
- **Timezone**: Always `Z` (UTC)
- **Agent ID**: Configured in `config.json` (e.g., "claude-code", "agent-grok")
- **Action**: Type of event ("AUTO-COMMIT", "TOOL-WRITE", etc.)
- **Context**: Location or scope ("[workspace]", "[/src]", etc.)
- **Message**: Human-readable description

---

## ⚙️ Configuration Reference

### config.json

```json
{
  "repo_path": "/absolute/path/to/git/repo",
  "remote_name": "origin",
  "branch_name": "master",
  "chronos_stamp_path": "/usr/local/bin/chronos-stamp",
  "agent_id": "your-agent-name",
  "debounce_ms": 5000
}
```

**Fields:**

- **repo_path** (required): Absolute path to git repository root
- **remote_name** (required): Git remote name (usually "origin")
- **branch_name** (required): Branch to push to (usually "master" or "main")
- **chronos_stamp_path** (required): Path to chronos-stamp binary
- **agent_id** (required): Identifier for this agent (used in commit messages)
- **debounce_ms** (required): Milliseconds to wait between commits (prevents storms)

### Recommended Debounce Values

- **Interactive Development**: 5000ms (5 seconds)
- **CI/CD Pipeline**: 10000ms (10 seconds)
- **Background Daemons**: 30000ms (30 seconds)
- **Mass Agent Execution**: 60000ms (1 minute)

---

## 🎯 Usage Patterns

### Pattern 1: Claude Code Integration

Monitor Claude Code's workspace for automatic commits:

```json
{
  "repo_path": "/home/user/projects/myapp",
  "remote_name": "origin",
  "branch_name": "claude-dev",
  "chronos_stamp_path": "/usr/local/bin/chronos-stamp",
  "agent_id": "claude-code",
  "debounce_ms": 5000
}
```

**Result**: Every tool execution by Claude Code is automatically committed and pushed with chronos-stamp.

### Pattern 2: summon_agent Integration

Monitor crucible workspaces for agent activity:

```json
{
  "repo_path": "/home/user/crucible/grok-20251024-143052/workspace",
  "remote_name": "origin",
  "branch_name": "agent-work",
  "chronos_stamp_path": "/usr/local/bin/chronos-stamp",
  "agent_id": "agent-grok",
  "debounce_ms": 10000
}
```

**Result**: Every file written by the agent is committed with chronos-stamp for temporal accountability.

### Pattern 3: Multi-Agent Orchestration

Run one scribe per agent workspace:

```bash
# Launch 100 agents
agent-batch-launch-v3 tasks.csv --auto-retry

# For each agent workspace, launch a scribe
for dir in ~/crucible/grok-*/workspace; do
  # Generate config for this workspace
  cat > "$dir/../scribe-config.json" <<EOF
{
  "repo_path": "$dir",
  "remote_name": "origin",
  "branch_name": "agent-$(basename $(dirname $dir))",
  "chronos_stamp_path": "/usr/local/bin/chronos-stamp",
  "agent_id": "$(basename $(dirname $dir))",
  "debounce_ms": 30000
}
EOF

  # Launch scribe
  (cd "$(dirname $dir)" && duckcache-scribe) &
done
```

**Result**: 100 agents, each with their own scribe, all committing with chronos-stamp.

---

## 📚 Integration with summon_agent

The scribe integrates seamlessly with summon_agent's crucible architecture:

### Automatic Git Tracking

When summon_agent creates a crucible, it initializes git:

```
~/crucible/grok-20251024-143052/
├── bin/           # Hermetic tools
├── workspace/     # Agent working directory (git-tracked)
│   └── .git/      # Initialized by summon_agent
├── context/       # Read-only context
└── agent.log      # Execution log
```

### Scribe Integration Steps

1. **summon_agent** creates crucible and initializes git
2. **Launch scribe** to monitor `workspace/`
3. **Agent makes changes** via tools (write_file, edit_file, etc.)
4. **Scribe detects changes** (inotify)
5. **Scribe commits** with chronos-stamp
6. **Scribe pushes** to remote (temporal accountability)

### Example Workflow

```bash
# 1. Spawn agent
summon_agent grok "Implement user authentication" \
  --context-path ~/myproject \
  --max-turns 50

# 2. Launch scribe for this agent's workspace
WORKSPACE=$(ls -td ~/crucible/grok-*/workspace | head -1)
cd "$(dirname $WORKSPACE)"

cat > scribe-config.json <<EOF
{
  "repo_path": "$WORKSPACE",
  "remote_name": "origin",
  "branch_name": "agent-work",
  "chronos_stamp_path": "/usr/local/bin/chronos-stamp",
  "agent_id": "agent-grok",
  "debounce_ms": 10000
}
EOF

duckcache-scribe &

# 3. Agent works autonomously
# 4. Scribe commits every change with chronos-stamp
# 5. Full temporal history preserved
```

---

## 🔧 Troubleshooting

### Issue: Scribe Exits Immediately

```
The Sovereign Scribe awakens.
Error: FileNotFound
```

**Solution**: Ensure `config.json` exists in current directory:

```bash
ls config.json  # Should exist
cat config.json  # Should be valid JSON
```

### Issue: Git Commands Fail

```
Command failed with exit code: 128
Command was: git operation
```

**Solution**: Verify git remote and push access:

```bash
cd /path/to/repo
git remote -v  # Check remote is configured
git push  # Test manual push works
```

### Issue: Chronos-Stamp Not Found

```
chronos-stamp failed with exit code: 127
```

**Solution**: Install chronos-stamp or fix path:

```bash
which chronos-stamp  # Should return path
# Update config.json with correct path
```

### Issue: Permission Denied

```
Error: AccessDenied
```

**Solution**: Ensure write permissions:

```bash
ls -ld /path/to/repo
# Should be writable by user running scribe
```

### Issue: Too Many Commits

```
# Git log shows hundreds of commits in seconds
```

**Solution**: Increase `debounce_ms` in config:

```json
{
  "debounce_ms": 30000  // Increase from 5000 to 30000
}
```

---

## 🎓 Advanced Usage

### Querying Chronos History

```bash
# View all chronos commits
git log --grep="CHRONOS" --oneline

# Extract timestamps
git log --grep="CHRONOS" --format="%s" | grep -oP '\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d+'

# Find specific agent's commits
git log --grep="agent-grok" --format="%s"

# Analyze commit frequency
git log --grep="CHRONOS" --format="%at" | sort -n | uniq -c

# Find commits in time range
git log --grep="CHRONOS" --since="2025-10-24T13:00:00" --until="2025-10-24T14:00:00"
```

### Analyzing Temporal Patterns

```bash
# Count commits per hour
git log --grep="CHRONOS" --format="%H" | sort | uniq -c

# Find busiest agent
git log --grep="CHRONOS" --format="%s" | grep -oP '::\K[^:]+' | head -1 | sort | uniq -c | sort -nr | head

# Measure average time between commits
git log --grep="CHRONOS" --format="%at" | awk 'NR>1{print $1-prev} {prev=$1}' | awk '{sum+=$1; n++} END {print sum/n}'
```

### Multi-Scribe Monitoring

```bash
# Launch scribes for multiple repos
for repo in ~/repos/*; do
  (cd "$repo" && duckcache-scribe) &
done

# Monitor all scribes
ps aux | grep duckcache-scribe

# Stop all scribes
pkill duckcache-scribe
```

---

## 📄 Systemd Service Configuration

Example `/etc/systemd/system/duckcache-scribe.service`:

```ini
[Unit]
Description=DuckCache Scribe - Chronos-Stamp Auto-Commit Daemon
After=network.target

[Service]
Type=simple
User=your-username
WorkingDirectory=/home/your-username/duck-cache-scribe
ExecStart=/usr/local/bin/duckcache-scribe
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
```

**Enable and monitor:**

```bash
sudo systemctl daemon-reload
sudo systemctl enable duckcache-scribe
sudo systemctl start duckcache-scribe
sudo systemctl status duckcache-scribe
sudo journalctl -u duckcache-scribe -f  # Follow logs
```

---

## 🌟 Documentation Hub

This repository also contains comprehensive documentation for the AI_CONDUCTOR ecosystem:

- **[DAG_RETRY_SYSTEM.md](DAG_RETRY_SYSTEM.md)** - The Doctrine of the Sovereign Gift
- **[AUTONOMOUS_RETRY_V3.md](AUTONOMOUS_RETRY_V3.md)** - Self-Healing DAG Execution
- **[WEAPON_UPGRADE_COMPLETE.md](WEAPON_UPGRADE_COMPLETE.md)** - Complete upgrade timeline

---

## 📄 Licensing

### MIT License

```
MIT License
Copyright (c) 2025 Richard Tune / Quantum Encoding Ltd

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

---

## 🤝 Contributing

Contributions are welcome! Please see [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.

---

## 📞 Support

- **Issues**: https://github.com/quantum-encoding/duck-cache-scribe/issues
- **Email**: info@quantumencoding.io
- **Website**: https://quantumencoding.io
- **Documentation**: https://docs.quantumencoding.io/duck-cache-scribe

---

**Copyright © 2025 Richard Tune / Quantum Encoding Ltd**
MIT License

**"Accountability to the past through 4th-dimensional timestamps"**
