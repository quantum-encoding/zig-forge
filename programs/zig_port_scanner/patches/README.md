# Zig Standard Library Patches

This directory contains patches for the Zig standard library that enable
additional functionality used by this project.


## Why Patches Exist

The Zig 0.16 (dev.1303) standard library has an incomplete networking
implementation. Specifically, `std.Io.Threaded.netConnectIpPosix()`
panics with "TODO implement netConnectIpPosix with timeout" when a
timeout is requested.

## Applying the Patch

### For Local Development

```bash
# Locate your Zig installation
ZIGLIB=$(zig env | jq -r .lib_dir)

# Apply the patch
cd "$ZIGLIB"
patch -p1 < /path/to/0001-implement-posix-connect-with-timeout.patch

# Rebuild zig-port-scanner with v5.0.0
cd /path/to/zig-port-scanner
zig build
```

### For Contributing to Zig

This patch is **PR-ready** for the Zig project. To submit:

1. Clone the Zig repository:
   ```bash
   git clone https://github.com/ziglang/zig.git
   cd zig
   ```

2. Apply the patch:
   ```bash
   git apply /path/to/0001-implement-posix-connect-with-timeout.patch
   ```

3. Test the implementation:
   ```bash
   # Build Zig from source with your changes
   mkdir build && cd build
   cmake .. -DCMAKE_BUILD_TYPE=Release
   make -j$(nproc)

   # Run tests
   ./zig build test
   ```

4. Submit PR following [Zig contribution guidelines](https://github.com/ziglang/zig/blob/master/CONTRIBUTING.md)

## Patch Details

### What It Implements

The patch adds timeout support for TCP connections on POSIX systems using:
- Non-blocking sockets (via `fcntl` + `O.NONBLOCK`)
- `poll()` for timeout-based waiting
- `SO_ERROR` socket option to check connection status

### Technical Approach

```
1. Create socket in blocking mode (existing behavior)
2. If timeout requested:
   a. Set socket to non-blocking via fcntl
   b. Initiate connect (returns EINPROGRESS)
   c. Use poll() to wait with timeout
   d. Check SO_ERROR to determine success/failure
3. If no timeout, use existing blocking connect
```

### Lines Changed

- **Added**: 119 lines (posixConnectWithTimeout + timeout handling)
- **Modified**: 40 lines (netConnectIpPosix refactor)
- **Total**: ~160 lines

### Platform Support

- ✅ **Linux**: Fully tested
- ✅ **macOS**: Should work (uses standard POSIX)
- ✅ **BSD**: Should work (uses standard POSIX)
- ❌ **Windows**: Requires separate implementation (netConnectIpWindows)

## Testing

After applying the patch, verify with:

```bash
# Build the test scanner
cd zig-port-scanner
zig build

# Test against live servers
./zig-out/bin/zig-port-scanner -p=80,443 google.com

# Expected: 2 open ports (HTTP/HTTPS)
```

## Reverting

To remove the patch and return to stock Zig:

```bash
cd "$ZIGLIB"
patch -R -p1 < /path/to/0001-implement-posix-connect-with-timeout.patch
```

Then use v4.1.0 of zig-port-scanner which doesn't require the patch.

## Contributing

If you improve this patch:
1. Update the patch file with your changes
2. Update this README with new details
3. Submit to both this repo AND the Zig project

- **Implementation**: Pattern-matched from existing Zig stdlib (posixConnect)
- **Testing**: Production port scanner (zig-port-scanner)
- **Inspiration**: Rust `std::net::TcpStream::connect_timeout()`


