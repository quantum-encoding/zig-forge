#!/usr/bin/env bash
#
# ensure-fresh-lib.sh — rebuild libterminal_mux.a when the Zig sources are newer.
#
# The Swift host (aiconductor) links zig-out/lib/libterminal_mux.a by relative
# path. Nothing in the Xcode build graph knows about src/*.zig, so an edited
# core links against yesterday's archive and the change silently does not exist
# at runtime. This script closes that gap: it compares the newest mtime under
# the Zig source set against the archive and rebuilds (+ repacks for ld-prime)
# only when the archive is older or missing.
#
# Wire it as a Run Script build phase placed BEFORE "Compile Sources", or run it
# by hand before an Xcode build:
#
#     zig-forge/programs/terminal_mux/scripts/ensure-fresh-lib.sh
#
# Exit status: 0 when the archive is fresh (already or after rebuilding),
# non-zero when the rebuild failed — which fails the Xcode build, by design.

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(dirname "$here")"
archive="$root/zig-out/lib/libterminal_mux.a"
repack="$root/../../scripts/repack-for-xcode.sh"

# Xcode's Run Script phases run with a minimal PATH that usually lacks zig.
if ! command -v zig >/dev/null 2>&1; then
    for candidate in /opt/homebrew/bin /usr/local/bin "$HOME/.local/bin" "$HOME/bin"; do
        if [[ -x "$candidate/zig" ]]; then
            PATH="$candidate:$PATH"
            break
        fi
    done
fi
if ! command -v zig >/dev/null 2>&1; then
    echo "error: zig not found on PATH — cannot verify libterminal_mux.a is current" >&2
    exit 1
fi

# The inputs that can invalidate the archive. build.zig.zon is optional.
sources=("$root/src" "$root/include" "$root/build.zig")
[[ -f "$root/build.zig.zon" ]] && sources+=("$root/build.zig.zon")

stale=0
if [[ ! -f "$archive" ]]; then
    stale=1
    reason="archive missing"
else
    # -newer is a per-file mtime comparison, so a single find over every input
    # answers "is anything newer than the archive?" without parsing timestamps.
    newer="$(find "${sources[@]}" -type f -newer "$archive" -print -quit 2>/dev/null || true)"
    if [[ -n "$newer" ]]; then
        stale=1
        reason="newer than archive: ${newer#"$root/"}"
    fi
fi

if [[ $stale -eq 0 ]]; then
    echo "libterminal_mux.a is current"
    exit 0
fi

echo "rebuilding libterminal_mux.a ($reason)"
( cd "$root" && zig build )

# Zig 0.16 emits 2-byte-aligned Mach-O archive members; Apple's ld-prime needs
# 8-byte or the link fails with "not 8-byte aligned". Repack on Darwin.
if [[ "$(uname -s)" == "Darwin" && -x "$repack" ]]; then
    "$repack" "$archive"
fi

echo "libterminal_mux.a rebuilt"
