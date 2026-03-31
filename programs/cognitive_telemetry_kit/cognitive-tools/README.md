# 🧰 Cognitive Tools - User-Facing Utilities

**Powerful CLI tools for analyzing and exporting cognitive telemetry data**

These tools give users direct access to their captured cognitive states without needing to write SQL queries or understand the database schema.

---

## Tools Included

### 1. **cognitive-export** - CSV Export Tool
Export cognitive states to CSV for analysis in Excel, Python, R, or any data tool.

```bash
# Export all states
cognitive-export

# Export specific PID
cognitive-export --pid 12345 -o session-12345.csv

# Export today's states
cognitive-export --start "2025-11-03 00:00:00"

# Export with filters
cognitive-export --state "%Thinking%" --limit 1000

# Include full raw content
cognitive-export --include-raw -o detailed.csv
```

**Options:**
- `-o, --output <file>` - Output filename (default: cognitive-states.csv)
- `--start <date>` - Start date filter (YYYY-MM-DD HH:MM:SS)
- `--end <date>` - End date filter
- `--pid <number>` - Filter by specific PID
- `--state <pattern>` - Filter by state pattern (SQL LIKE)
- `--limit <number>` - Limit number of records
- `--include-raw` - Include raw_content column

### 2. **cognitive-stats** - Analytics Dashboard
Beautiful terminal dashboard showing statistics about your cognitive telemetry data.

```bash
cognitive-stats
```

**Displays:**
- Total states captured
- Number of unique sessions (PIDs)
- Time range of data collection
- Top 20 most common cognitive states
- Top 10 most active sessions

**Example Output:**
```
🧠 COGNITIVE TELEMETRY STATISTICS
═══════════════════════════════════════════════

📊 Overall Statistics:
   Total States:        95224
   Unique Sessions:        35

   First Capture:   2025-10-28 08:36:11
   Latest Capture:  2025-11-03 12:22:05

🔥 Top 20 Cognitive States:
   ┌────────────────────────────────────────┬─────────┐
   │ State                                  │ Count   │
   ├────────────────────────────────────────┼─────────┤
   │ Compacting conversation                │    1248 │
   │ Computing                              │     311 │
   │ Zesting                                │     295 │
   ...
```

### 3. **cognitive-query** - Advanced Search Tool
Search, filter, and explore cognitive states with powerful queries.

```bash
# Search for specific states
cognitive-query search "Thinking"

# Show full session history for a PID
cognitive-query session 12345

# Show recent states
cognitive-query recent 20

# Timeline visualization (coming soon)
cognitive-query timeline 12345
```

**Commands:**
- `search <pattern>` - Search for states matching pattern
- `session <pid>` - Show all states for a specific session
- `timeline <pid>` - Timeline visualization (planned)
- `recent [limit]` - Show recent states (default: 20)

---

## Installation

```bash
cd cognitive-tools
zig build
./install.sh
```

The installer will:
1. Build all three tools
2. Install them to `/usr/local/bin/`
3. Make them globally accessible

---

## Use Cases

### Data Analysis
Export to CSV and analyze in your favorite tools:

```bash
# Export all data
cognitive-export -o all-states.csv

# Open in Python/pandas
python
>>> import pandas as pd
>>> df = pd.read_csv('all-states.csv')
>>> df['cognitive_state'].value_counts()
```

### Performance Insights
See which cognitive states you spend the most time in:

```bash
cognitive-stats
```

Identify:
- Most common thought patterns
- Longest sessions
- Peak productivity times

### Session Debugging
When something went wrong, review the cognitive journey:

```bash
# Find the session PID
cognitive-stats

# Review what happened
cognitive-query session 12345
```

### Research & Development
Export filtered data for analysis:

```bash
# Export only "Thinking" states
cognitive-export --state "%Thinking%" -o thinking-analysis.csv

# Export last week's data
cognitive-export --start "2025-10-27 00:00:00" --end "2025-11-03 23:59:59"
```

---

## Performance

All tools are compiled Zig binaries:
- **Fast**: Query 95k records in <100ms
- **Low Memory**: ~5MB RAM usage
- **Zero Dependencies**: Just SQLite3 (already installed)

---

## Requirements

- Zig 0.16+
- SQLite3 (libsqlite3-dev)
- cognitive-watcher running and collecting data

---

## Tips

### Quick Stats
Add an alias for instant stats:

```bash
echo "alias cstats='cognitive-stats'" >> ~/.bashrc
```

### Automated Exports
Export daily snapshots:

```bash
# Add to crontab
0 0 * * * cognitive-export -o ~/backups/cognitive-$(date +\%Y\%m\%d).csv
```

### Integration with Other Tools
Pipe cognitive-query output to other commands:

```bash
# Count unique states today
cognitive-query recent 1000 | grep "$(date +%Y-%m-%d)" | wc -l
```

---

## Future Enhancements

Planned features:
- 📊 **cognitive-viz** - Interactive TUI dashboard with charts
- 🎯 **cognitive-replay** - Replay a session's cognitive journey
- 📈 **cognitive-trends** - Analyze patterns over time
- 🔍 **cognitive-diff** - Compare two sessions
- 📱 **Web UI** - Browser-based analytics dashboard

---

## Troubleshooting

### Database Locked
If you get "database is locked" errors:

```bash
# Stop cognitive-watcher temporarily
sudo systemctl stop cognitive-watcher

# Run your command
cognitive-export

# Restart watcher
sudo systemctl start cognitive-watcher
```

### No Data Showing
Check if cognitive-watcher is capturing data:

```bash
# Check watcher status
systemctl status cognitive-watcher

# Check database
sqlite3 /var/lib/cognitive-watcher/cognitive-states.db "SELECT COUNT(*) FROM cognitive_states"
```

### Permission Denied
Database requires read access:

```bash
# Add yourself to the group (if needed)
sudo usermod -a -G cognitive-watcher $USER

# Or use sudo
sudo cognitive-export
```

---

## License

Same as parent project (GPL-3.0 / Commercial dual-license)

## Credits

- Built with Zig 0.16
- Part of the Cognitive Telemetry Kit
- Quantum Encoding Ltd / Richard Tune

---

*Making cognitive telemetry data accessible to everyone.* 🧠✨
