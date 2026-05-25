#!/usr/bin/env bash
# jesternet-server — Linux systemd installer.
#
# Run as root on a fresh Linux box (Debian/Ubuntu/Fedora — any
# distro with systemd). Idempotent: re-running upgrades the binary
# + reloads the unit + restarts the service. Doesn't touch
# /var/lib/jesternet's contents on rerun (so data_dir survives
# upgrades).
#
# Usage:
#   sudo ./setup.sh                  # install fresh OR upgrade existing
#   sudo ./setup.sh --bin <path>     # install from a specific binary path
#                                    # (default: ./jesternet-server next to this script,
#                                    # or ../zig-out/bin/jesternet-server)
#   sudo ./setup.sh --uninstall      # stop, disable, remove unit + user
#                                    # (PRESERVES /var/lib/jesternet by default)
#   sudo ./setup.sh --uninstall --purge-data
#                                    # also rm -rf /var/lib/jesternet (destructive)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ── Configuration ──────────────────────────────────────────────
SERVICE_NAME="jesternet-server"
USER_NAME="jesternet"
GROUP_NAME="jesternet"
DATA_DIR="/var/lib/jesternet"
BIN_DEST="/usr/local/bin/jesternet-server"
UNIT_DEST="/etc/systemd/system/${SERVICE_NAME}.service"
UNIT_SRC="${SCRIPT_DIR}/${SERVICE_NAME}.service"

# Binary source: --bin overrides; otherwise probe sensible locations.
BIN_SRC=""
UNINSTALL=false
PURGE_DATA=false

for arg in "$@"; do
  case "$arg" in
    --bin) shift; BIN_SRC="$1"; shift ;;
    --bin=*) BIN_SRC="${arg#--bin=}" ;;
    --uninstall) UNINSTALL=true ;;
    --purge-data) PURGE_DATA=true ;;
    --help|-h)
      sed -n '2,/^$/p' "$0" | sed 's/^# //; s/^#//'
      exit 0
      ;;
  esac
done

# ── Preconditions ─────────────────────────────────────────────
if [ "$(id -u)" -ne 0 ]; then
  echo "✗ Must run as root (try: sudo $0)" >&2
  exit 1
fi

if ! command -v systemctl >/dev/null 2>&1; then
  echo "✗ systemctl not found — this script needs a systemd-managed host" >&2
  exit 1
fi

# ── Uninstall path ────────────────────────────────────────────
if [ "$UNINSTALL" = true ]; then
  echo "→ Stopping ${SERVICE_NAME}..."
  systemctl stop "$SERVICE_NAME" 2>/dev/null || true
  systemctl disable "$SERVICE_NAME" 2>/dev/null || true
  rm -f "$UNIT_DEST"
  systemctl daemon-reload
  rm -f "$BIN_DEST"

  if id -u "$USER_NAME" >/dev/null 2>&1; then
    userdel "$USER_NAME" 2>/dev/null || true
  fi
  if getent group "$GROUP_NAME" >/dev/null 2>&1; then
    groupdel "$GROUP_NAME" 2>/dev/null || true
  fi

  if [ "$PURGE_DATA" = true ]; then
    echo "→ Purging ${DATA_DIR}..."
    rm -rf "$DATA_DIR"
  else
    echo "ℹ ${DATA_DIR} preserved (pass --purge-data to remove)"
  fi
  echo "✓ Uninstalled"
  exit 0
fi

# ── Resolve binary source ──────────────────────────────────────
if [ -z "$BIN_SRC" ]; then
  for candidate in \
    "${SCRIPT_DIR}/jesternet-server" \
    "${SCRIPT_DIR}/../zig-out/bin/jesternet-server" \
    "${SCRIPT_DIR}/../../zig-out/bin/jesternet-server"; do
    if [ -x "$candidate" ]; then
      BIN_SRC="$candidate"
      break
    fi
  done
fi

if [ -z "$BIN_SRC" ] || [ ! -x "$BIN_SRC" ]; then
  echo "✗ Binary not found. Build first (zig build -Doptimize=ReleaseSafe" >&2
  echo "  -Dtarget=x86_64-linux-gnu) and either pass --bin <path> or" >&2
  echo "  place the binary next to this script." >&2
  exit 1
fi

if [ ! -f "$UNIT_SRC" ]; then
  echo "✗ Systemd unit file missing at $UNIT_SRC" >&2
  exit 1
fi

# ── User + group ──────────────────────────────────────────────
if ! getent group "$GROUP_NAME" >/dev/null 2>&1; then
  echo "→ Creating group ${GROUP_NAME}..."
  groupadd --system "$GROUP_NAME"
fi
if ! id -u "$USER_NAME" >/dev/null 2>&1; then
  echo "→ Creating user ${USER_NAME}..."
  useradd \
    --system \
    --gid "$GROUP_NAME" \
    --home-dir "$DATA_DIR" \
    --no-create-home \
    --shell /usr/sbin/nologin \
    --comment "jesternet-server runtime user" \
    "$USER_NAME"
fi

# ── Data dir ──────────────────────────────────────────────────
if [ ! -d "$DATA_DIR" ]; then
  echo "→ Creating ${DATA_DIR}..."
  install -d -m 0750 -o "$USER_NAME" -g "$GROUP_NAME" "$DATA_DIR"
else
  chown "$USER_NAME:$GROUP_NAME" "$DATA_DIR"
  chmod 0750 "$DATA_DIR"
fi

# ── Install binary ────────────────────────────────────────────
echo "→ Installing binary to ${BIN_DEST}..."
install -m 0755 -o root -g root "$BIN_SRC" "$BIN_DEST"

# ── Install systemd unit ──────────────────────────────────────
echo "→ Installing unit to ${UNIT_DEST}..."
install -m 0644 -o root -g root "$UNIT_SRC" "$UNIT_DEST"

# ── Reload + (re)start ────────────────────────────────────────
systemctl daemon-reload

# Enable starts on boot; restart is idempotent (start if stopped,
# restart if running).
if ! systemctl is-enabled --quiet "$SERVICE_NAME"; then
  echo "→ Enabling ${SERVICE_NAME}..."
  systemctl enable "$SERVICE_NAME"
fi

echo "→ Restarting ${SERVICE_NAME}..."
systemctl restart "$SERVICE_NAME"

# ── Health check ──────────────────────────────────────────────
# Give the server a couple seconds to come up + bind. /healthz is
# the no-auth liveness endpoint; expect 200 "ok\n".
sleep 2
if curl -fsS -m 5 http://127.0.0.1:8080/healthz >/dev/null 2>&1; then
  HEALTH="✓ Health OK (200)"
else
  HEALTH="⚠ /healthz didn't respond — check 'journalctl -u ${SERVICE_NAME} -n 50'"
fi

echo ""
echo "═══════════════════════════════════════════════════════"
echo "✓ jesternet-server installed"
echo "  Binary:   ${BIN_DEST}"
echo "  Data dir: ${DATA_DIR} (owner ${USER_NAME}:${GROUP_NAME}, 0750)"
echo "  Unit:     ${UNIT_DEST}"
echo "  ${HEALTH}"
echo ""
echo "  Logs:     journalctl -u ${SERVICE_NAME} -f"
echo "  Status:   systemctl status ${SERVICE_NAME}"
echo "  Restart:  systemctl restart ${SERVICE_NAME}"
echo "═══════════════════════════════════════════════════════"
