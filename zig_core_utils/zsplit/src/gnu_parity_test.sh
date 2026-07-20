#!/bin/bash
# External-anchor parity test: diff zsplit output against the REAL GNU
# coreutils `split` binary (gsplit). This is the strongest anchor per the
# zig-forge golden rule -- expected outputs come from a different, authoritative
# implementation, not from zsplit itself.
#
# Usage: gnu_parity_test.sh <zsplit-binary> [gnu-split-binary]
# Exits 0 on full parity, 1 on any divergence. If no GNU split is found the
# harness prints a clear SKIP and exits 0 (build stays green on machines that
# lack coreutils), so it never silently "passes" a broken binary.
set -u

ZS="${1:?usage: gnu_parity_test.sh <zsplit> [gsplit]}"
# Resolve to an absolute path before we cd into a temp dir below.
case "$ZS" in
  /*) : ;;
  *)  ZS="$(cd "$(dirname "$ZS")" && pwd)/$(basename "$ZS")" ;;
esac
GS="${2:-}"
if [ -z "$GS" ]; then
  for cand in /opt/homebrew/bin/gsplit /opt/homebrew/opt/coreutils/libexec/gnubin/split /usr/local/bin/gsplit "$(command -v gsplit 2>/dev/null)"; do
    if [ -n "$cand" ] && [ -x "$cand" ]; then GS="$cand"; break; fi
  done
fi
if [ -z "$GS" ] || [ ! -x "$GS" ]; then
  echo "SKIP: no GNU split (gsplit) binary found; cannot run external-anchor parity test."
  exit 0
fi

echo "zsplit = $ZS"
echo "gnu    = $GS"

BASE=$(mktemp -d)
trap 'find "$BASE" -mindepth 1 -delete 2>/dev/null' EXIT
cd "$BASE"

fails=0
pass(){ echo "  ok   $1"; }
fail(){ echo "  FAIL $1"; fails=$((fails+1)); }

# Build a spread of representative inputs.
python3 -c "import sys;sys.stdout.write(''.join(f'line {i:04d}\n' for i in range(1,201)))" > lines200.txt   # 2000 bytes, 200 lines
python3 -c "import sys;sys.stdout.write('x'*21)" > raw21.txt                                                 # 21 bytes, no newline
python3 -c "import sys,os;sys.stdout.buffer.write(os.urandom(0))" > empty.txt                                # 0 bytes
python3 -c "import sys;sys.stdout.write('\n'.join('a'*40 for _ in range(10))+'\n')" > longlines.txt          # 10 x 41-byte lines
head -c 5000 /dev/urandom > rand5000.bin

# compare_dirs Z G  -> parity of file names and bytes
compare_dirs(){
  local zf gf
  zf=$(cd "$1" && ls | sort | tr '\n' ' ')
  gf=$(cd "$2" && ls | sort | tr '\n' ' ')
  if [ "$zf" != "$gf" ]; then
    echo "    file lists differ:"; echo "      zsplit: $zf"; echo "      gnu:    $gf"; return 1
  fi
  local name
  for name in $(cd "$2" && ls); do
    if ! cmp -s "$1/$name" "$2/$name"; then
      echo "    contents differ for $name"; return 1
    fi
  done
  return 0
}

# run_case "label" input -- flags...
run_case(){
  local label="$1"; shift
  local input="$1"; shift
  local z g; z=$(mktemp -d); g=$(mktemp -d)
  ( cd "$z" && "$ZS" "$@" "$BASE/$input" ) >/dev/null 2>&1
  local zrc=$?
  ( cd "$g" && "$GS" "$@" "$BASE/$input" ) >/dev/null 2>&1
  local grc=$?
  if [ "$zrc" != "$grc" ]; then
    fail "$label (exit $zrc vs gnu $grc)"; find "$z" "$g" -mindepth 1 -delete; return
  fi
  if compare_dirs "$z" "$g"; then pass "$label"; else fail "$label"; fi
  find "$z" "$g" -mindepth 1 -delete
}

# error_case "label" input rc -- flags...   (only exit-code parity matters)
error_case(){
  local label="$1"; shift
  local input="$1"; shift
  local z g; z=$(mktemp -d); g=$(mktemp -d)
  ( cd "$z" && "$ZS" "$@" "$BASE/$input" ) >/dev/null 2>&1; local zrc=$?
  ( cd "$g" && "$GS" "$@" "$BASE/$input" ) >/dev/null 2>&1; local grc=$?
  if [ "$zrc" = "$grc" ]; then pass "$label (exit $zrc)"; else fail "$label (exit $zrc vs gnu $grc)"; fi
  find "$z" "$g" -mindepth 1 -delete
}

# mode_case: assert output file permission bits match GNU (open() ABI fix).
mode_case(){
  local z g; z=$(mktemp -d); g=$(mktemp -d)
  ( cd "$z" && "$ZS" "$BASE/lines200.txt" ) >/dev/null 2>&1
  ( cd "$g" && "$GS" "$BASE/lines200.txt" ) >/dev/null 2>&1
  local zm gm
  zm=$(stat -f '%A' "$z/xaa" 2>/dev/null || stat -c '%a' "$z/xaa")
  gm=$(stat -f '%A' "$g/xaa" 2>/dev/null || stat -c '%a' "$g/xaa")
  if [ "$zm" = "$gm" ]; then pass "output file mode ($zm)"; else fail "output file mode ($zm vs gnu $gm)"; fi
  find "$z" "$g" -mindepth 1 -delete
}

echo "-- success cases --"
run_case "default (1000 lines)"   lines200.txt
run_case "-l 7"                   lines200.txt -l 7
run_case "-l 50"                  lines200.txt -l 50
run_case "-b 100"                 lines200.txt -b 100
run_case "-b 1K"                  rand5000.bin -b 1K
run_case "-b 7 (raw21)"           raw21.txt   -b 7
run_case "-C 80 line-bytes"       lines200.txt -C 80
run_case "-C 40 longlines"        longlines.txt -C 40
run_case "-n 3"                   lines200.txt -n 3
run_case "-n 7"                   lines200.txt -n 7
run_case "-n 4 (raw21)"           raw21.txt   -n 4
run_case "-n 3 (rand5000)"        rand5000.bin -n 3
run_case "-n 10 (raw21, empties)" raw21.txt   -n 10
run_case "-d numeric -l 30"       lines200.txt -d -l 30
run_case "-a 3 -l 40"             lines200.txt -a 3 -l 40
run_case "-a 20 -b 5 (raw21)"     raw21.txt   -a 20 -b 5
run_case "--additional-suffix"    lines200.txt -l 60 --additional-suffix=.txt
run_case "--numeric-suffixes=5"   lines200.txt --numeric-suffixes=5 -l 40
run_case "empty input -l 10"      empty.txt   -l 10

echo "-- error / exit-code cases --"
error_case "-b 0 rejected"        raw21.txt   1 -b 0
error_case "-C 0 rejected"        raw21.txt   1 -C 0
error_case "-l 0 rejected"        raw21.txt   1 -l 0
error_case "-n 0 rejected"        raw21.txt   1 -n 0
error_case "suffixes exhausted"   lines200.txt 1 -a 1 -l 1

echo "-- permission-mode case --"
mode_case

echo
if [ "$fails" -eq 0 ]; then
  echo "PARITY OK: all cases match GNU split."
  exit 0
else
  echo "PARITY FAILED: $fails case(s) diverged from GNU split."
  exit 1
fi
