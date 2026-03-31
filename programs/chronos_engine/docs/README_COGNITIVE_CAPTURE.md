# Claude Code Cognitive State Capture

**Real-time capture of Claude Code's internal cognitive states using eBPF kernel probes.**

## What This Does

Captures the status line text that Claude Code displays to users but Claude itself cannot see:
- "Testing..."
- "Channelling..."
- "Thinking..."
- "Bash(command) Running"
- etc.

Uses a kernel-level TTY subsystem kprobe to intercept terminal writes, parse cognitive states, deduplicate, and store in SQLite database for analysis.

## Quick Start

```bash
# 1. Generate kernel headers (one-time)
sudo bpftool btf dump file /sys/kernel/btf/vmlinux format c > vmlinux.h

# 2. Compile eBPF probe
clang -O2 -target bpf -D__TARGET_ARCH_x86 -g \
  -c cognitive-oracle-v2.bpf.c -o cognitive-oracle-v2.bpf.o

# 3. Compile watcher
gcc -O2 -Wall cognitive-watcher-v2.c \
  -o cognitive-watcher-v2 \
  -lbpf -lelf -lz -lsqlite3 -lcrypto

# 4. Run (requires root for eBPF)
sudo ./cognitive-watcher-v2

# 5. Query captured states
sqlite3 cognitive-states.db \
  "SELECT id, timestamp_human, tool_name, status FROM cognitive_states ORDER BY id DESC LIMIT 20;"
```

## Architecture

```
Claude Code → tty_write() [KPROBE] → Ring Buffer → Watcher → SQLite DB
```

- **cognitive-oracle-v2.bpf.c** - eBPF kprobe on `tty_write()` kernel function
- **cognitive-watcher-v2.c** - Userspace consumer with parsing, deduplication, persistence
- **cognitive-states-schema.sql** - Database schema for state storage
- **cognitive-states.db** - SQLite database (created on first run)

## Database Schema

```sql
CREATE TABLE cognitive_states (
    id INTEGER PRIMARY KEY,
    timestamp_ns INTEGER,
    timestamp_human TEXT,
    pid INTEGER,
    process_name TEXT,
    state_type TEXT,        -- 'tool_execution', 'thinking', etc.
    tool_name TEXT,          -- 'Bash', 'Read', 'Write'
    tool_args TEXT,          -- Full command/arguments
    status TEXT,             -- 'Running', 'Completed', 'Interrupted'
    raw_content TEXT,
    content_hash TEXT UNIQUE -- SHA256 for deduplication
);
```

## Example Output

```
🧠 COGNITIVE STATE #158 [PID=302079]:
   Bash(sudo bpftool map dump name cognitive_stats_v2 2>&1 | grep -v libwarden)
   Running
   💾 Saved to database (total: 42, deduped: 118)
```

## Query Examples

```bash
# Recent states
sqlite3 cognitive-states.db \
  "SELECT timestamp_human, tool_name, status FROM cognitive_states ORDER BY id DESC LIMIT 10;"

# Session statistics
sqlite3 cognitive-states.db \
  "SELECT COUNT(*) as total, COUNT(DISTINCT tool_name) as tools,
   MIN(timestamp_human) as start, MAX(timestamp_human) as end
   FROM cognitive_states;"

# State distribution
sqlite3 cognitive-states.db \
  "SELECT state_type, COUNT(*) as count FROM cognitive_states
   GROUP BY state_type ORDER BY count DESC;"
```

## Requirements

- Linux kernel 5.8+ with BTF enabled
- libbpf, libelf, zlib
- SQLite3
- OpenSSL (libcrypto)
- Root access (for eBPF kprobe)

## How It Works

### 1. eBPF Kprobe Attachment

Hooks the kernel's `tty_write()` function which ALL terminal output passes through:

```c
SEC("kprobe/tty_write")
int probe_tty_write(struct pt_regs *ctx) {
    // Filter for Claude Code processes only
    if (!is_claude_process()) return 0;

    // Extract buffer from iov_iter (handles ubuf/kvec)
    struct iov_iter *from = (struct iov_iter *)PT_REGS_PARM2(ctx);
    bpf_probe_read_user(event->buffer, size, from->ubuf);

    // Submit to ring buffer
    bpf_ringbuf_submit(event, 0);
}
```

### 2. Userspace Processing

Polls eBPF ring buffer and processes events:

```c
// Strip ANSI escape codes
strip_ansi(clean_buffer, raw_buffer);

// Parse cognitive state
parse_state(clean_buffer, &tool_name, &tool_args, &status);

// Deduplicate via SHA256 hash
sha256_hash(normalized_content, content_hash);
if (content_hash != last_state_hash) {
    save_to_database(state);
}
```

### 3. State Parsing

Extracts structured data from status line text:

```
Input:  "Bash(pwd)\n   Running"
Output: tool_name="Bash", tool_args="pwd", status="Running"
```

## Deduplication

Uses SHA256 hash of normalized content (`tool|args|status`):
- Skips exact duplicate states automatically
- Detects state changes (e.g., "Running" → "Completed")
- Reduces storage and noise

## Performance

- **CPU Impact**: <1% overhead (kprobe on tty_write with process filter)
- **Memory**: ~4KB per eBPF map, ~40KB database for 16 states
- **Capture Rate**: Real-time (microsecond latency from kernel to database)
- **Deduplication**: ~80% of events filtered as duplicates

## Use Cases

1. **Cognitive Graph Visualization** - Plot thinking → executing → completed flows
2. **Productivity Analytics** - Time spent in each cognitive state
3. **Session Replay** - Reconstruct what Claude was doing at any point
4. **AI Research** - Ground truth data for reasoning process analysis
5. **Performance Monitoring** - Identify bottlenecks in AI workflow

## Troubleshooting

### "Failed to attach kprobe"
- Ensure kernel has kprobe support: `grep CONFIG_KPROBES /boot/config-$(uname -r)`
- Check BTF is enabled: `ls /sys/kernel/btf/vmlinux`

### "Cannot open database"
- Ensure write permissions in current directory
- Check SQLite3 is installed: `sqlite3 --version`

### No states captured
- Verify Claude Code is running and has PID matching filter
- Check kprobe is attached: `sudo bpftool link show | grep tty_write`
- Enable verbose mode to see all TTY captures (not just cognitive states)

## Credits

**Author**: Richard Tune / Quantum Encoding Ltd
**License**: GPL-2.0 (eBPF), Dual License - MIT (Non-Commercial) / Commercial (Userspace)
**Date**: 2025-10-28

Part of Guardian Shield - Chronos Engine cognitive monitoring subsystem.

## Related Documentation

- `/tmp/cognitive-diary/VICTORY_REPORT.md` - Full technical deep-dive
- `/tmp/cognitive-diary/THE_NEW_DOCTRINE.md` - Design philosophy and investigation journey
- `/tmp/cognitive-diary/COGNITIVE_STATE_DISCOVERY_FINAL.md` - Original research notes

---

**THE KERNEL IS THE GROUND TRUTH.** 🔮
