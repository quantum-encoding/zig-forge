#!/bin/bash
# Zig Charts Test Suite
# Generates SVG charts from all JSON test files

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
JSON_DIR="$SCRIPT_DIR/json"
OUTPUT_DIR="$SCRIPT_DIR/output"
CHART_BIN="$PROJECT_DIR/zig-out/bin/chart-demo"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo "========================================"
echo "  Zig Charts Test Suite"
echo "========================================"
echo ""

# Check if binary exists
if [ ! -f "$CHART_BIN" ]; then
    echo -e "${YELLOW}Building chart-demo...${NC}"
    cd "$PROJECT_DIR"
    zig build
    cd "$SCRIPT_DIR"
fi

# Create output directory
mkdir -p "$OUTPUT_DIR"

# Count tests
TOTAL=0
PASSED=0
FAILED=0

# Process each JSON file
echo "Running tests..."
echo ""

for json_file in "$JSON_DIR"/*.json; do
    if [ -f "$json_file" ]; then
        TOTAL=$((TOTAL + 1))
        filename=$(basename "$json_file" .json)
        output_file="$OUTPUT_DIR/${filename}.svg"

        printf "  %-30s " "$filename"

        # Run the chart generator
        if "$CHART_BIN" render "$json_file" -o "$output_file" 2>/dev/null; then
            # Verify output file was created and has content
            if [ -f "$output_file" ] && [ -s "$output_file" ]; then
                # Check if it's valid SVG (starts with <?xml or <svg)
                if head -1 "$output_file" | grep -q "<?xml\|<svg"; then
                    echo -e "${GREEN}PASS${NC}"
                    PASSED=$((PASSED + 1))
                else
                    echo -e "${RED}FAIL${NC} (invalid SVG)"
                    FAILED=$((FAILED + 1))
                fi
            else
                echo -e "${RED}FAIL${NC} (no output)"
                FAILED=$((FAILED + 1))
            fi
        else
            echo -e "${RED}FAIL${NC} (error)"
            FAILED=$((FAILED + 1))
        fi
    fi
done

echo ""
echo "========================================"
echo "  Results: $PASSED/$TOTAL passed"
if [ $FAILED -gt 0 ]; then
    echo -e "  ${RED}$FAILED test(s) failed${NC}"
else
    echo -e "  ${GREEN}All tests passed!${NC}"
fi
echo "========================================"
echo ""
echo "Output files: $OUTPUT_DIR/"
echo ""

# List generated files with sizes
if [ $PASSED -gt 0 ]; then
    echo "Generated SVG files:"
    ls -lh "$OUTPUT_DIR"/*.svg 2>/dev/null | awk '{print "  " $9 " (" $5 ")"}'
fi

# Exit with error if any tests failed
if [ $FAILED -gt 0 ]; then
    exit 1
fi
