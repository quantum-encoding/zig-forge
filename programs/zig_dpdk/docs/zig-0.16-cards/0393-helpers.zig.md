# Migration Card: `std/os/linux/bpf/helpers.zig`

## 1) Concept

This file provides Zig bindings for Linux BPF (Berkeley Packet Filter) helper functions. It serves as a low-level interface to the BPF subsystem in the Linux kernel, exposing eBPF helper functions that can be called from BPF programs. The file contains function pointer declarations for all BPF helpers, each assigned a specific numeric identifier that corresponds to the kernel's internal helper ID system.

Key components include:
- Function pointers for BPF map operations (lookup, update, delete)
- Network packet manipulation functions
- System introspection helpers (process info, timestamps, etc.)
- Socket and connection management functions
- Memory access and probing operations

## 2) The 0.11 vs 0.16 Diff

This file represents a **stable BPF interface** rather than a Zig API migration. The patterns here are consistent with low-level kernel interfaces:

- **No explicit allocators**: BPF helpers manage memory internally or work with pre-allocated kernel structures
- **Direct function pointers**: Using `@ptrFromInt()` to create function pointers from fixed numeric IDs
- **Error handling via return codes**: All functions return `c_long` or similar types with error codes
- **Kernel types**: Heavy use of kernel-specific types from `kern.zig` rather than Zig standard types

The signature pattern is consistent throughout:
```zig
pub const helper_name: *align(1) const fn(parameters) ReturnType = @ptrFromInt(helper_id);
```

## 3) The Golden Snippet

```zig
const helpers = @import("std").os.linux.bpf.helpers;

// Example: Look up an element in a BPF map
pub fn lookup_map_value(map: *const kern.MapDef, key: *const u32) ?*u32 {
    return @ptrCast(helpers.map_lookup_elem(map, @ptrCast(key)));
}

// Example: Get current timestamp
pub fn get_current_time() u64 {
    return helpers.ktime_get_ns();
}

// Example: Get random number for BPF program
pub fn get_random() u32 {
    return helpers.get_prandom_u32();
}
```

## 4) Dependencies

**Primary Dependencies:**
- `std` (via `../../../std.zig`)
- `kern.zig` (local module providing kernel type definitions)

**Kernel Type Dependencies:**
- `kern.MapDef`, `kern.SkBuff`, `kern.Sock`, `kern.XdpMd`
- `kern.SockOps`, `kern.SkMsgMd`, `kern.TcpSock`
- Various other kernel structure definitions from `kern.zig`

**Note:** This file contains compile-time errors for missing types (`PtRegs`, `TcpHdr`, `SkFullSock`) indicating incomplete OS-specific implementations.