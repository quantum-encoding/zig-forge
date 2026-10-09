#!/usr/bin/env bash
# Build + repack libchronos_ledger.a for embedding in the CosmicDuckOS XPC sink and
# aiconductor, and copy it with its source-identity stamp into swift/Vendor/.
#
# Output: swift/Vendor/libchronos_ledger.a and libchronos_ledger-source-id.txt (both
# gitignored). The header stays canonical at chronos-ledger/include/chronos_ledger.h —
# point Xcode's Header Search Paths there.
#
# The build is scripts/build-macos-lib.sh (ReleaseSmall, repacked for ld-prime,
# stamped). The stamp covers ../../zig-quantum-encryption/src, which build.zig
# imports for ML-DSA signing, so a change there makes this archive read stale.
#
# The repo root is found from this file's own location, not from git, so the script
# works in an export with no .git directory.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
LIB="$(dirname "$HERE")"
ROOT="$(cd "$LIB/../../.." && pwd)"
OUT="$HERE/Vendor"
mkdir -p "$OUT"

"$ROOT/scripts/build-macos-lib.sh" programs/cognitive_telemetry_kit/chronos-ledger

# The stamp is copied after the archive, so the Vendor pair keeps the build's
# ordering: an archive newer than its stamp was written by something else.
cp "$LIB/zig-out/lib/libchronos_ledger.a" "$OUT/libchronos_ledger.a.tmp"
mv "$OUT/libchronos_ledger.a.tmp" "$OUT/libchronos_ledger.a"
cp "$LIB/zig-out/lib/libchronos_ledger-source-id.txt" "$OUT/libchronos_ledger-source-id.txt.tmp"
mv "$OUT/libchronos_ledger-source-id.txt.tmp" "$OUT/libchronos_ledger-source-id.txt"

echo "→ $OUT/libchronos_ledger.a"
echo "  header: $LIB/include  (add to the XPC target's Header Search Paths)"
