#!/bin/bash
# Build Zig libraries for iOS (device + simulator, arm64).
#
# Usage:
#   ./build-ios-libs.sh                  # build every library below
#   ./build-ios-libs.sh zig_docx zigpdf  # build only the named libraries
#
# The optional name filter lets an Xcode "Run Script" build phase provision
# just the libs an app needs (fast) instead of the whole set.

set -e

# Optional allow-list of library names passed on the command line.
WANTED=("$@")
should_build() {
    [ ${#WANTED[@]} -eq 0 ] && return 0
    local candidate="$1" w
    for w in "${WANTED[@]}"; do
        [ "$w" = "$candidate" ] && return 0
    done
    return 1
}

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ZIG="${ZIG:-zig}"
# Zig 0.16+ uses simplified target triples (no vendor)
IOS_TARGET="aarch64-ios"
IOS_SIM_TARGET="aarch64-ios-simulator"
OUTPUT_DIR="$SCRIPT_DIR/ios-libs"

# Find iOS SDKs
IOS_SDK=$(xcrun --sdk iphoneos --show-sdk-path 2>/dev/null)
IOS_SIM_SDK=$(xcrun --sdk iphonesimulator --show-sdk-path 2>/dev/null)

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${CYAN}=== Building Zig Libraries for iOS ===${NC}"
echo -e "Zig version: $($ZIG version)"
echo -e "Target: $IOS_TARGET"
echo -e "iOS SDK: $IOS_SDK"
echo -e "iOS Sim SDK: $IOS_SIM_SDK"
echo ""

if [ -z "$IOS_SDK" ]; then
    echo -e "${RED}Error: iOS SDK not found. Install Xcode.${NC}"
    exit 1
fi

mkdir -p "$OUTPUT_DIR/ios-arm64"
mkdir -p "$OUTPUT_DIR/ios-sim-arm64"

SUCCESS=0
FAILED=0

# Make one emitted archive linkable and record what it is, in this order:
#
#   1. repack it with libtool. Zig 0.16 pads Mach-O members to 2-byte alignment, and
#      ld64 IGNORES a 64-bit member that is not 8-byte aligned ("ignoring archive member
#      ... not 8-byte aligned"), so every symbol in it comes out undefined in the app's
#      link, far from the cause;
#   2. prove the repack took, with a link that must load every member;
#   3. stamp it (scripts/stamp-archive.sh): `-source-id.txt`, so a consumer can tell it
#      from one built months ago, and `.a.sha256`, so the stamp cannot vouch for any
#      other archive. Last, because the sha256 is of the final bytes.
finish_archive() {
    local archive="$1" id="$2"
    "$SCRIPT_DIR/../scripts/repack-for-xcode.sh" "$archive" >/dev/null &&
        "$SCRIPT_DIR/../scripts/check-apple-archive.sh" "$archive" &&
        "$SCRIPT_DIR/../scripts/stamp-archive.sh" "$archive" "$id" || {
        echo -e "${RED}  ✗ $archive: repack, link check or stamp failed${NC}"
        return 1
    }
}

build_lib() {
    local lib_name=$1
    local dir=$2
    local source=$3
    local full_dir="$SCRIPT_DIR/$dir"

    if [ ! -d "$full_dir" ]; then
        echo -e "${YELLOW}  Skipping $lib_name - directory not found: $dir${NC}"
        return 1
    fi

    if [ ! -f "$full_dir/$source" ]; then
        echo -e "${YELLOW}  Skipping $lib_name - source not found: $source${NC}"
        return 1
    fi

    echo -e "${CYAN}Building $lib_name...${NC}"

    # The identity is taken BEFORE building: a source edited mid-build then leaves a
    # stamp that reads stale, never one that claims a newer source than the archive.
    local id
    id="$("$SCRIPT_DIR/../scripts/zig-source-id.sh" "$full_dir")"

    # Build for iOS device (arm64)
    # Use ReleaseSmall + strip to avoid linking std.debug (which uses macOS-only APIs)
    echo -e "  → iOS Device ($IOS_TARGET)"
    if $ZIG build-lib \
        -target $IOS_TARGET \
        -OReleaseSmall \
        --name "$lib_name" \
        -static \
        -lc \
        -fstrip \
        -fcompiler-rt \
        --sysroot "$IOS_SDK" \
        -I"$IOS_SDK/usr/include" \
        "$full_dir/$source" \
        -femit-bin="$OUTPUT_DIR/ios-arm64/lib${lib_name}.a" \
        2>&1; then
        echo -e "${GREEN}  ✓ iOS Device${NC}"
        finish_archive "$OUTPUT_DIR/ios-arm64/lib${lib_name}.a" "$id" || return 1
    else
        echo -e "${RED}  ✗ iOS Device failed${NC}"
        return 1
    fi

    # Build for iOS Simulator (arm64)
    echo -e "  → iOS Simulator ($IOS_SIM_TARGET)"
    if $ZIG build-lib \
        -target $IOS_SIM_TARGET \
        -OReleaseSmall \
        --name "$lib_name" \
        -static \
        -lc \
        -fstrip \
        -fcompiler-rt \
        --sysroot "$IOS_SIM_SDK" \
        -I"$IOS_SIM_SDK/usr/include" \
        "$full_dir/$source" \
        -femit-bin="$OUTPUT_DIR/ios-sim-arm64/lib${lib_name}.a" \
        2>&1; then
        echo -e "${GREEN}  ✓ iOS Simulator${NC}"
        finish_archive "$OUTPUT_DIR/ios-sim-arm64/lib${lib_name}.a" "$id" || return 1
    else
        echo -e "${RED}  ✗ iOS Simulator failed${NC}"
        return 1
    fi

    return 0
}

# Build each library.
# Format: "lib_name|directory|source_file"
LIBS=(
    "quantum_crypto|simd_crypto_ffi|src/ffi-grok.zig"
    "http_sentinel|http_sentinel_ffi|src/ffi.zig"
    "electrum_ffi|electrum_ffi|src/ffi.zig"
    "market_data_core|market_data_parser|src/market_data_core.zig"
    "lockfree_core|lockfree_queue|src/lockfree_core.zig"
    "async_core|async_scheduler|src/async_core.zig"
    "memory_pool_core|memory_pool|src/memory_pool_core.zig"
    "financial_core|financial_engine|src/financial_core.zig"
    "zsss|zig_core_utils/zsss|src/lib.zig"
    "zigpdf|zig_pdf_generator|src/ffi.zig"
    "zig_docx|zig_docx|src/ffi.zig"
)

SKIPPED=0
for entry in "${LIBS[@]}"; do
    IFS='|' read -r name dir source <<< "$entry"
    if ! should_build "$name"; then
        SKIPPED=$((SKIPPED + 1))
        continue
    fi
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    if build_lib "$name" "$dir" "$source"; then SUCCESS=$((SUCCESS + 1)); else FAILED=$((FAILED + 1)); fi
done

echo ""
echo -e "${CYAN}=== Build Summary ===${NC}"
echo -e "${GREEN}Succeeded: $SUCCESS${NC}"
echo -e "${RED}Failed: $FAILED${NC}"
echo ""

echo -e "Libraries output to:"
echo -e "  iOS Device:    ${CYAN}$OUTPUT_DIR/ios-arm64/${NC}"
echo -e "  iOS Simulator: ${CYAN}$OUTPUT_DIR/ios-sim-arm64/${NC}"
echo ""

# List built libraries
echo -e "${CYAN}Built libraries (iOS Device):${NC}"
ls -lh "$OUTPUT_DIR/ios-arm64/"*.a 2>/dev/null || echo "  (none)"
echo ""
echo -e "${CYAN}Built libraries (iOS Simulator):${NC}"
ls -lh "$OUTPUT_DIR/ios-sim-arm64/"*.a 2>/dev/null || echo "  (none)"

# A library that failed to build, repack, link-check or stamp fails the script, so a
# caller (an Xcode Run Script phase) cannot carry on against the archive it left behind.
[ "$FAILED" -eq 0 ] || exit 1
