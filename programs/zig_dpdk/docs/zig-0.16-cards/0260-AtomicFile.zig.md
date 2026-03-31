# Migration Card: std.fs.AtomicFile

## 1) Concept

This file implements atomic file operations for Zig's standard library. The `AtomicFile` type provides a mechanism for writing files atomically - it writes to a temporary file first, then renames it to the final destination in a single atomic operation. This prevents partial writes and ensures the destination file either contains the complete new content or retains the previous version.

Key components include:
- **AtomicFile struct**: Manages the temporary file, destination filename, and directory state
- **init/deinit pattern**: Standard Zig resource management for creating and cleaning up the atomic file
- **flush/renameIntoPlace/finish**: Methods for writing data and committing the atomic operation
- **Error handling**: Specific error types for different failure modes during the atomic file lifecycle

## 2) The 0.11 vs 0.16 Diff

**Explicit Allocator Requirements**: No allocator parameter in the API. The `init` function accepts a `write_buffer: []u8` for buffering, but this is separate from memory allocation patterns.

**I/O Interface Changes**: Uses dependency injection through the `Dir` parameter. The `init` function takes a `dir: Dir` and `close_dir_on_deinit: bool`, allowing callers to control directory lifecycle management.

**Error Handling Changes**: Uses specific, composed error types:
- `InitError = File.OpenError`
- `FlushError = File.WriteError`  
- `RenameIntoPlaceError = posix.RenameError`
- `FinishError = FlushError || RenameIntoPlaceError`

**API Structure Changes**: Consistent with Zig's init/deinit pattern:
- `init()` creates the atomic file wrapper
- `deinit()` handles cleanup even after partial operations
- `finish()` combines flush and rename operations

## 3) The Golden Snippet

```zig
const std = @import("std");

pub fn writeAtomicFile() !void {
    const cwd = std.fs.cwd();
    const dest_name = "output.txt";
    
    // Buffer for file writing
    var buffer: [4096]u8 = undefined;
    
    // Create atomic file
    var atomic_file = try std.fs.AtomicFile.init(
        dest_name,
        std.fs.File.default_mode,
        cwd,
        false,  // don't close cwd on deinit
        &buffer
    );
    defer atomic_file.deinit();
    
    // Write data
    try atomic_file.file_writer.writeAll("Hello, World!\n");
    
    // Commit atomically
    try atomic_file.finish();
}
```

## 4) Dependencies

- `std.fs` (File, Dir operations)
- `std.posix` (low-level rename operations)
- `std.crypto.random` (temporary filename generation)
- `std.fmt` (hex formatting for temporary names)
- `std.debug` (assertions)

**Note**: This API follows Zig's standard patterns and requires no major migration changes from 0.11 to 0.16. The main considerations are proper error handling and resource management through the init/deinit pattern.