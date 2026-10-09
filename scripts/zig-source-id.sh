#!/usr/bin/env bash
# Print a content identity for one Zig program's sources.
#
# A prebuilt static archive is compared against the source it claims to be built from
# by this identity: Cifra's check-zig-slices.sh and the `-source-id.txt` stamp that
# build-macos-lib.sh writes beside each archive both use it. A stale or
# differently-optimised `.a` links fine and the test suite goes green against it, so
# the comparison is the only thing that notices.
#
# What it covers: every file under the program directory, and every directory outside
# it that the build reads. Those are found in build.zig (string literals starting
# `../`, which is how `b.path("../other/src/lib.zig")` imports a sibling's module)
# and build.zig.zon (`.path = "../dep"` package dependencies), followed transitively.
# A `.zig` file named that way brings in its whole directory, because a module can
# import anything under its root file's directory. Headers, build.zig.zon, embedded
# fonts and fixtures are therefore all in, not just `.zig`.
#
# Which files: exactly those a clean copy of the repo holds. In a git work tree that is
# what git lists (tracked, plus untracked files no .gitignore excludes), so local build
# products and other ignored files never count. Without git (an export, a synced copy)
# it is every file present. Either way, build outputs and caches (zig-out, .zig-cache,
# Cargo/SwiftPM build dirs, archives, object files), symlinks and the stamps themselves
# are left out, so the same commit has the same identity in a checkout, a clone and an
# export, and building or testing a program never changes it.
#
# Each file is hashed with its path relative to the program directory, so a rename is
# a change and the answer does not depend on how the argument was spelled. The list is
# sorted so it never depends on filesystem order.
#
#   scripts/zig-source-id.sh programs/simd_crypto_ffi            # the identity
#   scripts/zig-source-id.sh --deps programs/zig_pdf_generator   # the directories and
#                                                                # files it covers
set -euo pipefail

mode=id
if [ "${1:-}" = "--deps" ]; then
  mode=deps
  shift
fi
DIR="${1:?usage: zig-source-id.sh [--deps] <program-dir>}"
[ -d "$DIR" ] || { echo "error: no such directory: $DIR" >&2; exit 1; }

BASE="$(cd "$DIR" && pwd -P)"

# Relative path from $2 to $1; both absolute, physical, no trailing slash.
relpath() {
  local t="$1" b="$2" up=""
  while [ "$t" != "$b" ] && [ "${t#"$b"/}" = "$t" ]; do
    b="${b%/*}"
    up="../$up"
  done
  if [ "$t" = "$b" ]; then
    up="${up%/}"
    printf '%s\n' "${up:-.}"
  else
    printf '%s\n' "$up${t#"$b"/}"
  fi
}

# Physical absolute path of an existing file or directory.
physical() {
  if [ -d "$1" ]; then
    (cd "$1" && pwd -P)
  else
    printf '%s/%s\n' "$(cd "$(dirname "$1")" && pwd -P)" "$(basename "$1")"
  fi
}

# The `../…` paths a package's build reads, as written, one per line. Whole-line `//`
# comments are skipped so a path mentioned in prose is not mistaken for an input.
referenced() {
  local pkg="$1" f
  for f in "$pkg/build.zig" "$pkg/build.zig.zon"; do
    [ -f "$f" ] || continue
    grep -v '^[[:space:]]*//' "$f" | grep -oE '"(\.\./)+[^"]*"' | tr -d '"' || true
  done
}

# Breadth-first over packages: the program, then each directory a build reaches into.
# Entries are absolute; `seen` is newline-delimited.
covered="$BASE"
seen="
$BASE
"
queue="$BASE"
while [ -n "$queue" ]; do
  pkg="${queue%%
*}"
  if [ "$queue" = "$pkg" ]; then queue=""; else queue="${queue#*
}"; fi

  while IFS= read -r ref; do
    [ -n "$ref" ] || continue
    target="$pkg/$ref"
    if [ ! -e "$target" ]; then
      # A build cannot succeed with a missing input, so it is not a source of a
      # successfully built archive.
      echo "warning: $(relpath "$pkg" "$BASE")/build.zig names $ref, which does not exist" >&2
      continue
    fi
    abs="$(physical "$target")"
    case "$abs" in
      *.zig) abs="$(dirname "$abs")" ;;
    esac
    case "$seen" in
      *"
$abs
"*) continue ;;
    esac
    seen="$seen$abs
"
    covered="$covered
$abs"
    # Only a package directory has a build of its own to follow.
    if [ -d "$abs" ] && { [ -f "$abs/build.zig" ] || [ -f "$abs/build.zig.zon" ]; }; then
      queue="${queue:+$queue
}$abs"
    fi
  done <<EOF
$(referenced "$pkg")
EOF
done

if [ "$mode" = deps ]; then
  while IFS= read -r abs; do relpath "$abs" "$BASE"; done <<EOF | LC_ALL=C sort -u
$covered
EOF
  exit 0
fi

# Computed from INSIDE the program directory so every path is relative to it.
cd "$BASE"

# Drops build outputs, caches, stamps, symlinks and vanished files from a NUL-delimited
# list, and spells paths inside the program directory as `./…`, the way find does, so
# both listings below produce identical names.
keep_sources() {
  perl -0 -ne '
    chomp;
    next if m{(^|/)(zig-out|\.zig-cache|zig-cache|\.git|\.worktrees|target|\.build|\.swiftpm|node_modules|__pycache__|DerivedData)/};
    next if m{(^|/)\.DS_Store$} || m{-source-id\.txt$} || m{\.release-stamp\.json$}
         || m{\.repacked$} || m{\.(a|o|dylib|so)$};
    next if -l $_ || !-f _;
    $_ = "./$_" unless m{^\.\.?/};
    print "$_\0";
  '
}

# The work tree holding the program, if any. A covered path outside it (another repo,
# or no repo) is listed by walking it.
top=""
if command -v git >/dev/null 2>&1 && top="$(git -C "$BASE" rev-parse --show-toplevel 2>/dev/null)"; then
  top="$(cd "$top" && pwd -P)"
fi

{
  while IFS= read -r abs; do
    rel="$(relpath "$abs" "$BASE")"
    if [ -n "$top" ] && case "$abs" in "$top" | "$top"/*) true ;; *) false ;; esac; then
      git ls-files -z --cached --others --exclude-standard -- "$rel"
    elif [ -d "$abs" ]; then
      find "$rel" -type f -print0
    else
      printf '%s\0' "$rel"
    fi
  done <<EOF
$covered
EOF
} | keep_sources \
  | LC_ALL=C sort -zu \
  | xargs -0 shasum -a 256 \
  | shasum -a 256 \
  | cut -d' ' -f1
