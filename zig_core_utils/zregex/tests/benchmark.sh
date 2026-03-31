#!/bin/bash
# Benchmark zregex vs GNU grep using hyperfine
#
# NOTE: GNU grep is highly optimized with 30+ years of development, SIMD
# acceleration, Boyer-Moore for literals, and hybrid DFA/NFA approaches.
# zregex prioritizes:
#   - Guaranteed O(n*m) worst-case (ReDoS immunity)
#   - Clean, auditable implementation
#   - Correct Thompson NFA semantics
#
# For raw speed on simple patterns, GNU grep will be faster.
# zregex's value is in predictable performance and security.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ZREGEX="$SCRIPT_DIR/../zig-out/bin/zregex"
DATA_DIR="$SCRIPT_DIR/data"
RESULTS_DIR="$SCRIPT_DIR/results"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

check_deps() {
    if ! command -v hyperfine &> /dev/null; then
        echo -e "${RED}Error: hyperfine not found. Install with: cargo install hyperfine${NC}"
        exit 1
    fi
    if ! command -v grep &> /dev/null; then
        echo -e "${RED}Error: grep not found${NC}"
        exit 1
    fi
    if [ ! -f "$ZREGEX" ]; then
        echo -e "${YELLOW}Building zregex (ReleaseFast)...${NC}"
        (cd "$SCRIPT_DIR/.." && zig build -Doptimize=ReleaseFast)
    fi
}

generate_data() {
    if [ ! -d "$DATA_DIR" ] || [ -z "$(ls -A $DATA_DIR 2>/dev/null)" ]; then
        echo -e "${YELLOW}Generating test data...${NC}"
        bash "$SCRIPT_DIR/generate_testdata.sh"
    fi
}

# Verify both tools produce same results
verify_match() {
    local pattern="$1"
    local file="$2"
    local name="$3"

    local grep_count=$(grep -cE "$pattern" "$file" 2>/dev/null || echo "0")
    local zregex_count=$("$ZREGEX" -c "$pattern" "$file" 2>/dev/null || echo "0")

    if [ "$grep_count" = "$zregex_count" ]; then
        echo -e "  ${GREEN}✓${NC} $name: $grep_count matches"
        return 0
    else
        echo -e "  ${RED}✗${NC} $name: grep=$grep_count, zregex=$zregex_count ${RED}(MISMATCH)${NC}"
        return 1
    fi
}

run_bench() {
    local name="$1"
    local pattern="$2"
    local file="$3"
    local warmup="${4:-2}"
    local runs="${5:-5}"

    echo -e "\n${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}$name${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "Pattern: ${GREEN}$pattern${NC}"
    echo -e "File: $(basename "$file") ($(du -h "$file" | cut -f1))"

    # Verify correctness first
    verify_match "$pattern" "$file" "correctness" || return 1

    echo ""
    hyperfine \
        --warmup "$warmup" \
        --runs "$runs" \
        --export-markdown "$RESULTS_DIR/${name// /_}.md" \
        -n "grep" "grep -E '$pattern' '$file'" \
        -n "zregex" "'$ZREGEX' '$pattern' '$file'"
}

run_bench_count() {
    local name="$1"
    local pattern="$2"
    local file="$3"

    echo -e "\n${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}$name (count mode)${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "Pattern: ${GREEN}$pattern${NC}"

    verify_match "$pattern" "$file" "correctness" || return 1

    echo ""
    hyperfine \
        --warmup 2 \
        --runs 5 \
        --export-markdown "$RESULTS_DIR/${name// /_}_count.md" \
        -n "grep -c" "grep -cE '$pattern' '$file'" \
        -n "zregex -c" "'$ZREGEX' -c '$pattern' '$file'"
}

main() {
    echo -e "${GREEN}╔════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║           zregex vs GNU grep Benchmark Suite                   ║${NC}"
    echo -e "${GREEN}║                                                                ║${NC}"
    echo -e "${GREEN}║  zregex: Thompson NFA, O(n*m) guaranteed, ReDoS-immune         ║${NC}"
    echo -e "${GREEN}║  grep:   Highly optimized, SIMD, Boyer-Moore, hybrid DFA       ║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════════════════════════════╝${NC}"

    check_deps
    generate_data
    mkdir -p "$RESULTS_DIR"

    echo -e "\n${YELLOW}Verifying correctness across all test patterns...${NC}"

    local all_correct=true

    # Verify all patterns first
    for pattern in "hello" "world" '\bword\b' '[0-9]+' "^Line" 'dog\.$' '\[ERROR\]' 'fn [a-z_]+'; do
        verify_match "$pattern" "$DATA_DIR/simple_1mb.txt" "$pattern" || all_correct=false
    done

    if [ "$all_correct" = true ]; then
        echo -e "\n${GREEN}All patterns verified correct!${NC}"
    else
        echo -e "\n${RED}Some patterns have mismatches - check regex implementation${NC}"
    fi

    echo -e "\n${YELLOW}Running performance benchmarks...${NC}"

    # Simple patterns
    run_bench "Literal: hello" "hello" "$DATA_DIR/simple_1mb.txt"
    run_bench "Literal: fox" "fox" "$DATA_DIR/simple_1mb.txt"

    # Word boundaries
    run_bench "Word boundary" '\bworld\b' "$DATA_DIR/simple_1mb.txt"

    # Character classes
    run_bench "Digit sequence" '[0-9]+' "$DATA_DIR/simple_1mb.txt"

    # Anchors
    run_bench "Start anchor" "^Line" "$DATA_DIR/simple_1mb.txt"

    # Log patterns
    run_bench "Log: ERROR" '\[ERROR\]' "$DATA_DIR/log_1mb.txt"

    # Code patterns
    run_bench "Code: function" 'fn [a-z_]+' "$DATA_DIR/code_1mb.txt"

    # Count mode
    run_bench_count "Count: hello" "hello" "$DATA_DIR/simple_1mb.txt"

    # Summary
    echo -e "\n${GREEN}╔════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║                      Benchmark Complete                         ║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════════════════════════════╝${NC}"
    echo -e "\nResults saved to: ${YELLOW}$RESULTS_DIR/${NC}"
    echo ""
    echo -e "${CYAN}Key Takeaways:${NC}"
    echo -e "  • GNU grep is highly optimized for raw throughput"
    echo -e "  • zregex guarantees O(n*m) worst-case (no ReDoS)"
    echo -e "  • Both produce identical match results"
    echo ""
}

quick_test() {
    check_deps
    generate_data
    mkdir -p "$RESULTS_DIR"

    echo -e "${CYAN}Quick benchmark test${NC}\n"

    run_bench "Quick: hello" "hello" "$DATA_DIR/simple_1mb.txt" 1 3
}

correctness_test() {
    check_deps
    generate_data

    echo -e "${GREEN}╔════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║              Correctness Verification Suite                    ║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════════════════════════════╝${NC}\n"

    local pass=0
    local fail=0

    test_pattern() {
        local pattern="$1"
        local file="$2"
        local desc="$3"

        local grep_out=$(grep -E "$pattern" "$file" 2>/dev/null | head -100 | md5sum | cut -d' ' -f1)
        local zregex_out=$("$ZREGEX" "$pattern" "$file" 2>/dev/null | head -100 | md5sum | cut -d' ' -f1)

        if [ "$grep_out" = "$zregex_out" ]; then
            echo -e "${GREEN}✓${NC} $desc"
            ((pass++))
        else
            echo -e "${RED}✗${NC} $desc"
            ((fail++))
        fi
    }

    echo -e "${CYAN}Testing patterns on simple_1mb.txt:${NC}"
    test_pattern "hello" "$DATA_DIR/simple_1mb.txt" "Literal: hello"
    test_pattern "world" "$DATA_DIR/simple_1mb.txt" "Literal: world"
    test_pattern "fox" "$DATA_DIR/simple_1mb.txt" "Literal: fox"
    test_pattern "[0-9]+" "$DATA_DIR/simple_1mb.txt" "Char class: [0-9]+"
    test_pattern "^Line" "$DATA_DIR/simple_1mb.txt" "Anchor: ^Line"
    test_pattern 'dog\.$' "$DATA_DIR/simple_1mb.txt" 'Anchor: dog\.$'
    test_pattern '\bworld\b' "$DATA_DIR/simple_1mb.txt" 'Word boundary: \bworld\b'
    test_pattern "qu.ck" "$DATA_DIR/simple_1mb.txt" "Dot: qu.ck"
    test_pattern "test.*line" "$DATA_DIR/simple_1mb.txt" "Star: test.*line"
    test_pattern "hel+" "$DATA_DIR/simple_1mb.txt" "Plus: hel+"
    test_pattern "worlds?" "$DATA_DIR/simple_1mb.txt" "Optional: worlds?"

    echo -e "\n${CYAN}Testing patterns on log_1mb.txt:${NC}"
    test_pattern '\[ERROR\]' "$DATA_DIR/log_1mb.txt" 'Brackets: \[ERROR\]'
    test_pattern '\[INFO\]' "$DATA_DIR/log_1mb.txt" 'Brackets: \[INFO\]'
    test_pattern '192\.168\.[0-9]+\.[0-9]+' "$DATA_DIR/log_1mb.txt" 'IP pattern'

    echo -e "\n${CYAN}Testing patterns on code_1mb.txt:${NC}"
    test_pattern 'fn [a-z_]+' "$DATA_DIR/code_1mb.txt" 'Function: fn [a-z_]+'
    test_pattern 'allocator\.' "$DATA_DIR/code_1mb.txt" 'Method: allocator\.'

    echo ""
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "Results: ${GREEN}$pass passed${NC}, ${RED}$fail failed${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    [ $fail -eq 0 ]
}

case "${1:-}" in
    --quick)
        quick_test
        ;;
    --correctness)
        correctness_test
        ;;
    --help)
        echo "Usage: $0 [OPTION]"
        echo ""
        echo "Options:"
        echo "  (none)        Run full benchmark suite"
        echo "  --quick       Run a quick benchmark"
        echo "  --correctness Run correctness verification only"
        echo "  --help        Show this help"
        ;;
    "")
        main
        ;;
    *)
        echo "Unknown option: $1"
        echo "Run with --help for usage"
        exit 1
        ;;
esac
