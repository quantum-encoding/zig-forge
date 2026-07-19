#!/usr/bin/env bash
# Chronos — uninstaller for both tiers.
#
#   1. Removes the Chronos PostToolUse hook from ~/.claude/settings.json
#      (idempotent, backs the file up first, never touches other hooks).
#   2. If the systemd --user daemon unit is installed, stops + disables it, then
#      removes the unit file.
#   3. Relocates the installed Chronos binaries/scripts out of the prefix.
#
# On removal we do NOT use bare `rm`: it is blocked by Guardian Shield on some
# boxes (and forbidden by org convention), and calling a removal tool from inside
# a script can poison the shell. Instead every removed file is MOVED into a
# timestamped backup dir and its location printed — recoverable, and safe on any
# machine. Delete that backup dir by hand when you are satisfied.
#
# What it deliberately LEAVES: per-repo opt-in state. A repo you ran
# `chronos-enable-repo` on still has `git config chronos.enabled true` and its
# post-commit shim. Turn those off per repo with:  chronos-disable-repo /path/to/repo
# (do that BEFORE removing the binaries if you want the shim's target to still exist).
#
# Usage:
#   ./uninstall.sh                    # ~/.local/bin + ~/.claude/settings.json
#   ./uninstall.sh --prefix DIR
#   ./uninstall.sh --system           # /usr/local/bin (sudo)
#   ./uninstall.sh --settings PATH
#   ./uninstall.sh --keep-settings    # leave settings.json untouched
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREFIX="$HOME/.local/bin"
SYSTEM=0
SETTINGS="${CHRONOS_SETTINGS:-$HOME/.claude/settings.json}"
TOUCH_SETTINGS=1
UNIT_DIR="${CHRONOS_USER_UNIT_DIR:-$HOME/.config/systemd/user}"

usage() { sed -n '2,29p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
  case "$1" in
    --prefix)        PREFIX="${2:?--prefix requires a directory}"; shift 2 ;;
    --system)        SYSTEM=1; PREFIX="/usr/local/bin"; shift ;;
    --settings)      SETTINGS="${2:?--settings requires a path}"; shift 2 ;;
    --keep-settings) TOUCH_SETTINGS=0; shift ;;
    -h|--help)       usage; exit 0 ;;
    *) echo "ERROR: unknown argument '$1'" >&2; usage >&2; exit 2 ;;
  esac
done

SUDO=""
if [ "$SYSTEM" = 1 ] || { [ -e "$PREFIX" ] && [ ! -w "$PREFIX" ]; }; then
  [ "$(id -u)" != 0 ] && SUDO="sudo"
fi

BACKUP="${TMPDIR:-/tmp}/chronos-uninstalled-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BACKUP"

# Relocate a file into $BACKUP (never rm). Preserves the basename.
relocate() {  # relocate <path>
  local p="$1"
  [ -e "$p" ] || [ -L "$p" ] || return 0
  $SUDO mv -f "$p" "$BACKUP/$(basename "$p")"
  echo "  moved $p -> $BACKUP/"
}

echo "== Chronos uninstaller =="
echo "   prefix=$PREFIX  settings=$SETTINGS  backup=$BACKUP"
echo ""

# 1. Unwire the settings.json hook.
if [ "$TOUCH_SETTINGS" = 1 ]; then
  if command -v python3 >/dev/null 2>&1; then
    echo "-- removing PostToolUse hook from $SETTINGS --"
    python3 "$SCRIPT_DIR/chronos-settings-hook.py" --remove --settings "$SETTINGS" || true
  else
    echo "-- python3 not found: leaving settings.json alone. Remove the chronos-hook PostToolUse entry by hand. --"
  fi
  echo ""
fi

# 2. Stop + remove the systemd --user daemon unit if present.
UNIT="$UNIT_DIR/chronosd.service"
if [ -f "$UNIT" ]; then
  echo "-- removing systemd --user daemon unit --"
  if command -v systemctl >/dev/null 2>&1; then
    systemctl --user disable --now chronosd.service 2>/dev/null || true
  fi
  relocate "$UNIT"
  command -v systemctl >/dev/null 2>&1 && systemctl --user daemon-reload 2>/dev/null || true
  echo ""
fi

# 3. Relocate installed binaries/scripts.
echo "-- relocating installed binaries from $PREFIX --"
for f in chronos-hook chronos-stamp chronos-push chronos-enable-repo \
         chronos-disable-repo chronos-post-commit chronos-hook-install-all \
         chronosd get-cognitive-state cognitive-query; do
  relocate "$PREFIX/$f"
done

echo ""
echo "== uninstalled =="
echo "Removed files were moved to: $BACKUP"
echo "  (nothing was hard-deleted; remove that dir yourself when satisfied)"
echo ""
echo "NOTE: repos you opted in are still ticking. For each one, run BEFORE relying on it:"
echo "   chronos-disable-repo /path/to/repo"
echo "(its post-commit shim referenced the now-moved chronos-post-commit.)"
