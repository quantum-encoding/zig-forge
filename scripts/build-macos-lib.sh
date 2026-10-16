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
# mode, a link that proves Xcode's linker loads every member, and the stamps
# scripts/stamp-archive.sh writes beside each archive: `<lib>-source-id.txt` (from
# zig-source-id.sh) and `<lib>.a.sha256`.
#
#   scripts/build-macos-lib.sh <program-dir> [ReleaseSmall|ReleaseFast]
#
# The mode defaults to ReleaseSmall, matching build-ios-libs.sh. It is an argument
# rather than a setting so the exact command line — which `baton release` hashes into
# an input's identity — says which mode built the archive.
#
# A program whose build.zig declares a `lib` step is built with that step, so building
# its library does not also reinstall its executables (zterm_plex's `zterm` in
# zig-out/bin is the CLI on PATH).
#
# On a Mac the target is explicit: <arch>-macos.26.0. Zig's native target stamps every
# object with the HOST's macOS version as its minimum (27.0 on a Mac running 27) and
# tunes for the host CPU. Linked into an app whose floor is lower, ld warns "built for
# newer 'macOS' version", and an archive built on an M5 may use instructions an M1
# lacks. Zig ignores MACOSX_DEPLOYMENT_TARGET, so the floor has to be in the target.
# 26.0 is the fleet's floor (2026-10-11: every app that links these archives, and the
# Rust FFI build scripts that export MACOSX_DEPLOYMENT_TARGET, moved to 26.0 together;
# an archive newer than the app it goes into makes ld warn and moves the app's floor). A non-native target also turns off Zig's SDK
# detection, so the SDK's usr/ is passed as a search prefix: without it a program that
# links a system library (zig_endpoint_sec's -lEndpointSecurity) finds nothing.
#
# On Windows (Git bash) the target is x86_64-windows-msvc, the ABI Rust's
# x86_64-pc-windows-msvc links. Zig's native target there is the GNU (MinGW) ABI, whose
# libc references the MSVC linker cannot resolve; being explicit also builds for the
# baseline x86-64 CPU rather than the build host's. Zig names that archive <lib>.lib.
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

# The Zig (scripts/zig-toolchain.sh): $ZIG, else the forge's patched install, else PATH;
# refused unless it is a toolchain consumed archives may be built with. Its identity is
# stamped beside each archive (<lib>-toolchain.txt).
# shellcheck source=zig-toolchain.sh
. "$ROOT/scripts/zig-toolchain.sh"
forge_zig_require

cd "$ROOT/$DIR"

step=install
if grep -qE 'b\.step\("lib",' build.zig; then
  step=lib
fi

# The identity is taken BEFORE building: a source edited mid-build then leaves a stamp
# that reads stale, never one that claims a newer source than the archive holds.
id="$("$ROOT/scripts/zig-source-id.sh" "$ROOT/$DIR")"

if [ "$(uname -s)" = Darwin ]; then
  case "$(uname -m)" in
    arm64) arch=aarch64 ;;
    x86_64) arch=x86_64 ;;
    *) echo "error: no macOS target for architecture $(uname -m)" >&2; exit 1 ;;
  esac
  sdk="$(xcrun --sdk macosx --show-sdk-path)"
  "$ZIG" build "$step" -Doptimize="$MODE" -Dtarget="$arch-macos.26.0" --search-prefix "$sdk/usr"
else
  case "$(uname -s)" in
    MINGW* | MSYS* | CYGWIN*) "$ZIG" build "$step" -Doptimize="$MODE" -Dtarget=x86_64-windows-msvc ;;
    *) "$ZIG" build "$step" -Doptimize="$MODE" ;;
  esac
fi

built=0
for archive in zig-out/lib/*.a zig-out/lib/*.lib; do
  [ -e "$archive" ] || continue
  if [ "$(uname -s)" = Darwin ]; then
    # ld64 skips a Mach-O member that is not 8-byte aligned with only a warning rather
    # than refusing the archive. Zig 0.16 wrote 2-byte-aligned members and every archive
    # was repacked here; 0.17 writes aligned ones, so there is no repack, but the proof
    # stays: a link that must load every member.
    "$ROOT/scripts/check-apple-archive.sh" "$archive" >/dev/null
  fi
  "$ROOT/scripts/stamp-archive.sh" "$archive" "$id" "$ZIG_TOOLCHAIN_ID"
  echo "built + stamped $DIR/$archive ($MODE, $ZIG_TOOLCHAIN_ID)"
  built=$((built + 1))
done

[ "$built" -gt 0 ] || { echo "error: zig build $step produced no archive in $DIR/zig-out/lib" >&2; exit 1; }
