#!/bin/bash
# Local build and test script for zig-coreutils AUR package
# Run this in the aur/ directory to test the package locally

set -e

echo "==> Building zig-coreutils-git package locally..."
echo ""

# Use the git PKGBUILD
cp PKGBUILD-git PKGBUILD.test

# Create a temp directory for building
BUILDDIR=$(mktemp -d)
trap "rm -rf $BUILDDIR" EXIT

cp PKGBUILD.test "$BUILDDIR/PKGBUILD"
cp zig-coreutils.install "$BUILDDIR/"

cd "$BUILDDIR"

echo "==> Running makepkg..."
makepkg -sf --noconfirm

echo ""
echo "==> Package built successfully!"
ls -lh *.pkg.tar.*

echo ""
echo "==> To install: sudo pacman -U $(ls *.pkg.tar.* | head -1)"
