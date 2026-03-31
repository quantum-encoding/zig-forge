#!/bin/bash
# Result Validator - Assert on API responses
# Usage: ./validate-results.sh <results-file>

RESULTS_FILE=${1:-test-results/latest.jsonl}

if [ ! -f "$RESULTS_FILE" ]; then
    echo "Error: Results file not found: $RESULTS_FILE"
    exit 1
fi

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

FAILURES=0

# Helper function for assertions
assert_status() {
    local id=$1
    local expected=$2
    local actual=$(jq -r "select(.id==\"$id\") | .status" "$RESULTS_FILE")

    if [ "$actual" == "$expected" ]; then
        echo -e "${GREEN}✓${NC} $id: status $actual"
    else
        echo -e "${RED}✗${NC} $id: expected $expected, got $actual"
        ((FAILURES++))
    fi
}

assert_latency_under() {
    local id=$1
    local max_ms=$2
    local actual=$(jq -r "select(.id==\"$id\") | .latency_ms" "$RESULTS_FILE")

    if [ "$actual" -lt "$max_ms" ]; then
        echo -e "${GREEN}✓${NC} $id: latency ${actual}ms < ${max_ms}ms"
    else
        echo -e "${RED}✗${NC} $id: latency ${actual}ms exceeds ${max_ms}ms"
        ((FAILURES++))
    fi
}

assert_body_contains() {
    local id=$1
    local pattern=$2
    local body=$(jq -r "select(.id==\"$id\") | .body" "$RESULTS_FILE")

    if echo "$body" | grep -q "$pattern"; then
        echo -e "${GREEN}✓${NC} $id: body contains '$pattern'"
    else
        echo -e "${RED}✗${NC} $id: body missing '$pattern'"
        ((FAILURES++))
    fi
}

echo "Running API Test Validations..."
echo "─────────────────────────────────────"

# Health checks should return 200
assert_status "health-check" "200"
assert_latency_under "health-check" 100

# Version endpoint should return 200
assert_status "version-check" "200"

# Invalid login should return 401
assert_status "login-invalid" "401"

# Valid login should return 200
assert_status "login-valid" "200"

# Not found should return 404
assert_status "not-found" "404"

# Unauthorized should return 401 or 403
actual=$(jq -r 'select(.id=="unauthorized") | .status' "$RESULTS_FILE")
if [ "$actual" == "401" ] || [ "$actual" == "403" ]; then
    echo -e "${GREEN}✓${NC} unauthorized: status $actual (expected 401 or 403)"
else
    echo -e "${RED}✗${NC} unauthorized: expected 401/403, got $actual"
    ((FAILURES++))
fi

# Performance checks
assert_latency_under "users-list" 500
assert_latency_under "user-get" 200

echo "─────────────────────────────────────"
if [ $FAILURES -eq 0 ]; then
    echo -e "${GREEN}All validations passed!${NC}"
    exit 0
else
    echo -e "${RED}$FAILURES validation(s) failed${NC}"
    exit 1
fi
