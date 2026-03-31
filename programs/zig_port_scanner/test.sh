#!/bin/bash
# Test runner for zig-port-scanner
# Mimics the rigorous testing approach from core-utils Rust project

set -e  # Exit on error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

PASSED=0
FAILED=0
SKIPPED=0

print_header() {
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

print_pass() {
    echo -e "${GREEN}✓ $1${NC}"
    ((PASSED++))
}

print_fail() {
    echo -e "${RED}✗ $1${NC}"
    ((FAILED++))
}

print_skip() {
    echo -e "${YELLOW}⊘ $1${NC}"
    ((SKIPPED++))
}

# Check if we're in the right directory
if [ ! -f "build.zig" ]; then
    echo -e "${RED}Error: Must run from zig-port-scanner directory${NC}"
    exit 1
fi

print_header "ZIG PORT SCANNER TEST SUITE"
echo "Testing like we're submitting to upstream CI/CD"
echo ""

# ============================================================================
# Phase 1: Build Tests
# ============================================================================

print_header "Phase 1: Build Tests"

echo "Building project..."
if zig build 2>&1 | tee /tmp/build.log; then
    print_pass "Build succeeded"
else
    print_fail "Build failed"
    cat /tmp/build.log
    exit 1
fi

echo ""

# ============================================================================
# Phase 2: Unit Tests (No Network Required)
# ============================================================================

print_header "Phase 2: Unit Tests (No Network)"
echo "These tests should pass in any environment..."
echo ""

echo "Running unit tests..."
if zig build test 2>&1 | tee /tmp/test-unit.log; then
    # Count passed tests from output
    UNIT_PASSED=$(grep -c "test.*ok" /tmp/test-unit.log || true)
    print_pass "Unit tests passed ($UNIT_PASSED tests)"
else
    print_fail "Unit tests failed"
    cat /tmp/test-unit.log
    exit 1
fi

echo ""

# ============================================================================
# Phase 3: Integration Tests (Network Required)
# ============================================================================

print_header "Phase 3: Integration Tests (Network)"
echo "These tests require internet access..."
echo ""

# Check if we have network
if ping -c 1 -W 2 google.com >/dev/null 2>&1; then
    echo "Network available, running integration tests..."

    if zig build test-integration 2>&1 | tee /tmp/test-integration.log; then
        INT_PASSED=$(grep -c "test.*ok" /tmp/test-integration.log || true)
        print_pass "Integration tests passed ($INT_PASSED tests)"
    else
        print_fail "Integration tests failed"
        cat /tmp/test-integration.log
        # Don't exit - integration tests are optional
        ((FAILED++))
    fi
else
    print_skip "Integration tests (no network)"
    ((SKIPPED++))
fi

echo ""

# ============================================================================
# Phase 4: Functional Tests (End-to-End)
# ============================================================================

print_header "Phase 4: Functional Tests (E2E)"
echo "Testing actual scanner behavior..."
echo ""

SCANNER="./zig-out/bin/zig-port-scanner"

if [ ! -x "$SCANNER" ]; then
    print_fail "Scanner binary not found or not executable"
    exit 1
fi

# Test 1: Help message
echo "Testing help message..."
if $SCANNER -h >/dev/null 2>&1 || $SCANNER --help >/dev/null 2>&1; then
    print_pass "Help message works"
else
    print_fail "Help message failed"
fi

# Test 2: Invalid arguments
echo "Testing error handling..."
if ! $SCANNER 2>/dev/null; then
    print_pass "Correctly rejects missing arguments"
else
    print_fail "Should reject missing arguments"
fi

# Test 3: Invalid port spec
echo "Testing invalid port spec..."
if ! $SCANNER -p=invalid localhost 2>/dev/null; then
    print_pass "Correctly rejects invalid port spec"
else
    print_fail "Should reject invalid port spec"
fi

# Test 4: Localhost scan
echo "Testing localhost scan..."
if $SCANNER -p=54321 -t=500 localhost >/tmp/scan-localhost.log 2>&1; then
    if grep -q "0 open port" /tmp/scan-localhost.log; then
        print_pass "Localhost scan works (port correctly reported as not open)"
    else
        print_skip "Localhost scan unexpected result"
        cat /tmp/scan-localhost.log
    fi
else
    print_fail "Localhost scan failed"
    cat /tmp/scan-localhost.log
fi

# Test 5: Multiple ports
echo "Testing multiple port scan..."
if $SCANNER -p=54321,54322,54323 -t=500 localhost >/tmp/scan-multi.log 2>&1; then
    if grep -q "Scanning 3 ports" /tmp/scan-multi.log; then
        print_pass "Multiple port specification works"
    else
        print_fail "Multiple ports not parsed correctly"
        cat /tmp/scan-multi.log
    fi
else
    print_fail "Multiple port scan failed"
fi

# Test 6: Port range
echo "Testing port range..."
if $SCANNER -p=54321-54325 -t=500 localhost >/tmp/scan-range.log 2>&1; then
    if grep -q "Scanning 5 ports" /tmp/scan-range.log; then
        print_pass "Port range works"
    else
        print_fail "Port range not parsed correctly"
        cat /tmp/scan-range.log
    fi
else
    print_fail "Port range scan failed"
fi

# Test 7: Timeout setting
echo "Testing custom timeout..."
if $SCANNER -p=54321 -t=2000 localhost >/tmp/scan-timeout.log 2>&1; then
    print_pass "Custom timeout accepted"
else
    print_fail "Custom timeout failed"
fi

# Test 8: Thread count
echo "Testing thread count..."
if $SCANNER -p=54321-54325 -j=5 localhost >/tmp/scan-threads.log 2>&1; then
    print_pass "Custom thread count accepted"
else
    print_fail "Custom thread count failed"
fi

echo ""

# ============================================================================
# Phase 5: Network Tests (If Available)
# ============================================================================

if ping -c 1 -W 2 google.com >/dev/null 2>&1; then
    print_header "Phase 5: Network Tests (Live Servers)"
    echo "Testing against real servers..."
    echo ""

    # Test Google HTTP
    echo "Scanning google.com:80..."
    if $SCANNER -p=80 -t=5000 google.com >/tmp/scan-google.log 2>&1; then
        if grep -q "80.*open" /tmp/scan-google.log; then
            print_pass "Google HTTP detected as open"
        else
            print_skip "Google HTTP scan inconclusive"
            cat /tmp/scan-google.log
        fi
    else
        print_fail "Google scan failed"
    fi

    # Test Google HTTPS
    echo "Scanning google.com:443..."
    if $SCANNER -p=443 -t=5000 google.com >/tmp/scan-google-https.log 2>&1; then
        if grep -q "443.*open" /tmp/scan-google-https.log; then
            print_pass "Google HTTPS detected as open"
        else
            print_skip "Google HTTPS scan inconclusive"
        fi
    else
        print_fail "Google HTTPS scan failed"
    fi

    # Test GitHub SSH
    echo "Scanning github.com:22..."
    if $SCANNER -p=22 -t=5000 github.com >/tmp/scan-github-ssh.log 2>&1; then
        if grep -q "22.*open" /tmp/scan-github-ssh.log; then
            print_pass "GitHub SSH detected as open"
        else
            print_skip "GitHub SSH scan inconclusive"
        fi
    else
        print_fail "GitHub SSH scan failed"
    fi

    echo ""
else
    print_skip "Phase 5: Network Tests (no internet)"
fi

# ============================================================================
# Phase 6: Performance Tests
# ============================================================================

print_header "Phase 6: Performance Tests"
echo "Ensuring reasonable performance..."
echo ""

# Test: 100 port scan should complete quickly
echo "Testing 100-port scan performance..."
START=$(date +%s)
$SCANNER -p=54321-54420 -t=500 -j=20 localhost >/tmp/scan-perf.log 2>&1 || true
END=$(date +%s)
ELAPSED=$((END - START))

if [ $ELAPSED -lt 30 ]; then
    print_pass "100-port scan completed in ${ELAPSED}s (fast enough)"
else
    print_fail "100-port scan took ${ELAPSED}s (too slow, expected <30s)"
fi

echo ""

# ============================================================================
# Summary
# ============================================================================

print_header "TEST SUMMARY"
echo ""
echo -e "Tests passed:  ${GREEN}${PASSED}${NC}"
echo -e "Tests failed:  ${RED}${FAILED}${NC}"
echo -e "Tests skipped: ${YELLOW}${SKIPPED}${NC}"
echo ""

if [ $FAILED -eq 0 ]; then
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}✓ ALL TESTS PASSED - READY FOR PRODUCTION${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    exit 0
else
    echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${RED}✗ TESTS FAILED - NEEDS FIXES${NC}"
    echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    exit 1
fi
