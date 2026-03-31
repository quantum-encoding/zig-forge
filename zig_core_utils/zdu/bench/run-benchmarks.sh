#!/bin/bash
#
# zdu Benchmark Suite
# Compares zdu against GNU du and optionally Rust uutils du
#
# Usage: ./bench/run-benchmarks.sh [--full] [--target DIR]
#
# Options:
#   --full          Run full benchmark suite including large directories
#   --target DIR    Benchmark a specific directory
#   --rust PATH     Path to Rust uutils du binary (optional)
#   --warmup N      Number of warmup runs (default: 3)
#   --runs N        Number of benchmark runs (default: 10)
#

set -e

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
RESULTS_DIR="$PROJECT_DIR/bench/results"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_FILE="$RESULTS_DIR/benchmark_${TIMESTAMP}.log"
JSON_FILE="$RESULTS_DIR/benchmark_${TIMESTAMP}.json"

# Default settings
WARMUP=3
RUNS=10
FULL_SUITE=false
CUSTOM_TARGET=""
RUST_DU=""

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log() {
    echo -e "$1" | tee -a "$LOG_FILE"
}

# Filter out libwarden/guardian shield noise from output
filter_noise() {
    grep -v -E '^\[libwarden|Guardian Shield' || true
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --full)
            FULL_SUITE=true
            shift
            ;;
        --target)
            CUSTOM_TARGET="$2"
            shift 2
            ;;
        --rust)
            RUST_DU="$2"
            shift 2
            ;;
        --warmup)
            WARMUP="$2"
            shift 2
            ;;
        --runs)
            RUNS="$2"
            shift 2
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Setup
mkdir -p "$RESULTS_DIR"

log "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
log "${CYAN}                    zdu Benchmark Suite                         ${NC}"
log "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
log ""
log "Timestamp: $(date -Iseconds)"
log "Warmup runs: $WARMUP"
log "Benchmark runs: $RUNS"
log ""

# Build optimized binary
log "${YELLOW}Building release-fast binary...${NC}"
cd "$PROJECT_DIR"
zig build bench 2>&1 | filter_noise | tee -a "$LOG_FILE"
ZDU_BIN="$PROJECT_DIR/zig-out/bin/zdu-bench"

if [[ ! -f "$ZDU_BIN" ]]; then
    log "${RED}Error: zdu-bench binary not found${NC}"
    exit 1
fi

log "${GREEN}✓ Build complete: $ZDU_BIN${NC}"
log ""

# Detect GNU du
GNU_DU=$(which du 2>/dev/null || echo "")
if [[ -z "$GNU_DU" ]]; then
    log "${RED}Error: GNU du not found${NC}"
    exit 1
fi
log "GNU du: $GNU_DU"
log "zdu: $ZDU_BIN"
[[ -n "$RUST_DU" ]] && log "Rust du: $RUST_DU"
log ""

# Check hyperfine
if ! command -v hyperfine &> /dev/null; then
    log "${RED}Error: hyperfine not found. Install with: cargo install hyperfine${NC}"
    exit 1
fi
log "hyperfine: $(which hyperfine)"
log ""

# Define benchmark targets
declare -a TARGETS

if [[ -n "$CUSTOM_TARGET" ]]; then
    TARGETS=("$CUSTOM_TARGET")
elif [[ "$FULL_SUITE" == "true" ]]; then
    TARGETS=(
        "."                                    # Current project
        "$HOME"                               # Home directory
        "/usr"                                # System directory
        "/var/log"                            # Log files
    )
    # Add node_modules if it exists
    if [[ -d "$PROJECT_DIR/bench/fixtures/node_modules" ]]; then
        TARGETS+=("$PROJECT_DIR/bench/fixtures/node_modules")
    fi
else
    TARGETS=(
        "."                                   # Current project
        "$HOME"                              # Home directory
    )
fi

# JSON results accumulator
echo "[" > "$JSON_FILE"
FIRST_RESULT=true

run_benchmark() {
    local target="$1"
    local name="$2"

    log "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    log "${YELLOW}Benchmark: ${name}${NC}"
    log "Target: $target"
    log ""

    # Pre-flight stats using zdu
    log "Gathering target statistics..."
    local zdu_stats=$("$ZDU_BIN" -s --json-stats "$target" 2>&1 | filter_noise | grep '{"tool"' || echo '{}')
    log "Target stats: $zdu_stats"
    log ""

    # Hyperfine JSON output file
    local hf_json="$RESULTS_DIR/hyperfine_${TIMESTAMP}_${name//\//_}.json"

    # Build command array for hyperfine
    local cmds=()
    cmds+=("'$ZDU_BIN' -s '$target'")
    cmds+=("'$GNU_DU' -s '$target'")

    if [[ -n "$RUST_DU" && -f "$RUST_DU" ]]; then
        cmds+=("'$RUST_DU' -s '$target'")
    fi

    log "Running hyperfine..."

    # Run hyperfine (suppress stderr noise from commands, ignore failures for permission errors)
    if [[ -n "$RUST_DU" && -f "$RUST_DU" ]]; then
        hyperfine \
            --warmup "$WARMUP" \
            --runs "$RUNS" \
            --ignore-failure \
            --export-json "$hf_json" \
            --export-markdown "$RESULTS_DIR/hyperfine_${TIMESTAMP}_${name//\//_}.md" \
            -n "zdu" "$ZDU_BIN -s $target 2>/dev/null" \
            -n "gnu-du" "$GNU_DU -s $target 2>/dev/null" \
            -n "rust-du" "$RUST_DU -s $target 2>/dev/null" \
            2>&1 | filter_noise | tee -a "$LOG_FILE"
    else
        hyperfine \
            --warmup "$WARMUP" \
            --runs "$RUNS" \
            --ignore-failure \
            --export-json "$hf_json" \
            --export-markdown "$RESULTS_DIR/hyperfine_${TIMESTAMP}_${name//\//_}.md" \
            -n "zdu" "$ZDU_BIN -s $target 2>/dev/null" \
            -n "gnu-du" "$GNU_DU -s $target 2>/dev/null" \
            2>&1 | filter_noise | tee -a "$LOG_FILE"
    fi

    log ""

    # Append to combined JSON
    if [[ "$FIRST_RESULT" == "true" ]]; then
        FIRST_RESULT=false
    else
        echo "," >> "$JSON_FILE"
    fi

    # Create combined result entry
    cat >> "$JSON_FILE" << EOF
{
    "benchmark_name": "$name",
    "target": "$target",
    "timestamp": "$(date -Iseconds)",
    "target_stats": $zdu_stats,
    "hyperfine_results": $(cat "$hf_json")
}
EOF

    log "${GREEN}✓ Benchmark complete: $name${NC}"
    log ""
}

# Run benchmarks
for target in "${TARGETS[@]}"; do
    if [[ -d "$target" ]]; then
        name=$(basename "$target")
        [[ "$name" == "." ]] && name="project"
        run_benchmark "$target" "$name"
    else
        log "${YELLOW}Skipping non-existent target: $target${NC}"
    fi
done

# Close JSON array
echo "]" >> "$JSON_FILE"

# Summary
log ""
log "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
log "${GREEN}                    Benchmark Complete                          ${NC}"
log "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
log ""
log "Results saved to:"
log "  Log:  $LOG_FILE"
log "  JSON: $JSON_FILE"
log ""

# Parse and display summary
log "${YELLOW}Performance Summary:${NC}"
log ""

# Extract mean times from hyperfine results
for hf_file in "$RESULTS_DIR"/hyperfine_${TIMESTAMP}_*.json; do
    if [[ -f "$hf_file" ]]; then
        benchmark_name=$(basename "$hf_file" .json | sed "s/hyperfine_${TIMESTAMP}_//")
        log "  ${CYAN}$benchmark_name:${NC}"

        # Parse with jq if available, otherwise use grep/awk
        if command -v jq &> /dev/null; then
            jq -r '.results[] | "    \(.command): \(.mean * 1000 | floor)ms (±\(.stddev * 1000 | floor)ms)"' "$hf_file" 2>/dev/null | filter_noise | tee -a "$LOG_FILE" || true
        fi
        log ""
    fi
done

log "${GREEN}Done!${NC}"
