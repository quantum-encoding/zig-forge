#!/usr/bin/env bash
# Guardian Shield v9 - uninstaller.
#
#   1. If enforcement is live (pins under /sys/fs/bpf/guardian_shield), runs
#      the loader with --unpin to detach every LSM hook (refcount-to-zero
#      teardown - see V9_STATUS.md "LSM link lifecycle").
#   2. Stops any still-running loader/logger instance.
#   3. Removes the install directory.
#
# Usage:  ./uninstall.sh [--prefix DIR]     (default /opt/guardian-shield)
#
# Note: if this box previously ran in hardening_mode, --unpin MUST be executed
# by the installed (trusted) loader binary - which is exactly what this script
# does, before deleting it. If teardown ever reports pins it cannot remove,
# the guaranteed fallback is a reboot: all BPF state (pins, links, maps) is
# discarded at boot. That is fail-secure, not a fault.

set -euo pipefail

PREFIX="/opt/guardian-shield"
while [ $# -gt 0 ]; do
  case "$1" in
    --prefix) PREFIX="${2:?--prefix requires a directory}"; shift 2 ;;
    -h|--help) sed -n '2,16p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "ERROR: unknown argument '$1'" >&2; exit 2 ;;
  esac
done

SUDO=""
[ "$(id -u)" != 0 ] && SUDO="sudo"

# Read pin_dir from the installed config so a customized pin_dir is honored.
PIN_DIR="/sys/fs/bpf/guardian_shield"
if [ -f "$PREFIX/config.json" ] && command -v jq >/dev/null 2>&1; then
  PIN_DIR="$(jq -r '.pin_dir // "/sys/fs/bpf/guardian_shield"' "$PREFIX/config.json")"
fi

# 1. Detach live enforcement first, while the trusted loader still exists.
if $SUDO test -d "$PIN_DIR" 2>/dev/null; then
  if [ -x "$PREFIX/guardian_shield_loader" ] && [ -f "$PREFIX/config.json" ]; then
    echo "-- live pins found under $PIN_DIR: unpinning --"
    $SUDO "$PREFIX/guardian_shield_loader" "$PREFIX/config.json" --unpin
  else
    echo "WARNING: pins exist under $PIN_DIR but the installed loader/config is missing." >&2
    echo "  Enforcement is still active. Either re-run install.sh and then this script," >&2
    echo "  or reboot (all BPF pins/links are discarded at boot - guaranteed teardown)." >&2
    exit 1
  fi
else
  echo "-- no live pins under $PIN_DIR (enforcement not active) --"
fi

# 2. Stop any lingering loader/logger instance (comm is truncated to 15 chars).
$SUDO pkill -x guardian_shield 2>/dev/null || true

# 3. Remove installed artifacts.
if [ -d "$PREFIX" ]; then
  echo "-- removing $PREFIX --"
  $SUDO rm -rf -- "$PREFIX"
fi

# Confirm teardown actually happened before declaring success.
if $SUDO test -d "$PIN_DIR" 2>/dev/null; then
  echo "WARNING: $PIN_DIR still exists after teardown. Reboot to guarantee all" >&2
  echo "  BPF links/pins are released (fail-secure fallback)." >&2
  exit 1
fi

echo "Guardian Shield v9 uninstalled. (Log file /var/log/guardian_shield.jsonl left in place; remove it manually if desired.)"
