# zdedupe-bench

Times the zdedupe core (`programs/zdedupe`) at any commit, keeps every run, and records
the last good commit so a tweak can always be undone.

It lives outside `programs/zdedupe` on purpose: `scripts/zig-source-id.sh` covers every
file under a program, so results kept there would change the core's identity on every
run and make tauri_apps/zdedupe's vendored-core gate call its core stale.

## The loop

```bash
B=tools/zdedupe-bench/bench.py
$B good                         # the last good commit, its numbers, what changed since
# edit programs/zdedupe/src/...
$B run . GOOD_SHA               # working tree against the last good core, interleaved
$B compare GOOD_SHA .           # the verdict again, from the ledger, without rerunning
```

- **Better, and the results are the same**: commit the change, `$B run HEAD`, then
  `$B good HEAD --note "what it bought"`. Commit `results/` and `good.json` with it.
- **Worse**: throw the edit away (`git restore programs/zdedupe`), or, once commits have
  landed, `$B restore` prints how to bring the last good core back as a new commit
  (`--apply` stages it). What was tried stays in history; vendor the restored core into
  tauri_apps/zdedupe with `scripts/vendor-core.sh HEAD`.

`compare` exits 1 on a regression or when two builds found different things, so it can
gate a script.

## What a run is

`bench.py run REF...` builds each REF's core as it ships (`zig build-lib -OReleaseFast
-mcpu baseline` with compiler-rt, the Zig `scripts/zig-toolchain.sh` picks) from a
`git archive` export, links `phasebench.c` against it, and scans each target with the
macOS app's default settings (hidden files, build output and credential stores
excluded). REF `.` is the working tree, uncommitted edits included.

Per target: one untimed warm-up, then `-n` rounds with the builds interleaved. Each run
appends one line to `results/<host>.jsonl`: wall and CPU seconds per phase (CPU / wall =
cores kept busy), peak RSS, the load average at the start, and a digest of everything
the scan found. The numbers are warm-cache: they measure the core, not the disk.

A build is known by its source id and toolchain, not its commit, so commits that leave
the core alone share one build and one history.

| Target | What it exercises |
|---|---|
| `small` | 100,000 files of 100 B–48 KiB, 40% duplicates: per-file cost (walk, open, hash) |
| `clones` | 8,000 identical files in 4,000 APFS clone pairs: grouping and clone accounting (macOS) |
| `big` | six 1 GiB files of one size: chunked comparison of large candidates |
| `compare` | Compare mode (and the check behind a permanent folder delete): 20,000 files and four 512 MiB files per side |
| `-p PATH` | a real tree, duplicates mode |
| `--compare-paths A B` | two real folders, Compare mode |

Fixtures are made once under `~/.cache/zdedupe-bench/fixtures` (about 10 GB;
`ZDEDUPE_BENCH_HOME` moves everything) and remade only when a target's recipe version
changes.

## Notes

- `bench.py once PATH... -- -L 5` builds the working tree and runs one scan with
  phasebench's own output (`-L` logs rates and the longest-running path; `-C` cancels when
  stuck). The build keeps its symbols, so `sample` on it names functions.
- A commit from before the Zig 0.17 port needs `--zig /path/to/zig-0.16`; the toolchain
  is part of the build's identity, so its runs are kept apart.
- With an Endpoint Security client installed, an agent's process tree can be authorized
  on a slower path than an app. `--detached` runs each scan as a launchd job instead.
  Builds compared in the same mode are compared fairly either way.
