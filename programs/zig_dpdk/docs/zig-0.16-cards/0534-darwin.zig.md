# Migration Card: darwin.zig

## 1) Concept

This file is part of Zig's standard library system support for Darwin platforms (macOS, iOS, tvOS, watchOS, visionOS, and DriverKit). It provides SDK detection and verification utilities for Apple development environments. The key components include functions to check if Xcode SDKs are installed and to retrieve SDK paths for specific target platforms.

The file handles cross-platform SDK management by interacting with Xcode command-line tools (`xcode-select` and `xcrun`) while avoiding unwanted CLT installation prompts. It supports detection for all major Apple platforms including iOS (with simulator and Mac Catalyst variants), macOS, tvOS, watchOS, visionOS, and DriverKit.

## 2) The 0.11 vs 0.16 Diff

**Explicit Allocator Requirements:**
Both public functions now require explicit allocator parameters:
- `isSdkInstalled(allocator: Allocator) bool`
- `getSdk(allocator: Allocator, target: *const Target) ?[]const u8`

**Process Execution Pattern:**
Uses the new `std.process.Child.run` with struct initialization syntax:
```zig
std.process.Child.run(.{
    .allocator = allocator,
    .argv = &.{ "xcode-select", "--print-path" },
})
```

**Memory Management:**
Explicit memory cleanup patterns using `defer` blocks to free allocated stdout/stderr:
```zig
defer {
    allocator.free(result.stderr);
    allocator.free(result.stdout);
}
```

**Target Handling:**
Uses the updated `std.Target` structure with nested enums for OS tags and ABIs:
```zig
target.os.tag  // e.g., .ios, .macos, .tvos
target.abi     // e.g., .simulator, .macabi
```

## 3) The Golden Snippet

```zig
const std = @import("std");
const darwin = std.zig.system.darwin;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    
    // Check if SDK is installed
    const installed = darwin.isSdkInstalled(allocator);
    std.debug.print("SDK installed: {}\n", .{installed});
    
    // Get SDK path for macOS target
    var target = std.zig.CrossTarget{ .os_tag = .macos };
    const native_target = try target.getTarget();
    
    if (darwin.getSdk(allocator, &native_target)) |sdk_path| {
        defer allocator.free(sdk_path);
        std.debug.print("macOS SDK path: {s}\n", .{sdk_path});
    }
}
```

## 4) Dependencies

- `std.mem` (as `mem`) - Memory allocation and manipulation utilities
- `std.Target` - Target platform and architecture definitions  
- `std.process.Child` - Process execution and management
- `std.SemanticVersion` - Version handling (imported but not directly used in public APIs)
- `std.zig.system.darwin.macos` - macOS-specific system utilities

**Primary Dependencies Graph:**
```
std.mem → Allocator, memory operations
std.Target → Platform targeting
std.process → Child process execution
```