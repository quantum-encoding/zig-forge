#!/usr/bin/env bash
# Build zsss (SLIP-0039) for the Apple and Linux targets its build.zig emits, and stamp
# each archive with the identity of the sources it was built from.
#
# zsss differs from the single-target programs: one `zig build apple linux` emits a dozen
# ReleaseFast archives (macOS, iOS, simulator, Linux gnu/musl, each per-arch; a bare
# `zig build` makes only the host libzsss.a). The `android` step needs an NDK libc that Zig cannot
# provide on its own, so it is not part of this script. Stamping cannot live beside
# a single build line the way it does in build-ios-libs.sh. This walks the output instead.
#
# The stamp is what lets a consumer refuse a stale archive. zsss is the SLIP-39 share
# split/combine — the backup-recovery path — and a stale one silently un-ships fixes:
# commit 8021e7b2, "validate share-set consistency in combine to return an error instead
# of SIGSEGV on mismatched shares", is exactly the class of change at risk, and the
# SeedShares test target links the same archive so its suite would stay green against it.
#
#   scripts/build-zsss.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ZSSS="$ROOT/zig_core_utils/zsss"
[ -d "$ZSSS" ] || { echo "error: no zsss at $ZSSS" >&2; exit 1; }

# The identity is taken BEFORE building: a source edited mid-build then leaves stamps
# that read stale, never ones that claim a newer source than the archives hold.
id="$("$ROOT/scripts/zig-source-id.sh" "$ZSSS")"

cd "$ZSSS"
zig build apple linux

# The macOS archive is the one Xcode links directly, so it needs the 8-byte Mach-O
# member alignment ld-prime requires. The cross-compiled ones are consumed by their own
# toolchains and are left alone. Repacked before stamping, so each stamp is written
# after the archive it describes.
mac="zig-out/lib/libzsss-aarch64-macos.a"
[ -e "$mac" ] || { echo "error: zig build did not produce $mac" >&2; exit 1; }
"$ROOT/scripts/repack-for-xcode.sh" "$mac" >/dev/null

# Only the per-target archives (libzsss-<arch>-<os>.a) are what consumers link. A bare
# `zig build` writes a host libzsss.a in Debug; it is never stamped.
stamped=0
for archive in zig-out/lib/libzsss-*.a; do
  [ -e "$archive" ] || continue
  printf '%s\n' "$id" > "${archive%.a}-source-id.txt.tmp"
  mv "${archive%.a}-source-id.txt.tmp" "${archive%.a}-source-id.txt"
  stamped=$((stamped + 1))
done

echo "zsss built; $stamped archives stamped as $id"
