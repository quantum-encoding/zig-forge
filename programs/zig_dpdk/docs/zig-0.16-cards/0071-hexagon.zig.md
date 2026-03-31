# Migration Card: Hexagon Target Features

## 1) Concept

This file defines CPU features and models for the Hexagon architecture target in Zig's standard library. It's an auto-generated file that enumerates all available Hexagon processor features (like audio extensions, HVX vector instructions, memory operations) and defines various CPU models with their specific feature sets. The file provides feature set manipulation functions and detailed metadata about each feature including LLVM names, descriptions, and dependencies.

Key components include:
- `Feature` enum with 45 different Hexagon architecture features
- Feature set manipulation functions (`featureSet`, `featureSetHas`, etc.)
- `all_features` array containing detailed metadata for each feature
- `cpu` namespace with 16 different Hexagon CPU models (v5 through v79)

## 2) The 0.11 vs 0.16 Diff

This file contains minimal migration impact as it primarily defines data structures rather than public APIs with complex signatures. The key observations:

- **No explicit allocator requirements**: The feature set functions are generic and don't require memory allocation
- **No I/O interface changes**: This is a pure data definition file with no I/O operations
- **No error handling changes**: Functions operate on compile-time known data without error returns
- **API structure consistency**: The pattern uses static feature sets and enum-based feature definitions

The main public API consists of:
- `featureSet(features: []const Feature) FeatureSet` - creates feature sets from feature slices
- `featureSetHas(set: FeatureSet, feature: Feature) bool` - checks feature presence
- CPU model constants with predefined feature sets

## 3) The Golden Snippet

```zig
const std = @import("std");
const hexagon = std.Target.hexagon;

// Check if a CPU model supports specific features
const cpu_model = hexagon.cpu.hexagonv68;
const features = cpu_model.features;

const has_hvx = hexagon.featureSetHas(features, .hvx);
const has_audio = hexagon.featureSetHas(features, .audio);
const has_memops = hexagon.featureSetHas(features, .memops);

// Create a custom feature set
const custom_features = hexagon.featureSet(&[_]hexagon.Feature{
    .hvx,
    .hvx_length128b,
    .memops,
    .packets,
});
```

## 4) Dependencies

- `std` - Main standard library import
- `std.Target.Cpu` - CPU feature and model definitions
- `std.Target.Cpu.Feature` - Individual CPU feature type
- `std.Target.Cpu.Model` - CPU model definition type
- `std.debug` - Runtime assertions for validation

This file is primarily a data definition file with minimal runtime behavior, serving as configuration for the Zig compiler's Hexagon target support.