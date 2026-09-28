# zterm benchmark runs

One row per `scripts/bench-run.py` run; the report behind each row is `bench/runs/*/report-<stamp>.json`.

| commit | date | machine | mixed MiB/s | plain MiB/s | cjk MiB/s | redraw MiB/s | pty MiB/s | key p50 µs | view MiB/s | view×16 MiB/s | 10k history ms | server RSS MB | flags | stamp |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 0aae047 | 2026-09-28 | quantum-encoding-ltd | 67.376 | 157.5 | 54.822 | 360.3 | 69.570 | 21.230 | 11.202 | 3.871 | 19.111 | 22.090 | --repeat 5 | 20260928T161730 |
| 0aae047+dirty | 2026-09-28 | quantum-encoding-ltd | 72.346 | 163.8 | 56.285 | 348.2 | 66.356 | 25.948 | 10.295 | 3.869 | 15.109 | 22.130 | --repeat 5 | 20260928T161834 |
