# zigit

Git, in Zig. From-scratch reimplementation of git's plumbing + porcelain,
binary-compatible with on-disk `.git/` directories. Single static binary,
no libgit2 dependency.

## Status

**Phases 1–10 complete** — every core git workflow is now covered.
zigit can `init / add / commit / log / status / diff / branch /
switch / checkout / gc / clone / push / merge / rebase`. Merges
fast-forward when possible, do a true three-way at file granularity
otherwise (refusing on real conflicts), and produce merge commits
with two parents that real git's `log --graph` walks correctly.
Rebase replays commits onto a new base via cherry-pick, aborting
cleanly on the first conflict.

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
| `zigit push URL [BRANCH]` | Push BRANCH (default = HEAD's branch) to URL via smart-HTTPS receive-pack (v1). URL may embed credentials: `https://user:token@host/path`. Sends only the new objects (computed via reachability closure exclusion). |
| `zigit merge BRANCH` | Fast-forward when possible, otherwise true 3-way at file granularity. On real conflicts (modify/modify, add/add, modify/delete) prints the path list + reason and exits non-zero. Merge commit has two parents and is recognised by `git log --graph`. |
| `zigit rebase ONTO` | Replay HEAD's commits since merge_base(HEAD, ONTO) on top of ONTO, cherry-pick style. Each commit becomes a new commit with the same message + author but a new parent. Aborts cleanly on the first conflict (work tree unchanged). |

## Build

```
zig build              # produces zig-out/bin/zigit
zig build test         # 70 unit tests
./tests/parity.sh      # 93 byte-for-byte checks vs real `git`
```

The parity suite includes a network-dependent clone test against
`https://github.com/octocat/Spoon-Knife` (skipped if offline) and a
local push test that spins up a Python wrapper around
`git-http-backend` (skipped if Python or git-http-backend isn't
available).

## Roadmap

Phases 1–10 cover every core git workflow. Polish items still open:

- Line-level conflict markers in merge (currently file-granularity)
- `restore` / `reset` / `tag` / `stash`
- ssh:// transport, credential helpers, `.git/config` `[remote]`
- Pack writer that deltifies (5–20× smaller packs)
- `prune`, reflog, multi-pack indexes

See the top-level commit messages for design notes per phase.
