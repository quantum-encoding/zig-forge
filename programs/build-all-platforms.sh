#!/bin/bash
#
# Build All Programs for Multiple Platforms
#
# This script builds all Zig programs in the zig-forge repository
# for multiple target platforms including native, Android, iOS, and WASM.
#
# Usage:
#   ./build-all-platforms.sh [options]
#
# Options:
#   --native       Build native binaries only (default if no options)
#   --android      Build Android ARM64 libraries
#   --ios          Build iOS ARM64 libraries
#   --ios-sim      Build iOS Simulator ARM64 libraries
#   --wasm         Build WebAssembly modules
#   --all          Build for all platforms
#   --libs-only    Only build programs that produce libraries (skip CLI-only)
#   --program NAME Build only the specified program
#   --list         List all available programs
#   --help         Show this help message
#
# Examples:
#   ./build-all-platforms.sh --native
#   ./build-all-platforms.sh --all
#   ./build-all-platforms.sh --android --ios
#   ./build-all-platforms.sh --program zig_pdf_generator --all

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROGRAMS_DIR="$SCRIPT_DIR"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Build flags
BUILD_NATIVE=false
BUILD_ANDROID=false
BUILD_IOS=false
BUILD_IOS_SIM=false
BUILD_WASM=false
LIBS_ONLY=false
SPECIFIC_PROGRAM=""

# Counters
NATIVE_PASS=0
NATIVE_FAIL=0
ANDROID_PASS=0
ANDROID_FAIL=0
IOS_PASS=0
IOS_FAIL=0
IOS_SIM_PASS=0
IOS_SIM_FAIL=0
WASM_PASS=0
WASM_FAIL=0

# Arrays to track results
declare -a NATIVE_FAILED_PROGRAMS
declare -a ANDROID_FAILED_PROGRAMS
declare -a IOS_FAILED_PROGRAMS
declare -a IOS_SIM_FAILED_PROGRAMS
declare -a WASM_FAILED_PROGRAMS

# Programs known to have cross-platform library support
LIBRARY_PROGRAMS=(
    "zig_pdf_generator"
    "zig_charts"
    "simd_crypto_ffi"
    "http_sentinel_ffi"
    "electrum_ffi"
    "quantum_seed_vault"
    # Utility libraries
    "zig_uuid"
    "zig_msgpack"
    "zig_ratelimit"
    "zig_humanize"
    "zig_websocket"
    "zig_jwt"
    "zig_toml"
    "zig_base58"
    "zig_metrics"
    "zig_bloom"
    # Composite services
    "zig_token_service"
)

# Programs that are Linux-only (skip on macOS)
LINUX_ONLY_PROGRAMS=(
    "audio_forge"      # ALSA
    "chronos_engine"   # D-Bus, io_uring
    "guardian_shield"  # BPF
    "mempool_sniffer"  # io_uring
    "hydra"            # io_uring
)

print_header() {
    echo -e "${CYAN}"
    echo "╔══════════════════════════════════════════════════════════════════╗"
    echo "║           Quantum Zig Forge - Multi-Platform Builder             ║"
    echo "╚══════════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

print_usage() {
    head -30 "$0" | tail -27 | sed 's/^#//'
}

list_programs() {
    echo -e "${BLUE}Available programs:${NC}"
    echo ""
    for dir in "$PROGRAMS_DIR"/*/; do
        if [[ -f "$dir/build.zig" ]]; then
            name=$(basename "$dir")
            # Check if it's a library program
            if [[ " ${LIBRARY_PROGRAMS[*]} " =~ " ${name} " ]]; then
                echo -e "  ${GREEN}$name${NC} (library)"
            elif [[ " ${LINUX_ONLY_PROGRAMS[*]} " =~ " ${name} " ]]; then
                echo -e "  ${YELLOW}$name${NC} (Linux-only)"
            else
                echo "  $name"
            fi
        fi
    done
    echo ""
    echo -e "Total: $(ls -d "$PROGRAMS_DIR"/*/build.zig 2>/dev/null | wc -l | tr -d ' ') programs"
}

is_linux_only() {
    local name="$1"
    [[ " ${LINUX_ONLY_PROGRAMS[*]} " =~ " ${name} " ]]
}

has_target() {
    local dir="$1"
    local target="$2"
    cd "$dir"
    zig build --help 2>&1 | grep -q "^  $target "
}

build_native() {
    local dir="$1"
    local name=$(basename "$dir")

    if is_linux_only "$name"; then
        echo -e "  ${YELLOW}SKIP${NC} (Linux-only)"
        return 0
    fi

    cd "$dir"
    if zig build 2>&1; then
        echo -e "  ${GREEN}PASS${NC}"
        ((NATIVE_PASS++))
        return 0
    else
        echo -e "  ${RED}FAIL${NC}"
        ((NATIVE_FAIL++))
        NATIVE_FAILED_PROGRAMS+=("$name")
        return 1
    fi
}

build_android() {
    local dir="$1"
    local name=$(basename "$dir")

    cd "$dir"
    if ! has_target "$dir" "android"; then
        echo -e "  ${YELLOW}N/A${NC}"
        return 0
    fi

    if zig build android 2>&1; then
        echo -e "  ${GREEN}PASS${NC}"
        ((ANDROID_PASS++))
        return 0
    else
        echo -e "  ${RED}FAIL${NC}"
        ((ANDROID_FAIL++))
        ANDROID_FAILED_PROGRAMS+=("$name")
        return 1
    fi
}

build_ios() {
    local dir="$1"
    local name=$(basename "$dir")

    cd "$dir"
    if ! has_target "$dir" "ios"; then
        echo -e "  ${YELLOW}N/A${NC}"
        return 0
    fi

    if zig build ios 2>&1; then
        echo -e "  ${GREEN}PASS${NC}"
        ((IOS_PASS++))
        return 0
    else
        echo -e "  ${RED}FAIL${NC}"
        ((IOS_FAIL++))
        IOS_FAILED_PROGRAMS+=("$name")
        return 1
    fi
}

build_ios_sim() {
    local dir="$1"
    local name=$(basename "$dir")

    cd "$dir"
    if ! has_target "$dir" "ios-sim"; then
        echo -e "  ${YELLOW}N/A${NC}"
        return 0
    fi

    if zig build ios-sim 2>&1; then
        echo -e "  ${GREEN}PASS${NC}"
        ((IOS_SIM_PASS++))
        return 0
    else
        echo -e "  ${RED}FAIL${NC}"
        ((IOS_SIM_FAIL++))
        IOS_SIM_FAILED_PROGRAMS+=("$name")
        return 1
    fi
}

build_wasm() {
    local dir="$1"
    local name=$(basename "$dir")

    cd "$dir"
    if ! has_target "$dir" "wasm"; then
        echo -e "  ${YELLOW}N/A${NC}"
        return 0
    fi

    if zig build wasm 2>&1; then
        echo -e "  ${GREEN}PASS${NC}"
        ((WASM_PASS++))
        return 0
    else
        echo -e "  ${RED}FAIL${NC}"
        ((WASM_FAIL++))
        WASM_FAILED_PROGRAMS+=("$name")
        return 1
    fi
}

build_program() {
    local dir="$1"
    local name=$(basename "$dir")

    echo -e "${BLUE}Building: ${NC}$name"

    if $BUILD_NATIVE; then
        printf "  %-12s" "native:"
        build_native "$dir" || true
    fi

    if $BUILD_ANDROID; then
        printf "  %-12s" "android:"
        build_android "$dir" || true
    fi

    if $BUILD_IOS; then
        printf "  %-12s" "ios:"
        build_ios "$dir" || true
    fi

    if $BUILD_IOS_SIM; then
        printf "  %-12s" "ios-sim:"
        build_ios_sim "$dir" || true
    fi

    if $BUILD_WASM; then
        printf "  %-12s" "wasm:"
        build_wasm "$dir" || true
    fi
}

print_summary() {
    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}                         BUILD SUMMARY                              ${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════════${NC}"
    echo ""

    if $BUILD_NATIVE; then
        local total=$((NATIVE_PASS + NATIVE_FAIL))
        if [[ $NATIVE_FAIL -eq 0 ]]; then
            echo -e "Native:      ${GREEN}$NATIVE_PASS/$total PASS${NC}"
        else
            echo -e "Native:      ${GREEN}$NATIVE_PASS${NC}/${RED}$NATIVE_FAIL${NC} (total: $total)"
        fi
    fi

    if $BUILD_ANDROID; then
        local total=$((ANDROID_PASS + ANDROID_FAIL))
        if [[ $total -gt 0 ]]; then
            if [[ $ANDROID_FAIL -eq 0 ]]; then
                echo -e "Android:     ${GREEN}$ANDROID_PASS/$total PASS${NC}"
            else
                echo -e "Android:     ${GREEN}$ANDROID_PASS${NC}/${RED}$ANDROID_FAIL${NC} (total: $total)"
            fi
        fi
    fi

    if $BUILD_IOS; then
        local total=$((IOS_PASS + IOS_FAIL))
        if [[ $total -gt 0 ]]; then
            if [[ $IOS_FAIL -eq 0 ]]; then
                echo -e "iOS:         ${GREEN}$IOS_PASS/$total PASS${NC}"
            else
                echo -e "iOS:         ${GREEN}$IOS_PASS${NC}/${RED}$IOS_FAIL${NC} (total: $total)"
            fi
        fi
    fi

    if $BUILD_IOS_SIM; then
        local total=$((IOS_SIM_PASS + IOS_SIM_FAIL))
        if [[ $total -gt 0 ]]; then
            if [[ $IOS_SIM_FAIL -eq 0 ]]; then
                echo -e "iOS Sim:     ${GREEN}$IOS_SIM_PASS/$total PASS${NC}"
            else
                echo -e "iOS Sim:     ${GREEN}$IOS_SIM_PASS${NC}/${RED}$IOS_SIM_FAIL${NC} (total: $total)"
            fi
        fi
    fi

    if $BUILD_WASM; then
        local total=$((WASM_PASS + WASM_FAIL))
        if [[ $total -gt 0 ]]; then
            if [[ $WASM_FAIL -eq 0 ]]; then
                echo -e "WASM:        ${GREEN}$WASM_PASS/$total PASS${NC}"
            else
                echo -e "WASM:        ${GREEN}$WASM_PASS${NC}/${RED}$WASM_FAIL${NC} (total: $total)"
            fi
        fi
    fi

    # Print failed programs
    echo ""
    if [[ ${#NATIVE_FAILED_PROGRAMS[@]} -gt 0 ]]; then
        echo -e "${RED}Native failures:${NC} ${NATIVE_FAILED_PROGRAMS[*]}"
    fi
    if [[ ${#ANDROID_FAILED_PROGRAMS[@]} -gt 0 ]]; then
        echo -e "${RED}Android failures:${NC} ${ANDROID_FAILED_PROGRAMS[*]}"
    fi
    if [[ ${#IOS_FAILED_PROGRAMS[@]} -gt 0 ]]; then
        echo -e "${RED}iOS failures:${NC} ${IOS_FAILED_PROGRAMS[*]}"
    fi
    if [[ ${#IOS_SIM_FAILED_PROGRAMS[@]} -gt 0 ]]; then
        echo -e "${RED}iOS Sim failures:${NC} ${IOS_SIM_FAILED_PROGRAMS[*]}"
    fi
    if [[ ${#WASM_FAILED_PROGRAMS[@]} -gt 0 ]]; then
        echo -e "${RED}WASM failures:${NC} ${WASM_FAILED_PROGRAMS[*]}"
    fi

    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════════${NC}"
}

# Parse arguments
if [[ $# -eq 0 ]]; then
    BUILD_NATIVE=true
fi

while [[ $# -gt 0 ]]; do
    case $1 in
        --native)
            BUILD_NATIVE=true
            shift
            ;;
        --android)
            BUILD_ANDROID=true
            shift
            ;;
        --ios)
            BUILD_IOS=true
            shift
            ;;
        --ios-sim)
            BUILD_IOS_SIM=true
            shift
            ;;
        --wasm)
            BUILD_WASM=true
            shift
            ;;
        --all)
            BUILD_NATIVE=true
            BUILD_ANDROID=true
            BUILD_IOS=true
            BUILD_IOS_SIM=true
            BUILD_WASM=true
            shift
            ;;
        --libs-only)
            LIBS_ONLY=true
            shift
            ;;
        --program)
            SPECIFIC_PROGRAM="$2"
            shift 2
            ;;
        --list)
            list_programs
            exit 0
            ;;
        --help|-h)
            print_usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            print_usage
            exit 1
            ;;
    esac
done

# Main execution
print_header

echo -e "${BLUE}Build targets:${NC}"
$BUILD_NATIVE && echo "  - Native (macOS)"
$BUILD_ANDROID && echo "  - Android ARM64"
$BUILD_IOS && echo "  - iOS ARM64"
$BUILD_IOS_SIM && echo "  - iOS Simulator ARM64"
$BUILD_WASM && echo "  - WebAssembly"
echo ""

START_TIME=$(date +%s)

if [[ -n "$SPECIFIC_PROGRAM" ]]; then
    # Build specific program
    program_dir="$PROGRAMS_DIR/$SPECIFIC_PROGRAM"
    if [[ -d "$program_dir" && -f "$program_dir/build.zig" ]]; then
        build_program "$program_dir"
    else
        echo -e "${RED}Error: Program '$SPECIFIC_PROGRAM' not found${NC}"
        exit 1
    fi
else
    # Build all programs
    for dir in "$PROGRAMS_DIR"/*/; do
        if [[ -f "$dir/build.zig" ]]; then
            name=$(basename "$dir")

            # Skip non-library programs if --libs-only
            if $LIBS_ONLY && [[ ! " ${LIBRARY_PROGRAMS[*]} " =~ " ${name} " ]]; then
                continue
            fi

            build_program "$dir"
        fi
    done
fi

END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

print_summary

echo -e "Build completed in ${BLUE}${DURATION}s${NC}"
