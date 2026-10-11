#!/usr/bin/env bash
#
# ensure-fresh-lib.sh — rebuild libterminal_mux.a unless it is the canonical build of
# the current sources.
#
# The Swift host (aiconductor) links zig-out/lib/libterminal_mux.a by relative
# path. Nothing in the Xcode build graph knows about src/*.zig, so an edited
# core links against yesterday's archive and the change silently does not exist
# at runtime. This script closes that gap.
#
# The archive is current when scripts/check-archive-stamp.sh accepts it:
#   - libterminal_mux-source-id.txt beside it equals scripts/zig-source-id.sh for
#     the program now (same sources, by content — not by mtime);
#   - libterminal_mux-toolchain.txt names the Zig consumed archives are built with;
#   - libterminal_mux.a.sha256 matches the archive's bytes, so the stamps describe
#     THIS archive. Anything that rewrote it after build-macos-lib.sh stamped it — a
#     hand-run `zig build lib -Doptimize=…` (host macOS floor, no link proof), a copy
#     or a restore — fails here whatever the file times say. (Plain `zig build` writes
#     zig-out/lib/dev/ and never this archive.)
# Otherwise it is rebuilt with scripts/build-macos-lib.sh (ReleaseSmall, link-checked,
# stamped), the same command consumers' release.toml files declare.
#
# Wire it as a Run Script build phase placed BEFORE "Compile Sources", or run it
# by hand before an Xcode build:
#
#     zig-forge/programs/terminal_mux/scripts/ensure-fresh-lib.sh
#
# Exit status: 0 when the archive is current (already or after rebuilding),
# non-zero when the rebuild failed — which fails the Xcode build, by design.

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
program="$(dirname "$here")"
repo="$(cd "$program/../.." && pwd)"
archive="$program/zig-out/lib/libterminal_mux.a"

# Xcode's Run Script phases run with a minimal PATH that usually lacks zig. The
# forge's patched install is found off PATH (scripts/zig-toolchain.sh); PATH `zig` is
# only its fallback, and build-macos-lib.sh refuses a Zig that may not stamp.
if ! command -v zig >/dev/null 2>&1; then
    for candidate in /opt/homebrew/bin /usr/local/bin "$HOME/.local/bin" "$HOME/bin"; do
        if [[ -x "$candidate/zig" ]]; then
            PATH="$candidate:$PATH"
            break
        fi
    done
fi

reason=""
if [[ ! -f "$archive" ]]; then
    reason="archive missing"
elif ! why="$("$repo/scripts/check-archive-stamp.sh" "$archive" "$program" 2>&1)"; then
    reason="$(printf '%s' "$why" | tr '\n' ' ')"
fi

if [[ -z "$reason" ]]; then
    echo "libterminal_mux.a is current"
    exit 0
fi

echo "rebuilding libterminal_mux.a ($reason)"
"$repo/scripts/build-macos-lib.sh" programs/terminal_mux
echo "libterminal_mux.a rebuilt"
