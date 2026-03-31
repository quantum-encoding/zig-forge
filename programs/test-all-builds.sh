#!/bin/bash
#
# Quantum Zig Forge - Build Tester
# Tests all programs against the current Zig version
#
# Usage: ./test-all-builds.sh [--verbose] [--cross]
#   --verbose  Show error details for failed builds
#   --cross    Also test cross-compilation (macOS, Android)
#

# Don't exit on error - we want to continue testing all programs
set +e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
ZIG_VERSION=$(zig version 2>/dev/null || echo "unknown")
LOG_DIR="${SCRIPT_DIR}/build-logs"
LOG_FILE="${LOG_DIR}/build_${TIMESTAMP}.log"
SUMMARY_FILE="${LOG_DIR}/build_${TIMESTAMP}_summary.txt"

VERBOSE=false
CROSS_COMPILE=false
for arg in "$@"; do
    case "$arg" in
        --verbose) VERBOSE=true ;;
        --cross) CROSS_COMPILE=true ;;
    esac
done

# Create log directory
mkdir -p "$LOG_DIR"

# Colors for terminal output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Counters
PASSED=0
FAILED=0
SKIPPED=0
TOTAL=0

# Cross-compile counters
CROSS_MACOS_PASSED=0
CROSS_MACOS_FAILED=0
CROSS_ANDROID_PASSED=0
CROSS_ANDROID_FAILED=0

# Arrays to track results
declare -a PASSED_PROGRAMS
declare -a FAILED_PROGRAMS
declare -a SKIPPED_PROGRAMS
declare -a CROSS_MACOS_PASSED_PROGRAMS
declare -a CROSS_MACOS_FAILED_PROGRAMS
declare -a CROSS_ANDROID_PASSED_PROGRAMS
declare -a CROSS_ANDROID_FAILED_PROGRAMS

echo "========================================================"
echo "  Quantum Zig Forge - Build Tester"
echo "========================================================"
echo "Zig Version: $ZIG_VERSION"
echo "Timestamp:   $TIMESTAMP"
echo "Log File:    $LOG_FILE"
echo "========================================================"
echo ""

# Write header to log file
{
    echo "========================================================"
    echo "  Quantum Zig Forge - Build Test Results"
    echo "========================================================"
    echo "Zig Version: $ZIG_VERSION"
    echo "Test Date:   $(date)"
    echo "Host:        $(uname -a)"
    echo "========================================================"
    echo ""
} > "$LOG_FILE"

# Function to test a single program
test_program() {
    local prog_dir="$1"
    local prog_name=$(basename "$prog_dir")

    # Skip non-directories and special entries
    if [[ ! -d "$prog_dir" ]]; then
        return
    fi

    # Skip if no build.zig
    if [[ ! -f "$prog_dir/build.zig" ]]; then
        echo -e "${YELLOW}[SKIP]${NC} $prog_name (no build.zig)"
        echo "[SKIP] $prog_name - no build.zig found" >> "$LOG_FILE"
        SKIPPED_PROGRAMS+=("$prog_name")
        ((SKIPPED++))
        return
    fi

    ((TOTAL++))

    printf "Testing %-40s " "$prog_name..."

    # Run build and capture output
    local build_output
    local build_status

    {
        echo "--------------------------------------------------------"
        echo "Program: $prog_name"
        echo "Path:    $prog_dir"
        echo "Time:    $(date +%H:%M:%S)"
        echo "--------------------------------------------------------"
    } >> "$LOG_FILE"

    # Run the build with timeout
    build_output=$(cd "$prog_dir" && timeout 120 zig build 2>&1) || build_status=$?
    build_status=${build_status:-0}

    # Check for errors in output (some builds return 0 but have errors)
    if [[ $build_status -eq 0 ]] && ! echo "$build_output" | grep -q "error:"; then
        echo -e "${GREEN}[PASS]${NC}"
        echo "[PASS]" >> "$LOG_FILE"
        PASSED_PROGRAMS+=("$prog_name")
        ((PASSED++))
    else
        echo -e "${RED}[FAIL]${NC}"
        echo "[FAIL]" >> "$LOG_FILE"
        FAILED_PROGRAMS+=("$prog_name")
        ((FAILED++))
    fi

    # Log output (filter out libwarden noise for cleaner logs)
    if [[ -n "$build_output" ]]; then
        echo "$build_output" | grep -v "libwarden.so" | grep -v "Guardian Shield" >> "$LOG_FILE" 2>/dev/null || true
    fi

    if $VERBOSE && [[ $build_status -ne 0 ]]; then
        echo "$build_output" | grep "error:" | head -5
    fi

    echo "" >> "$LOG_FILE"
}

# Function to test cross-compilation for a single program
test_cross_compile() {
    local prog_dir="$1"
    local target="$2"
    local target_name="$3"
    local prog_name=$(basename "$prog_dir")

    # Skip if no build.zig
    if [[ ! -f "$prog_dir/build.zig" ]]; then
        return
    fi

    printf "  ├─ %-12s " "$target_name..."

    # Run build with target
    local build_output
    local build_status

    build_output=$(cd "$prog_dir" && timeout 120 zig build -Dtarget="$target" 2>&1) || build_status=$?
    build_status=${build_status:-0}

    # Check for errors
    if [[ $build_status -eq 0 ]] && ! echo "$build_output" | grep -q "error:"; then
        echo -e "${GREEN}[PASS]${NC}"
        echo "  [PASS] $target_name" >> "$LOG_FILE"
        if [[ "$target_name" == "macOS" ]]; then
            CROSS_MACOS_PASSED_PROGRAMS+=("$prog_name")
            ((CROSS_MACOS_PASSED++))
        else
            CROSS_ANDROID_PASSED_PROGRAMS+=("$prog_name")
            ((CROSS_ANDROID_PASSED++))
        fi
    else
        echo -e "${RED}[FAIL]${NC}"
        echo "  [FAIL] $target_name" >> "$LOG_FILE"
        if [[ "$target_name" == "macOS" ]]; then
            CROSS_MACOS_FAILED_PROGRAMS+=("$prog_name")
            ((CROSS_MACOS_FAILED++))
        else
            CROSS_ANDROID_FAILED_PROGRAMS+=("$prog_name")
            ((CROSS_ANDROID_FAILED++))
        fi

        if $VERBOSE; then
            echo "$build_output" | grep "error:" | head -3 | sed 's/^/      /'
        fi
    fi
}

# Get all program directories
cd "$SCRIPT_DIR"

for prog in */; do
    # Skip special directories and programs with their own build systems
    case "$prog" in
        build-logs/|.zig-cache/|zig-out/)
            # Build artifacts
            continue
            ;;
        zig_core_utils/)
            # Has its own master build script
            echo -e "${YELLOW}[SKIP]${NC} zig_core_utils (has own build system - run ./build-all.sh)"
            echo "[SKIP] zig_core_utils - has own build system" >> "$LOG_FILE"
            SKIPPED_PROGRAMS+=("zig_core_utils")
            ((SKIPPED++))
            continue
            ;;
        guardian_shield/)
            # Complex multi-component project
            echo -e "${YELLOW}[SKIP]${NC} guardian_shield (complex multi-component)"
            echo "[SKIP] guardian_shield - complex multi-component project" >> "$LOG_FILE"
            SKIPPED_PROGRAMS+=("guardian_shield")
            ((SKIPPED++))
            continue
            ;;
        *\[TODO\]/)
            # Skip TODO projects
            continue
            ;;
    esac

    test_program "${SCRIPT_DIR}/${prog%/}"
done

# Cross-compilation tests (only for programs that passed native build)
if $CROSS_COMPILE && [[ ${#PASSED_PROGRAMS[@]} -gt 0 ]]; then
    echo ""
    echo "========================================================"
    echo "  Cross-Compilation Tests"
    echo "========================================================"
    echo ""

    {
        echo ""
        echo "========================================================"
        echo "  Cross-Compilation Tests"
        echo "========================================================"
    } >> "$LOG_FILE"

    for prog_name in "${PASSED_PROGRAMS[@]}"; do
        prog_dir="${SCRIPT_DIR}/${prog_name}"

        echo "Testing $prog_name cross-compilation..."
        echo "Cross-compile: $prog_name" >> "$LOG_FILE"

        # Test macOS (aarch64-macos)
        test_cross_compile "$prog_dir" "aarch64-macos" "macOS"

        # Test Android (aarch64-linux-android)
        test_cross_compile "$prog_dir" "aarch64-linux-android" "Android"

        echo ""
    done
fi

# Print summary
echo ""
echo "========================================================"
echo "  Build Summary"
echo "========================================================"
echo -e "Total:   $TOTAL programs tested"
echo -e "${GREEN}Passed:${NC}  $PASSED"
echo -e "${RED}Failed:${NC}  $FAILED"
echo -e "${YELLOW}Skipped:${NC} $SKIPPED"

if $CROSS_COMPILE; then
    echo ""
    echo "Cross-compilation (of $PASSED native-passing programs):"
    echo -e "  macOS:   ${GREEN}$CROSS_MACOS_PASSED${NC} passed, ${RED}$CROSS_MACOS_FAILED${NC} failed"
    echo -e "  Android: ${GREEN}$CROSS_ANDROID_PASSED${NC} passed, ${RED}$CROSS_ANDROID_FAILED${NC} failed"
fi
echo "========================================================"

# Write summary file
{
    echo "========================================================"
    echo "  Build Summary - Zig $ZIG_VERSION"
    echo "  $(date)"
    echo "========================================================"
    echo ""
    echo "RESULTS: $PASSED passed, $FAILED failed, $SKIPPED skipped (of $TOTAL)"
    echo ""

    if [[ ${#PASSED_PROGRAMS[@]} -gt 0 ]]; then
        echo "PASSED (${#PASSED_PROGRAMS[@]}):"
        printf '  - %s\n' "${PASSED_PROGRAMS[@]}"
        echo ""
    fi

    if [[ ${#FAILED_PROGRAMS[@]} -gt 0 ]]; then
        echo "FAILED (${#FAILED_PROGRAMS[@]}):"
        printf '  - %s\n' "${FAILED_PROGRAMS[@]}"
        echo ""
    fi

    if [[ ${#SKIPPED_PROGRAMS[@]} -gt 0 ]]; then
        echo "SKIPPED (${#SKIPPED_PROGRAMS[@]}):"
        printf '  - %s\n' "${SKIPPED_PROGRAMS[@]}"
        echo ""
    fi

    if $CROSS_COMPILE; then
        echo "========================================================"
        echo "  Cross-Compilation Results"
        echo "========================================================"
        echo ""
        echo "macOS (aarch64-macos): $CROSS_MACOS_PASSED passed, $CROSS_MACOS_FAILED failed"
        if [[ ${#CROSS_MACOS_PASSED_PROGRAMS[@]} -gt 0 ]]; then
            echo "  Passed:"
            printf '    - %s\n' "${CROSS_MACOS_PASSED_PROGRAMS[@]}"
        fi
        if [[ ${#CROSS_MACOS_FAILED_PROGRAMS[@]} -gt 0 ]]; then
            echo "  Failed:"
            printf '    - %s\n' "${CROSS_MACOS_FAILED_PROGRAMS[@]}"
        fi
        echo ""
        echo "Android (aarch64-linux-android): $CROSS_ANDROID_PASSED passed, $CROSS_ANDROID_FAILED failed"
        if [[ ${#CROSS_ANDROID_PASSED_PROGRAMS[@]} -gt 0 ]]; then
            echo "  Passed:"
            printf '    - %s\n' "${CROSS_ANDROID_PASSED_PROGRAMS[@]}"
        fi
        if [[ ${#CROSS_ANDROID_FAILED_PROGRAMS[@]} -gt 0 ]]; then
            echo "  Failed:"
            printf '    - %s\n' "${CROSS_ANDROID_FAILED_PROGRAMS[@]}"
        fi
        echo ""
    fi
} > "$SUMMARY_FILE"

# Append summary to main log
cat "$SUMMARY_FILE" >> "$LOG_FILE"

echo ""
echo "Full log:    $LOG_FILE"
echo "Summary:     $SUMMARY_FILE"
echo ""

# List failed programs if any
if [[ ${#FAILED_PROGRAMS[@]} -gt 0 ]]; then
    echo -e "${RED}Failed programs:${NC}"
    printf '  - %s\n' "${FAILED_PROGRAMS[@]}"
    echo ""
    echo "Run with --verbose for error details, or check the log file."
fi

# Exit with appropriate code
if [[ $FAILED -gt 0 ]]; then
    exit 1
fi
exit 0
