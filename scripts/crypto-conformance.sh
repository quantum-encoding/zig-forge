#!/usr/bin/env bash
# Crypto conformance gate for the Zig crypto the wallets link (docs/CRYPTO-CONFORMANCE.md).
#
#   scripts/crypto-conformance.sh          check: regenerate the Rust differential corpora into a
#                                          temp dir and diff them against the committed ones, then
#                                          run `zig build test` for every program in the table
#   scripts/crypto-conformance.sh --regen  rewrite the committed corpora (after a deliberate
#                                          reference-crate bump), then run the tests
#   scripts/crypto-conformance.sh --no-rust  skip the corpus check (no cargo on this machine)
#
# Test builds only: nothing here runs `zig build lib`, so no consumed archive or stamp is touched.
#
# The Zig is the one consumed archives are built with (scripts/zig-toolchain.sh): $ZIG,
# else the forge's patched install (~/.local/zig-0.17.0-p1, scripts/patch-zig-0.17.sh),
# else PATH `zig`; any other toolchain is refused, so the vectors are proven on the
# compiler that builds the shipped archives.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=zig-toolchain.sh
. "$root/scripts/zig-toolchain.sh"
forge_zig_require
echo "zig: $ZIG ($ZIG_TOOLCHAIN_ID)"
mode="${1:-check}"
programs=(programs/simd_crypto_ffi programs/zig-quantum-encryption zig_core_utils/zsss)
corpora=(programs/simd_crypto_ffi/testdata/differential/rust_reference.txt
         programs/zig-quantum-encryption/testdata/differential/rust_reference.txt)

if [[ "$mode" != "--no-rust" ]]; then
  (cd "$root/tools/crypto-refgen" && nice -n 10 cargo build --release --locked -q)
  gen="$root/tools/crypto-refgen/target/release/crypto-refgen"
  if [[ "$mode" == "--regen" ]]; then
    "$gen" "$root"
  else
    tmp="$(mktemp -d)"
    trap 'rm -r "$tmp"' EXIT
    for c in "${corpora[@]}"; do mkdir -p "$tmp/$(dirname "$c")"; done
    "$gen" "$tmp" >/dev/null
    for c in "${corpora[@]}"; do
      if ! cmp -s "$root/$c" "$tmp/$c"; then
        echo "FAIL: $c differs from what the reference crates produce now (run with --regen if intended)" >&2
        exit 1
      fi
      echo "ok   $c reproduces from the reference crates"
    done
  fi
fi

for p in "${programs[@]}"; do
  echo "== zig build test: $p"
  (cd "$root/$p" && nice -n 10 "$ZIG" build test --summary new)
done
echo "crypto conformance: all green"
