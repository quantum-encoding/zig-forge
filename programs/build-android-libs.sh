#!/bin/bash
# Build all Zig libraries for Android (aarch64-linux-android).
# Usage: ./build-android-libs.sh
#
# Mirror of build-ios-libs.sh — same lib set, same per-program directory
# layout, same `zig build-lib` invocation shape. Differences:
#
#   * Target: `aarch64-linux-android` (Zig 0.16 syntax) instead of
#     `aarch64-ios`. Zig bundles Bionic libc headers so we don't need
#     to thread the NDK sysroot through for static-lib output — the
#     NDK toolchain comes into play at link time, which the downstream
#     Tauri/cargo-ndk build handles.
#
#   * Output: per-program `<program>/zig-out/lib/android-arm64/` to
#     match what `src-tauri/build.rs`'s Android branch expects today.
#     (Could be moved to a central `programs/android-libs/android-arm64/`
#     to mirror the iOS central layout — see commit-message TODO.)
#
#   * NO libtool repack step: Android uses lld, which accepts Zig's
#     2-byte archive member alignment. The repack-for-xcode.sh dance
#     is an Apple ld-prime quirk only.

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ZIG="${ZIG:-zig}"
ANDROID_TARGET="aarch64-linux-android"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${CYAN}=== Building Zig Libraries for Android ===${NC}"
echo -e "Zig version: $($ZIG version)"
echo -e "Target: $ANDROID_TARGET"
echo ""

SUCCESS=0
FAILED=0

# Build a single lib for android-arm64.
#
# Output goes to `<program>/zig-out/lib/android-arm64/lib<name>.a` to
# match `src-tauri/build.rs`'s expected path on Android. If we ever
# move to a central layout (like iOS's `programs/ios-libs/`), update
# both this script's OUTPUT_DIR and the build.rs lib_path helper.
build_lib() {
    local lib_name=$1
    local dir=$2
    local source=$3
    local full_dir="$SCRIPT_DIR/$dir"
    local output_dir="$full_dir/zig-out/lib/android-arm64"

    if [ ! -d "$full_dir" ]; then
        echo -e "${YELLOW}  Skipping $lib_name - directory not found: $dir${NC}"
        return 1
    fi

    if [ ! -f "$full_dir/$source" ]; then
        echo -e "${YELLOW}  Skipping $lib_name - source not found: $source${NC}"
        return 1
    fi

    mkdir -p "$output_dir"

    echo -e "${CYAN}Building $lib_name...${NC}"
    echo -e "  → Android arm64 ($ANDROID_TARGET)"

    # Use ReleaseSmall + strip — same rationale as the iOS build:
    # avoid linking `std.debug` machinery that pulls platform-specific
    # APIs we don't need on Android either.
    if $ZIG build-lib \
        -target $ANDROID_TARGET \
        -OReleaseSmall \
        --name "$lib_name" \
        -static \
        -lc \
        -fstrip \
        "$full_dir/$source" \
        -femit-bin="$output_dir/lib${lib_name}.a" \
        2>&1; then
        echo -e "${GREEN}  ✓ Android arm64${NC}"
        return 0
    else
        echo -e "${RED}  ✗ Android arm64 failed${NC}"
        return 1
    fi
}

# Build each library — same list as build-ios-libs.sh.
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
build_lib "zigpdf" "zig_pdf_generator" "src/ffi.zig" && ((SUCCESS++)) || ((FAILED++))

# =============================================================================
# Programs with their own `zig build android` step.
#
# financial_engine and mempool_sniffer each define an `android` step
# in their `build.zig` that produces multiple artifacts in
# `zig-out/lib/android-arm64/`. We invoke those native steps rather
# than hand-rolling the build flags here, because:
#
#   * financial_engine's android step produces THREE libs in one shot:
#     libfinancial_core.a, libfinancial_engine.a, libcoinbase_fix.a.
#     `libfinancial_engine` and `libcoinbase_fix` are Android-only
#     (downstream `src-tauri/build.rs` links them on Android but not
#     iOS/macOS — they require ZMQ/mbedTLS which the build.zig stubs
#     out under the android target).
#
#   * mempool_sniffer's android step produces libmempool_sniffer_core.a
#     and uses the poll backend (io_uring isn't available on Android).
#
# The native steps overwrite our build_lib's libfinancial_core.a
# above with their own version; same name, equivalent contents,
# Android-specific build flags applied.
# =============================================================================

native_android_step() {
    local dir=$1
    local full_dir="$SCRIPT_DIR/$dir"

    if [ ! -d "$full_dir" ]; then
        echo -e "${YELLOW}  Skipping native android step in $dir — directory not found${NC}"
        return 1
    fi

    echo -e "${CYAN}Native zig build android in $dir...${NC}"
    if (cd "$full_dir" && $ZIG build android) 2>&1; then
        echo -e "${GREEN}  ✓ $dir android step${NC}"
        return 0
    else
        echo -e "${RED}  ✗ $dir android step failed${NC}"
        return 1
    fi
}

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
native_android_step "financial_engine" && ((SUCCESS++)) || ((FAILED++))

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
native_android_step "mempool_sniffer" && ((SUCCESS++)) || ((FAILED++))

# zsss lives under zig_core_utils/, not programs/. The iOS build
# skips it with a "directory not found" warning because of the same
# path mismatch — Android src-tauri/libs/android-arm64/libzsss.a is
# already present in the repo so we don't need to rebuild it here.
# If/when zsss is rebuilt for Android, copy the resulting .a into
# `src-tauri/libs/android-arm64/` (the path src-tauri/build.rs uses
# for zsss specifically, separate from the other Zig FFI libs).
#
# signal_broadcast is gated on the `zig-ffi` Cargo feature which
# isn't in the default feature set — not built here. Enable that
# feature when ZMQ dependencies are wired up Android-side.

echo ""
echo -e "${CYAN}=== Build Summary ===${NC}"
echo -e "${GREEN}Succeeded: $SUCCESS${NC}"
echo -e "${RED}Failed: $FAILED${NC}"
echo ""
echo -e "Libraries output to per-program:"
echo -e "  ${CYAN}<program>/zig-out/lib/android-arm64/lib<name>.a${NC}"
echo ""

# Quick listing — find all .a files we just emitted.
echo -e "${CYAN}Built libraries:${NC}"
find "$SCRIPT_DIR" -path "*/zig-out/lib/android-arm64/*.a" 2>/dev/null | sort | while read p; do
    echo "  $(ls -lh "$p" | awk '{print $5}')  $p"
done
