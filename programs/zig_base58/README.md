# zig_base58 - Bitcoin-style Base58 Encoding

A pure-Zig implementation of Base58 and Base58Check encoding for Bitcoin, Tron, Dogecoin, Litecoin, Ripple, and IPFS. Base58Check uses **double SHA-256** as required by Bitcoin / Tron / DOGE / LTC consensus rules.

## Features

- **Multiple alphabets**: Bitcoin/Tron/IPFS (default), Ripple/XRP, Flickr
- **Base58Check**: SHA-256d (double SHA-256) checksum, externally validated against published test vectors from Bitcoin Core, Satoshi's genesis address, and Tron's USDT contract address
- **Versioned helpers**: `encodeCheckVersioned` / `decodeCheckVersioned` make the network version byte explicit and reject cross-network address reuse (BTC address fed to a Tron decoder errors with `WrongVersion`)
- **OOM-safe**: decoder rejects inputs longer than `MAX_DECODE_INPUT` (1 KiB)
- **Streaming Encoder**: Process large data without loading everything in memory
- **Leading Zero Preservation**: Correctly preserves leading zero bytes as '1' characters
- **Comprehensive Tests**: Full test coverage including edge cases and known vectors
- **Benchmarks**: Performance measurement suite

## Building

```bash
cd programs/zig_base58
zig build
```

## Usage

### CLI Tool

The `zbase58` command-line tool is installed to `zig-out/bin/zbase58`.

#### Basic Encoding

```bash
# Encode string to Base58
zbase58 "Hello World"
# Output: JxF12TrwUP45BMd

# Explicit encode command
zbase58 encode "Bitcoin"
# Output: 3WyEDWjcVB
```

#### Decoding

```bash
# Decode Base58 string
zbase58 decode "JxF12TrwUP45BMd"
# Output: Hello World
```

#### Base58Check (with Checksum)

```bash
# Encode with SHA-256d checksum (Bitcoin/Tron-compatible)
zbase58 check-encode "Payment data"
# Output: 82iP79GRURMpBqpbNs

# Decode and verify checksum
zbase58 check-decode "82iP79GRURMpBqpbNs"
# Output: Payment data

# Invalid checksum detection
zbase58 check-decode "82iP79GRURMpBqpbNsX"
# Output: Error: checksum verification failed
```

#### Help and Version

```bash
zbase58 --help      # Show help message
zbase58 -h          # Short help
zbase58 --version   # Show version
zbase58 -v          # Short version
```

### Library API

Import the base58 module in your Zig code:

```zig
const base58 = @import("base58");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Encode bytes
    const data = "Hello";
    const encoded = try base58.encode(allocator, data);
    defer allocator.free(encoded);
    std.debug.print("Encoded: {s}\n", .{encoded});

    // Decode
    const decoded = try base58.decode(allocator, encoded);
    defer allocator.free(decoded);
    std.debug.print("Decoded: {s}\n", .{decoded});

    // Base58Check
    const checked = try base58.encodeCheck(allocator, data);
    defer allocator.free(checked);

    const verified = try base58.decodeCheck(allocator, checked);
    defer allocator.free(verified);
}
```

## Project Structure

```
zig_base58/
├── build.zig              # Build configuration
├── src/
│   ├── lib.zig            # Library root with re-exports
│   ├── base58.zig         # Core Base58 implementation
│   ├── main.zig           # CLI tool
│   └── bench.zig          # Benchmarks
└── zig-out/
    ├── bin/
    │   ├── zbase58        # CLI executable
    │   └── base58-bench   # Benchmark executable
    └── lib/
        └── libzig_base58.a # Static library
```

## Building and Testing

### Build All Targets

```bash
zig build
```

Produces:
- `zig-out/bin/zbase58` - CLI tool
- `zig-out/bin/base58-bench` - Benchmarks
- `zig-out/lib/libzig_base58.a` - Static library

### Run Tests

```bash
zig build test
```

Test coverage includes:
- Empty input handling
- Single and multiple leading zeros
- Encode/decode round-trip verification
- Base58Check checksum validation
- Invalid character detection
- Known test vectors
- Streaming encoder

### Run Benchmarks

```bash
zig build bench
```

Or run directly:
```bash
./zig-out/bin/base58-bench
```

Benchmarks measure:
- Small data encoding (16 bytes)
- Medium data encoding (64 bytes)
- Large data encoding (1KB)
- Decoding performance
- Base58Check encoding

## Algorithm Overview

### Base58 Encoding

1. Convert binary data to base58 digits using repeated division
2. Prepend one '1' character for each leading zero byte in input
3. Map digits to Base58 alphabet characters

**Base58 Alphabet**: `123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz`

### Base58Check

1. Compute **double** SHA-256 over the data: `SHA256(SHA256(data))`
2. Append the first 4 bytes of that hash as a checksum
3. Encode (data || checksum) using standard Base58
4. To verify, decode, recompute SHA-256d over (decoded[..len-4]), and compare against decoded[len-4..]

Bitcoin, Tron, Dogecoin, and Litecoin all use this same SHA-256d construction. A single-SHA-256 variant is **not** compatible with any of them — every external wallet and exchange will reject such addresses.

## Performance

A benchmark executable (`base58-bench`) is built by `zig build bench`. It measures
small/medium/large encode, decode, and Base58Check encode. No fixed numbers are quoted
here — run the suite on your own hardware for figures relevant to your platform.

## API Reference

### Functions

#### `encode(allocator, data: []const u8) ![]u8`
Encode binary data to Base58 string. Caller owns returned memory.

#### `decode(allocator, encoded: []const u8) ![]u8`
Decode Base58 string to binary data. Caller owns returned memory.

#### `encodeCheck(allocator, data: []const u8) ![]u8`
Encode with Base58Check (SHA-256d checksum). The caller is responsible for prepending the network version byte; prefer `encodeCheckVersioned` for wallet code.

#### `decodeCheck(allocator, encoded: []const u8) ![]u8`
Decode and verify Base58Check checksum (SHA-256d). Returns the payload with the checksum stripped, still including the version byte.

#### `encodeCheckVersioned(allocator, version: u8, payload: []const u8) ![]u8`
Encode `<version><payload><SHA256d(version||payload)[0..4]>`. Preferred for addresses — pass the network version byte (0x00 BTC P2PKH, 0x05 BTC P2SH, 0x1E DOGE, 0x30 LTC, 0x41 Tron) and the raw hash separately.

#### `decodeCheckVersioned(allocator, expected_version: u8, encoded: []const u8) ![]u8`
Decode, verify the SHA-256d checksum, AND verify the version byte. Returns just the payload bytes. Errors with `WrongVersion` on cross-network address reuse, `InvalidChecksum` on mutation, `PayloadTooShort` if length < 5.

#### `encodeWith(allocator, alphabet: *const Alphabet, data: []const u8) ![]u8`
#### `decodeWith(allocator, alphabet: *const Alphabet, encoded: []const u8) ![]u8`
Alphabet-parameterized variants. Use `&Alphabet.ripple` for XRP, `&Alphabet.flickr` for Flickr short URLs, `&Alphabet.bitcoin` for the default.

### Types

#### `StreamEncoder`
Streaming encoder for processing large data:

```zig
var encoder = try StreamEncoder.init(allocator, 1024);
defer encoder.deinit();

try encoder.write(data_part_1);
try encoder.write(data_part_2);

const encoded = try encoder.finish();
defer allocator.free(encoded);
```

### Errors

- `InvalidCharacter` - Input contains character not in Base58 alphabet
- `InvalidChecksum` - Base58Check verification failed
- `EmptyInput` - Input is empty (non-fatal, returns empty encoded string)
- `InputTooLong` - Decoder input exceeds `MAX_DECODE_INPUT` (DoS guard)
- `WrongVersion` - `decodeCheckVersioned` got a different version byte than expected (cross-network address reuse)
- `PayloadTooShort` - `decodeCheckVersioned` got fewer than 5 bytes (no room for version + checksum)

## Specifications

- **Base58 Standard**: Bitcoin implementation
- **Checksum Algorithm**: SHA-256d (`SHA256(SHA256(data))`)
- **Checksum Size**: 4 bytes (first 4 bytes of the SHA-256d output)
- **Zig Version**: 0.16.0-dev
- **Memory**: Zero-copy where possible, allocator-based

## Examples

### Bitcoin Address

Bitcoin addresses use Base58Check:

```bash
# Version byte (0x00) + 20-byte hash + checksum
zbase58 check-encode "data"
```

### IPFS Hash

IPFS uses Base58:

```bash
zbase58 encode "multihash_binary_data"
```

### Data Serialization

```bash
# Encode binary protocol messages
zbase58 encode "protocol_buffer_data"
```

## Files

- `src/base58.zig` - Core implementation
- `src/lib.zig` - Library root with re-exports
- `src/main.zig` - CLI tool
- `src/bench.zig` - Benchmarks
- `build.zig` - Build config

## Testing Checklist

✓ Empty input encoding
✓ Single leading zero
✓ Multiple leading zeros
✓ Round-trip encoding/decoding
✓ Base58Check validation
✓ Checksum failure detection
✓ Invalid character rejection
✓ Known test vectors
✓ Streaming encoder
✓ CLI tool functionality
✓ Benchmark execution

## Implementation Notes

- Uses Zig 0.16 std library with proper allocation patterns
- All memory allocated through Allocator interface
- Error handling with proper defer cleanup
- 16-bit arithmetic to prevent overflow in base conversion
- Stack-allocated alphabet lookup table (256 bytes)
- Stream encoder for unbounded data sizes

## License

Part of quantum-zig-forge collection

## See Also

- Bitcoin Base58: https://en.bitcoin.it/wiki/Base58Check_encoding
- Zig Language: https://ziglang.org
- IPFS: https://ipfs.io
