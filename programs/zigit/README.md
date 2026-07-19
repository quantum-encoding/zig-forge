# zigit

Git, in Zig. From-scratch reimplementation of git's plumbing + porcelain,
binary-compatible with on-disk `.git/` directories and the smart-HTTP
wire protocol. Single static binary, no libc, no libgit2 dependency.

## Status — v1.0

**27 commands shipped, 184 parity checks against real `git`, 132 unit
tests, single ~7.9 MB static binary.** Daily-driver ready against any
HTTPS-accessible git server (GitHub, GitLab, Forgejo, jesternet, …).

zigit can do everything a typical developer workflow needs:

```
init      add       commit       log [--oneline]     status [-s] (ahead/behind aware)
diff      branch    switch       checkout            tag        stash
merge     rebase    restore      reset               remote -v
gc        prune     reflog       blame [--porcelain]
clone     fetch     pull         push
```

Plus the plumbing primitives (`hash-object`, `cat-file`,
`update-index`, `ls-files`, `write-tree`, `commit-tree`).

Daily-driver porcelain that previous versions lacked but v1.0 ships:

| Capability | Notes |
|---|---|
| `zigit fetch [REMOTE]` | smart-HTTP v2 incremental fetch with pack download. Writes `.git/refs/remotes/<remote>/<branch>`. |
| `zigit pull [REMOTE]` | Fetch + merge orchestrator. Fast-forwards when possible. |
| `zigit status` ahead/behind | Reads the local remote-tracking ref, computes commit-only ahead/behind via two graph walks + set difference. Matches git's wording for all five states. |
| `zigit blame [-L N,M] [--porcelain]` | Full line-level attribution. Tree-OID short-circuit at file granularity is the perf hot-path. Multi-parent merge handling: only conflict-resolution content attributes to the merge commit. Byte-for-byte porcelain parity with real git. |
| `zigit log --oneline` | Compact `<7-char-short-oid> <subject>` form. Byte-parity with git. |
| `zigit remote -v` | Emits both `(fetch)` and `(push)` lines per remote, sorted lexicographically. |
| OS credential helpers | `credential.helper = osxkeychain` (or `manager`, `cache`, any conformant helper) — zigit silently retrieves tokens during clone/fetch/push via git's documented `gitcredentials(7)` protocol. |

## Build

```
zig build               # produces zig-out/bin/zigit
zig build test          # in-tree unit tests, ~5 s
zig build parity        # byte-for-byte checks vs real `git` (needs system git)
./tests/parity.sh       # the same parity harness, invoked directly
```

The parity suite includes a network-dependent clone test against
`https://github.com/octocat/Spoon-Knife` (skipped if offline) and
local push/fetch/pull tests that spin up a Python wrapper around
`git-http-backend` (skipped if Python or git-http-backend isn't
available).

## On-disk + wire compatibility

| Format | Read | Write | Notes |
|---|---|---|---|
| Loose object | yes | yes | `<kind> <size>\0` + zlib. SHA-1 matches `git hash-object`. |
| Index v2 | yes | yes | Trailing SHA matches. |
| Pack v2 | yes | yes | OFS_DELTA chains emitted by `gc` + `push`; verified by `git verify-pack`. |
| Pack index v2 | yes | yes | Built directly by zigit; verified by `git verify-pack`. |
| Multi-pack-index | yes | no | Reader uses git-written midx files for object lookup. |
| `packed-refs` | yes | yes | Written by `clone` + `gc`. |
| `.git/config` | yes | yes | INI subset; round-trips with `git config`. |
| Reflogs | yes | yes | Format matches git's. |
| Smart-HTTP v2 (clone / fetch) | yes | n/a | `Git-Protocol: version=2`, ls-refs + fetch with ofs-delta + thin-pack. |
| Smart-HTTP v1 receive-pack (push) | yes | n/a | `report-status`, `ok refs/heads/X` parsed. |

## Not implemented (the honest list)

These are intentional v1.0 cuts. The CHANGELOG and source comments
flag each gap; if any blocks your workflow, it's a v1.1 candidate.

- **Transports beyond HTTPS** — `ssh://`, `git@host:path`, `git://`
  all return a clean "not yet implemented" message. Only smart-HTTPS
  is supported.
- **Submodules** — no `submodule` command, `.gitmodules` is treated
  as an ordinary file. `status` and `diff` print a one-line warning
  to stderr when `.gitmodules` is present.
- **Sparse / partial / shallow clone** — clone always fetches the
  full history.
- **Cherry-pick / revert as commands** — the cherry-pick mechanic
  exists internally (rebase uses it) but isn't exposed.
- **Hooks, GPG signing, LFS, bisect, worktree, blame --follow,
  grep, archive** — none.
- **`log` flag richness** — `log` supports `--oneline` and `-n N`
  but not `--graph` / `--pretty=format:` / `--author` / `--since`.

## v1.0 highlights

- **27 commands** across plumbing + porcelain.
- **OS keychain integration** via the standard credential-helper
  protocol — your existing `git config credential.helper osxkeychain`
  Just Works.
- **Push perf rewrite** — a 95 MiB monorepo that previously hung the
  deltify planner for ~11 min CPU-bound now completes in seconds
  (cached chunk index per recent-window slot, cheap pre-filters).
- **Server-side jesternet fix** (`fflate` pack parser) unblocked push
  against the Workers backend end-to-end; see `CHANGELOG.md` for the
  details.

See `CHANGELOG.md` for the full v1.0-track changelog, including the
blame implementation, fetch/pull/status ahead/behind, credential
helpers, and the older Phase 1–17 build summary.

## Internals tour

```
src/
├── main.zig              CLI dispatch
├── lib.zig               library re-exports for embedders
├── repo.zig              .git discovery, loose+pack store wiring
├── workdir.zig           file walk + lstat
├── worktree.zig          checkout / restore materialisation
├── config.zig            INI parser/writer + merged ~/.gitconfig overlay
├── reflog.zig            .git/logs/* read/write
├── cli/                  28 command modules
├── object/               oid / kind / loose-store / commit / tree / walker
├── index/                index v2 file + entry
├── refs/                 ref resolution (symbolic + direct + packed-refs)
├── pack/                 pack reader/writer, idx reader/writer, deltify, midx reader
├── net/                  smart-http v2 + v1, pkt-line, auth, url, credentials
├── diff/                 myers + unified + diff3
├── merge/                three-way + merge-base
└── blame/                region tracking + algorithm + formatters

tests/
├── parity.sh             184 checks vs real git, 31 sections
└── git_http_server.py    Python wrapper around git-http-backend
                          for push / fetch / pull / credential-helper tests
```

Each module has a header-comment explaining the algorithm and
on-disk shape — built to be read.
