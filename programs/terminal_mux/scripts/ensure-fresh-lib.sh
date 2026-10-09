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
# The archive is current when ALL of these hold:
#   - libterminal_mux-source-id.txt beside it equals scripts/zig-source-id.sh for
#     the program now (same sources, by content — not by mtime);
#   - the archive is not newer than that stamp. scripts/build-macos-lib.sh writes the
#     stamp after the archive, so an archive newer than its stamp was written by
#     something else — typically a hand-run `zig build`, which is Debug and
#     unrepacked for ld-prime.
# Otherwise it is rebuilt with scripts/build-macos-lib.sh (ReleaseSmall, repacked,
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
stamp="$program/zig-out/lib/libterminal_mux-source-id.txt"

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

reason=""
if [[ ! -f "$archive" ]]; then
    reason="archive missing"
elif [[ ! -f "$stamp" ]]; then
    reason="archive has no source-identity stamp"
elif [[ "$archive" -nt "$stamp" ]]; then
    reason="archive was written after its stamp, not by build-macos-lib.sh"
else
    expected="$("$repo/scripts/zig-source-id.sh" "$program")"
    actual="$(tr -d '[:space:]' < "$stamp")"
    if [[ "$actual" != "$expected" ]]; then
        reason="sources changed since the archive was built"
    fi
fi

if [[ -z "$reason" ]]; then
    echo "libterminal_mux.a is current"
    exit 0
fi

echo "rebuilding libterminal_mux.a ($reason)"
"$repo/scripts/build-macos-lib.sh" programs/terminal_mux
echo "libterminal_mux.a rebuilt"
