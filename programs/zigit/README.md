# zigit

Git, in Zig. From-scratch reimplementation of git's plumbing + porcelain,
binary-compatible with on-disk `.git/` directories. Single static binary,
no libgit2 dependency.

## Status

**Phase 1 complete** — object store basics. zigit and real git can read
each other's loose objects.

| Command | Notes |
|---|---|
| `zigit init [path]` | Creates `.git/` skeleton, HEAD → `refs/heads/main` |
| `zigit hash-object [-w] [-t kind] [--stdin] <file>` | Compute object hash, optionally write |
| `zigit cat-file (-p\|-t\|-s\|-e) <oid>` | Print, type, size, exists. SHA prefix lookup ≥ 4 chars |

## Build

```
zig build              # produces zig-out/bin/zigit
zig build test         # 15 unit tests
./tests/parity.sh      # 21 byte-for-byte checks vs real `git`
```

## Roadmap

Phase 2 — index + write-tree + commit-tree
Phase 3 — `add` / `commit` / `log` porcelain + refs/heads/*
Phase 4 — `status` + `diff` (Myers)
Phase 5 — `branch` / `switch` / `checkout`
Phase 6+ — pack files, smart HTTPS, merge/rebase

See the top-level commit messages for design notes per phase.
