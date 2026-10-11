#!/usr/bin/env bash
# Build zsss (SLIP-0039) for every target its consumers vendor — Apple, Linux, Android
# (static and shared) and Windows — and stamp each archive with the identity of the
# sources it was built from.
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
# ...-android.29". The static archives need no link step and build with Zig alone. Both
# are built here with the `zig build-lib` lines build.zig's android step runs
# (ReleaseFast, -lc, no strip; -static -fPIC for the archive, -dynamic for the shared
# library), one per ABI, so the step's own all-or-nothing never writes them. The static
# object this writes has the same machine code, data sections and symbol table as the
# one the step installs (checked 2026-10-11 on all four ABIs: objdump -d / -s / nm
# identical); only a global-cache path in the debug strings differs, so the archive bytes
# do. The step is not changed in build.zig because the file is part of the source
# identity every stamped slice carries.
#
# The shared libraries get the NDK's Bionic through a `--libc` file (the format `zig
# libc` prints) per ABI, pointing at the sysroot's usr/include, usr/include/<triple> and
# usr/lib/<triple>/<api>; `--sysroot` alone is not enough, Zig does not detect the NDK
# layout from it, and one file cannot serve four ABIs, which is why `zig build android
# --libc` is no use. The NDK is found through $ANDROID_NDK_HOME, $NDK_HOME, or the newest
# ndk/<version> under $ANDROID_HOME, $ANDROID_SDK_ROOT or the Android Studio SDK
# location, and the script fails before building anything without one: the .so files
# are artifacts of the zsss row in libs.toml, so a run without them would leave the row
# half-built with nothing to say so until the gate. The .so files are nobody's input
# today (quantum_vault links `static=zsss` into its Tauri cdylib and vendors the .so
# beside it), so they are built and stamped only so that no consumer carries an old one.
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
#   ANDROID_NDK_HOME=~/Library/Android/sdk/ndk/29.0.14206865 scripts/build-zsss.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ZSSS="$ROOT/zig_core_utils/zsss"
# The Zig (scripts/zig-toolchain.sh): $ZIG, else the forge's patched install, else PATH;
# refused unless consumed archives may be built with it. Stamped as <lib>-toolchain.txt.
# shellcheck source=zig-toolchain.sh
. "$ROOT/scripts/zig-toolchain.sh"
forge_zig_require
[ -d "$ZSSS" ] || { echo "error: no zsss at $ZSSS" >&2; exit 1; }

# The NDK, before anything is built (see the header). One toolchain host directory per
# NDK: darwin-x86_64 on every Mac (Rosetta on Apple silicon), linux-x86_64 on Linux.
find_ndk() {
  local c sdk
  for c in "${ANDROID_NDK_HOME:-}" "${NDK_HOME:-}"; do
    [ -n "$c" ] && [ -d "$c/toolchains/llvm/prebuilt" ] && { echo "$c"; return 0; }
  done
  for sdk in "${ANDROID_HOME:-}" "${ANDROID_SDK_ROOT:-}" "$HOME/Library/Android/sdk" "$HOME/Android/Sdk"; do
    [ -n "$sdk" ] && [ -d "$sdk/ndk" ] || continue
    c="$(ls -d "$sdk"/ndk/*/ 2>/dev/null | sort -V | tail -1)"
    [ -n "$c" ] && [ -d "$c/toolchains/llvm/prebuilt" ] && { echo "${c%/}"; return 0; }
  done
  return 1
}
ndk="$(find_ndk)" || {
  echo "error: no Android NDK: set ANDROID_NDK_HOME (or NDK_HOME) to an NDK, or install one" >&2
  echo "  under \$ANDROID_HOME/ndk; the zsss Android shared libraries need its Bionic libc" >&2
  exit 1
}
sysroot="$(ls -d "$ndk"/toolchains/llvm/prebuilt/*/sysroot 2>/dev/null | head -1)"
[ -n "$sysroot" ] && [ -d "$sysroot/usr/lib" ] ||
  { echo "error: $ndk has no toolchains/llvm/prebuilt/<host>/sysroot" >&2; exit 1; }
# Zig 0.16 resolves a bare `*-linux-android` target to Android API 29 (what build.zig's
# android step names, and what its error names without an NDK), so the crt objects and
# libc.so stubs are taken from that API level. A different level would change which
# Bionic symbols the .so may reference, so it is not a knob.
android_api=29

# The identity is taken BEFORE building: a source edited mid-build then leaves stamps
# that read stale, never ones that claim a newer source than the archives hold.
id="$("$ROOT/scripts/zig-source-id.sh" "$ZSSS")"

cd "$ZSSS"
"$ZIG" build apple linux windows

# Android: the four ABIs build.zig's android step names, in the order it names them, as
# `libzsss-<name>.a` and `libzsss-<name>.so` — the files the step would install. Each
# is the step's own `zig build-lib` line (ReleaseFast, -lc, no strip; -static -fPIC for
# the archive, -dynamic for the shared library), plus `--libc` for the shared one. The
# sysroot's per-triple directories are named by the NDK's triples, which differ from
# Zig's for 32-bit x86 (i686-linux-android).
android_targets=(aarch64-linux-android arm-linux-androideabi x86_64-linux-android x86-linux-android)
android_names=(aarch64-android arm-android x86_64-android x86-android)
android_triples=(aarch64-linux-android arm-linux-androideabi x86_64-linux-android i686-linux-android)
scratch="$(mktemp -d "${TMPDIR:-/tmp}/build-zsss.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT
for i in "${!android_targets[@]}"; do
  out="zig-out/lib/libzsss-${android_names[$i]}.a"
  "$ZIG" build-lib -OReleaseFast -target "${android_targets[$i]}" -lc -static -fPIC \
    --name "zsss-${android_names[$i]}" -Mroot=src/lib.zig -femit-bin="$out.tmp"
  mv "$out.tmp" "$out"

  triple="${android_triples[$i]}"
  for d in "$sysroot/usr/include" "$sysroot/usr/include/$triple" "$sysroot/usr/lib/$triple/$android_api"; do
    [ -d "$d" ] || { echo "error: NDK sysroot has no $d" >&2; exit 1; }
  done
  libc_file="$scratch/libc-$triple.txt"
  # gcc_dir is 0.16's name for what 0.17 calls cc_dir (it reads either); 0.17 refuses a
  # Linux-OS file with it empty or without darwin_sdk_dir, 0.16 ignores the key it does not
  # know. It names where crtbegin/crtend are looked up; the NDK keeps its crtbegin_so.o /
  # crtend_so.o in the same per-API directory as the other crt objects.
  crt="$sysroot/usr/lib/$triple/$android_api"
  printf 'include_dir=%s\nsys_include_dir=%s\ncrt_dir=%s\nmsvc_lib_dir=\nkernel32_lib_dir=\ngcc_dir=%s\ndarwin_sdk_dir=\n' \
    "$sysroot/usr/include" "$sysroot/usr/include/$triple" "$crt" "$crt" > "$libc_file"
  # Built under its final name, so the SONAME is the file name consumers would load.
  so="libzsss-${android_names[$i]}.so"
  "$ZIG" build-lib -OReleaseFast -target "${android_targets[$i]}" -lc -dynamic --libc "$libc_file" \
    --name "zsss-${android_names[$i]}" -Mroot=src/lib.zig -femit-bin="$scratch/$so"
  mv "$scratch/$so" "zig-out/lib/$so"
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

# Only the per-target archives (libzsss-<arch>-<os>.a, zsss-<arch>-windows.lib) and the
# Android shared libraries (libzsss-<arch>-android.so, the ones quantum_vault vendors)
# are what consumers link or carry. A bare `zig build` writes a host libzsss.a in Debug;
# it is never stamped, nor are the Linux/macOS shared libraries the steps leave beside the
# archives. Stamped last, so each stamp's sha256 is of the file as consumers will link
# it. An Android .a and .so of one ABI share their -source-id.txt (same stem); both come
# from this one run, so the shared line is true of both.
stamped=0
for archive in zig-out/lib/libzsss-*.a zig-out/lib/zsss-*-windows.lib zig-out/lib/libzsss-*-android.so; do
  [ -e "$archive" ] || continue
  "$ROOT/scripts/stamp-archive.sh" "$archive" "$id" "$ZIG_TOOLCHAIN_ID"
  stamped=$((stamped + 1))
done

echo "zsss built with $ZIG_TOOLCHAIN_ID; ${#apple[@]} Apple archives link-checked, $stamped archives stamped as $id"
