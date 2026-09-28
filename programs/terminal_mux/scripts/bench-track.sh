#!/bin/bash
# Superseded by scripts/bench-run.py, which records every sample and the
# machine state, and compares runs with a noise-aware rule. Kept so existing
# muscle memory and hooks still work: `bench-track.sh [runs]`.
#
# bench/results.csv holds the schema-1 history (text-scraped best-of-N); it is
# not comparable with bench-run.py's numbers — see bench/NOTES.md.
set -euo pipefail
exec python3 "$(dirname "$0")/bench-run.py" --repeat "${1:-5}" --fail-on-regression
