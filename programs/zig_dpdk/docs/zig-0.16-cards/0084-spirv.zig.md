# Migration Card: std/Target/spirv.zig

## 1) Concept

This file defines SPIR-V target features and CPU models for Zig's cross-compilation infrastructure. It's an auto-generated file (created by `tools/update_cpu_features.zig`) that enumerates SPIR-V capabilities and versions as compile-time feature sets. The key components include a `Feature` enum listing SPIR-V capabilities like floating-point types, integer precision, and version support, along with predefined CPU models for different SPIR-V target environments like OpenCL and Vulkan.

The file provides feature set utility functions and dependency relationships between SPIR-V features, enabling compile-time feature validation and target configuration. It serves as part of Zig's target abstraction layer for SPIR-V code generation.

## 2) The 0.11 vs 0.16 Diff

**No public API changes detected.** This file contains only data definitions and comptime utilities:

- **Feature Enum**: Simple enum of SPIR-V capabilities and versions
- **Feature Set Functions**: Comptime utilities (`featureSet`, `featureSetHas`, etc.) that work with enum features
- **CPU Models**: Static data structures defining SPIR-V target configurations

The public interface consists of:
- Data types (`Feature` enum, `cpu` struct with models)
- Comptime helper functions generated via `CpuFeature.FeatureSetFns`
- No allocator requirements, I/O interfaces, or error handling changes
- No initialization patterns or factory functions

## 3) The Golden Snippet

```zig
const std = @import("std");
const spirv = std.Target.spirv;

// Check if a feature set contains specific SPIR-V capabilities
const features = spirv.featureSet(&.{ .float16, .int64, .v1_5 });
const has_float16 = spirv.featureSetHas(features, .float16);

// Use predefined SPIR-V CPU model
const vulkan_model = spirv.cpu.vulkan_v1_2;
```

## 4) Dependencies

- `std.Target.Cpu` (via `CpuFeature` and `CpuModel`)
- `std.debug` (for assertions in comptime blocks)
- No heavy I/O or memory management dependencies

**Note**: This is an auto-generated target definition file with stable data-oriented APIs. Migration impact is minimal as it contains no runtime functions or complex initialization patterns that would be affected by Zig 0.16 changes.