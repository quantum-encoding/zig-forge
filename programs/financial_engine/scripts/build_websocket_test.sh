#!/bin/bash

# Build script for WebSocket test
echo "Building WebSocket test..."

ZIG="/usr/local/zig-x86_64-linux-0.16.0/zig"

# Create zig-out/bin directory if it doesn't exist
mkdir -p zig-out/bin

# Build the WebSocket test
$ZIG build-exe \
    src/test_websocket.zig \
    -lc \
    -lwebsockets \
    -O ReleaseFast \
    --name test-websocket \
    --cache-dir .zig-cache \
    --global-cache-dir ~/.cache/zig

# Move to output directory
mv test-websocket zig-out/bin/ 2>/dev/null || true

if [ -f "zig-out/bin/test-websocket" ]; then
    echo "✅ Build successful! Run with: ./zig-out/bin/test-websocket"
else
    echo "❌ Build failed"
    exit 1
fi