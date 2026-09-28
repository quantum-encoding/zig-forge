# 2026-09-28-pacing-0 — zterm on quantum-encoding-ltd

11th Gen Intel(R) Core(TM) i7-11800H @ 2.30GHz (16 CPUs, 62.6 GB), kernel 7.2.7-arch1-1, zig 0.16.0.

Recorded by `scripts/bench-run.py`; the metrics are defined in `src/bench.zig` and `src/viewbench.zig`. Each `report-<stamp>.json` holds every sample and the machine state at the time (power profile, AC, governor, load before and after).

Caveats: timings on a desktop in use are noisy. Read a change against the spread (min..max) of both runs, not the medians alone; `--quick` runs are smoke tests.

## What these runs show

The same binary as the pacing-8/16 runs with `--frame-ms 0`: the unpaced
server, the control arm of that A/B.
