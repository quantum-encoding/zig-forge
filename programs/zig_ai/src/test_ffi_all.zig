// Copyright (c) 2025 QUANTUM ENCODING LTD
// Licensed under the MIT License.

//! Test root for `zig build test-ffi`.
//!
//! The FFI tests must be rooted at a file in `src/`, not at `src/ffi/mod.zig`
//! itself. A module's root source file fixes the module path, and every file
//! under `src/ffi/` reaches its implementation with `@import("../…")` —
//! rooting at `src/ffi/mod.zig` puts those paths outside the module and the
//! test binary fails to compile before a single test runs.
//!
//! Only `ffi/mod.zig` is imported here: `src/lib.zig` and `src/ffi/lib.zig`
//! define the same `export fn zig_ai_*` symbols, so pulling in a second one
//! collides at link time. `src/test_all.zig` excludes all three for the same
//! reason and owns the non-FFI tests.

const std = @import("std");

const ffi_mod = @import("ffi/mod.zig");

test {
    std.testing.refAllDecls(ffi_mod);
}
