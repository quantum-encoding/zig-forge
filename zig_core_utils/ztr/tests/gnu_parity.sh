#!/usr/bin/env bash
#
# gnu_parity.sh — externally-anchored parity tests for ztr (GNU `tr` clone).
#
# The anchor is the REAL GNU coreutils `tr` binary. For every case below we run
# the same input through both ztr and GNU tr and require byte-identical stdout
# plus a matching exit class (success vs failure). This is a true external
# anchor per zig-forge/CLAUDE.md §1: the expected outputs are produced by an
# implementation ztr's author did not write.
#
# A second block (LITERAL ANCHORS) asserts documented GNU/POSIX byte outputs
# hard-coded here (with citations), so the suite still proves something on a
# machine without GNU tr installed.
#
# Usage: gnu_parity.sh <path-to-ztr>
# Exit 0 = all parity checks passed; nonzero = at least one mismatch.

set -u

ZTR="${1:-zig-out/bin/ztr}"
if [[ ! -x "$ZTR" ]]; then
  echo "FATAL: ztr binary not found/executable at '$ZTR'" >&2
  exit 2
fi

# Locate a real GNU tr. Homebrew installs it as `gtr` and under gnubin/.
GTR=""
for c in \
  /opt/homebrew/opt/coreutils/libexec/gnubin/tr \
  /usr/local/opt/coreutils/libexec/gnubin/tr \
  /opt/homebrew/bin/gtr \
  /usr/local/bin/gtr \
  gtr; do
  if command -v "$c" >/dev/null 2>&1; then
    # Confirm it is really GNU coreutils, not BSD tr.
    if "$c" --version 2>/dev/null | head -1 | grep -qi 'GNU coreutils'; then
      GTR="$c"; break
    fi
  fi
done

fail=0
pass=0

# --- Block 1: differential parity against the real GNU binary -----------------
# check <description> <input-as-printf-string> <ztr args...>
check() {
  local desc="$1"; local input="$2"; shift 2
  if [[ -z "$GTR" ]]; then return; fi
  local z_out g_out z_rc g_rc
  z_out=$(printf '%b' "$input" | "$ZTR"  "$@" 2>/dev/null); z_rc=${PIPESTATUS[1]:-$?}
  g_out=$(printf '%b' "$input" | "$GTR"  "$@" 2>/dev/null); g_rc=${PIPESTATUS[1]:-$?}
  # Compare stdout exactly, and exit *class* (0 vs non-0) — exact codes for
  # error cases are not part of the contract, only success/failure is.
  local z_cls=$(( z_rc == 0 ? 0 : 1 ))
  local g_cls=$(( g_rc == 0 ? 0 : 1 ))
  if [[ "$z_out" == "$g_out" && "$z_cls" == "$g_cls" ]]; then
    pass=$((pass+1))
  else
    fail=$((fail+1))
    printf 'FAIL [%s]\n  args:  %s\n  ztr => %q (rc %s)\n  gnu => %q (rc %s)\n' \
      "$desc" "$*" "$z_out" "$z_rc" "$g_out" "$g_rc" >&2
  fi
}

# Translate
check "basic upper"            "hello\n"        a-z A-Z
check "range translate"        "hello world\n"  'a-y' 'b-z'
check "single char"            "banana\n"       a X
check "class lower->upper"     "MixedCase\n"    '[:lower:]' '[:upper:]'
check "class upper->lower"     "MixedCase\n"    '[:upper:]' '[:lower:]'
check "class alnum"            "a1!z9?\n"       '[:alnum:]' X   # was a silent no-op before fix
check "class alpha"            "a1!z9?\n"       '[:alpha:]' X
check "class digit"            "a1!z9?\n"       '[:digit:]' X
check "class xdigit"           "1a2g3F!\n"      '[:xdigit:]' X  # was a silent no-op before fix
check "class blank"            "a\tb c\n"       '[:blank:]' _   # was a silent no-op before fix
check "class cntrl"            "a\x01b\x1fc\n"  '[:cntrl:]' X   # was a silent no-op before fix
check "class graph"            "a b\tc\n"       '[:graph:]' X   # was a silent no-op before fix
check "class print"            "a b\tc\n"       '[:print:]' X   # was a silent no-op before fix
check "class punct"            "a!b?c.\n"       '[:punct:]' X   # was a silent no-op before fix
check "class space"            "a b\tc\nd\n"    '[:space:]' _
check "shorter set2 pad"       "abcdef\n"       abcdef xy       # last char pads
check "escape newline src"     "a\nb\n"         '\n' _
check "escape tab src"         "a\tb\n"         '\t' _
check "escape bell"            "a\x07b\n"       '\a' _          # \a not decoded before fix
check "escape backspace"       "a\x08b\n"       '\b' _          # \b not decoded before fix
check "escape formfeed"        "a\x0cb\n"       '\f' _          # \f not decoded before fix
check "escape vtab"            "a\x0bb\n"       '\v' _          # \v not decoded before fix
check "octal escape"           "a\x07b\n"       '\007' X
check "octal escape 2"         "aXb\n"          '\130' Y        # \130 = 'X'

# Repeat construct [c*] / [c*n]
check "repeat fill mid"        "abcde\n"        abcde 'x[y*]'   # brackets leaked before fix
check "repeat fill whole"      "abc\n"          a-c '[x*]'      # brackets leaked before fix
check "repeat n decimal"       "abcde\n"        abcde '[x*3]y'
check "repeat n octal"         "aaaabbbb\n"     a-d '[x*012]'

# Complement translate (the flagship bug: every byte was replaced before fix)
check "complement translate"   "abc123\n"       -c 0-9 X
check "complement multichar"   "\x00\x01\x02abc\n" -c abc YZ
check "complement all-alpha"   "he11o w0rld\n"  -c '[:alpha:]' .

# Delete
check "delete vowels"          "hello world\n"  -d aeiou
check "delete class"           "a1b2c3\n"       -d '[:digit:]'
check "delete complement"      "a1b2c3\n"       -cd '[:digit:]'
check "delete newline"         "a\nb\nc\n"      -d '\n'

# Squeeze
check "squeeze spaces"         "a   b     c\n"  -s ' '
check "squeeze class"          "aabbccdd\n"     -s '[:lower:]'
check "squeeze after translate" "aaabbb\n"      -s ab xy
check "complement squeeze"     "abc!!!def??\n"  -cs '[:alnum:]' X
check "delete+squeeze"         "aabbccdd\n"     -ds a b

# Truncate
check "truncate set1"          "abcdef\n"       -t abcdef xy
check "truncate equal"         "abc\n"          -t abc xyz

# Error / edge cases (exit class must match; stdout empty on error)
check "empty set2 errors"      "x\n"            a ''
check "reverse range set1"     "x\n"            z-x y
check "reverse range set2"     "abc\n"          a-c z-x
check "delete two operands"    "ab\n"           -d a b
check "three operands"         "ab\n"           a b c

# Larger input to exercise the 8192-byte flush / short-write path
BIG=$(printf 'a%.0s' {1..20000})
check "large input translate"  "$BIG\n"         a-z A-Z
check "large input squeeze"    "$BIG\n"         -s a

# --- Block 2: literal documented anchors (run even without GNU installed) ------
# Expected bytes are GNU coreutils 9.x / POSIX documented outputs, cited inline.
lit() {
  local desc="$1"; local input="$2"; local expect="$3"; shift 3
  local got
  got=$(printf '%b' "$input" | "$ZTR" "$@" 2>/dev/null)
  if [[ "$got" == "$(printf '%b' "$expect")" ]]; then
    pass=$((pass+1))
  else
    fail=$((fail+1))
    printf 'FAIL(literal) [%s]\n  args: %s\n  got:      %q\n  expected: %q\n' \
      "$desc" "$*" "$got" "$(printf '%b' "$expect")" >&2
  fi
}

# POSIX tr, GNU tr manual: `tr abcde 'x[y*]'` pads set2 to xyyyy.
lit "man: repeat fill"      "abcde" "xyyyy"   abcde 'x[y*]'
# GNU: complement replaces only the complement, leaving digits intact.
lit "man: complement"      "abc123" "XXX123"  -c 0-9 X
# GNU/POSIX: [:upper:] -> [:lower:] lowercases.
lit "man: case fold"       "HELLO"  "hello"   '[:upper:]' '[:lower:]'
# GNU tr manual example: squeeze repeated spaces.
lit "man: squeeze"         "a    b" "a b"     -s ' '
# GNU/POSIX: -d deletes the SET.
lit "man: delete"          "Hello"  "Hll"     -d aeo

echo "gnu_parity: $pass passed, $fail failed$( [[ -z "$GTR" ]] && echo ' (GNU tr not found: differential block skipped, literal anchors ran)' || echo " (GNU: $GTR)" )"
[[ $fail -eq 0 ]] && exit 0 || exit 1
