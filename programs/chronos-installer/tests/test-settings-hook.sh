#!/usr/bin/env bash
# test-settings-hook.sh — exercise chronos-settings-hook.py against a THROWAWAY
# settings.json in a temp dir. It NEVER touches the operator's real
# ~/.claude/settings.json: every path here lives under a mktemp -d sandbox.
#
# Covers: fresh add, idempotent re-add (no duplicate), refresh on changed command,
# preservation of an unrelated pre-existing hook, backup creation, removal (and
# that removal leaves the unrelated hook intact), and malformed-JSON refusal.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="$HERE/../chronos-settings-hook.py"
SANDBOX="$(mktemp -d)"
# We deliberately do NOT delete the sandbox in-process. Bare `rm` is forbidden
# (org convention + this box's Guardian Shield blocks it), and invoking a removal
# tool from inside a script can poison the shell's exit status here. Leaving a
# mktemp dir behind is harmless and universally safe; its path is printed so it
# can be removed by hand (or by the OS temp reaper) afterwards. The `exit "$rc"`
# preserves the real pass/fail status through the trap.
cleanup() { local rc=$?; echo "note: test sandbox left at $SANDBOX"; exit "$rc"; }
trap cleanup EXIT

S="$SANDBOX/settings.json"
CMD="CHRONOS_STAMP_BIN=/home/tester/.local/bin/chronos-stamp /home/tester/.local/bin/chronos-hook"
PASS=0; FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
bad()  { echo "  FAIL: $1" >&2; FAIL=$((FAIL+1)); }

jqget() { python3 -c "import json,sys; print(json.load(open('$1')))"; }
count_chronos() { python3 -c "import json; d=json.load(open('$1')); print(sum(1 for m in d.get('hooks',{}).get('PostToolUse',[]) for h in m.get('hooks',[]) if 'chronos-hook' in h.get('command','')))"; }
count_ptu_hooks() { python3 -c "import json; d=json.load(open('$1')); print(sum(len(m.get('hooks',[])) for m in d.get('hooks',{}).get('PostToolUse',[])))"; }

echo "== chronos-settings-hook.py test suite (sandbox: $SANDBOX) =="

# --- 1. Seed a settings.json with an UNRELATED PostToolUse hook + a permission.
cat > "$S" <<'JSON'
{
  "permissions": { "allow": ["Bash(ls:*)"] },
  "hooks": {
    "PostToolUse": [
      { "matcher": "Edit", "hooks": [ { "type": "command", "command": "/opt/other/formatter.sh" } ] }
    ]
  }
}
JSON

# --- 2. Add the Chronos hook.
python3 "$HELPER" --add --command "$CMD" --settings "$S" >/dev/null
[ "$(count_chronos "$S")" = "1" ] && ok "add: exactly one chronos hook present" || bad "add: chronos hook count != 1"
[ -f "$S.chronos.bak" ] && ok "add: backup file created" || bad "add: no backup created"
python3 -c "import json; d=json.load(open('$S')); assert d['permissions']['allow']==['Bash(ls:*)']; assert any(h.get('command')=='/opt/other/formatter.sh' for m in d['hooks']['PostToolUse'] for h in m['hooks'])" \
  && ok "add: unrelated permission + formatter hook preserved" || bad "add: clobbered unrelated config"

# --- 3. Idempotent re-add with the SAME command -> no duplicate, count stays 1.
python3 "$HELPER" --add --command "$CMD" --settings "$S" >/dev/null
[ "$(count_chronos "$S")" = "1" ] && ok "re-add (same cmd): still exactly one chronos hook" || bad "re-add duplicated the hook"

# --- 4. Re-add with a DIFFERENT command -> refreshed in place, still count 1.
CMD2="CHRONOS_STAMP_BIN=/usr/local/bin/chronos-stamp /usr/local/bin/chronos-hook"
python3 "$HELPER" --add --command "$CMD2" --settings "$S" >/dev/null
[ "$(count_chronos "$S")" = "1" ] && ok "refresh: still one chronos hook after command change" || bad "refresh duplicated the hook"
python3 -c "import json; d=json.load(open('$S')); assert any(h.get('command')=='$CMD2' for m in d['hooks']['PostToolUse'] for h in m['hooks'])" \
  && ok "refresh: command updated in place" || bad "refresh: command not updated"

# --- 5. --check reports present.
python3 "$HELPER" --check --settings "$S" >/dev/null && ok "check: reports present (exit 0)" || bad "check: reported absent"

# --- 6. Remove -> chronos gone, unrelated formatter hook still there.
python3 "$HELPER" --remove --settings "$S" >/dev/null
[ "$(count_chronos "$S")" = "0" ] && ok "remove: chronos hook gone" || bad "remove: chronos hook remained"
python3 -c "import json; d=json.load(open('$S')); assert any(h.get('command')=='/opt/other/formatter.sh' for m in d['hooks']['PostToolUse'] for h in m['hooks'])" \
  && ok "remove: unrelated formatter hook preserved" || bad "remove: destroyed unrelated hook"
python3 "$HELPER" --check --settings "$S" >/dev/null && bad "check: still reports present after remove" || ok "check: reports absent after remove (exit 1)"

# --- 7. Fresh add into a NON-EXISTENT settings.json (new user).
S2="$SANDBOX/new/settings.json"
python3 "$HELPER" --add --command "$CMD" --settings "$S2" >/dev/null
[ "$(count_chronos "$S2")" = "1" ] && ok "fresh file: creates settings.json with the hook" || bad "fresh file: hook not added"

# --- 8. Malformed JSON is refused, file untouched.
S3="$SANDBOX/bad.json"
printf '{ this is : not json' > "$S3"
before="$(cat "$S3")"
if python3 "$HELPER" --add --command "$CMD" --settings "$S3" >/dev/null 2>&1; then
  bad "malformed: helper did NOT refuse malformed JSON"
else
  [ "$(cat "$S3")" = "$before" ] && ok "malformed: refused and left file untouched" || bad "malformed: modified an unparseable file"
fi

# --- 9. Add preserves a SIBLING hook inside the SAME '*' matcher.
S4="$SANDBOX/sibling.json"
cat > "$S4" <<'JSON'
{ "hooks": { "PostToolUse": [ { "matcher": "*", "hooks": [ { "type": "command", "command": "/opt/audit.sh" } ] } ] } }
JSON
python3 "$HELPER" --add --command "$CMD" --settings "$S4" >/dev/null
[ "$(count_ptu_hooks "$S4")" = "2" ] && ok "sibling: chronos appended alongside sibling in same matcher" || bad "sibling: matcher hook count != 2"
python3 "$HELPER" --remove --settings "$S4" >/dev/null
python3 -c "import json; d=json.load(open('$S4')); assert any(h.get('command')=='/opt/audit.sh' for m in d['hooks']['PostToolUse'] for h in m['hooks'])" \
  && ok "sibling: remove kept the sibling audit hook" || bad "sibling: remove destroyed the sibling"

echo ""
echo "== results: $PASS passed, $FAIL failed =="
[ "$FAIL" = "0" ] && exit 0 || exit 1
