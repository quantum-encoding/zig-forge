#!/bin/bash
# API Test Suite Runner for quantum-curl
# Usage: ./run-api-tests.sh <environment> [--verbose]

set -e

# Configuration
QUANTUM_CURL="./zig-out/bin/quantum-curl"
TEST_SUITE="examples/api-test-suite.jsonl"
RESULTS_DIR="test-results"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Environment URLs
declare -A ENVS=(
    ["local"]="http://localhost:3000"
    ["dev"]="https://api.dev.example.com"
    ["staging"]="https://api.staging.example.com"
    ["production"]="https://api.example.com"
)

# Parse arguments
ENV=${1:-staging}
VERBOSE=${2}
BASE_URL=${ENVS[$ENV]}

if [ -z "$BASE_URL" ]; then
    echo -e "${RED}Error: Unknown environment '$ENV'${NC}"
    echo "Available: ${!ENVS[@]}"
    exit 1
fi

echo -e "${BLUE}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║  API Test Suite - quantum-curl                              ║${NC}"
echo -e "${BLUE}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${YELLOW}Environment:${NC} $ENV"
echo -e "${YELLOW}Base URL:${NC}    $BASE_URL"
echo -e "${YELLOW}Test Suite:${NC}  $TEST_SUITE"
echo ""

# Create results directory
mkdir -p "$RESULTS_DIR"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
RESULTS_FILE="$RESULTS_DIR/results_${ENV}_${TIMESTAMP}.jsonl"

# Replace placeholder URLs with actual environment URL
sed "s|https://api.staging.example.com|$BASE_URL|g" "$TEST_SUITE" | \
    grep -v "^#" | \
    $QUANTUM_CURL --concurrency 10 > "$RESULTS_FILE"

# Parse results
echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}Test Results${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
echo ""

# Statistics
TOTAL=$(wc -l < "$RESULTS_FILE")
SUCCESS=$(jq -r 'select(.status >= 200 and .status < 400) | .id' "$RESULTS_FILE" | wc -l)
FAILED=$(jq -r 'select(.status >= 400 or .error) | .id' "$RESULTS_FILE" | wc -l)
AVG_LATENCY=$(jq -s 'map(.latency_ms) | add / length' "$RESULTS_FILE")

printf "${GREEN}✓ Success:${NC} %d/%d\n" "$SUCCESS" "$TOTAL"
printf "${RED}✗ Failed:${NC}  %d/%d\n" "$FAILED" "$TOTAL"
printf "${YELLOW}⚡ Avg Latency:${NC} %.0fms\n" "$AVG_LATENCY"
echo ""

# Detailed results
if [ "$VERBOSE" == "--verbose" ] || [ $FAILED -gt 0 ]; then
    echo -e "${BLUE}Detailed Results:${NC}"
    echo "─────────────────────────────────────────────────────────────"

    while IFS= read -r line; do
        ID=$(echo "$line" | jq -r '.id')
        STATUS=$(echo "$line" | jq -r '.status')
        LATENCY=$(echo "$line" | jq -r '.latency_ms')
        RETRIES=$(echo "$line" | jq -r '.retry_count // 0')
        ERROR=$(echo "$line" | jq -r '.error_message // ""')

        # Color code by status
        if [ "$STATUS" -ge 200 ] && [ "$STATUS" -lt 300 ]; then
            COLOR=$GREEN
            ICON="✓"
        elif [ "$STATUS" -ge 300 ] && [ "$STATUS" -lt 400 ]; then
            COLOR=$YELLOW
            ICON="↻"
        else
            COLOR=$RED
            ICON="✗"
        fi

        printf "${COLOR}%s${NC} %-20s ${BLUE}[%d]${NC} %4dms" \
            "$ICON" "$ID" "$STATUS" "$LATENCY"

        if [ $RETRIES -gt 0 ]; then
            printf " ${YELLOW}(retried %dx)${NC}" "$RETRIES"
        fi

        if [ -n "$ERROR" ]; then
            printf "\n  ${RED}Error: %s${NC}" "$ERROR"
        fi

        echo ""
    done < "$RESULTS_FILE"
fi

echo ""
echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
echo -e "Full results saved to: ${YELLOW}$RESULTS_FILE${NC}"

# Exit code based on test results
if [ $FAILED -gt 0 ]; then
    echo -e "${RED}Tests FAILED${NC}"
    exit 1
else
    echo -e "${GREEN}All tests PASSED${NC}"
    exit 0
fi
