# Adding Programs to Quantum Zig Forge

Quick guide for adding new programs to the monorepo.

## Steps

### 1. Add Program Directory

Copy or create your program in `programs/`:

```bash
cp -r /path/to/your-program programs/your_program_name
# OR
mkdir -p programs/your_program_name
```

**Naming:** Use `snake_case` for directory names (e.g., `http_sentinel`, `guardian_shield`)

### 2. Ensure build.zig Exists

Your program must have its own `build.zig` in `programs/your_program_name/build.zig`

### 3. Update Root build.zig

Edit `/home/founder/github_public/quantum-zig-forge/build.zig`:

```zig
// In the build() function, add your program:
buildProgram(b, "your_program_name", target, optimize, build_all);

// And add tests:
testProgram(b, "your_program_name", test_all);
```

Example:
```zig
// Programs
buildProgram(b, "http_sentinel", target, optimize, build_all);
buildProgram(b, "guardian_shield", target, optimize, build_all);
buildProgram(b, "your_program_name", target, optimize, build_all);  // ADD THIS

// Test all programs
const test_all = b.step("test", "Run all tests in the monorepo");
testProgram(b, "http_sentinel", test_all);
testProgram(b, "guardian_shield", test_all);
testProgram(b, "your_program_name", test_all);  // ADD THIS
```

### 4. Update Root README.md

Add your program to the "Programs" section in `README.md`:

```markdown
### your_program_name

Brief description of what your program does.

**Features:**
- Feature 1
- Feature 2
- Feature 3

**Documentation:** [programs/your_program_name/README.md](programs/your_program_name/README.md)

**Binaries:**
- `binary-name` - Description
```

### 5. Test Build

```bash
# From monorepo root
zig build your_program_name

# Check binaries appeared
ls -lh zig-out/bin/
```

### 6. Build Everything

```bash
zig build all
```

## Example: Adding a New Program

```bash
# 1. Copy program
cp -r /path/to/cool-tool programs/cool_tool

# 2. Edit root build.zig
# Add: buildProgram(b, "cool_tool", target, optimize, build_all);
# Add: testProgram(b, "cool_tool", test_all);

# 3. Update README.md with program info

# 4. Build and test
zig build cool_tool
zig build test

# 5. Build everything
zig build all
```

## Verification

After adding your program:

1. Binaries appear in `zig-out/bin/`
2. Libraries (if any) appear in `zig-out/lib/`
3. `zig build your_program_name` works
4. `zig build test` runs your tests
5. `zig build all` includes your program

## Notes

- Each program remains independent with its own build.zig
- Programs can be built standalone: `cd programs/your_program && zig build`
- Root build system collects all outputs to central `zig-out/`
- Use `--prefix ../../zig-out` in buildProgram() to direct output to root
