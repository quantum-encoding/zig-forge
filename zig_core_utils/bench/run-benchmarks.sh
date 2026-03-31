#!/bin/bash
# Benchmark runner for zig core utils vs GNU coreutils
# Usage: ./run-benchmarks.sh [tool] [iterations]

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(dirname "$SCRIPT_DIR")"
RESULTS_DIR="$SCRIPT_DIR/results"
ITERATIONS=${2:-10}
WARMUP=3

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Timestamp for results
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

mkdir -p "$RESULTS_DIR"

# Helper: run benchmark and capture timing
bench() {
    local name="$1"
    local cmd="$2"
    local iterations="$3"

    # Warmup
    for ((i=0; i<WARMUP; i++)); do
        eval "$cmd" > /dev/null 2>&1 || true
    done

    # Actual benchmark
    local total=0
    local times=()

    for ((i=0; i<iterations; i++)); do
        local start=$(date +%s%N)
        eval "$cmd" > /dev/null 2>&1 || true
        local end=$(date +%s%N)
        local elapsed=$(( (end - start) / 1000000 )) # Convert to ms
        times+=($elapsed)
        total=$((total + elapsed))
    done

    # Calculate stats
    local avg=$((total / iterations))

    # Sort for median
    IFS=$'\n' sorted=($(sort -n <<<"${times[*]}")); unset IFS
    local mid=$((iterations / 2))
    local median=${sorted[$mid]}

    # Min/Max
    local min=${sorted[0]}
    local max=${sorted[$((iterations - 1))]}

    echo "$name,$avg,$median,$min,$max"
}

# Benchmark: mkdir
bench_mkdir() {
    echo -e "${BLUE}=== Benchmarking mkdir ===${NC}"

    local zmkdir="$BASE_DIR/zmkdir/zig-out/bin/zmkdir"

    if [[ ! -x "$zmkdir" ]]; then
        echo -e "${YELLOW}Building zmkdir...${NC}"
        (cd "$BASE_DIR/zmkdir" && zig build -Doptimize=ReleaseFast)
    fi

    local result_file="$RESULTS_DIR/mkdir_${TIMESTAMP}.csv"
    echo "tool,avg_ms,median_ms,min_ms,max_ms" > "$result_file"

    # Test: Create single directory
    echo "Test: Single directory creation"
    rm -rf /tmp/bench_mkdir_* 2>/dev/null || true

    local gnu_result=$(bench "gnu_mkdir_single" "rm -rf /tmp/bench_mkdir_gnu && mkdir /tmp/bench_mkdir_gnu" $ITERATIONS)
    local zig_result=$(bench "zmkdir_single" "rm -rf /tmp/bench_mkdir_zig && $zmkdir /tmp/bench_mkdir_zig" $ITERATIONS)

    echo "$gnu_result" >> "$result_file"
    echo "$zig_result" >> "$result_file"

    # Test: Create nested directories (-p)
    echo "Test: Nested directory creation (-p)"

    gnu_result=$(bench "gnu_mkdir_nested" "rm -rf /tmp/bench_mkdir_gnu && mkdir -p /tmp/bench_mkdir_gnu/a/b/c/d/e/f/g/h/i/j" $ITERATIONS)
    zig_result=$(bench "zmkdir_nested" "rm -rf /tmp/bench_mkdir_zig && $zmkdir -p /tmp/bench_mkdir_zig/a/b/c/d/e/f/g/h/i/j" $ITERATIONS)

    echo "$gnu_result" >> "$result_file"
    echo "$zig_result" >> "$result_file"

    # Test: Create many directories
    echo "Test: Many directories (100)"

    gnu_result=$(bench "gnu_mkdir_many" "rm -rf /tmp/bench_mkdir_gnu_* && for i in {1..100}; do mkdir /tmp/bench_mkdir_gnu_\$i; done" $ITERATIONS)
    zig_result=$(bench "zmkdir_many" "rm -rf /tmp/bench_mkdir_zig_* && $zmkdir /tmp/bench_mkdir_zig_{1..100}" $ITERATIONS)

    echo "$gnu_result" >> "$result_file"
    echo "$zig_result" >> "$result_file"

    # Cleanup
    rm -rf /tmp/bench_mkdir_* 2>/dev/null || true

    echo -e "${GREEN}Results saved to: $result_file${NC}"
    print_results "$result_file"
}

# Benchmark: wc
bench_wc() {
    echo -e "${BLUE}=== Benchmarking wc ===${NC}"

    local zwc="$BASE_DIR/zwc/zig-out/bin/zwc-bench"

    if [[ ! -x "$zwc" ]]; then
        echo -e "${YELLOW}Building zwc...${NC}"
        (cd "$BASE_DIR/zwc" && zig build bench)
    fi

    local result_file="$RESULTS_DIR/wc_${TIMESTAMP}.csv"
    echo "tool,avg_ms,median_ms,min_ms,max_ms" > "$result_file"

    # Create test files
    echo "Creating test files..."
    head -c 1M /dev/urandom | base64 > /tmp/bench_wc_1m.txt
    head -c 10M /dev/urandom | base64 > /tmp/bench_wc_10m.txt
    head -c 50M /dev/urandom | base64 > /tmp/bench_wc_50m.txt

    # Test: 1MB file
    echo "Test: 1MB file"
    local gnu_result=$(bench "gnu_wc_1m" "wc /tmp/bench_wc_1m.txt" $ITERATIONS)
    local zig_result=$(bench "zwc_1m" "$zwc /tmp/bench_wc_1m.txt" $ITERATIONS)
    echo "$gnu_result" >> "$result_file"
    echo "$zig_result" >> "$result_file"

    # Test: 10MB file
    echo "Test: 10MB file"
    gnu_result=$(bench "gnu_wc_10m" "wc /tmp/bench_wc_10m.txt" $ITERATIONS)
    zig_result=$(bench "zwc_10m" "$zwc /tmp/bench_wc_10m.txt" $ITERATIONS)
    echo "$gnu_result" >> "$result_file"
    echo "$zig_result" >> "$result_file"

    # Test: 50MB file
    echo "Test: 50MB file"
    gnu_result=$(bench "gnu_wc_50m" "wc /tmp/bench_wc_50m.txt" $ITERATIONS)
    zig_result=$(bench "zwc_50m" "$zwc /tmp/bench_wc_50m.txt" $ITERATIONS)
    echo "$gnu_result" >> "$result_file"
    echo "$zig_result" >> "$result_file"

    # Test: Lines only (-l) - 50MB
    echo "Test: Lines only (-l) 50MB"
    gnu_result=$(bench "gnu_wc_lines" "wc -l /tmp/bench_wc_50m.txt" $ITERATIONS)
    zig_result=$(bench "zwc_lines" "$zwc -l /tmp/bench_wc_50m.txt" $ITERATIONS)
    echo "$gnu_result" >> "$result_file"
    echo "$zig_result" >> "$result_file"

    # Cleanup
    rm -f /tmp/bench_wc_*.txt

    echo -e "${GREEN}Results saved to: $result_file${NC}"
    print_results "$result_file"
}

# Benchmark: rmdir
bench_rmdir() {
    echo -e "${BLUE}=== Benchmarking rmdir ===${NC}"

    local zrmdir="$BASE_DIR/zrmdir/zig-out/bin/zrmdir"

    if [[ ! -x "$zrmdir" ]]; then
        echo -e "${YELLOW}Building zrmdir...${NC}"
        (cd "$BASE_DIR/zrmdir" && zig build -Doptimize=ReleaseFast) || {
            echo -e "${RED}zrmdir not built yet, skipping${NC}"
            return
        }
    fi

    local result_file="$RESULTS_DIR/rmdir_${TIMESTAMP}.csv"
    echo "tool,avg_ms,median_ms,min_ms,max_ms" > "$result_file"

    # Test: Remove single directory
    echo "Test: Single directory removal"

    local gnu_result=$(bench "gnu_rmdir_single" "mkdir -p /tmp/bench_rmdir_gnu && rmdir /tmp/bench_rmdir_gnu" $ITERATIONS)
    local zig_result=$(bench "zrmdir_single" "mkdir -p /tmp/bench_rmdir_zig && $zrmdir /tmp/bench_rmdir_zig" $ITERATIONS)

    echo "$gnu_result" >> "$result_file"
    echo "$zig_result" >> "$result_file"

    # Test: Remove nested directories (-p)
    echo "Test: Nested directory removal (-p)"

    gnu_result=$(bench "gnu_rmdir_nested" "mkdir -p /tmp/bench_rmdir_gnu/a/b/c/d/e && rmdir -p /tmp/bench_rmdir_gnu/a/b/c/d/e" $ITERATIONS)
    zig_result=$(bench "zrmdir_nested" "mkdir -p /tmp/bench_rmdir_zig/a/b/c/d/e && $zrmdir -p /tmp/bench_rmdir_zig/a/b/c/d/e" $ITERATIONS)

    echo "$gnu_result" >> "$result_file"
    echo "$zig_result" >> "$result_file"

    # Cleanup
    rm -rf /tmp/bench_rmdir_* 2>/dev/null || true

    echo -e "${GREEN}Results saved to: $result_file${NC}"
    print_results "$result_file"
}

# Benchmark: touch
bench_touch() {
    echo -e "${BLUE}=== Benchmarking touch ===${NC}"

    local ztouch="$BASE_DIR/ztouch/zig-out/bin/ztouch"

    if [[ ! -x "$ztouch" ]]; then
        echo -e "${YELLOW}Building ztouch...${NC}"
        (cd "$BASE_DIR/ztouch" && zig build -Doptimize=ReleaseFast) || {
            echo -e "${RED}ztouch not built yet, skipping${NC}"
            return
        }
    fi

    local result_file="$RESULTS_DIR/touch_${TIMESTAMP}.csv"
    echo "tool,avg_ms,median_ms,min_ms,max_ms" > "$result_file"

    # Test: Create single file
    echo "Test: Create single file"
    rm -f /tmp/bench_touch_* 2>/dev/null || true

    local gnu_result=$(bench "gnu_touch_single" "rm -f /tmp/bench_touch_gnu && touch /tmp/bench_touch_gnu" $ITERATIONS)
    local zig_result=$(bench "ztouch_single" "rm -f /tmp/bench_touch_zig && $ztouch /tmp/bench_touch_zig" $ITERATIONS)

    echo "$gnu_result" >> "$result_file"
    echo "$zig_result" >> "$result_file"

    # Test: Create many files
    echo "Test: Create 100 files"

    gnu_result=$(bench "gnu_touch_many" "rm -f /tmp/bench_touch_gnu_* && touch /tmp/bench_touch_gnu_{1..100}" $ITERATIONS)
    zig_result=$(bench "ztouch_many" "rm -f /tmp/bench_touch_zig_* && $ztouch /tmp/bench_touch_zig_{1..100}" $ITERATIONS)

    echo "$gnu_result" >> "$result_file"
    echo "$zig_result" >> "$result_file"

    # Cleanup
    rm -f /tmp/bench_touch_* 2>/dev/null || true

    echo -e "${GREEN}Results saved to: $result_file${NC}"
    print_results "$result_file"
}

# Benchmark: rm
bench_rm() {
    echo -e "${BLUE}=== Benchmarking rm ===${NC}"

    local zrm="$BASE_DIR/zrm/zig-out/bin/zrm"

    if [[ ! -x "$zrm" ]]; then
        echo -e "${YELLOW}Building zrm...${NC}"
        (cd "$BASE_DIR/zrm" && zig build -Doptimize=ReleaseFast) || {
            echo -e "${RED}zrm not built yet, skipping${NC}"
            return
        }
    fi

    local result_file="$RESULTS_DIR/rm_${TIMESTAMP}.csv"
    echo "tool,avg_ms,median_ms,min_ms,max_ms" > "$result_file"

    # Test: Remove single file
    echo "Test: Remove single file"

    local gnu_result=$(bench "gnu_rm_single" "touch /tmp/bench_rm_gnu && rm /tmp/bench_rm_gnu" $ITERATIONS)
    local zig_result=$(bench "zrm_single" "touch /tmp/bench_rm_zig && $zrm /tmp/bench_rm_zig" $ITERATIONS)

    echo "$gnu_result" >> "$result_file"
    echo "$zig_result" >> "$result_file"

    # Test: Remove many files
    echo "Test: Remove 100 files"

    gnu_result=$(bench "gnu_rm_many" "touch /tmp/bench_rm_gnu_{1..100} && rm /tmp/bench_rm_gnu_{1..100}" $ITERATIONS)
    zig_result=$(bench "zrm_many" "touch /tmp/bench_rm_zig_{1..100} && $zrm /tmp/bench_rm_zig_{1..100}" $ITERATIONS)

    echo "$gnu_result" >> "$result_file"
    echo "$zig_result" >> "$result_file"

    # Cleanup
    rm -f /tmp/bench_rm_* 2>/dev/null || true

    echo -e "${GREEN}Results saved to: $result_file${NC}"
    print_results "$result_file"
}

# Benchmark: cp
bench_cp() {
    echo -e "${BLUE}=== Benchmarking cp ===${NC}"

    local zcp="$BASE_DIR/zcp/zig-out/bin/zcp"

    if [[ ! -x "$zcp" ]]; then
        echo -e "${YELLOW}Building zcp...${NC}"
        (cd "$BASE_DIR/zcp" && zig build -Doptimize=ReleaseFast) || {
            echo -e "${RED}zcp not built yet, skipping${NC}"
            return
        }
    fi

    local result_file="$RESULTS_DIR/cp_${TIMESTAMP}.csv"
    echo "tool,avg_ms,median_ms,min_ms,max_ms" > "$result_file"

    # Create test files
    echo "Creating test files..."
    head -c 1M /dev/urandom > /tmp/bench_cp_src_1m
    head -c 10M /dev/urandom > /tmp/bench_cp_src_10m
    head -c 100M /dev/urandom > /tmp/bench_cp_src_100m

    # Test: Copy 1MB file
    echo "Test: Copy 1MB file"
    local gnu_result=$(bench "gnu_cp_1m" "cp /tmp/bench_cp_src_1m /tmp/bench_cp_dst_gnu && rm /tmp/bench_cp_dst_gnu" $ITERATIONS)
    local zig_result=$(bench "zcp_1m" "$zcp /tmp/bench_cp_src_1m /tmp/bench_cp_dst_zig && rm /tmp/bench_cp_dst_zig" $ITERATIONS)
    echo "$gnu_result" >> "$result_file"
    echo "$zig_result" >> "$result_file"

    # Test: Copy 10MB file
    echo "Test: Copy 10MB file"
    gnu_result=$(bench "gnu_cp_10m" "cp /tmp/bench_cp_src_10m /tmp/bench_cp_dst_gnu && rm /tmp/bench_cp_dst_gnu" $ITERATIONS)
    zig_result=$(bench "zcp_10m" "$zcp /tmp/bench_cp_src_10m /tmp/bench_cp_dst_zig && rm /tmp/bench_cp_dst_zig" $ITERATIONS)
    echo "$gnu_result" >> "$result_file"
    echo "$zig_result" >> "$result_file"

    # Test: Copy 100MB file
    echo "Test: Copy 100MB file"
    gnu_result=$(bench "gnu_cp_100m" "cp /tmp/bench_cp_src_100m /tmp/bench_cp_dst_gnu && rm /tmp/bench_cp_dst_gnu" $ITERATIONS)
    zig_result=$(bench "zcp_100m" "$zcp /tmp/bench_cp_src_100m /tmp/bench_cp_dst_zig && rm /tmp/bench_cp_dst_zig" $ITERATIONS)
    echo "$gnu_result" >> "$result_file"
    echo "$zig_result" >> "$result_file"

    # Cleanup
    rm -f /tmp/bench_cp_* 2>/dev/null || true

    echo -e "${GREEN}Results saved to: $result_file${NC}"
    print_results "$result_file"
}

# Print results in a nice table
print_results() {
    local file="$1"
    echo ""
    echo -e "${YELLOW}Results:${NC}"
    echo "----------------------------------------"
    printf "%-20s %8s %8s %8s %8s\n" "Tool" "Avg(ms)" "Med(ms)" "Min(ms)" "Max(ms)"
    echo "----------------------------------------"

    tail -n +2 "$file" | while IFS=, read -r tool avg med min max; do
        printf "%-20s %8s %8s %8s %8s\n" "$tool" "$avg" "$med" "$min" "$max"
    done
    echo "----------------------------------------"

    # Calculate and show speedup
    echo ""
    echo -e "${YELLOW}Speedup (GNU/Zig):${NC}"

    local prev_avg=""
    local prev_tool=""
    tail -n +2 "$file" | while IFS=, read -r tool avg med min max; do
        if [[ "$prev_tool" == gnu_* && "$tool" == z* ]]; then
            if [[ "$avg" -gt 0 ]]; then
                local speedup=$(echo "scale=2; $prev_avg / $avg" | bc)
                local test_name="${prev_tool#gnu_}"
                if (( $(echo "$speedup > 1" | bc -l) )); then
                    echo -e "  $test_name: ${GREEN}${speedup}x faster${NC}"
                else
                    echo -e "  $test_name: ${RED}${speedup}x (slower)${NC}"
                fi
            fi
        fi
        prev_avg="$avg"
        prev_tool="$tool"
    done
    echo ""
}

# Run all benchmarks
bench_all() {
    echo -e "${BLUE}╔════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║   Zig Core Utils Benchmark Suite       ║${NC}"
    echo -e "${BLUE}║   Iterations: $ITERATIONS                         ║${NC}"
    echo -e "${BLUE}╚════════════════════════════════════════╝${NC}"
    echo ""

    bench_wc
    echo ""
    bench_mkdir
    echo ""
    bench_rmdir
    echo ""
    bench_touch
    echo ""
    bench_rm
    echo ""
    bench_cp

    echo -e "${GREEN}All benchmarks complete!${NC}"
    echo "Results saved to: $RESULTS_DIR"
}

# Main
case "${1:-all}" in
    mkdir)  bench_mkdir ;;
    wc)     bench_wc ;;
    rmdir)  bench_rmdir ;;
    touch)  bench_touch ;;
    rm)     bench_rm ;;
    cp)     bench_cp ;;
    all)    bench_all ;;
    *)
        echo "Usage: $0 [mkdir|wc|rmdir|touch|rm|cp|all] [iterations]"
        echo "  Default: all benchmarks with 10 iterations"
        exit 1
        ;;
esac
