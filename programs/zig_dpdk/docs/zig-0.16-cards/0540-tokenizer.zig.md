# Migration Card: Zig Tokenizer

## 1) Concept

This file implements a Zig language tokenizer that lexes Zig source code into tokens. The main components are:

- **Token struct**: Represents a lexical token with a tag (type) and location (start/end indices). Contains a comprehensive enum of all Zig token types including keywords, operators, literals, and punctuation.

- **Tokenizer struct**: A state machine that processes source code character-by-character to produce tokens. It handles all Zig lexical constructs including identifiers, literals, comments, operators, and handles error recovery by returning invalid tokens and resetting on newlines.

## 2) The 0.11 vs 0.16 Diff

**No significant API changes detected** for migration from 0.11 to 0.16. The tokenizer maintains the same simple, allocation-free interface:

- **No explicit allocator requirements**: The tokenizer works entirely with input buffers and doesn't require memory allocation
- **No I/O interface changes**: Operates purely on in-memory `[:0]const u8` buffers
- **No error handling changes**: Uses simple return types without error unions
- **API structure unchanged**: Simple `init()` + `next()` pattern remains consistent

Key public APIs:
- `Tokenizer.init(buffer: [:0]const u8) Tokenizer` - Factory function
- `Tokenizer.next(self: *Tokenizer) Token` - Stateful token production
- `Token.getKeyword(bytes: []const u8) ?Tag` - Static keyword lookup

## 3) The Golden Snippet

```zig
const std = @import("std");
const tokenizer = std.zig.tokenizer;

// Tokenize Zig source code
var source = "const foo = 42; // comment\n".*;
var tok = tokenizer.Tokenizer.init(&source);

while (true) {
    const token = tok.next();
    switch (token.tag) {
        .eof => break,
        .invalid => std.debug.print("Invalid token at {d}-{d}\n", .{token.loc.start, token.loc.end}),
        else => std.debug.print("{s}: '{s}'\n", .{
            @tagName(token.tag),
            source[token.loc.start..token.loc.end]
        }),
    }
}
```

## 4) Dependencies

- `std` - Primary standard library import
- `std.StaticStringMap` - Used for keyword lookup table
- `std.mem` - Used for BOM detection (`std.mem.startsWith`)
- `std.debug` - Used in test and debugging functions

**Note**: This is a stable, mature component with minimal dependencies and no breaking changes in the 0.16 migration.