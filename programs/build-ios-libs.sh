#!/bin/bash
# Build all Zig libraries for iOS (aarch64-apple-ios)
# Usage: ./build-ios-libs.sh

set -e

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
        --sysroot "$IOS_SDK" \
        -I"$IOS_SDK/usr/include" \
        "$full_dir/$source" \
        -femit-bin="$OUTPUT_DIR/ios-arm64/lib${lib_name}.a" \
        2>&1; then
        echo -e "${GREEN}  ✓ iOS Device${NC}"
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
        --sysroot "$IOS_SIM_SDK" \
        -I"$IOS_SIM_SDK/usr/include" \
        "$full_dir/$source" \
        -femit-bin="$OUTPUT_DIR/ios-sim-arm64/lib${lib_name}.a" \
        2>&1; then
        echo -e "${GREEN}  ✓ iOS Simulator${NC}"
    else
        echo -e "${RED}  ✗ iOS Simulator failed${NC}"
        return 1
    fi

    return 0
}

# Build each library
# Format: build_lib "lib_name" "directory" "source_file"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
build_lib "quantum_crypto" "simd_crypto_ffi" "src/ffi-grok.zig" && ((SUCCESS++)) || ((FAILED++))

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
build_lib "http_sentinel" "http_sentinel_ffi" "src/ffi.zig" && ((SUCCESS++)) || ((FAILED++))

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
build_lib "electrum_ffi" "electrum_ffi" "src/ffi.zig" && ((SUCCESS++)) || ((FAILED++))

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
build_lib "market_data_core" "market_data_parser" "src/market_data_core.zig" && ((SUCCESS++)) || ((FAILED++))

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
build_lib "lockfree_core" "lockfree_queue" "src/lockfree_core.zig" && ((SUCCESS++)) || ((FAILED++))

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
build_lib "async_core" "async_scheduler" "src/async_core.zig" && ((SUCCESS++)) || ((FAILED++))

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
build_lib "memory_pool_core" "memory_pool" "src/memory_pool_core.zig" && ((SUCCESS++)) || ((FAILED++))

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
build_lib "financial_core" "financial_engine" "src/financial_core.zig" && ((SUCCESS++)) || ((FAILED++))

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
build_lib "zsss" "zig_core_utils/zsss" "src/lib.zig" && ((SUCCESS++)) || ((FAILED++))

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
build_lib "zigpdf" "zig_pdf_generator" "src/ffi.zig" && ((SUCCESS++)) || ((FAILED++))

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
