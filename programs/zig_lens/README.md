# zig-lens

Multi-language source code analysis and visualization tool, written in Zig. Scans codebases and produces structural reports — functions, types, imports, dependency graphs, unsafe operations, and complexity metrics — in multiple output formats.

Built for the [Quantum Zig Forge](https://github.com/quantum-encoding/quantum-zig-forge) monorepo. Designed to give AI agents and developers instant structural understanding of unfamiliar codebases without reading every file.

## Supported Languages

| Language | Analysis Method | Coverage |
|----------|----------------|----------|
| **Zig** | `std.zig.Ast` (compiler's own parser) | Full AST — functions, structs, enums, unions, imports, unsafe builtins, doc comments |
| **Rust** | Line-based scanner | Functions, structs, enums, traits, impl blocks, `use`/`mod`, unsafe blocks, doc comments |
| **C** | Line-based scanner | Functions, structs, enums, unions, typedefs, `#include`, `#define`, unsafe C patterns (`strcpy`, `gets`, etc.) |
| **Python** | Indent-aware scanner | Functions, classes, imports, decorators, docstrings, constants, unsafe patterns (`eval`, `exec`, `os.system`) |
| **JavaScript/TypeScript** | Line-based scanner | Functions, arrow functions, classes, interfaces, type aliases, enums (TS), imports/require, JSDoc, tests (`describe`/`it`/`test`) |
| **Svelte** | JS/TS scanner (within `<script>` blocks) | Same as JS/TS |

## Quick Start

```bash
# Build
zig build

# Analyze a single file
zig-lens src/main.zig

# Analyze a project directory
zig-lens /path/to/project/

# JSON output
zig-lens /path/to/project/ --format json

# Compact JSON optimized for AI context windows
zig-lens /path/to/project/ --compact

# Generate all reports into a directory
zig-lens /path/to/project/ --report ./docs/

# Compile entire codebase into a single Markdown file
zig-lens /path/to/project/ --compile --output codebase.md
```

## Output Formats

### Terminal (default)

Colored summary with file rankings and function hotspots:

```
zig-lens — my_project

  Files:     13        Functions:  87
  Structs:   12        Enums:       3
  LOC:       1,847     Tests:      14
  Pub API:   34        Imports:    22

Largest files:
  src/core/mbuf.zig                        312 lines  (14 fns, 3 structs)
  src/core/ring.zig                        287 lines  (11 fns, 1 struct)

Hotspots (largest functions):
  core/mbuf.zig:allocPool              42 lines
  core/ring.zig:enqueue                38 lines
```

### JSON (`--format json`)

Full per-file analysis with functions, structs, enums, unions, imports, tests, and unsafe operations. Includes line numbers, parameter signatures, return types, and doc comments.

### Compact JSON (`--compact`)

AI-optimized output: project summary, key types, public functions, dependency graph, and warnings. Designed to fit in an LLM context window while maximizing structural insight.

### Markdown (`--format markdown` or `--format md`)

GitHub-compatible report with summary tables, Mermaid dependency diagrams, public API listing, and unsafe operations audit.

### Graphviz DOT (`--format dot`)

Dependency graph for visualization. Nodes are colored by role (green = entry point, blue = hub module, gray = leaf). Directories are grouped into subgraph clusters.

```bash
zig-lens /path/to/project/ --format dot | dot -Tsvg > deps.svg
```

### Codebase Compilation (`--compile`)

Concatenates all source files into a single Markdown document with a directory tree and syntax-highlighted file contents. Skips binary files, build artifacts, `node_modules`, `zig-cache`, etc. Useful for feeding an entire codebase to an AI agent in one shot.

## Report Mode (`--report <dir>`)

Generates all output formats into a directory at once:

| File | Description |
|------|-------------|
| `ai-context.json` | Compact JSON for AI agents |
| `full-analysis.json` | Detailed per-file JSON |
| `summary.md` | Markdown summary with tables |
| `dependencies.dot` | Graphviz dependency graph |
| `OVERVIEW.md` | Narrative architecture overview with language breakdown, core modules, key types, public API, and warnings |

## CLI Reference

```
zig-lens <path> [options]

  <path>                File or directory to analyze

Options:
  --format <fmt>        Output format: terminal (default), json, markdown, dot
  --compact             Compact JSON optimized for AI context windows
  --compile             Compile entire codebase into single MD file for AI
  --report <dir>        Generate all reports into directory
  --imports             Import/dependency analysis only
  --unsafe              Unsafe operations audit
  --output <file>       Write output to file instead of stdout
  --help, -h            Show this help
```

## What It Analyzes

### Per-file metrics
- Lines of code, blank lines, comment lines
- File size in bytes
- Language detection

### Structural analysis
- **Functions** — name, line, body length, parameters, return type, visibility (`pub`), `extern`/`export`, doc comments
- **Structs** — name, field count, method count, kind (struct, packed, extern, trait, impl, interface, class, type alias), doc comments
- **Enums** — name, variant count, tag type, method count, doc comments
- **Unions** — name, field count, tag type, method count, doc comments
- **Constants** — name, type, visibility, doc comments
- **Tests** — name and line number

### Import/dependency analysis
- Import path, classification (standard library, local, external package), binding name
- Dependency graph construction from local imports
- Hub detection (files imported by 3+ others)
- Orphan detection (files not imported by anything)
- Cycle detection (Tarjan's strongly connected components)

### Unsafe operations audit
- **Zig:** `@ptrCast`, `@intFromPtr`, `@ptrFromInt`, `@alignCast`, `@bitCast`, `@intCast`, `@truncate`, `@setRuntimeSafety`, `asm`, `@cImport`/`@cInclude`
- **Rust:** `unsafe fn`, `unsafe impl`, `unsafe {}` blocks
- **C:** `malloc`/`free`, `strcpy`/`strcat`/`sprintf` (buffer overflow risk), `gets` (critical), void pointer casts
- **Python:** `eval`, `exec`, `os.system`, `pickle.load`, `shell=True`
- **JS/TS:** `eval`, `new Function`, `innerHTML`, `dangerouslySetInnerHTML`, `document.write`

Each operation is tagged with a risk level: low, medium, high, or critical.

### Pattern detection (Zig)
- Allocator parameter usage
- `std.Io` parameter usage
- Packed/extern struct detection
- SIMD usage (`@Vector`, `@shuffle`, `@reduce`)
- Silent error swallowing (`catch {}`)

### Quality signals
- Doc comment coverage (% of public declarations with `///` or equivalent)
- Test density (tests per function ratio)
- TODO/FIXME/HACK marker counts
- `catch {}` (silent error discard) detection

### Complexity metrics (Zig)
- Cyclomatic complexity per function (`if`, `switch`, `while`, `for`, `catch`, `orelse`, `try`, `and`/`or`)
- Function body length
- Parameter count

## Architecture

```
src/
├── main.zig                 CLI entry point, argument parsing, output dispatch
├── scanner.zig              File discovery — directory walking, language detection, skip lists
├── parser.zig               Zig AST wrapper — std.zig.Ast.parse(), helpers for names/imports/docs/lines
├── models.zig               Shared data types — FileReport, ProjectReport, FunctionInfo, StructInfo, etc.
├── analyzers/
│   ├── structure.zig        Zig AST analysis — functions, structs, enums, unions, constants, tests
│   ├── imports.zig          Zig @import graph — path extraction, stdlib/local/package classification
│   ├── unsafe_ops.zig       Zig unsafe builtin detection with risk levels
│   ├── rust.zig             Rust line-based analyzer
│   ├── c_lang.zig           C line-based analyzer
│   ├── python.zig           Python indent-aware analyzer
│   ├── javascript.zig       JS/TS/Svelte line-based analyzer
│   ├── complexity.zig       Cyclomatic complexity via AST traversal
│   ├── patterns.zig         Allocator/Io/SIMD/packed struct/catch {} detection
│   └── quality.zig          Doc coverage, test density, TODO/FIXME/HACK markers
├── graph/
│   ├── builder.zig          Dependency graph construction — nodes, edges, fan-in/fan-out, hubs, orphans
│   ├── dot.zig              Graphviz DOT export with directory clusters and role-based coloring
│   └── cycles.zig           Tarjan's SCC algorithm for cycle detection
└── output/
    ├── terminal.zig         Colored terminal summary with file rankings and hotspots
    ├── json.zig             JSON export — full and compact modes, custom writer with proper escaping
    ├── markdown.zig         Markdown report with Mermaid dependency diagrams
    ├── report.zig           Multi-format report generator (all outputs into a directory)
    └── compile.zig          Codebase compiler — directory tree + all file contents in one Markdown doc
```

## Design Principles

- **Compiler-grade parsing for Zig.** Uses `std.zig.Ast.parse()` — the same parser the Zig compiler uses. No regex hacks, no custom tokenizers.
- **Graceful degradation.** Bad file? Report it, skip it, continue. One parse error never aborts the scan.
- **Zero external dependencies.** Pure Zig, builds with `zig build` and nothing else.
- **Deterministic output.** Same input always produces identical output. Files are sorted, no hash map iteration order leaks.
- **JSON is source of truth.** All output formats derive from the same analysis data. Analyze once, render many ways.
- **Context-window aware.** `--compact` mode minimizes JSON size while maximizing structural insight for AI agents.

## Building

Requires Zig 0.16.0-dev or later.

```bash
zig build
```

The binary is output to `zig-out/bin/zig-lens`.

## Running Tests

```bash
zig build test
```

## License

Part of the Quantum Zig Forge monorepo by Quantum Encoding.
