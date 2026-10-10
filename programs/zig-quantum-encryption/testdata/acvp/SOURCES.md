# Provenance of testdata/acvp/*.txt

ACVP-Server commit 975de31eb83d87039ec88934fdc47d8c312b892d (2026-08-12), fetched 2026-10-10 from
https://raw.githubusercontent.com/usnistgov/ACVP-Server/master/gen-val/json-files/<Algorithm>/internalProjection.json

SHA-256 of each downloaded file:

```
e67ee6540d40e11506c3c4e3b1f79fc1cefcd49820db99fc61f87cc8ba463baf  ML-DSA-keyGen-FIPS204/internalProjection.json
72dcaf5f69853ca267ccd16af9cb40949786aca0fcfbf05d1ebeba132b93af22  ML-DSA-sigGen-FIPS204/internalProjection.json
47cdd6314c7f746d02421ffcba89d4dbc7bb875ac49e07a029fdfc26fba55437  ML-DSA-sigVer-FIPS204/internalProjection.json
a556952ce869bb89c3a3196a701dad89647c193a34c86eafb61a9d710d5b810f  ML-KEM-encapDecap-FIPS203/internalProjection.json
d7a62a2c3476957f56dd8d24f9004ea6776ccfe995ffe71a65bb9506dc9c7b1b  ML-KEM-keyGen-FIPS203/internalProjection.json
```

Regenerate: python3 -I tools/extract_acvp.py <dir holding the five Algorithm dirs> testdata/acvp 975de31eb83d87039ec88934fdc47d8c312b892d

## Classical half of the hybrid KEM (src/classical_conformance.zig)

Built by `python3 -I tools/extract_classical.py <download dir> testdata 975de31eb83d87039ec88934fdc47d8c312b892d`.

| File | Source | SHA-256 of the download |
|---|---|---|
| `acvp/sha3_256_aft.txt`, `acvp/sha3_256_mct.txt` | ACVP-Server `SHA3-256-2.0/internalProjection.json` (same commit) | `dba4689436c7e440e61dc517210def3e8e09e50c0e9eff29ea66d89bdd0f2c63` |
| `acvp/hmac_sha3_256.txt` | ACVP-Server `HMAC-SHA3-256-2.0/internalProjection.json` (same commit) | `a13ad967cf3752a11d5cb9bcb3e8eb10ea808f7c9087b768e434ccc6bbed4c89` |
| `rfc7748/x25519.txt` | https://www.rfc-editor.org/rfc/rfc7748.txt, sections 5.2 and 6.1 | `279ca0ecc5e92e2962e27b846986aeb74729d9dd34bd4a04a362f80dcb596ad3` |
| `wycheproof/x25519_test.json` (verbatim) | https://raw.githubusercontent.com/C2SP/wycheproof/main/testvectors_v1/x25519_test.json | `35c3f5231cf25cc640b524d403461deee9e49441d5d915a3a25b2c8ff5adbe7d` |
| `differential/rust_reference.txt` | written by tools/crypto-refgen at the repo root (x25519-dalek 2.0.1, sha3 0.10.9, hkdf 0.12.4) | regenerated and diffed by scripts/crypto-conformance.sh |
