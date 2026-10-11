#!/usr/bin/env bash
# Stamp a built archive: what it was built from, and which bytes it is.
#
#   scripts/stamp-archive.sh <archive> <source-id> [<toolchain-id>]
#
# The archive is a `lib<name>.a`, a `<name>.lib` (what Zig writes for a Windows MSVC
# target) or a `lib<name>.so` (an Android shared library). Writes, beside it:
#
#   <lib>-source-id.txt   the source identity (scripts/zig-source-id.sh), one line. The
#                         format every existing reader parses; unchanged. A .a and a .so
#                         of the same stem share it, so stamp both from one build.
#   <lib>-toolchain.txt   the Zig that built it (scripts/zig-toolchain.sh), one line, e.g.
#                         "zig 0.17.0 + zig-0.17.0-ios-nullfile.patch sha256:56ace2b8…". From
#                         the third argument, else $ZIG_TOOLCHAIN_ID (exported by the build
#                         scripts' forge_zig_require), else the identity of the Zig the
#                         build scripts would select now. A .a and a .so of one stem share it.
#   <archive>.sha256      the archive's sha256, in `shasum -a 256` format with the bare
#                         file name, so `cd <dir> && shasum -a 256 -c <archive>.sha256`
#                         (or scripts/sha256.sh -c, on a host without shasum) verifies it.
#
# The source-id alone says which sources an archive SHOULD be; only the sha256 says the
# archive beside it IS the one that build wrote. Without it a stamp that travels without
# its archive reads fresh: programs/ios-libs/*/lib*-source-id.txt were tracked in git
# while the archives were ignored, so pulling a restamp commit (338c9594) onto a Mac
# holding older archives paired the new stamp with the old bytes and every gate passed
# (work item FB672FF4). A gate that checks the sha256 refuses that pairing.
#
# All three files are written via a temporary and a rename, the sha256 last; call this only
# after the last write to the archive (the Xcode repack included).
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd -P)"
SHA256="$HERE/sha256.sh"
archive="${1:?usage: stamp-archive.sh <archive> <source-id> [<toolchain-id>]}"
id="${2:?usage: stamp-archive.sh <archive> <source-id> [<toolchain-id>]}"
toolchain="${3:-${ZIG_TOOLCHAIN_ID:-}}"
if [ -z "$toolchain" ]; then
  # shellcheck source=zig-toolchain.sh
  . "$HERE/zig-toolchain.sh"
  forge_zig_require
  toolchain="$ZIG_TOOLCHAIN_ID"
fi
[ -f "$archive" ] || { echo "error: no archive at $archive" >&2; exit 1; }
case "$archive" in *.a | *.lib | *.so) ;; *) echo "error: $archive is not a .a, .lib or .so" >&2; exit 1 ;; esac

stamp="${archive%.*}-source-id.txt"
printf '%s\n' "$id" > "$stamp.tmp"
mv "$stamp.tmp" "$stamp"

tc="${archive%.*}-toolchain.txt"
printf '%s\n' "$toolchain" > "$tc.tmp"
mv "$tc.tmp" "$tc"

dir="$(dirname "$archive")" name="$(basename "$archive")"
(cd "$dir" && "$SHA256" "$name" > "$name.sha256.tmp" && mv "$name.sha256.tmp" "$name.sha256")
