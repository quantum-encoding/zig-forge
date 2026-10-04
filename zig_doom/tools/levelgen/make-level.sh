#!/usr/bin/env bash
# make-level.sh — level spec (JSON tile map) → playable PWAD.
#
#   tools/levelgen/make-level.sh levels/doubleback.json out.wad
#
# Compiles the spec with levelgen.py, then builds the BSP nodes, blockmap
# and reject table with ZDBSP (vanilla node format, which zig_doom reads).
# ZDBSP is fetched and built on first use into tools/levelgen/.zdbsp.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
spec="${1:?usage: make-level.sh spec.json out.wad}"
out="${2:?usage: make-level.sh spec.json out.wad}"
zdbsp="$here/.zdbsp/build/zdbsp"

if [ ! -x "$zdbsp" ]; then
    echo "make-level: building ZDBSP (first use)…" >&2
    [ -d "$here/.zdbsp" ] || command git clone -q --depth 1 https://github.com/rheit/zdbsp "$here/.zdbsp"
    # getopt.c uses getenv() with stdlib.h included only under glibc; on
    # macOS the implicit int return would truncate the pointer.
    grep -q 'make-level: getenv' "$here/.zdbsp/getopt.c" ||
        sed -i.bak '/^#include <stdio.h>/a\
#include <stdlib.h> /* make-level: getenv */
' "$here/.zdbsp/getopt.c"
    cmake -S "$here/.zdbsp" -B "$here/.zdbsp/build" -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_POLICY_VERSION_MINIMUM=3.5 >/dev/null
    cmake --build "$here/.zdbsp/build" -j8 2>&1 | grep -E " error" >&2 || true
    [ -x "$zdbsp" ] || { echo "make-level: ZDBSP build failed" >&2; exit 1; }
fi

raw="$(mktemp -t levelgen).wad"
trap 'command rm -f "$raw"' EXIT
python3 "$here/levelgen.py" "$spec" "$raw"
"$zdbsp" -R -t -o "$out" "$raw" >/dev/null
echo "make-level: $out" >&2
