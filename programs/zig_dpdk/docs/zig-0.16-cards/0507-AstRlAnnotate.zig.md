# Migration Card: AstRlAnnotate.zig

## 1) Concept

This file implements an AST (Abstract Syntax Tree) analysis pass that runs before AstGen to determine which expressions require result locations. The key purpose is to optimize ZIR (Zig Intermediate Representation) generation by deciding when to use result pointers versus simple block break instructions.

The main component is the `AstRlAnnotate` struct which analyzes syntax forms that may provide result locations. It tracks nodes where sub-expressions consume result pointers non-trivially (e.g., through field pointer writes) and marks them as requiring actual result locations from allocations rather than just using break instructions.

## 2) The 0.11 vs 0.16 Diff

**No public API migration changes detected.** This file contains internal compiler infrastructure with no user-facing public APIs. The analysis reveals:

- The only public function `annotate` maintains the same allocator-centric pattern already present in Zig 0.11
- No I/O interface changes - this is purely AST analysis
- No error handling changes - only `Allocator.Error` is used
- No API structure changes - this is internal compiler logic

The file follows established Zig patterns with explicit allocator requirements, but these patterns were already standard in 0.11.

## 3) The Golden Snippet

**No user-facing API exists in this file.** This is internal compiler infrastructure. The only public function is for internal compiler use:

```zig
// Internal compiler usage only
const nodes_needing_rl = try AstRlAnnotate.annotate(gpa, arena, parsed_tree);
```

## 4) Dependencies

The file imports these standard library modules:

- `std.mem` (for `Allocator`, `AutoHashMapUnmanaged`)
- `std.zig` (for `Ast`, `BuiltinFn`)
- `std.debug` (for `assert`)

This indicates heavy dependency on memory allocation utilities and the Zig AST representation system.

---

**Conclusion**: This is an internal compiler implementation file with no public migration impact for Zig developers.