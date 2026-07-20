#!/usr/bin/env bash
#
# End-to-end GNU-parity harness for zpinky (the strong external anchor).
#
# It diffs zpinky's output BYTE-FOR-BYTE against the real GNU coreutils `pinky`
# binary for every case whose output is deterministic (independent of live
# idle-time drift), and checks exit codes / streams for the error paths.
#
# Usage: gnu_diff.sh <path-to-zpinky>
# Exits non-zero on the first parity mismatch. Skips (exit 0) only if no GNU
# pinky binary can be found on the host.

set -u

ZP="${1:?usage: gnu_diff.sh <path-to-zpinky>}"

# Locate the real GNU pinky.
GP=""
for cand in \
    /opt/homebrew/bin/gpinky \
    /opt/homebrew/opt/coreutils/libexec/gnubin/pinky \
    "$(command -v gpinky 2>/dev/null || true)" \
    "$(command -v pinky 2>/dev/null || true)"; do
    if [ -n "$cand" ] && [ -x "$cand" ]; then
        # Confirm it is really GNU coreutils pinky, not some other 'pinky'.
        if "$cand" --version 2>/dev/null | head -1 | grep -qi 'coreutils'; then
            GP="$cand"
            break
        fi
    fi
done

if [ -z "$GP" ]; then
    echo "SKIP: no GNU coreutils pinky found on host; cannot run parity anchor" >&2
    exit 0
fi

echo "zpinky : $ZP"
echo "gnu    : $GP"

fails=0

# --- byte-exact stdout diff for a deterministic invocation ------------------
diff_out() {
    local desc="$1"; shift
    local g z
    g="$("$GP" "$@" 2>/dev/null)"
    z="$("$ZP" "$@" 2>/dev/null)"
    if [ "$g" == "$z" ]; then
        echo "PASS  stdout  $desc"
    else
        echo "FAIL  stdout  $desc"
        echo "  --- gnu ---"; printf '%s\n' "$g" | sed 's/^/    /'
        echo "  --- zpinky ---"; printf '%s\n' "$z" | sed 's/^/    /'
        fails=$((fails + 1))
    fi
}

# --- exit-code + stderr-substring check -------------------------------------
check_err() {
    local desc="$1"; local want_code="$2"; local want_sub="$3"; shift 3
    local err code
    err="$("$ZP" "$@" 2>&1 >/dev/null)"
    code=$?
    local gerr gcode
    gerr="$("$GP" "$@" 2>&1 >/dev/null)"
    gcode=$?
    local ok=1
    [ "$code" -eq "$want_code" ] || ok=0
    [ "$gcode" -eq "$want_code" ] || ok=0   # confirm GNU agrees on the code
    printf '%s' "$err" | grep -q "$want_sub" || ok=0
    if [ "$ok" -eq 1 ]; then
        echo "PASS  exit=$code err~'$want_sub'  $desc"
    else
        echo "FAIL  $desc (zpinky exit=$code, gnu exit=$gcode, want=$want_code)"
        echo "    zpinky stderr: $err"
        fails=$((fails + 1))
    fi
}

# --- stream check: informational output must go to stdout, stderr empty -----
check_info_stream() {
    local desc="$1"; shift
    local out err code
    out="$("$ZP" "$@" 2>/tmp/zpinky_err_$$)"
    code=$?
    err="$(cat /tmp/zpinky_err_$$)"; rm -f /tmp/zpinky_err_$$
    if [ "$code" -eq 0 ] && [ -n "$out" ] && [ -z "$err" ]; then
        echo "PASS  stream  $desc (stdout non-empty, stderr empty, exit 0)"
    else
        echo "FAIL  stream  $desc (exit=$code stdout_len=${#out} stderr_len=${#err})"
        fails=$((fails + 1))
    fi
}

# ===========================================================================
# Long format: reads only the account database (getpwnam) — fully deterministic.
# ===========================================================================
diff_out "long: -l root"                -l root
diff_out "long: -l nobody"              -l nobody
diff_out "long: -l daemon"              -l daemon
diff_out "long: -l root nobody daemon"  -l root nobody daemon
diff_out "long: -l unknown (???)"       -l zznosuchuser42
diff_out "long: -lb (omit home/shell)"  -lb root
diff_out "long: -lh (omit project)"     -lh root
diff_out "long: -lp (omit plan)"        -lp root
diff_out "long: bundled -lbhp"          -lbhp root nobody

# ===========================================================================
# Short format: '-q' omits the volatile idle column; the "When" column is the
# login timestamp (stable for the life of a session), so this is deterministic.
# ===========================================================================
diff_out "short: -q (no idle column)"   -q

# ===========================================================================
# Error paths and informational streams (GNU/POSIX contract).
# ===========================================================================
check_err "-l with no username errors" 1 "no username" -l
check_err "invalid option -Z errors"   1 "invalid option" -Z
check_err "unrecognized --bogus errors" 1 "unrecognized option" --bogus
check_info_stream "--version to stdout" --version
check_info_stream "--help to stdout"    --help

echo
if [ "$fails" -eq 0 ]; then
    echo "ALL PARITY CHECKS PASSED"
    exit 0
else
    echo "$fails PARITY CHECK(S) FAILED"
    exit 1
fi
