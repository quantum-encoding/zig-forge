#!/usr/bin/env bash
# Guardian Shield v9 - machine-agnostic installer.
#
# What this does:
#   1. Verifies every prerequisite (kernel BPF-LSM, BTF, clang, zig, bpftool,
#      libbpf, a JSON validator) and FAILS LOUD with the exact remediation.
#   2. Regenerates bpf/vmlinux.h from THIS machine's kernel BTF (the BPF object
#      must be built against the kernel it will run on - mount-crossing offsets
#      are not CO-RE-relocatable).
#   3. Builds the BPF object + userspace loader via `zig build`.
#   4. Renders config.template.json for THIS machine (${HOME}, ${USER},
#      ${INSTALL_DIR}) and validates the result: strict JSON, zero unresolved
#      ${...} placeholders.
#   5. Installs everything root-owned (default /opt/guardian-shield) and prints
#      the exact command to load + pin enforcement.
#
# What this does NOT do: it never loads anything into the kernel. Loading a
# BPF-LSM enforcement layer pins hooks that PERSIST after the loader exits and
# gate filesystem operations machine-wide - that must be the operator's
# explicit, reviewed decision, not a side effect of an install script. The
# load command is printed at the end; run it yourself after reviewing the
# generated config.
#
# Usage:
#   ./install.sh                     # build + install to /opt/guardian-shield
#   ./install.sh --prefix DIR        # alternate install dir
#   ./install.sh --check-config      # render + validate the config only (no
#                                    # build, no install, nothing written
#                                    # outside a temp file) - used by tests/
#   ./install.sh --skip-build        # reuse existing zig-out artifacts
#
# Run as a regular user; sudo is invoked only for the final copy phase.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREFIX="/opt/guardian-shield"
CHECK_CONFIG_ONLY=0
SKIP_BUILD=0

# BPF-side limit (MAX_PATH_LEN in guardian_shield.bpf.c / the loader): any
# policy path prefix must fit in 128 bytes including the NUL.
readonly MAX_POLICY_PATH=127

usage() { sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
  case "$1" in
    --prefix)       PREFIX="${2:?--prefix requires a directory}"; shift 2 ;;
    --check-config) CHECK_CONFIG_ONLY=1; shift ;;
    --skip-build)   SKIP_BUILD=1; shift ;;
    -h|--help)      usage; exit 0 ;;
    *) echo "ERROR: unknown argument '$1'" >&2; usage >&2; exit 2 ;;
  esac
done

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
FAILED=0
fail() {  # fail "what is wrong" "how to fix it"
  echo "" >&2
  echo "MISSING PREREQUISITE: $1" >&2
  echo "  remediation: $2" >&2
  FAILED=1
}
note() { echo "  [ok] $*"; }

# The policy must be rendered for the human operator's account, not root -
# resolve the invoking user even when the whole script is run under sudo.
TARGET_USER="${SUDO_USER:-$(id -un)}"
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
if [ -z "$TARGET_HOME" ] || [ ! -d "$TARGET_HOME" ]; then
  echo "ERROR: cannot resolve home directory for user '$TARGET_USER'" >&2
  exit 1
fi

# Escape a string for use in a sed replacement (\, &, and the | delimiter).
sed_escape() { printf '%s' "$1" | sed -e 's/[\\&|]/\\&/g'; }

validate_json() {  # validate_json <file>
  if command -v jq >/dev/null 2>&1; then
    jq empty "$1"
  elif command -v python3 >/dev/null 2>&1; then
    python3 -m json.tool "$1" >/dev/null
  else
    echo "ERROR: neither jq nor python3 available to validate JSON" >&2
    return 1
  fi
}

# Render config.template.json -> $1 with this machine's values substituted.
render_config() {  # render_config <out_file> <install_dir>
  local out="$1" install_dir="$2"
  local template="$SCRIPT_DIR/config.template.json"
  [ -f "$template" ] || { echo "ERROR: $template not found" >&2; return 1; }

  sed -e "s|\${HOME}|$(sed_escape "$TARGET_HOME")|g" \
      -e "s|\${USER}|$(sed_escape "$TARGET_USER")|g" \
      -e "s|\${INSTALL_DIR}|$(sed_escape "$install_dir")|g" \
      "$template" > "$out"

  # 1. No unresolved placeholders may survive - an unresolved ${...} would be
  #    loaded as a literal path and silently protect nothing.
  if grep -n '\${' "$out" >&2; then
    echo "ERROR: unresolved \${...} placeholders remain in the generated config (lines above)." >&2
    return 1
  fi
  # 2. Must be strict JSON (the loader's std.json parse is strict).
  if ! validate_json "$out"; then
    echo "ERROR: generated config is not valid JSON: $out" >&2
    return 1
  fi
  # 3. Policy path entries must fit the BPF-side 128-byte key (best-effort,
  #    needs jq). Overlong entries would be skipped by the loader with only a
  #    warning - surface it here instead.
  if command -v jq >/dev/null 2>&1; then
    local overlong
    overlong="$(jq -r '(.protected_paths + .critical_paths + .credential_paths)[]' "$out" | awk -v m="$MAX_POLICY_PATH" 'length($0) > m')"
    if [ -n "$overlong" ]; then
      echo "ERROR: these policy paths exceed the ${MAX_POLICY_PATH}-byte BPF key limit and would NOT be enforced:" >&2
      echo "$overlong" >&2
      return 1
    fi
  fi
  return 0
}

# ---------------------------------------------------------------------------
# --check-config: render + validate only, then exit. No build, no install.
# ---------------------------------------------------------------------------
if [ "$CHECK_CONFIG_ONLY" = 1 ]; then
  tmp="$(mktemp)"
  trap 'rm -f "$tmp"' EXIT   # temp file only; never touches the source tree
  render_config "$tmp" "$PREFIX"
  echo "config template renders clean for user=$TARGET_USER home=$TARGET_HOME install_dir=$PREFIX:"
  cat "$tmp"
  exit 0
fi

# ---------------------------------------------------------------------------
# Prerequisite checks - every failure prints its remediation; all failures
# are collected so one run reports everything, then the script exits non-zero.
# ---------------------------------------------------------------------------
echo "== Guardian Shield v9 installer =="
echo "   user=$TARGET_USER  home=$TARGET_HOME  install dir=$PREFIX"
echo ""
echo "-- checking prerequisites --"

# Kernel >= 5.7 (first kernel with BPF-LSM).
KREL="$(uname -r)"
KMAJ="${KREL%%.*}"; KREST="${KREL#*.}"; KMIN="${KREST%%[!0-9]*}"
if [ "$KMAJ" -lt 5 ] || { [ "$KMAJ" -eq 5 ] && [ "${KMIN:-0}" -lt 7 ]; }; then
  fail "kernel $KREL is older than 5.7 (no BPF-LSM support)" \
       "upgrade to a kernel >= 5.7 built with CONFIG_BPF_LSM=y"
else
  note "kernel $KREL >= 5.7"
fi

# bpf must be in the ACTIVE LSM stack (boot-time kernel cmdline).
LSM_FILE=/sys/kernel/security/lsm
LSM_LIST=""
if [ -r "$LSM_FILE" ]; then
  LSM_LIST="$(cat "$LSM_FILE")"
elif command -v sudo >/dev/null 2>&1; then
  LSM_LIST="$(sudo cat "$LSM_FILE" 2>/dev/null || true)"
fi
if [ -z "$LSM_LIST" ]; then
  fail "cannot read $LSM_FILE (securityfs not mounted?)" \
       "mount securityfs (mount -t securityfs securityfs /sys/kernel/security) and re-run"
elif ! printf '%s' "$LSM_LIST" | tr ',' '\n' | grep -x 'bpf' >/dev/null; then
  fail "'bpf' is NOT in the active LSM stack (currently: $LSM_LIST)" \
       "add bpf to the LSM list on the kernel cmdline, e.g. GRUB_CMDLINE_LINUX=\"... lsm=${LSM_LIST},bpf\" then grub-mkconfig -o /boot/grub/grub.cfg (or update-grub) and reboot"
else
  note "BPF LSM active ($LSM_LIST)"
fi

# Kernel BTF (CO-RE source + vmlinux.h generation).
if [ ! -e /sys/kernel/btf/vmlinux ]; then
  fail "/sys/kernel/btf/vmlinux missing (kernel lacks CONFIG_DEBUG_INFO_BTF=y)" \
       "use a distribution kernel with BTF enabled (all mainstream distros since ~2021 ship it)"
else
  note "kernel BTF present"
fi

# CONFIG_SECURITY_PATH (the path_* LSM hook family). Best-effort: not every
# distro exposes the kernel config; if we cannot check, the loader's
# fail-closed attach will still catch it at load time.
KCONF=""
if [ -r /proc/config.gz ]; then
  KCONF="$(zcat /proc/config.gz 2>/dev/null || true)"
elif [ -r "/boot/config-$KREL" ]; then
  KCONF="$(cat "/boot/config-$KREL")"
fi
if [ -n "$KCONF" ]; then
  if ! printf '%s\n' "$KCONF" | grep -x 'CONFIG_SECURITY_PATH=y' >/dev/null; then
    fail "kernel built without CONFIG_SECURITY_PATH=y (the path_* LSM hooks do not exist)" \
         "use a kernel with CONFIG_SECURITY_PATH=y (standard on mainstream distros)"
  elif ! printf '%s\n' "$KCONF" | grep -x 'CONFIG_BPF_LSM=y' >/dev/null; then
    fail "kernel built without CONFIG_BPF_LSM=y" \
         "use a kernel with CONFIG_BPF_LSM=y"
  else
    note "CONFIG_SECURITY_PATH=y, CONFIG_BPF_LSM=y"
  fi
else
  echo "  [??] kernel config not readable (/proc/config.gz, /boot/config-$KREL) - cannot pre-verify CONFIG_SECURITY_PATH; the loader will fail closed at attach time if it is missing"
fi

# clang with the BPF backend.
if ! command -v clang >/dev/null 2>&1; then
  fail "clang not found" \
       "install clang/llvm (Arch: pacman -S clang llvm; Debian/Ubuntu: apt install clang llvm)"
elif ! clang --print-targets 2>/dev/null | grep -w 'bpf' >/dev/null; then
  fail "installed clang lacks the BPF target" \
       "install a full llvm/clang build (distribution clang packages include the BPF backend)"
else
  note "clang $(clang --version | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1) with BPF target"
fi

# bpftool (vmlinux.h generation + operator inspection).
if ! command -v bpftool >/dev/null 2>&1; then
  fail "bpftool not found" \
       "install it (Arch: pacman -S bpf; Debian/Ubuntu: apt install linux-tools-common linux-tools-\$(uname -r) or bpftool)"
else
  note "bpftool present"
fi

# zig >= 0.16 (the loader uses the 0.16 std API; older zig will not compile it).
if ! command -v zig >/dev/null 2>&1; then
  fail "zig not found" \
       "install Zig 0.16+ from https://ziglang.org/download/ and put it on PATH"
else
  ZV="$(zig version)"
  ZMAJ="${ZV%%.*}"; ZREST="${ZV#*.}"; ZMIN="${ZREST%%[!0-9]*}"
  if [ "$ZMAJ" -eq 0 ] && [ "${ZMIN:-0}" -lt 16 ]; then
    fail "zig $ZV is too old (the loader requires the Zig 0.16 std API)" \
         "install Zig 0.16+ from https://ziglang.org/download/"
  else
    note "zig $ZV"
  fi
fi

# libbpf >= 1.0 (headers + shared library; the loader links -lbpf).
if [ ! -f /usr/include/bpf/libbpf.h ]; then
  fail "libbpf development headers not found (/usr/include/bpf/libbpf.h)" \
       "install libbpf (Arch: pacman -S libbpf; Debian/Ubuntu: apt install libbpf-dev)"
elif ! ldconfig -p 2>/dev/null | grep 'libbpf\.so' >/dev/null; then
  fail "libbpf shared library not found in the linker cache" \
       "install libbpf (Arch: pacman -S libbpf; Debian/Ubuntu: apt install libbpf-dev)"
else
  note "libbpf headers + library present"
fi

# A JSON validator for the generated config (jq preferred, python3 accepted).
if ! command -v jq >/dev/null 2>&1 && ! command -v python3 >/dev/null 2>&1; then
  fail "neither jq nor python3 found (needed to validate the generated config)" \
       "install jq (Arch: pacman -S jq; Debian/Ubuntu: apt install jq)"
else
  note "JSON validator available ($(command -v jq >/dev/null 2>&1 && echo jq || echo python3))"
fi

# liburing - OPTIONAL, only for the bypass test harness.
BUILD_HARNESS=0
if [ -f /usr/include/liburing.h ]; then
  BUILD_HARNESS=1
  note "liburing present - bypass test harness will be built"
else
  echo "  [--] liburing not found - skipping the bypass test harness (optional; Arch: pacman -S liburing; Debian/Ubuntu: apt install liburing-dev)"
fi

if [ "$FAILED" != 0 ]; then
  echo "" >&2
  echo "ABORTING: prerequisites missing (see remediation above). Nothing was built or installed." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# vmlinux.h - ALWAYS regenerated from the running kernel's BTF. The BPF
# object embeds struct-layout offsets (the mount-crossing container_of) that
# are NOT CO-RE-relocatable, so the object must be built against the kernel
# it will run on. Stale headers from another machine are exactly the bug this
# installer exists to prevent.
# ---------------------------------------------------------------------------
if [ "$SKIP_BUILD" = 0 ]; then
  echo ""
  echo "-- generating bpf/vmlinux.h from this kernel's BTF --"
  bpftool btf dump file /sys/kernel/btf/vmlinux format c > "$SCRIPT_DIR/bpf/vmlinux.h"
  note "bpf/vmlinux.h regenerated for $KREL"

  # -------------------------------------------------------------------------
  # Build. `bpf` + `loader` steps only - the default step also builds the
  # liburing test harness, which must stay optional.
  # -------------------------------------------------------------------------
  echo ""
  echo "-- building (zig build) --"
  (cd "$SCRIPT_DIR" && zig build bpf loader -Doptimize=ReleaseSafe)
  if [ "$BUILD_HARNESS" = 1 ]; then
    (cd "$SCRIPT_DIR" && zig build test-harness -Doptimize=ReleaseSafe)
  fi
fi

LOADER_BIN="$SCRIPT_DIR/zig-out/bin/guardian_shield_loader"
BPF_OBJ="$SCRIPT_DIR/zig-out/bin/guardian_shield.bpf.o"
for f in "$LOADER_BIN" "$BPF_OBJ"; do
  [ -f "$f" ] || { echo "ERROR: build artifact missing: $f" >&2; exit 1; }
done

# ---------------------------------------------------------------------------
# Render the machine-specific config.
# ---------------------------------------------------------------------------
echo ""
echo "-- rendering config for this machine --"
GEN_CONFIG="$(mktemp)"
trap 'rm -f "$GEN_CONFIG"' EXIT
render_config "$GEN_CONFIG" "$PREFIX"
note "config rendered + validated (strict JSON, no unresolved placeholders)"

# ---------------------------------------------------------------------------
# Install (root-owned - the loader's path is TAG_TRUSTED under hardening
# mode, so it must never live somewhere an unprivileged user can replace it).
# ---------------------------------------------------------------------------
echo ""
echo "-- installing to $PREFIX (sudo) --"
SUDO=""
[ "$(id -u)" != 0 ] && SUDO="sudo"

case "$PREFIX" in
  "$TARGET_HOME"/*)
    echo "  WARNING: $PREFIX is inside \$HOME. Under hardening_mode the loader path is" >&2
    echo "  TRUSTED - a user-writable loader is a privilege hole. Prefer /opt/guardian-shield." >&2
    ;;
esac

$SUDO install -d -m 0755 -o root -g root "$PREFIX"
$SUDO install    -m 0755 -o root -g root "$LOADER_BIN" "$PREFIX/guardian_shield_loader"
$SUDO install    -m 0644 -o root -g root "$BPF_OBJ"    "$PREFIX/guardian_shield.bpf.o"
if [ -f "$PREFIX/config.json" ]; then
  echo "  existing $PREFIX/config.json preserved as config.json.prev"
  $SUDO cp -p "$PREFIX/config.json" "$PREFIX/config.json.prev"
fi
$SUDO install    -m 0644 -o root -g root "$GEN_CONFIG" "$PREFIX/config.json"
$SUDO install    -m 0755 -o root -g root "$SCRIPT_DIR/uninstall.sh" "$PREFIX/uninstall.sh"
if [ "$BUILD_HARNESS" = 1 ] && [ -f "$SCRIPT_DIR/zig-out/bin/gs_bypass_test" ]; then
  $SUDO install -d -m 0755 -o root -g root "$PREFIX/tests"
  $SUDO install    -m 0755 -o root -g root "$SCRIPT_DIR/zig-out/bin/gs_bypass_test" "$PREFIX/tests/gs_bypass_test"
  $SUDO install    -m 0755 -o root -g root "$SCRIPT_DIR/tests/run_bypass_suite.sh"  "$PREFIX/tests/run_bypass_suite.sh"
fi

echo ""
echo "== installed - NOT loaded =="
echo ""
echo "Guardian Shield is installed but NO kernel enforcement is active yet."
echo "Loading pins LSM hooks that gate filesystem operations machine-wide and"
echo "PERSIST after the loader exits - that is a decision to make deliberately,"
echo "with the policy reviewed, not an installer side effect."
echo ""
echo "  1. Review the policy:        $PREFIX/config.json"
echo "     (consider a first run with \"log_only\": true to audit before enforcing)"
echo ""
echo "  2. Load + attach + PIN:      sudo $PREFIX/guardian_shield_loader $PREFIX/config.json --verbose"
echo ""
echo "  3. Verify:                   ls /sys/fs/bpf/guardian_shield/   (one pin per hook)"
echo "                               sudo bpftool link show"
echo "                               tail -f /var/log/guardian_shield.jsonl"
if [ "$BUILD_HARNESS" = 1 ]; then
  echo "     bypass suite (as a NON-root user, with the shield loaded):"
  echo "                               $PREFIX/tests/run_bypass_suite.sh \"\$HOME/gs_test_protected\" \"\$HOME/gs_test_scratch\""
fi
echo ""
echo "  4. Remove enforcement:       sudo $PREFIX/guardian_shield_loader $PREFIX/config.json --unpin"
echo "     Full uninstall:           $PREFIX/uninstall.sh"
