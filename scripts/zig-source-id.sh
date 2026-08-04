#!/usr/bin/env bash
# Print a content identity for one Zig program's sources.
#
# The identity is a hash over every `.zig` file under the program directory, with
# each file's PATH included so a rename is a change, and the list sorted so the
# answer never depends on filesystem order.
#
# This exists so a prebuilt static archive can be compared against the source it
# claims to be built from. `walletcore` has had that check since a stale slice made
# an ownership check appear not to exist; the Zig cores underneath had none, and on
# 2026-08-04 both consequences showed up at once — the iOS archives were two days
# behind their sources, and macOS was linking a Debug build while iOS linked
# ReleaseSmall, so the two platforms ran different machine code for the same crypto
# primitives with a fully green test suite behind them.
#
#   scripts/zig-source-id.sh programs/simd_crypto_ffi
set -euo pipefail

DIR="${1:?usage: zig-source-id.sh <program-dir>}"
[ -d "$DIR" ] || { echo "error: no such directory: $DIR" >&2; exit 1; }

# Computed from INSIDE the directory so every path is relative to it. `shasum` prints
# the path beside each digest, so hashing `/abs/path/src/x.zig` and `rel/src/x.zig`
# yields different identities for identical bytes — a gate that fails depending on how
# its argument was spelled is one someone switches off.
#
# `find | sort` rather than a glob: these trees are nested, and a glob that quietly
# misses a subdirectory produces a stable-looking identity that ignores real changes
# — the fail-open shape this whole mechanism exists to avoid.
cd "$DIR"
find . -type f -name '*.zig' -print0 \
  | LC_ALL=C sort -z \
  | xargs -0 shasum -a 256 \
  | shasum -a 256 \
  | cut -d' ' -f1
