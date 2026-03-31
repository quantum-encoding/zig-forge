#!/bin/bash
# Download DOOM shareware WAD (freely distributable)
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WAD_DIR="$SCRIPT_DIR/../wad"
mkdir -p "$WAD_DIR"

URL="https://distro.ibiblio.org/slitaz/sources/packages/d/doom1.wad"
SHA256="5b2e249b9c5133ec987b3ea77596381dc0d6bc1f5f56f0e5ec8d0a8b188dacd7"
DEST="$WAD_DIR/doom1.wad"

if [ -f "$DEST" ]; then
    echo "doom1.wad already exists at $DEST"
    echo "Verifying checksum..."
    echo "$SHA256  $DEST" | shasum -a 256 -c && exit 0
    echo "Checksum mismatch, re-downloading..."
fi

echo "Downloading DOOM shareware WAD..."
curl -L -o "$DEST" "$URL"
echo "Verifying checksum..."
echo "$SHA256  $DEST" | shasum -a 256 -c
echo "Done! WAD saved to $DEST"
