#!/usr/bin/env bash
# zig-docx Benchmark Suite
# Tests all conversion modes with real documents
# Requires: hyperfine, /usr/bin/time (GNU or BSD)
set -euo pipefail

BINARY="./zig-out/bin/zig-docx"
BENCH_DIR="/tmp/zig-docx-bench"
RESULTS_FILE="$BENCH_DIR/results.md"

# Test files — edit these paths to match your system
PDF_LARGE="/Users/director/Downloads/arm_neoverse_v2_core_trm_102375_0002_03_en.pdf"
PDF_SMALL="/Users/director/Downloads/AI Coding and Vibe Coding_ The Fastest-Growing SaaS Category in History.pdf"
XLSX_FILE="/Users/director/Downloads/metatron_full_compute_valuation.xlsx"
DOCX_FILE="/Users/director/work/poly-repo/crg-direct-polyrepo/blog-stuff/How Much Electricity Does a 4kW Solar System Produce.docx"

# Colors
GREEN='\033[0;32m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

echo -e "${BOLD}zig-docx Benchmark Suite${NC}"
echo "════════════════════════════════════════"

# Check binary
if [ ! -f "$BINARY" ]; then
    echo "Building zig-docx..."
    zig build 2>&1
fi

# Setup
rm -rf "$BENCH_DIR"
mkdir -p "$BENCH_DIR"/{pdf_chunks,xlsx_out,docx_out}

echo -e "\n${CYAN}Binary:${NC} $BINARY"
echo -e "${CYAN}Output:${NC} $BENCH_DIR"

# ─────────────────────────────────────────────────
# File stats
# ─────────────────────────────────────────────────
echo -e "\n${BOLD}Test Files${NC}"
echo "────────────────────────────────────────"
for f in "$PDF_LARGE" "$PDF_SMALL" "$XLSX_FILE" "$DOCX_FILE"; do
    if [ -f "$f" ]; then
        SIZE=$(ls -lh "$f" | awk '{print $5}')
        echo "  $(basename "$f"): $SIZE"
    else
        echo "  MISSING: $f"
    fi
done

# ─────────────────────────────────────────────────
# Helper: run with /usr/bin/time for peak RSS
# ─────────────────────────────────────────────────
run_with_stats() {
    local label="$1"
    shift
    echo -e "\n${GREEN}▸ $label${NC}"

    # Run once to get peak memory (macOS /usr/bin/time format)
    local time_output
    time_output=$( { /usr/bin/time -l "$@" > /dev/null; } 2>&1 )
    local peak_mem=$(echo "$time_output" | grep "maximum resident" | awk '{print $1}')
    local real_time=$(echo "$time_output" | grep "real" | awk '{print $1}')

    if [ -n "$peak_mem" ]; then
        local mem_mb=$(echo "scale=1; $peak_mem / 1048576" | bc 2>/dev/null || echo "?")
        echo "  Peak RSS: ${mem_mb}MB"
    fi

    echo "$time_output" | grep -E "real|user|sys" | head -3 | sed 's/^/  /'
}

# ─────────────────────────────────────────────────
# Benchmarks
# ─────────────────────────────────────────────────

cat > "$RESULTS_FILE" << 'HEADER'
# zig-docx Benchmark Results

HEADER
echo "Date: $(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$RESULTS_FILE"
echo "" >> "$RESULTS_FILE"

# 1. PDF Large → Markdown
if [ -f "$PDF_LARGE" ]; then
    echo -e "\n${BOLD}1. PDF → Markdown (large: ARM Neoverse V2 TRM, 11MB, 1529 pages)${NC}"
    echo "────────────────────────────────────────"
    run_with_stats "PDF extract + markdown" "$BINARY" "$PDF_LARGE" -o "$BENCH_DIR/arm_neoverse.md"
    echo "  Output: $(ls -lh "$BENCH_DIR/arm_neoverse.md" | awk '{print $5}')"
    echo "  Words: $(wc -w < "$BENCH_DIR/arm_neoverse.md" | tr -d ' ')"

    echo -e "\n  ${CYAN}hyperfine (3 runs):${NC}"
    hyperfine --warmup 1 --runs 3 \
        "$BINARY '$PDF_LARGE' -o $BENCH_DIR/arm_neoverse.md" \
        2>&1 | grep -E "Time|Range" | sed 's/^/  /'

    echo "" >> "$RESULTS_FILE"
    echo "## 1. PDF → Markdown (11MB, 1529 pages)" >> "$RESULTS_FILE"
    echo '```' >> "$RESULTS_FILE"
    hyperfine --warmup 1 --runs 3 \
        "$BINARY '$PDF_LARGE' -o $BENCH_DIR/arm_neoverse.md" \
        2>&1 | tee -a "$RESULTS_FILE"
    echo '```' >> "$RESULTS_FILE"
fi

# 2. PDF Large → Chunked
if [ -f "$PDF_LARGE" ]; then
    echo -e "\n${BOLD}2. PDF → Chunked Markdown (large)${NC}"
    echo "────────────────────────────────────────"
    rm -rf "$BENCH_DIR/pdf_chunks"
    mkdir -p "$BENCH_DIR/pdf_chunks"
    run_with_stats "PDF extract + chunk" "$BINARY" --chunk "$PDF_LARGE" -o "$BENCH_DIR/pdf_chunks"
    echo "  Chunks: $(ls "$BENCH_DIR/pdf_chunks"/*.md 2>/dev/null | wc -l | tr -d ' ')"
    echo "  Total size: $(du -sh "$BENCH_DIR/pdf_chunks" | awk '{print $1}')"

    echo -e "\n  ${CYAN}hyperfine (3 runs):${NC}"
    hyperfine --warmup 1 --runs 3 --prepare "rm -rf $BENCH_DIR/pdf_chunks && mkdir -p $BENCH_DIR/pdf_chunks" \
        "$BINARY --chunk '$PDF_LARGE' -o $BENCH_DIR/pdf_chunks" \
        2>&1 | grep -E "Time|Range" | sed 's/^/  /'

    echo "" >> "$RESULTS_FILE"
    echo "## 2. PDF → Chunked (11MB, 1529 pages → 417 chunks)" >> "$RESULTS_FILE"
    echo '```' >> "$RESULTS_FILE"
    hyperfine --warmup 1 --runs 3 --prepare "rm -rf $BENCH_DIR/pdf_chunks && mkdir -p $BENCH_DIR/pdf_chunks" \
        "$BINARY --chunk '$PDF_LARGE' -o $BENCH_DIR/pdf_chunks" \
        2>&1 | tee -a "$RESULTS_FILE"
    echo '```' >> "$RESULTS_FILE"
fi

# 3. PDF Small → Markdown
if [ -f "$PDF_SMALL" ]; then
    echo -e "\n${BOLD}3. PDF → Markdown (small: 6 pages)${NC}"
    echo "────────────────────────────────────────"
    run_with_stats "PDF small extract" "$BINARY" "$PDF_SMALL" -o "$BENCH_DIR/ai_coding.md"
    echo "  Output: $(ls -lh "$BENCH_DIR/ai_coding.md" | awk '{print $5}')"

    echo -e "\n  ${CYAN}hyperfine (5 runs):${NC}"
    hyperfine --warmup 1 --runs 5 \
        "$BINARY '$PDF_SMALL' -o $BENCH_DIR/ai_coding.md" \
        2>&1 | grep -E "Time|Range" | sed 's/^/  /'

    echo "" >> "$RESULTS_FILE"
    echo "## 3. PDF → Markdown (small, 6 pages)" >> "$RESULTS_FILE"
    echo '```' >> "$RESULTS_FILE"
    hyperfine --warmup 1 --runs 5 \
        "$BINARY '$PDF_SMALL' -o $BENCH_DIR/ai_coding.md" \
        2>&1 | tee -a "$RESULTS_FILE"
    echo '```' >> "$RESULTS_FILE"
fi

# 4. XLSX → CSV
if [ -f "$XLSX_FILE" ]; then
    echo -e "\n${BOLD}4. XLSX → CSV${NC}"
    echo "────────────────────────────────────────"
    run_with_stats "XLSX to CSV" "$BINARY" "$XLSX_FILE" -o "$BENCH_DIR/xlsx_out/valuation.csv"
    echo "  Output: $(ls -lh "$BENCH_DIR/xlsx_out/valuation.csv" | awk '{print $5}')"

    echo -e "\n  ${CYAN}hyperfine (10 runs):${NC}"
    hyperfine --warmup 2 --runs 10 \
        "$BINARY '$XLSX_FILE' -o $BENCH_DIR/xlsx_out/valuation.csv" \
        2>&1 | grep -E "Time|Range" | sed 's/^/  /'

    echo "" >> "$RESULTS_FILE"
    echo "## 4. XLSX → CSV" >> "$RESULTS_FILE"
    echo '```' >> "$RESULTS_FILE"
    hyperfine --warmup 2 --runs 10 \
        "$BINARY '$XLSX_FILE' -o $BENCH_DIR/xlsx_out/valuation.csv" \
        2>&1 | tee -a "$RESULTS_FILE"
    echo '```' >> "$RESULTS_FILE"
fi

# 5. XLSX → Markdown table
if [ -f "$XLSX_FILE" ]; then
    echo -e "\n${BOLD}5. XLSX → Markdown Table${NC}"
    echo "────────────────────────────────────────"
    run_with_stats "XLSX to Markdown" "$BINARY" --markdown "$XLSX_FILE" -o "$BENCH_DIR/xlsx_out/valuation.md"
    echo "  Output: $(ls -lh "$BENCH_DIR/xlsx_out/valuation.md" | awk '{print $5}')"

    echo -e "\n  ${CYAN}hyperfine (10 runs):${NC}"
    hyperfine --warmup 2 --runs 10 \
        "$BINARY --markdown '$XLSX_FILE' -o $BENCH_DIR/xlsx_out/valuation.md" \
        2>&1 | grep -E "Time|Range" | sed 's/^/  /'

    echo "" >> "$RESULTS_FILE"
    echo "## 5. XLSX → Markdown Table" >> "$RESULTS_FILE"
    echo '```' >> "$RESULTS_FILE"
    hyperfine --warmup 2 --runs 10 \
        "$BINARY --markdown '$XLSX_FILE' -o $BENCH_DIR/xlsx_out/valuation.md" \
        2>&1 | tee -a "$RESULTS_FILE"
    echo '```' >> "$RESULTS_FILE"
fi

# 6. DOCX → MDX
if [ -f "$DOCX_FILE" ]; then
    echo -e "\n${BOLD}6. DOCX → MDX${NC}"
    echo "────────────────────────────────────────"
    run_with_stats "DOCX to MDX" "$BINARY" "$DOCX_FILE" -o "$BENCH_DIR/docx_out/solar.mdx"
    echo "  Output: $(ls -lh "$BENCH_DIR/docx_out/solar.mdx" | awk '{print $5}')"

    echo -e "\n  ${CYAN}hyperfine (10 runs):${NC}"
    hyperfine --warmup 2 --runs 10 \
        "$BINARY '$DOCX_FILE' -o $BENCH_DIR/docx_out/solar.mdx" \
        2>&1 | grep -E "Time|Range" | sed 's/^/  /'

    echo "" >> "$RESULTS_FILE"
    echo "## 6. DOCX → MDX" >> "$RESULTS_FILE"
    echo '```' >> "$RESULTS_FILE"
    hyperfine --warmup 2 --runs 10 \
        "$BINARY '$DOCX_FILE' -o $BENCH_DIR/docx_out/solar.mdx" \
        2>&1 | tee -a "$RESULTS_FILE"
    echo '```' >> "$RESULTS_FILE"
fi

# ─────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────
echo -e "\n${BOLD}════════════════════════════════════════${NC}"
echo -e "${BOLD}Summary${NC}"
echo "────────────────────────────────────────"
echo "  Binary size: $(ls -lh "$BINARY" | awk '{print $5}')"
echo "  All outputs: $(du -sh "$BENCH_DIR" | awk '{print $1}')"
echo "  Results:     $RESULTS_FILE"

echo "" >> "$RESULTS_FILE"
echo "## System Info" >> "$RESULTS_FILE"
echo '```' >> "$RESULTS_FILE"
echo "Binary: $(ls -lh "$BINARY" | awk '{print $5}')" >> "$RESULTS_FILE"
sysctl -n machdep.cpu.brand_string >> "$RESULTS_FILE" 2>/dev/null || echo "Unknown CPU" >> "$RESULTS_FILE"
echo "RAM: $(sysctl -n hw.memsize 2>/dev/null | awk '{printf "%.0f GB", $1/1073741824}')" >> "$RESULTS_FILE"
echo "OS: $(sw_vers -productName 2>/dev/null) $(sw_vers -productVersion 2>/dev/null)" >> "$RESULTS_FILE"
echo '```' >> "$RESULTS_FILE"

echo -e "\n${GREEN}Done. Full results in: $RESULTS_FILE${NC}"
