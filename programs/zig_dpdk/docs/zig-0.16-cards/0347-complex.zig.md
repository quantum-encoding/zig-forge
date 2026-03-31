# Migration Card: std/math/complex.zig

## 1) Concept

This file provides complex number functionality for Zig's standard library. It defines a generic `Complex(T)` type that represents complex numbers with real and imaginary parts, where `T` must be a floating-point type. The main component is the `Complex` struct type that provides basic arithmetic operations (addition, subtraction, multiplication, division) and mathematical operations (conjugate, negation, reciprocal, magnitude calculations).

The file also serves as a module re-exporter, importing and exporting various complex mathematical functions from submodules including trigonometric functions (sin, cos, tan), hyperbolic functions (sinh, cosh, tanh), inverse functions (asin, acos, atan), and other mathematical operations (exp, log, pow, sqrt, abs).

## 2) The 0.11 vs 0.16 Diff

**No significant breaking API changes detected in this file.** The complex number implementation follows consistent patterns:

- **Construction**: Uses `init()` factory pattern rather than direct struct initialization
- **Method-based API**: All operations are instance methods on the `Complex` type
- **Value semantics**: Operations return new `Complex` instances rather than modifying in-place
- **No allocators**: Mathematical operations are pure computations without memory allocation
- **No I/O dependencies**: The API is focused on mathematical operations only

The pattern `Complex(T).init(re, im)` for construction and method chaining like `a.add(b).mul(c)` appears to be the intended usage pattern in both versions.

## 3) The Golden Snippet

```zig
const std = @import("std");
const Complex = std.math.Complex;

// Create complex numbers
const a = Complex(f32).init(3.0, 4.0);
const b = Complex(f32).init(1.0, 2.0);

// Perform operations
const sum = a.add(b);
const product = a.mul(b);
const conjugate = a.conjugate();
const magnitude = a.magnitude();

// Use mathematical functions
const sine = std.math.complex.sin(a);
const exponential = std.math.complex.exp(b);
```

## 4) Dependencies

- `std` - Base standard library import
- `std.testing` - For test infrastructure
- `std.math` - For mathematical constants and utility functions

**Note**: This analysis is based on the main complex.zig file. The individual complex function modules (abs.zig, cos.zig, sin.zig, etc.) may contain additional implementation details and dependencies not visible in this re-export file.