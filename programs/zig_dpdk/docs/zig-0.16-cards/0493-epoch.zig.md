# Migration Card: std/time/epoch.zig

## 1) Concept

This file provides epoch reference times and calendar/time calculation utilities for various timestamp systems. It defines constants for different epoch systems (POSIX, DOS, Windows, etc.) and provides types and functions for converting between epoch seconds and calendar components like years, months, days, and time-of-day.

Key components include epoch constants for different systems, leap year calculations, date/time decomposition utilities (`EpochSeconds`, `EpochDay`, `DaySeconds`), and calendar arithmetic functions for working with years, months, and days.

## 2) The 0.11 vs 0.16 Diff

This file contains minimal breaking changes between 0.11 and 0.16 patterns. The main differences are:

- **Enum casting syntax**: Uses new `@intFromEnum` and `@enumFromInt` syntax instead of the older casting patterns
- **Integer casting**: Uses explicit type casting with `@as` and `@intCast` for type safety
- **Pure computation**: No allocator requirements or I/O changes since this is a mathematical utility module
- **Error handling**: Functions are pure computations without error returns

The API structure remains largely the same with simple struct initialization and method calls.

## 3) The Golden Snippet

```zig
const std = @import("std");
const epoch = std.time.epoch;

// Convert epoch seconds to calendar components
const seconds_since_epoch: u64 = 1622924906;
const epoch_seconds = epoch.EpochSeconds{ .secs = seconds_since_epoch };

const epoch_day = epoch_seconds.getEpochDay();
const day_seconds = epoch_seconds.getDaySeconds();

const year_day = epoch_day.calculateYearDay();
const month_day = year_day.calculateMonthDay();

const hours = day_seconds.getHoursIntoDay();
const minutes = day_seconds.getMinutesIntoHour();
const seconds = day_seconds.getSecondsIntoMinute();

// Use epoch constants
const windows_epoch = epoch.windows;
const unix_epoch = epoch.unix;
```

## 4) Dependencies

- `std.math` - For mathematical operations and comptime modulus
- `std.testing` - For test framework (test-only dependency)

The module has minimal dependencies and focuses on mathematical computations for time/date conversions.