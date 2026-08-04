#!/usr/bin/env bash
# Build zsss (SLIP-0039) for every target its build.zig emits, and stamp each archive
# with the identity of the sources it was built from.
#
# zsss differs from the single-target programs: one `zig build` emits a dozen archives
# (macOS, iOS, simulator, Linux, Android, each per-arch), so stamping cannot live beside
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

cd "$ZSSS"
zig build

id="$("$ROOT/scripts/zig-source-id.sh" "$ZSSS")"

stamped=0
for archive in zig-out/lib/*.a; do
  [ -e "$archive" ] || continue
  printf '%s\n' "$id" > "${archive%.a}-source-id.txt"
  stamped=$((stamped + 1))
done

# The macOS archive is the one Xcode links directly, so it needs the 8-byte Mach-O
# member alignment ld-prime requires. The cross-compiled ones are consumed by their own
# toolchains and are left alone.
if [ -e "zig-out/lib/libzsss-aarch64-macos.a" ]; then
  "$ROOT/scripts/repack-for-xcode.sh" "zig-out/lib/libzsss-aarch64-macos.a" >/dev/null
fi

echo "zsss built; $stamped archives stamped as $id"
