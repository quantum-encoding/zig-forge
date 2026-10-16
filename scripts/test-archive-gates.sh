#!/usr/bin/env bash
# Tests for the gates on archives other repos link (work items 437F922C and FB672FF4).
#
#   scripts/test-archive-gates.sh
#
# 437F922C — an Apple archive must LINK, and zsss's build must make it so:
#   - an archive as the forge's Zig (0.17) writes it passes check-apple-archive.sh with no
#     repack; an archive as Zig 0.16 wrote it (a 2-byte-aligned member) still fails it,
#     with ld's "not 8-byte aligned" asserted, when a 0.16 is available to write one
#     (ZIG16 or PATH zig), so the gate is shown to catch what it exists for;
#   - zsss's `zig build ios macos` (into a scratch prefix) produces macOS, iOS and simulator
#     archives that all pass check-apple-archive.sh. In 2026-10, with Zig 0.16 and only the
#     macOS archive repacked, the iOS and simulator ones failed.
#
# FB672FF4 — a stamp must not vouch for an archive it was not written for:
#   - a stamp pulled through git onto a clone holding an older archive (the 338c9594
#     restamp case, replayed with real repos) fails check-archive-stamp.sh;
#   - so do a missing .a.sha256, a missing archive, and a stale source-id;
#   - so does an archive whose -toolchain.txt names a Zig the forge does not build with
#     (an unpatched 0.17.0), or that has none;
#   - build-android-libs.sh stamps what it builds (A4E49146: it wrote no stamp);
#   - this repo's .gitignore refuses the programs/ios-libs stamps and every .a.sha256,
#     and nothing of the kind is tracked.
#
# FC6894C5 — zterm_plex's ensure-fresh-lib.sh judges an archive by its stamps' sha256,
#   not by file times: one rewritten after stamping but older than its stamp is rebuilt.
#
# Needs the forge's Zig (scripts/zig-toolchain.sh), git and Xcode's SDKs (DEVELOPER_DIR, if xcode-select points at the
# Command Line Tools). Exit status: 0 when every case passes.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
S="$ROOT/scripts"
tmp="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/archive-gates-test.XXXXXX")" && pwd -P)"
trap 'rm -rf "$tmp"' EXIT
case "$tmp" in "$ROOT"/*) echo "scratch dir $tmp is inside the repo" >&2; exit 1 ;; esac

# The Zig the build scripts use (scripts/zig-toolchain.sh), exported to them.
# shellcheck source=zig-toolchain.sh
. "$S/zig-toolchain.sh"
forge_zig_require
echo "zig: $ZIG ($ZIG_TOOLCHAIN_ID)"
zig_() { "$ZIG" "$@"; }

pass=0 fail=0
ok()  { pass=$((pass + 1)); echo "  ✓ $1"; }
bad() { fail=$((fail + 1)); echo "  ✘ $1"; }

echo "437F922C: Apple archives must link"

# A symbol name of this length left Zig 0.16's single member at an offset that is 2 mod 8.
mkdir -p "$tmp/fx"
printf 'export fn fx_abcd() u32 {\n    return 7;\n}\n' > "$tmp/fx/fx.zig"
(cd "$tmp/fx" && ZIG_GLOBAL_CACHE_DIR="$tmp/fx/gcache" zig_ build-lib -static -target aarch64-ios.26.0-simulator \
  -OReleaseFast --name fx fx.zig --cache-dir "$tmp/fx/cache")
if out="$("$S/check-apple-archive.sh" "$tmp/fx/libfx.a" 2>&1)"; then
  ok "an archive as the forge's Zig writes it links with no repack (8-byte aligned members)"
else
  bad "an archive as the forge's Zig writes it fails the link check: $out"
fi
# The gate itself must still catch a misaligned member. Zig 0.16 writes one for this
# fixture, so when a 0.16 is at hand (ZIG16, or PATH `zig` reporting 0.16.x) its archive
# must fail with ld's "not 8-byte aligned"; without one the case says it was skipped.
zig16="${ZIG16:-zig}"
if command -v "$zig16" >/dev/null 2>&1 && [[ "$("$zig16" version 2>/dev/null)" == 0.16.* ]]; then
  mkdir -p "$tmp/fx16"
  (cd "$tmp/fx16" && "$zig16" build-lib -static -target aarch64-ios.26.0-simulator -OReleaseFast \
    --name fx "$tmp/fx/fx.zig" --cache-dir "$tmp/fx16/cache" --global-cache-dir "$tmp/fx16/gcache")
  if out="$("$S/check-apple-archive.sh" "$tmp/fx16/libfx.a" 2>&1)"; then
    bad "a Zig 0.16 archive with a 2-byte-aligned member passed the link check"
  elif grep -q 'not 8-byte aligned' <<<"$out"; then
    ok "a misaligned member (Zig 0.16's archive) still fails the link check (ld: not 8-byte aligned)"
  else
    bad "fixture precondition: expected ld's 'not 8-byte aligned' from the 0.16 archive, got: $out"
  fi
else
  echo "  - skipped: no Zig 0.16 (ZIG16) to write a misaligned fixture for the negative case"
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

# An Android shared library is stamped and checked like an archive (same stem, so it
# shares the .a's source-id line and has its own .so.sha256).
printf 'shared library bytes\n' > "$tmp/m2/ios-libs/libx.so"
"$S/stamp-archive.sh" "$tmp/m2/ios-libs/libx.so" "$id"
if [ -f "$tmp/m2/ios-libs/libx.so.sha256" ] &&
   "$S/check-archive-stamp.sh" "$tmp/m2/ios-libs/libx.so" "$prog" 2>/dev/null &&
   "$S/check-archive-stamp.sh" "$tmp/m2/ios-libs/libx.a" "$prog" 2>/dev/null; then
  ok "a .so is stamped (own .so.sha256) and checked beside the .a of the same stem"
else
  bad "a .so could not be stamped and checked beside its .a"
fi
printf 'other shared library bytes\n' > "$tmp/m2/ios-libs/libx.so"
if out="$("$S/check-archive-stamp.sh" "$tmp/m2/ios-libs/libx.so" "$prog" 2>&1)"; then
  bad "a rewritten .so passed its stamp"
elif grep -q 'sha256 mismatch' <<<"$out"; then
  ok "a .so rewritten after stamping fails the gate (sha256 mismatch)"
else
  bad "a rewritten .so failed for the wrong reason: $out"
fi

cp "$tmp/m2/ios-libs/libx.a" "$tmp/nosum.a"
"$S/stamp-archive.sh" "$tmp/nosum.a" "$id"
rm "$tmp/nosum.a.sha256"
if "$S/check-archive-stamp.sh" "$tmp/nosum.a" "$prog" 2>/dev/null; then
  bad "a stamp with no .a.sha256 passed"
else
  ok "a source-id stamp without its .a.sha256 fails the gate"
fi

# The toolchain stamp: a vanilla 0.17.0 says `zig version` 0.17.0 exactly like the forge's
# patched one, so only <lib>-toolchain.txt tells their archives apart.
cp "$tmp/m2/ios-libs/libx.a" "$tmp/vanilla.a"
"$S/stamp-archive.sh" "$tmp/vanilla.a" "$id" "zig 0.17.0 (unpatched)"
if out="$("$S/check-archive-stamp.sh" "$tmp/vanilla.a" "$prog" 2>&1)"; then
  bad "an archive stamped as built by an unpatched 0.17.0 passed"
elif grep -q "was built with 'zig 0.17.0 (unpatched)'" <<<"$out"; then
  ok "an archive built by an unpatched Zig 0.17.0 fails the gate (toolchain stamp)"
else
  bad "an unpatched-0.17.0 archive failed for the wrong reason: $out"
fi
cp "$tmp/m2/ios-libs/libx.a" "$tmp/notc.a"
"$S/stamp-archive.sh" "$tmp/notc.a" "$id"
if [ "$(cat "$tmp/notc-toolchain.txt")" != "$ZIG_TOOLCHAIN_ID" ]; then
  bad "stamp-archive.sh without a toolchain argument did not record \$ZIG_TOOLCHAIN_ID"
fi
rm "$tmp/notc-toolchain.txt"
if "$S/check-archive-stamp.sh" "$tmp/notc.a" "$prog" 2>/dev/null; then
  bad "an archive with no -toolchain.txt passed"
else
  ok "an archive without its -toolchain.txt fails the gate"
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

# A4E49146: the Android archive was the one producer that wrote no stamp at all.
android="$ROOT/programs/simd_crypto_ffi/zig-out/lib/android-arm64/libquantum_crypto.a"
if ! zsh -lc '"$0" quantum_crypto' "$ROOT/programs/build-android-libs.sh" >"$tmp/android.log" 2>&1; then
  bad "build-android-libs.sh quantum_crypto failed:"; sed 's/^/      /' "$tmp/android.log"
elif out="$("$S/check-archive-stamp.sh" "$android" "$ROOT/programs/simd_crypto_ffi" 2>&1)"; then
  ok "build-android-libs.sh stamps the Android quantum_crypto archive (source-id + sha256)"
else
  bad "the Android archive is not verifiable: $out"
fi

# FC6894C5: zterm_plex's ensure-fresh-lib.sh (aiconductor's Xcode Run Script; the program
# was terminal_mux) decided "current" from the source-id plus file times, so an archive
# rewritten after stamping but left older than its stamp (a copy, a restore, `touch`)
# passed. It must judge by the stamps' sha256 and toolchain as check-archive-stamp.sh does.
# Replayed in a scratch forge: the real scripts, and a one-function program named
# zterm_plex with a `lib` step that also installs the archive under its former name.
# programs/terminal_mux links to it and the script is called by that path, as consumers
# still on the old name call it, so it must take the source id over the real directory.
efl="$tmp/efl"
mkdir -p "$efl/programs/zterm_plex/src" "$efl/programs/zterm_plex/scripts"
ln -s zterm_plex "$efl/programs/terminal_mux"
ln -s "$S" "$efl/scripts"
cp "$ROOT/programs/zterm_plex/scripts/ensure-fresh-lib.sh" "$efl/programs/zterm_plex/scripts/"
printf 'export fn tm_probe() u32 {\n    return 1;\n}\n' > "$efl/programs/zterm_plex/src/lib.zig"
cat > "$efl/programs/zterm_plex/build.zig" <<'ZIG'
const std = @import("std");
pub fn build(b: *std.Build) void {
    const lib = b.addLibrary(.{ .linkage = .static, .name = "zterm_plex", .root_module = b.createModule(.{
        .root_source_file = b.path("src/lib.zig"),
        .target = b.standardTargetOptions(.{}),
        .optimize = b.standardOptimizeOption(.{}),
    }) });
    const step = b.step("lib", "consumed archive");
    step.dependOn(&b.addInstallArtifact(lib, .{}).step);
    step.dependOn(&b.addInstallLibFile(lib.getEmittedBin(), "libterminal_mux.a").step);
}
ZIG
efl_run() { ZIG_GLOBAL_CACHE_DIR="$tmp/efl-gcache" "$efl/programs/terminal_mux/scripts/ensure-fresh-lib.sh" 2>&1; }
efl_dir="$efl/programs/zterm_plex/zig-out/lib"
efl_lib="$efl_dir/libzterm_plex.a"
if ! out="$(efl_run)" || ! grep -q 'rebuilt' <<<"$out"; then
  bad "ensure-fresh-lib.sh did not build a missing archive: $out"
elif ! out="$(efl_run)" || ! grep -q 'is current' <<<"$out"; then
  bad "ensure-fresh-lib.sh rebuilt an archive it had just stamped (called by the former path): $out"
elif ! [ -f "$efl_dir/libterminal_mux.a" ]; then
  bad "the lib step did not install the archive under its former name"
else
  ok "ensure-fresh-lib.sh, called by the former path, builds a missing archive, then calls it current"
  mv "$efl_dir/libterminal_mux.a" "$efl_dir/libterminal_mux.a.away"
  if ! out="$(efl_run)" || ! grep -q 'libterminal_mux.a (the former name' <<<"$out" || ! [ -f "$efl_dir/libterminal_mux.a" ]; then
    bad "ensure-fresh-lib.sh did not rebuild when the former-name archive was missing: $out"
  else
    ok "ensure-fresh-lib.sh rebuilds when the former-name archive consumers link is missing"
  fi
  printf 'not the stamped archive\n' > "$efl_lib"
  touch -r "$efl_dir/libzterm_plex-source-id.txt" -A -000100 "$efl_lib"
  if ! [ "$efl_lib" -ot "$efl_dir/libzterm_plex-source-id.txt" ]; then
    bad "setup: the rewritten archive is not older than its stamp"
  elif ! out="$(efl_run)"; then
    bad "ensure-fresh-lib.sh failed to rebuild a rewritten archive: $out"
  elif grep -q 'is current' <<<"$out"; then
    bad "ensure-fresh-lib.sh called an archive rewritten after stamping current (FC6894C5)"
  elif grep -q 'sha256 mismatch' <<<"$out" &&
       "$S/check-archive-stamp.sh" "$efl_lib" "$efl/programs/zterm_plex" 2>/dev/null; then
    ok "ensure-fresh-lib.sh rebuilds an archive rewritten after stamping, whatever its mtime (sha256)"
  else
    bad "ensure-fresh-lib.sh handled a rewritten archive wrongly: $out"
  fi
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
