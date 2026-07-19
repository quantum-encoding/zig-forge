#!/usr/bin/env bash
# Chronos — installer for the LINUX D-BUS DAEMON tier (the "original" depth).
#
# This is an OPTIONAL add-on on top of the git-provenance tier (install.sh). It
# builds and installs `chronosd` — the D-Bus turn-complete / cognitive emitter —
# plus its cognitive-state helpers, then renders a systemd --user unit pointing at
# the resolved install path. With it, [CHRONOS] ticks carry the live cognitive
# gerund instead of the tool-activity fallback, and turn-complete signals are
# emitted on the session bus.
#
# Platform: LINUX ONLY. On macOS the git-provenance tier is the whole story (there
# is no chronosd); this script refuses to run on Darwin.
#
# What it does NOT do: it never starts or enables the daemon. Starting a daemon
# is the operator's decision — the exact `systemctl --user enable --now` command
# is PRINTED at the end for you to run after review.
#
# Usage:
#   ./install-daemon.sh                  # build + install to ~/.local/bin, render --user unit
#   ./install-daemon.sh --prefix DIR     # alternate install dir
#   ./install-daemon.sh --system         # install to /usr/local/bin (sudo); still renders a --user unit
#   ./install-daemon.sh --skip-build     # reuse existing zig-out artifacts
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_SRC="${CHRONOS_ENGINE_SRC:-$SCRIPT_DIR/../chronos_engine}"

PREFIX="$HOME/.local/bin"
SYSTEM=0
SKIP_BUILD=0
UNIT_DIR="${CHRONOS_USER_UNIT_DIR:-$HOME/.config/systemd/user}"

# The daemon binary the engine's build.zig produces for the D-Bus cognitive/turn-
# complete emitter. Overridable in case the engine renames it. NOTE for the
# Architect: build.zig currently emits `chronosd-cognitive` (the unified daemon),
# while the legacy system unit references `chronosd-dbus`; we install it under the
# name `chronosd` so quantum-diary's which("chronosd") detection lights up.
DAEMON_ARTIFACT="${CHRONOS_DAEMON_ARTIFACT:-chronosd-cognitive}"

usage() { sed -n '2,28p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
  case "$1" in
    --prefix)     PREFIX="${2:?--prefix requires a directory}"; shift 2 ;;
    --system)     SYSTEM=1; PREFIX="/usr/local/bin"; shift ;;
    --skip-build) SKIP_BUILD=1; shift ;;
    -h|--help)    usage; exit 0 ;;
    *) echo "ERROR: unknown argument '$1'" >&2; usage >&2; exit 2 ;;
  esac
done

FAILED=0
fail() { echo "" >&2; echo "MISSING PREREQUISITE: $1" >&2; echo "  remediation: $2" >&2; FAILED=1; }
note() { echo "  [ok] $*"; }

echo "== Chronos D-Bus daemon installer (Linux tier) =="
echo "   prefix=$PREFIX  unit-dir=$UNIT_DIR  daemon=$DAEMON_ARTIFACT"
echo ""

# Platform gate.
if [ "$(uname -s 2>/dev/null)" != "Linux" ]; then
  echo "This tier is Linux-only (no chronosd on macOS). Nothing to do." >&2
  exit 0
fi

echo "-- checking prerequisites --"
# zig 0.16+
if ! command -v zig >/dev/null 2>&1; then
  fail "zig not found (required: Zig 0.16+)" "install Zig 0.16+ from https://ziglang.org/download/"
else
  ZV="$(zig version)"; ZMAJ="${ZV%%.*}"; ZREST="${ZV#*.}"; ZMIN="${ZREST%%[!0-9]*}"
  if [ "$ZMAJ" -eq 0 ] && [ "${ZMIN:-0}" -lt 16 ]; then
    fail "zig $ZV is too old (engine uses the Zig 0.16 std API)" "install Zig 0.16+ from https://ziglang.org/download/"
  else note "zig $ZV"; fi
fi

# libdbus-1 dev (the daemon links -ldbus-1).
if command -v pkg-config >/dev/null 2>&1 && pkg-config --exists dbus-1; then
  note "libdbus-1 dev present ($(pkg-config --modversion dbus-1))"
else
  fail "libdbus-1 development files not found" \
       "install dbus dev (Arch: pacman -S dbus; Debian/Ubuntu: apt install libdbus-1-dev; and pkg-config)"
fi

# libbpf + sqlite3 dev (the engine's cognitive targets link -lbpf -lsqlite3).
[ -f /usr/include/bpf/libbpf.h ] && note "libbpf dev present" || \
  fail "libbpf dev not found (/usr/include/bpf/libbpf.h)" "install libbpf (Arch: pacman -S libbpf; Debian/Ubuntu: apt install libbpf-dev)"
[ -f /usr/include/sqlite3.h ] && note "sqlite3 dev present" || \
  fail "sqlite3 dev not found (/usr/include/sqlite3.h)" "install sqlite3 dev (Arch: pacman -S sqlite; Debian/Ubuntu: apt install libsqlite3-dev)"

# systemd --user must be available for the unit to be usable.
if command -v systemctl >/dev/null 2>&1 && systemctl --user show-environment >/dev/null 2>&1; then
  note "systemd --user available"
else
  fail "systemd --user is not available in this session" \
       "run inside a systemd user session (loginctl enable-linger \$USER for a headless box), or install the root unit instead (see INSTALL.md)"
fi

[ -f "$ENGINE_SRC/build.zig" ] || fail "engine source not found at $ENGINE_SRC" "clone the full zig-forge repo, or set CHRONOS_ENGINE_SRC to programs/chronos_engine"

if [ "$FAILED" != 0 ]; then
  echo "" >&2
  echo "ABORTING: prerequisites missing (see remediation above). Nothing was built or installed." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Build the engine. This compiles all engine artifacts (including the daemon).
# ---------------------------------------------------------------------------
if [ "$SKIP_BUILD" = 0 ]; then
  echo ""
  echo "-- building the chronos engine (zig build) --"
  if ! ( cd "$ENGINE_SRC" && zig build -Doptimize=ReleaseSafe ); then
    echo "" >&2
    echo "ERROR: 'zig build' failed in $ENGINE_SRC. The D-Bus daemon tier could not be" >&2
    echo "  built on this machine. Common causes: a toolchain link mismatch (a very new" >&2
    echo "  system CRT vs the installed Zig linker), or a missing dev library above." >&2
    echo "  The git-provenance tier (install.sh) does NOT need any of this and is unaffected." >&2
    exit 1
  fi
fi

DAEMON_BIN="$ENGINE_SRC/zig-out/bin/$DAEMON_ARTIFACT"
[ -f "$DAEMON_BIN" ] || { echo "ERROR: built daemon artifact missing: $DAEMON_BIN (set CHRONOS_DAEMON_ARTIFACT if renamed)" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Install the daemon (as `chronosd` for detection) + cognitive-state helpers.
# ---------------------------------------------------------------------------
SUDO=""
if [ "$SYSTEM" = 1 ] || { [ -d "$PREFIX" ] && [ ! -w "$PREFIX" ]; }; then
  [ "$(id -u)" != 0 ] && SUDO="sudo"
fi

echo ""
echo "-- installing daemon + helpers to $PREFIX ${SUDO:+(sudo)} --"
$SUDO install -d -m 0755 "$PREFIX"
$SUDO install -m 0755 "$DAEMON_BIN" "$PREFIX/chronosd"
note "installed chronosd (from $DAEMON_ARTIFACT)"
# get-cognitive-state is the reader chronos-hook calls (via CHRONOS_STATE_BIN the
# git-provenance install already baked into the settings.json hook command).
if [ -f "$ENGINE_SRC/scripts/get-cognitive-state" ]; then
  $SUDO install -m 0755 "$ENGINE_SRC/scripts/get-cognitive-state" "$PREFIX/get-cognitive-state"
  note "installed get-cognitive-state"
fi
if [ -f "$ENGINE_SRC/scripts/cognitive-query" ]; then
  $SUDO install -m 0755 "$ENGINE_SRC/scripts/cognitive-query" "$PREFIX/cognitive-query"
  note "installed cognitive-query"
fi

# ---------------------------------------------------------------------------
# Render the systemd --user unit with the RESOLVED ExecStart path.
# ---------------------------------------------------------------------------
echo ""
echo "-- rendering systemd --user unit --"
mkdir -p "$UNIT_DIR"
UNIT="$UNIT_DIR/chronosd.service"
# sed-escape the path for the replacement side (\, &, | delimiter).
esc_exec="$(printf '%s' "$PREFIX/chronosd" | sed -e 's/[\\&|]/\\&/g')"
sed -e "s|@EXECSTART@|$esc_exec|g" "$SCRIPT_DIR/chronosd.user.service.template" > "$UNIT"
if grep -q '@EXECSTART@' "$UNIT"; then
  echo "ERROR: unit still has an unresolved @EXECSTART@ placeholder: $UNIT" >&2
  exit 1
fi
note "rendered $UNIT  (ExecStart=$PREFIX/chronosd)"

echo ""
echo "== installed — NOT started =="
echo ""
echo "The daemon is installed and a --user unit is written, but nothing is running."
echo "Starting it is your call. To enable + start it (and survive logout on a"
echo "headless box), run:"
echo ""
echo "   systemctl --user daemon-reload"
echo "   systemctl --user enable --now chronosd.service"
echo "   loginctl enable-linger \"\$USER\"        # only needed for a headless/SSH box"
echo ""
echo "   status:   systemctl --user status chronosd.service"
echo "   logs:     journalctl --user -u chronosd.service -f"
echo ""
echo "System-wide (root) alternative: the hardened system unit lives at"
echo "   $ENGINE_SRC/config/chronosd.service"
echo "Install it to /etc/systemd/system/ and enable with 'sudo systemctl' — see INSTALL.md."
