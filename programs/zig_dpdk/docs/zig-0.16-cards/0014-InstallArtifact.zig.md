# Migration Card: std/Build/Step/InstallArtifact.zig

## 1) Concept

This file implements the `InstallArtifact` build step, which handles installation of compiled artifacts (executables, libraries, etc.) to their final destination directories. It manages the installation of various output types including the main binary, debug symbols (PDB files), import libraries (implib), header files, and dynamic library symlinks. The step coordinates with the Zig build system to copy files to appropriate installation directories like `bin`, `lib`, or `header` while handling platform-specific considerations like DLL symlinks on Unix-like systems.

Key components include the `InstallArtifact` struct containing installation configuration, the `Options` struct for customization, and the `make` function that performs the actual installation logic. The step integrates with the Zig build graph through dependency relationships with compilation steps.

## 2) The 0.11 vs 0.16 Diff

**Explicit Allocator Requirements:**
- The `create` function uses `owner.allocator` for allocation, following the pattern where allocators are obtained from build context rather than passed explicitly
- Directory walking in the `make` function uses `b.allocator` from the build context

**I/O Interface Changes:**
- Uses `LazyPath` abstraction for emitted files rather than direct path manipulation
- File installation uses `step.installFile()` and `step.installDir()` methods
- Directory iteration uses `std.fs.Dir.Walker` with build allocator

**API Structure Changes:**
- Factory pattern: `InstallArtifact.create()` returns `*InstallArtifact` rather than struct initialization
- Configuration through `Options` struct with union-based directory specification
- `InstallDir` enum used for destination directory specification instead of string paths
- Installation status tracking through `result_cached` field

## 3) The Golden Snippet

```zig
// Create an installation step for a compiled artifact
const install_step = std.Build.Step.InstallArtifact.create(
    builder, 
    compiled_artifact, 
    .{
        .dest_dir = .{ .override = .bin },
        .pdb_dir = .default,
        .h_dir = .{ .disabled = {} },
        .implib_dir = .default,
        .dylib_symlinks = true,
        .dest_sub_path = "my-custom-name",
    }
);

// Add to build dependencies
builder.getInstallStep().dependOn(&install_step.step);
```

## 4) Dependencies

- `std` (base import)
- `std.Build.Step` (step infrastructure)
- `std.Build.InstallDir` (installation directory handling)
- `std.Build.LazyPath` (path abstraction)
- `std.fs` (file system operations)
- `std.mem` (memory utilities for string operations)