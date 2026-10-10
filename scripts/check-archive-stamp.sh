#!/usr/bin/env bash
# Check that an archive's stamps (scripts/stamp-archive.sh) describe it and its sources.
#
#   scripts/check-archive-stamp.sh <archive.a> <program-dir>
#
# Fails, naming the reason, when
#   - the archive, its <lib>-source-id.txt or its <lib>.a.sha256 is missing;
#   - the source-id differs from scripts/zig-source-id.sh <program-dir> (stale archive);
#   - the sha256 differs from the archive's bytes (the stamp was written for another
#     archive: copied, pulled or restored without it, or the archive was rewritten after
#     stamping).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
archive="${1:?usage: check-archive-stamp.sh <archive.a> <program-dir>}"
dir="${2:?usage: check-archive-stamp.sh <archive.a> <program-dir>}"

stamp="${archive%.a}-source-id.txt"
sum="$archive.sha256"
[ -f "$archive" ] || { echo "no archive at $archive" >&2; exit 1; }
[ -f "$stamp" ] || { echo "$archive has no source-id stamp ($stamp)" >&2; exit 1; }
[ -f "$sum" ] || { echo "$archive has no sha256 stamp ($sum)" >&2; exit 1; }

expected="$("$ROOT/scripts/zig-source-id.sh" "$dir")"
actual="$(tr -d '[:space:]' < "$stamp")"
if [ "$actual" != "$expected" ]; then
  echo "$archive was built from $actual; its sources are now $expected" >&2
  exit 1
fi

if ! (cd "$(dirname "$archive")" && shasum -a 256 -s -c "$(basename "$sum")"); then
  echo "$archive is not the archive its stamp was written for (sha256 mismatch: the stamp" >&2
  echo "  arrived without its archive, or the archive changed after stamping)" >&2
  exit 1
fi
