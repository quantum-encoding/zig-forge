# Migration Card: P-384 Field Element Type

## 1) Concept

This file defines the finite field arithmetic type for the P-384 elliptic curve. It creates a specialized field element type `Fe` using a generic field construction system. The configuration specifies P-384's specific cryptographic parameters including the field order (a 384-bit prime), bit sizes, and encoding length, while delegating the actual arithmetic operations to a formally verified FIAT backend implementation (`p384_64.zig`).

The key component is the `Fe` type which represents elements in the P-384 prime field and will be used for all elliptic curve operations on this curve. This is a foundational building block for P-384 cryptographic operations.

## 2) The 0.11 vs 0.16 Diff

**No public function signature changes detected** - this file only exports a type definition.

The migration pattern here is purely structural:
- **Type-based API**: Instead of exposing standalone functions, the API is encapsulated in the `Fe` type returned by `Field()`
- **Compile-time configuration**: The field parameters are passed as a struct literal at compile time
- **Backend abstraction**: The actual arithmetic is handled by the FIAT backend through dependency injection

The `Fe` type follows Zig 0.16's pattern of type-safe, compile-time configured cryptographic primitives rather than runtime-configured objects.

## 3) The Golden Snippet

```zig
const std = @import("std");
const p384_field = @import("std/crypto/pcurves/p384/field.zig");

// The Fe type represents a P-384 field element
const Fe = p384_field.Fe;

// Field elements are used for elliptic curve operations
// (Actual usage would involve the methods provided by the Fe type)
```

## 4) Dependencies

- `std` - Standard library base
- `../common.zig` - Common field arithmetic infrastructure
- `p384_64.zig` - FIAT-backed 64-bit P-384 arithmetic implementation

**Note**: This is a type definition file - the actual dependencies are inherited from the common field implementation and used through the configured `Fe` type.