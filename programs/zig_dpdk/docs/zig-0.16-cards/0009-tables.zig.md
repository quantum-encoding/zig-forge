```markdown
# Migration Card: tables.zig

## 1) Concept
This file serves as the central hub for UEFI table-related definitions in Zig's `std.os.uefi.tables` module. It re-exports core UEFI service table types—`BootServices`, `RuntimeServices`, `ConfigurationTable`, `SystemTable`, and `TableHeader`—from dedicated submodules, providing developers with direct access to firmware interfaces. Additionally, it defines a comprehensive set of UEFI primitives, including enums (`TimerDelay`, `MemoryType`, `LocateSearchType`), packed structs (`MemoryDescriptorAttribute`), extern structs for memory management (`MemoryDescriptor`, `CapsuleHeader`), and utility wrappers like `MemoryMapSlice` and its iterator. These components enable low-level interaction with UEFI memory maps, protocols, allocation strategies, and events, forming the foundational types for building UEFI applications, drivers, or bootloaders.

Key features include OEM/vendor-extensible `MemoryType` handling with conversion methods (`fromOem`, `toOem`), iterable memory map slicing, protocol opening attributes (`OpenProtocolAttributes`, `OpenProtocolArgs`), and constants like `global_variable` GUID, all aligned with UEFI specifications for portability and type safety.

## 2) The 0.11 vs 0.16 Diff
This file primarily defines data types, enums, and structs with inline methods rather than standalone functions, so there are no traditional public function signatures to compare. However, notable shifts from Zig 0.11 patterns include:

- **No explicit Allocator requirements**: All types are stack-friendly or pointer-based (e.g., `MemoryMapSlice` uses raw `[*]u8` slices without allocators); no `init`/`deinit` pairs or factory functions observed—pure value initialization.
- **I/O interface changes**: `MemoryType.format` adopts modern dependency injection via `*std.Io.Writer` (generic writer pattern), returning `std.Io.Writer.Error!void`. Older 0.11 code might have used procedural printing or `std.debug.print`.
- **Error handling changes**: Method errors are specific (e.g., `Writer.Error`) rather than generic `error{...}` unions; no broad `!` propagation changes here.
- **API structure changes**: Shift to object-oriented patterns with methods on enums/structs (e.g., `MemoryType.fromOem()`, `MemoryMapSlice.iterator()`, `MemoryDescriptorIterator.next()`). No `init`/`open` dichotomy; types are zero-cost value types or extern layouts. `OpenProtocolAttributes` uses `packed struct` bitfields with `fromBits`/`toBits` for enum<->bits conversion, improving over raw integer manipulation in 0.11. Re-exports (e.g., `pub const BootServices`) follow submodule patterns for better modularity.

No breaking changes to core type layouts (extern/packed structs match spec); migration focuses on adopting iterator-based slicing over manual indexing.

## 3) The Golden Snippet
```zig
const map_slice = MemoryMapSlice{
    .info = .{ .key = .{}, .descriptor_size = @sizeOf(MemoryDescriptor), .descriptor_version = 0, .len = 10 },
    .ptr = undefined, // Provided by BootServices.GetMemoryMap()
};

var iter = map_slice.iterator();
while (iter.next()) |descriptor| {
    std.debug.print("Memory type: {}\n", .{descriptor.type});
}
```
(Demonstrates 0.16 iterator pattern on `MemoryMapSlice` for safe, idiomatic traversal.)

## 4) Dependencies
- `std` (core, testing, enums, Io.Writer)
- `std.os.uefi` (Handle, Event, Guid, cc; heavily used for all UEFI primitives)
- `std.math` (IntFittingRange for OEM/Vendor ranges)
- `std.debug` (assert)
- Submodules: `tables/boot_services.zig`, `tables/runtime_services.zig`, `tables/configuration_table.zig`, `tables/system_table.zig`, `tables/table_header.zig`
```
```