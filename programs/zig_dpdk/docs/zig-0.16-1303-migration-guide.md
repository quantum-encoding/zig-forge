# Zig 0.16.0-dev.1303 Migration Guide

## Overview

This document details all breaking changes and fixes required to migrate a Zig codebase from earlier 0.16 versions to **Zig 0.16.0-dev.1303+ee0a0f119**.

Migration Date: 2025-11-23
Project: zig-financial-engine (High-frequency trading system)

---

## Critical Breaking Changes

### 1. Build System API Changes

#### Module System Refactor

**Old API (Zig 0.16 early versions):**
```zig
const exe = b.addExecutable(.{
    .name = "my-app",
    .root = b.path("src/main.zig"),
    .target = target,
    .optimize = optimize,
});
```

**New API (0.16.0-dev.1303):**
```zig
const exe = b.addExecutable(.{
    .name = "my-app",
    .root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    }),
});
```

**Key Changes:**
- `.root` field removed
- `.root_module` now required
- Must use `b.createModule()` to create module configuration
- `target` and `optimize` moved inside module configuration

**Files Modified:**
- `build.zig` - All executable definitions

---

### 2. Time API Complete Removal

#### timestamp() Function Removed

**Old API:**
```zig
const now = std.time.timestamp();
```

**New API:**
```zig
const now = @as(i64, @intCast((std.posix.clock_gettime(std.posix.CLOCK.REALTIME) catch unreachable).sec));
```

**Explanation:**
- `std.time.timestamp()` completely removed
- Must use POSIX `clock_gettime()` directly
- Returns `timespec` struct with `.sec` (seconds) and `.nsec` (nanoseconds)
- Requires explicit type cast with `@as(i64, @intCast(...))`

**Files Modified:**
- `src/main.zig`
- `src/alpaca_trading_api.zig`
- `src/order_book.zig`
- `src/risk_manager.zig`
- `src/hft_alpaca_real.zig`
- `src/live_trading.zig`
- `src/fix_protocol.zig`
- `src/network.zig`
- `src/order_sender.zig`
- `src/order_book_v2.zig`

---

#### milliTimestamp() Function Removed

**Old API:**
```zig
const now_ms = std.time.milliTimestamp();
```

**New API:**
```zig
const now_ms = blk: {
    const ts = std.posix.clock_gettime(std.posix.CLOCK.REALTIME) catch unreachable;
    break :blk @as(i64, @intCast(ts.sec)) * 1000 + @divTrunc(ts.nsec, 1_000_000);
};
```

**Explanation:**
- Manual conversion required: seconds * 1000 + (nanoseconds / 1,000,000)
- Uses labeled block for clean expression

**Files Modified:**
- `src/hft_system.zig`
- `src/order_sender.zig`

---

#### nanoTimestamp() Function Removed

**Old API:**
```zig
const now_ns = std.time.nanoTimestamp();
```

**New API:**
```zig
const ts = std.posix.clock_gettime(std.posix.CLOCK.REALTIME) catch unreachable;
const now_ns = @as(i128, ts.sec) * 1_000_000_000 + ts.nsec;
```

**Explanation:**
- Manual conversion: seconds * 1,000,000,000 + nanoseconds
- Use `i128` for overflow protection on large nanosecond values

**Files Modified:**
- `src/hft_system.zig`
- `src/network.zig`

---

### 3. ArrayList API Changes

#### Initialization Changes

**Old API:**
```zig
.pnl_history = std.ArrayList(Decimal){
    .items = &.{},
    .capacity = 0,
    .allocator = allocator,
},
```

**New API:**
```zig
.pnl_history = .{},
```

**Explanation:**
- Empty struct literal `{}` now used for ArrayList initialization
- Allocator no longer part of struct initialization
- Much cleaner syntax

**Files Modified:**
- `src/risk_manager.zig`
- `src/order_book.zig`

---

#### Method Signatures Changed

**Old API:**
```zig
self.pnl_history.deinit();
try self.pnl_history.append(value);
```

**New API:**
```zig
self.pnl_history.deinit(self.allocator);
try self.pnl_history.append(self.allocator, value);
```

**Explanation:**
- `deinit()` now requires allocator parameter
- `append()` now requires allocator as first parameter
- Better explicit memory management

**Files Modified:**
- `src/risk_manager.zig`
- `src/order_book.zig`

---

### 4. File Reader API Changes

#### Io Interface Requirement

**Old API:**
```zig
var file_reader = file.reader();
```

**New API:**
```zig
var threaded: std.Io.Threaded = .init_single_threaded;
const io = threaded.ioBasic();
var buffer: [8192]u8 = undefined;
var file_reader = file.reader(io, &buffer);
```

**Explanation:**
- File operations now require `Io` interface for async compatibility
- Must create `std.Io.Threaded` instance
- Requires buffer for IO operations
- Use `.init_single_threaded` for synchronous code

**Files Modified:**
- `src/strategy_config.zig`

---

### 5. HTTP Client API Changes

#### Io Field Required

**Old API:**
```zig
http.Client{ .allocator = allocator }
```

**New API:**
```zig
pub const HttpClient = struct {
    allocator: std.mem.Allocator,
    client: http.Client,
    threaded: std.Io.Threaded,

    pub fn init(allocator: std.mem.Allocator) HttpClient {
        var threaded: std.Io.Threaded = .init_single_threaded;
        return .{
            .allocator = allocator,
            .client = http.Client{ .allocator = allocator, .io = threaded.io() },
            .threaded = threaded,
        };
    }
}
```

**Explanation:**
- HTTP client now requires `.io` field
- Must store `Io.Threaded` instance in struct
- Use `threaded.io()` to get interface

**Files Modified:**
- `src/http_client.zig`

---

### 6. Type Annotation Requirements

#### @intCast Must Have Known Result Type

**Old API:**
```zig
.timestamp = @intCast(some_value),
```

**New API:**
```zig
.timestamp = @as(i64, @intCast(some_value)),
```

**Explanation:**
- `@intCast` now requires explicit result type
- Use `@as(type, @intCast(...))` pattern
- More type-safe, prevents ambiguous casts

**Common Pattern:**
```zig
// Timestamp conversion with type annotation
const time_sec = @as(i64, @intCast((std.posix.clock_gettime(std.posix.CLOCK.REALTIME) catch unreachable).sec));
```

**Files Modified:**
- `src/hft_system.zig`
- `src/fix_protocol.zig`
- `src/order_sender.zig`
- `src/hft_alpaca_real.zig`

---

### 7. Anonymous Type Handling

#### Accessing Anonymous Struct/Enum Fields

**Problem:**
```zig
const Position = struct {
    side: enum { long, short },  // Anonymous enum
};

// Error: can't reference .side directly
fn foo(side: Position.side) void { }
```

**Solution:**
```zig
fn foo(side: @TypeOf(@as(Position, undefined).side)) void { }
```

**Explanation:**
- Anonymous types can't be referenced directly as field types
- Use `@TypeOf(@as(StructType, undefined).field_name)` pattern
- Creates undefined instance to extract type

**Files Modified:**
- `src/main.zig`
- `src/risk_manager.zig`

---

## Workarounds for Known Issues

### DWARF Relocation Bug with System Libraries

**Issue:**
When building in Debug mode with certain system libraries (libwebsockets, libsystemd), Zig's DWARF debug info generator crashes with:
```
thread panic: missing dwarf relocation target
```

**Workaround:**
Force release optimization for affected executables:

```zig
// Force ReleaseFast due to Zig 0.16 dev DWARF bug
const real_hft_optimize = if (optimize == .Debug) .ReleaseFast else optimize;
const real_hft_exe = b.addExecutable(.{
    .name = "real-hft-system",
    .root_module = b.createModule(.{
        .root_source_file = b.path("src/hft_alpaca_real.zig"),
        .target = target,
        .optimize = real_hft_optimize,  // Use workaround
    }),
});

real_hft_exe.linkSystemLibrary("websockets");
real_hft_exe.linkLibC();
```

**Affected Libraries:**
- libwebsockets
- libsystemd
- Possibly other complex C libraries with deep debug info

**Files Modified:**
- `build.zig` (real-hft-system executable)

---

## Complete File Change Summary

### build.zig
- Changed all `addExecutable` calls from `.root` to `.root_module` pattern (7 executables)
- Added ZMQ linking for hft-system and live-trading
- Added DWARF workaround for real-hft-system
- Commented out missing test files

### src/main.zig
- Fixed 3 timestamp() calls → clock_gettime
- Fixed getDepth return type with @TypeOf
- Fixed anonymous enum type reference for Position.side

### src/risk_manager.zig
- Changed ArrayList initialization to empty struct
- Added allocator parameter to deinit
- Fixed 3 timestamp() calls

### src/order_book.zig
- Added allocator field to PriceLevel struct
- Changed ArrayList initialization
- Updated deinit() calls
- Fixed 2 timestamp() calls

### src/order_book_v2.zig
- Fixed 2 timestamp() calls (lines 179, 365)

### src/strategy_config.zig
- Fixed file.reader() with Io interface
- Added threaded Io and buffer

### src/http_client.zig
- Added threaded field
- Added io parameter to http.Client
- Stored Io.Threaded in struct

### src/live_trading.zig
- Added missing strategy_config field to SystemConfig
- Fixed 1 timestamp() call

### src/hft_system.zig
- Fixed 5 milliTimestamp() calls with manual conversion
- Fixed nanoTimestamp() with detailed calculation
- Fixed 5 timestamp() calls
- Added @as type annotations to 2 @intCast locations

### src/hft_alpaca_real.zig
- Added risk management fields to SystemConfig
- Fixed 3 timestamp() calls in run() method
- Added @as type annotations to @intCast

### src/fix_protocol.zig
- Fixed 5 timestamp() calls
- Added @as type annotations to 2 @intCast locations

### src/network.zig
- Fixed 2 timestamp() calls
- Fixed nanoTimestamp() with manual timespec conversion

### src/alpaca_trading_api.zig
- Fixed 1 timestamp() call in order ID generation

### src/order_sender.zig
- Fixed 1 timestamp() call
- Fixed 1 @intCast with type annotation

---

## Build Results

**Successfully Building (9/11 targets):**
1. ✅ zig-financial-engine (9.8MB)
2. ✅ trading-api-test (26MB)
3. ✅ hft-system (12MB)
4. ✅ live-trading (11MB)
5. ✅ real-hft-system (102KB) - with DWARF workaround
6. ✅ alpaca-connect-test
7. ✅ fix-engine-test
8. ✅ network-test
9. ✅ order-book-test

**Commented Out (missing source files):**
- alpaca-test (src/alpaca_test.zig missing)
- real-connection-test (src/real_connection_test.zig missing)

---

## Migration Checklist

When migrating your Zig project to 0.16.0-dev.1303, check these items:

- [ ] Update all `addExecutable()` calls to use `.root_module` with `createModule()`
- [ ] Replace all `std.time.timestamp()` with `clock_gettime()` + type cast
- [ ] Replace all `std.time.milliTimestamp()` with manual calculation
- [ ] Replace all `std.time.nanoTimestamp()` with manual calculation
- [ ] Update ArrayList initialization to use empty struct `{}`
- [ ] Add allocator parameter to ArrayList.deinit()
- [ ] Add allocator parameter to ArrayList.append()
- [ ] Update file.reader() to use Io interface
- [ ] Update http.Client to include `.io` field
- [ ] Add `@as` type annotations to all `@intCast` calls
- [ ] Fix anonymous type references with `@TypeOf(@as(...))`
- [ ] Add DWARF workaround for system libraries if needed

---

## Testing Migration

After applying changes, verify with:

```bash
# Clean build
rm -rf zig-cache zig-out
zig build

# Test individual executables
./zig-out/bin/zig-financial-engine
./zig-out/bin/hft-system
./zig-out/bin/trading-api-test

# Verify library linkage
ldd zig-out/bin/real-hft-system
```

---

## References

- Zig Version: 0.16.0-dev.1303+ee0a0f119
- Migration Date: 2025-11-23
- Working Examples: `/home/founder/zig_forge/zig-port-scanner`, `/home/founder/zig_forge/zig-0.16-cards`
- Official Docs: https://ziglang.org/documentation/master/ (Note: May be outdated for dev builds)

---

## Key Lessons

1. **Documentation is outdated** for dev builds - always check working code examples
2. **Read Zig source code** when APIs change - it's the source of truth
3. **Type annotations matter** - new compiler is stricter about type inference
4. **Time API migration** - Most invasive change, affects nearly every file
5. **Debug mode bugs** - Dev builds may have issues, be ready to use release mode
6. **Test incrementally** - Fix one subsystem at a time, verify build

---

## Contact

For questions about this migration:
- Project: zig-financial-engine
- Location: /home/founder/zig_forge/zig-financial-engine
- Zig Version: Run `zig version` to verify you're on 0.16.0-dev.1303+ee0a0f119
