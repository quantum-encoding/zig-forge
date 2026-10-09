#!/usr/bin/env bash
# Build libzigpdf.a for Apple linkers.
#
#   ./build-libs.sh [release|debug]
#
# release (the default) is scripts/build-macos-lib.sh programs/zig_pdf_generator: ReleaseSmall,
# repacked for ld-prime, stamped with its source identity. That is the build consumers
# link and the one their release.toml files declare.
#
# debug is a plain `zig build` for local work. A Debug archive is not the release
# build, so the stamps beside it are removed: nothing may report it as current.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
LIB="$HERE/zig-out/lib/libzigpdf.a"

case "${1:-release}" in
  release)
    "$ROOT/scripts/build-macos-lib.sh" programs/zig_pdf_generator ;;
  debug)
    (cd "$HERE" && zig build)
    rm -f "${LIB%.a}-source-id.txt" "$LIB.release-stamp.json"
    if [ "$(uname -s)" = Darwin ]; then
      "$ROOT/scripts/repack-for-xcode.sh" "$LIB" >/dev/null
    fi
    echo "built $LIB (Debug, unstamped)" ;;
  *)
    echo "usage: $0 [release|debug]" >&2
    exit 1 ;;
esac

echo "symbols exported: $(nm -gU "$LIB" 2>/dev/null | grep -c " T _zigpdf" || true)"
