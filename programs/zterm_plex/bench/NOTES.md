# Benchmark notes

## Cell size is NOT the throughput lever (2026-07-17)

The June 2026 profiling note ("remaining limit is memory bandwidth on 16-byte
Cell writes — next lever is a narrower Cell") was tested before committing to
the 12-byte refactor (~123 hot-path field-access sites):

**Method.** Padded `Cell` 16B → 24B (+50%) with a dummy `u64` field — two
binaries, otherwise identical, run interleaved (16B, 24B, 16B, …) for 7 rounds
on a heavily loaded machine, comparing **minimum time per configuration**
(the minimum is the least-interfered run; interleaving cancels load drift).

**Result.** Best-of-7 MiB/s:

| metric | 16B | 24B (+50%) |
|---|---|---|
| emulator mixed (SGR-heavy) | 45.1 | 66.3 |
| emulator plain (SIMD path) | 72.7 | 78.7 |

A 50% LARGER cell benches as fast or faster at the minima. Any real size
effect is below run-to-run noise even at the minimum — i.e. parser/dispatch
cost dominates and the write path is not bandwidth-bound at current
throughput. A 16→12B shrink (−25%) can therefore not pay for its churn.

**Verdict.** Do not do the narrow-Cell refactor until something else lifts
parser throughput several-fold; re-run this A/B (pad probe is a 2-line diff in
`Cell`) before believing any future "cells are the bottleneck" claim.

## Recording runs (2026-09-28)

`scripts/bench-run.py` is how a run is recorded: it builds ReleaseFast, runs
`zterm-bench` (core) and `zterm-viewbench` (through a hermetic `zterm server`,
as a front end sees it), and writes `BENCH.md` + `bench/runs/<date>-<label>/`
in the layout the Experiments panel reads. Every metric keeps all its samples
and the machine state (power profile, AC, governor, load before/after).

Comparing: a change is called better/WORSE only with n >= 5 on both runs, a
median change above 5%, and non-overlapping min..max ranges. On this desktop
two runs of the SAME commit differed by 10-25% on most timings (load ~5), so
anything weaker reports regressions that are noise. For a comparison you will
act on, record both runs back to back on an idle machine on AC, same `--cpus`.

## results.csv (schema 1, superseded)

Not comparable with bench-run.py: its PTY figure included two 1-second idle
pumps (57.7 MiB/s measured to the last byte vs 5.7 recorded), and its
create/attach figures spawned the user's login shell, not /bin/sh.


`scripts/bench-track.sh [runs]` appends best-of-N rows here with the git rev
and fails (exit 1) on >10% regressions vs the previous row. Record the
canonical baseline on AC power with an idle machine — the first row (2026-07-16)
was captured on battery under heavy load and only documents that context.
