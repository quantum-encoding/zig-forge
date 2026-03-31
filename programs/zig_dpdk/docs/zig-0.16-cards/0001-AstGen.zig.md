```markdown
# AstGen.zig Migration Card

## 1) Concept
AstGen.zig implements the lowering of Zig's Abstract Syntax Tree (AST) into ZIR (Zig Intermediate Representation), an untyped, linear instruction stream for semantic analysis and further compilation phases. It recursively traverses the AST, emitting ZIR instructions for expressions, declarations, control structures, and types while managing complex state such as scopes (for locals, namespaces, defers), result locations (rvalue/lvalue semantics via `ResultInfo`), source cursor tracking for debug info, string interning, and incremental compilation hashing. Key components include the `AstGen` struct (holding `instructions`, `extra`, `string_bytes`, `ref_table`, etc.), specialized emitters (e.g., `expr`, `blockExpr`, `fnDeclInner`), error emission via `compile_errors`, and scope types (`LocalVal`, `LocalPtr`, `Namespace`, `Defer`).

The primary public entry point `generate` initializes `AstGen`, performs result-location annotation via `AstRlAnnotate`, lowers the root container declaration, handles parse errors by emitting ZIR compile errors, populates extra data (imports, errors), and returns a complete `Zir` module.

## 2) The 0.11 vs 0.16 Diff
- **Explicit Allocator requirements**: Factory function `pub fn generate(gpa: Allocator, tree: Ast) Allocator.Error!Zir` requires explicit `Allocator` (no struct init or hidden arena).
- **I/O interface changes**: No direct I/O; ZIR output via return value (no file/stream deps injected).
- **Error handling changes**: Generic `Allocator.Error!Zir` (OOM only); semantic errors collected in `Zir.compile_errors` rather than specific sets.
- **API structure changes**: Pure factory `generate` (no `init`/`deinit` cycle exposed); internal state fully encapsulated.

## 3) The Golden Snippet
```zig
const zir = try AstGen.generate(gpa, tree);
```

## 4) Dependencies
- `std.mem`
- `std.zig.Ast`
- `std.zig.Zir`
- `std.zig.BuiltinFn`
- `std.zig.AstRlAnnotate`
- `std.hash_map`
- `std.ArrayListUnmanaged`
- `std.AutoHashMapUnmanaged`
- `std.AutoArrayHashMapUnmanaged`
- `std.heap.ArenaAllocator`
```
## Explanation of Analysis
- **Public API**: Single `pub fn generate` qualifies as developer-usable (e.g., compiler tooling/bootstrapping).
- **Snippet**: Directly from `pub fn generate` usage pattern.
- **No SKIP**: Contains public migration-impacting API.