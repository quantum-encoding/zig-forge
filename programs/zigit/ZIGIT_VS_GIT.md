# zigit vs git — state of the implementation

A snapshot comparison between zigit (this tree) and upstream `git` 2.52.
Generated 2026-05-19.

## TL;DR

zigit is a from-scratch reimplementation of git's plumbing + porcelain
in Zig, binary-compatible with on-disk `.git/` directories and the smart
HTTP wire protocol. Single static ~7.9 MB executable, no libc, no
libgit2 dependency. 27 commands implemented through 17 phases.
156 parity checks pass byte-for-byte against real `git` across all
covered surface area; 109 unit tests pass.

Where zigit currently differs from git: the CLI flag surface is
narrower (one or two flags per command, not the full git-style menu),
there is no SSH transport, no submodules, no sparse checkout, no LFS,
no hooks, no GPG signing, no worktrees, no bisect, no cherry-pick (the
internals exist via rebase), and the merge conflict UX is line-marker
output rather than git's full rerere/`mergetool` machinery.

## Build & footprint

|                          | zigit                      | git 2.52 (Homebrew)      |
|--------------------------|----------------------------|--------------------------|
| Source LOC               | 13 567 lines of Zig        | ~300 k lines of C        |
| Build dependency         | Zig 0.16 compiler          | C toolchain + zlib + curl + openssl/libressl + iconv + expat + … |
| `link_libc`              | no                         | yes                      |
| Distributed binary       | one static ELF/Mach-O      | one `git` driver + 178 helper binaries in `libexec/git-core/` |
| Installed size on disk   | 7.9 MB                     | 61 MB (Homebrew cellar)  |
| Driver binary size       | 7.9 MB                     | 3.6 MB                   |

zigit is bigger as a single binary because everything (TLS, pack
encoding, diff, merge, smart-HTTP) is statically linked in. The actual
install footprint is ~8 % of upstream git's, and there is one binary
to ship instead of 179.

## Command parity

### Plumbing — implemented

| Command | Coverage |
|---|---|
| `init [path]` | `.git/` skeleton + `HEAD` → `refs/heads/main`. Byte-identical layout to `git init`. |
| `hash-object [-w] [-t kind] [--stdin] FILE` | SHA-1 with the `<kind> <size>\0` framing; `-w` writes the loose object. |
| `cat-file (-p\|-t\|-s\|-e) OID` | Type, size, exists, pretty-print. SHA prefix lookup ≥ 4 chars. Tree pretty-print byte-matches git's. |
| `update-index --add FILE...` | Writes index v2 with the same trailer SHA. |
| `ls-files [-s\|--stage]` | With or without mode/oid/stage columns. |
| `write-tree` | Persists the index as nested trees, prints root oid. |
| `commit-tree TREE [-p PARENT]... -m MSG` | Reads `GIT_AUTHOR_*` / `GIT_COMMITTER_*` from env. |

### Porcelain — implemented

| Command | Coverage |
|---|---|
| `add FILE...` | Wraps `update-index --add`. |
| `commit -m MSG` | Identity falls back env → `.git/config` `[user]` → `"zigit"`. Writes reflog. |
| `log [-n N]` | First-parent walk from HEAD. |
| `status [-s\|--porcelain]` | Three-way diff (HEAD vs index, index vs workdir, untracked). `--porcelain` matches git byte-for-byte. |
| `diff [--cached] [PATHSPEC...]` | Myers + unified diff. Output byte-identical to `git diff` for the covered cases. |
| `branch [-d\|-D] [NAME [START]]` | List / create / delete. Refuses to delete the current branch. |
| `switch [-c] NAME` | Updates HEAD + index + workdir. Refuses if local edits would be lost. |
| `checkout TARGET` | Branch → switch; commit oid (full or ≥ 4-char prefix) → detached HEAD. |
| `gc` | Packs loose objects + refs. Output passes `git fsck --strict` and `git verify-pack`. |
| `clone URL [PATH]` | Smart-HTTPS v2. Active branch lands at `refs/heads/<branch>`, others at `refs/remotes/origin/<branch>`. Materialises work tree. |
| `push URL [BRANCH]` | Smart-HTTPS v1 receive-pack. Computes the reachability closure and only ships new objects. Embedded credentials (`https://user:tok@host`) + `.git-credentials` + askpass. `--verbose` for per-phase timing; `--no-delta` to bypass the deltify planner. |
| `merge BRANCH` | Fast-forward when possible, otherwise true 3-way at file granularity. diff3-aware: disjoint hunks resolve, overlap → conflict markers. |
| `rebase ONTO` | Cherry-pick replay since `merge_base(HEAD, ONTO)`. Aborts cleanly on first conflict, work tree unchanged. |
| `restore [--staged] PATH...` | Restore from index, or HEAD with `--staged`. |
| `reset [--soft\|--mixed\|--hard] [TARGET]` | Move HEAD ± rewrite index ± rewrite workdir. |
| `tag [-d] [NAME [COMMIT]]` | List / create / delete lightweight tags. |
| `stash <push\|list\|pop\|drop>` | Save/restore work-tree state via `refs/stash` + reflog. |
| `remote [-v\|add\|remove\|show]` | Read/writes `[remote "..."]` blocks in `.git/config`. Round-trips with git. |
| `reflog [show [REF]]` | Walks `.git/logs/refs/...`. Format matches git's. |
| `prune [--dry-run]` | Drops unreferenced loose objects. |

### Not implemented

The deliberate cuts that have not landed yet:

- **Transports beyond HTTPS** — `ssh://`, `git@host:path`, and `git://`
  all return a clean "not yet implemented" message at the CLI boundary.
  Only smart-HTTPS is supported.
- **Submodules** — no `submodule` command, `.gitmodules` is treated as
  an ordinary file.
- **Sparse checkout / partial clone / shallow clone** — `clone` always
  fetches the full history.
- **Cherry-pick / revert as commands** — the cherry-pick mechanic
  exists internally (rebase uses it) but isn't exposed.
- **Bisect, worktree, blame, grep, archive** — not present.
- **Hooks** — none of the `.git/hooks/*` lifecycle is invoked.
- **Signing** — no GPG/SSH commit signing or verification.
- **LFS, attributes, ignore-revs, sparse-index, fsmonitor, multi-pack-index writer** — none. The midx **reader** is wired in (zigit reads `git`-written `.git/objects/pack/multi-pack-index` files) but zigit does not yet write one.
- **Symlinks (mode 120000)** — currently materialised as regular files.
  Marked TODO in `src/worktree.zig`.

The CLI flag surface for implemented commands is also smaller than
git's — for example `log` supports `-n N` but not `--oneline`,
`--graph`, `--pretty`, `--author`, `--since`, etc.

## On-disk format compatibility

| Format | Read | Write | Notes |
|---|---|---|---|
| Loose object (`.git/objects/ab/cdef…`) | yes | yes | `<kind> <size>\0` framing, zlib-deflated. SHA-1 matches `git hash-object`. |
| Index v2 (`.git/index`) | yes | yes | Trailing SHA matches; `git ls-files -s` reads zigit-written indexes. |
| Pack v2 (`pack-<sha>.pack`) | yes | yes | OFS_DELTA chains emitted by `gc`; verified by `git verify-pack`. |
| Pack index v2 (`pack-<sha>.idx`) | yes | yes | Fan-out + sha + crc + offset tables. Verified by `git verify-pack`. |
| Multi-pack-index (`multi-pack-index`) | yes | no | Reader only — `git`-written midx files are used for object lookup; zigit doesn't emit one. |
| `packed-refs` | yes | yes | Written by `gc` after packing loose refs. |
| Symbolic refs (`HEAD`, `refs/heads/*`) | yes | yes | Both the `ref: refs/heads/x` and direct-oid forms. |
| `.git/config` (INI subset) | yes | yes | Sections + dotted keys (`remote.origin.url`, `user.email`, etc.). Round-trips with git. |
| `.git-credentials` | yes | n/a | Helper-style file; consulted on push. |
| Reflogs (`.git/logs/refs/*`) | yes | yes | Format matches git's; git's `reflog` reads zigit-written entries. |

The parity suite (`tests/parity.sh`) exercises every one of these
formats in both directions — zigit-writes → git-reads and
git-writes → zigit-reads — across 156 individual checks.

## Wire protocol coverage

| Protocol | Direction | Implementation |
|---|---|---|
| Smart-HTTP v2 (`Git-Protocol: version=2`) | clone / fetch | `discoverV2` → `lsRefs` → `fetch` with `ofs-delta` + `thin-pack` caps. Server reply demuxes sideband 0x01 (pack data), 0x02 (progress → stderr), 0x03 (fatal). |
| Smart-HTTP v1 receive-pack | push | `discoverV1ForReceive` → `pushPack` (`<old> <new> <ref>\0report-status` + pack body). Parses `unpack ok` / `ok refs/heads/X`. |
| pkt-line framing | both | RFC-compliant `<4 hex><payload>` with `0000` flush and `0001` delim. |
| Auth | both | URL-embedded `user:token@`, `.git-credentials`, askpass. Basic auth header. |

There is no `git://` (custom-port unauthenticated) or SSH transport;
they are explicit "not yet implemented" returns at the CLI.

## Pack format coverage

| Capability | Read | Write |
|---|---|---|
| Raw `commit` / `tree` / `blob` / `tag` entries | yes | yes |
| `OFS_DELTA` chains (variable-length negative offset) | yes | yes (gc + push) |
| `REF_DELTA` chains (20-byte base oid) | yes | no — zigit never emits these (it picks OFS) but can resolve them on read |
| Thin packs from server | yes (via fallback to loose store for missing bases) | does not send thin packs |
| Delta chain depth | up to `max_delta_depth = 50` (matches git default) | bounded by planner window |
| Deltify planner | n/a | sort-by-size, 10-entry recent window, BaseIndex cache, cheap pre-filters (target ≥ 16 B, base ≤ 16 MiB, target ≥ base/8) |

zigit's deltify is intentionally conservative versus git's
`pack-objects`, which does smarter name-hashing and path-bucketing. On
the test corpus (Section 23 of parity.sh) zigit-deltified packs are
within a few percent of git's size and resolve identically.

## Diff / merge algorithms

- **Diff**: Myers SES with the standard linear-space refinement
  (`src/diff/myers.zig`). Unified-format output matches `git diff` byte
  for byte for the cases the parity suite covers.
- **Merge**: file-granularity 3-way with diff3-aware hunk-level
  resolution. Disjoint hunks resolve; overlapping hunks emit
  `<<<<<<<` / `=======` / `>>>>>>>` markers and the merge aborts. No
  rerere, no `mergetool` orchestration.
- **Rebase**: cherry-pick style replay. No interactive rebase, no
  `--autosquash`, no `--onto`-with-different-base ergonomics.

## Performance characteristics

| Operation | Notes |
|---|---|
| `hash-object`, `cat-file` | Same order of magnitude as git for single objects. |
| `add`, `status` on a small repo | Single-digit ms — comparable to git. |
| `gc` on a fresh repo | Packs all loose objects + emits OFS_DELTA. Output verified by `git verify-pack`. |
| `push` (95 MiB monorepo) | Used to burn 99 % CPU for ~11 min before sending bytes (rebuilt the deltify chunk index per pair). After the perf fix on this branch, the planner caches one `BaseIndex` per recent-window slot and applies cheap bail-outs (`MAX_DELTIFY_BASE` = 16 MiB, size-ratio guard, ≥ CHUNK size floor). `zigit push --verbose` now prints per-phase ms via `Io.Clock.awake`. |

zigit's reachability walker (`src/object/walker.zig`) dedupes at
enqueue time, so the queue is bounded by `|unique reachable objects|`
rather than `|commits × tree-entries|`. This matters on monorepos with
deep trees that share many blobs across commits.

No benchmarks against git on a large repo have been recorded in this
tree yet; the comparison above is qualitative.

## Test coverage

- **Unit tests** (`zig build test`): 109 tests across object kinds,
  index round-trip, pack read/write, deltify encode/decode + planner,
  Myers diff, three-way merge, smart-HTTP framing, midx reader,
  reflog, prune. Runs in ~5 s.
- **Parity tests** (`tests/parity.sh`): 156 checks across 27 sections.
  Each check shells out to real `git` and asserts byte-for-byte output
  agreement. Covers SHA-1 framing, loose-object cross-interop in both
  directions, cat-file modes, index, write-tree, commit-tree, add /
  commit / log, status, diff, branch/switch/checkout, pack read+write,
  clone, push, merge (FF + 3-way + conflict refusal), rebase,
  restore/reset/tag, diff3-aware merge, stash, config+remote, deltify,
  credentials + URL classification, reflog, prune, and reading a
  real-git-written multi-pack-index.

The clone test pulls `github.com/octocat/Spoon-Knife` over real
HTTPS (skipped if offline). The push test spawns a local
`git-http-backend` via the Python wrapper in `tests/git_http_server.py`
(skipped if Python or git-http-backend aren't available).

## What "compatible" means concretely

| Scenario | Works? |
|---|---|
| `git clone $(zigit-pushed-url)` | yes (parity §16 / §23) |
| `zigit clone https://github.com/...` | yes (parity §15) |
| `zigit add` a file, then `git commit` it | yes (index round-trip — parity §6) |
| `git add` a file, then `zigit commit` it | yes |
| `zigit gc`, then `git fsck --strict` | yes (parity §14) |
| `git gc`, then `zigit cat-file -p OID` | yes (parity §13) |
| `zigit push` to a real GitHub repo | yes — `https://user:token@github.com/...` |
| Merge conflict produced by zigit, resolved with `git mergetool` | unmarked: conflict markers are standard git format, but `mergetool` integration isn't tested |
| `zigit log --graph` | no — `--graph` not implemented |
| `git submodule update` inside a zigit-cloned repo | no submodule support |
| `git lfs pull` | not implemented |

## Recommended use

zigit today is suitable for:

- everyday plumbing/porcelain on personal projects when you want a
  single static binary instead of the 61 MB Homebrew tree
- embedding into other Zig tooling that needs to read/write git
  repos without dragging in libgit2
- learning the git internals — every module has a header comment
  explaining the algorithm and on-disk shape

It is **not** suitable for:

- repos that depend on submodules, LFS, or hooks
- shops that rely on signed commits / tags
- workflows that require SSH transport
- power users who depend on flag-rich subcommands (`log --pretty=format:`,
  `diff --color-words`, `rebase -i`, etc.)

## Roadmap candidates, ordered by impact

1. **SSH transport** — biggest functional gap. Either shell out to
   `ssh` like libgit2 fallback does, or implement openssh client
   handshake natively.
2. **Submodules** — read+write `.gitmodules` and recurse on clone /
   status / update.
3. **Interactive rebase + cherry-pick command** — internals exist;
   surfacing them is mostly UX.
4. **`log` flags** — `--oneline`, `--graph`, `--pretty=format:`,
   `--author`, `--since`. Most-requested missing surface.
5. **Multi-pack-index writer** — reader is in, writer would let large
   repos avoid scanning every `.idx` on each lookup.
6. **Hooks** — `.git/hooks/pre-commit` etc. shelled out at the
   appropriate lifecycle points.
7. **Symlinks (mode 120000)** — small but currently incorrect.

## File-level layout

```
src/
├── main.zig              CLI dispatch
├── lib.zig               library re-exports
├── repo.zig              .git discovery, loose+pack store wiring
├── workdir.zig           checkout / restore materialisation
├── worktree.zig          mode/perm helpers
├── config.zig            INI parser+writer
├── reflog.zig            .git/logs/* read/write
├── cli/                  27 command modules
├── object/               oid / kind / loose-store / commit / tree / walker
├── index/                index v2 file + entry
├── refs/                 ref resolution (symbolic + direct + packed-refs)
├── pack/                 pack reader/writer, idx reader/writer, deltify, midx reader
├── net/                  smart-http v2 + v1, pkt-line, auth, url, credentials
├── diff/                 myers + unified + diff3
└── merge/                three-way + merge-base

tests/
├── parity.sh             156 checks vs real git, 27 sections
└── git_http_server.py    Python wrapper around git-http-backend for push tests
```
