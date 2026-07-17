#!/bin/bash
# Repeatable benchmark with regression tracking.
#
# Usage: ./scripts/bench-track.sh [runs]     (default 3)
#
# Builds ReleaseFast, runs tmux-bench N times, keeps the BEST of each metric
# (best-of-N filters scheduler noise — a regression can't hide behind a lucky
# run, only a noisy machine can under-report), appends a row to
# bench/results.csv with the git rev, and prints deltas vs the previous row.
# Throughput drops or latency rises beyond 10% exit non-zero, so this can gate
# CI or a pre-push hook.
set -euo pipefail
cd "$(dirname "$0")/.."
RUNS="${1:-3}"
CSV="bench/results.csv"

zig build -Doptimize=ReleaseFast >/dev/null

best_mixed=0; best_plain=0; best_pty=0; best_create=999999999; best_attach=999999999
for i in $(seq "$RUNS"); do
  out="$(./zig-out/bin/tmux-bench 2>&1)"
  mixed=$(awk  '/emulator mixed/  {print $(NF-1)}' <<<"$out")
  plain=$(awk  '/emulator plain/  {print $(NF-1)}' <<<"$out")
  pty=$(awk    '/pty ingest/      {print $(NF-1)}' <<<"$out")
  create=$(awk '/create\+destroy/ {print $2}'      <<<"$out")
  attach=$(awk '/attach\+detach/  {print $2}'      <<<"$out")
  best_mixed=$(awk  -v a="$best_mixed"  -v b="$mixed"  'BEGIN{print (b+0>a+0)?b:a}')
  best_plain=$(awk  -v a="$best_plain"  -v b="$plain"  'BEGIN{print (b+0>a+0)?b:a}')
  best_pty=$(awk    -v a="$best_pty"    -v b="$pty"    'BEGIN{print (b+0>a+0)?b:a}')
  best_create=$(awk -v a="$best_create" -v b="$create" 'BEGIN{print (b+0<a+0)?b:a}')
  best_attach=$(awk -v a="$best_attach" -v b="$attach" 'BEGIN{print (b+0<a+0)?b:a}')
  echo "run $i/$RUNS: mixed=${mixed} plain=${plain} pty=${pty} MiB/s · create=${create} attach=${attach} us/op"
done

mkdir -p bench
[ -f "$CSV" ] || echo "date,rev,mixed_mibs,plain_mibs,pty_mibs,create_us,attach_us" > "$CSV"
prev=$(tail -n 1 "$CSV")
rev=$(git rev-parse --short HEAD 2>/dev/null || echo unknown)
echo "$(date +%F),${rev},${best_mixed},${best_plain},${best_pty},${best_create},${best_attach}" >> "$CSV"

echo
echo "best-of-${RUNS}: mixed=${best_mixed} plain=${best_plain} pty=${best_pty} MiB/s · create=${best_create} attach=${best_attach} us/op"

# Compare vs previous row (skip when this is the first data row).
case "$prev" in date,*|"") echo "(no previous row — baseline recorded)"; exit 0;; esac
IFS=, read -r _ prev_rev p_mixed p_plain p_pty p_create p_attach <<<"$prev"
echo "vs ${prev_rev}:"
fail=0
check() { # name new old higher_is_better
  local d
  d=$(awk -v n="$2" -v o="$3" 'BEGIN{ if (o+0==0) {print 0; exit} printf "%.1f", (n-o)/o*100 }')
  echo "  $1: ${3} -> ${2}  (${d}%)"
  if [ "$4" = up ]; then
    awk -v d="$d" 'BEGIN{exit !(d < -10)}' && { echo "    ^ REGRESSION (>10% drop)"; fail=1; }
  else
    awk -v d="$d" 'BEGIN{exit !(d > 10)}'  && { echo "    ^ REGRESSION (>10% slower)"; fail=1; }
  fi
  return 0
}
check "mixed MiB/s" "$best_mixed"  "$p_mixed"  up
check "plain MiB/s" "$best_plain"  "$p_plain"  up
check "pty MiB/s"   "$best_pty"    "$p_pty"    up
check "create us"   "$best_create" "$p_create" down
check "attach us"   "$best_attach" "$p_attach" down
exit "$fail"
