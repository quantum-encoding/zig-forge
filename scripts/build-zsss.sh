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

# Every Apple archive (macOS, iOS, simulator) is linked by Xcode's ld64, which needs
# 8-byte Mach-O member alignment that Zig 0.16 does not write. build.zig's apple steps
# repack each one after installing it; this proves it, with a link per archive, before
# anything is stamped. Until 2026-10-10 only the macOS archive was repacked here, and
# the iOS and simulator archives Cifra links came out with every _zsss_* undefined
# (work item 437F922C). The Linux archives are consumed by their own toolchains.
apple=(zig-out/lib/libzsss-*-macos.a zig-out/lib/libzsss-*-ios.a zig-out/lib/libzsss-*-ios-simulator.a)
for archive in "${apple[@]}"; do
  [ -e "$archive" ] || { echo "error: zig build did not produce $archive" >&2; exit 1; }
done
if [ "$(uname -s)" = Darwin ]; then
  "$ROOT/scripts/check-apple-archive.sh" "${apple[@]}" >/dev/null ||
    { echo "error: an Apple archive above does not link; nothing was stamped" >&2; exit 1; }
else
  echo "warning: not on macOS: the Apple archives were neither repacked nor link-checked," >&2
  echo "  and are stamped as built; build them on a Mac before an app links them" >&2
fi

# Only the per-target archives (libzsss-<arch>-<os>.a) are what consumers link. A bare
# `zig build` writes a host libzsss.a in Debug; it is never stamped. Stamped last, so
# each stamp's sha256 is of the archive as consumers will link it.
stamped=0
for archive in zig-out/lib/libzsss-*.a; do
  [ -e "$archive" ] || continue
  "$ROOT/scripts/stamp-archive.sh" "$archive" "$id"
  stamped=$((stamped + 1))
done

echo "zsss built; ${#apple[@]} Apple archives link-checked, $stamped archives stamped as $id"
