#!/usr/bin/env bash
# Red-Team Audit Hook — spawns a focused Claude instance to attack the code that
# was just committed, and PERSISTS every result so the audits are reviewable.
#
# Installed as a repo's .git/hooks/post-commit (or, under chronos, chained as
# .git/hooks/post-commit.pre-chronos and invoked only for real commits).
#
# Results collection (local to .git, not version-controlled, survives forever):
#   .git/red-team-audits/<short-sha>/
#       meta.json     — structured record (ts, commit, files, exit, verdict, …)
#       diff.patch    — the .zig diff that was audited
#       audit.md      — the auditor's full report (claude -p output)
#       verdict.txt   — CLEAN | FINDINGS | REVIEW | ERROR
#   .git/red-team-audits/index.jsonl  — one JSON line per audit (machine review)
#   .git/red-team-audits/index.md     — running human-readable table
#
# Review with:  red-team-report            (summary of all audits)
#               red-team-report <short-sha> (one audit's full report)
#
# Config:
#   git config hook.redteam false   — disable
#   RED_TEAM_CLAUDE=/path/to/claude  — override the claude binary (for testing)
#
# History: this hook silently no-op'd for ~2 months because the claude CLI
# stopped accepting a positional prompt placed AFTER --allowedTools, and the old
# `set -euo pipefail` aborted the subshell before anything was logged. Fixed:
# prompt is piped via stdin, and we do NOT use `set -e` around the audit.

ENABLED=$(git config --get hook.redteam 2>/dev/null || echo "true")
[ "$ENABLED" = "true" ] || exit 0

# Only audit when Zig source actually changed.
CHANGED=$(git diff-tree --no-commit-id --name-only -r HEAD -- '*.zig' 2>/dev/null || true)
[ -z "$CHANGED" ] && exit 0

# Never audit the auditor's own patch commits.
MSG=$(git log -1 --pretty=%B 2>/dev/null)
echo "$MSG" | grep -q "Red-Team-Audit" && exit 0

CLAUDE_BIN="${RED_TEAM_CLAUDE:-/opt/homebrew/bin/claude}"
COMMIT=$(git rev-parse --short HEAD)
COMMIT_FULL=$(git rev-parse HEAD)
SUBJECT=$(git log -1 --pretty=%s HEAD)
REPO_ROOT=$(git rev-parse --show-toplevel)
GITDIR=$(git rev-parse --absolute-git-dir)
COLLECTION="$GITDIR/red-team-audits"
OUTDIR="$COLLECTION/$COMMIT"
LOG="$GITDIR/red-team-audit.log"
WORKTREE="$GITDIR/red-team-worktree-$COMMIT"
BRANCH="red-team-audit-$COMMIT"
TS=$(date -Iseconds)

# Initialise the collection (synchronously, so the markdown header is race-free).
mkdir -p "$OUTDIR"
if [ ! -f "$COLLECTION/index.md" ]; then
  printf '# Red-Team Audit Index\n\n| Time | Commit | Verdict | Patched | Subject |\n|---|---|---|---|---|\n' > "$COLLECTION/index.md"
fi

# Run the audit in the background so the commit is never blocked.
(
  echo "════════════════════════════════════════════════════"
  echo "Red Team Audit started: $TS"
  echo "Commit: $COMMIT  ($SUBJECT)"
  echo "Changed files:"; echo "$CHANGED"

  # Capture the audited diff.
  if ! git diff HEAD~1..HEAD -- '*.zig' > "$OUTDIR/diff.patch" 2>/dev/null; then
    echo "(no parent / first commit)" > "$OUTDIR/diff.patch"
  fi
  DIFF=$(cat "$OUTDIR/diff.patch")

  # Isolated worktree so the auditor can patch without touching the builder tree.
  # Idempotent: clear any stale worktree AND branch from a prior run on this sha.
  if [ -d "$WORKTREE" ]; then git worktree remove --force "$WORKTREE" 2>/dev/null || rm -rf "$WORKTREE"; fi
  git worktree prune 2>/dev/null || true
  git branch -D "$BRANCH" 2>/dev/null || true
  git worktree add -b "$BRANCH" "$WORKTREE" HEAD >/dev/null 2>&1

  PROMPT="You are a security auditor. Red-team the code changes in commit $COMMIT ($SUBJECT).

Working directory: $WORKTREE

## Changed files
$CHANGED

## Diff
$DIFF

## Instructions
1. Read each changed file in full. Think like an attacker.
2. Check for: injection, SSRF, path traversal, timing side-channels, memory
   safety, DoS via parsing, credential leakage, missing validation, integer
   overflow.
3. For each finding: explain the attack, write a test that proves it, then patch.
4. Run tests: cd into the project dir and run 'zig build test'.
5. If all tests pass and you patched something, commit with a message starting
   'Red-Team-Audit:' and a summary. Do NOT push.
6. If no vulnerabilities are found, print exactly 'AUDIT CLEAN'.

Begin your report with one line:  VERDICT: CLEAN   or   VERDICT: FINDINGS (<n>)"

  if [ ! -d "$WORKTREE" ]; then
    echo "ERROR: could not create audit worktree ($WORKTREE) for $COMMIT" > "$OUTDIR/audit.md"
    EXIT_CODE=126
  else
    # FIX: feed the prompt on stdin. The current claude CLI rejects a positional
    # prompt placed after --allowedTools. Capture stdout+stderr to audit.md.
    ( cd "$WORKTREE" && printf '%s' "$PROMPT" | "$CLAUDE_BIN" -p \
          --allowedTools 'Bash,Read,Write,Edit,Glob,Grep' ) > "$OUTDIR/audit.md" 2>&1
    EXIT_CODE=$?
  fi

  # Did the auditor commit a patch on the branch?
  PATCH_COMMITS=$(git -C "$WORKTREE" rev-list --count "$COMMIT_FULL..$BRANCH" 2>/dev/null || echo 0)
  PATCHED="no"; [ "${PATCH_COMMITS:-0}" -gt 0 ] 2>/dev/null && PATCHED="yes"

  # Derive a verdict.
  if [ "$EXIT_CODE" -ne 0 ]; then
    VERDICT="ERROR"
  elif [ "$PATCHED" = "yes" ]; then
    VERDICT="FINDINGS"
  elif grep -qiE 'AUDIT CLEAN|VERDICT: *CLEAN' "$OUTDIR/audit.md" 2>/dev/null; then
    VERDICT="CLEAN"
  else
    VERDICT="REVIEW"   # ran, but no clear verdict — eyeball audit.md
  fi
  echo "$VERDICT" > "$OUTDIR/verdict.txt"

  # Structured record (JSON built by python3 from env — no shell string injection).
  RT_TS="$TS" RT_COMMIT="$COMMIT" RT_FULL="$COMMIT_FULL" RT_SUBJECT="$SUBJECT" \
  RT_FILES="$CHANGED" RT_EXIT="$EXIT_CODE" RT_VERDICT="$VERDICT" RT_PATCHED="$PATCHED" \
  RT_BRANCH="$BRANCH" RT_AUDIT="$OUTDIR/audit.md" python3 -c '
import json, os
files=[f for f in os.environ.get("RT_FILES","").splitlines() if f.strip()]
rec={"ts":os.environ["RT_TS"],"commit":os.environ["RT_COMMIT"],
     "commit_full":os.environ["RT_FULL"],"subject":os.environ["RT_SUBJECT"],
     "files":files,"exit":int(os.environ.get("RT_EXIT") or 0),
     "verdict":os.environ["RT_VERDICT"],"patched":os.environ["RT_PATCHED"],
     "branch":os.environ["RT_BRANCH"],"audit":os.environ["RT_AUDIT"]}
print(json.dumps(rec))' > "$OUTDIR/meta.json" 2>/dev/null

  # Append to the collection indexes.
  [ -s "$OUTDIR/meta.json" ] && cat "$OUTDIR/meta.json" >> "$COLLECTION/index.jsonl"
  SUBJ_SAFE=$(printf '%s' "$SUBJECT" | tr '|' '/' | cut -c1-60)
  printf '| %s | `%s` | %s | %s | %s |\n' "$TS" "$COMMIT" "$VERDICT" "$PATCHED" "$SUBJ_SAFE" >> "$COLLECTION/index.md"

  # Clean up the worktree; keep the branch ONLY when it carries a real patch.
  cd "$REPO_ROOT"
  git worktree remove --force "$WORKTREE" 2>/dev/null || rm -rf "$WORKTREE"
  [ "$PATCHED" != "yes" ] && { git branch -D "$BRANCH" 2>/dev/null || true; }

  echo "Audit finished: $(date -Iseconds)  verdict=$VERDICT patched=$PATCHED exit=$EXIT_CODE"
  if [ "$PATCHED" = "yes" ]; then
    echo "  -> patch on branch $BRANCH — review: git log $BRANCH --oneline; merge: git merge $BRANCH"
  fi
  echo "  -> report: red-team-report $COMMIT"
  echo "════════════════════════════════════════════════════"
) >> "$LOG" 2>&1 &

disown
exit 0
