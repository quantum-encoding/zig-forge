# shellcheck shell=bash
# Which Zig builds and stamps the archives other repos link, and how that toolchain is named.
# Sourced (not run) by every script that writes or checks a consumed archive:
# build-macos-lib.sh, build-zsss.sh, programs/build-ios-libs.sh, programs/build-android-libs.sh,
# stamp-archive.sh, check-archive-stamp.sh, crypto-conformance.sh.
#
#   . "$ROOT/scripts/zig-toolchain.sh"
#   forge_zig_require          # sets and exports ZIG (absolute path) and ZIG_TOOLCHAIN_ID,
#                              # or exits naming what is wrong
#   forge_zig_id <zig>         # prints a Zig's toolchain identity
#   forge_zig_accepted <id>    # status 0 when <id> may stamp a consumed archive
#
# The forge builds with Zig 0.17.0 PLUS a six-line std patch
# (scripts/zig-0.17.0-ios-nullfile.patch): official 0.17.0 cannot compile any iOS target that
# reaches std.debug.print (std.Io.Threaded's NullFile has no `fd` for .ios/.visionos). A
# vanilla 0.17.0 and the patched one both say `zig version` = 0.17.0, so the version alone
# cannot tell them apart; the identity adds the patch's sha256, and is only granted when the
# std file the patch edits hashes to the patched bytes AND the install carries the
# TOOLCHAIN-ID file scripts/patch-zig-0.17.sh writes. Identities:
#
#   zig 0.17.0 + zig-0.17.0-ios-nullfile.patch sha256:<patch sha256>   the forge toolchain
#   zig 0.17.0 (unpatched)                                             official 0.17.0
#   zig 0.17.0 (modified std: Threaded.zig sha256:<hex>)               anything else
#   zig <version>                                                      every other version
#
# Each stamped archive records the identity in `<lib>-toolchain.txt` beside it
# (stamp-archive.sh), and check-archive-stamp.sh refuses an archive whose identity is not
# accepted, so a stamp from a vanilla 0.17.0 (or a 0.16.0 one after the flip) cannot pass.
#
# Selecting the Zig: $ZIG when set (a path or a command name); otherwise the patched install
# scripts/patch-zig-0.17.sh makes, at the first of ~/.local/zig-0.17.0-p1/zig and
# /opt/zig-0.17.0-p1/zig that exists; otherwise `zig` on PATH. The user's shell and
# Homebrew are never changed: PATH `zig` may stay 0.16.0 for other work.

FORGE_ZIG_SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
FORGE_ZIG_VERSION="0.17.0"
FORGE_ZIG_PATCH_NAME="zig-0.17.0-ios-nullfile.patch"
FORGE_ZIG_PATCH="$FORGE_ZIG_SCRIPTS/$FORGE_ZIG_PATCH_NAME"
FORGE_ZIG_PATCH_SHA256="56ace2b887defd50bb1ac7f929964689cbeaddccec3d10e12ca19e907c0ea79c"
# lib/std/Io/Threaded.zig of the official 0.17.0 tarball, before and after the patch.
FORGE_ZIG_THREADED_VANILLA="1a770001e309f24c8c58a9fdb3c095994c454cbfa9dba9d4f1dede2f134eeac7"
FORGE_ZIG_THREADED_PATCHED="7d658d672ce56d1523c5c02696098aea4bdb5ecc003aff1d182e24a56000c781"
FORGE_ZIG_ID="zig $FORGE_ZIG_VERSION + $FORGE_ZIG_PATCH_NAME sha256:$FORGE_ZIG_PATCH_SHA256"
FORGE_ZIG_INSTALLS=("$HOME/.local/zig-0.17.0-p1/zig" "/opt/zig-0.17.0-p1/zig")
# The identities allowed to stamp a consumed archive: the patched 0.17.0 alone (since the
# 0.17 flip; a 0.16.0 or vanilla-0.17.0 stamp is refused), and it is the default Zig.
FORGE_ZIG_ACCEPT=("$FORGE_ZIG_ID")
FORGE_ZIG_PREFER_INSTALL=1

# Hashed through stdin: a name holding a backslash (every Windows path `zig env` prints)
# makes both shasum and sha256sum mark the line with a leading "\".
forge_zig_sha256() { "$FORGE_ZIG_SCRIPTS/sha256.sh" < "$1" | cut -d' ' -f1; }

# The Zig to use, as an absolute path (see the header).
forge_zig_resolve() {
  local z="${ZIG:-}" c
  if [ -z "$z" ] && [ "$FORGE_ZIG_PREFER_INSTALL" = 1 ]; then
    for c in "${FORGE_ZIG_INSTALLS[@]}"; do
      [ -x "$c" ] && { z="$c"; break; }
    done
  fi
  [ -n "$z" ] || z=zig
  case "$z" in
    */*) ;;
    *) z="$(command -v "$z" 2>/dev/null)" || return 1 ;;
  esac
  [ -x "$z" ] || return 1
  printf '%s\n' "$z"
}

forge_zig_id() {
  local zig="$1" v std_dir threaded sum bin_dir
  v="$("$zig" version 2>/dev/null)" || { echo "unknown (\`$zig version\` failed)"; return 0; }
  if [ "$v" != "$FORGE_ZIG_VERSION" ]; then
    echo "zig $v"; return 0
  fi
  std_dir="$("$zig" env 2>/dev/null | sed -n 's/^ *\.std_dir = "\(.*\)",$/\1/p')"
  threaded="$std_dir/Io/Threaded.zig"
  if [ ! -f "$threaded" ]; then
    echo "zig $v (no std at '$std_dir')"; return 0
  fi
  sum="$(forge_zig_sha256 "$threaded")"
  case "$sum" in
    "$FORGE_ZIG_THREADED_VANILLA") echo "zig $v (unpatched)" ;;
    "$FORGE_ZIG_THREADED_PATCHED")
      # The std is right; the install must also say what it is (patch-zig-0.17.sh).
      bin_dir="$(cd "$(dirname "$zig")" && pwd -P)"
      [ -L "$zig" ] && bin_dir="$(cd "$(dirname "$(readlink "$zig")")" 2>/dev/null && pwd -P || echo "$bin_dir")"
      if [ -f "$bin_dir/TOOLCHAIN-ID" ] && [ "$(head -1 "$bin_dir/TOOLCHAIN-ID")" = "$FORGE_ZIG_ID" ]; then
        echo "$FORGE_ZIG_ID"
      else
        echo "zig $v (patched std, but no TOOLCHAIN-ID from scripts/patch-zig-0.17.sh beside $zig)"
      fi ;;
    *) echo "zig $v (modified std: Threaded.zig sha256:$sum)" ;;
  esac
}

forge_zig_accepted() {
  local a
  for a in "${FORGE_ZIG_ACCEPT[@]}"; do [ "$1" = "$a" ] && return 0; done
  return 1
}

forge_zig_require() {
  local z id
  if ! z="$(forge_zig_resolve)"; then
    echo "error: no Zig found (ZIG='${ZIG:-}', no patched install at ${FORGE_ZIG_INSTALLS[*]}, none on PATH)" >&2
    echo "  install the forge toolchain with scripts/patch-zig-0.17.sh" >&2
    exit 1
  fi
  id="$(forge_zig_id "$z")"
  if ! forge_zig_accepted "$id"; then
    echo "error: $z is '$id'; consumed archives are built only with" >&2
    echo "  '$FORGE_ZIG_ID'" >&2
    echo "  Install it with scripts/patch-zig-0.17.sh (official 0.17.0 tarball by checksum + the patch)," >&2
    echo "  then leave ZIG unset (the install at ~/.local/zig-0.17.0-p1 is found) or set ZIG=<install>/zig." >&2
    exit 1
  fi
  ZIG="$z"
  ZIG_TOOLCHAIN_ID="$id"
  export ZIG ZIG_TOOLCHAIN_ID
}
