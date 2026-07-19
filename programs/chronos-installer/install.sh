#!/usr/bin/env bash
# Chronos — machine-agnostic installer for the GIT-PROVENANCE tier (universal:
# Linux + macOS). This is the tier quantum-diary detects: it probes `chronos-push`
# on PATH and lights up "Chronos" when present.
#
# What this installs (default: ~/.local/bin, no sudo):
#   chronos-hook            compiled Zig PostToolUse hook — lays a [CHRONOS] tick
#                           commit after each tool call in an opted-in repo
#   chronos-stamp           daemon-free Phi-timestamp generator (local tick file)
#                           — the source of the fold-able [CHRONOS] tick line
#   chronos-push            the "ship it" fold: squashes ticks, pushes a clean history
#   chronos-enable-repo     opt a repo in  (git config chronos.enabled + post-commit shim)
#   chronos-disable-repo    opt a repo back out
#   chronos-post-commit     squash shim target (currently a documented no-op)
#   chronos-hook-install-all  bulk-symlink the hook into every repo under $HOME
#
# What it does to Claude Code:
#   Wires a PostToolUse '*' hook -> the installed chronos-hook into
#   ~/.claude/settings.json — IDEMPOTENTLY and SAFELY (backs the file up first,
#   parses the JSON structurally, never clobbers other hooks). The command baked
#   in is absolute and carries CHRONOS_*_BIN env vars, so it needs nothing on PATH.
#
# What it does NOT do: it never enables ticking in any repo (that is per-repo and
# explicit: `chronos-enable-repo /path/to/repo`), and it installs no daemon. The
# optional Linux D-Bus turn-complete daemon (chronosd) is a separate add-on —
# see ./install-daemon.sh.
#
# Usage:
#   ./install.sh                       # build + install to ~/.local/bin, wire the hook
#   ./install.sh --prefix DIR          # install to DIR/bin-style dir (no sudo if writable)
#   ./install.sh --system              # install to /usr/local/bin (uses sudo)
#   ./install.sh --no-wire-hook        # install binaries only; do NOT touch settings.json
#   ./install.sh --settings PATH       # target a specific settings.json (default ~/.claude/settings.json)
#   ./install.sh --skip-build          # reuse existing zig-out artifacts
#
# quantum-diary meta-installer: it calls "$CHRONOS_DIR/install.sh" — point
# CHRONOS_DIR at THIS directory (programs/chronos-installer) in a repo checkout.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source trees. Default to the sibling locations in a zig-forge checkout; override
# via env for an unusual layout. The installer builds FROM these but never edits them.
HOOK_SRC="${CHRONOS_HOOK_SRC:-$SCRIPT_DIR/../cognitive_telemetry_kit/chronos-hook}"
ENGINE_SRC="${CHRONOS_ENGINE_SRC:-$SCRIPT_DIR/../chronos_engine}"

PREFIX="$HOME/.local/bin"
SYSTEM=0
SKIP_BUILD=0
WIRE_HOOK=1
SETTINGS="${CHRONOS_SETTINGS:-$HOME/.claude/settings.json}"

usage() { sed -n '2,45p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
  case "$1" in
    --prefix)       PREFIX="${2:?--prefix requires a directory}"; shift 2 ;;
    --system)       SYSTEM=1; PREFIX="/usr/local/bin"; shift ;;
    --no-wire-hook) WIRE_HOOK=0; shift ;;
    --settings)     SETTINGS="${2:?--settings requires a path}"; shift 2 ;;
    --skip-build)   SKIP_BUILD=1; shift ;;
    -h|--help)      usage; exit 0 ;;
    *) echo "ERROR: unknown argument '$1'" >&2; usage >&2; exit 2 ;;
  esac
done

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
FAILED=0
fail() { echo "" >&2; echo "MISSING PREREQUISITE: $1" >&2; echo "  remediation: $2" >&2; FAILED=1; }
note() { echo "  [ok] $*"; }

# Zig target. On Linux we default to a STATIC musl build: the binaries become
# portable (no glibc-version dependency — they run on any distro), and it
# sidesteps a real link failure with very new toolchains (gcc 16's crt1.o
# carries .sframe unwind sections whose R_X86_64_PC64 relocations Zig's linker
# rejects when linking the SYSTEM glibc CRT). macOS builds native. Override
# with CHRONOS_ZIG_TARGET (e.g. `native` to force the system toolchain, or a
# specific `<arch>-linux-musl`).
ZIG_TARGET="${CHRONOS_ZIG_TARGET:-}"
if [ -z "$ZIG_TARGET" ]; then
  case "$(uname -s)" in
    Linux) ZIG_TARGET="$(uname -m)-linux-musl" ;;
    *)     ZIG_TARGET="native" ;;
  esac
fi
# Flag forms differ: `zig build` takes -Dtarget=, `zig build-exe` takes -target.
BUILD_TARGET=(); EXE_TARGET=()
if [ "$ZIG_TARGET" != native ]; then
  BUILD_TARGET=("-Dtarget=$ZIG_TARGET")
  EXE_TARGET=("-target" "$ZIG_TARGET")
fi

# ---------------------------------------------------------------------------
# Prerequisite gate — collect every failure, then abort once with all of them.
# ---------------------------------------------------------------------------
echo "== Chronos installer (git-provenance tier) =="
echo "   prefix=$PREFIX  settings=$SETTINGS  wire-hook=$WIRE_HOOK"
echo ""
echo "-- checking prerequisites --"

# zig — the required version is read from the hook kit's build (it targets the
# Zig 0.16 std API; see chronos-hook/README.md "Built with Zig 0.16").
REQUIRED_ZIG_MAJOR=0
REQUIRED_ZIG_MINOR=16
if ! command -v zig >/dev/null 2>&1; then
  fail "zig not found (required: Zig ${REQUIRED_ZIG_MAJOR}.${REQUIRED_ZIG_MINOR}+)" \
       "install Zig ${REQUIRED_ZIG_MAJOR}.${REQUIRED_ZIG_MINOR}+ from https://ziglang.org/download/ and put it on PATH"
else
  ZV="$(zig version)"; ZMAJ="${ZV%%.*}"; ZREST="${ZV#*.}"; ZMIN="${ZREST%%[!0-9]*}"
  if [ "$ZMAJ" -eq 0 ] && [ "${ZMIN:-0}" -lt "$REQUIRED_ZIG_MINOR" ]; then
    fail "zig $ZV is too old (chronos-hook uses the Zig ${REQUIRED_ZIG_MAJOR}.${REQUIRED_ZIG_MINOR} std API)" \
         "install Zig ${REQUIRED_ZIG_MAJOR}.${REQUIRED_ZIG_MINOR}+ from https://ziglang.org/download/"
  else
    note "zig $ZV"
  fi
fi

command -v git  >/dev/null 2>&1 && note "git present"  || fail "git not found" "install git (Arch: pacman -S git; Debian/Ubuntu: apt install git; macOS: xcode-select --install)"
command -v bash >/dev/null 2>&1 && note "bash present" || fail "bash not found" "install bash"

# python3 — only required when wiring the hook (structural, safe settings.json edit).
if [ "$WIRE_HOOK" = 1 ]; then
  if command -v python3 >/dev/null 2>&1; then note "python3 present (settings.json wiring)"
  else fail "python3 not found (needed to safely edit ~/.claude/settings.json)" \
            "install python3, or re-run with --no-wire-hook and wire the PostToolUse hook by hand (see INSTALL.md)"; fi
fi

# Source trees must be present (a partial download).
[ -f "$HOOK_SRC/build.zig" ]              || fail "hook source not found at $HOOK_SRC" "clone the full zig-forge repo, or set CHRONOS_HOOK_SRC to programs/cognitive_telemetry_kit/chronos-hook"
[ -f "$ENGINE_SRC/chronos-stamp-macos.zig" ] || fail "engine stamp source not found at $ENGINE_SRC" "clone the full zig-forge repo, or set CHRONOS_ENGINE_SRC to programs/chronos_engine"

if [ "$FAILED" != 0 ]; then
  echo "" >&2
  echo "ABORTING: prerequisites missing (see remediation above). Nothing was built or installed." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Build. chronos-hook via its own build.zig (hook + ledger deps only — no dbus,
# no bpf). chronos-stamp is the DAEMON-FREE stamp (chronos-stamp-macos.zig): its
# name says macOS but the source is pure libc (clock + a local tick file) and is
# the portable, cross-platform choice — it is what makes the hook emit a fold-able
# [CHRONOS] line WITHOUT requiring the Linux D-Bus daemon.
# ---------------------------------------------------------------------------
STAGE="$SCRIPT_DIR/.stage"
if [ "$SKIP_BUILD" = 0 ]; then
  echo ""
  echo "-- building chronos-hook (zig build, target=$ZIG_TARGET) --"
  ( cd "$HOOK_SRC" && zig build -Doptimize=ReleaseSafe "${BUILD_TARGET[@]}" )

  echo "-- building chronos-stamp (daemon-free, from chronos-stamp-macos.zig) --"
  mkdir -p "$STAGE"
  ( cd "$ENGINE_SRC" && zig build-exe chronos-stamp-macos.zig -lc -O ReleaseSafe \
        "${EXE_TARGET[@]}" -femit-bin="$STAGE/chronos-stamp" )
fi

HOOK_BIN="$HOOK_SRC/zig-out/bin/chronos-hook"
STAMP_BIN="$STAGE/chronos-stamp"
[ -f "$HOOK_BIN" ]  || { echo "ERROR: build artifact missing: $HOOK_BIN (run without --skip-build)" >&2; exit 1; }
[ -f "$STAMP_BIN" ] || { echo "ERROR: build artifact missing: $STAMP_BIN (run without --skip-build)" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Install.
# ---------------------------------------------------------------------------
SUDO=""
if [ "$SYSTEM" = 1 ] || { [ -d "$PREFIX" ] && [ ! -w "$PREFIX" ]; }; then
  [ "$(id -u)" != 0 ] && SUDO="sudo"
fi

echo ""
echo "-- installing to $PREFIX ${SUDO:+(sudo)} --"
$SUDO install -d -m 0755 "$PREFIX"
$SUDO install -m 0755 "$HOOK_BIN"                       "$PREFIX/chronos-hook"
$SUDO install -m 0755 "$STAMP_BIN"                      "$PREFIX/chronos-stamp"
$SUDO install -m 0755 "$HOOK_SRC/chronos-push"          "$PREFIX/chronos-push"
$SUDO install -m 0755 "$HOOK_SRC/chronos-enable-repo"   "$PREFIX/chronos-enable-repo"
$SUDO install -m 0755 "$HOOK_SRC/chronos-disable-repo"  "$PREFIX/chronos-disable-repo"
$SUDO install -m 0755 "$HOOK_SRC/chronos-post-commit"   "$PREFIX/chronos-post-commit"
$SUDO install -m 0755 "$HOOK_SRC/chronos-hook-install-all" "$PREFIX/chronos-hook-install-all"
note "installed 7 components"

# ---------------------------------------------------------------------------
# Wire the PostToolUse hook into settings.json (idempotent + backed up). The
# command is absolute and carries CHRONOS_*_BIN so it resolves regardless of the
# hook process's PATH. CHRONOS_STATE_BIN points at where the Linux daemon add-on
# would install get-cognitive-state; if that isn't installed, the hook degrades
# to a clean tool-activity gerund (Editing/Writing/…) — no error.
# ---------------------------------------------------------------------------
HOOK_CMD="CHRONOS_STAMP_BIN='$PREFIX/chronos-stamp' CHRONOS_STATE_BIN='$PREFIX/get-cognitive-state' CHRONOS_ENABLE_REPO_BIN='$PREFIX/chronos-enable-repo' CHRONOS_POST_COMMIT_BIN='$PREFIX/chronos-post-commit' '$PREFIX/chronos-hook'"

if [ "$WIRE_HOOK" = 1 ]; then
  echo ""
  echo "-- wiring PostToolUse hook into $SETTINGS --"
  python3 "$SCRIPT_DIR/chronos-settings-hook.py" --add --command "$HOOK_CMD" --settings "$SETTINGS"
else
  echo ""
  echo "-- NOT wiring the hook (--no-wire-hook). To wire it yourself, add a PostToolUse '*' hook with command:"
  echo "     $HOOK_CMD"
fi

# ---------------------------------------------------------------------------
# PATH warning + next steps.
# ---------------------------------------------------------------------------
case ":$PATH:" in
  *":$PREFIX:"*) : ;;
  *) echo ""
     echo "  WARNING: $PREFIX is not on your \$PATH. The Claude hook works (its command is"
     echo "  absolute), but 'chronos-push' won't be callable by name and quantum-diary"
     echo "  detects Chronos by finding chronos-push on PATH. Add to your shell rc:"
     echo "     export PATH=\"$PREFIX:\$PATH\""
     ;;
esac

echo ""
echo "== installed =="
echo ""
echo "Chronos is installed but NO repo is ticking yet (opt-in, per repo):"
echo ""
echo "  1. Opt a repo in:     chronos-enable-repo /path/to/repo"
echo "                        (sets git config chronos.enabled + the post-commit shim)"
echo "  2. Work — each tool action leaves a [CHRONOS] tick commit in that repo."
echo "  3. Ship:              git push \"your message\"   (folds ticks, pushes clean history)"
echo "     (equivalently:     chronos-push -m \"your message\")"
echo "  4. Opt back out:      chronos-disable-repo /path/to/repo"
echo ""
echo "quantum-diary lights up \"Chronos\" as soon as chronos-push is on PATH."
echo "Optional Linux depth (D-Bus turn-complete emitter): ./install-daemon.sh"
