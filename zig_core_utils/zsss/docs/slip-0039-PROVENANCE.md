# SLIP-0039 archived artifacts

`src/slip39.zig` implements SLIP-0039. These files are the specification and
test data it was written against, archived verbatim so that future changes are
checked against the spec rather than against memory. Do not edit them; refresh
them from upstream and re-run `zig build test` instead.

Fetched 2026-07-29:

| File | Upstream | SHA-256 |
|------|----------|---------|
| `docs/slip-0039.md` | https://raw.githubusercontent.com/satoshilabs/slips/master/slip-0039.md | `7b4269f66f10f03ac685ea7c76f742bfbf56211af1af29339eadef9acba1f856` |
| `docs/slip-0039-wordlist.txt` | https://raw.githubusercontent.com/satoshilabs/slips/master/slip-0039/wordlist.txt | `bcc4555340332d169718aed8bf31dd9d5248cb7da6e5d355140ef4f1e601eec3` |
| `tests/slip-0039-vectors.json` | https://raw.githubusercontent.com/trezor/python-shamir-mnemonic/master/vectors.json | `13ebecebdd869dd2bc2cdf69e7ce3a158cf106cac76c39d17682b1c6cdabbdc4` |

Verify with `shasum -a 256 <file>`.

## How each artifact is used

- **`slip-0039.md`** — the specification. Comments in `src/slip39.zig` cite its
  section names ("Format of the share mnemonic", "Encryption of the master
  secret", "Combining the shares", and the numbered "Design rationale"
  footnotes) so that every constant and validity check is traceable to the text
  it comes from.

- **`slip-0039-wordlist.txt`** — the mandated 1024-word list. The copy compiled
  into `slip39.wordlist` is identical to this file, in the same order. A test in
  `src/slip39.zig` re-checks the properties the spec requires of the list
  (alphabetically sorted, 4-8 letters, unique 4-letter prefixes), which would
  catch an accidental edit to the array.

- **`slip-0039-vectors.json`** — the canonical test vectors, which the spec's
  "Test vectors" section points to. `src/slip39_vectors_test.zig` runs every one
  of the 45 cases: 15 that must combine to a given master secret and 30 that
  must be rejected. Positive cases are additionally checked against the vector's
  BIP-0032 master `xprv`, and each share is re-encoded to confirm the encoder
  reproduces the canonical mnemonic byte for byte.

## Interoperability

Internal vectors prove conformance to the published data; they do not prove that
another implementation can read shares this one writes. That is checked
separately by `tests/slip39_interop.py`, which round-trips shares in both
directions against `python-shamir-mnemonic` (the reference implementation named
in the spec). Run it directly, or let `tests/run_tests.sh` invoke it:

```sh
pip install shamir-mnemonic
python3 tests/slip39_interop.py ./zig-out/bin/zsss
```
