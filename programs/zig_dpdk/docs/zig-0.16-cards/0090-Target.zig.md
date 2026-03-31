# Migration Card: `std.Target`

## 1) Concept

This file defines the `Target` struct which represents a fully resolved compilation target in Zig. It contains concrete information about the target machine including CPU architecture, operating system, ABI, object format, and dynamic linker configuration. Unlike the `Query` module which might leave some components as "default" or "host", this data structure is fully resolved into specific OS versions, CPU features, and other concrete details.

Key components include:
- **CPU**: Architecture, model, and feature sets
- **OS**: Operating system tag and version ranges
- **ABI**: Application Binary Interface specification
- **ObjectFormat**: Binary format for object files
- **DynamicLinker**: Configuration for dynamic linking

## 2) The 0.11 vs 0.16 Diff

### Explicit Allocator Requirements
- **`zigTriple`**: Now requires explicit allocator parameter
- **`hurdTuple`**: Now requires explicit allocator parameter  
- **`linuxTriple`**: Now requires explicit allocator parameter
- **`DynamicLinker.initFmt`**: Now returns error union and requires format arguments

### API Structure Changes
- **Factory functions**: `Cpu.baseline()` and `Model.baseline()` replace direct struct initialization patterns
- **Enum evolution**: Many new OS tags added (visionos, ohos, ohoseabi, etc.)
- **Method organization**: Target-specific functionality organized into architecture-specific submodules

### Error Handling Changes
- **Specific error types**: Functions like `WindowsVersion.parse()` return specific errors (`error.InvalidOperatingSystemVersion`)
- **Error unions**: Dynamic linker initialization functions return error unions

## 3) The Golden Snippet

```zig
const std = @import("std");
const Target = std.Target;

// Create a target for x86_64 Linux
pub fn createLinuxTarget() Target {
    const arch = .x86_64;
    const os_tag = .linux;
    const abi = Target.Abi.default(arch, os_tag);
    
    return .{
        .cpu = Target.Cpu.baseline(arch, .{
            .tag = os_tag,
            .version_range = Target.Os.defaultVersionRange(arch, os_tag, abi),
        }),
        .os = .{
            .tag = os_tag,
            .version_range = Target.Os.defaultVersionRange(arch, os_tag, abi),
        },
        .abi = abi,
        .ofmt = Target.ObjectFormat.default(os_tag, arch),
        .dynamic_linker = Target.DynamicLinker.none,
    };
}

// Usage example
pub fn main() !void {
    var target = createLinuxTarget();
    std.debug.print("Target executable extension: {s}\n", .{target.exeFileExt()});
    std.debug.print("Pointer bit width: {d}\n", .{target.ptrBitWidth()});
    std.debug.print("Stack alignment: {d}\n", .{target.stackAlignment()});
}
```

## 4) Dependencies

- **`std.mem`**: Used for memory operations and feature set manipulation
- **`std.fmt`**: Used for string formatting in triple generation
- **`std.io`**: Used for Windows version formatting
- **`std.enums`**: Used for enum name resolution
- **`std.SemanticVersion`**: Used for OS version range handling
- **`std.zig.target`**: Used for available libc information
- **`std.zig.Subsystem`**: Used for subsystem definitions (deprecated)
- **`std.coff`**: Used for COFF machine type conversions
- **`std.elf`**: Used for ELF machine type conversions

### Target-Specific Submodules
- `std.Target.aarch64`, `std.Target.x86`, `std.Target.arm`, etc.
- `std.Target.Query` for target query functionality

This module represents a stable core API with evolutionary changes focused on better allocator handling and expanded platform support rather than breaking API changes.