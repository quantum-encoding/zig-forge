#!/usr/bin/env bash
#
# Externally-anchored parity tests for zpwd.
#
# THE ANCHOR is the real GNU coreutils `pwd` binary (9.x). For a spread of
# flag / env / cwd combinations we run BOTH zpwd and GNU pwd with an identical
# (argv, cwd, environment) and require their STDOUT and EXIT CODE to match.
# The expected outputs come from a program zpwd's author did not write, so this
# is a genuine external anchor (not a roundtrip / self-consistency check).
#
# stderr text is intentionally NOT compared: GNU emits its program name
# ("pwd:") in diagnostics while zpwd emits "zpwd:", a legitimate difference.
# We compare stderr only where GNU/POSIX pins the STREAM (help/version -> stdout).
#
# Usage: gnu_parity.sh <path-to-zpwd-binary>
#
# Exit 0 = all parity assertions held. Exit 1 = a mismatch (printed). Exit 2 =
# no GNU pwd binary found (cannot anchor) -> hard fail, we do not silently pass.

set -u

ZPWD="${1:?usage: gnu_parity.sh <zpwd-binary>}"
# Resolve to an absolute path: the harness cd's into a sandbox before exec'ing.
case "$ZPWD" in
    /*) : ;; # already absolute
    *)  ZPWD="$(cd "$(dirname "$ZPWD")" && pwd)/$(basename "$ZPWD")" ;;
esac

# --- locate the GNU pwd binary (the external anchor) ------------------------
GNU=""
for c in \
    /opt/homebrew/opt/coreutils/libexec/gnubin/pwd \
    /opt/homebrew/bin/gpwd \
    /usr/local/opt/coreutils/libexec/gnubin/pwd \
    /usr/bin/pwd
do
    if [ -x "$c" ]; then
        # Confirm it is actually GNU coreutils (has --version with "coreutils").
        if "$c" --version 2>/dev/null | grep -qi "coreutils"; then
            GNU="$c"
            break
        fi
    fi
done

if [ -z "$GNU" ]; then
    echo "FATAL: no GNU coreutils pwd binary found; cannot anchor tests." >&2
    exit 2
fi

echo "anchor GNU pwd: $GNU"
echo "under test:     $ZPWD"

FAILS=0
PASSES=0

# --- sandbox: a symlink so logical(-L) and physical(-P) paths differ --------
SB="$(mktemp -d "${TMPDIR:-/tmp}/zpwd_parity.XXXXXX")"
mkdir -p "$SB/real"
ln -sf "$SB/real" "$SB/link"
LINK="$SB/link"
cleanup() { rm -rf "$SB"; }
trap cleanup EXIT

# run BIN in cwd=$LINK with env overrides (KEY=VAL ...) then given args.
# Prints: "<exit>\n<stdout>"
run_one() {
    local bin="$1"; shift
    local envs=() ; local a
    while [ $# -gt 0 ] && [[ "$1" == *=* ]] && [[ "$1" != -* ]]; do
        envs+=("$1"); shift
    done
    local out rc
    out="$(cd "$LINK" && env -u POSIXLY_CORRECT "${envs[@]}" "$bin" "$@" 2>/dev/null)"
    rc=$?
    printf '%s\n%s' "$rc" "$out"
}

# parity <label> [ENV=VAL ...] -- [args...]
# compares zpwd vs GNU stdout+exit for identical (env,args) in cwd=$LINK.
parity() {
    local label="$1"; shift
    local envs=()
    while [ "$1" != "--" ]; do envs+=("$1"); shift; done
    shift # drop --
    local z g
    z="$(run_one "$ZPWD" "${envs[@]}" "$@")"
    g="$(run_one "$GNU"  "${envs[@]}" "$@")"
    if [ "$z" = "$g" ]; then
        PASSES=$((PASSES+1))
        echo "PASS  $label"
    else
        FAILS=$((FAILS+1))
        echo "FAIL  $label"
        echo "        args:  $*"
        echo "        env:   ${envs[*]:-<none>}"
        echo "        zpwd:  exit+stdout = [${z}]"
        echo "        gnu:   exit+stdout = [${g}]"
    fi
}

# === parity cases (anchored to GNU pwd output) ==============================

# Default mode is PHYSICAL (GNU 9.x); PWD is the logical entry path.
parity "default (=> physical)"        "PWD=$LINK" --
parity "-L logical"                   "PWD=$LINK" -- -L
parity "-P physical"                  "PWD=$LINK" -- -P
parity "--logical"                    "PWD=$LINK" -- --logical
parity "--physical"                   "PWD=$LINK" -- --physical
parity "-LP (last wins => physical)"  "PWD=$LINK" -- -LP
parity "-PL (last wins => logical)"   "PWD=$LINK" -- -PL

# POSIXLY_CORRECT flips the default to logical.
parity "POSIXLY_CORRECT default"      "PWD=$LINK" "POSIXLY_CORRECT=1" --

# -L must reject a poisoned/stale PWD and fall back to physical.
parity "-L bogus PWD -> physical"     "PWD=/totally/bogus/nope" -- -L
parity "-L empty PWD -> physical"     "PWD=" -- -L
parity "-L relative PWD -> physical"  "PWD=relative/path" -- -L

# -L must reject PWD containing '.'/'..' components -> physical.
parity "-L dotdot PWD -> physical"    "PWD=$SB/link/../link" -- -L
parity "-L dot PWD -> physical"       "PWD=$SB/./link" -- -L

# End-of-options marker: '--' accepted, exit 0, prints cwd.
parity "bare -- ends options"         "PWD=$LINK" -- --

# Non-option operands ignored: stdout + exit 0 must match (stderr text differs).
parity "operand 'foo' ignored"        "PWD=$LINK" -- foo
parity "operand then flag 'foo -P'"   "PWD=$LINK" -- foo -P
parity "bare '-' is an operand"       "PWD=$LINK" -- -

# Invalid option: both must exit nonzero (stdout empty on both).
parity "invalid short -x"             "PWD=$LINK" -- -x
parity "invalid long --bogus"         "PWD=$LINK" -- --bogus

# === documented-stream anchors (GNU/POSIX: --help/--version -> STDOUT, rc 0) =
# coreutils manual "Common options": --help/--version print on standard output;
# POSIX Utility Conventions. Verify the STREAM + exit code, not GNU's wording.
stream_check() {
    local label="$1" flag="$2"
    local so se rc
    so="$(cd "$LINK" && "$ZPWD" "$flag" 2>/dev/null)"
    se="$(cd "$LINK" && "$ZPWD" "$flag" 2>&1 >/dev/null)"
    "$ZPWD" "$flag" >/dev/null 2>&1; rc=$?
    if [ -n "$so" ] && [ -z "$se" ] && [ "$rc" -eq 0 ]; then
        PASSES=$((PASSES+1)); echo "PASS  $label"
    else
        FAILS=$((FAILS+1))
        echo "FAIL  $label (stdout_len=${#so} stderr_len=${#se} rc=$rc; want stdout>0,stderr=0,rc=0)"
    fi
}
stream_check "--help -> stdout, exit 0"    --help
stream_check "--version -> stdout, exit 0" --version

# === summary ===============================================================
echo "-------------------------------------------"
echo "zpwd GNU-parity: $PASSES passed, $FAILS failed"
[ "$FAILS" -eq 0 ] || exit 1
exit 0
