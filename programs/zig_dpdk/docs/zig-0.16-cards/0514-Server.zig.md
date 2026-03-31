# Migration Card: std.zig.Server

## 1) Concept

This file implements a protocol server for Zig's build system communication. It handles message passing between the Zig compiler and build runners, supporting various message types including error bundles, test metadata, test results, coverage data, and file system inputs. The server communicates over I/O streams (reader/writer) and manages serialization/deserialization of structured binary messages with proper endianness handling.

Key components include message type definitions (Header, Tag, and various payload structs), server initialization, message sending methods for different payload types, and message receiving methods for basic data types.

## 2) The 0.11 vs 0.16 Diff

**Explicit Allocator Requirements:**
- `allocErrorBundle` now requires an explicit `std.mem.Allocator` parameter
- No factory functions - uses direct struct initialization pattern

**I/O Interface Changes:**
- Uses dependency injection with `std.Io.Reader` and `std.Io.Writer` interfaces
- Server initialized with `Options` struct containing I/O streams
- All methods operate on the injected I/O interfaces rather than file descriptors

**Error Handling Changes:**
- Uses Zig's standard error sets with `!` return type syntax
- No generic error types - specific error handling per operation

**API Structure Changes:**
- Simple `init` function with `Options` struct pattern
- Method naming follows `serveX` and `receiveX` patterns
- No `open`/`close` lifecycle - server is stateless after initialization

## 3) The Golden Snippet

```zig
const std = @import("std");
const Server = std.zig.Server;

// Initialize server with I/O streams
var server = try Server.init(.{
    .in = &input_reader,
    .out = &output_writer,
    .zig_version = "0.16.0",
});

// Send a test result message
try server.serveTestResults(.{
    .index = 42,
    .flags = .{
        .status = .pass,
        .fuzz = false,
        .log_err_count = 0,
        .leak_count = 0,
    },
});

// Receive a message header
const header = try server.receiveMessage();
```

## 4) Dependencies

- `std.mem` (Allocator type)
- `std.io` (Reader/Writer interfaces)
- `std.zig` (ErrorBundle, Client.Message)
- `std.Build.Cache` (Cache utilities and digest handling)
- `std.debug` (assert function)

This file represents a stable protocol interface with minimal breaking changes - primarily the allocator parameter addition in `allocErrorBundle` and the standardized I/O interface patterns.