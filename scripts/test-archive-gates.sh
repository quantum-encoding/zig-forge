#!/usr/bin/env bash
# Tests for the gates on archives other repos link (work items 437F922C and FB672FF4).
#
#   scripts/test-archive-gates.sh
#
# 437F922C — an Apple archive must LINK, and zsss's build must make it so:
#   - an archive as Zig 0.16 writes it (2-byte member alignment) fails
#     check-apple-archive.sh, and the same archive repacked with repack-for-xcode.sh
#     passes. The fixture is built with `zig build-lib`; its precondition (ld reports the
#     member "not 8-byte aligned") is asserted, so a Zig that stops writing misaligned
#     members makes the test say so rather than pass vacuously;
#   - zsss's `zig build ios macos` (into a scratch prefix) produces macOS, iOS and simulator
#     archives that all pass check-apple-archive.sh. Before build.zig repacked them,
#     the iOS and simulator ones failed.
#
# FB672FF4 — a stamp must not vouch for an archive it was not written for:
#   - a stamp pulled through git onto a clone holding an older archive (the 338c9594
#     restamp case, replayed with real repos) fails check-archive-stamp.sh;
#   - so do a missing .a.sha256, a missing archive, and a stale source-id;
#   - this repo's .gitignore refuses the programs/ios-libs stamps and every .a.sha256,
#     and nothing of the kind is tracked.
#
# Needs zig (zsh -lc), git and Xcode's SDKs (DEVELOPER_DIR, if xcode-select points at the
# Command Line Tools). Exit status: 0 when every case passes.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
S="$ROOT/scripts"
tmp="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/archive-gates-test.XXXXXX")" && pwd -P)"
trap 'rm -rf "$tmp"' EXIT
case "$tmp" in "$ROOT"/*) echo "scratch dir $tmp is inside the repo" >&2; exit 1 ;; esac

zig_() { zsh -lc 'zig "$@"' zig "$@"; }

pass=0 fail=0
ok()  { pass=$((pass + 1)); echo "  ✓ $1"; }
bad() { fail=$((fail + 1)); echo "  ✘ $1"; }

echo "437F922C: Apple archives must link"

# A symbol name of this length leaves Zig's single member at an offset that is 2 mod 8.
mkdir -p "$tmp/fx"
printf 'export fn fx_abcd() u32 {\n    return 7;\n}\n' > "$tmp/fx/fx.zig"
(cd "$tmp/fx" && zig_ build-lib -static -target aarch64-ios-simulator -OReleaseFast \
  --name fx fx.zig --cache-dir "$tmp/fx/cache" --global-cache-dir "$tmp/fx/gcache")
if out="$("$S/check-apple-archive.sh" "$tmp/fx/libfx.a" 2>&1)"; then
  bad "an archive as Zig writes it passed the link check"
elif grep -q 'not 8-byte aligned' <<<"$out"; then
  ok "an archive as Zig writes it (ld: member not 8-byte aligned) fails the link check"
else
  bad "fixture precondition: expected ld's 'not 8-byte aligned', got: $out"
fi
"$S/repack-for-xcode.sh" "$tmp/fx/libfx.a" >/dev/null
if "$S/check-apple-archive.sh" "$tmp/fx/libfx.a" >/dev/null 2>&1; then
  ok "the same archive repacked with repack-for-xcode.sh links"
else
  bad "the repacked archive still fails the link check"
fi

zsss_out="$tmp/zsss-out"
(cd "$ROOT/zig_core_utils/zsss" && zig_ build ios macos --prefix "$zsss_out" >/dev/null)
apple=("$zsss_out"/lib/libzsss-*-macos.a "$zsss_out"/lib/libzsss-*-ios.a "$zsss_out"/lib/libzsss-*-ios-simulator.a)
if [ ${#apple[@]} -eq 5 ] && "$S/check-apple-archive.sh" "${apple[@]}" >"$tmp/zsss.log" 2>&1; then
  ok "zsss's zig build ios macos: all ${#apple[@]} Apple archives link"
else
  bad "zsss's Apple archives (${#apple[@]} found) do not all link:"
  sed 's/^/      /' "$tmp/zsss.log"
fi

echo "FB672FF4: a stamp vouches only for its own archive"

# A program whose identity zig-source-id.sh can take (outside git: every file counts).
prog="$tmp/prog"
mkdir -p "$prog"
printf 'pub fn f() void {}\n' > "$prog/lib.zig"
id="$("$S/zig-source-id.sh" "$prog")"

# The 338c9594 case with real repos. "m2" builds, stamps and commits its stamp the way
# programs/ios-libs did (forced past the ignore rule, as tracking it was); "m5" holds
# its own older archive and pulls.
git_() { git -c user.name=t -c user.email=t@t -c init.defaultBranch=main -c chronos.enabled=false "$@"; }
for m in m2 m5; do git_ init -q "$tmp/$m"; done
mkdir -p "$tmp/m2/ios-libs" "$tmp/m5/ios-libs"
printf '*.a\n' > "$tmp/m2/.gitignore"
git_ -C "$tmp/m2" add .gitignore && git_ -C "$tmp/m2" commit -qm init
git_ -C "$tmp/m5" pull -q "$tmp/m2" main

printf 'old archive bytes\n' > "$tmp/m5/ios-libs/libx.a"
"$S/stamp-archive.sh" "$tmp/m5/ios-libs/libx.a" "older-source-id"
printf 'new archive bytes\n' > "$tmp/m2/ios-libs/libx.a"
"$S/stamp-archive.sh" "$tmp/m2/ios-libs/libx.a" "$id"
if "$S/check-archive-stamp.sh" "$tmp/m2/ios-libs/libx.a" "$prog" 2>/dev/null; then
  ok "fresh: the archive its stamp was written for passes"
else
  bad "a freshly stamped archive fails"
fi

git_ -C "$tmp/m2" add -f ios-libs/libx-source-id.txt ios-libs/libx.a.sha256
git_ -C "$tmp/m2" commit -qm "restamp"
# The pull overwrites m5's untracked stamps, as the 338c9594 pull did.
rm "$tmp/m5/ios-libs/libx-source-id.txt" "$tmp/m5/ios-libs/libx.a.sha256"
git_ -C "$tmp/m5" pull -q "$tmp/m2" main
if [ "$(cat "$tmp/m5/ios-libs/libx-source-id.txt")" != "$id" ]; then
  bad "setup: the pull did not bring the new stamp"
elif out="$("$S/check-archive-stamp.sh" "$tmp/m5/ios-libs/libx.a" "$prog" 2>&1)"; then
  bad "a stamp pulled onto an older archive passed the gate (the FB672FF4 hole)"
elif grep -q 'sha256 mismatch' <<<"$out"; then
  ok "a stamp pulled through git onto an older archive fails the gate (sha256 mismatch)"
else
  bad "a pulled stamp failed for the wrong reason: $out"
fi

cp "$tmp/m2/ios-libs/libx.a" "$tmp/nosum.a"
"$S/stamp-archive.sh" "$tmp/nosum.a" "$id"
rm "$tmp/nosum.a.sha256"
if "$S/check-archive-stamp.sh" "$tmp/nosum.a" "$prog" 2>/dev/null; then
  bad "a stamp with no .a.sha256 passed"
else
  ok "a source-id stamp without its .a.sha256 fails the gate"
fi

if "$S/check-archive-stamp.sh" "$tmp/absent.a" "$prog" 2>/dev/null; then
  bad "a missing archive passed"
else
  ok "a missing archive fails the gate"
fi

printf 'pub fn g() void {}\n' >> "$prog/lib.zig"
if out="$("$S/check-archive-stamp.sh" "$tmp/m2/ios-libs/libx.a" "$prog" 2>&1)"; then
  bad "a stale source-id passed"
elif grep -q 'its sources are now' <<<"$out"; then
  ok "an archive whose sources changed since stamping fails the gate"
else
  bad "a stale archive failed for the wrong reason: $out"
fi

ignored=(programs/ios-libs/ios-arm64/libquantum_crypto-source-id.txt
         programs/ios-libs/ios-sim-arm64/libquantum_crypto-source-id.txt
         programs/ios-libs/ios-arm64/libquantum_crypto.a.sha256
         zig_core_utils/zsss/zig-out/lib/libzsss-aarch64-ios.a.sha256)
all_ignored=1
for p in "${ignored[@]}"; do
  git -C "$ROOT" check-ignore -q --no-index "$p" || { all_ignored=0; bad "$p is not ignored"; }
done
[ "$all_ignored" = 1 ] && ok "this repo ignores the ios-libs stamps and every .a.sha256"
tracked="$(git -C "$ROOT" ls-files 'programs/ios-libs/*-source-id.txt' '*.a.sha256')"
if [ -z "$tracked" ]; then
  ok "no ios-libs stamp or .a.sha256 is tracked"
else
  bad "tracked stamps: $tracked"
fi

echo
echo "archive gates: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
