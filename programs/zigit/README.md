# zigit

Git, in Zig. From-scratch reimplementation of git's plumbing + porcelain,
binary-compatible with on-disk `.git/` directories. Single static binary,
no libgit2 dependency.

## Status

**Phases 1–6 complete** — object store + index + tree + commit + refs +
porcelain + status + Myers diff + branch/switch/checkout + pack-file
read + packed-refs. zigit transparently reads pack files (with full
delta-chain resolution: OFS_DELTA + REF_DELTA), so `cat-file -p`,
`log`, `status`, and `diff` all work against repos that have been
through `git gc`. `status --porcelain` and `diff` match `git`'s
output byte-for-byte, including diff's function-context hints in
hunk headers.

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
| `zigit status [-s\|--porcelain]` | Three-way comparison: HEAD vs index, index vs workdir, untracked. `--porcelain` matches `git status --porcelain` byte-for-byte |
| `zigit diff [--cached] [pathspec...]` | Myers + unified diff. Default workdir vs index, `--cached` for index vs HEAD. Byte-identical to `git diff` for the cases we cover |
| `zigit branch [-d\|-D] [NAME [START]]` | List local branches (current marked `*`); create at HEAD or START; delete (refuses current) |
| `zigit switch [-c] NAME` | Move HEAD to a branch, update workdir + index. Refuses if local edits would be lost |
| `zigit checkout TARGET` | Branch name → switch; commit oid (full or ≥4-char prefix) → detached HEAD |

## Build

```
zig build              # produces zig-out/bin/zigit
zig build test         # 43 unit tests
./tests/parity.sh      # 58 byte-for-byte checks vs real `git`
```

## Roadmap

Phase 7 — pack files (write) + `gc` (repack loose objects, expire packed-refs)
Phase 5 — `branch` / `switch` / `checkout`
Phase 6+ — pack files, smart HTTPS, merge/rebase

See the top-level commit messages for design notes per phase.
