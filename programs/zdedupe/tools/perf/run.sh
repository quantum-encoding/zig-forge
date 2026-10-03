#!/bin/bash
# Per-phase timing of the zdedupe core on a fixture or a real tree.
#
#   tools/perf/run.sh fixture DIR [N]     make N small files (default 200000) in DIR
#   tools/perf/run.sh bench PATH [ARGS]   build phasebench against zig-out and time a scan
#
# phasebench ARGS: -m MODE (0 dupes, 2 disk space) -x (default excludes)
# -H (hidden) -j N (threads) -W (stop after the walk) -o STORE.
#
# On a Mac with an Endpoint Security client, run the bench outside any agent's
# process tree (launchctl submit / open), or every open is measured through the
# agent's own authorization path, not the app's.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$here/../.."
case "${1:-}" in
  fixture) python3 "$here/mkfixture.py" "$2" "${3:-200000}" ;;
  bench)
    shift
    (cd "$root" && zig build -Doptimize=ReleaseFast)
    out="$(mktemp -d)"
    cp "$root/zig-out/lib/libzdedupe.a" "$out/"
    if [ "$(uname)" = Darwin ]; then
      "$root/../../scripts/repack-for-xcode.sh" "$out/libzdedupe.a" >/dev/null
      cc -O2 -o "$out/phasebench" "$here/phasebench.c" "$out/libzdedupe.a" -framework Security -framework CoreFoundation
    else
      cc -O2 -o "$out/phasebench" "$here/phasebench.c" "$out/libzdedupe.a" -lpthread
    fi
    target="$1"; shift
    "$out/phasebench" -o "$out/store.bin" "$@" "$target"
    ;;
  *) sed -n '2,12p' "$0"; exit 2 ;;
esac
