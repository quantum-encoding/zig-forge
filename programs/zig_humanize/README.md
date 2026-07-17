# zig_humanize

A small Zig library for turning raw numbers, sizes, durations, and timestamps into human-readable strings (bytes, durations, thousands-separated numbers, ordinals, percentages, relative time, and grammatical lists).

All formatting functions are allocator-based and return an owned `[]const u8` that the caller must free.

## Public API

The consumable module is `zig_humanize` (see `src/lib.zig`), re-exporting from `src/humanize.zig`:

- `formatBytes(allocator, bytes)` / `formatBytesOptions(allocator, bytes, format)` — human-readable byte sizes. `ByteFormat.SI` uses 1000-based units (KB, MB, GB, ...); `ByteFormat.Binary` uses 1024-based units (KiB, MiB, GiB, ...).
- `formatDuration(allocator, milliseconds)` — durations as `ms` / `s` / `m` / `h` style strings.
- `formatNumber(allocator, value)` — thousands-separated integers.
- `ordinalSuffix(n)` / `formatOrdinal(allocator, n)` — ordinal suffixes (`1st`, `2nd`, `3rd`, ...).
- `formatPercentage(allocator, ...)` — percentage strings.
- `formatRelativeTime(allocator, ..., RelativeTimeOptions)` — relative time ("5 minutes ago", "in 2 hours").
- `formatList(allocator, items, ...)` — grammatical joins ("a, b, and c").

## Usage

Add the module in a consumer's `build.zig`:

```zig
const humanize = b.dependency("zig_humanize", .{ .target = target, .optimize = optimize });
exe_module.addImport("zig_humanize", humanize.module("zig_humanize"));
```

Then:

```zig
const humanize = @import("zig_humanize");

const s = try humanize.formatBytes(allocator, 1_500_000);
defer allocator.free(s);
// s == "1.50 MB"
```

## Build

```sh
zig build            # build the CLI executable and library
zig build run        # run the CLI
zig build test       # run the library tests
zig build bench      # run benchmarks
```

Requires Zig 0.16.0.
