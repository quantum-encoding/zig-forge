# Migration Card: RISC-V Target Features

## 1) Concept

This file defines RISC-V CPU features and models for Zig's target system. It's an auto-generated file that provides comprehensive definitions of RISC-V instruction set extensions, CPU features, and processor models. The file contains:

- A complete enum of all RISC-V features (from basic integer extensions like 'i' to specialized extensions like vector operations, cryptography, and custom vendor extensions)
- Feature set utility functions for checking feature dependencies and compatibility
- Detailed CPU model definitions with specific feature sets for various RISC-V implementations

This is part of Zig's cross-compilation infrastructure, allowing the compiler to target specific RISC-V processor capabilities and generate optimized code.

## 2) The 0.11 vs 0.16 Diff

**No public API migration changes detected.** This file contains only data definitions and enum declarations without public functions that would require migration. The key components are:

- **Enum declarations**: `Feature` enum with all RISC-V extensions
- **Feature set utilities**: Standard pattern using `CpuFeature.FeatureSetFns(Feature)` 
- **CPU model constants**: Static data structures defining processor configurations

The feature set functions (`featureSet`, `featureSetHas`, etc.) follow the established pattern from `std.Target.Cpu` and don't show allocator requirements or signature changes typical of 0.11→0.16 migrations.

## 3) The Golden Snippet

```zig
const std = @import("std");
const Target = std.Target;

// Check if a RISC-V CPU model supports specific features
pub fn main() void {
    const cpu_model = Target.riscv.cpu.sifive_u74;
    
    // Check if this CPU supports compressed instructions (C extension)
    const has_compressed = Target.riscv.featureSetHas(cpu_model.features, .c);
    std.debug.print("SiFive U74 has compressed instructions: {}\n", .{has_compressed});
    
    // Check if it supports atomic operations (A extension)  
    const has_atomic = Target.riscv.featureSetHas(cpu_model.features, .a);
    std.debug.print("SiFive U74 has atomic operations: {}\n", .{has_atomic});
}
```

## 4) Dependencies

- `std` (primary standard library import)
- `std.Target.Cpu` (CPU feature and model definitions)
- `std.Target.Cpu.Feature` (base feature type)
- `std.Target.Cpu.Model` (base CPU model type)
- `std.debug` (for assertions in compile-time blocks)

This file is part of Zig's target-specific infrastructure and primarily depends on the CPU feature system in `std.Target.Cpu`.