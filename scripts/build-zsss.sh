#!/usr/bin/env bash
# Build zsss (SLIP-0039) for every target its consumers vendor — Apple, Linux, Android
# (static) and Windows — and stamp each archive with the identity of the sources it was
# built from.
#
# zsss differs from the single-target programs: one `zig build apple linux` emits a dozen
# ReleaseFast archives (macOS, iOS, simulator, Linux gnu/musl, each per-arch; a bare
# `zig build` makes only the host libzsss.a). Stamping cannot live beside a single build
# line the way it does in build-ios-libs.sh. This walks the output instead.
#
# Windows: `zig build windows` is the MSVC-ABI static archive Rust's
# x86_64-pc-windows-msvc links (zsss-x86_64-windows.lib). It cross-compiles from any host:
# a static archive links nothing, so the Windows SDK's import libraries are never looked
# up (the same arrangement as zig-quantum-encryption's Windows archive, f67bcce). The
# build.zig comment saying it needs a Windows host predates that finding.
#
# Android: build.zig's `android` step emits a static AND a shared library per ABI, and
# the shared ones cannot be built without an NDK — Zig bundles Bionic's headers but not
# its libc.so/crt objects, so `-dynamic` fails with "unable to provide libc for target
# ...-android.29". The static archives need no link step and build with Zig alone. They
# are built here with the `zig build-lib` line build.zig's android step runs for its
# static artifact (ReleaseFast, -lc, PIC, no strip), one per ABI, so the step's own
# half-failure never writes them. The object this writes has the same machine code, data
# sections and symbol table as the one the step installs (checked 2026-10-11 on all four
# ABIs: objdump -d / -s / nm identical); only a global-cache path in the debug strings
# differs, so the archive bytes do. The .so files are nobody's input today
# (quantum_vault links `static=zsss` into its Tauri cdylib); a machine with an NDK can
# still run `zig build android` for them. The step is not changed in build.zig because
# the file is part of the source identity every stamped slice carries.
#
# The stamp is what lets a consumer refuse a stale archive. zsss is the SLIP-39 share
# split/combine — the backup-recovery path — and a stale one silently un-ships fixes:
# commit 8021e7b2, "validate share-set consistency in combine to return an error instead
# of SIGSEGV on mismatched shares", is exactly the class of change at risk, and the
# SeedShares test target links the same archive so its suite would stay green against it.
# quantum_vault's Android and Windows slices were the June 2026 build until 2026-10-11
# (crypto test campaign finding #4: a 61-byte PNG segfaulted zsss_stego_extract).
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
zig build apple linux windows

# Android static archives: the four ABIs build.zig's android step names, in the order it
# names them, as `libzsss-<name>.a` — the same file the step would install.
android_targets=(aarch64-linux-android arm-linux-androideabi x86_64-linux-android x86-linux-android)
android_names=(aarch64-android arm-android x86_64-android x86-android)
for i in "${!android_targets[@]}"; do
  out="zig-out/lib/libzsss-${android_names[$i]}.a"
  zig build-lib -OReleaseFast -target "${android_targets[$i]}" -lc -static -fPIC \
    --name "zsss-${android_names[$i]}" -Mroot=src/lib.zig -femit-bin="$out.tmp"
  mv "$out.tmp" "$out"
done

# Every Apple archive (macOS, iOS, simulator) is linked by Xcode's ld64, which needs
# 8-byte Mach-O member alignment that Zig 0.16 does not write. build.zig's apple steps
# repack each one after installing it; this proves it, with a link per archive, before
# anything is stamped. Until 2026-10-10 only the macOS archive was repacked here, and
# the iOS and simulator archives Cifra links came out with every _zsss_* undefined
# (work item 437F922C). The Linux, Android and Windows archives are consumed by their
# own toolchains (lld, link.exe), which accept Zig's member alignment.
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

# Only the per-target archives (libzsss-<arch>-<os>.a, zsss-<arch>-windows.lib) are what
# consumers link. A bare `zig build` writes a host libzsss.a in Debug; it is never
# stamped. Stamped last, so each stamp's sha256 is of the archive as consumers will
# link it.
stamped=0
for archive in zig-out/lib/libzsss-*.a zig-out/lib/zsss-*-windows.lib; do
  [ -e "$archive" ] || continue
  "$ROOT/scripts/stamp-archive.sh" "$archive" "$id"
  stamped=$((stamped + 1))
done

echo "zsss built; ${#apple[@]} Apple archives link-checked, $stamped archives stamped as $id"
