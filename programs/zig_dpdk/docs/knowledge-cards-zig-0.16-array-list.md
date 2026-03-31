# Zig 0.16 Knowledge Cards

## Card 1: ArrayList - Unmanaged API

```yaml
---
tags: [ArrayList, allocator, memory_management, unmanaged]
patterns: [explicit_allocator, manual_memory]
category: data_structures
---
```

### 1) Concept
Zig 0.16 changed ArrayList from a "managed" container (storing allocator internally) to an "unmanaged" container (allocator passed to each operation). This eliminates hidden state, makes memory operations explicit, and allows more flexible allocator usage patterns. All operations (append, deinit, etc.) now require the allocator as the first parameter after self.

### 2) The Metal Check
- **No hidden state** - ArrayList no longer stores allocator, reducing struct size
- **Explicit memory** - Every allocation/deallocation operation shows allocator usage
- **Lifetime clarity** - Allocator lifetime decoupled from container lifetime
- **API consistency** - All mutation operations follow `method(allocator, value)` pattern

### 3) The Speed Snippet

**❌ OLD (Zig 0.13/0.14) - Managed ArrayList:**
```zig
// BAD: Old API - won't compile in Zig 0.16
var ports = std.ArrayList(u16).init(allocator);  // ❌ No .init() method
defer ports.deinit();  // ❌ Missing allocator parameter

try ports.append(80);  // ❌ Missing allocator parameter
const allocator = ports.allocator;  // ❌ No .allocator field

fn parsePortSpec(spec: []const u8, ports: *std.ArrayList(u16)) !void {
    const allocator = ports.allocator;  // ❌ Can't access allocator
    try ports.append(port);  // ❌ Wrong signature
}
```

**✅ NEW (Zig 0.16) - Unmanaged ArrayList:**
```zig
// GOOD: Zig 0.16 unmanaged API
var gpa = std.heap.GeneralPurposeAllocator(.{}){};
defer _ = gpa.deinit();
const allocator = gpa.allocator();

// Initialize with .empty sentinel
var ports: std.ArrayList(u16) = .empty;
defer ports.deinit(allocator);  // ✅ Pass allocator to deinit

// All operations require allocator parameter
try ports.append(allocator, 80);
try ports.append(allocator, 443);

// Function signatures must accept allocator
fn parsePortSpec(
    spec: []const u8,
    ports: *std.ArrayList(u16),
    allocator: std.mem.Allocator  // ✅ Explicit allocator parameter
) !void {
    const port = try std.fmt.parseInt(u16, spec, 10);
    try ports.append(allocator, port);  // ✅ Pass allocator
}

// Call site
try parsePortSpec("8080", &ports, allocator);
```

**Complete Working Example:**
```zig
const std = @import("std");

pub fn main() !void {
    // Setup allocator
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create unmanaged ArrayList
    var numbers: std.ArrayList(i32) = .empty;
    defer numbers.deinit(allocator);

    // Append elements
    try numbers.append(allocator, 1);
    try numbers.append(allocator, 2);
    try numbers.append(allocator, 3);

    // Access items (no change)
    for (numbers.items) |num| {
        std.debug.print("{}\n", .{num});
    }

    // Nested function usage
    try addRange(&numbers, allocator, 10, 15);

    std.debug.print("Total items: {}\n", .{numbers.items.len});
}

fn addRange(
    list: *std.ArrayList(i32),
    allocator: std.mem.Allocator,  // ✅ Must accept allocator
    start: i32,
    end: i32
) !void {
    var i = start;
    while (i < end) : (i += 1) {
        try list.append(allocator, i);  // ✅ Pass allocator
    }
}
```

### 4) Migration Checklist

**Breaking Changes:**
- ❌ `ArrayList.init(allocator)` → ✅ `ArrayList = .empty`
- ❌ `list.allocator` field → ✅ Pass allocator explicitly
- ❌ `list.append(item)` → ✅ `list.append(allocator, item)`
- ❌ `list.deinit()` → ✅ `list.deinit(allocator)`
- ❌ `list.appendSlice(slice)` → ✅ `list.appendSlice(allocator, slice)`
- ❌ `list.insert(idx, item)` → ✅ `list.insert(allocator, idx, item)`

**Common Errors:**
```zig
// Error: no field named 'allocator'
ports.allocator = allocator;  // ❌ Remove this line

// Error: struct has no member named 'init'
var ports = std.ArrayList(u16).init(allocator);  // ❌ Use .empty

// Error: expected 2 arguments, found 1
try ports.append(port);  // ❌ Missing allocator
try ports.append(allocator, port);  // ✅ Correct
```

### 5) Dependencies
- `std.mem.Allocator` - For allocator type
- `std.ArrayList` - The unmanaged container
- `std.heap.GeneralPurposeAllocator` - Common allocator implementation

---

## Card 2: std.time.Timer API

```yaml
---
tags: [Timer, timing, benchmarking, monotonic]
patterns: [performance_measurement, nanosecond_precision]
category: time_measurement
---
```

### 1) Concept
Zig 0.16 removed `std.time.milliTimestamp()` in favor of the more precise and monotonic `std.time.Timer` API. Timer provides nanosecond-precision monotonic timing using the fastest available system clock, with explicit start/read/lap operations. Results are in nanoseconds and must be manually converted to other units using `std.time.ns_per_ms` constants.

### 2) The Metal Check
- **Monotonic** - Guaranteed non-decreasing time values (won't go backwards)
- **Nanosecond precision** - Returns u64 nanoseconds for high-resolution timing
- **Platform optimized** - Uses fastest available clock (RDTSC on x86, CLOCK_BOOTTIME on Linux)
- **No system calls** - After initialization, reading is fast (no syscall overhead)

### 3) The Speed Snippet

**❌ OLD (Removed in Zig 0.16):**
```zig
// BAD: Doesn't exist in Zig 0.16
const start = std.time.milliTimestamp();  // ❌ No such function
doWork();
const elapsed = std.time.milliTimestamp() - start;  // ❌ milliTimestamp removed
try testing.expect(elapsed < 1000);
```

**✅ NEW (Zig 0.16) - Timer API:**
```zig
// GOOD: Use Timer for precise monotonic timing
var timer = try std.time.Timer.start();
doWork();
const elapsed_ns = timer.read();

// Convert to milliseconds
const elapsed_ms = elapsed_ns / std.time.ns_per_ms;
try testing.expect(elapsed_ms < 1000);

// Or use lap() to read and reset
const lap1_ns = timer.lap();
doMoreWork();
const lap2_ns = timer.lap();
```

**Complete Working Examples:**

**Basic Timing:**
```zig
const std = @import("std");

pub fn main() !void {
    // Start timer
    var timer = try std.time.Timer.start();

    // Do some work
    var sum: u64 = 0;
    var i: u64 = 0;
    while (i < 1_000_000) : (i += 1) {
        sum += i;
    }

    // Read elapsed time in nanoseconds
    const elapsed_ns = timer.read();

    // Convert to milliseconds
    const elapsed_ms = elapsed_ns / std.time.ns_per_ms;
    const elapsed_us = elapsed_ns / std.time.ns_per_us;

    std.debug.print("Elapsed: {} ns ({} us, {} ms)\n", .{
        elapsed_ns, elapsed_us, elapsed_ms
    });
    std.debug.print("Sum: {}\n", .{sum});
}
```

**Lap Timing (Multiple Measurements):**
```zig
const std = @import("std");

fn benchmarkOperation(name: []const u8, iterations: usize) !void {
    var timer = try std.time.Timer.start();

    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        // Simulate work
        var j: usize = 0;
        var sum: u64 = 0;
        while (j < 1000) : (j += 1) {
            sum += j;
        }
    }

    const elapsed_ns = timer.read();
    const avg_ns = elapsed_ns / iterations;

    std.debug.print("{s}: {} iterations in {} ms (avg: {} ns/op)\n", .{
        name,
        iterations,
        elapsed_ns / std.time.ns_per_ms,
        avg_ns,
    });
}

pub fn main() !void {
    try benchmarkOperation("Test 1", 1000);
    try benchmarkOperation("Test 2", 10000);
}
```

**Test Suite Pattern:**
```zig
const std = @import("std");
const testing = std.testing;

test "performance: operation completes quickly" {
    var timer = try std.time.Timer.start();

    // Operation to benchmark
    var result: u64 = 0;
    var i: u64 = 0;
    while (i < 1000) : (i += 1) {
        result += i * i;
    }

    const elapsed_ms = timer.read() / std.time.ns_per_ms;

    // Assert performance requirement
    try testing.expect(elapsed_ms < 100); // Should complete in <100ms
    try testing.expect(result > 0); // Verify work was done
}

test "timeout behavior" {
    const timeout_ms = 1000;

    var timer = try std.time.Timer.start();

    // Simulate operation with timeout
    std.time.sleep(500 * std.time.ns_per_ms);

    const elapsed_ms = timer.read() / std.time.ns_per_ms;

    // Verify timeout honored
    try testing.expect(elapsed_ms >= 500);
    try testing.expect(elapsed_ms < timeout_ms + 100); // Allow 100ms slack
}
```

**Time Units Conversion:**
```zig
const std = @import("std");

pub fn printTiming(elapsed_ns: u64) void {
    // Available conversion constants
    const ms = elapsed_ns / std.time.ns_per_ms;      // milliseconds
    const us = elapsed_ns / std.time.ns_per_us;      // microseconds
    const s = elapsed_ns / std.time.ns_per_s;        // seconds

    std.debug.print("Time: {} ns = {} μs = {} ms = {} s\n", .{
        elapsed_ns, us, ms, s
    });
}

// Constants available in std.time:
// - ns_per_us = 1000
// - ns_per_ms = 1000 * ns_per_us = 1_000_000
// - ns_per_s  = 1000 * ns_per_ms = 1_000_000_000
// - ns_per_min = 60 * ns_per_s
// - ns_per_hour = 60 * ns_per_min
```

### 4) Migration Guide

**Old → New:**
```zig
// Before (Zig 0.13/0.14)
const start = std.time.milliTimestamp();
doWork();
const elapsed = std.time.milliTimestamp() - start;

// After (Zig 0.16)
var timer = try std.time.Timer.start();
doWork();
const elapsed_ms = timer.read() / std.time.ns_per_ms;
```

**Common Patterns:**

| Use Case | Code |
|----------|------|
| Simple timing | `var timer = try Timer.start(); ... timer.read()` |
| Milliseconds | `timer.read() / std.time.ns_per_ms` |
| Lap timing | `const lap1 = timer.lap(); ... lap2 = timer.lap()` |
| Reset timer | `timer.reset()` |
| Check timeout | `if (timer.read() > timeout_ns) return error.Timeout;` |

### 5) Dependencies
- `std.time.Timer` - Main timing API
- `std.time.Instant` - Underlying timestamp type
- `std.time.ns_per_ms`, `ns_per_us`, `ns_per_s` - Conversion constants
- Platform-specific: `posix.clock_gettime()`, `windows.QueryPerformanceCounter()`

---

## Card 3: Zig Test Organization

```yaml
---
tags: [testing, test_suite, unit_tests, integration_tests]
patterns: [test_pyramid, ci_cd, test_levels]
category: testing_strategy
---
```

### 1) Concept
Zig test suites should follow a multi-level testing strategy: Unit tests (pure logic, no I/O), Integration tests (network/filesystem), Functional tests (E2E binary execution), and Performance tests (timing assertions). Tests are organized in separate files with explicit `pub` visibility for tested functions, and build.zig configures multiple test steps for different test levels.

### 2) The Metal Check
- **Fast unit tests** - Pure logic tests run in <1s with no I/O
- **Isolated integration tests** - Network tests in separate build step
- **Public test surface** - Only necessary symbols marked `pub` for testing
- **Explicit error types** - Test against actual error types, not generic errors

### 3) The Speed Snippet

**Project Structure:**
```
zig-port-scanner/
├── src/
│   ├── main.zig          # Main implementation
│   └── test.zig          # Comprehensive test suite
├── build.zig             # Build configuration
├── test.sh               # Bash test runner
└── .github/workflows/
    └── ci.yml            # CI/CD configuration
```

**build.zig - Test Configuration:**
```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Main executable
    const exe = b.addExecutable(.{
        .name = "zig-port-scanner",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe.linkLibC();
    b.installArtifact(exe);

    // Test suite
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/test.zig"),
        .target = target,
        .optimize = optimize,
    });

    const tests = b.addTest(.{
        .root_module = test_mod,
    });
    tests.linkLibC();

    // Unit tests (fast, no network)
    const test_step = b.step("test", "Run unit tests");
    const test_run = b.addRunArtifact(tests);
    test_step.dependOn(&test_run.step);

    // Integration tests (requires network)
    const test_integration = b.step("test-integration", "Run integration tests");
    test_integration.dependOn(&test_run.step);
}
```

**src/main.zig - Public Test Interface:**
```zig
const std = @import("std");

// ✅ GOOD: Mark types public for testing
pub const ScannerError = error{
    NoHost,
    InvalidPortRange,
    ResolutionFailed,
    ScanFailed,
};

pub const PortStatus = enum {
    open,
    closed,
    filtered,
    unknown,
};

// ✅ GOOD: Mark test-relevant functions public
pub fn parsePortSpec(
    spec: []const u8,
    ports: *std.ArrayList(u16),
    allocator: std.mem.Allocator
) !void {
    // Implementation
}

pub fn scanPort(io: Io, addr: IpAddress, timeout_ms: u32) !PortStatus {
    // Implementation
}

pub fn getServiceName(port: u16) []const u8 {
    return switch (port) {
        22 => "ssh",
        80 => "http",
        443 => "https",
        else => "unknown",
    };
}

// ❌ BAD: Don't expose internal helpers
fn validatePortRange(start: u16, end: u16) bool {
    return start <= end and start > 0;
}
```

**src/test.zig - Test Organization:**
```zig
const std = @import("std");
const testing = std.testing;
const main = @import("main.zig");
const Io = @import("io").Io;
const IpAddress = @import("io").IpAddress;

// ============================================================================
// UNIT TESTS - No dependencies, pure logic
// ============================================================================

test "parse single port" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var ports: std.ArrayList(u16) = .empty;
    defer ports.deinit(allocator);

    try main.parsePortSpec("80", &ports, allocator);
    try testing.expectEqual(@as(usize, 1), ports.items.len);
    try testing.expectEqual(@as(u16, 80), ports.items[0]);
}

test "parse port range" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var ports: std.ArrayList(u16) = .empty;
    defer ports.deinit(allocator);

    try main.parsePortSpec("80-82", &ports, allocator);
    try testing.expectEqual(@as(usize, 3), ports.items.len);
    try testing.expectEqual(@as(u16, 80), ports.items[0]);
    try testing.expectEqual(@as(u16, 82), ports.items[2]);
}

test "parse invalid port spec" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var ports: std.ArrayList(u16) = .empty;
    defer ports.deinit(allocator);

    const result = main.parsePortSpec("abc", &ports, allocator);
    try testing.expectError(main.ScannerError.InvalidPortRange, result);
}

test "service name detection" {
    try testing.expectEqualStrings("ssh", main.getServiceName(22));
    try testing.expectEqualStrings("http", main.getServiceName(80));
    try testing.expectEqualStrings("https", main.getServiceName(443));
    try testing.expectEqualStrings("unknown", main.getServiceName(9999));
}

// ============================================================================
// INTEGRATION TESTS - Network required
// ============================================================================

test "integration: scan localhost" {
    var threaded = Io.Threaded.init_single_threaded;
    const io = threaded.io();

    const addr = try IpAddress.parse("127.0.0.1", 54321);
    const status = try main.scanPort(io, addr, 1000);

    try testing.expect(status != .open);  // Port should be closed
}

test "integration: DNS resolution" {
    var threaded = Io.Threaded.init_single_threaded;
    const io = threaded.io();

    const addr = try main.resolveHost(io, "localhost");
    try testing.expect(addr.ip4.ip == 127 << 24 | 1);  // 127.0.0.1
}

// ============================================================================
// PERFORMANCE TESTS
// ============================================================================

test "performance: parse 1000 ports" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var ports: std.ArrayList(u16) = .empty;
    defer ports.deinit(allocator);

    var timer = try std.time.Timer.start();
    try main.parsePortSpec("1-1000", &ports, allocator);
    const elapsed_ms = timer.read() / std.time.ns_per_ms;

    try testing.expectEqual(@as(usize, 1000), ports.items.len);
    try testing.expect(elapsed_ms < 100);  // Should be very fast
}
```

**test.sh - Bash Test Runner:**
```bash
#!/bin/bash
set -e

echo "Phase 1: Build Tests"
zig build

echo "Phase 2: Unit Tests"
zig build test

echo "Phase 3: Integration Tests (requires network)"
if ping -c 1 google.com >/dev/null 2>&1; then
    zig build test-integration
else
    echo "Skipping integration tests (no network)"
fi

echo "Phase 4: Functional Tests"
./zig-out/bin/zig-port-scanner --help
./zig-out/bin/zig-port-scanner -p=80 localhost

echo "✅ All tests passed!"
```

### 4) Testing Patterns

**Error Testing:**
```zig
// ✅ GOOD: Test against specific error type
const result = main.parsePortSpec("invalid", &ports, allocator);
try testing.expectError(main.ScannerError.InvalidPortRange, result);

// ❌ BAD: Don't test against generic error
try testing.expectError(error.InvalidCharacter, result);  // Wrong error type
```

**Allocator Testing Pattern:**
```zig
test "example test" {
    // Standard allocator setup
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Use testing.allocator for leak detection (alternative)
    // const allocator = testing.allocator;

    var list: std.ArrayList(u16) = .empty;
    defer list.deinit(allocator);

    // Test code
}
```

**Performance Test Pattern:**
```zig
test "performance: operation within timeout" {
    var timer = try std.time.Timer.start();

    // Operation to benchmark
    performExpensiveOperation();

    const elapsed_ms = timer.read() / std.time.ns_per_ms;
    try testing.expect(elapsed_ms < 1000);  // Must complete in <1s
}
```

### 5) Dependencies
- `std.testing` - Test framework
- `std.ArrayList` - For test data structures
- `std.time.Timer` - Performance testing
- `std.heap.GeneralPurposeAllocator` - Memory management in tests

---

## Card 4: Public Test Surface

```yaml
---
tags: [visibility, pub, testing, api_design]
patterns: [information_hiding, test_interface]
category: module_design
---
```

### 1) Concept
In Zig, only symbols marked `pub` are accessible from other modules, including test files. To enable comprehensive testing without exposing implementation details to users, selectively mark types, functions, and error sets as `pub` based on testing needs. Use separate test files (`test.zig`) that import the main module to verify public behavior.

### 2) The Metal Check
- **Minimal public surface** - Only expose what tests require
- **No pub for users** - Mark `pub` for testing, not for API consumers
- **Error types public** - Test files need access to error sets
- **Enum types public** - Test assertions require type access

### 3) The Speed Snippet

**❌ BAD: Everything private, tests fail:**
```zig
// src/main.zig
const std = @import("std");

// ❌ BAD: Error set not public
const ScannerError = error{
    InvalidPortRange,
};

// ❌ BAD: Enum not public
const PortStatus = enum {
    open,
    closed,
};

// ❌ BAD: Function not public
fn parsePortSpec(spec: []const u8, ports: *std.ArrayList(u16)) !void {
    // ...
}

// src/test.zig
const main = @import("main.zig");

test "parse port" {
    // ❌ ERROR: 'parsePortSpec' is not marked 'pub'
    try main.parsePortSpec("80", &ports);

    // ❌ ERROR: 'ScannerError' is not marked 'pub'
    const result = main.parsePortSpec("invalid", &ports);
    try testing.expectError(main.ScannerError.InvalidPortRange, result);
}
```

**✅ GOOD: Strategic public marking:**
```zig
// src/main.zig
const std = @import("std");

// ✅ GOOD: Error set public for test assertions
pub const ScannerError = error{
    InvalidPortRange,
    ResolutionFailed,
    ScanFailed,
};

// ✅ GOOD: Enum public for test assertions
pub const PortStatus = enum {
    open,
    closed,
    filtered,
    unknown,

    // Public method for string conversion
    pub fn toString(self: PortStatus) []const u8 {
        return switch (self) {
            .open => "open",
            .closed => "closed",
            .filtered => "filtered",
            .unknown => "unknown",
        };
    }
};

// ✅ GOOD: Core functions public for testing
pub fn parsePortSpec(
    spec: []const u8,
    ports: *std.ArrayList(u16),
    allocator: std.mem.Allocator
) !void {
    // Implementation
}

pub fn scanPort(io: Io, addr: IpAddress, timeout_ms: u32) !PortStatus {
    // Implementation
}

pub fn getServiceName(port: u16) []const u8 {
    return switch (port) {
        22 => "ssh",
        80 => "http",
        443 => "https",
        else => "unknown",
    };
}

// ❌ GOOD: Internal helpers remain private
fn validateInput(input: []const u8) bool {
    return input.len > 0;
}

const INTERNAL_BUFFER_SIZE = 4096;  // Private constant

// src/test.zig
const std = @import("std");
const testing = std.testing;
const main = @import("main.zig");

test "parse port spec" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var ports: std.ArrayList(u16) = .empty;
    defer ports.deinit(allocator);

    // ✅ Works: Function is public
    try main.parsePortSpec("80", &ports, allocator);
    try testing.expectEqual(@as(usize, 1), ports.items.len);
}

test "parse invalid port" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var ports: std.ArrayList(u16) = .empty;
    defer ports.deinit(allocator);

    const result = main.parsePortSpec("invalid", &ports, allocator);

    // ✅ Works: Error type is public
    try testing.expectError(main.ScannerError.InvalidPortRange, result);
}

test "port status enum" {
    const status = main.PortStatus.open;

    // ✅ Works: Enum is public
    try testing.expectEqual(main.PortStatus.open, status);
    try testing.expectEqualStrings("open", status.toString());
}

test "service name detection" {
    // ✅ Works: Function is public
    try testing.expectEqualStrings("ssh", main.getServiceName(22));
    try testing.expectEqualStrings("http", main.getServiceName(80));
}
```

**Complete Working Example - Module with Test Interface:**
```zig
// src/calculator.zig
const std = @import("std");

// ✅ Public error set for test assertions
pub const CalculatorError = error{
    DivisionByZero,
    Overflow,
    InvalidOperation,
};

// ✅ Public result type for tests
pub const Result = struct {
    value: i64,
    overflow: bool,
};

// ✅ Public functions for testing
pub fn add(a: i64, b: i64) Result {
    const result = @addWithOverflow(a, b);
    return .{
        .value = result[0],
        .overflow = result[1] != 0,
    };
}

pub fn divide(a: i64, b: i64) CalculatorError!i64 {
    if (b == 0) return CalculatorError.DivisionByZero;
    return @divTrunc(a, b);
}

// ❌ Private internal helpers
fn validateRange(x: i64) bool {
    return x >= -1000000 and x <= 1000000;
}

const MAX_CACHE_SIZE = 1024;  // Private constant

// src/calculator_test.zig
const std = @import("std");
const testing = std.testing;
const calc = @import("calculator.zig");

test "addition works" {
    const result = calc.add(5, 3);
    try testing.expectEqual(@as(i64, 8), result.value);
    try testing.expectEqual(false, result.overflow);
}

test "addition overflow detection" {
    const result = calc.add(std.math.maxInt(i64), 1);
    try testing.expectEqual(true, result.overflow);
}

test "division by zero" {
    const result = calc.divide(10, 0);
    try testing.expectError(calc.CalculatorError.DivisionByZero, result);
}

test "normal division" {
    const result = try calc.divide(10, 2);
    try testing.expectEqual(@as(i64, 5), result);
}
```

### 4) Visibility Guidelines

**What to Make Public:**

| Type | Public? | Reason |
|------|---------|--------|
| Error sets | ✅ Yes | Tests need to assert specific errors |
| Enum types | ✅ Yes | Tests compare enum values |
| Result structs | ✅ Yes | Tests verify return values |
| Core functions | ✅ Yes | Primary testing targets |
| Constants (API) | ✅ Yes | Tests verify behavior against limits |

**What to Keep Private:**

| Type | Public? | Reason |
|------|---------|--------|
| Internal helpers | ❌ No | Implementation details |
| Internal constants | ❌ No | Not part of test contract |
| Validation functions | ❌ No | Tested indirectly via public API |
| Buffer sizes | ❌ No | Implementation details |

**Migration Pattern:**

```zig
// Step 1: Identify test compilation errors
// error: 'FooError' is not marked 'pub'

// Step 2: Make only the required symbol public
const FooError = error{ ... };  // ❌ Before
pub const FooError = error{ ... };  // ✅ After

// Step 3: Recompile tests
zig build test

// Step 4: Repeat until all tests compile
```

### 5) Dependencies
- `std` - Standard library (no special imports needed for `pub`)
- Test files must import the module: `const main = @import("main.zig");`
