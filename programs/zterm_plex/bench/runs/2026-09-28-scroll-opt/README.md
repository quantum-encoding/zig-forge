# 2026-09-28-scroll-opt — zterm on quantum-encoding-ltd

11th Gen Intel(R) Core(TM) i7-11800H @ 2.30GHz (16 CPUs, 62.6 GB), kernel 7.2.7-arch1-1, zig 0.16.0.

Recorded by `scripts/bench-run.py`; the metrics are defined in `src/bench.zig` and `src/viewbench.zig`. Each `report-<stamp>.json` holds every sample and the machine state at the time (power profile, AC, governor, load before and after).

Caveats: timings on a desktop in use are noisy. Read a change against the spread (min..max) of both runs, not the medians alone; `--quick` runs are smoke tests.

## What this run shows

The per-line scroll work (fc4624d) and the input-exemption fix (c70eba5).
The row above in BENCH.md is the recorded state at c70eba5; its automatic
comparison says "not comparable" because zterm-viewbench moved to schema 2
(3M-line streams). The before/after evidence is the interleaved A/B in `ab/`,
same machine, same hour, alternating builds, n=10 per metric per side:

Core (zterm-bench, 40054d1 vs fc4624d): short lines 15.9 -> 49.9 MiB/s
(3.15x), mixed SGR 68.5 -> 142.6 (2.08x), plain 160.5 -> 278.8 (1.74x),
PTY ingest 60.4 -> 68.7; CJK and full-screen redraw unchanged (other paths).

Through a server (zterm-viewbench schema 2, one client binary, server
40054d1 vs c70eba5): output with 1/4/16 viewers and a stalled one
1.85-1.96x (1 viewer 13.3 -> 24.5 MiB/s); frames/s during a flood 187 ->
126.05 (the old 50 ms input window sent a frame per read at the start);
keypress p50 24.6 vs 28.5 us with overlapping ranges, p99 100.1 vs 100.4.
The comparison rule called every throughput metric better in both pairs and
nothing worse.

Machine: load 5-7 throughout (desktop in use); treat single medians as
approximate, the pair verdicts as the result.
