# Zig Bug Report: translate-c failure with glibc 2.42 on __builtin_va_arg_pack

## Summary

Zig's `translate-c` fails to import standard C headers (fcntl.h) when using glibc 2.42, specifically failing on `__builtin_va_arg_pack` and `__builtin_va_arg_pack_len` builtins.

## Environment

- **Zig Version:** `0.16.0-dev.604+e932ab003`
- **OS:** Arch Linux
- **Kernel:** `6.16.10-arch1-1`
- **glibc:** `2.42+r17+gd7274d718e6f-1`
- **Target:** `x86_64-linux-gnu`

## Reproduction

### Minimal build.zig
```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const lib_module = b.createModule(.{
        .root_source_file = .{ .cwd_relative = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });

    const lib = b.addLibrary(.{
        .name = "test",
        .root_module = lib_module,
        .linkage = .dynamic,
    });
    lib.linkLibC();
    b.installArtifact(lib);
}
```

### Minimal src/main.zig
```zig
const c = @cImport({
    @cInclude("fcntl.h");
    @cInclude("unistd.h");
});

export fn open(pathname: [*:0]const u8, flags: c_int, ...) c_int {
    _ = pathname;
    _ = flags;
    return -1;
}
```

### Build command
```bash
zig build -Doptimize=ReleaseSafe
```

## Error Output

```
error: /usr/include/bits/fcntl2.h:45:7: error: use of unknown builtin '__builtin_va_arg_pack_len' [-Wimplicit-function-declaration]
  if (__va_arg_pack_len () > 1)
      ^
/usr/include/sys/cdefs.h:639:30: note: expanded from here
# define __va_arg_pack_len() __builtin_va_arg_pack_len ()
                             ^

error: /usr/include/bits/fcntl2.h:55:45: error: use of unknown builtin '__builtin_va_arg_pack' [-Wimplicit-function-declaration]
      return __open_alias (__path, __oflag, __va_arg_pack ());
                                            ^
/usr/include/sys/cdefs.h:638:26: note: expanded from here
# define __va_arg_pack() __builtin_va_arg_pack ()
                         ^

error: /usr/include/bits/fcntl2.h:46:5: error: call to '__error__' declared with attribute error: open can be called either with 2 or 3 arguments, not more
    __open_too_many_args ();
    ^

error: /usr/include/bits/fcntl2.h:52:4: error: call to '__error__' declared with attribute error: open with O_CREAT or O_TMPFILE in second argument needs 3 arguments
      __open_missing_mode ();
   ^
```

## Analysis

The issue occurs in glibc's fortified headers (`bits/fcntl2.h`), which use GCC-specific builtins:
- `__builtin_va_arg_pack()` - GCC builtin to pass variadic args
- `__builtin_va_arg_pack_len()` - GCC builtin to get variadic arg count

These builtins are used in glibc's compile-time safety checks for functions like `open()` and `openat()`.

## Expected Behavior

Zig's translate-c should either:
1. Recognize and handle these GCC builtins, OR
2. Gracefully skip the fortified header paths, OR
3. Provide a `-D_FORTIFY_SOURCE=0` escape hatch

## Actual Behavior

translate-c fails with "use of unknown builtin" errors, making it impossible to import standard C headers when linking against glibc 2.42.

## Impact

This blocks any Zig project that:
- Uses `@cImport` with standard headers (fcntl.h, stdio.h, etc.)
- Links against glibc 2.42+
- Tries to build LD_PRELOAD libraries or syscall interceptors

## Workarounds

### Option 1: Use ReleaseFast Instead of ReleaseSafe (RECOMMENDED)

Build with `-Doptimize=ReleaseFast` instead of `-Doptimize=ReleaseSafe`. This avoids the issue entirely because `ReleaseFast` doesn't add `-D_FORTIFY_SOURCE=2`.

```bash
zig build -Doptimize=ReleaseFast
```

**Why this works:** The `_FORTIFY_SOURCE` macro is only added for `ReleaseSafe` builds (see `src/Compilation.zig:6810`). `ReleaseFast` produces smaller, faster binaries without the problematic fortified headers.

### Option 2: Patch the Zig Compiler

Modify `/usr/local/zig/lib/std/Build/Step/Compile.zig` or the source file that adds `-D_FORTIFY_SOURCE=2` to comment out that line. This requires rebuilding the Zig compiler itself.

### Option 3: Downgrade glibc

Not practical for most users.

## Context

This issue affected Guardian Shield, a security project that intercepts filesystem syscalls via LD_PRELOAD. The issue is **RESOLVED** by using `ReleaseFast` optimization mode instead of `ReleaseSafe`.

However, this remains a genuine bug in Zig's translate-c engine that should be fixed upstream for projects that specifically require `ReleaseSafe` builds.

## Related Issues

- Possibly related to changes in translate-c between 0.13 and 0.16
- May be specific to glibc 2.42's changes in fortified headers
- Similar to historic issues with `__attribute__` handling

## Reproduction Repository

[Will provide if needed - minimal test case above should suffice]

---

**Is this a known issue?** Should I downgrade Zig or is there a fix in progress?
