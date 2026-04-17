#!/usr/bin/env bash
#
# repack-for-xcode.sh — fix Zig-emitted static archives for Apple's linker.
#
# Zig's archive writer (as of 0.16.0 stable) pads Mach-O archive members
# to 2-byte alignment. Apple's ld-prime (Xcode 16+) rejects 64-bit Mach-O
# archive members that aren't 8-byte aligned with:
#
#     ld: 64-bit mach-o member 'foo.o' not 8-byte aligned in 'libfoo.a'
#
# The canonical macOS tool `libtool -static` produces correctly aligned
# archives. This script extracts an archive and repacks it via libtool.
#
# Works with multiple archives; pass any number of .a paths.
#
# Also fixes a Zig quirk where extracted .o files land without read
# permission (chmod first, then libtool).
#
# Usage:
#   ./repack-for-xcode.sh path/to/libfoo.a [more.a ...]
#
# Exit status: 0 on success, non-zero if any repack fails.

set -euo pipefail

if [[ $# -eq 0 ]]; then
    echo "usage: $(basename "$0") <archive.a> [archive.a ...]" >&2
    exit 2
fi

for archive in "$@"; do
    if [[ ! -f "$archive" ]]; then
        echo "✗ not found: $archive" >&2
        exit 1
    fi

    tmpdir="$(mktemp -d)"
    cleanup() { rm -rf "$tmpdir"; }
    trap cleanup EXIT

    cp "$archive" "$tmpdir/orig.a"
    (cd "$tmpdir" && ar x orig.a && rm orig.a)
    chmod -R u+rw "$tmpdir"

    count=$(ls "$tmpdir"/*.o 2>/dev/null | wc -l | tr -d ' ')
    if [[ "$count" -eq 0 ]]; then
        echo "✗ $archive — no objects extracted (empty or malformed?)" >&2
        exit 1
    fi

    libtool -static -o "$tmpdir/repacked.a" "$tmpdir"/*.o
    mv "$tmpdir/repacked.a" "$archive"
    size=$(ls -l "$archive" | awk '{print $5}')
    echo "✓ $archive ($count obj, $size bytes)"

    cleanup
    trap - EXIT
done
