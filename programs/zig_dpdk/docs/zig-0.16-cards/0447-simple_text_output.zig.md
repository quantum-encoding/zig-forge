# Migration Card: std/os/uefi/protocol/simple_text_output.zig

## 1) Concept

This file defines the UEFI Simple Text Output Protocol, which provides a standardized interface for text-based output in UEFI (Unified Extensible Firmware Interface) environments. The protocol enables basic console operations like writing strings, controlling cursor position, clearing the screen, and managing text attributes (colors). It's essentially the UEFI equivalent of a console/text output driver.

Key components include the main `SimpleTextOutput` extern struct that wraps UEFI function pointers, error sets for each operation, attribute definitions for text colors, mode information structures, and geometry data for screen dimensions. The protocol uses UTF-16 strings and provides constants for box-drawing characters and geometric shapes commonly used in UEFI interfaces.

## 2) The 0.11 vs 0.16 Diff

**No Breaking Changes Detected in Public API**

This file represents a UEFI protocol binding with the following characteristics:

- **No Allocator Requirements**: All operations are direct UEFI system calls without memory allocation
- **Direct UEFI Binding**: Functions wrap existing UEFI protocol function pointers with Zig error handling
- **Error Handling Pattern**: Each function returns specific error sets combining `uefi.UnexpectedError` with protocol-specific errors
- **API Structure**: Consistent wrapper pattern around UEFI function pointers with proper error translation

The migration pattern here is primarily about error handling translation from raw UEFI status codes to Zig error sets, which appears consistent with Zig's error handling evolution.

## 3) The Golden Snippet

```zig
const std = @import("std");
const SimpleTextOutput = std.os.uefi.protocol.SimpleTextOutput;

// Assuming we have a SimpleTextOutput protocol instance
fn exampleUsage(stdout: *SimpleTextOutput) void {
    // Clear the screen
    stdout.clearScreen() catch |err| {
        // Handle clear screen error
        return;
    };

    // Set text attribute (white on black)
    const attr = SimpleTextOutput.Attribute{
        .foreground = .white,
        .background = .black,
    };
    stdout.setAttribute(attr) catch |err| {
        // Handle attribute error
        return;
    };

    // Output a string (UTF-16 null-terminated)
    const message = "Hello, UEFI!\x00";
    const wide_msg = std.unicode.utf8ToUtf16LeStringLiteral(message);
    const success = stdout.outputString(wide_msg) catch |err| {
        // Handle output error
        return;
    };

    // Move cursor to position (5, 10)
    stdout.setCursorPosition(5, 10) catch |err| {
        // Handle cursor error
        return;
    };
}
```

## 4) Dependencies

- **std.os.uefi** - Core UEFI types and utilities
- **std.os.uefi.Guid** - Protocol identifier
- **std.os.uefi.Status** - UEFI status codes
- **std.os.uefi.cc** - UEFI calling convention

This is a leaf node in the dependency graph with minimal external dependencies beyond the core UEFI infrastructure.