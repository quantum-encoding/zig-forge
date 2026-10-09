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
# This script exists so the correct build is the easy one: a release optimisation
# mode, the Mach-O repack Xcode's linker requires, and a source-identity stamp
# (`<lib>-source-id.txt`, from zig-source-id.sh) beside each archive.
#
#   scripts/build-macos-lib.sh <program-dir> [ReleaseSmall|ReleaseFast]
#
# The mode defaults to ReleaseSmall, matching build-ios-libs.sh. It is an argument
# rather than a setting so the exact command line — which `baton release` hashes into
# an input's identity — says which mode built the archive.
#
# A program whose build.zig declares a `lib` step is built with that step, so building
# its library does not also reinstall its executables (terminal_mux's `zterm` in
# zig-out/bin is the CLI on PATH).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIR="${1:?usage: build-macos-lib.sh <program-dir> [ReleaseSmall|ReleaseFast]}"
MODE="${2:-ReleaseSmall}"
[ -d "$ROOT/$DIR" ] || { echo "error: no such program: $DIR" >&2; exit 1; }

case "$MODE" in
  ReleaseSmall | ReleaseFast) ;;
  *)
    # Debug and ReleaseSafe keep the panic machinery; a consumed archive built that
    # way runs different code from the iOS slices of the same library.
    echo "error: mode must be ReleaseSmall or ReleaseFast, not '$MODE'" >&2
    exit 1 ;;
esac

cd "$ROOT/$DIR"

step=install
if grep -qE 'b\.step\("lib",' build.zig; then
  step=lib
fi

# The identity is taken BEFORE building: a source edited mid-build then leaves a stamp
# that reads stale, never one that claims a newer source than the archive holds.
id="$("$ROOT/scripts/zig-source-id.sh" "$ROOT/$DIR")"

zig build "$step" -Doptimize="$MODE"

built=0
for archive in zig-out/lib/*.a; do
  [ -e "$archive" ] || continue
  if [ "$(uname -s)" = Darwin ]; then
    # Zig 0.16 emits 2-byte-aligned Mach-O members; ld-prime needs 8. Skipping this
    # fails the LINK rather than shipping something wrong, but it fails confusingly.
    "$ROOT/scripts/repack-for-xcode.sh" "$archive" >/dev/null
  fi
  stamp="${archive%.a}-source-id.txt"
  printf '%s\n' "$id" > "$stamp.tmp"
  mv "$stamp.tmp" "$stamp"
  echo "built + stamped $DIR/$archive ($MODE)"
  built=$((built + 1))
done

[ "$built" -gt 0 ] || { echo "error: zig build $step produced no archive in $DIR/zig-out/lib" >&2; exit 1; }
