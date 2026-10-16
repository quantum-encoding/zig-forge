# 2026-09-28-pacing-16 — zterm on quantum-encoding-ltd

11th Gen Intel(R) Core(TM) i7-11800H @ 2.30GHz (16 CPUs, 62.6 GB), kernel 7.2.7-arch1-1, zig 0.16.0.

Recorded by `scripts/bench-run.py`; the metrics are defined in `src/bench.zig` and `src/viewbench.zig`. Each `report-<stamp>.json` holds every sample and the machine state at the time (power profile, AC, governor, load before and after).

Caveats: timings on a desktop in use are noisy. Read a change against the spread (min..max) of both runs, not the medians alone; `--quick` runs are smoke tests.

## What these runs show

Frame pacing at --frame-ms 16 on 1eafb37, interleaved with `2026-09-28-pacing-0`
(same binary, unpaced) to cancel load drift. Throughput through the server
rose (16 viewers: 3.6 -> ~11.4 MiB/s), but keypress_us and resize_ms rose to
the interval itself: that version held frames answering input when the key
came within one interval of the previous frame. Fixed in the next commit
(input window, 50 ms); see `2026-09-28-pacing-8-input`.
