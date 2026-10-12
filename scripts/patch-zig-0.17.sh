#!/usr/bin/env bash
# Install the forge's Zig: the official 0.17.0 release, verified by checksum, with
# scripts/zig-0.17.0-ios-nullfile.patch applied to its std.
#
#   scripts/patch-zig-0.17.sh                          # download for this host, install to
#                                                      # ~/.local/zig-0.17.0-p1
#   scripts/patch-zig-0.17.sh --tarball <file>         # use an already-downloaded tarball
#                                                      # (.tar.xz; .zip on Windows)
#   scripts/patch-zig-0.17.sh --prefix /opt/zig-0.17.0-p1
#   scripts/patch-zig-0.17.sh --force                  # replace an existing install (the old
#                                                      # one is moved aside, not deleted)
#
# Why: official 0.17.0 cannot compile any iOS target that reaches std.debug.print
# (std/Io/Threaded.zig: "no field named 'fd' in Io.Threaded.NullFile"); the patch is the
# two Apple hunks of master's fix (0.18.0-dev.146), see its header. Drop this script and
# the patch when a 0.17.x release carries the fix (then scripts/zig-toolchain.sh pins
# that release instead).
#
# The tarball's sha256 must equal the one ziglang.org/download/index.json publishes for
# 0.17.0 (pinned below, so a tampered or truncated download is refused even offline). The
# install is assembled in a temporary directory beside the prefix, checked (`zig version`
# is 0.17.0, std's Threaded.zig hashes to the patched bytes, a std.debug.print probe
# compiles for aarch64-ios.26.0) and only then moved into place. It writes TOOLCHAIN-ID
# beside the `zig` binary: one line, the identity scripts/zig-toolchain.sh grants and
# every stamp records in `<lib>-toolchain.txt`:
#
#   zig 0.17.0 + zig-0.17.0-ios-nullfile.patch sha256:<sha256 of the patch>
#
# Run it on every machine that stamps archives (the M2, the Linux builders, crg-win from
# Git bash, where ziglang.org publishes a .zip rather than a .tar.xz). It never
# touches PATH, Homebrew or the user's shell; the forge scripts find the install by its
# prefix (or take ZIG=<prefix>/zig).
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd -P)"
# shellcheck source=zig-toolchain.sh
. "$HERE/zig-toolchain.sh"

prefix="$HOME/.local/zig-0.17.0-p1"
tarball=""
force=0
while [ $# -gt 0 ]; do
  case "$1" in
    --prefix) prefix="${2:?--prefix needs a directory}"; shift 2 ;;
    --tarball) tarball="${2:?--tarball needs a file}"; shift 2 ;;
    --force) force=1; shift ;;
    -h | --help) sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "error: unknown argument $1" >&2; exit 2 ;;
  esac
done

# Official 0.17.0 host tarballs: https://ziglang.org/download/index.json, key "0.17.0".
ext=tar.xz
case "$(uname -s)-$(uname -m)" in
  Darwin-arm64)   host=aarch64-macos sum=b607e9b9234790a008116ae5bdb71c6243b84b9fb42a53a9e70fde41c06c536a ;;
  Darwin-x86_64)  host=x86_64-macos  sum=4f9a1c5269aa17ebda5e6d3c2b89d6cbf36f7d2b22a0306e9ab98f25f95529c6 ;;
  Linux-x86_64)   host=x86_64-linux  sum=1cbe9df9f27e6b78d14ccbca43b6703a404ef79ef1c463de901d7f088d4e2026 ;;
  Linux-aarch64 | Linux-arm64)
                  host=aarch64-linux sum=9e8d11661d4ae3bd57702a3832781e23ad151dde5798e16a5ccd503f65234ff8 ;;
  MINGW*-x86_64 | MSYS*-x86_64 | CYGWIN*-x86_64)
                  host=x86_64-windows sum=b5663f69581dcf391293fbf16c06cb80d81d806545ce618b4d0bab7f0eb8c428 ext=zip ;;
  *) echo "error: no pinned Zig 0.17.0 tarball for $(uname -s) $(uname -m); add its" >&2
     echo "  url + shasum from https://ziglang.org/download/index.json to this script" >&2
     exit 1 ;;
esac
name="zig-$host-$FORGE_ZIG_VERSION"
url="https://ziglang.org/download/$FORGE_ZIG_VERSION/$name.$ext"

[ -f "$FORGE_ZIG_PATCH" ] || { echo "error: no patch at $FORGE_ZIG_PATCH" >&2; exit 1; }
patch_sum="$(forge_zig_sha256 "$FORGE_ZIG_PATCH")"
[ "$patch_sum" = "$FORGE_ZIG_PATCH_SHA256" ] || {
  echo "error: $FORGE_ZIG_PATCH has sha256 $patch_sum, scripts/zig-toolchain.sh pins" >&2
  echo "  $FORGE_ZIG_PATCH_SHA256; change both together" >&2
  exit 1
}

if [ -e "$prefix" ]; then
  if [ -x "$prefix/zig" ] && [ "$(forge_zig_id "$prefix/zig")" = "$FORGE_ZIG_ID" ] && [ "$force" = 0 ]; then
    echo "already installed: $prefix/zig is '$FORGE_ZIG_ID'"
    exit 0
  fi
  [ "$force" = 1 ] || {
    echo "error: $prefix exists and is not the forge toolchain ($(forge_zig_id "$prefix/zig" 2>/dev/null || echo '?'));" >&2
    echo "  pass --force to replace it" >&2
    exit 1
  }
fi

parent="$(dirname "$prefix")"
mkdir -p "$parent"
work="$(mktemp -d "$parent/.zig-0.17.0-p1.XXXXXX")"
trap 'rm -rf "$work"' EXIT

if [ -z "$tarball" ]; then
  echo "downloading $url"
  curl -fL --proto '=https' --tlsv1.2 -o "$work/$name.$ext" "$url"
  tarball="$work/$name.$ext"
fi
got="$(forge_zig_sha256 "$tarball")"
if [ "$got" != "$sum" ]; then
  echo "error: $tarball has sha256 $got; the official $name.$ext is $sum" >&2
  exit 1
fi
echo "ok    $name.$ext sha256 $sum"

mkdir "$work/x"
case "$ext" in
  zip) unzip -q "$tarball" -d "$work/x" ;;
  *) tar -xJf "$tarball" -C "$work/x" ;;
esac
src="$work/x/$name"
[ -x "$src/zig" ] || { echo "error: $tarball holds no $name/zig" >&2; exit 1; }

(cd "$src" && patch -p0 --forward --batch < "$FORGE_ZIG_PATCH" >/dev/null) || {
  echo "error: $FORGE_ZIG_PATCH_NAME does not apply to $name" >&2; exit 1; }
printf '%s\n' "$FORGE_ZIG_ID" > "$src/TOOLCHAIN-ID"

# Prove it before it replaces anything.
v="$("$src/zig" version)"
[ "$v" = "$FORGE_ZIG_VERSION" ] || { echo "error: the patched zig says $v" >&2; exit 1; }
id="$(forge_zig_id "$src/zig")"
[ "$id" = "$FORGE_ZIG_ID" ] || { echo "error: the patched install identifies as '$id'" >&2; exit 1; }
mkdir "$work/probe"
printf 'const std = @import("std");\nexport fn probe(x: u32) void {\n    std.debug.print("{d}\\n", .{x});\n}\n' > "$work/probe/probe.zig"
(cd "$work/probe" && ZIG_GLOBAL_CACHE_DIR="$work/probe/g" "$src/zig" build-obj -target aarch64-ios.26.0 \
  -OReleaseSmall --cache-dir "$work/probe/c" probe.zig) || {
  echo "error: the patched std still cannot compile std.debug.print for aarch64-ios.26.0" >&2; exit 1; }
echo "ok    std.debug.print compiles for aarch64-ios.26.0"

if [ -e "$prefix" ]; then
  # Kept, not deleted: the caller decides when the old install goes.
  old="$prefix.replaced-$(date +%Y%m%d%H%M%S)"
  mv "$prefix" "$old"
  echo "moved the previous install to $old"
fi
mv "$src" "$prefix"

echo "installed $prefix/zig"
echo "  zig version: $("$prefix/zig" version)"
echo "  patch:       $FORGE_ZIG_PATCH_NAME sha256 $FORGE_ZIG_PATCH_SHA256"
echo "  TOOLCHAIN-ID: $(cat "$prefix/TOOLCHAIN-ID")"
