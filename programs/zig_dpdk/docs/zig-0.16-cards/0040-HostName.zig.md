# Migration Card: std/Io/net/HostName.zig

## 1) Concept

This file implements a `HostName` type that represents a validated hostname according to standard DNS specifications. A valid hostname must be UTF-8 encoded, have length ≤ 255 characters, and contain only alphanumeric ASCII characters, hyphens, and dots. The module provides functionality for hostname validation, DNS lookups, DNS packet parsing, and establishing network connections to hosts.

Key components include:
- `HostName` struct wrapping validated byte slices
- DNS lookup functionality with async queue-based results
- DNS packet parsing and expansion (decompression)
- Connection establishment with multiple IP fallback
- `/etc/resolv.conf` parsing for system DNS configuration

## 2) The 0.11 vs 0.16 Diff

**Explicit I/O Interface Dependency Injection:**
- All network operations require explicit `Io` parameter injection
- `lookup(host_name: HostName, io: Io, resolved: *Io.Queue(LookupResult), options: LookupOptions) void`
- `connect(host_name: HostName, io: Io, port: u16, options: IpAddress.ConnectOptions) ConnectError!Stream`
- `connectMany(host_name: HostName, io: Io, port: u16, results: *Io.Queue(ConnectManyResult), options: IpAddress.ConnectOptions) void`

**Async Queue-Based Results:**
- DNS lookups use `Io.Queue(LookupResult)` for async result delivery
- Connection attempts use `Io.Queue(ConnectManyResult)` for multiple connection attempts
- Queue-based pattern replaces callback-based async from 0.11

**Factory Function Pattern:**
- `init(bytes: []const u8) ValidateError!HostName` - validates and creates HostName instance
- No allocator required - HostName borrows external memory

**Enhanced Error Handling:**
- Specific error sets: `ValidateError`, `LookupError`, `ConnectError`, `ExpandError`
- Error union returns instead of generic error types

## 3) The Golden Snippet

```zig
const std = @import("std");
const Io = std.Io;
const HostName = Io.net.HostName;

// Validate and create a HostName
const host = try HostName.init("example.com");

// Perform DNS lookup with dependency-injected Io
var lookup_buffer: [32]HostName.LookupResult = undefined;
var lookup_queue: Io.Queue(HostName.LookupResult) = .init(&lookup_buffer);
var canonical_name_buffer: [HostName.max_len]u8 = undefined;

host.lookup(io, &lookup_queue, .{
    .port = 80,
    .canonical_name_buffer = &canonical_name_buffer,
});

// Connect to the host
const stream = try host.connect(io, 80, .{});
defer stream.close(io);
```

## 4) Dependencies

- `std.Io` - Core I/O interface and async operations
- `std.Io.net.IpAddress` - IP address handling and connection
- `std.mem` - Memory operations and integer reading
- `std.unicode` - UTF-8 validation
- `std.ascii` - Case-insensitive string comparison and character checking
- `std.fmt` - Integer parsing for configuration files

The module has deep integration with the new Zig 0.16 I/O system and demonstrates the comprehensive dependency injection pattern required for network operations in this version.