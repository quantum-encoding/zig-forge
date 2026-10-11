#!/usr/bin/env bash
# SHA-256 of files (or of stdin), printed the way `shasum -a 256` prints it:
# "<hex>  <name>", one line per file.
#
# zig-source-id.sh hashes these lines, so every host has to print them byte for byte
# alike or the same sources get a different identity. `shasum` (Perl; macOS and most
# Linux) is used where it exists. Git for Windows ships only GNU `sha256sum`, which in
# binary mode marks each line "<hex> *<name>"; the marker is rewritten to shasum's two
# spaces. Binary mode is what hashes the bytes on disk on every host.
#
#   scripts/sha256.sh [file...]       no file: stdin, named "-"
#   scripts/sha256.sh -c <sumfile>    verify a file in that format, silently; the exit
#                                     status says whether every listed file matches
#
# SHA256_TOOL=shasum|sha256sum picks the implementation instead (scripts/test-sha256.sh
# runs both on the same input).
set -euo pipefail

tool="${SHA256_TOOL:-}"
if [ -z "$tool" ]; then
  if command -v shasum >/dev/null 2>&1; then tool=shasum; else tool=sha256sum; fi
fi

if [ "${1:-}" = -c ]; then
  sums="${2:?usage: sha256.sh -c <sumfile>}"
  case "$tool" in
    shasum) exec shasum -a 256 -s -c "$sums" ;;
    sha256sum) exec sha256sum --status -c "$sums" ;;
  esac
fi

case "$tool" in
  shasum) shasum -a 256 "$@" ;;
  # A name holding a backslash or newline is escaped by both tools with a leading "\".
  sha256sum) sha256sum -b "$@" | sed 's/^\(\\\{0,1\}[0-9a-f]\{64\}\) \*/\1  /' ;;
  *) echo "error: SHA256_TOOL must be shasum or sha256sum, not '$tool'" >&2; exit 2 ;;
esac
