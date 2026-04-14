#!/bin/bash
# Build static + shared libraries and fix Apple linker alignment.
# Usage: ./build-libs.sh [debug|release]
set -euo pipefail

OPT="${1:-release}"
case "$OPT" in
    release) ZIG_OPT="-Doptimize=ReleaseFast" ;;
    debug)   ZIG_OPT="" ;;
    *)       echo "Usage: $0 [debug|release]"; exit 1 ;;
esac

echo "Building zigpdf ($OPT)..."
zig build $ZIG_OPT

# Fix 8-byte alignment for Apple's linker (Zig 0.16 ar issue)
LIB="zig-out/lib/libzigpdf.a"
if [ -f "$LIB" ]; then
    TMPDIR=$(mktemp -d)
    cd "$TMPDIR"
    ar x "$OLDPWD/$LIB"
    chmod 644 *.o
    ar rcs "$OLDPWD/$LIB" *.o
    ranlib "$OLDPWD/$LIB"
    cd "$OLDPWD"
    rm -rf "$TMPDIR"
    echo "Re-aligned: $LIB"
fi

echo ""
ls -lh zig-out/lib/libzigpdf.*
echo ""
echo "Symbols exported:"
nm -gU zig-out/lib/libzigpdf.a 2>/dev/null | grep "T _zigpdf" | wc -l | tr -d ' '
