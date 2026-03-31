# Migration Card: std.crypto.Certificate.Bundle

## 1) Concept

This file implements a certificate bundle that stores Certificate Authority (CA) certificates used for SSL certificate validation. The bundle maintains certificates in DER-encoded form concatenated in a single byte array (`bytes` field), with a hash map (`map` field) providing efficient lookup from subject names to certificate indices. The implementation supports scanning operating system standard certificate locations and provides verification capabilities against the stored certificate authorities.

Key components include platform-specific rescan functions for Linux, macOS, Windows, and various BSD systems, certificate parsing and validation logic, and methods to add certificates from files and directories. The bundle is designed to efficiently store and look up certificates while maintaining their DER-encoded format.

## 2) The 0.11 vs 0.16 Diff

### Explicit Allocator Requirements
- **All functions requiring memory allocation now explicitly take `gpa: Allocator` parameter**
- `deinit(cb: *Bundle, gpa: Allocator)`
- `rescan(cb: *Bundle, gpa: Allocator, io: Io, now: Io.Timestamp)`
- `addCertsFromFilePathAbsolute(cb: *Bundle, gpa: Allocator, io: Io, now: Io.Timestamp, abs_file_path: []const u8)`
- All other `addCertsFrom*` functions follow the same pattern

### I/O Interface Changes
- **Dependency injection of I/O operations through `io: Io` parameter**
- **Timestamp handling via `Io.Timestamp` instead of direct system calls**
- Functions like `rescan`, `addCertsFromFilePathAbsolute`, etc. take `io: Io` and `now: Io.Timestamp` parameters
- File operations use `Io.File` and `Io.File.Reader` instead of direct `std.fs.File` usage

### Error Handling Changes
- **Specific, composed error sets for each operation**
- `VerifyError = Certificate.Parsed.VerifyError || error{CertificateIssuerNotFound}`
- `RescanError = RescanLinuxError || RescanMacError || RescanWithPathError || RescanWindowsError`
- `AddCertsFromFilePathError = fs.File.OpenError || AddCertsFromFileError || Io.Clock.Error`

### API Structure Changes
- **No traditional constructor/destructor pattern** - bundle initialized with default struct initialization
- **Explicit deinit required** with allocator parameter
- **Platform-agnostic scanning** via `rescan()` that delegates to OS-specific implementations

## 3) The Golden Snippet

```zig
const std = @import("std");
const Bundle = std.crypto.Certificate.Bundle;

// Initialize bundle with OS certificates
var bundle: Bundle = .{};
defer bundle.deinit(allocator);

const io = std.io;
const now = try io.Clock.real.now(io);

try bundle.rescan(allocator, io, now);

// Use the bundle for certificate verification
const subject_cert = try Certificate.parse(cert_data);
try bundle.verify(subject_cert, now.toSeconds());
```

## 4) Dependencies

- `std.mem` - Memory operations and equality comparisons
- `std.fs` - File system operations and directory iteration
- `std.hash_map` - HashMap implementation for certificate lookup
- `std.base64` - Base64 decoding for PEM certificates
- `std.crypto.Certificate` - Certificate parsing and validation
- `std.io` - I/O abstraction and timestamp handling
- `std.os.windows` - Windows-specific certificate store access (Windows only)

The module has heavy platform-specific dependencies through the imported submodules (`Bundle/macos.zig`) and conditional compilation based on `builtin.os.tag`.