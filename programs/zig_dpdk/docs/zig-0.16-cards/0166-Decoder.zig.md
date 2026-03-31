# Migration Card: std/crypto/codecs/asn1/der/Decoder.zig

## 1) Concept

This file implements a secure DER (Distinguished Encoding Rules) parser for ASN.1 (Abstract Syntax Notation One) data formats. It provides a non-allocating decoder that strictly validates DER encoding rules, including checking for minimal length representations and valid boolean values. The decoder operates on a byte slice without reading outside its bounds and returns slices that remain within the input buffer.

Key components include:
- `Decoder` struct containing the input bytes, current parsing index, and field tag tracking
- Main decoding method `any()` that handles various ASN.1 types through compile-time type reflection
- Helper methods for sequence parsing (`sequence()`), element extraction (`element()`), and byte viewing (`view()`)
- Strict validation of DER encoding rules including canonical integer representations

## 2) The 0.11 vs 0.16 Diff

**No Allocator Required**: This API is designed to be allocation-free. The decoder operates directly on input bytes without requiring any memory allocator, making it suitable for constrained environments.

**Type-Driven Decoding**: The primary public function `any()` uses Zig's type system to determine decoding behavior:
- Structs are decoded by recursively calling `any()` on each field
- Built-in types (bool, int, enum) have specialized decoding logic
- Optional types are handled with default value fallbacks
- Custom types can implement `decodeDer` method for custom parsing

**Error Handling**: Uses specific error sets rather than generic errors:
- `error{EndOfStream, UnexpectedElement}` in `element()`
- `error{NonCanonical, LargeValue}` in integer decoding
- `error.InvalidBool` for boolean validation

**API Structure**: Maintains consistent pattern of stateful decoder that advances through the input buffer. No factory functions or complex initialization - decoder is initialized directly with input bytes.

## 3) The Golden Snippet

```zig
const std = @import("std");
const der = std.crypto.codecs.asn1.der;

test "decode sequence with integers" {
    // DER-encoded sequence containing two integers
    const der_bytes = [_]u8{
        0x30, 0x06,        // SEQUENCE (length 6)
        0x02, 0x01, 0x01,  // INTEGER 1  
        0x02, 0x01, 0x02,  // INTEGER 2
    };
    
    var decoder = der.Decoder{ .bytes = &der_bytes };
    const seq = try decoder.sequence();
    
    const first_int = try decoder.any(u8);
    const second_int = try decoder.any(u8);
    
    try std.testing.expectEqual(@as(u8, 1), first_int);
    try std.testing.expectEqual(@as(u8, 2), second_int);
    try std.testing.expectEqual(decoder.index, seq.slice.end);
}
```

## 4) Dependencies

- **std.mem**: Used for `readVarInt` in integer decoding and compile-time reflection
- **std.meta**: Heavy usage for compile-time type inspection (`hasFn`, `fields`, `typeInfo`)
- **std.testing**: Used in test blocks for assertions
- **Local ASN.1 modules**: 
  - `../../asn1.zig` (provides Index, Tag, FieldTag, ExpectedTag, Element types)
  - `../Oid.zig` (used for object identifier parsing in enum decoding)

The decoder has minimal external dependencies and relies heavily on Zig's compile-time capabilities for type-driven parsing.