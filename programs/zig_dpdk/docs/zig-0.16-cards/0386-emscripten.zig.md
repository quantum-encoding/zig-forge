# Migration Card: `std/os/emscripten.zig`

## 1) Concept

This file provides Emscripten-specific OS bindings and system call interfaces for Zig programs targeting WebAssembly in browser environments. It serves as the primary interface between Zig code and the Emscripten runtime, exposing JavaScript-specific functionality like async file operations, main loop management, Web Workers, and browser APIs alongside POSIX-like system calls adapted for the web platform.

Key components include:
- Emscripten-specific async operations (wget, IDB, workers)
- Main loop and timing control functions
- Browser integration APIs (canvas, window, device pixel ratio)
- POSIX-compatible system call definitions adapted for Emscripten
- Error code mappings from WASI to Emscripten

## 2) The 0.11 vs 0.16 Diff

This file primarily contains C-style extern function declarations and constant definitions rather than Zig-style public APIs with allocator patterns. However, notable differences from traditional Zig 0.11 patterns include:

**C-Style Function Signatures**: All public functions use C calling convention and C-style parameter types:
```zig
pub extern "c" fn emscripten_set_main_loop(
    func: em_callback_func, 
    fps: c_int, 
    simulate_infinite_loop: c_int
) void;
```

**Opaque Pointer Types**: Uses `?*anyopaque` instead of `?*c_void` or specific pointer types:
```zig
pub const em_arg_callback_func = ?*const fn (?*anyopaque) callconv(.c) void;
```

**Error Handling**: Functions return C-style error codes rather than Zig error unions:
```zig
pub extern "c" fn emscripten_wget(url: [*:0]const u8, file: [*:0]const u8) c_int;
```

**No Allocator Patterns**: Unlike Zig 0.16 patterns, these C bindings don't require explicit allocators - memory management follows C conventions.

## 3) The Golden Snippet

```zig
const std = @import("std");
const emscripten = std.os.emscripten;

var counter: i32 = 0;

fn mainLoop() callconv(.c) void {
    counter += 1;
    if (counter >= 60) {
        emscripten.emscripten_cancel_main_loop();
    }
}

pub fn main() void {
    // Set up Emscripten main loop running at 60fps
    emscripten.emscripten_set_main_loop(mainLoop, 60, 1);
}
```

## 4) Dependencies

- `std.c` - C standard library bindings
- `std.os.wasi` - WASI error code mappings
- `std.os.linux` - Linux/POSIX constant definitions
- `std.posix` - POSIX I/O vector and timing constants
- `std.elf` - ELF header definitions for dynamic linking
- `std.mem` - Memory utilities (implicitly through other imports)
- `std.math` - Math utilities for bit operations

*Note: This file contains C-style bindings rather than idiomatic Zig 0.16 APIs. Migration primarily involves adapting to the C calling conventions and pointer types rather than Zig-specific patterns.*