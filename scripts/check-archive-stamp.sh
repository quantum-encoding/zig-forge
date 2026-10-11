#!/usr/bin/env bash
# Check that an archive's stamps (scripts/stamp-archive.sh) describe it and its sources.
#
#   scripts/check-archive-stamp.sh <archive> <program-dir>
#
# The archive is a `lib<name>.a`, a Windows `<name>.lib` or an Android `lib<name>.so`.
# Fails, naming the reason, when
#   - the archive, its <lib>-source-id.txt, its <lib>-toolchain.txt or its <archive>.sha256
#     is missing;
#   - the toolchain it records is not one scripts/zig-toolchain.sh accepts for consumed
#     archives (after the 0.17 flip: only the patched 0.17.0, so an archive from a vanilla
#     0.17.0 or from 0.16.0 is refused even when its sources are current);
#   - the source-id differs from scripts/zig-source-id.sh <program-dir> (stale archive);
#   - the sha256 differs from the archive's bytes (the stamp was written for another
#     archive: copied, pulled or restored without it, or the archive was rewritten after
#     stamping).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=zig-toolchain.sh
. "$ROOT/scripts/zig-toolchain.sh"
archive="${1:?usage: check-archive-stamp.sh <archive> <program-dir>}"
dir="${2:?usage: check-archive-stamp.sh <archive> <program-dir>}"
case "$archive" in *.a | *.lib | *.so) ;; *) echo "$archive is not a .a, .lib or .so" >&2; exit 1 ;; esac

stamp="${archive%.*}-source-id.txt"
tc="${archive%.*}-toolchain.txt"
sum="$archive.sha256"
[ -f "$archive" ] || { echo "no archive at $archive" >&2; exit 1; }
[ -f "$stamp" ] || { echo "$archive has no source-id stamp ($stamp)" >&2; exit 1; }
[ -f "$sum" ] || { echo "$archive has no sha256 stamp ($sum)" >&2; exit 1; }
[ -f "$tc" ] || { echo "$archive has no toolchain stamp ($tc): it predates scripts/zig-toolchain.sh; rebuild it" >&2; exit 1; }

expected="$("$ROOT/scripts/zig-source-id.sh" "$dir")"
actual="$(tr -d '[:space:]' < "$stamp")"
if [ "$actual" != "$expected" ]; then
  echo "$archive was built from $actual; its sources are now $expected" >&2
  exit 1
fi

built_with="$(head -1 "$tc")"
if ! forge_zig_accepted "$built_with"; then
  echo "$archive was built with '$built_with'; consumed archives must come from" >&2
  echo "  '${FORGE_ZIG_ACCEPT[*]}' (scripts/patch-zig-0.17.sh installs it)" >&2
  exit 1
fi

if ! (cd "$(dirname "$archive")" && "$ROOT/scripts/sha256.sh" -c "$(basename "$sum")"); then
  echo "$archive is not the archive its stamp was written for (sha256 mismatch: the stamp" >&2
  echo "  arrived without its archive, or the archive changed after stamping)" >&2
  exit 1
fi
