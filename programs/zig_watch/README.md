# zig-watch

A polling file-change watcher that runs a shell command whenever a watched file or directory changes.

`zig-watch` scans the given path at a fixed interval (default 1s), and when it detects added, removed, or modified files it prints the changed paths and runs a user-supplied command via `/bin/sh -c`. The command is whatever you place after the `--` separator, so shell features (pipes, redirects, env expansion) work as written.

## Usage

```
zig-watch <path> [options] -- <command...>
```

## Options

| Option | Description |
|---|---|
| `--ext <exts>` | Only react to files with these extensions (comma-separated, e.g. `.zig,.json`) |
| `--ignore <patterns>` | Ignore matching paths (comma-separated, e.g. `.git,node_modules,*.swp`) |
| `--debounce <ms>` | Coalesce a burst of changes into one command run (default: `0`, off) |
| `--interval <time>` | Poll interval (default: `1s`). Units: `ms`, `s`, `m`, `h`, `d` — e.g. `500ms`, `2s`, `1m30s` |
| `-h`, `--help` | Show help |

Interval parsing accepts a sequence of `<number><unit>` groups (`1m30s`); a trailing
group with no unit is read as seconds, so `--interval 2` means `2s`.

### Debounce semantics

`--debounce` is defer-and-coalesce, never drop:

- The first change to a path fires the command immediately.
- Further changes within the window are coalesced — no extra runs.
- When the window elapses, the coalesced burst fires exactly once, even if
  nothing has changed since.

The window is measured on a monotonic clock (`CLOCK_MONOTONIC`), so it is
unaffected by wall-clock steps, and it is independent of the file's own mtime.

## Examples

```
zig-watch src --ext .zig -- zig build test
zig-watch . --ext .zig,.json --interval 2s -- echo "files changed"
zig-watch . --ignore .git,node_modules,*.swp -- npm run build
zig-watch src --debounce 500 -- zig build
```

## Build

```
zig build            # builds the zig-watch executable
zig build run -- ... # build and run
zig build test       # run the watcher + CLI-parser unit tests
```

## What is watched

- **Hidden entries are skipped** at every depth: any name starting with `.`
  (`.git/`, `.env`, `src/.cache`) is never traversed or tracked.
- **Symlinks are neither followed nor watched.** Entries are `lstat`'d, and only
  regular files and directories are considered, so a symlink loop cannot hang
  the walk.
- The first scan establishes the baseline: pre-existing files are recorded, not
  reported. Only changes after startup run the command.

## Notes

- Change detection is **poll-based** (`nanosleep` + directory rescan), not `inotify`/`FSEvents`. It works cross-platform but is not instantaneous — latency is bounded by the poll interval.
- The trailing command is executed through `/bin/sh -c`; the operator owns the command string by construction.

## License

MIT © 2025 QUANTUM ENCODING LTD
