#!/bin/bash
# install.sh — build + install the full chronos stamping/telemetry stack on macOS.
#
# Installs to /usr/local/bin:
#   chronos-stamp          (chronos_engine/chronos-stamp-macos — Phi timestamp gen)
#   chronos-hook           (this dir — PostToolUse tick committer, per-repo gated)
#   get-cognitive-state    (chronos_engine/scripts — cross-platform state reader)
#   chronos-post-commit    (squash accumulated ticks into the real commit + push)
#   chronos-enable-repo    (opt a repo in: sets git config + post-commit shim)
#   chronos-disable-repo   (opt a repo back out)
#
# After installing, enable per repo with:  chronos-enable-repo /path/to/repo
# and wire the PostToolUse hook in ~/.claude/settings.json to /usr/local/bin/chronos-hook.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
engine="$here/../../chronos_engine"

echo "🔨 Building chronos-hook..."
( cd "$here" && zig build )

echo "🔨 Building chronos-stamp-macos..."
( cd "$engine" && zig build )

echo "📦 Installing binaries + scripts to /usr/local/bin (sudo)..."
sudo install -m 0755 "$here/zig-out/bin/chronos-hook"             /usr/local/bin/chronos-hook
sudo install -m 0755 "$engine/zig-out/bin/chronos-stamp-macos"    /usr/local/bin/chronos-stamp
sudo install -m 0755 "$engine/scripts/get-cognitive-state"        /usr/local/bin/get-cognitive-state
sudo install -m 0755 "$here/chronos-post-commit"                  /usr/local/bin/chronos-post-commit
sudo install -m 0755 "$here/chronos-push"                        /usr/local/bin/chronos-push
sudo install -m 0755 "$here/chronos-enable-repo"                  /usr/local/bin/chronos-enable-repo
sudo install -m 0755 "$here/chronos-disable-repo"                 /usr/local/bin/chronos-disable-repo
sudo install -m 0755 "$here/red-team-report"                     /usr/local/bin/red-team-report

# Optional: the red-team auditor hook. Deploy it into a repo's post-commit (or,
# under chronos, as post-commit.pre-chronos so it runs on the squashed commit):
#   install -m 0755 "$here/red-team-audit-hook.sh" "$(git -C <repo> rev-parse --git-path hooks)/post-commit.pre-chronos"
# Results land in <repo>/.git/red-team-audits/ — review with: red-team-report

echo "✅ chronos stack installed."

# Pre-flight the cognitive telemetry source so a misconfigured host is caught
# here, not after weeks of NOT-DETECTED stamps. On Linux this also creates the
# watcher DB + schema; on macOS it verifies libcognitive-capture.dylib is present.
echo "🩺 Pre-flight: verifying cognitive telemetry source..."
if ! /usr/local/bin/get-cognitive-state --init; then
  echo "⚠️  telemetry preflight reported an issue (see above) — stamps may read NOT-DETECTED."
  if [ "$(uname -s 2>/dev/null)" = "Darwin" ]; then
    echo "    macOS capture lib lives in cognitive_telemetry_kit/libcognitive-capture;"
    echo "    build it and: sudo install -m0755 zig-out/lib/libcognitive-capture.dylib /usr/local/lib/"
  fi
fi

echo
echo "Next:"
echo "  1) Ensure ~/.claude/settings.json has a PostToolUse '*' hook -> /usr/local/bin/chronos-hook"
echo "  2) Enable a repo:   chronos-enable-repo /path/to/repo   (sets chronos.enabled, installs shim)"
echo "  3) Work — each tool action leaves a [CHRONOS] tick commit."
echo "  4) Ship:            chronos-push [-m \"message\"]          (squash ticks into one commit + push)"
echo "  5) Disable a repo:  chronos-disable-repo /path/to/repo"
echo
echo "Note: there is no auto-push. The squash+push is the explicit 'chronos-push' step."
