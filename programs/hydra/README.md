# Hydra

Hydra is a GPU-accelerated brute-force search engine that pairs a CPU-side
orchestrator ("Queen") with a CUDA GPU executor to scan a numeric range for a
value whose hash matches a target.

## What it does

- **Queen (`src/queen.zig`)** — CPU-side orchestrator: generates work-unit
  batches over a `[start, end)` range and dispatches them to the GPU.
- **GPU kernel (`src/gpu_kernel.zig`)** — loads CUDA (`libcuda`) and NVRTC
  (`libnvrtc`) at runtime via `dlopen`, JIT-compiles the search kernel with
  NVRTC, and runs it. If no CUDA device / library is present, initialization
  returns an error and the caller reports the GPU as unavailable.
- **SIMD batch (`src/simd_batch.zig`)** — CPU SIMD hashing helpers and an
  AVX2/AVX-512 capability probe, used for the SIMD portion of the benchmark.
- **Work unit (`src/work_unit.zig`)** — shared work-unit header/result types
  and the batch generator.

## Build & run

Requires Zig 0.16. The CUDA GPU path targets NVIDIA hardware on Linux (the GPU
kernel `dlopen`s `libcuda.so` / `libnvrtc.so`). The CPU-only paths (argument
parsing, SIMD probe, unit tests) build and run without a GPU.

```sh
zig build            # build the hydra executable
zig build run        # run the search
zig build test       # run the unit tests
```

```
Usage: hydra [OPTIONS]

Options:
  --start <N>       Starting value for search (default: 0)
  --end <M>         Ending value for search (default: 100000000)
  --target <hex>    Target hash to find (hex string)
  --benchmark, -b   Run performance benchmark
  --help, -h        Show this help message
```

The `bench` step and the `hydra-bench` executable link CUDA directly and expect
the CUDA toolkit installed under `/opt/cuda` on a Linux/NVIDIA host.

## Tests

`zig build test` runs the inline tests in `work_unit.zig`, `simd_batch.zig`, and
`queen.zig`. The Queen test is GPU-gated: it skips itself
(`error.SkipZigTest`) when no CUDA device is available, so the suite passes on
machines without a GPU.

## Notes

- The NVRTC kernel is currently compiled for a fixed SM architecture
  (`compute_86`) rather than querying the device's compute capability.
