# Migration Card: Windows Sublanguage Constants

## 1) Concept

This file contains Windows sublanguage ID constants used for locale and language identification in the Windows operating system. These are hexadecimal values that represent different language and regional combinations, following Microsoft's Language Identifier (LCID) format where the sublanguage is the high word of the locale identifier.

The file provides a comprehensive collection of constants for internationalization support, covering everything from common languages (English, Spanish, Chinese) to regional variants (e.g., `ENGLISH_US`, `ENGLISH_UK`) and specialized cases like `NEUTRAL`, `DEFAULT`, and `SYS_DEFAULT`. Each constant represents a specific language-region combination used by Windows APIs for locale-sensitive operations.

## 2) The 0.11 vs 0.16 Diff

**No Migration Changes Required**

This file contains only constant declarations with no function signatures, struct definitions, or public APIs that would be affected by Zig 0.11 to 0.16 migration patterns. The constants are simple integer literals that remain compatible across Zig versions.

Key observations:
- No allocator requirements (only constants)
- No I/O interface changes
- No error handling patterns
- No API structure changes
- No function signatures to migrate

## 3) The Golden Snippet

```zig
const std = @import("std");
const sublang = std.os.windows.sublang;

// Example usage of Windows sublanguage constants
pub fn main() void {
    const user_lang = sublang.ENGLISH_US;
    const system_lang = sublang.SYS_DEFAULT;
    
    std.debug.print("User language: 0x{x}\n", .{user_lang});
    std.debug.print("System default: 0x{x}\n", .{system_lang});
    
    // Check for specific language variants
    if (user_lang == sublang.CHINESE_TRADITIONAL) {
        std.debug.print("Using Traditional Chinese\n", .{});
    }
}
```

## 4) Dependencies

This file has no imports or dependencies - it's a self-contained collection of constants. However, it's typically used in conjunction with:

- `std.os.windows` - Windows-specific OS APIs
- Windows locale and internationalization functions
- System configuration and regional settings APIs

The constants are designed to be used with Windows API functions that require language and locale identifiers, such as those in the Windows NLS (National Language Support) APIs.