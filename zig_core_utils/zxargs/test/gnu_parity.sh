#!/usr/bin/env bash
#
# gnu_parity.sh — externally-anchored behavior tests for zxargs.
#
# Two kinds of anchor, per zig-forge/CLAUDE.md's golden rule (NO roundtrip-only tests):
#
#   [XARGS]  Diffed live against the real system xargs binary (/usr/bin/xargs, a
#            BSD/POSIX implementation the zxargs author did not write). Used for the
#            behaviors that POSIX/BSD/GNU all agree on (basic batching, -n, -0, -s
#            byte-splitting, command-not-found=127, cannot-execute=126, -n0 rejected).
#
#   [GNU]    Documented GNU findutils xargs(1) EXIT STATUS, expected bytes/codes
#            written literally here. GNU deliberately differs from BSD on these:
#              123  a command exited 1..125
#              124  a command exited 255
#              125  a command was killed by a signal
#            Source: GNU findutils manual, "xargs" -> "Exit status"
#            (https://www.gnu.org/software/findutils/manual/html_node/xargs-options.html)
#            and xargs(1). BSD /usr/bin/xargs returns 1 for all three, so those cases
#            are anchored to the GNU spec, not diffed against the system binary.
#
# Usage: gnu_parity.sh [path-to-zxargs]     (or set ZXARGS_BIN)

set -u

ZX="${1:-${ZXARGS_BIN:-./zig-out/bin/zxargs}}"
SYS_XARGS="/usr/bin/xargs"

if [ ! -x "$ZX" ]; then
    echo "FATAL: zxargs binary not found/executable at: $ZX" >&2
    exit 2
fi

pass=0
fail=0
tmpd="$(mktemp -d)"
trap 'rm -rf "$tmpd"' EXIT

# ---- helpers ---------------------------------------------------------------

# run BIN ARGS... < stdin_data(as $STDIN); sets OUT (stdout) and RC (exit code)
run() {
    local bin="$1"; shift
    OUT="$(printf '%b' "$STDIN" | "$bin" "$@" 2>/dev/null)"
    RC=$?
}

ok()   { pass=$((pass+1)); }
bad()  { fail=$((fail+1)); echo "FAIL: $1" >&2; }

# [XARGS] anchor: our stdout must byte-match the system xargs' stdout for the same input+args
diff_xargs() {
    local desc="$1"; shift
    run "$SYS_XARGS" "$@"; local sys_out="$OUT"
    run "$ZX"        "$@"; local our_out="$OUT"
    if [ "$sys_out" = "$our_out" ]; then
        ok
    else
        bad "$desc  [system xargs] $(printf %q "$sys_out")  !=  [zxargs] $(printf %q "$our_out")"
    fi
}

# [XARGS] anchor: our exit code must match the system xargs' exit code
diff_xargs_rc() {
    local desc="$1"; shift
    run "$SYS_XARGS" "$@"; local sys_rc="$RC"
    run "$ZX"        "$@"; local our_rc="$RC"
    if [ "$sys_rc" = "$our_rc" ]; then
        ok
    else
        bad "$desc  [system xargs rc=$sys_rc]  !=  [zxargs rc=$our_rc]"
    fi
}

# [GNU] anchor: our stdout must equal a literal expected value
expect_out() {
    local desc="$1" want="$2"; shift 2
    run "$ZX" "$@"
    if [ "$OUT" = "$want" ]; then ok; else
        bad "$desc  want $(printf %q "$want")  got $(printf %q "$OUT")"
    fi
}

# [GNU] anchor: our exit code must equal a literal expected value
expect_rc() {
    local desc="$1" want="$2"; shift 2
    run "$ZX" "$@"
    if [ "$RC" = "$want" ]; then ok; else
        bad "$desc  want rc=$want  got rc=$RC"
    fi
}

# ---- [XARGS] diffed live against /usr/bin/xargs ----------------------------

STDIN='a b c d\n'
diff_xargs "basic: all items to one echo"           echo
diff_xargs "-n2 batching"                     -n2   echo
diff_xargs "-n1 batching"                     -n1   echo
diff_xargs "-n3 batching (remainder)"         -n3   echo

STDIN='aa bb cc dd\n'
diff_xargs "-s10 splits by byte budget"       -s 10 echo
diff_xargs "-s11 splits by byte budget"       -s 11 echo
diff_xargs "-s20 fits on one line"            -s 20 echo

# -0 null-delimited input (safe filenames)
STDIN='a\0b\0c\0'
diff_xargs "-0 null-delimited"                -0    echo

# command not found -> 127 (POSIX/BSD/GNU agree)
STDIN='x\n'
diff_xargs_rc "not found -> 127"                    /nonexistent/zzz_cmd

# a regular non-executable file cannot be run -> 126 (POSIX/BSD/GNU agree)
noexec="$tmpd/noexec"; printf 'plain text\n' > "$noexec"; chmod 644 "$noexec"
STDIN='x\n'
diff_xargs_rc "cannot execute -> 126"               "$noexec"

# -n0 is rejected (nonzero exit) by both BSD and GNU
STDIN='x\n'
diff_xargs_rc "-n0 rejected (nonzero)"        -n0   echo

# ---- [GNU] documented findutils xargs(1) EXIT STATUS -----------------------
# (BSD /usr/bin/xargs returns 1 for these; the GNU convention is what zxargs targets.)

STDIN='x\n'
expect_rc "GNU: command exits 1..125 -> 123"  123   false
expect_rc "GNU: command exits 255     -> 124" 124   sh -c 'exit 255'
expect_rc "GNU: command killed by sig  -> 125" 125  sh -c 'kill -TERM $$'

# -n0 specifically exits 1 (xargs' own usage error), per GNU "value for -n option should be >= 1"
expect_rc "GNU: -n0 usage error -> 1"          1    -n0 echo

# ---- [GNU] documented -I replace and unterminated-quote behavior -----------

STDIN='x\ny\n'
expect_out "-I{} one command per item"  "item x
item y"   -I{} echo item {}

# GNU xargs: an unmatched quote in the input is a fatal error (exit 1).
# Ref: xargs(1) "unmatched ... quote".  BSD accepts it silently, so [GNU]-anchored.
STDIN='a"b\n'
expect_rc "GNU: unterminated quote is fatal -> 1"  1  echo

# GNU -x: exit (rc 1) when a single item cannot fit the -s byte budget.
# Ref: xargs(1) "-x ... Exit if the command line ... exceeds the ... size".
STDIN='aaaaaaaaaaaaaaaa\n'
expect_rc "GNU: -x + oversized item -> 1"          1    -s 8 -x echo
# Without -x, an item that alone exceeds -s is still run (cannot be split).
expect_out "GNU: no -x, oversized item still runs" "aaaaaaaaaaaaaaaa"  -s 8 echo

# ---- summary ---------------------------------------------------------------

echo "zxargs gnu_parity: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
