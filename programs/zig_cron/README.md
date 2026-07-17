# zig-cron

A lightweight, single-process task scheduler that reads a config file of `<interval> <command>` lines and runs each command on its own interval in a continuous foreground loop.

## What it does

- Parses a config file with one task per line: `<interval> <command>`.
- Blank lines and lines starting with `#` are ignored; malformed lines are skipped with a warning.
- Wakes once per second, and for each task whose interval has elapsed since its last run, executes the command via `/bin/sh -c` (shell semantics — pipes, redirects, and env expansion — are intentional), inheriting the parent's stdout/stderr.
- Logs each run with an `HH:MM:SS` timestamp, tracks per-task failure counts and exit codes, and prints a "recovered" notice when a previously failing task succeeds again.
- Handles `SIGTERM`/`SIGINT` for graceful shutdown.

Scheduling is interval-based (fixed delay from the last run), not calendar/crontab-based — there are no minute/hour/day-of-week fields.

## Interval syntax

Concatenated `<number><unit>` segments, where units are `s` (seconds), `m` (minutes), `h` (hours), `d` (days). A bare number is treated as seconds. Examples:

| Interval | Meaning |
|----------|---------|
| `5s`     | every 5 seconds |
| `1m`     | every minute |
| `30m`    | every 30 minutes |
| `1h`     | every hour |
| `2h30m`  | every 2 hours 30 minutes |
| `1d`     | every day |

## Usage

```
zig-cron <config_file>
zig-cron --help
```

Config example:

```
# Pull latest code every 30 minutes
30m git pull

# Disk space check hourly
1h df -h >> /tmp/disk.log

# Heartbeat every 5 seconds
5s echo heartbeat
```

## Build

Requires Zig 0.16. Links libc.

```
zig build            # build the zig-cron executable
zig build run -- config.txt
zig build test       # run unit tests (interval parse/format, config parsing)
```

## Security note

Commands are executed through `/bin/sh -c` by design: the whole point of the tool is to run operator-supplied shell commands on a schedule. The operator owns the config file and therefore the command strings — treat write access to the config as equivalent to shell access.

## License

MIT — Copyright (c) 2025 QUANTUM ENCODING LTD.
