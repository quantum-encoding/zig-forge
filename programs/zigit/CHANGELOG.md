# Changelog

All notable changes to zigit. Dates are ISO local-day stamps. Older
"Phase N" milestones (the original 17-phase build) are summarised at
the bottom; this file foregrounds the v1.0-track polish work.

## Unreleased — v1.0 polish

### Remote-tracking & daily-driver porcelain

- **`zigit fetch [REMOTE]`** — new command. Default remote is
  `origin`. Resolves `remote.<name>.url` from `.git/config`, runs
  `discoverV2` + `lsRefs`, downloads new objects via the existing
  smart-HTTP `fetch()` path (no have/want negotiation yet — accepts
  the fat pack), indexes the pack into `.git/objects/pack/`, then
  writes `.git/refs/remotes/<remote>/<branch>` for every advertised
  head. Skips the pack entirely when every advertised oid is already
  local (`"Already up to date — N ref(s) refreshed"`). Refs are
  written via tmp + rename so a crash mid-update can't leave a
  partial file.
- **`zigit pull [REMOTE]`** — orchestrator. No-arg form reads
  `branch.<current>.remote` + `branch.<current>.merge` from config
  (auto-wired by `clone`). With an explicit `REMOTE` arg, only the
  remote is overridden; the upstream branch still comes from config.
  Runs `fetch` first, then `merge refs/remotes/<remote>/<branch>`.
  Fast-forwards by default; falls through to three-way + conflict
  refusal otherwise.
- **`zigit status` — ahead/behind summary** in the long format only
  (porcelain stays clean). Reads `branch.<name>.remote` +
  `branch.<name>.merge` from config to find the upstream, looks up
  `refs/remotes/<remote>/<branch>`, then runs two commit-only graph
  walks + set difference for the counts. Five output states match
  git word-for-word:
  - `Your branch is up to date with 'origin/main'.`
  - `Your branch is ahead of 'origin/main' by N commit(s).`
  - `Your branch is behind 'origin/main' by N commit(s), and can be fast-forwarded.`
  - `Your branch and 'origin/main' have diverged, ...`
  - An "unresolvable" fallback when the remote ref exists but the
    objects aren't local (degraded fetch).

  The walks are commit-only (no tree/blob traversal), so the
  computation is O(commits-reachable) per side. No network — the
  user runs `zigit fetch` to refresh the local cache.

### Credential management

- **OS credential helper protocol** support in
  `src/net/credentials.zig`. zigit can now silently retrieve tokens
  from `git-credential-osxkeychain`, `git-credential-manager`,
  `git-credential-cache`, or any program that conforms to git's
  documented `gitcredentials(7)` protocol. Resolution order, in
  priority:
  1. URL-embedded `user:token@host`
  2. `credential.helper` from merged `~/.gitconfig` + `.git/config`
     (NEW)
  3. `~/.git-credentials`
  4. `GIT_ASKPASS` / `SSH_ASKPASS`

  Short-name helpers (`credential.helper = osxkeychain`) resolve via
  `git-credential-<name>` in PATH; absolute paths run directly;
  `!`-prefixed shell helpers are intentionally skipped to keep the
  spawn surface minimal.
- **Push, fetch, and clone now all consult the credential helper.**
  Previously only `push` did. `clone` and `fetch` extended via a new
  optional `authorization` arg on `smart_http.discoverV2`, `lsRefs`,
  and `fetch`.

### Output ergonomics

- **`zigit log --oneline`** — compact format matching git's default
  abbrev=7: `<7-char-short-oid> <subject>` per commit. Composes
  with `-n N`. Subject is everything up to the first `\n` in the
  commit message.
- **`zigit remote -v`** now emits BOTH `(fetch)` and `(push)` lines
  per remote (matches git). Push URL falls back to fetch URL when
  `remote.<name>.pushurl` is unset.  The non-verbose listing now
  sorts lexicographically too (git's behaviour); previously was
  insertion order.
- **`.gitmodules` warning** — `zigit status` (long format) and
  `zigit diff` print a single-line stderr notice when the work tree
  contains a `.gitmodules` file: `warning: this repository contains
  submodules, which zigit currently ignores`. Suppressed under
  `status --porcelain` to keep machine-parseable output clean.

### `zigit blame` (new)

A full implementation, byte-for-byte parity with
`git blame --porcelain` on the 7 fixtures the parity suite covers
(single-author, multi-author, file-unchanged-across-N-commits,
merge commit, file-created-mid-history, `-L` range, deletions).

- **Library**: `src/blame/region.zig` (pure region tracking + Myers
  diff splitting), `src/blame/blame.zig` (algorithm + caches),
  `src/blame/format.zig` (human + porcelain formatters).
- **Algorithm highlights**:
  - Priority queue keyed on author_time desc, OID tie-break, so the
    DAG walks newest-first without explicit topological sort.
  - Tree-OID short-circuit at file granularity (the big perf win for
    long-lived files in large repos).
  - Multi-parent merge handling that walks **every** parent of a
    merge commit, routing lines to the parent whose blob holds them
    unchanged. Only conflict-resolution content (present in no
    parent) attributes to the merge commit itself — matches git's
    semantics, not the naive first-parent-only shortcut.
  - Caches inside a per-call arena: parsed commits, tree-path → blob
    OID (keyed by tree OID so commits with identical trees share a
    lookup), blob bytes, line splits.
- **CLI**: `zigit blame [-L N[,M]] [--porcelain] [--verbose] PATH`.
  `-L N` (no upper bound) clamps to end of file; `--max-commits N`
  caps the walk; `--verbose` emits counters (`commits_examined`,
  `short_circuit_hits`, `diffs_run`).

### Push performance

- **Cached deltify base index** — `pack/deltify.zig` was rebuilding
  the chunk index of each candidate base for every target it
  evaluated. For a 95 MiB monorepo this manifested as 99% CPU for
  ~11 minutes before the first HTTP request. The planner now
  builds one `BaseIndex` per recent-window slot and reuses it
  across all targets. Cheap pre-filters (size ratio guard,
  `MAX_DELTIFY_BASE = 16 MiB`) skip pairs that can't plausibly
  win.
- **Walker dedupe at enqueue time** — the pop-time check was
  correct but let the queue balloon O(N × M) on deep monorepos.
- **`zigit push --verbose`** (or `ZIGIT_PUSH_VERBOSE=1`) prints
  per-phase ms via `Io.Clock.awake`. `--no-delta`
  (or `ZIGIT_PUSH_NO_DELTA=1`) bypasses the planner entirely as an
  emergency raw-only path.

### Clone correctness

- **`refs/remotes/origin/<active>`** now emitted in packed-refs
  alongside `refs/heads/<active>` for the active branch. Real git
  does this and it's what `status` looks up. Without it, the
  ahead/behind line was silently absent right after clone.

### Server-side (jesternet)

- **Pack parser switched from pako to fflate** in
  `lib/pack-parser.ts` (commit `a9917a6` in the jesternet repo).
  The old approach mis-handled bytes past `Z_STREAM_END`, throwing
  `incorrect header check` on the next object's zlib magic. The
  new strategy uses fflate's `unzlibSync` plus a doubling-then-
  binary search on slice length: for each object, find the
  smallest slice that inflates to exactly `hdr.size` bytes — that
  IS the compressed length. fflate is lenient about trailing
  bytes after the deflate body + adler32, which makes "succeeded
  with output.length === hdr.size" a monotone predicate, so the
  binary search converges in O(log N) probes. Each probe is a
  synchronous microseconds-scale inflation. End-to-end, a real
  `git push` of the jesternet repo (1.8 MB, hundreds of
  deltified objects from a real-git client) now lands in ~16 s
  and fits inside the Worker CPU budget. This is what unblocked
  zigit's push against jesternet end-to-end.

### Parity & tests

- **184 parity checks** vs real `git` (up from 156 at the last
  major checkpoint). New sections:
  - §28 (7) — blame `--porcelain` byte-for-byte.
  - §29 (9) — fetch + status ahead/behind across all five states.
  - §30 (6) — pull fast-forward + idempotence.
  - §31 (3) — credential helper invocation (witness-file scheme).
- **132 unit tests** (up from 109). New coverage in
  `src/blame/{region,blame,format}.zig`,
  `src/pack/deltify.zig` perf regression test, walker enqueue
  dedup test.

---

## Earlier — Phase 1–17 (the original 17-phase build)

Each phase landed as a single commit; see `git log` for full
details and design notes. Summary:

- **Phase 1–4** — plumbing: init, hash-object, cat-file,
  update-index, ls-files, write-tree, commit-tree, then add /
  commit / log / status / Myers diff.
- **Phase 5–7** — branch / switch / checkout, pack-file read +
  packed-refs, pack-file write + `gc` (passes
  `git fsck --strict` and `git verify-pack`).
- **Phase 8–9** — smart-HTTPS v2 read-only clone (works against
  GitHub) and v1 receive-pack push.
- **Phase 10–12** — merge (fast-forward + three-way at file
  granularity), rebase via cherry-pick, restore / reset / tag,
  diff3 line-level merge with conflict markers.
- **Phase 13–14** — stash (push / list / pop / drop), config +
  remote (round-trips with `git config`).
- **Phase 15–17** — URL classifier + `.git-credentials` +
  askpass, deltify pack writer (OFS_DELTA chains git can
  verify), reflog + prune + midx reader.

Today: 27 commands implemented, single ~7.9 MB static binary
without libc / libgit2 / curl. Suitable as a daily driver on
projects that don't depend on submodules, LFS, hooks, SSH
transport, or GPG signing.
