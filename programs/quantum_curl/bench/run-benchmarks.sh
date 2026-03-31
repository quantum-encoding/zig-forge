#!/bin/bash
# Quantum Curl Benchmark Suite
# CI/CD Integration Script for Performance Regression Detection
#
# Usage:
#   ./run-benchmarks.sh              # Run benchmarks, output to console
#   ./run-benchmarks.sh --json       # Output JSON for CI/CD parsing
#   ./run-benchmarks.sh --ci         # CI mode: JSON output + regression check
#
# Environment Variables:
#   BENCH_BASELINE_FILE  - Path to baseline JSON for regression comparison
#   BENCH_THRESHOLD      - Regression threshold percentage (default: 10)
#   BENCH_TARGET_URL     - Target URL (default: local echo server)

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
QUANTUM_CURL_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$QUANTUM_CURL_DIR/zig-out/bin"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
ECHO_SERVER_PORT=${BENCH_ECHO_PORT:-8888}
TARGET_URL=${BENCH_TARGET_URL:-"http://127.0.0.1:$ECHO_SERVER_PORT/"}
BASELINE_FILE=${BENCH_BASELINE_FILE:-""}
THRESHOLD=${BENCH_THRESHOLD:-10}
OUTPUT_JSON=false
CI_MODE=false
RESULTS_DIR="$QUANTUM_CURL_DIR/bench/results"

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --json)
            OUTPUT_JSON=true
            shift
            ;;
        --ci)
            CI_MODE=true
            OUTPUT_JSON=true
            shift
            ;;
        --baseline)
            BASELINE_FILE="$2"
            shift 2
            ;;
        --threshold)
            THRESHOLD="$2"
            shift 2
            ;;
        --url)
            TARGET_URL="$2"
            shift 2
            ;;
        --help|-h)
            echo "Quantum Curl Benchmark Suite"
            echo ""
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --json              Output results as JSON"
            echo "  --ci                CI mode (JSON + regression check + exit code)"
            echo "  --baseline FILE     Compare against baseline JSON file"
            echo "  --threshold PCT     Regression threshold (default: 10)"
            echo "  --url URL           Target URL (default: local echo server)"
            echo "  -h, --help          Show this help"
            echo ""
            echo "Environment Variables:"
            echo "  BENCH_BASELINE_FILE - Path to baseline JSON"
            echo "  BENCH_THRESHOLD     - Regression threshold percentage"
            echo "  BENCH_TARGET_URL    - Target URL for benchmarks"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Build benchmarks
build_benchmarks() {
    if [[ "$OUTPUT_JSON" != "true" ]]; then
        echo -e "${BLUE}Building quantum-curl and benchmarks...${NC}"
    fi

    cd "$QUANTUM_CURL_DIR"
    zig build -Doptimize=ReleaseFast 2>/dev/null

    if [[ ! -f "$BUILD_DIR/quantum-curl" ]]; then
        echo -e "${RED}ERROR: quantum-curl binary not found${NC}" >&2
        exit 1
    fi

    if [[ ! -f "$BUILD_DIR/bench-echo-server" ]]; then
        echo -e "${RED}ERROR: bench-echo-server binary not found${NC}" >&2
        exit 1
    fi

    if [[ ! -f "$BUILD_DIR/bench-quantum-curl" ]]; then
        echo -e "${RED}ERROR: bench-quantum-curl binary not found${NC}" >&2
        exit 1
    fi
}

# Start echo server in background
start_echo_server() {
    if [[ "$OUTPUT_JSON" != "true" ]]; then
        echo -e "${BLUE}Starting echo server on port $ECHO_SERVER_PORT...${NC}"
    fi

    # Kill any existing echo server
    pkill -f "bench-echo-server" 2>/dev/null || true
    sleep 0.5

    "$BUILD_DIR/bench-echo-server" "$ECHO_SERVER_PORT" &>/dev/null &
    ECHO_SERVER_PID=$!

    # Wait for server to start
    sleep 1

    # Verify server is running
    if ! kill -0 $ECHO_SERVER_PID 2>/dev/null; then
        echo -e "${RED}ERROR: Echo server failed to start${NC}" >&2
        exit 1
    fi

    if [[ "$OUTPUT_JSON" != "true" ]]; then
        echo -e "${GREEN}Echo server started (PID: $ECHO_SERVER_PID)${NC}"
    fi
}

# Stop echo server
stop_echo_server() {
    if [[ -n "$ECHO_SERVER_PID" ]]; then
        kill $ECHO_SERVER_PID 2>/dev/null || true
        wait $ECHO_SERVER_PID 2>/dev/null || true
    fi
    pkill -f "bench-echo-server" 2>/dev/null || true
}

# Run benchmarks
run_benchmarks() {
    mkdir -p "$RESULTS_DIR"

    local timestamp=$(date +%Y%m%d_%H%M%S)
    local results_file="$RESULTS_DIR/benchmark_${timestamp}.json"

    local bench_args="--url $TARGET_URL"

    if [[ "$OUTPUT_JSON" == "true" ]]; then
        bench_args="$bench_args --json"
    fi

    if [[ -n "$BASELINE_FILE" && -f "$BASELINE_FILE" ]]; then
        bench_args="$bench_args --baseline $BASELINE_FILE --threshold $THRESHOLD"
    fi

    if [[ "$OUTPUT_JSON" == "true" ]]; then
        "$BUILD_DIR/bench-quantum-curl" $bench_args | tee "$results_file"
    else
        "$BUILD_DIR/bench-quantum-curl" $bench_args

        # Also save JSON version
        "$BUILD_DIR/bench-quantum-curl" --url "$TARGET_URL" --json > "$results_file"
    fi

    # In CI mode, create/update baseline if none exists
    if [[ "$CI_MODE" == "true" && -z "$BASELINE_FILE" ]]; then
        local baseline_path="$RESULTS_DIR/baseline.json"
        if [[ ! -f "$baseline_path" ]]; then
            if [[ "$OUTPUT_JSON" != "true" ]]; then
                echo -e "${YELLOW}Creating baseline: $baseline_path${NC}"
            fi
            cp "$results_file" "$baseline_path"
        fi
    fi

    echo "$results_file"
}

# Check for regression
check_regression() {
    local current_file="$1"
    local baseline_file="${BASELINE_FILE:-$RESULTS_DIR/baseline.json}"

    if [[ ! -f "$baseline_file" ]]; then
        if [[ "$OUTPUT_JSON" != "true" ]]; then
            echo -e "${YELLOW}No baseline file found, skipping regression check${NC}"
        fi
        return 0
    fi

    # Extract key metrics from both files
    local current_rps=$(jq -r '.summary.avg_requests_per_second' "$current_file" 2>/dev/null || echo "0")
    local baseline_rps=$(jq -r '.summary.avg_requests_per_second' "$baseline_file" 2>/dev/null || echo "0")

    local current_p99=$(jq -r '.summary.avg_p99_latency_ms' "$current_file" 2>/dev/null || echo "0")
    local baseline_p99=$(jq -r '.summary.avg_p99_latency_ms' "$baseline_file" 2>/dev/null || echo "0")

    # Check if we have valid numbers
    if [[ "$baseline_rps" == "0" || "$baseline_rps" == "null" ]]; then
        return 0
    fi

    # Calculate regression percentage for RPS (lower is worse)
    local rps_change=$(echo "scale=2; (($current_rps - $baseline_rps) / $baseline_rps) * 100" | bc 2>/dev/null || echo "0")

    # Calculate regression percentage for P99 (higher is worse)
    local p99_change=$(echo "scale=2; (($current_p99 - $baseline_p99) / $baseline_p99) * 100" | bc 2>/dev/null || echo "0")

    local has_regression=false

    # RPS regression (negative change beyond threshold)
    if (( $(echo "$rps_change < -$THRESHOLD" | bc -l 2>/dev/null || echo 0) )); then
        has_regression=true
        if [[ "$OUTPUT_JSON" != "true" ]]; then
            echo -e "${RED}REGRESSION: Throughput decreased by ${rps_change}% (threshold: -${THRESHOLD}%)${NC}"
        fi
    fi

    # P99 regression (positive change beyond threshold)
    if (( $(echo "$p99_change > $THRESHOLD" | bc -l 2>/dev/null || echo 0) )); then
        has_regression=true
        if [[ "$OUTPUT_JSON" != "true" ]]; then
            echo -e "${RED}REGRESSION: P99 latency increased by ${p99_change}% (threshold: ${THRESHOLD}%)${NC}"
        fi
    fi

    if [[ "$has_regression" == "true" ]]; then
        return 1
    fi

    if [[ "$OUTPUT_JSON" != "true" ]]; then
        echo -e "${GREEN}No regression detected (RPS: ${rps_change}%, P99: ${p99_change}%)${NC}"
    fi

    return 0
}

# Cleanup on exit
cleanup() {
    stop_echo_server
}

trap cleanup EXIT

# Main execution
main() {
    build_benchmarks

    # Only start local echo server if using default URL
    if [[ "$TARGET_URL" == "http://127.0.0.1:$ECHO_SERVER_PORT/" ]]; then
        start_echo_server
    fi

    local results_file
    results_file=$(run_benchmarks)

    if [[ "$CI_MODE" == "true" ]]; then
        if ! check_regression "$results_file"; then
            exit 1
        fi
    fi
}

main
