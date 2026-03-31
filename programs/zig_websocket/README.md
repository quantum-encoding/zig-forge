# zig_websocket - RFC 6455 WebSocket Protocol Library

A pure Zig implementation of the WebSocket protocol (RFC 6455) for Zig 0.16, providing robust frame parsing, building, handshake validation, and connection state management.

## Features

### Core Protocol Implementation
- **Frame parsing and building** - Complete RFC 6455 frame format support
- **Frame masking** - Client-to-server masking with XOR operation
- **Handshake validation** - Sec-WebSocket-Key to Sec-WebSocket-Accept generation using SHA1 and Base64
- **Connection state machine** - connecting → open → closing → closed
- **Message fragmentation** - Support for fragmented messages with continuation frames
- **Control frames** - ping, pong, and close frame handling with status codes
- **Close codes** - Full RFC 6455 close status code validation (1000-1015)

### Zero Dependencies
- Pure Zig implementation using only stdlib
- No external dependencies required
- Suitable for embedded and constrained environments
- Works with Zig 0.16 API patterns

### Frame Opcode Support
- **0x0** - Continuation frame
- **0x1** - Text frame
- **0x2** - Binary frame
- **0x8** - Close frame
- **0x9** - Ping frame
- **0xA** - Pong frame
- Reserved opcodes (0x3-0x7, 0xB+) properly rejected

## Building

### Build all artifacts
```bash
cd /path/to/zig_websocket
zig build
```

### Build specific targets
```bash
# Library only
zig build

# Run unit tests
zig build test

# Run benchmarks
zig build run websocket-bench

# Run interactive demo
zig build run websocket-demo
```

## Usage

### Library API

#### Creating and encoding frames

```zig
const websocket = @import("websocket");

var frame = try websocket.Frame.init(
    allocator,
    true,              // fin flag
    .text,             // opcode
    "Hello, WebSocket!"
);
defer frame.deinit(allocator);

const encoded_bytes = try frame.toBytes(allocator);
defer allocator.free(encoded_bytes);
```

#### Creating masked frames (client-to-server)

```zig
var masked_frame = try websocket.Frame.initMasked(
    allocator,
    true,
    .text,
    "Client message"
);
defer masked_frame.deinit(allocator);
// masking_key field is automatically populated
```

#### Parsing frames

```zig
const parse_result = try websocket.Frame.fromBytes(allocator, frame_bytes);
defer allocator.free(parse_result.frame.payload);

const frame = parse_result.frame;
const bytes_consumed = parse_result.bytes_consumed;
```

#### WebSocket Handshake

```zig
// Server side: validate client key and generate accept
const accept = try websocket.Handshake.generateAccept(allocator, client_key);
defer allocator.free(accept);

// Validation
const is_valid = try websocket.Handshake.validate(
    allocator,
    client_key,
    accept
);
```

#### Connection Management

```zig
var conn = websocket.Connection.init(allocator, true); // is_server=true
defer conn.deinit();

// Process incoming frames
try conn.processFrame(&frame);

// Check connection state
if (conn.state == .open) {
    // Handle frame
}
```

#### Close Frames

```zig
const close_frame = try websocket.CloseFrame.parse(payload);
// code: u16, reason: []const u8

const close_bytes = try close_frame.toBytes(allocator);
defer allocator.free(close_bytes);
```

### CLI Tools

#### websocket-demo

Interactive demonstration of WebSocket protocol features:

```bash
websocket-demo demo                    # Run full demo
websocket-demo encode <message>        # Encode text to frame
websocket-demo decode <hex>            # Decode hex frame
websocket-demo handshake <key>         # Generate handshake
websocket-demo echo                    # Echo server demo
```

Examples:
```bash
websocket-demo encode "Hello"
websocket-demo decode "811148656c6c6f"
websocket-demo handshake "dGhlIHNhbXBsZSBub25jZQ=="
```

#### websocket-bench

Performance benchmarks for frame operations:

```bash
websocket-bench
```

Measures:
- Frame encoding/decoding throughput
- Masking operations
- Handshake generation
- Header parsing
- Operations per second

## File Structure

```
zig_websocket/
├── build.zig              # Zig 0.16 build configuration
├── src/
│   ├── lib.zig           # Public API re-exports
│   ├── websocket.zig     # Core implementation
│   ├── main.zig          # CLI demo executable
│   └── bench.zig         # Performance benchmarks
└── README.md
```

## Implementation Details

### Frame Encoding
- FIN (1 bit) | RSV (3 bits) | Opcode (4 bits)
- MASK (1 bit) | Payload length (7, 16, or 64 bits)
- Masking key (4 bytes) if MASK=1
- Payload data

### Payload Length Encoding
- 0-125: 7-bit value
- 126-65535: 16-bit value with length=126
- 65536+: 64-bit value with length=127

### Masking Algorithm
```
transformed_byte[i] = original_byte[i] XOR masking_key[i % 4]
```

### SHA1-Based Handshake
```
Accept = Base64(SHA1(Key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"))
```

## Performance

Benchmarks on modern hardware show:
- Frame encoding: ~23M ops/sec
- Frame decoding: ~71M ops/sec
- Masked encoding: ~10M ops/sec
- Header parsing: ~245M ops/sec
- Handshake generation: ~3.7M ops/sec
- Masking operations: ~49M ops/sec

## Testing

Comprehensive test suite covering:
- Opcode enum values and operations
- Control frame validation
- Frame header serialization/parsing
- Masked frame operations
- Handshake accept generation (RFC 6455 Section 1.2 examples)
- UTF-8 validation
- Connection state machine
- Frame round-trip encoding/decoding

Run tests:
```bash
zig build test
```

## Protocol Compliance

Fully implements RFC 6455:
- Section 5.1: Frame format and opcodes
- Section 5.2: Data framing
- Section 5.3: Client-to-server masking
- Section 7.1.4: Handshake validation
- Section 7.4: Status codes
- Section 7.6-7.7: UTF-8 validation

## Known Limitations

- Protocol library only: Does not include TCP socket handling
- No compression support (RFC 7692)
- No TLS/SSL (handled at socket layer)
- Simple deterministic RNG for masking keys (use crypto RNG in production)

## Usage Notes

### Zig 0.16 API Patterns

This library uses Zig 0.16 compatible patterns:
- `std.array_list.AlignedManaged(T, null)` instead of `std.ArrayList(T)`
- `std.time.Instant.now()` with try/catch for timestamps
- `std.process.Init` for main function signature

### Memory Management

All allocated data is owned by the caller:
```zig
const bytes = try frame.toBytes(allocator);
defer allocator.free(bytes);  // Must free!
```

### Error Handling

Common errors:
- `IncompleteHeader` - Not enough bytes for frame header
- `IncompleteFrame` - Payload data incomplete
- `ReservedOpcode` - Invalid opcode received
- `InvalidCloseCode` - Close code outside valid range
- `InvalidUtf8` - Close reason not valid UTF-8
- `FragmentedControlFrame` - Control frames cannot be fragmented

## License

Part of quantum-zig-forge project

## Examples

See `src/main.zig` for comprehensive CLI examples and `src/bench.zig` for performance testing patterns.
