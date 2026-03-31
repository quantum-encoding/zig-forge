```markdown
# Migration Card: Builder.zig

## 1) Concept
This file implements the core `Builder` struct for programmatically constructing LLVM IR modules, optimized for Zig's compiler backend. It provides a high-level, type-safe API to define LLVM types (integers, pointers, vectors, structs, functions), constants (integers, floats, aggregates, zero/undef/poison), globals (variables, functions, aliases), attributes, metadata (DWARF debug info), and function bodies with instructions (arithmetic, loads/stores, calls, branches, etc.). Key components include deduplicated storage via hash maps (`AutoArrayHashMapUnmanaged`) for strings, types, constants, and attributes; efficient serialization to LLVM text or bitcode; and WIP (work-in-progress) function builders for safe instruction emission. The builder supports bitcode output via `toBitcode` and text printing via `print`, with options for stripping debug info.

The API emphasizes capacity pre-allocation (`ensureUnused*Capacity`, `AssumeCapacity` variants) for performance, comptime-generated LLVM intrinsics/signatures, and rich debug metadata (DI* nodes). It handles LLVM specifics like address spaces, linkages, call conventions, fast-math flags, and atomic operations while abstracting low-level details.

## 2) The 0.11 vs 0.16 Diff
- **Explicit Allocator requirements**: All init requires `Options` with `Allocator`; no more implicit/general-purpose allocators. Factory functions like `intType`, `ptrType`, `fnType` now return `Allocator.Error!Type` and use `self.gpa`. `AssumeCapacity` variants (e.g., `intTypeAssumeCapacity`) added for manual capacity management, replacing 0.11's less explicit patterns.
- **I/O interface changes**: `print` now takes `std.Io.Writer` (dependency injection); no more fixed buffers or implicit writers. `printToFile`/`dump` use allocating writers. Bitcode output via new `toBitcode` with producer metadata.
- **Error handling changes**: Generic `Allocator.Error!` everywhere (e.g., `string`, `addGlobal`); no specific LLVM errors. `!void` for infallible ops.
- **API structure changes**: No `init`/`open`; single `init(Options)` with `gpa`, `strip`, `name`, `target`, `triple`. Globals use `addGlobal(name, Global)` or helpers (`addVariable`, `addFunction`, `addAlias`); functions via `WipFunction` for building bodies (`finish`). Types use `fnType(ret, params, kind)` replacing vararg patterns. Metadata via dedicated `debug*` factories (e.g., `debugFile`, `debugSubprogram`). New `strtabString` for symbol tables.

| 0.11 Pattern | 0.16 Signature |
|--------------|----------------|
| Implicit alloc | `Builder.init(.{ .allocator = gpa })` |
| `makeInt(bits)`? | `builder.intType(bits)` → `Allocator.Error!Type` |
| Direct instr emit | `WipFunction` + `finish()` |
| Fixed print | `builder.print(writer)` |

## 3) The Golden Snippet
```zig
const std = @import("std");
var gpa = std.heap.GeneralPurposeAllocator(.{}).transact();
const builder = try Builder.init(.{
    .allocator = gpa.allocator(),
    .strip = false,
    .name = "module.ll",
});
defer builder.deinit();

const i32_ty = try builder.intType(32);
const main_fn_ty = try builder.fnType(.void, &.{i32_ty}, .normal);
const main_fn = try builder.addFunction(main_fn_ty, "main", .default);
```
## 4) Dependencies
- `std.mem` (Allocator, ArrayListUnmanaged, AutoHashMapUnmanaged, MultiArrayList)
- `std.log` (scoped logging)
- `std.dwarf` (DW constants)
- `std.Io.Writer` (output interfaces)
- `ir.zig` (IR types/enums)
- `bitcode_writer.zig` (bitcode emission)
```
## Summary
Public LLVM IR builder API with allocator-driven, capacity-aware construction; migrated to explicit errors, writer DI, and structured factories/WIP helpers. Use `AssumeCapacity` for perf-critical code.