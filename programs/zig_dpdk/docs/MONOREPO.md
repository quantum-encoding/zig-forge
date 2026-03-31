# Quantum Zig Forge Monorepo Guide

## Structure

```
quantum-zig-forge/
├── build.zig              # Root build orchestrator
├── programs/              # Individual programs
│   └── http_sentinel/     # Each program has own build.zig
├── libs/                  # Shared libraries
├── docs/                  # Documentation
├── tests/                 # Integration tests
├── scripts/               # Build and utility scripts
└── zig-out/              # Centralized build output (ROOT)
    └── bin/              # All binaries collected here
```

## Building

### Build Everything
```bash
zig build
# OR
zig build all
```

All binaries are placed in `zig-out/bin/` at the repository root.

### Build Specific Program
```bash
zig build http_sentinel
```

### Run Tests
```bash
zig build test
```

### Clean
```bash
zig build clean
```

## How It Works

1. Root `build.zig` orchestrates all program builds
2. Each program in `programs/` has its own `build.zig`
3. Root build system uses `--prefix ../../zig-out` to collect all binaries
4. Each program can be built independently: `cd programs/http_sentinel && zig build`

## Adding New Programs

1. Create directory: `programs/your_program/`
2. Add `build.zig` and source code
3. Update root `build.zig`:
   ```zig
   buildProgram(b, "your_program", target, optimize, build_all);
   testProgram(b, "your_program", test_all);
   ```
4. Update root `README.md`

## Program Independence

Each program:
- Has its own build configuration
- Can be built standalone
- Maintains its own dependencies
- Has its own tests and examples
- Outputs to root `zig-out/` when built from root
- Outputs to local `zig-out/` when built standalone

## Benefits

- Single `zig-out/bin/` directory for all binaries
- Easy to find and run any program
- Programs remain independent
- Simple to add new programs
- Can build programs individually or all at once
