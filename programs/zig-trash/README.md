# zig-trash

`trash` is a CLI that moves files and directories to the OS trash instead of deleting them, and manages what is already in there (`list`, `size`, `empty`, `restore`).

It is a drop-in `rm` substitute: `-v`, `-f`, `-n`, `-r`/`-R` and `--` are accepted with `rm` semantics, and it exits nonzero on failure. Agent sessions are told to use a `trash` in place of `rm`, so **the failure mode of whichever binary is installed is permanent data loss** — correctness beats features here, and anything ambiguous fails safe and preserves the file.

> **This is not the deployed `trash`.** On the operator's Mac, `~/.local/bin/trash` is a separate Rust implementation (`trash 1.1.0`), and by decision (2026-08-07) it stays. This tree is source-only: build and test it, but do not install it over the deployed binary. Swapping the implementation behind a command every agent session must use — and which `rm` is blocked in favour of — is an operator call, not a maintenance step.

## Platforms

| | Backend | Undo |
|---|---|---|
| macOS | `NSFileManager trashItemAtURL:` — the real Finder Trash | Cmd+Z in Finder, or `trash restore` |
| Linux | freedesktop.org trash spec (`~/.local/share/Trash/`) | `trash restore`, or any spec-compliant tool |

Because macOS gives no listing/restore API and `~/.Trash` enumeration is TCC-blocked, the tool keeps its own freedesktop-style `.trashinfo` metadata in `~/.Trash/.trash-metadata/`. On Linux the standard `info/` directory is used, and the `Path` value is percent-encoded per the spec, so entries interoperate with `gio trash` and `trash-cli` in both directions.

## Usage

```
trash [-vfnr] <path>...              send to trash
trash list [--older 7d] [--project] [--json]
trash size [--bytes]
trash empty [--older 7d] [--yes]
trash restore <pattern> [--to <path>]
```

`trash --help` documents every flag. Two behaviours worth knowing:

- **Symlinks are trashed as links, not targets** — `trash link` removes the link and leaves the file it points at alone, matching `rm`. Dangling symlinks are trashable too.
- **`empty` refuses to prompt when stdin is not a TTY.** Non-interactive callers must pass `--yes`, so a script can never be silently answered "yes".

## Build, test, install

```sh
zig build                 # -> zig-out/bin/trash
zig build test            # tier-1 anchors (fast, touches nothing outside .zig-cache)
zig build itest           # end-to-end behavioural tests (see below)
```

Installing is deliberately not part of that sequence — see the note at the top. If a machine does adopt this binary, `~/.local/bin/trash` is a copy rather than a symlink, so the install has to be repeated after every source change or an old binary quietly outlives the tree it was built from:

```sh
install -m 755 zig-out/bin/trash ~/.local/bin/trash
```

### Tests

`src/tier1_anchors.zig` — externally anchored unit vectors, per the repo's golden rule:

- freedesktop trash-spec `.trashinfo` format and percent-encoding rules
- golden `.trashinfo` bodies as `gio trash` / `trash-cli` emit them (byte-for-byte, parsed back)
- published Unix epoch values (`0`, `1000000000`, `1234567890`, `2147483647`, leap-day timestamps) for the date arithmetic that `empty --older` depends on
- argument-parsing negatives, including the negative-age guard that stops `empty --older -1d` from meaning "delete everything"

`tests/integration.sh` — drives the real binary: trashes a file, a directory tree, a symlink, a dangling symlink, colliding basenames, and a filename containing quotes, a backslash and a newline; asserts the original is gone, the entry is listed, `list --json` still parses, and the bytes come back byte-identical. **Every case restores what it trashed and `trash empty` is never invoked**, so a run leaves nothing behind. It writes only inside a scratch directory it creates, and refuses to run with a scratch root inside a git work tree or your home.

```sh
zig build itest                                    # scratch under $TMPDIR
bash tests/integration.sh zig-out/bin/trash /some/scratch/dir
```

## Consumers

- `programs/zig_ai/src/agent/tools/trash_file.zig` execs `trash <path>` (argv mode) and checks the exit status.
- The global agent policy mandates `trash` over `rm`.

The CLI contract is the interface: don't change the meaning of `trash <path>`, `-v/-f/-n/-r`, `--`, or the nonzero-exit-on-failure rule without checking both.
