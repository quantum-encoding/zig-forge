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
| `--debounce <ms>` | Debounce time in milliseconds (default: `0`, no debounce) |
| `--interval <time>` | Poll interval (default: `1s`). Accepts suffixes `s`/`m`/`h`/`d`, e.g. `500ms`* / `2s` / `1m` |
| `-h`, `--help` | Show help |

\* Interval parsing treats trailing digits with no suffix as seconds and recognizes `s`, `m`, `h`, `d` suffixes.

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
zig build test       # run the watcher unit tests
```

## Notes

- Change detection is **poll-based** (`nanosleep` + directory rescan), not `inotify`/`FSEvents`. It works cross-platform but is not instantaneous — latency is bounded by the poll interval.
- The trailing command is executed through `/bin/sh -c`; the operator owns the command string by construction.

## License

MIT © 2025 QUANTUM ENCODING LTD
