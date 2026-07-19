#!/usr/bin/env bash
# End-to-end behavioural tests for the `trash` binary.
#
# This tool's failure mode is permanent data loss, so the assertions are always
# the same pair: the original is GONE, and the bytes are RECOVERABLE. Every
# case restores what it trashed, so the run leaves nothing behind in the real
# trash — and `trash empty` is never invoked.
#
# Usage: integration.sh /path/to/trash [scratch-dir]
#
# The scratch dir must be a throwaway directory. It is created fresh and is
# only ever populated with files this script wrote.

set -uo pipefail

TRASH="${1:?usage: integration.sh <path-to-trash-binary> [scratch-dir]}"
[ -x "$TRASH" ] || { echo "not executable: $TRASH" >&2; exit 1; }
TRASH="$(cd "$(dirname "$TRASH")" && pwd)/$(basename "$TRASH")"

RUN_ID="zigtrash-it-$$-$(date +%s)"
SCRATCH_ROOT="${2:-${TMPDIR:-/tmp}}"
WORK="$SCRATCH_ROOT/$RUN_ID"

# Safety rail: never operate inside a git work tree (the repo) or in $HOME.
case "$WORK" in
  "$HOME"|"$HOME"/Documents/*|"$HOME"/Desktop/*)
    echo "refusing to use a scratch dir inside your home: $WORK" >&2; exit 1;;
esac
if git -C "$SCRATCH_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
  echo "refusing to use a scratch dir inside a git work tree: $SCRATCH_ROOT" >&2
  exit 1
fi

mkdir -p "$WORK" || exit 1
# Canonicalise: the tool records realpath()'d originals, so a scratch root with
# a trailing slash or a symlinked component (macOS $TMPDIR has both) would make
# every `restore <path>` pattern miss.
WORK="$(cd "$WORK" && pwd -P)"

PASS=0
FAIL=0
ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (got '$2', want '$3')"; fi; }

section() { printf '\n== %s\n' "$1"; }

# Print the JSON entries whose original path contains the run id.
mine_json() {
  "$TRASH" list --json | python3 -c '
import json,sys
rid = sys.argv[1]
data = json.load(sys.stdin)          # hard-fails if --json is not valid JSON
print(json.dumps([e for e in data if rid in e["path"]]))
' "$RUN_ID"
}

mine_count() { mine_json | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))'; }

# ── 1. regular file: gone, listed, recoverable ──────────────────────────────
section "regular file"
F="$WORK/hello.txt"
printf 'canary-%s\n' "$RUN_ID" > "$F"
BEFORE="$(cat "$F")"
"$TRASH" "$F" >/dev/null 2>&1; check "trash exits 0" "$?" "0"
[ -e "$F" ] && bad "original removed" || ok "original removed"
check "listed exactly once" "$(mine_count)" "1"
"$TRASH" restore "$F" >/dev/null 2>&1; check "restore exits 0" "$?" "0"
[ -f "$F" ] && ok "file is back" || bad "file is back"
check "contents byte-identical" "$(cat "$F" 2>/dev/null)" "$BEFORE"
check "no longer listed" "$(mine_count)" "0"

# ── 2. directory with nested contents ───────────────────────────────────────
section "directory (recursive)"
D="$WORK/tree"
mkdir -p "$D/a/b"
echo one > "$D/a/1.txt"; echo two > "$D/a/b/2.txt"
SIG_BEFORE="$( (cd "$D" && find . | sort && cat a/1.txt a/b/2.txt) )"
"$TRASH" -r "$D" >/dev/null 2>&1; check "trash -r exits 0" "$?" "0"
[ -e "$D" ] && bad "directory removed" || ok "directory removed"
"$TRASH" restore "$D" >/dev/null 2>&1; check "restore exits 0" "$?" "0"
SIG_AFTER="$( (cd "$D" && find . | sort && cat a/1.txt a/b/2.txt) 2>/dev/null )"
check "tree + contents identical" "$SIG_AFTER" "$SIG_BEFORE"
"$TRASH" restore "$D" >/dev/null 2>&1  # drain any stale metadata; ignore result

# ── 3. symlink: the LINK goes, the TARGET stays (rm semantics) ──────────────
section "symlink"
T="$WORK/target.txt"; L="$WORK/link.txt"
echo target-data > "$T"
ln -s "$T" "$L"
"$TRASH" "$L" >/dev/null 2>&1; check "trash exits 0" "$?" "0"
[ -e "$T" ] && ok "TARGET SURVIVES (data-loss regression)" || bad "TARGET SURVIVES (data-loss regression)"
check "target contents intact" "$(cat "$T" 2>/dev/null)" "target-data"
[ -L "$L" ] && bad "link removed" || ok "link removed"
"$TRASH" restore "$L" >/dev/null 2>&1
[ -L "$L" ] && ok "restored as a symlink, not a copy" || bad "restored as a symlink, not a copy"
check "link still points at target" "$(readlink "$L" 2>/dev/null)" "$T"

# ── 4. dangling symlink is trashable (access() follows links) ───────────────
section "dangling symlink"
DL="$WORK/dangling.txt"
ln -s "$WORK/does-not-exist" "$DL"
"$TRASH" "$DL" >/dev/null 2>&1; check "trash exits 0" "$?" "0"
[ -L "$DL" ] && bad "dangling link removed" || ok "dangling link removed"
"$TRASH" restore "$DL" >/dev/null 2>&1
[ -L "$DL" ] && ok "restored" || bad "restored"

# ── 5. basename collision: two different files, same name ──────────────────
section "name collision"
mkdir -p "$WORK/c1" "$WORK/c2"
echo first  > "$WORK/c1/dup.txt"
echo second > "$WORK/c2/dup.txt"
"$TRASH" "$WORK/c1/dup.txt" "$WORK/c2/dup.txt" >/dev/null 2>&1
check "both trashed, exit 0" "$?" "0"
check "both tracked separately" "$(mine_count)" "2"
"$TRASH" restore "$WORK/c1/dup.txt" >/dev/null 2>&1
"$TRASH" restore "$WORK/c2/dup.txt" >/dev/null 2>&1
check "first restored with its own bytes"  "$(cat "$WORK/c1/dup.txt" 2>/dev/null)" "first"
check "second restored with its own bytes" "$(cat "$WORK/c2/dup.txt" 2>/dev/null)" "second"

# ── 6. hostile filenames: JSON output must stay parseable ──────────────────
section "hostile filenames (JSON injection)"
# Quotes, a backslash, a comma, a brace-object AND an embedded newline — all
# legal in a POSIX filename. The quotes/backslash break a printf-built JSON
# object; the newline forges extra lines in a raw (unencoded) .trashinfo.
Q="$WORK/"$'quote"and\\backslash,{"path":"pwned"}\nsecond-line.txt'
printf 'q\n' > "$Q"
"$TRASH" "$Q" >/dev/null 2>&1; check "trash exits 0" "$?" "0"
if mine_json >/dev/null 2>&1; then ok "list --json still parses"; else bad "list --json still parses"; fi
check "quoted name listed once" "$(mine_count)" "1"
RTPATH="$(mine_json | python3 -c 'import json,sys; print(json.load(sys.stdin)[0]["path"])')"
check "path survives the JSON round trip" "$RTPATH" "$Q"
"$TRASH" restore "$Q" >/dev/null 2>&1
[ -f "$Q" ] && ok "restored" || bad "restored"

# ── 7. --dry-run must not touch anything ───────────────────────────────────
section "--dry-run"
DR="$WORK/dryrun.txt"; echo dr > "$DR"
"$TRASH" -n "$DR" >/dev/null 2>&1; check "exits 0" "$?" "0"
[ -f "$DR" ] && ok "file untouched" || bad "file untouched"
check "nothing added to trash" "$(mine_count)" "0"

# ── 8. missing paths, empty argument ───────────────────────────────────────
section "error handling"
"$TRASH" "$WORK/nope.txt" >/dev/null 2>&1; check "missing file exits 1" "$?" "1"
"$TRASH" -f "$WORK/nope.txt" >/dev/null 2>&1; check "missing file with -f exits 0" "$?" "0"
"$TRASH" "" >/dev/null 2>&1; RC=$?
[ "$RC" -eq 1 ] && ok "empty argument exits 1 (no panic)" || bad "empty argument exits 1 (no panic), got $RC"
# NOTE: `empty --older -1d` is deliberately NOT exercised here. If the negative
# -age guard ever regresses, running it would permanently delete the caller's
# entire trash. The guard is covered by the parseAge anchors in tier1_anchors.zig.
"$TRASH" restore "" >/dev/null 2>&1; check "empty restore pattern rejected" "$?" "1"

# ── 9. leftovers ───────────────────────────────────────────────────────────
section "cleanup"
LEFT="$(mine_count)"
check "nothing left in the trash from this run" "$LEFT" "0"
if [ "$LEFT" != "0" ]; then
  echo "  leftover entries (restore or remove by hand):" >&2
  mine_json >&2
fi
# The scratch dir is left in place on purpose — this script does not delete
# anything it did not create, and nothing here is worth an `rm -rf` in a tool
# whose whole point is to avoid one.
printf '  scratch dir: %s\n' "$WORK"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
