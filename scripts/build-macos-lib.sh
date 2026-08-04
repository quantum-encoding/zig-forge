#!/usr/bin/env bash
# Build one Zig program's macOS static library the way a consumer must link it.
#
# `zig build` with no `-Doptimize` takes Zig's DEBUG default. On 2026-08-04 that is
# exactly what had happened to simd_crypto_ffi: the macOS archive was a 3.99 MB
# Debug build carrying "index out of bounds" and "integer overflow" panic strings,
# while the iOS archives were 473 KB of ReleaseSmall with none. The Mac and the
# iPhone therefore ran DIFFERENT MACHINE CODE for the same crypto primitives —
# sha256, sha512, hmac, pbkdf2, all on the live BIP-39 seed path — differing
# precisely in whether an integer overflow panics or wraps. A test passing on macOS
# proved nothing about the iOS binary.
#
# This script exists so the correct build is the easy one: same optimisation mode as
# the iOS slices, the Mach-O repack Xcode's linker requires, and a source-identity
# stamp beside the archive.
#
#   scripts/build-macos-lib.sh programs/simd_crypto_ffi
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIR="${1:?usage: build-macos-lib.sh <program-dir>}"
[ -d "$ROOT/$DIR" ] || { echo "error: no such program: $DIR" >&2; exit 1; }

cd "$ROOT/$DIR"

# ReleaseSmall, matching build-ios-libs.sh. The two platforms differing in
# optimisation mode is the defect this file is named after.
zig build -Doptimize=ReleaseSmall

for archive in zig-out/lib/*.a; do
  [ -e "$archive" ] || continue
  # Zig 0.16 emits 2-byte-aligned Mach-O members; ld-prime needs 8. Skipping this
  # fails the LINK rather than shipping something wrong, but it fails confusingly.
  "$ROOT/scripts/repack-for-xcode.sh" "$archive" >/dev/null
  "$ROOT/scripts/zig-source-id.sh" "$ROOT/$DIR" > "${archive%.a}-source-id.txt"
  echo "built + stamped $archive"
done
