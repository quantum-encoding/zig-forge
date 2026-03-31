# Migration Card: NVPTX Target Features

## 1) Concept

This file defines CPU features and models for NVIDIA's Parallel Thread Execution (PTX) architecture, which is used for GPU computing with NVIDIA hardware. The file is auto-generated and contains enumerations of PTX version features (ptx32 through ptx88) and NVIDIA GPU compute capability versions (sm_100 through sm_90a).

Key components include:
- `Feature` enum defining all available PTX and compute capability features
- Feature set utility functions (`featureSet`, `featureSetHas`, etc.) for working with feature combinations
- `all_features` array containing metadata for each feature (LLVM names, descriptions, dependencies)
- `cpu` namespace containing pre-defined CPU models with specific feature combinations

## 2) The 0.11 vs 0.16 Diff

This file contains no public API changes that require migration from 0.11 to 0.16 patterns because:

- **No explicit allocator requirements**: The file contains only enum definitions, compile-time arrays, and feature set utility functions - no dynamic allocation
- **No I/O interface changes**: This is a pure data definition file with no I/O operations
- **No error handling changes**: Functions operate on feature sets without error conditions
- **No API structure changes**: The pattern of defining features and CPU models remains consistent

The public exports are:
- `Feature` enum (data only)
- Feature set utility functions (unchanged pattern from 0.11)
- `all_features` compile-time array (data only)
- `cpu` models (data structures only)

## 3) The Golden Snippet

```zig
const std = @import("std");
const nvptx = std.Target.nvptx;

// Check if a feature set contains specific capabilities
const my_features = nvptx.featureSet(&.{.ptx70, .sm_80});
const has_ptx70 = nvptx.featureSetHas(my_features, .ptx70);
const has_sm_80 = nvptx.featureSetHas(my_features, .sm_80);

// Use a pre-defined CPU model
const sm_75_model = nvptx.cpu.sm_75;
```

## 4) Dependencies

- `std` (primary import)
- `std.Target.Cpu.Feature`
- `std.Target.Cpu.Model`

This file has minimal dependencies and primarily relies on the standard library's CPU feature system for its implementation.