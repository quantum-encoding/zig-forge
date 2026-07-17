# zigix_monitor

A terminal system monitor for Linux that reads live system state from `/proc` and renders it as a real-time TUI dashboard with a PC-98 amber colour scheme.

## What it does

`zigix-monitor` is a single-binary interactive terminal application built on the in-tree `zig_tui` framework (referenced from `../zig_tui`). It collects a system snapshot from `/proc` and refreshes it on a timer, presenting four tabs:

- **Overview** — per-core CPU bars, total CPU, memory/swap usage, disk, uptime, and load averages.
- **Services** — a fixed list of well-known services with port/status detection via `/proc/net/tcp`.
- **Network** — per-interface RX/TX traffic counters with computed transfer rates.
- **Logs** — event log derived from changes observed between snapshots.

A header, tab bar, and status bar (hostname, kernel version, key hints, clock) frame the content area.

## Platform

Linux only. Data collection reads the Linux `/proc` filesystem, so the monitor produces meaningful output on Linux hosts. The source notes the same `/proc` interface is intended for future Zigix kernel integration.

## Controls

- `1`–`4` — switch to a tab by number
- `←` / `→` — move between tabs
- `↑` / `↓` — scroll the log view (Logs tab)
- `q`, `Q`, or `Esc` — quit

## Build & run

Uses Zig 0.16.

```sh
zig build          # build the executable
zig build run      # build and run the monitor
zig build test     # run unit tests
```

The build reaches into the sibling `../zig_tui` directory for the TUI module, so it expects the surrounding `zig-forge/programs` layout.
