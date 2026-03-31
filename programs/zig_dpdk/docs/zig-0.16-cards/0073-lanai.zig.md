# Migration Card: Lanai Target CPU Features

## 1) Concept

This file defines CPU features and models for the Lanai architecture target in Zig's standard library. It's an auto-generated file that provides:

- An enum of available CPU features (currently empty for Lanai)
- Utility functions for working with CPU feature sets (`featureSet`, `featureSetHas`, etc.)
- Predefined CPU models (`generic` and `v11`) with their respective feature sets

The file serves as architecture-specific configuration for Zig's cross-compilation targeting system, allowing the compiler to optimize code generation based on the specific Lanai CPU capabilities.

## 2) The 0.11 vs 0.16 Diff

**No breaking API changes detected.** This file contains only data definitions and comptime utilities that follow stable patterns:

- Uses `CpuFeature.FeatureSetFns` generic pattern consistently
- All data is computed at compile-time using `blk` blocks and struct literals
- No allocator dependencies or I/O interfaces
- No error handling requirements (all operations are comptime-safe)

The API structure remains compatible because:
- Feature sets are built using the same `featureSet(&[_]Feature{})` pattern
- CPU models are defined as struct literals with consistent field names
- All functionality operates at compile-time without runtime dependencies

## 3) The Golden Snippet

```zig
const std = @import("std");
const lanai = std.Target.lanai;

// Check if a CPU model has specific features
const features = lanai.featureSet(&[_]lanai.Feature{});
const has_features = lanai.featureSetHas(features, &.{});

// Use predefined CPU models
const cpu_model = lanai.cpu.v11;
const cpu_features = cpu_model.features;

// Verify feature set operations work
const has_any = lanai.featureSetHasAny(features, &.{});
const has_all = lanai.featureSetHasAll(features, &.{});
```

## 4) Dependencies

- `std` - Base standard library import
- `std.Target.Cpu` - CPU feature and model definitions
- `std.debug` - For compile-time assertions

**Migration Impact: LOW** - No migration required. This is a stable, auto-generated target definition file with no breaking changes between 0.11 and 0.16.