# Zigix POSIX Shell — Design Document

See full design in the agent task output. Key architecture:

## Architecture: Pipeline
```
Source text → [Tokenizer] → [Parser] → [AST] → [Expander] → [Executor]
```

## Implementation Phases
1. Tokenizer + Parser + AST (simple commands, pipes, &&, ||)
2. Executor + Variables (fork/exec/pipe/wait)
3. Expander ($VAR, ${VAR:-default}, quoting)
4. Builtins (cd, export, test/[, set, trap)
5. Control flow (if/for/while/case)
6. Command substitution, trap, set -e
7. Glob expansion, pattern matching
8. Here-documents, subshells, brace groups
9. Kernel Makefile recipe test suite

## Memory Budget: ~620 KiB (all static, no heap)

## Build Modes
- `zig build -Dtarget=x86_64-linux-musl` — test on Linux
- Freestanding — native Zigix (sys.zig syscalls)

## Required for Linux Kernel Build
- sh -c "command" with full POSIX semantics
- Pipes, command substitution, control flow
- set -e, trap EXIT, here-documents
- All 10 kernel Makefile recipe patterns documented in full design
