# 2026-09-28-aa-noise — zterm on quantum-encoding-ltd

11th Gen Intel(R) Core(TM) i7-11800H @ 2.30GHz (16 CPUs, 62.6 GB), kernel 7.2.7-arch1-1, zig 0.16.0.

Recorded by `scripts/bench-run.py`; the metrics are defined in `src/bench.zig` and `src/viewbench.zig`. Each `report-<stamp>.json` holds every sample and the machine state at the time (power profile, AC, governor, load before and after).

Caveats: timings on a desktop in use are noisy. Read a change against the spread (min..max) of both runs, not the medians alone; `--quick` runs are smoke tests.

## Why this run exists

An A/A check: the same commit as `2026-09-28-baseline`, run straight after it
on the same machine under the same load (~5), to measure the noise the
comparison rule has to survive. Medians moved by up to 33% (reattach first
frame), 22% (keypress p50), 12% (stalled-viewer throughput); the rule called
all of them noise. Its one false positive, `attach_detach_us` (0.013 → 0.027
µs), is a ~15 ns registry lookup whose run-to-run value depends on the core
and clock it lands on, so it is now `trend_only`.

Its BENCH.md row says `0aae047+dirty`: the only uncommitted files were the
baseline run's own outputs (BENCH.md, bench/runs), which the dirty check then
counted. The code was 0aae047 exactly; the check now excludes those outputs.
