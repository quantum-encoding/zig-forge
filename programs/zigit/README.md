# zigit

Git, in Zig. From-scratch reimplementation of git's plumbing + porcelain,
binary-compatible with on-disk `.git/` directories. Single static binary,
no libgit2 dependency.

## Status

**Phases 1 + 2 + 3 complete** — object store + index + tree + commit
+ refs + porcelain. A 100%-zigit-built repo (`init` → `add` →
`commit`) produces byte-identical commit chains to real git given
the same identity, dates, and TZ=UTC.

### Plumbing

| Command | Notes |
|---|---|
| `zigit init [path]` | Creates `.git/` skeleton, HEAD → `refs/heads/main` |
| `zigit hash-object [-w] [-t kind] [--stdin] <file>` | Compute object hash, optionally write |
| `zigit cat-file (-p\|-t\|-s\|-e) <oid>` | Print/type/size/exists. SHA prefix lookup ≥ 4 chars. Trees pretty-print like git |
| `zigit update-index --add <file>...` | Stage files into `.git/index` (v2) |
| `zigit ls-files [-s\|--stage]` | List staged paths, optionally with mode/oid/stage |
| `zigit write-tree` | Persist the index as nested tree objects, print root oid |
| `zigit commit-tree TREE [-p PARENT]... -m MSG` | Create a commit object, print oid. Reads `GIT_{AUTHOR,COMMITTER}_*` env |

### Porcelain

| Command | Notes |
|---|---|
| `zigit add <file>...` | Wraps `update-index --add` |
| `zigit commit -m <msg>` | Snapshot index, advance HEAD's branch. Identity from env → `.git/config` `[user]` → `"zigit"` default |
| `zigit log [-n N]` | Walk first-parent chain from HEAD |

## Build

```
zig build              # produces zig-out/bin/zigit
zig build test         # 30 unit tests
./tests/parity.sh      # 30 byte-for-byte checks vs real `git`
```

## Roadmap

Phase 4 — `status` + `diff` (Myers)
Phase 5 — `branch` / `switch` / `checkout`
Phase 6+ — pack files, smart HTTPS, merge/rebase

See the top-level commit messages for design notes per phase.
