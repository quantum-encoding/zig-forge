# Migration Card: Propeller Target CPU Features

## 1) Concept

This file defines CPU features and models for the Propeller architecture target in Zig's standard library. It's an auto-generated file that provides architectural feature definitions for the Propeller processor family. The key components include:

- A `Feature` enum defining the available CPU features (currently just `p2` for Propeller 2 support)
- Utility functions for working with feature sets (`featureSet`, `featureSetHas`, etc.)
- Complete feature definitions in `all_features` array
- CPU model definitions (`p1` and `p2`) with their respective feature sets

This file serves as metadata for the compiler's code generation backend, enabling feature detection and target-specific optimizations for Propeller processors.

## 2) The 0.11 vs 0.16 Diff

**No migration-required changes detected.** This file contains only data definitions and generic utility functions that follow consistent patterns across Zig versions. The public API consists of:

- Enum definitions (`Feature`)
- Generic feature set utility functions (via `CpuFeature.FeatureSetFns`)
- CPU model constants (`cpu.p1`, `cpu.p2`)
- Feature metadata array (`all_features`)

All these elements use standard Zig patterns that haven't changed between 0.11 and 0.16. The file contains no:
- Explicit allocator requirements
- I/O interface changes  
- Error handling changes
- API structure changes requiring migration

## 3) The Golden Snippet

```zig
const std = @import("std");
const propeller = std.Target.propeller;

// Check if a CPU model supports specific features
const features = propeller.cpu.p2.features;
const has_p2 = propeller.featureSetHas(features, propeller.Feature.p2);

// Use in target specification
const target = std.zig.CrossTarget{
    .cpu_arch = .propeller,
    .cpu_model = .{ .explicit = &propeller.cpu.p2 },
};
```

## 4) Dependencies

- `std` - Base standard library import
- `std.Target.Cpu` - CPU feature and model definitions
- `std.debug` - Runtime assertions

This file has minimal dependencies and primarily relies on the compiler target infrastructure rather than memory allocation, I/O, or other runtime services.