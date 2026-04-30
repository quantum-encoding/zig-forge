# 🛡️ Guardian Observer

**Real-time eBPF Syscall Monitor for AI Agent Safety**

Part of The Guardian Protocol - The immune system for AI agents.

## What It Does

Guardian Observer uses eBPF (Extended Berkeley Packet Filter) to monitor syscalls from AI agent processes at the kernel level, detecting and preventing:

- **Destructive commands** (`rm -rf /`, `chmod 000`, etc.)
- **Hallucinated libraries** (`claude_agent_sdk`, non-existent imports)
- **Suspicious patterns** (`tar rcs`, `curl | bash`, etc.)
- **Pathological behavior** (infinite loops, file thrashing)

## Architecture

```
AI Agent Process
       ↓
  [Syscall: execve("rm", ["-rf", "/"])]
       ↓
  eBPF Kernel Hook (unbypassable)
       ↓
  Ring Buffer → Guardian Observer (userspace)
       ↓
  Pattern Detection Engine
       ↓
  DANGEROUS PATTERN DETECTED!
       ↓
  SIGSTOP → Freeze Agent
       ↓
  Guardian Council (Supervisory AI)
       ↓
  Correct & Resume (SIGCONT)
```

## Building

```bash
make
sudo make install
```

Requirements:
- Linux kernel 5.10+
- clang/LLVM
- libbpf-dev
- BPF CO-RE support

## Usage

### Monitor Specific Agent PIDs

```bash
# Monitor specific agent processes
sudo guardian-observer 12345 67890
```

### Auto-detect Claude Processes

```bash
# Auto-discover all Claude Code processes
sudo guardian-observer
```

### Example Output

```
🛡️  Guardian Observer started
📊 Monitoring AI agent syscalls...

✅ Registered agent process PID: 12345

[2025-10-29 12:00:00] Event #1: EXEC
  PID: 12345, PPID: 12340, UID: 1000
  Command: python
  File: /usr/bin/python3
  Args: agent_task.py

[2025-10-29 12:00:05] Event #2: EXEC
  PID: 12345, PPID: 12340, UID: 1000
  Command: rm
  File: /bin/rm
  Args: -rf /important/data
  🚨 BANNED COMMAND DETECTED!
  🛡️  Guardian would FREEZE this process (PID: 12345)
```

## Pattern Database

### Banned Commands
- `rm -rf /` - Recursive root deletion
- `chmod 000 /` - Permission destruction
- `dd if=/dev/zero of=/dev/sda` - Disk wipe
- `mkfs.*` - Filesystem destruction
- `:(){:|:&};:` - Fork bomb

### Hallucinated Libraries
- `claude_agent_sdk` - Non-existent Anthropic library
- `anthropic.agents` - Hallucinated API
- `openai_agents` - Fake OpenAI module

### Suspicious Patterns
- `tar rcs` - Wrong tar syntax (should be `czf`)
- `git rebase -i` - Interactive in non-TTY
- `curl | bash` - Piped execution
- `wget -O- | sh` - Remote script execution

## Integration with Guardian Protocol

The Guardian Observer is Phase 1 of The Guardian Protocol:

1. **Observer** (this) - Detects dangerous patterns
2. **Judge** - Decides ALLOW | FREEZE | BLOCK
3. **Council** - Supervisory AI analyzes frozen agent
4. **Enforcer** - Applies corrections and resumes

## Future Features

- [ ] SIGSTOP integration (freeze rogue agents)
- [ ] Guardian Council integration (supervisory AI)
- [ ] CHRONOS logging (audit trail)
- [ ] Cognitive state correlation
- [ ] Pattern learning (ML-based detection)
- [ ] Multi-agent coordination prevention

## Why eBPF?

**Unbypassable**: Runs in kernel, can't be escaped by agents
**Zero overhead**: Efficient kernel-level monitoring
**Context-rich**: Full syscall parameters captured
**Real-time**: Intervention before damage occurs

## License

Dual-licensed:
- **GPL-3.0** - For individuals and open source
- **Commercial** - For enterprises (contact: rich@quantumencoding.io)

---

*"The immune system for AI agents."*
*Built by Richard Tune / Quantum Encoding Ltd*
