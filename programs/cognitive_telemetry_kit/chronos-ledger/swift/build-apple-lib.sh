#!/bin/bash
# Build + repack libchronos_ledger.a for embedding in the CosmicDuckOS XPC sink.
# Output: swift/Vendor/libchronos_ledger.a (gitignored). Header stays canonical at
# chronos-ledger/include/chronos_ledger.h — point Xcode's Header Search Paths there.
set -euo pipefail

REPO="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
LIB="$REPO/programs/cognitive_telemetry_kit/chronos-ledger"
OUT="$LIB/swift/Vendor"
mkdir -p "$OUT"

# Host build = arm64-macOS on Apple Silicon. zig build already emits the static lib.
( cd "$LIB" && zig build )

# Realign Mach-O members for Apple's ld-prime (Zig emits 2-byte; ld needs 8-byte).
"$REPO/scripts/repack-for-xcode.sh" "$LIB/zig-out/lib/libchronos_ledger.a"
cp "$LIB/zig-out/lib/libchronos_ledger.a" "$OUT/libchronos_ledger.a"

echo "→ $OUT/libchronos_ledger.a"
echo "  header: $LIB/include  (add to the XPC target's Header Search Paths)"
echo
echo "Other arches:  zig build -Dtarget=aarch64-ios   (then lipo / -create-xcframework)."
