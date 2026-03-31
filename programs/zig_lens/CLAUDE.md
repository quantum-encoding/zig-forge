# CLAUDE.md — zig_lens

> Project guide for Claude Code instances working on zig_lens.
> Read this COMPLETELY before writing any code.

---

## Identity

You are building `zig_lens` — a Zig source code analysis and visualization tool for the Quantum Zig Forge monorepo. This tool uses the Zig compiler's own parser (`std.zig.Ast`) to produce accurate, complete structural analysis of Zig projects. No external parser, no regex hacks, no incomplete grammar — the same AST the compiler sees is the AST you analyze.

You are a senior tooling engineer at Quantum Encoding. You build developer infrastructure that other engineers and AI agents rely on for accurate information. Accuracy is non-negotiable — if the tool reports a function signature, it must be correct. If it reports a dependency, that dependency must exist. False positives erode trust faster than missing data.

### Standards

- **Use the compiler's parser.** `std.zig.Ast.parse()` is the only acceptable way to parse Zig source. Never write custom tokenizers or regex-based extraction.
- **Zero false positives.** It is better to report nothing than to report something incorrect. If analysis is ambiguous, say so explicitly.
- **Structured output always.** Every analysis produces machine-readable output (JSON). Human-readable summaries are derived from the structured data, never generated separately.
- **No external dependencies.** Pure Zig, no libc, no external tools. The binary should work on any platform Zig targets.

---

## Why This Tool Exists

### Problem
The Quantum Zig Forge monorepo contains 60+ programs and 130+ utilities. When a new Claude Code instance is spun up on an unfamiliar program, it has no structural understanding of the codebase. It reads files sequentially, guesses at architecture, misses dependencies, and wastes context window on exploration.

### Solution
`zig_lens` scans a Zig project and produces a structured report: what's in the code, how it's connected, what the public API looks like, where the complexity lives, and what patterns are used. This report can be fed directly to an AI agent as context, printed to terminal, or exported as JSON/DOT/Markdown for tooling.

### Users
1. **Claude Code instances** — scan an unfamiliar codebase before starting work. Instant structural map instead of reading every file sequentially.
2. **Rich (the developer)** — understand cross-project dependencies, audit unsafe operations, track API surface growth across the monorepo.
3. **Investor presentations** — visualize the scale and architecture. "Here's a dependency graph of 60 programs sharing 15 libraries."
4. **Open source contributors** — onboard by reading the structural report instead of manually exploring.

---

## Ecosystem Context

Lives in the Quantum Zig Forge monorepo at `programs/zig_lens/`.

### Integration Points

| Tool | Relationship |
|------|-------------|
| **All 60+ programs** | Analysis targets |
| **zig_core_utils** (131 utilities) | Primary test corpus — 131 standalone projects |
| **zig_charts** | Visualization backend — JSON chart API for graphs and heatmaps |
| **zig_pdf_generator** | PDF report generation |
| **Zigix kernel** | Complex multi-file analysis target (stress test) |

---

## Project Structure

```
programs/zig_lens/
├── build.zig
├── src/
│   ├── main.zig              # CLI entry, argument parsing, output dispatch
│   ├── scanner.zig           # File discovery — walk dirs, find .zig files, skip zig-cache
│   ├── parser.zig            # AST parsing wrapper — std.zig.Ast.parse() + error recovery
│   ├── analyzers/
│   │   ├── structure.zig     # Functions, structs, enums, unions, constants, tests
│   │   ├── imports.zig       # @import graph — file deps, stdlib vs local vs package
│   │   ├── api_surface.zig   # Public API extraction — pub decls, doc comments, signatures
│   │   ├── unsafe_ops.zig    # Unsafe operation audit — @ptrCast, @intFromPtr, asm, etc.
│   │   ├── complexity.zig    # Cyclomatic complexity, nesting depth, function length, LOC
│   │   ├── patterns.zig      # Allocator usage, error handling, comptime, SIMD, vtables
│   │   └── quality.zig       # Doc coverage, test density, naming, catch {} detection
│   ├── graph/
│   │   ├── builder.zig       # Build dependency graph from import analysis
│   │   ├── dot.zig           # Graphviz DOT export
│   │   └── cycles.zig        # Cycle detection (Tarjan's SCC)
│   ├── output/
│   │   ├── terminal.zig      # Colored terminal summary
│   │   ├── json.zig          # JSON export (primary machine-readable format)
│   │   ├── markdown.zig      # Markdown report generation
│   │   └── html.zig          # Self-contained HTML report with embedded SVG
│   └── models.zig            # Shared data types — FileReport, FunctionInfo, StructInfo, etc.
└── tests/
    ├── test_parser.zig
    ├── test_imports.zig
    ├── test_complexity.zig
    └── fixtures/
        ├── simple.zig
        ├── complex_struct.zig
        ├── unsafe_heavy.zig
        └── circular_a.zig / circular_b.zig
```

---

## CLI Design

```bash
# Scan a single file
zig-lens src/main.zig

# Scan a project directory (auto-finds build.zig, walks src/)
zig-lens programs/zig_dpdk/

# Scan entire monorepo (discovers all build.zig projects)
zig-lens --monorepo /path/to/quantum-zig-forge

# Output formats
zig-lens programs/zig_dpdk/ --format terminal     # Colored terminal (default)
zig-lens programs/zig_dpdk/ --format json          # Machine-readable JSON
zig-lens programs/zig_dpdk/ --format markdown      # GitHub-compatible markdown
zig-lens programs/zig_dpdk/ --format html          # Self-contained HTML report
zig-lens programs/zig_dpdk/ --format dot           # Graphviz DOT dependency graph

# Specific analyses
zig-lens programs/zig_dpdk/ --imports              # Import/dependency graph only
zig-lens programs/zig_dpdk/ --unsafe               # Unsafe operations audit
zig-lens programs/zig_dpdk/ --api                  # Public API surface
zig-lens programs/zig_dpdk/ --complexity           # Complexity metrics
zig-lens programs/zig_dpdk/ --patterns             # Pattern detection

# Graph output (pipeable to graphviz)
zig-lens programs/zig_dpdk/ --imports --format dot | dot -Tsvg > deps.svg

# Compact JSON for AI context windows
zig-lens programs/zig_dpdk/ --format json --compact

# Diff two snapshots
zig-lens --diff before.json after.json

# Filter options
zig-lens programs/zig_dpdk/ --exclude tests/      # Skip test files
zig-lens programs/zig_dpdk/ --only-pub            # Only public API
zig-lens programs/zig_dpdk/ --min-complexity 5    # Only complex functions

# Output to file
zig-lens programs/zig_dpdk/ --output report.json
```

---

## Implementation Phases

### Phase 1: Core Scanner + AST Structure

The foundation. Parse Zig files using the compiler's AST and extract structural information.

**P1.1 — File Discovery (`scanner.zig`)**
- Walk a directory tree, collect all `.zig` files
- Skip `zig-cache/`, `zig-out/`, `.zig-cache/` directories automatically
- Detect project root by finding the nearest `build.zig` ancestor
- Return sorted list of `FileEntry`: `{ path, relative_path, size_bytes }`
- For monorepo: find all `build.zig` files to identify project boundaries

**P1.2 — AST Parser Wrapper (`parser.zig`)**
- Read file contents, call `std.zig.Ast.parse(allocator, source, .zig)`
- Handle parse errors gracefully — report them but continue
- Provide helper functions for common operations:

```zig
const std = @import("std");
const Ast = std.zig.Ast;

/// Parse a file and return the AST. Reports parse errors but doesn't abort.
pub fn parseFile(allocator: std.mem.Allocator, source: [:0]const u8) !Ast {
    return Ast.parse(allocator, source, .zig);
}

/// Check if a declaration node has the `pub` keyword before it.
pub fn isPublic(ast: Ast, node_idx: Ast.Node.Index) bool {
    const first_token = ast.firstToken(node_idx);
    if (first_token > 0) {
        return ast.tokens.items(.tag)[first_token - 1] == .keyword_pub;
    }
    return false;
}

/// Get the name of a declaration (function, var, const).
pub fn getDeclName(ast: Ast, node_idx: Ast.Node.Index) ?[]const u8 {
    const tag = ast.nodes.items(.tag)[node_idx];
    const main_token = ast.nodes.items(.main_token)[node_idx];
    return switch (tag) {
        .fn_decl, .fn_proto_simple, .fn_proto_multi, .fn_proto_one => ast.tokenSlice(main_token + 1),
        .simple_var_decl, .aligned_var_decl => ast.tokenSlice(main_token + 1),
        else => null,
    };
}

/// Extract the path from an @import("...") builtin call.
pub fn extractImportPath(ast: Ast, node_idx: Ast.Node.Index) ?[]const u8 {
    const tag = ast.nodes.items(.tag)[node_idx];
    if (tag != .builtin_call_two and tag != .builtin_call) return null;

    const main_token = ast.nodes.items(.main_token)[node_idx];
    if (!std.mem.eql(u8, ast.tokenSlice(main_token), "@import")) return null;

    const data = ast.nodes.items(.data)[node_idx];
    const arg_tag = ast.nodes.items(.tag)[data.lhs];
    if (arg_tag != .string_literal) return null;

    const raw = ast.tokenSlice(ast.nodes.items(.main_token)[data.lhs]);
    return raw[1 .. raw.len - 1]; // Strip quotes
}

/// Convert token byte offset to line:col.
pub fn tokenLocation(ast: Ast, source: []const u8, token_idx: u32) struct { line: u32, col: u32 } {
    const offset = ast.tokens.items(.start)[token_idx];
    var line: u32 = 1;
    var col: u32 = 1;
    for (source[0..@min(offset, source.len)]) |c| {
        if (c == '\n') { line += 1; col = 1; } else { col += 1; }
    }
    return .{ .line = line, .col = col };
}
```

**P1.3 — Structure Analyzer (`analyzers/structure.zig`)**
- Walk top-level declarations via `ast.rootDecls()`
- Extract per node type:
  - **Functions** (`.fn_decl`): name, params, return type, pub, comptime, export, extern, line, body line count
  - **Structs** (`.container_decl*`): name, fields, nested methods, packed, extern
  - **Enums**: name, variants, tag type, methods
  - **Unions**: name, fields, tag type, methods
  - **Constants/Variables** (`.simple_var_decl`): name, type, pub, comptime
  - **Test blocks** (`.test_decl`): name string, line
- Extract doc comments (`///`) and attach to associated declarations
- Handle nested containers (struct inside struct)

**P1.4 — Terminal Output (`output/terminal.zig`)**
```
zig-lens — programs/zig_dpdk/

Files:     13         Functions:   87
Structs:   12         Enums:        3
LOC:     1,847        Tests:       14
Pub API:   34         Unsafe ops:   7

Largest files:
  src/core/mbuf.zig      312 lines  (14 fns, 3 structs)
  src/core/ring.zig      287 lines  (11 fns, 1 struct)
  src/drivers/pmd.zig    201 lines  (8 fns, 2 structs)

Hotspots (highest complexity):
  mbuf.zig:allocPool     42 lines  complexity=8
  ring.zig:enqueue       38 lines  complexity=6

Unsafe operations:
  mem/physical.zig:23    @intFromPtr  (virt-to-phys translation)
  mem/hugepage.zig:45    @ptrCast     (hugepage alignment)
  drivers/pmd.zig:112    @ptrCast     (MMIO register access)
```

### Phase 2: Dependency Analysis + Graphs

**P2.1 — Import Graph (`analyzers/imports.zig`)**
- Find all `@import("...")` calls by walking AST nodes
- Classify: stdlib (`"std"`, `"builtin"`), local (file paths), package (named deps)
- Resolve relative paths within the project
- Build directed graph: nodes = files, edges = imports
- Track what's imported: `const tcp = @import("tcp.zig")` tells us the binding name

**P2.2 — Graph Builder + DOT Export (`graph/`)**
- Adjacency list from import data
- Tarjan's SCC for cycle detection
- Fan-in (how many files import this one) and fan-out (how many imports)
- Hub detection: files with highest in-degree are core modules
- DOT output with directory clusters, LOC-sized nodes, colored by role

**P2.3 — Dependency Metrics**
- Max dependency depth
- Orphan files (nothing imports them, not entry points)
- Coupling score per file (fan-in × fan-out)

### Phase 3: Deep Analysis

**P3.1 — Unsafe Operations Audit (`analyzers/unsafe_ops.zig`)**

| Operation | AST Detection | Risk Level |
|-----------|--------------|------------|
| `@ptrCast` | builtin_call, name "@ptrCast" | High |
| `@intFromPtr` | builtin_call | High |
| `@ptrFromInt` | builtin_call | High |
| `@alignCast` | builtin_call | Medium |
| `@bitCast` | builtin_call | Medium |
| `@intCast` / `@truncate` | builtin_call | Medium |
| `@setRuntimeSafety(false)` | builtin_call | Critical |
| `asm` / `asm volatile` | .asm_expr node | Critical |
| `@cImport` / `@cInclude` | builtin_call | Low |
| `allowzero` pointers | token scan | High |

Report: file, line, operation, function context, risk level, code snippet.

**P3.2 — Complexity Metrics (`analyzers/complexity.zig`)**
- Cyclomatic complexity per function (count: if, switch prongs, while, for, catch, orelse, try, and/or)
- Function length (lines)
- Nesting depth (maximum)
- Parameter count (flag >5)
- File-level: total LOC, blank lines, comment lines, comment ratio

**P3.3 — Pattern Detection (`analyzers/patterns.zig`)**

| Pattern | Detection | Significance |
|---------|----------|-------------|
| Allocator params | Function param type contains "Allocator" | Memory management strategy |
| Io params | Function param type contains "Io" | Async capability (std.Io) |
| Error handling | catch/try usage, error union returns | Reliability |
| Comptime generics | `comptime` params, `anytype` | Generic code |
| SIMD | `@Vector`, `@shuffle`, `@reduce` | Performance optimization |
| Packed structs | `packed struct` keyword | Hardware/protocol layouts |
| Extern structs | `extern struct` keyword | C FFI interop |
| Vtable pattern | Struct with fn pointer fields | Polymorphism/drivers |
| State machine | Switch on enum in loop | Protocol/event handling |
| Silent error swallow | `catch {}` | Bug risk (broke musl on Zigix) |

**P3.4 — Error Handling Analysis**
- Map `catch unreachable` usage (flag as risky)
- Detect `catch {}` (silent error swallowing — this is what broke musl utils on Zigix)
- Track error set propagation: which functions return which errors
- Flag functions that discard errors vs propagate them

**P3.5 — Quality Signals (`analyzers/quality.zig`)**
- Doc comment coverage (% of pub decls with `///`)
- Test density (test blocks per file, ratio to functions)
- TODO/FIXME/HACK markers in comments
- Undocumented public API

### Phase 4: Multi-Project + AI Agent Mode

**P4.1 — Build.zig Analysis**
- Parse `build.zig` as a Zig file via `std.zig.Ast`
- Detect patterns: `addExecutable`, `addStaticLibrary`, `addTest`, `dependency`, `linkSystemLibrary`
- Extract target names, root source files, dependencies
- Note: build.zig is imperative code, so this is best-effort pattern matching

**P4.2 — Monorepo Mode**
- Discover all projects (directories with `build.zig`)
- Run analysis on each, build cross-project dependency graph
- One-line summary per project
- Identify shared libraries and their consumers

**P4.3 — AI Agent JSON Output**
The killer feature. Compact JSON optimized for AI context windows:

```json
{
  "project": "zig_dpdk",
  "summary": { "files": 13, "loc": 1847, "functions": 87, "structs": 12, "pub_api": 34, "tests": 14, "unsafe_ops": 7 },
  "architecture": {
    "entry_points": ["main.zig"],
    "core_modules": ["core/ring.zig", "core/mbuf.zig", "core/mempool.zig"],
    "drivers": ["drivers/pmd.zig"],
    "platform": ["platform/linux.zig", "platform/zigix.zig"]
  },
  "key_types": [
    { "name": "MBuf", "file": "core/mbuf.zig", "kind": "struct", "fields": 12, "methods": 8, "doc": "64-byte cache-aligned packet buffer metadata" }
  ],
  "pub_functions": [
    { "name": "rxBurst", "file": "drivers/pmd.zig", "signature": "fn rxBurst(*PmdDriver, []*MBuf, u16) u16", "doc": "Poll NIC for received packets" }
  ],
  "dependency_graph": {
    "main.zig": ["core/ring.zig", "core/mbuf.zig", "core/config.zig"],
    "core/mbuf.zig": ["core/ring.zig", "mem/hugepage.zig"]
  },
  "warnings": [
    { "type": "high_complexity", "file": "core/mbuf.zig", "function": "allocPool", "value": 8 },
    { "type": "unsafe_op", "file": "mem/physical.zig", "line": 23, "op": "@intFromPtr" },
    { "type": "silent_catch", "file": "platform/linux.zig", "line": 89, "context": "catch {}" }
  ]
}
```

A new Claude Code instance reads this and immediately knows the architecture without reading 2800 lines of source.

### Phase 5: Visualization + Reporting

**P5.1 — HTML Report** — Self-contained HTML with embedded SVG dependency graph, collapsible file analysis, complexity heatmap
**P5.2 — Markdown Report** — GitHub-compatible with Mermaid diagrams
**P5.3 — Diff Mode** — Compare two JSON snapshots, report API changes, complexity trends

---

## AST Navigation Reference

### Key Patterns

```zig
// Parse
var ast = try std.zig.Ast.parse(allocator, source, .zig);
defer ast.deinit(allocator);

// Walk top-level declarations
for (ast.rootDecls()) |decl_idx| {
    const tag = ast.nodes.items(.tag)[decl_idx];
    const main_token = ast.nodes.items(.main_token)[decl_idx];
    const data = ast.nodes.items(.data)[decl_idx];

    switch (tag) {
        .fn_decl => { /* function — name at main_token+1 */ },
        .simple_var_decl => { /* const/var — name at main_token+1 */ },
        .container_decl, .container_decl_trailing,
        .container_decl_two, .container_decl_two_trailing,
        => { /* struct/enum/union */ },
        .test_decl => { /* test block */ },
        else => {},
    }
}

// Get source text of a token
const name = ast.tokenSlice(token_index);

// Get children: data.lhs and data.rhs (node indices)
// Some nodes have extra data — check std.zig.Ast source for specifics

// Source location
const byte_offset = ast.tokens.items(.start)[token_index];
// Count newlines in source[0..byte_offset] to get line number
```

### Token vs Node
- **Nodes** = AST constructs (declarations, expressions, statements). Navigate with `.tag`, `.data`, `.main_token`.
- **Tokens** = lexical elements (identifiers, keywords, literals). Get text with `ast.tokenSlice()`.
- A node's `.main_token` = the "most important" token (fn keyword, var keyword, etc.).
- The AST is a flat `u32`-indexed array, not a pointer tree. Cache-friendly. Don't fight the indices.

---

## Performance Targets

| Operation | Target |
|-----------|--------|
| Single file parse + analyze | <10ms |
| 131-file project (zig_core_utils) | <500ms |
| Full monorepo scan | <5s |
| JSON output for 100-function project | <50ms |
| Memory usage (monorepo) | <100MB |

Bottleneck is file I/O, not parsing. `std.zig.Ast.parse` is the compiler's own parser — it handles millions of lines per second.

---

## Codebase Rules

1. **std.zig.Ast is the only parser.** No regex. No manual tokenizers. The AST gives you everything.
2. **Graceful degradation.** Bad file? Report it, skip it, continue. Never abort a scan for one bad file.
3. **JSON is source of truth.** All other formats derive from the same analysis data. Analyze once, render many ways.
4. **Deterministic output.** Same input = identical output. Sort everything. No hash map iteration order leaking into output.
5. **Test with real code.** Fixtures for unit tests. Integration tests scan actual monorepo programs.
6. **Comments are data.** Extract `///` doc comments and attach to declarations. Part of the API surface.
7. **Zero external dependencies.** Pure Zig. Builds with `zig build` and nothing else.
8. **Context-window aware.** `--compact` JSON mode minimizes size while maximizing structural insight for AI agents.

---

## Priority Order

1. **P1.2 + P1.3 + P1.4** — Parse files, extract structure, terminal summary. Immediately useful.
2. **P2.1 + P2.2** — Import graph + DOT export. Architecture visualization.
3. **P3.1** — Unsafe ops audit. Security value.
4. **P4.3** — AI agent JSON output. The workflow multiplier.
5. **P3.2** — Complexity metrics.
6. Everything else follows naturally.

Get the core scanner producing terminal output first. Everything builds on that foundation.

---

## What Success Looks Like

A new Claude Code instance runs `zig-lens programs/zig_dpdk/ --format json --compact` and in under 500ms gets a complete structural map: 13 files, 87 functions, 12 structs, the dependency graph, the public API, the unsafe operations, and the complexity hotspots.

Instead of reading 2800 lines of source sequentially, the agent knows the architecture in milliseconds. That's the value proposition.
