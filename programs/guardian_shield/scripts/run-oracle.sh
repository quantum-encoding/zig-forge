#!/bin/bash
# The Oracle Protocol - Execution Script
# Systematic LSM Hook Reconnaissance

set -e

SCRIPT_DIR="/home/founder/github_public/guardian-shield"
ORACLE_SRC="$SCRIPT_DIR/oracle-probe.c"
ORACLE_BIN="$SCRIPT_DIR/oracle-probe"
REPORT_PATH="$SCRIPT_DIR/oracle-report.txt"

echo "═══════════════════════════════════════════════════════════"
echo "   THE ORACLE PROTOCOL - Compilation Phase"
echo "═══════════════════════════════════════════════════════════"

# Check for root
if [ "$EUID" -ne 0 ]; then
    echo "ERROR: Must run as root (use sudo)"
    exit 1
fi

# Compile oracle-probe
echo "Compiling Oracle Probe..."
gcc -o "$ORACLE_BIN" "$ORACLE_SRC" -lbpf -lelf -lz
if [ $? -ne 0 ]; then
    echo "ERROR: Compilation failed"
    exit 1
fi
echo "✓ Oracle Probe compiled successfully"
echo ""

# Execute oracle-probe
echo "═══════════════════════════════════════════════════════════"
echo "   THE ORACLE PROTOCOL - Reconnaissance Phase"
echo "═══════════════════════════════════════════════════════════"
echo ""

"$ORACLE_BIN"

# Display results
echo ""
echo "═══════════════════════════════════════════════════════════"
echo "   THE ORACLE PROTOCOL - Results"
echo "═══════════════════════════════════════════════════════════"
echo ""

if [ -f "$REPORT_PATH" ]; then
    echo "Report generated at: $REPORT_PATH"
    echo ""
    echo "--- REPORT PREVIEW ---"
    head -n 50 "$REPORT_PATH"
    echo ""
    echo "--- For full report, see: $REPORT_PATH ---"
else
    echo "WARNING: Report file not found"
fi

echo ""
echo "═══════════════════════════════════════════════════════════"
echo "   Oracle Protocol Complete"
echo "═══════════════════════════════════════════════════════════"

# Cleanup binary
rm -f "$ORACLE_BIN"
