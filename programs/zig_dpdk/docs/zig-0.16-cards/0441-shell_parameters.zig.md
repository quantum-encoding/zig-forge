# Migration Card: std/os/uefi/protocol/shell_parameters.zig

## 1) Concept

This file defines the UEFI Shell Parameters Protocol structure, which provides access to command-line parameters and standard I/O handles for UEFI applications running in a shell environment. The `ShellParameters` struct contains the command-line arguments array (`argv`) with argument count (`argc`), plus standard input, output, and error file handles that mimic traditional console I/O in a UEFI environment.

The protocol is identified by a specific GUID that allows UEFI applications to locate and use the shell parameters interface. This is part of Zig's UEFI standard library support, enabling UEFI application development with proper shell integration.

## 2) The 0.11 vs 0.16 Diff

**No public function signature changes detected.** This file contains only a struct definition with fields and a constant GUID declaration. The migration patterns analyzed:

- **No explicit allocator requirements**: The struct is a simple extern struct with no initialization functions
- **No I/O interface changes**: The file handles are direct fields, not interface-based
- **No error handling changes**: No functions are defined that could have error returns
- **No API structure changes**: No `init`/`open` patterns present

The struct fields remain compatible:
- `argv`: Pointer to null-terminated UTF-16 string arguments
- `argc`: Count of arguments  
- `stdin`, `stdout`, `stderr`: Standard UEFI file handles

## 3) The Golden Snippet

```zig
const std = @import("std");
const ShellParameters = std.os.uefi.protocol.ShellParameters;

// In a UEFI application, typically obtained via:
// const shell_params = system_table.boot_services.locateProtocol(&ShellParameters.guid);

fn print_args(shell_params: *ShellParameters) void {
    std.debug.print("Argument count: {}\n", .{shell_params.argc});
    
    var i: usize = 0;
    while (i < shell_params.argc) : (i += 1) {
        const arg = shell_params.argv[i];
        // Convert UTF-16 to UTF-8 for printing
        std.debug.print("Arg {}: {s}\n", .{i, arg});
    }
}
```

## 4) Dependencies

- `std.os.uefi` (primary UEFI framework)
- `std.os.uefi.Guid` (GUID handling)
- `std.os.uefi.FileHandle` (UEFI file handle type)

**Note**: This is a protocol definition file that would be used alongside other UEFI services and protocols in a complete UEFI application.