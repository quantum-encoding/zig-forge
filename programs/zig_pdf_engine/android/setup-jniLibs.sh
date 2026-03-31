#!/bin/bash
#
# Copy Zig-built shared libraries to Android jniLibs directory
#
# Usage: ./setup-jniLibs.sh [app_dir]
#   app_dir: Path to Android app module (default: ./app)

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ZIG_OUT="${SCRIPT_DIR}/../zig-out/lib"
APP_DIR="${1:-./app}"
JNI_LIBS="${APP_DIR}/src/main/jniLibs"

echo "Setting up jniLibs in ${JNI_LIBS}..."

# Create directories
mkdir -p "${JNI_LIBS}/arm64-v8a"
mkdir -p "${JNI_LIBS}/armeabi-v7a"
mkdir -p "${JNI_LIBS}/x86_64"

# Copy libraries
if [ -f "${ZIG_OUT}/android-arm64/libpdf_renderer.so" ]; then
    cp "${ZIG_OUT}/android-arm64/libpdf_renderer.so" "${JNI_LIBS}/arm64-v8a/"
    echo "  ✓ arm64-v8a"
else
    echo "  ✗ arm64-v8a (not found)"
fi

if [ -f "${ZIG_OUT}/android-arm32/libpdf_renderer.so" ]; then
    cp "${ZIG_OUT}/android-arm32/libpdf_renderer.so" "${JNI_LIBS}/armeabi-v7a/"
    echo "  ✓ armeabi-v7a"
else
    echo "  ✗ armeabi-v7a (not found)"
fi

if [ -f "${ZIG_OUT}/android-x86_64/libpdf_renderer.so" ]; then
    cp "${ZIG_OUT}/android-x86_64/libpdf_renderer.so" "${JNI_LIBS}/x86_64/"
    echo "  ✓ x86_64"
else
    echo "  ✗ x86_64 (not found)"
fi

echo ""
echo "Done! Libraries copied to ${JNI_LIBS}"
echo ""
echo "Directory structure:"
find "${JNI_LIBS}" -name "*.so" -exec ls -lh {} \;
