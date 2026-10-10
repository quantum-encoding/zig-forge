#!/usr/bin/env bash
# Prove that Apple's linker can link each Mach-O static archive given: a one-symbol link
# per member, for the platform the archive was built for.
#
# Zig 0.16's archive writer pads Mach-O members to 2-byte alignment. ld64 does not
# refuse such an archive; it prints
#
#   ld: ignoring archive member 'libzsss-aarch64-ios_zcu.o' - 64-bit mach-o not 8-byte aligned
#
# and carries on, so every symbol the member defines is simply undefined and the
# consumer's link fails far away from the cause (Cifra's simulator build, 2026-10-10,
# work item 437F922C). Comparing a source-id stamp cannot see this: the stamp was
# correct and the archive was still unlinkable. Only a link can.
#
# For every member that defines an external text symbol, the first such symbol is
# forced with `-u`, and the linked program must define every one of them: a member ld
# ignored leaves its symbol undefined. The link allows undefined symbols
# (`-undefined dynamic_lookup`), so what this proves is that ld LOADS each member, not
# that the library's own dependencies (EndpointSecurity, a framework) are on the line;
# a consumer's full link proves those. The target (arch, platform, minimum OS) is read
# from the archive's own LC_BUILD_VERSION, so the check links for exactly what the
# archive claims to be.
#
#   scripts/check-apple-archive.sh <archive.a> [archive.a ...]
#
# Exit status: 0 when every archive links; 1 when any does not; 2 on usage. Needs
# Xcode's SDKs (xcrun --sdk iphoneos / iphonesimulator / macosx).
set -euo pipefail

[ $# -gt 0 ] || { echo "usage: $(basename "$0") <archive.a> [archive.a ...]" >&2; exit 2; }

work="$(mktemp -d "${TMPDIR:-/tmp}/check-apple-archive.XXXXXX")"
trap 'rm -rf "$work"' EXIT
printf 'int main(void) { return 0; }\n' > "$work/main.c"

failed=0
for archive in "$@"; do
  if [ ! -f "$archive" ]; then
    echo "✗ $archive: not found" >&2; failed=1; continue
  fi

  # platform 1 = macOS, 2 = iOS, 7 = iOS simulator (mach-o/loader.h PLATFORM_*).
  read -r platform minos < <(otool -l "$archive" |
    awk '/cmd LC_BUILD_VERSION/ {b=1} b && $1=="platform" {p=$2} b && $1=="minos" {print p, $2; exit}') || true
  case "$(otool -hv "$archive" | awk '$1 ~ /^MH_MAGIC/ {print $2; exit}')" in
    ARM64) arch=arm64 ;;
    X86_64) arch=x86_64 ;;
    *) echo "✗ $archive: no 64-bit Mach-O member" >&2; failed=1; continue ;;
  esac
  case "${platform:-}" in
    1) sdk=macosx;          triple="$arch-apple-macos$minos" ;;
    2) sdk=iphoneos;        triple="$arch-apple-ios$minos" ;;
    7) sdk=iphonesimulator; triple="$arch-apple-ios$minos-simulator" ;;
    *) echo "✗ $archive: no Apple LC_BUILD_VERSION (platform '${platform:-}')" >&2; failed=1; continue ;;
  esac

  # One defined external text symbol per member. nm reads the archive itself, so a
  # misaligned member is still listed here even though ld will skip it.
  syms=() flags=()
  while IFS= read -r s; do syms+=("$s"); flags+=("-Wl,-u,$s"); done < <(
    nm -gU "$archive" 2>/dev/null |
      awk '/:$/ {member=$0; next} member != "" && $2 == "T" {print $3; member=""}')
  if [ ${#syms[@]} -eq 0 ]; then
    echo "✗ $archive: no member defines an external text symbol" >&2; failed=1; continue
  fi

  rm -f "$work/a.out"
  if ! out="$(xcrun --sdk "$sdk" clang -target "$triple" "$work/main.c" "${flags[@]}" \
                -Wl,-undefined,dynamic_lookup "$archive" -o "$work/a.out" 2>&1)"; then
    echo "✗ $archive does not link for $triple:" >&2
    printf '%s\n' "$out" | sed 's/^/    /' >&2
    failed=1; continue
  fi
  # Every defined symbol, local ones included: a private-extern member symbol
  # (compiler-rt's) is global in the archive and local once linked.
  defined="$(nm "$work/a.out" | awk 'NF == 3 {print $3}')"
  missing=()
  for s in "${syms[@]}"; do
    grep -qxF "$s" <<<"$defined" || missing+=("$s")
  done
  if [ ${#missing[@]} -gt 0 ]; then
    echo "✗ $archive: ld did not load the member(s) defining ${missing[*]} ($triple)" >&2
    printf '%s\n' "$out" | grep -v 'dynamic_lookup is deprecated' | sed 's/^/    /' >&2
    failed=1
  else
    echo "✓ $archive links ($triple, ${#syms[@]} member(s))"
  fi
done
exit "$failed"
