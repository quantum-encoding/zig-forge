# Zig 0.16 Migration Card: std/crypto/Certificate.zig

## 1) Concept

This file implements X.509 certificate parsing and verification functionality for Zig's standard crypto library. It provides comprehensive support for parsing X.509 certificates in DER format, including handling of certificate versions, signature algorithms, public key types, extensions, and validity periods. The core components include:

- **Certificate Parsing**: Functions to parse X.509 certificates and extract key components like issuer, subject, public key, signature, and validity periods
- **Certificate Verification**: Support for verifying certificate signatures using RSA, ECDSA, and Ed25519 algorithms
- **ASN.1/DER Decoding**: Complete DER (Distinguished Encoding Rules) parser for handling the binary certificate format
- **Hostname Validation**: RFC 6125-compliant hostname verification with wildcard support

## 2) The 0.11 vs 0.16 Diff

### No Explicit Allocator Requirements
- The API is allocation-free and works entirely with provided buffers
- All parsing functions accept `Certificate` structs containing pre-allocated buffers
- No factory functions requiring allocators are present

### I/O Interface Changes
- Pure data processing API - no I/O dependency injection patterns
- All operations work on byte slices (`[]const u8`) rather than streams
- Time validation uses integer timestamps rather than real-time clock interfaces

### Error Handling Changes
- Specific, granular error types rather than generic error unions
- `VerifyError` and `ParseError` provide detailed failure reasons
- Error sets are specific to certificate validation scenarios

### API Structure Changes
- **Direct struct initialization**: `Certificate{buffer, index}` pattern
- **Parse/Verify separation**: Separate `parse()` and `verify()` functions
- **Method-based access**: Parsed certificate data accessed via methods like `issuer()`, `subject()`, etc.

Key public function signatures:
```zig
// Certificate creation (no allocator)
pub const Certificate = struct { buffer: []const u8, index: u32 };

// Parsing (allocation-free)
pub fn parse(cert: Certificate) ParseError!Parsed

// Verification (explicit timestamp)
pub fn verify(parsed_subject: Parsed, parsed_issuer: Parsed, now_sec: i64) VerifyError!void
pub fn verifyHostName(parsed_subject: Parsed, host_name: []const u8) VerifyHostNameError!void
```

## 3) The Golden Snippet

```zig
const std = @import("std");
const Certificate = std.crypto.Certificate;

// Example: Parse and verify a certificate chain
fn verifyCertificateChain(
    subject_der: []const u8,
    issuer_der: []const u8,
    hostname: []const u8,
) !void {
    const subject_cert = Certificate{ .buffer = subject_der, .index = 0 };
    const issuer_cert = Certificate{ .buffer = issuer_der, .index = 0 };
    
    // Parse both certificates
    const parsed_subject = try subject_cert.parse();
    const parsed_issuer = try issuer_cert.parse();
    
    // Get current time (seconds since epoch)
    const now = std.time.timestamp();
    
    // Verify certificate signature and validity
    try parsed_subject.verify(parsed_issuer, now);
    
    // Verify hostname matches certificate
    try parsed_subject.verifyHostName(hostname);
    
    // Access certificate information
    std.debug.print("Subject: {s}\n", .{parsed_subject.subject()});
    std.debug.print("Issuer: {s}\n", .{parsed_subject.issuer()});
    std.debug.print("Common Name: {s}\n", .{parsed_subject.commonName()});
}
```

## 4) Dependencies

- **std.mem**: Used extensively for byte comparison and manipulation
- **std.crypto**: Core cryptographic operations (hashing, signatures)
- **std.time**: Time/date handling for certificate validity periods
- **std.crypto.ff**: Finite field arithmetic for RSA operations
- **std.crypto.ecc**: Elliptic curve cryptography for ECDSA
- **std.crypto.hash**: Hash functions (SHA1, SHA2 family)
- **std.crypto.sign**: Digital signature algorithms (Ed25519)

The module has no external dependencies beyond the Zig standard library and is designed to be completely self-contained for certificate processing.