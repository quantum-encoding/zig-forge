# Provenance of programs/simd_crypto_ffi/testdata/

Fetched 2026-10-10. `tools/extract_vectors.py <download dir> testdata` rebuilds every file
here from the downloads below (NIST and JSON files are copied byte-for-byte; the rest are parsed
from the published text). `differential/rust_reference.txt` is written by `tools/crypto-refgen`
at the repo root (`scripts/crypto-conformance.sh --regen`).

| File(s) | Publisher and URL | SHA-256 of the download |
|---|---|---|
| `nist/SHA{256,512}{ShortMsg,LongMsg,Monte}.rsp` | NIST CAVP SHAVS byte-oriented, https://csrc.nist.gov/CSRC/media/Projects/Cryptographic-Algorithm-Validation-Program/documents/shs/shabytetestvectors.zip | `929ef80b7b3418aca026643f6f248815913b60e01741a44bba9e118067f4c9b8` |
| `nist/HMAC.rsp` | NIST CAVP HMAC, https://csrc.nist.gov/CSRC/media/Projects/Cryptographic-Algorithm-Validation-Program/documents/mac/hmactestvectors.zip | `418c3837d38f249d6668146bd0090db24dd3c02d2e6797e3de33860a387ae4bd` |
| `blake3/test_vectors.json` | BLAKE3 team, https://raw.githubusercontent.com/BLAKE3-team/BLAKE3/master/test_vectors/test_vectors.json | `dcb91ea8accc77e6d6e632af7cdc1a99a9f3ae78cf648da595c7d064db32f624` |
| `bip39/vectors.json` | Trezor reference implementation named by BIP-0039, https://raw.githubusercontent.com/trezor/python-mnemonic/master/vectors.json | `fa3b937b7cff9c9b8ecd3aa011faeb8d6dd67993174b72326e83f4de8fdb30f8` |
| `secp256k1/tiny-secp256k1-ecdsa.json` | bitcoinjs tiny-secp256k1 fixtures (RFC 6979, low-S), https://raw.githubusercontent.com/bitcoinjs/tiny-secp256k1/master/tests/fixtures/ecdsa.json | `b830aa30d0ab3b6c51440caffac9206b24ae5450a387a2db73789f5ce795595d` |
| `rfc/rfc8439_chacha20.txt` | RFC 8439 2.4.2, A.1, A.2, https://www.rfc-editor.org/rfc/rfc8439.txt | `25bef70fbf7a07ff45c2fe4cb7c6ce954eac687413d8610603268b4e4415324c` |
| `rfc/rfc4231_hmac.txt` | RFC 4231 section 4, https://www.rfc-editor.org/rfc/rfc4231.txt | `72178527ce93500e730bc8eb182b857e583096d652b64ece0879c52ba1df973b` |
| `rfc/rfc7914_pbkdf2_sha256.txt` | RFC 7914 section 11, https://www.rfc-editor.org/rfc/rfc7914.txt | `df55932f8b6a5d271f36a634d91a25903724e189ba6c120bf7257cd47f10b197` |
| `ripemd160/vectors.txt` | RIPEMD-160 designers (Bosselaers), https://homes.esat.kuleuven.be/~bosselae/ripemd160.html | `2c93056656682146eedb9cc4848f22b100f5b078226c990c02081db9b972f2d7` |
| `bip32/vectors.txt` | BIP-0032 test vectors 1-4, https://raw.githubusercontent.com/bitcoin/bips/master/bip-0032.mediawiki | `e5e00a8289db2f681052cf24a745320afc225e66b25d1e489a7c884d2fc7f11f` |
| `bech32/valid_segwit.txt` | BIP-0350 valid addresses, https://raw.githubusercontent.com/bitcoin/bips/master/bip-0350.mediawiki | `63634b06aa8bae88b31929674736e74964c4598684269ac2b0b140c43a7a0dec` |
