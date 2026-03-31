# Cross-Platform RNG Integration Handoff

## Overview

The `src/rng.zig` module provides cross-platform cryptographic random number generation. This document explains how to integrate it into the existing codebase.

## Files to Modify

### 1. `src/ml_kem_api.zig`

**Find and replace the libc import and usage:**

```zig
// REMOVE THIS:
const libc = @cImport({
    @cInclude("stdlib.h");
});

// ADD THIS:
const rng = @import("rng.zig");
```

**Then replace all calls:**
```zig
// REPLACE:
libc.arc4random_buf(&seed, seed.len);

// WITH:
rng.fillSecureRandom(&seed);
```

---

### 2. `src/ml_dsa_v2.zig`

**Find and remove the existing wrapper (around line 12-20):**

```zig
// REMOVE THIS ENTIRE BLOCK:
// Zig 0.16: Use libc for random bytes (std.crypto.random removed)
const libc = @cImport({
    @cInclude("stdlib.h");
});

fn getRandomBytes(buf: []u8) void {
    libc.arc4random_buf(buf.ptr, buf.len);
}
```

**Replace with:**
```zig
const rng = @import("rng.zig");
const getRandomBytes = rng.fillSecureRandom;
```

---

### 3. `src/hybrid.zig`

**Find (around line 63):**
```zig
const libc = @cImport({
    @cInclude("stdlib.h");
});
```

**Replace with:**
```zig
const rng = @import("rng.zig");
```

**Then in the `keyGen` function, replace:**
```zig
libc.arc4random_buf(&seed, seed.len);
```

**With:**
```zig
rng.fillSecureRandom(&seed);
```

---

### 4. `src/quantum_vault_ffi.zig`

The FFI module imports the other modules, so it should automatically use the new RNG after the above changes. However, if there are any direct `arc4random_buf` calls, replace them similarly.

---

### 5. `build.zig` - Enable All Cross-Compilation Targets

**Remove the macOS-only restriction. Change:**

```zig
// For now, cross-compilation only works for macOS targets
// (arc4random_buf is BSD/macOS specific)
inline for ([_]CrossTarget{
    .{ .name = "macos-arm64", .query = .{ .cpu_arch = .aarch64, .os_tag = .macos } },
    .{ .name = "macos-x86_64", .query = .{ .cpu_arch = .x86_64, .os_tag = .macos } },
}) |ct| {
```

**To:**

```zig
inline for (cross_targets) |ct| {
```

**And remove the `_ = cross_targets;` line.**

**For Windows builds, add bcrypt linking. Inside the cross-compilation loop, after creating the library:**

```zig
const cross_lib = b.addLibrary(.{
    .linkage = .static,
    .name = "quantum_vault_" ++ ct.name,
    .root_module = cross_mod,
});

// Link bcrypt on Windows for BCryptGenRandom
if (ct.query.os_tag == .windows) {
    cross_lib.linkSystemLibrary("bcrypt");
}

b.installArtifact(cross_lib);
cross_step.dependOn(&cross_lib.step);
```

**Also update the native FFI library to link bcrypt on Windows:**

```zig
const ffi_static_lib = b.addLibrary(.{
    .linkage = .static,
    .name = "quantum_vault",
    .root_module = ffi_lib_mod,
});

// Link bcrypt on Windows
if (target.result.os.tag == .windows) {
    ffi_static_lib.linkSystemLibrary("bcrypt");
}

b.installArtifact(ffi_static_lib);
```

---

## Verification Steps

After making these changes:

1. **Build and test on native platform:**
   ```bash
   rm -rf .zig-cache
   zig build test
   ```

2. **Test cross-compilation:**
   ```bash
   zig build cross
   ls -la zig-out/lib/
   ```

   Expected output (all platforms):
   ```
   libquantum_vault_macos-arm64.a
   libquantum_vault_macos-x86_64.a
   libquantum_vault_linux-x86_64.a
   quantum_vault_windows-x86_64.lib
   libquantum_vault_ios-arm64.a
   libquantum_vault_android-arm64.a
   libquantum_vault_android-arm32.a
   ```

3. **Generate C header:**
   ```bash
   zig build gen-header
   cat include/quantum_vault.h
   ```

---

## RNG API Reference

```zig
const rng = @import("rng.zig");

// Primary API - panics on failure (recommended)
rng.fillSecureRandom(buf: []u8) void

// Safe API - returns errors
rng.fillSecureRandomSafe(buf: []u8) RngError!void

// Error types
const RngError = error{
    SystemRngFailed,
    InsufficientEntropy,
    UnsupportedPlatform,
};
```

---

## Platform Details

| Platform | Implementation | Notes |
|----------|---------------|-------|
| macOS | `arc4random_buf` | Always available, auto-seeded |
| iOS | `arc4random_buf` | Same as macOS |
| Linux | `getrandom(2)` syscall | Kernel 3.17+ (2014) |
| Android | `getrandom(2)` syscall | Works on all modern versions |
| Windows | `BCryptGenRandom` | Vista+ (CNG API) |
| FreeBSD/OpenBSD | `arc4random_buf` | BSD heritage |

---

## Security Notes

1. **No manual seeding** - All platforms auto-seed from system entropy
2. **Blocking behavior** - Linux `getrandom` blocks until entropy pool ready (boot time only)
3. **FIPS compliance** - Windows CNG is FIPS 140-2 certified when enabled
4. **Thread safety** - All implementations are thread-safe
