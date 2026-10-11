#!/usr/bin/env bash
# Tests that a source identity and an archive stamp come out the same on every host.
#
#   scripts/test-sha256.sh
#
# Runs anywhere bash and git do (macOS, Linux, Git for Windows), with whichever of
# `shasum` and `sha256sum` the host has; where it has both, each case runs with each,
# and stamps written by one are checked by the other:
#   - scripts/sha256.sh prints `shasum -a 256`'s lines for known inputs (a file, a name
#     with a space, stdin), whichever tool computes them;
#   - its -c accepts a matching sum file and refuses a changed archive;
#   - zig-source-id.sh gives a fixture program the identity pinned below, so a host that
#     hashes differently (GNU sha256sum's "*" marker, CRLF line endings) fails here rather
#     than refusing every stamped archive at build time;
#   - stamp-archive.sh / check-archive-stamp.sh take a Windows `<name>.lib` as they take a
#     `lib<name>.a`, and still refuse a stamp that is not for the bytes beside it;
#   - this repo's checkouts never rewrite line endings (.gitattributes), which would give
#     a Windows clone with core.autocrlf=true a different identity for the same commit.
#
# Exit status: 0 when every case passes.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
S="$ROOT/scripts"
tmp="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/sha256-test.XXXXXX")" && pwd -P)"
trap 'rm -rf "$tmp"' EXIT
case "$tmp" in "$ROOT"/*) echo "scratch dir $tmp is inside the repo" >&2; exit 1 ;; esac

pass=0 fail=0
ok()  { pass=$((pass + 1)); echo "  ✓ $1"; }
bad() { fail=$((fail + 1)); echo "  ✘ $1"; }

tools=()
command -v shasum >/dev/null 2>&1 && tools+=(shasum)
command -v sha256sum >/dev/null 2>&1 && tools+=(sha256sum)
[ ${#tools[@]} -gt 0 ] || { echo "neither shasum nor sha256sum is on PATH" >&2; exit 1; }
echo "hash tools on this host: ${tools[*]}"

# sha256("abc"), FIPS 180-2 appendix B.1.
ABC=ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad

mkdir -p "$tmp/files"
printf abc > "$tmp/files/x"
printf abc > "$tmp/files/a b"

echo "sha256.sh prints shasum's format"
for t in "${tools[@]}"; do
  got="$(cd "$tmp/files" && SHA256_TOOL=$t "$S/sha256.sh" x)"
  [ "$got" = "$ABC  x" ] && ok "$t: a file" || bad "$t: a file printed '$got'"
  got="$(cd "$tmp/files" && SHA256_TOOL=$t "$S/sha256.sh" "a b")"
  [ "$got" = "$ABC  a b" ] && ok "$t: a name with a space" || bad "$t: a name with a space printed '$got'"
  got="$(printf abc | SHA256_TOOL=$t "$S/sha256.sh")"
  [ "$got" = "$ABC  -" ] && ok "$t: stdin" || bad "$t: stdin printed '$got'"
done

echo "sha256.sh -c"
printf '%s  x\n' "$ABC" > "$tmp/files/x.sha256"
for t in "${tools[@]}"; do
  if (cd "$tmp/files" && SHA256_TOOL=$t "$S/sha256.sh" -c x.sha256); then
    ok "$t: a matching sum file passes"
  else
    bad "$t: a matching sum file was refused"
  fi
  printf abd > "$tmp/files/y"
  printf '%s  y\n' "$ABC" > "$tmp/files/y.sha256"
  if (cd "$tmp/files" && SHA256_TOOL=$t "$S/sha256.sh" -c y.sha256 2>/dev/null); then
    bad "$t: a changed file passed"
  else
    ok "$t: a changed file is refused"
  fi
done

echo "zig-source-id.sh is the same on every host"
# Outside any git work tree, so every file present counts. The pinned value is what
# shasum on macOS computes for exactly these bytes.
prog="$tmp/prog"
mkdir -p "$prog/src"
printf 'pub fn f() u32 {\n    return 7;\n}\n' > "$prog/src/lib.zig"
printf 'const std = @import("std");\npub fn build(b: *std.Build) void {\n    _ = b;\n}\n' > "$prog/build.zig"
printf 'line one\r\nline two\r\n' > "$prog/src/vectors.rsp"
PINNED=85d843d4ba47ac1772519f63929af937a626d69fc9bb29937726a72ece530daf
for t in "${tools[@]}"; do
  got="$(SHA256_TOOL=$t "$S/zig-source-id.sh" "$prog")"
  [ "$got" = "$PINNED" ] && ok "$t: the fixture's identity is the pinned one" \
    || bad "$t: the fixture's identity is $got, not $PINNED"
done

echo "stamps on a Windows .lib"
for t in "${tools[@]}"; do
  for c in "${tools[@]}"; do
    d="$tmp/lib-$t-$c"
    mkdir -p "$d"
    printf '!<arch>\nfixture' > "$d/fx.lib"
    SHA256_TOOL=$t "$S/stamp-archive.sh" "$d/fx.lib" "$PINNED"
    if [ -f "$d/fx-source-id.txt" ] && [ -f "$d/fx.lib.sha256" ]; then
      ok "stamped by $t: fx-source-id.txt and fx.lib.sha256 written"
    else
      bad "stamped by $t: expected fx-source-id.txt and fx.lib.sha256 in $(ls "$d")"
    fi
    if SHA256_TOOL=$c "$S/check-archive-stamp.sh" "$d/fx.lib" "$prog"; then
      ok "stamped by $t, checked by $c: passes"
    else
      bad "stamped by $t, checked by $c: refused"
    fi
    printf '!<arch>\nrebuilt' > "$d/fx.lib"
    if SHA256_TOOL=$c "$S/check-archive-stamp.sh" "$d/fx.lib" "$prog" 2>/dev/null; then
      bad "stamped by $t, checked by $c: an archive rewritten after stamping passed"
    else
      ok "stamped by $t, checked by $c: an archive rewritten after stamping is refused"
    fi
  done
done
if "$S/stamp-archive.sh" "$tmp/files/x" "$PINNED" 2>/dev/null; then
  bad "stamp-archive.sh stamped a file that is neither .a nor .lib"
else
  ok "stamp-archive.sh refuses a file that is neither .a nor .lib"
fi

echo "checkouts keep the committed bytes"
for f in programs/simd_crypto_ffi/build.zig programs/simd_crypto_ffi/testdata/nist/SHA256ShortMsg.rsp; do
  attr="$(git -C "$ROOT" check-attr text -- "$f" | sed 's/.*: text: //')"
  [ "$attr" = unset ] && ok "$f: no line-ending conversion" \
    || bad "$f: text attribute is '$attr', so a core.autocrlf=true clone rewrites it"
done

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
