#!/bin/bash
#
# Saturation Benchmark Script
# Tests various chunk_size configurations to find optimal throughput
# for 10 million variable exhaustive search
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Build first
echo "Building..."
/usr/local/zig/zig build 2>/dev/null

QUEEN="./zig-out/bin/queen"
WORKER="./zig-out/bin/worker"

# Test parameters
TASK_COUNT=10000000  # 10 million
CHUNK_SIZES=(1000 5000 10000 25000 50000 100000 250000 500000)
RESULTS_FILE="benchmark_results.txt"

# Clean up any existing processes
cleanup() {
    pkill -9 -f "queen --test" 2>/dev/null || true
    pkill -9 -f "worker --queen" 2>/dev/null || true
    sleep 1
}

trap cleanup EXIT

echo ""
echo "╔══════════════════════════════════════════════════════════════════════╗"
echo "║  SATURATION BENCHMARK - Finding Optimal Parameters                   ║"
echo "╠══════════════════════════════════════════════════════════════════════╣"
echo "║  Task Count: 10,000,000                                              ║"
echo "║  Test Function: numeric_match                                        ║"
echo "║  Secret Number: 8,734,501                                            ║"
echo "╚══════════════════════════════════════════════════════════════════════╝"
echo ""

# Initialize results file
echo "Saturation Benchmark Results - $(date)" > "$RESULTS_FILE"
echo "Task Count: $TASK_COUNT" >> "$RESULTS_FILE"
echo "======================================" >> "$RESULTS_FILE"
echo "" >> "$RESULTS_FILE"

best_throughput=0
best_chunk_size=0

for chunk_size in "${CHUNK_SIZES[@]}"; do
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "Testing chunk_size = $chunk_size"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    cleanup

    # Start queen in background and capture output
    QUEEN_OUTPUT=$(mktemp)
    $QUEEN --test numeric_match --start 0 --end $TASK_COUNT --chunk $chunk_size > "$QUEEN_OUTPUT" 2>&1 &
    QUEEN_PID=$!

    sleep 2

    # Start worker
    timeout 600 $WORKER --queen 127.0.0.1 --port 7777 2>&1 &
    WORKER_PID=$!

    # Wait for worker to complete
    wait $WORKER_PID 2>/dev/null || true

    # Give queen a moment to finalize
    sleep 2

    # Kill queen gracefully
    kill $QUEEN_PID 2>/dev/null || true
    wait $QUEEN_PID 2>/dev/null || true

    # Extract throughput from queen output
    throughput=$(grep -oP 'Throughput: \K[0-9]+' "$QUEEN_OUTPUT" | tail -1 || echo "0")
    elapsed=$(grep -oP 'Elapsed time: \K[0-9.]+' "$QUEEN_OUTPUT" | tail -1 || echo "0")
    verification=$(grep -c "SUCCESS" "$QUEEN_OUTPUT" || echo "0")

    echo ""
    echo "Results for chunk_size=$chunk_size:"
    echo "  Throughput: $throughput tasks/sec"
    echo "  Elapsed: ${elapsed}s"
    echo "  Verification: $([ "$verification" -gt 0 ] && echo "PASS" || echo "FAIL")"

    # Log to results file
    echo "chunk_size=$chunk_size: ${throughput} tasks/sec (${elapsed}s)" >> "$RESULTS_FILE"

    # Track best
    if [ "$throughput" -gt "$best_throughput" ]; then
        best_throughput=$throughput
        best_chunk_size=$chunk_size
    fi

    rm -f "$QUEEN_OUTPUT"
done

echo ""
echo "╔══════════════════════════════════════════════════════════════════════╗"
echo "║  BENCHMARK COMPLETE                                                   ║"
echo "╠══════════════════════════════════════════════════════════════════════╣"
printf "║  Best chunk_size: %-50s  ║\n" "$best_chunk_size"
printf "║  Best throughput: %-50s  ║\n" "$best_throughput tasks/sec"
echo "╚══════════════════════════════════════════════════════════════════════╝"
echo ""

# Append summary
echo "" >> "$RESULTS_FILE"
echo "======================================" >> "$RESULTS_FILE"
echo "BEST: chunk_size=$best_chunk_size @ $best_throughput tasks/sec" >> "$RESULTS_FILE"

echo "Results saved to: $RESULTS_FILE"
