# Migration Card: macOS System Detection

## 1) Concept

This file provides macOS-specific system detection capabilities for Zig's target detection system. It contains two main public functions: `detect()` for detecting the macOS version by parsing system plist files, and `detectNativeCpuAndFeatures()` for identifying the native Apple Silicon CPU architecture and features.

The key components include a custom XML/plist parser (`SystemVersionTokenizer`) that handles the minimal parsing needed to extract version information from macOS system files, and CPU family mapping logic that translates Apple's internal CPU identifiers to Zig's target CPU models.

## 2) The 0.11 vs 0.16 Diff

**No significant public API signature changes detected.** This file maintains stable interfaces:

- **No explicit allocator requirements**: Both public functions operate without heap allocation, using stack buffers for file reading
- **No I/O interface changes**: Uses direct `std.fs.cwd().readFile()` without dependency injection
- **Stable error handling**: Returns specific error types (`error.OSVersionDetectionFail`) rather than generic errors
- **Consistent API structure**: Functions follow detection/query patterns rather than init/open lifecycle

The main migration considerations are internal:
- Uses `std.Target` instead of deprecated target APIs
- Relies on `std.SemanticVersion` for version parsing
- Uses `std.posix.sysctlbynameZ()` for CPU detection

## 3) The Golden Snippet

```zig
const std = @import("std");
const Target = std.Target;

pub fn main() !void {
    var target_os = Target.Os{
        .tag = .macos,
        .version_range = .{ .semver = .{
            .min = .{ .major = 0, .minor = 0, .patch = 0 },
            .max = .{ .major = 0, .minor = 0, .patch = 0 },
        }},
    };
    
    try std.zig.system.darwin.macos.detect(&target_os);
    
    // target_os now contains detected macOS version
    const min_ver = target_os.version_range.semver.min;
    std.debug.print("Detected macOS {}.{}.{}\n", .{
        min_ver.major, min_ver.minor, min_ver.patch
    });
}
```

## 4) Dependencies

- `std.mem` - For string comparison operations
- `std.debug` - For assertion functions
- `std.fs` - For file system operations (reading plist files)
- `std.Target` - For target OS and CPU definitions
- `std.posix` - For system call interface (`sysctlbynameZ`)
- `std.testing` - For test framework (test cases only)
- `builtin` - For compile-time target information

**Note**: This is an internal system detection module. Most applications should interact with Zig's target detection through higher-level APIs rather than calling these functions directly.