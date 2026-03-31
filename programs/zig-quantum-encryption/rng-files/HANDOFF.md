# HANDOFF: Cross-Platform RNG Integration

## New File Created
`src/rng.zig` - Cross-platform cryptographic RNG

## Quick Integration

### ml_kem_api.zig
```zig
// Replace: const libc = @cImport({ @cInclude("stdlib.h"); });
// With:
const rng = @import("rng.zig");

// Replace: libc.arc4random_buf(ptr, len);
// With:    rng.fillSecureRandom(slice);
```

### ml_dsa_v2.zig  
```zig
// Delete the entire libc import and getRandomBytes wrapper
// Add:
const rng = @import("rng.zig");
const getRandomBytes = rng.fillSecureRandom;
```

### hybrid.zig
```zig
// Replace libc import with:
const rng = @import("rng.zig");

// Replace: libc.arc4random_buf(&seed, seed.len);
// With:    rng.fillSecureRandom(&seed);
```

### build.zig
1. Remove macOS-only restriction: use `cross_targets` not the hardcoded subset
2. Add for Windows targets: `cross_lib.linkSystemLibrary("bcrypt");`

## Verification
```bash
rm -rf .zig-cache && zig build test
zig build cross  # Should now work for all platforms
```

## Supported Platforms After Integration
- macOS arm64/x86_64 ✓
- Windows x86_64 ✓  
- Linux x86_64 ✓
- iOS arm64 ✓
- Android arm64/arm32 ✓
