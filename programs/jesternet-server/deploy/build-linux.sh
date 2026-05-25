#!/usr/bin/env bash
# Cross-compile jesternet-server from a dev machine (Mac / Linux / WSL)
# for x86_64 Linux deploy targets. Output: deploy/jesternet-server,
# ready to scp + run through setup.sh on the target.
#
# Usage:
#   ./deploy/build-linux.sh                # ReleaseSafe, x86_64-linux-gnu
#   ./deploy/build-linux.sh --musl         # x86_64-linux-musl (static-friendly)
#   ./deploy/build-linux.sh --arm64        # aarch64-linux-gnu (RPi, ARM VPS)
#   ./deploy/build-linux.sh --debug        # Debug build (NOT for prod)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRV_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

TARGET="x86_64-linux-gnu"
OPTIMIZE="ReleaseSafe"

for arg in "$@"; do
  case "$arg" in
    --musl)  TARGET="x86_64-linux-musl" ;;
    --arm64) TARGET="aarch64-linux-gnu" ;;
    --debug) OPTIMIZE="Debug" ;;
    --help|-h)
      sed -n '2,/^$/p' "$0" | sed 's/^# //; s/^#//'
      exit 0
      ;;
  esac
done

echo "→ Cross-compile: $TARGET ($OPTIMIZE)"

cd "$SRV_DIR"
zig build -Doptimize="$OPTIMIZE" -Dtarget="$TARGET"

BUILT="$SRV_DIR/zig-out/bin/jesternet-server"
OUT="$SCRIPT_DIR/jesternet-server"

if [ ! -x "$BUILT" ]; then
  echo "✗ Build succeeded but binary missing at $BUILT" >&2
  exit 1
fi

install -m 0755 "$BUILT" "$OUT"
SIZE=$(stat -f '%z' "$OUT" 2>/dev/null || stat -c '%s' "$OUT")
echo "✓ $OUT (${SIZE} bytes)"
echo ""
echo "Next: scp this binary + the deploy/ directory to the target,"
echo "      then run 'sudo ./setup.sh' on the target."
echo ""
echo "Example:"
echo "  scp -r deploy/ user@host:/tmp/jesternet-deploy/"
echo "  ssh user@host 'cd /tmp/jesternet-deploy && sudo ./setup.sh'"
