# zigit

Git, in Zig. From-scratch reimplementation of git's plumbing + porcelain,
binary-compatible with on-disk `.git/` directories. Single static binary,
no libgit2 dependency.

## Status

**Phases 1–8 complete** — full local stack + smart-HTTPS read-only
clone. zigit can fetch from real GitHub repos over HTTPS using
protocol v2: `zigit clone https://github.com/...` resolves HEAD to
the same oid `git clone` does, sets up `refs/heads/<active>` +
`refs/remotes/origin/*` the same way, materialises the work tree,
and the resulting `.git` passes `git fsck --strict`.

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
| `zigit gc` | Pack all loose objects + loose refs into a single pack + `packed-refs`. Output passes `git fsck --strict` and `git verify-pack` |
| `zigit clone URL [PATH]` | Read-only smart-HTTPS v2 clone. Active branch lands at `refs/heads/<branch>`, others at `refs/remotes/origin/<branch>` (matching real `git clone`). Work tree is materialised |

## Build

```
zig build              # produces zig-out/bin/zigit
zig build test         # 58 unit tests
./tests/parity.sh      # 75 byte-for-byte checks vs real `git`
```

The parity suite includes a network-dependent clone test against
`https://github.com/octocat/Spoon-Knife`; it self-skips when offline.

## Roadmap

Phase 9 — `push` (smart-HTTPS receive-pack), then merge / rebase
Phase 5 — `branch` / `switch` / `checkout`
Phase 6+ — pack files, smart HTTPS, merge/rebase

See the top-level commit messages for design notes per phase.
