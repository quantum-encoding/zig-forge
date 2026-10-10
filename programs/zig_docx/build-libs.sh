#!/usr/bin/env bash
# Build libzig_docx.a for Apple linkers.
#
#   ./build-libs.sh [release|debug]
#
# release (the default) is scripts/build-macos-lib.sh programs/zig_docx: ReleaseSmall,
# repacked for ld-prime, stamped with its source identity, written to zig-out/lib/libzig_docx.a.
# That is the build consumers link and the one their release.toml files declare.
#
# debug is a plain `zig build` for local work. It writes zig-out/lib/dev/libzig_docx.a and leaves
# the release archive and its stamps untouched: build.zig installs nothing else at the consumed path.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"

case "${1:-release}" in
  release)
    LIB="$HERE/zig-out/lib/libzig_docx.a"
    "$ROOT/scripts/build-macos-lib.sh" programs/zig_docx ;;
  debug)
    LIB="$HERE/zig-out/lib/dev/libzig_docx.a"
    (cd "$HERE" && zig build)
    if [ "$(uname -s)" = Darwin ]; then
      "$ROOT/scripts/repack-for-xcode.sh" "$LIB" >/dev/null
    fi
    echo "built $LIB (Debug, unstamped)" ;;
  *)
    echo "usage: $0 [release|debug]" >&2
    exit 1 ;;
esac

echo "symbols exported: $(nm -gU "$LIB" 2>/dev/null | grep -c " T _zig_docx" || true)"
