#!/usr/bin/env python3
"""Build programs/simd_crypto_ffi/testdata/ from the published vector sources.

    python3 -I tools/extract_vectors.py <download dir> testdata

<download dir> holds the files listed in testdata/SOURCES.md under the names given there.
Machine-readable sources (NIST .rsp, JSON) are copied byte-for-byte; vectors that are only
published as prose (RFC text, BIP mediawiki, the RIPEMD-160 page) are parsed into
`key=value` record files. Nothing here computes a digest, MAC, key or signature: every
expected value is the publisher's.
"""
import html, json, os, re, shutil, sys, zipfile

src, out = sys.argv[1], sys.argv[2]
P = lambda *a: os.path.join(src, *a)


def write_records(name, header, recs):
    path = os.path.join(out, name)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write("".join(f"# {h}\n" for h in header))
        f.write("# Extracted by tools/extract_vectors.py; do not edit.\n\n")
        for r in recs:
            for k, v in r.items():
                assert "\n" not in str(v)
                f.write(f"{k}={v}\n")
            f.write("\n")
    print(f"{name}: {len(recs)} records")


def copy(srcpath, name):
    dst = os.path.join(out, name)
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    shutil.copyfile(srcpath, dst)
    print(f"{name}: copied")


# --- NIST CAVP SHAVS (byte-oriented) and HMAC: verbatim -----------------------------------
with zipfile.ZipFile(P("shabytetestvectors.zip")) as z:
    for n in ["SHA256ShortMsg", "SHA256LongMsg", "SHA256Monte", "SHA512ShortMsg", "SHA512LongMsg", "SHA512Monte"]:
        dst = os.path.join(out, "nist", n + ".rsp")
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        with open(dst, "wb") as f:
            f.write(z.read(f"shabytetestvectors/{n}.rsp"))
        print(f"nist/{n}.rsp: copied")
with zipfile.ZipFile(P("hmactestvectors.zip")) as z:
    with open(os.path.join(out, "nist", "HMAC.rsp"), "wb") as f:
        f.write(z.read("HMAC.rsp"))
    print("nist/HMAC.rsp: copied")

# --- JSON sets: verbatim -------------------------------------------------------------------
copy(P("blake3_test_vectors.json"), "blake3/test_vectors.json")
copy(P("bip39_vectors.json"), "bip39/vectors.json")
copy(P("tiny_ecdsa.json"), "secp256k1/tiny-secp256k1-ecdsa.json")


# --- RFC 8439 ChaCha20 ---------------------------------------------------------------------
def rfc_lines(name):
    # Drop page footers/headers so hexdumps that straddle a page break stay contiguous.
    keep = []
    for line in open(P(name)).read().split("\n"):
        if re.match(r"^(Nir & Langley|RFC 8439|Nystrom|RFC 4231|Percival|RFC 7914)\s", line) or line.startswith("\f"):
            continue
        keep.append(line)
    return keep


def hexdump_after(lines, start, label):
    """Bytes of the RFC 8439 hexdump that follows the first line equal to `label` at/after start."""
    i = start
    while lines[i].strip() != label:
        i += 1
    i += 1
    data = []
    while i < len(lines):
        m = re.match(r"^  (\d{3})  ", lines[i])
        if not m:
            if lines[i].strip() == "":
                i += 1
                continue
            break
        assert int(m.group(1)) == len(data), (label, lines[i])
        data += lines[i][7:7 + 48].split()
        i += 1
    return "".join(data), i


L = rfc_lines("rfc8439.txt")
recs = []
# Section 2.4.2: inputs are given inline in the prose (copied here), outputs as hexdumps.
s = next(i for i, l in enumerate(L) if l.startswith("2.4.2.  Example and Test Vector for the ChaCha20 Cipher"))
pt, _ = hexdump_after(L, s, "Plaintext Sunscreen:")
ct, _ = hexdump_after(L, s, "Ciphertext Sunscreen:")
recs.append(dict(name="RFC 8439 2.4.2", key="".join(f"{i:02x}" for i in range(32)),
                 nonce="000000000000004a00000000", counter=1, plaintext=pt, ciphertext=ct))
a1 = next(i for i, l in enumerate(L) if l.startswith("A.1.  The ChaCha20 Block Functions"))
a2 = next(i for i, l in enumerate(L) if l.startswith("A.2.  ChaCha20 Encryption"))
a3 = next(i for i, l in enumerate(L) if l.startswith("A.3.  Poly1305"))
for sec, lo, hi in [("A.1", a1, a2), ("A.2", a2, a3)]:
    starts = [i for i in range(lo, hi) if re.match(r"^  Test Vector #\d+:", L[i])]
    for n, st in enumerate(starts, 1):
        key, _ = hexdump_after(L, st, "Key:")
        nonce, _ = hexdump_after(L, st, "Nonce:")
        ctr = next(re.search(r"Counter = (\d+)", L[i]).group(1) for i in range(st, hi) if "Counter =" in L[i])
        if sec == "A.1":  # keystream = encryption of 64 zero bytes
            ks, _ = hexdump_after(L, st, "Keystream:")
            pt, ct = "00" * (len(ks) // 2), ks
        else:
            pt, _ = hexdump_after(L, st, "Plaintext:")
            ct, _ = hexdump_after(L, st, "Ciphertext:")
        assert len(key) == 64 and len(nonce) == 24 and len(pt) == len(ct)
        recs.append(dict(name=f"RFC 8439 {sec} #{n}", key=key, nonce=nonce, counter=ctr, plaintext=pt, ciphertext=ct))
write_records("rfc/rfc8439_chacha20.txt",
              ["RFC 8439 ChaCha20: section 2.4.2, Appendix A.1 (block function keystreams), A.2 (encryption)",
               "Source: https://www.rfc-editor.org/rfc/rfc8439.txt"], recs)

# --- RFC 4231 HMAC-SHA-256 / HMAC-SHA-512 ----------------------------------------------------
L = rfc_lines("rfc4231.txt")
recs = []
cases = [i for i, l in enumerate(L) if re.match(r"^4\.\d\.  Test Case \d", l)]
for ci, st in enumerate(cases):
    end = cases[ci + 1] if ci + 1 < len(cases) else next(i for i in range(st, len(L)) if L[i].startswith("5.  "))
    fields, cur = {}, None
    for l in L[st + 1:end]:
        m = re.match(r"^   (Key|Data|HMAC-SHA-\d+)\s*=?\s+([0-9a-f]+)", l)
        if m:
            cur = m.group(1)
            fields[cur] = m.group(2)
            continue
        m = re.match(r"^\s{18}([0-9a-f]+)", l)
        if m and cur:
            fields[cur] += m.group(1)
        else:
            cur = None
    truncated = "truncation of output to 128 bits" in "\n".join(L[st:end])
    recs.append(dict(name=L[st].strip(), key=fields["Key"], data=fields["Data"],
                     sha256=fields["HMAC-SHA-256"], sha512=fields["HMAC-SHA-512"],
                     truncate_bits=128 if truncated else 0))
assert len(recs) == 7
write_records("rfc/rfc4231_hmac.txt",
              ["RFC 4231 test cases 1-7 (HMAC-SHA-256, HMAC-SHA-512); case 5 publishes the leftmost 128 bits",
               "Source: https://www.rfc-editor.org/rfc/rfc4231.txt"], recs)

# --- RFC 7914 section 11: PBKDF2-HMAC-SHA256 -----------------------------------------------------
t = open(P("rfc7914.txt")).read()
sec = t[t.index("11.  Test Vectors for PBKDF2 with HMAC-SHA-256"):t.index("12.  Test Vectors for scrypt")]
sec = "\n".join(l for l in sec.split("\n") if not re.match(r"^(Percival|RFC 7914)\s", l) and not l.startswith("\f"))
recs = []
for m in re.finditer(r'PBKDF2-HMAC-SHA-256 \(P="([^"]*)", S="([^"]*)",\s+c=(\d+), dkLen=(\d+)\) =\n((?:[ ]+(?:[0-9a-f]{2} ?)+\n)+)', sec):
    dk = "".join(m.group(5).split())
    assert len(dk) == 2 * int(m.group(4))
    recs.append(dict(password=m.group(1).encode().hex(), salt=m.group(2).encode().hex(), iterations=m.group(3), dk=dk))
assert len(recs) == 2, recs
write_records("rfc/rfc7914_pbkdf2_sha256.txt",
              ["RFC 7914 section 11, PBKDF2-HMAC-SHA256", "Source: https://www.rfc-editor.org/rfc/rfc7914.txt"], recs)

# --- RIPEMD-160 (Bosselaers' page) ----------------------------------------------------------------
page = open(P("ripemd160.html"), encoding="latin-1").read()
page = re.sub(r"<SUP>(\d)</SUP>", r"\1", page, flags=re.I)  # footnote marks stay in the label cell
page = html.unescape(re.sub(r"<[^>]+>", "\t", page))
inputs = {  # labels as printed on the page -> the message (footnotes 1-3 on the same page)
    '"" (empty string)': "", '"a"': "a", '"abc"': "abc", '"message digest"': "message digest",
    '"a...z"1': "abcdefghijklmnopqrstuvwxyz",
    '"abcdbcde...nopq"2': "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq",
    '"A...Za...z0...9"3': "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789",
    '8 times "1234567890"': "1234567890" * 8,
}
cells = [c.strip().replace("\xa0", "") for c in page.split("\t") if c.strip()]
recs = []
i = cells.index('"" (empty string)')
for _ in range(9):
    label, digest = cells[i], cells[i + 1]
    lab = re.sub(r"\s+", " ", label)
    assert re.fullmatch(r"[0-9a-f]{40}", digest), (label, digest)
    if lab == '1 million times "a"':
        recs.append(dict(name=lab, repeat="a", count=1000000, digest=digest))
    else:
        recs.append(dict(name=lab, message=inputs[lab].encode().hex(), digest=digest))
    i += 3  # label, RIPEMD-160, RIPEMD-128
write_records("ripemd160/vectors.txt",
              ["RIPEMD-160 test vectors published by its designers",
               "Source: https://homes.esat.kuleuven.be/~bosselae/ripemd160.html"], recs)

# --- BIP-0032 test vectors 1-4 (vector 5 is deserialisation-only; this library has no parser) ---
t = open(P("bip-0032.mediawiki")).read()
recs, vec, seed, chain = [], None, None, None
for l in t.split("\n"):
    m = re.match(r"^===Test vector (\d)===", l)
    if m:
        vec = int(m.group(1))
    if vec is None or vec > 4:
        continue
    m = re.match(r"^Seed \(hex\): ([0-9a-f]+)", l)
    if m:
        seed = m.group(1)
    m = re.match(r"^\* Chain (m.*)$", l)
    if m:
        chain = m.group(1).replace("<sub>H</sub>", "'")
    m = re.match(r"^\*\* ext pub: (xpub\w+)", l)
    if m:
        pub = m.group(1)
    m = re.match(r"^\*\* ext prv: (xprv\w+)", l)
    if m:
        recs.append(dict(vector=vec, seed=seed, chain=chain, xpub=pub, xprv=m.group(1)))
write_records("bip32/vectors.txt",
              ["BIP-0032 test vectors 1-4", "Source: https://github.com/bitcoin/bips/blob/master/bip-0032.mediawiki"], recs)

# --- BIP-0350 valid segwit addresses with their scriptPubKey -------------------------------------
# BIP-0350's list supersedes BIP-0173's: it keeps the v0 (bech32) cases and re-encodes v1+ with
# bech32m, which is what consensus-era wallets must produce.
t = open(P("bip-0350.mediawiki")).read()
recs = [dict(address=m.group(1), script=m.group(2))
        for m in re.finditer(r"^\* <tt>(\w+1\w+)</tt>: <tt>([0-9a-f]+)</tt>$", t, re.M)]
assert len(recs) == 8, recs
write_records("bech32/valid_segwit.txt",
              ["Valid segwit addresses and their scriptPubKey, BIP-0350 'Test vectors for v0-v16 native segregated witness addresses'",
               "Source: https://github.com/bitcoin/bips/blob/master/bip-0350.mediawiki"], recs)
