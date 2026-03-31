# Migration Card: std.Build.Cache

## 1) Concept

This file implements a build cache management system for Zig's `zig-cache` directories. It provides mechanisms to track file dependencies, compute content hashes, and determine when build artifacts can be reused versus when they need to be rebuilt. The cache is designed to be fast and simple rather than secure against malicious input.

Key components include:
- `Cache`: The main cache instance that manages the cache directory and path prefixes
- `Manifest`: Represents a cache entry that tracks dependencies and their hashes
- `HashHelper`: Incremental hashing utility for building cache keys
- `File`: Represents a cached dependency file with metadata and content hashes

## 2) The 0.11 vs 0.16 Diff

### Explicit Allocator Requirements
- **Cache initialization**: The `Cache` struct now requires explicit `gpa: Allocator` and `io: Io` fields
- **File management**: All file operations require passing the allocator through the cache structure
- **Path resolution**: `findPrefix` and related methods allocate paths using the cache's allocator

### I/O Interface Changes
- **Dependency injection**: Cache operations now use `std.Io` interface instead of direct filesystem calls
- **Timestamp handling**: Uses `Io.Timestamp` instead of platform-specific time types
- **Reader/Writer patterns**: Uses `Io.Reader` and `Io.Writer` interfaces for manifest operations

### API Structure Changes
- **Path abstraction**: New `Path` type replaces raw string paths in newer APIs
- **Deprecated methods**: `addFile()` is deprecated in favor of `addFilePath()`
- **Enhanced file handling**: `addOpenedFile()` allows passing pre-opened file handles
- **Lock management**: More sophisticated shared/exclusive locking for concurrent access

### Error Handling Changes
- **Specific error types**: `HitError` provides specific cache check failure reasons
- **Diagnostic tracking**: `Manifest.Diagnostic` captures detailed failure information
- **Error propagation**: File operation errors include file index context

## 3) The Golden Snippet

```zig
const std = @import("std");
const Cache = std.Build.Cache;

pub fn example() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    
    // Initialize cache
    var cache: Cache = .{
        .gpa = allocator,
        .io = std.io,  // Use default I/O interface
        .manifest_dir = try some_dir.makeOpenPath("zig-cache", .{}),
    };
    
    // Add path prefix for relative paths
    cache.addPrefix(.{ .path = null, .handle = some_dir });
    
    // Create manifest and add dependencies
    var manifest = cache.obtain();
    defer manifest.deinit();
    
    manifest.hash.addBytes("build_inputs");
    manifest.hash.add(1234);
    
    // Add file dependency using new Path type
    const file_path = Cache.Path{
        .root_dir = .{ .path = null, .handle = some_dir },
        .sub_path = "source_file.zig",
    };
    _ = try manifest.addFilePath(file_path, null);
    
    // Check cache hit
    if (try manifest.hit()) {
        // Cache hit - reuse existing artifact
        const digest = manifest.final();
        std.debug.print("Cache hit: {s}\n", .{digest});
    } else {
        // Cache miss - build and write manifest
        const digest = manifest.final();
        try manifest.writeManifest();
        std.debug.print("Cache miss: {s}\n", .{digest});
    }
}
```

## 4) Dependencies

- `std.mem` - Memory allocation and manipulation
- `std.fs` - Filesystem operations
- `std.fmt` - String formatting
- `std.crypto` - Cryptographic hashing (SipHash128)
- `std.Io` - I/O interface abstraction
- `std.Thread` - Mutex for thread safety
- `std.hash` - Hash utilities

The cache system is heavily dependent on the new I/O abstraction layer and requires explicit allocator management throughout its API surface.