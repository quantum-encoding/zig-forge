# Migration Card: SPARC Target Features

## 1) Concept

This file defines SPARC architecture-specific CPU features and models for Zig's target system support. It's an auto-generated file (created by `tools/update_cpu_features.zig`) that enumerates all available SPARC CPU features like cryptographic extensions, VIS instruction sets, LEON processor features, and various hardware workarounds. The file provides structured data about feature dependencies and pre-configured CPU models for different SPARC implementations.

Key components include:
- `Feature` enum listing all SPARC-specific CPU capabilities
- Feature set utility functions (`featureSet`, `featureSetHas`, etc.)
- Complete feature metadata including LLVM names, descriptions, and dependencies
- Predefined CPU models with their respective feature sets

## 2) The 0.11 vs 0.16 Diff

This file contains no public function signatures that would require migration changes. The public API consists entirely of:

- **Enum declarations** (`Feature` enum)
- **Compile-time constants** (`all_features` array, `cpu` struct with model constants)
- **Generic feature set utilities** (generated via `CpuFeature.FeatureSetFns`)

No migration changes are needed because:
- No allocator parameters are required (all data is compile-time generated)
- No I/O interfaces exist in this target definition file
- No error handling functions are exposed
- All API structures are simple enum values and constant definitions

## 3) The Golden Snippet

```zig
const std = @import("std");
const sparc = std.Target.sparc;

// Check if a CPU model supports specific features
const cpu_model = sparc.cpu.niagara4;
const has_crypto = sparc.featureSetHas(cpu_model.features, .crypto);
const has_vis3 = sparc.featureSetHas(cpu_model.features, .vis3);

// Create a custom feature set
const my_features = sparc.featureSet(&[_]sparc.Feature{
    .v9,
    .vis2,
    .popc,
});

std.debug.print("Niagara4 has crypto: {}\n", .{has_crypto});
```

## 4) Dependencies

- `std` - Base standard library import
- `std.Target.Cpu` - CPU feature and model definitions
- `std.Target.Cpu.Feature` - Feature type definitions
- `std.Target.Cpu.Model` - CPU model type definitions
- `std.debug` - Debug assertions

This file is part of Zig's target support infrastructure and primarily depends on the CPU feature system in `std.Target.Cpu`.