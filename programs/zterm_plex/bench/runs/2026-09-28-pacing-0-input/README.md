# 2026-09-28-pacing-0-input — zterm on quantum-encoding-ltd

11th Gen Intel(R) Core(TM) i7-11800H @ 2.30GHz (16 CPUs, 62.6 GB), kernel 7.2.7-arch1-1, zig 0.16.0.

Recorded by `scripts/bench-run.py`; the metrics are defined in `src/bench.zig` and `src/viewbench.zig`. Each `report-<stamp>.json` holds every sample and the machine state at the time (power profile, AC, governor, load before and after).

Caveats: timings on a desktop in use are noisy. Read a change against the spread (min..max) of both runs, not the medians alone; `--quick` runs are smoke tests.

## What these runs show

The A/B that decided frame pacing, on the fixed server (52920f0: 8 ms pacing
plus the 50 ms input window), `--frame-ms 0`, interleaved with the other arm,
two runs each (n=10 per view metric). 8 ms vs unpaced: 16 viewers 3.8 -> 9.4
MiB/s (+145%, better in both pairs); keypress p50 22 vs 26 us and resize 0.050
vs 0.061 ms (no loss); nothing WORSE. One viewer is unchanged (11.6 vs 11.7
MiB/s): that stream is short `seq` lines, which the emulator core alone
ingests at ~17.5 MiB/s (feed_lines_mibs, added after these runs) — the limit
there is the per-line scroll, not frames.
