#!/bin/bash
set -e
cd "$(dirname "${BASH_SOURCE[0]}")"

QUEEN="./zig-out/bin/queen"
WORKER="./zig-out/bin/worker"
TASK_COUNT=10000000  # 10 million

# Fewer chunk sizes for faster testing
CHUNK_SIZES=(10000 50000 100000 500000)

cleanup() {
    pkill -9 -f "queen --test" 2>/dev/null || true
    pkill -9 -f "worker --queen" 2>/dev/null || true
    sleep 1
}

trap cleanup EXIT

echo ""
echo "╔══════════════════════════════════════════════════════════════════════╗"
echo "║  SATURATION BENCHMARK - 10 Million Variables                         ║"
echo "╚══════════════════════════════════════════════════════════════════════╝"
echo ""

best_throughput=0
best_chunk_size=0

for chunk_size in "${CHUNK_SIZES[@]}"; do
    echo ""
    echo "Testing chunk_size = $chunk_size ..."
    
    cleanup
    
    QUEEN_OUTPUT=$(mktemp)
    $QUEEN --test numeric_match --start 0 --end $TASK_COUNT --chunk $chunk_size > "$QUEEN_OUTPUT" 2>&1 &
    QUEEN_PID=$!
    
    sleep 3
    
    timeout 600 $WORKER --queen 127.0.0.1 --port 7777 > /dev/null 2>&1 &
    WORKER_PID=$!
    
    wait $WORKER_PID 2>/dev/null || true
    sleep 2
    
    kill $QUEEN_PID 2>/dev/null || true
    wait $QUEEN_PID 2>/dev/null || true
    
    throughput=$(grep -oP 'Throughput: \K[0-9]+' "$QUEEN_OUTPUT" | tail -1 || echo "0")
    elapsed=$(grep -oP 'Elapsed time: \K[0-9.]+' "$QUEEN_OUTPUT" | tail -1 || echo "0")
    
    echo "  chunk_size=$chunk_size: ${throughput} tasks/sec (${elapsed}s)"
    
    if [ "$throughput" -gt "$best_throughput" ]; then
        best_throughput=$throughput
        best_chunk_size=$chunk_size
    fi
    
    rm -f "$QUEEN_OUTPUT"
done

echo ""
echo "╔══════════════════════════════════════════════════════════════════════╗"
echo "║  RESULTS                                                              ║"
echo "╠══════════════════════════════════════════════════════════════════════╣"
printf "║  Best chunk_size: %-52s║\n" "$best_chunk_size"
printf "║  Best throughput: %-52s║\n" "$best_throughput tasks/sec"
echo "╚══════════════════════════════════════════════════════════════════════╝"
