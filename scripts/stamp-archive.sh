#!/usr/bin/env bash
# Stamp a built archive: what it was built from, and which bytes it is.
#
#   scripts/stamp-archive.sh <archive.a> <source-id>
#
# Writes, beside the archive:
#
#   <lib>-source-id.txt   the source identity (scripts/zig-source-id.sh), one line. The
#                         format every existing reader parses; unchanged.
#   <lib>.a.sha256        the archive's sha256, in `shasum -a 256` format with the bare
#                         file name, so `cd <dir> && shasum -a 256 -c <lib>.a.sha256`
#                         verifies it.
#
# The source-id alone says which sources an archive SHOULD be; only the sha256 says the
# archive beside it IS the one that build wrote. Without it a stamp that travels without
# its archive reads fresh: programs/ios-libs/*/lib*-source-id.txt were tracked in git
# while the archives were ignored, so pulling a restamp commit (338c9594) onto a Mac
# holding older archives paired the new stamp with the old bytes and every gate passed
# (work item FB672FF4). A gate that checks the sha256 refuses that pairing.
#
# Both files are written via a temporary and a rename, the sha256 last; call this only
# after the last write to the archive (the Xcode repack included).
set -euo pipefail

archive="${1:?usage: stamp-archive.sh <archive.a> <source-id>}"
id="${2:?usage: stamp-archive.sh <archive.a> <source-id>}"
[ -f "$archive" ] || { echo "error: no archive at $archive" >&2; exit 1; }
case "$archive" in *.a) ;; *) echo "error: $archive is not a .a" >&2; exit 1 ;; esac

stamp="${archive%.a}-source-id.txt"
printf '%s\n' "$id" > "$stamp.tmp"
mv "$stamp.tmp" "$stamp"

dir="$(dirname "$archive")" name="$(basename "$archive")"
(cd "$dir" && shasum -a 256 "$name" > "$name.sha256.tmp" && mv "$name.sha256.tmp" "$name.sha256")
