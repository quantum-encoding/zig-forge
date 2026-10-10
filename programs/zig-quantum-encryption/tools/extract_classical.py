#!/usr/bin/env python3
"""Build testdata/{rfc7748,wycheproof,acvp}/ for the hybrid KEM's classical primitives
(src/classical_conformance.zig).

    python3 -I tools/extract_classical.py <download dir> testdata <ACVP-Server commit>

<download dir> holds rfc7748.txt, wp_x25519.json and acvp/{SHA3-256-2.0,HMAC-SHA3-256-2.0}/
internalProjection.json (URLs in testdata/acvp/SOURCES.md). Expected values are copied from the
publishers; nothing is computed here.
"""
import json, os, re, shutil, sys

src, out, commit = sys.argv[1], sys.argv[2], sys.argv[3]


def write(name, header, recs):
    path = os.path.join(out, name)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write("".join(f"# {h}\n" for h in header) + "# Extracted by tools/extract_classical.py; do not edit.\n\n")
        for r in recs:
            f.write("".join(f"{k}={v}\n" for k, v in r.items()) + "\n")
    print(name, len(recs))


# RFC 7748: section 5.2 (two X25519 vectors, iterated 1 and 1000 times) and section 6.1 (ECDH).
t = open(os.path.join(src, "rfc7748.txt")).read()
s52 = t[t.index("\n5.2.  Test Vectors"):t.index("\n6.  Diffie-Hellman")]
x25519 = s52[s52.index("   X25519:\n"):s52.index("   X448:\n")]
recs = []
for m in re.finditer(r"Input scalar:\s+([0-9a-f]{64}).*?Input u-coordinate:\s+([0-9a-f]{64}).*?Output u-coordinate:\s+([0-9a-f]{64})", x25519, re.S):
    recs.append(dict(kind="vector", scalar=m.group(1), u=m.group(2), out=m.group(3)))
assert len(recs) == 2
it = s52[s52.index("   For each iteration"):]
it = it[:it.index("   X448:")]
for n, label in [(1, "After one iteration:"), (1000, "After 1,000 iterations:")]:
    recs.append(dict(kind="iterate", iterations=n, out=re.search(re.escape(label) + r"\s+([0-9a-f]{64})", it).group(1)))
dh = t[t.index("\n6.1.  Curve25519\n"):t.index("\n6.2.  Curve448\n")]
vals = re.findall(r":\n\s+([0-9a-f]{64})", dh)
assert len(vals) == 5, vals
recs.append(dict(kind="dh", alice_sk=vals[0], alice_pk=vals[1], bob_sk=vals[2], bob_pk=vals[3], shared=vals[4]))
write("rfc7748/x25519.txt", ["RFC 7748 sections 5.2 and 6.1, X25519", "Source: https://www.rfc-editor.org/rfc/rfc7748.txt"], recs)

dst = os.path.join(out, "wycheproof", "x25519_test.json")
os.makedirs(os.path.dirname(dst), exist_ok=True)
shutil.copyfile(os.path.join(src, "wp_x25519.json"), dst)
print("wycheproof/x25519_test.json copied")

hdr = f"Source: https://github.com/usnistgov/ACVP-Server/tree/{commit}/gen-val/json-files"
d = json.load(open(os.path.join(src, "acvp", "SHA3-256-2.0", "internalProjection.json")))
aft = [t for g in d["testGroups"] if g["testType"] == "AFT" for t in g["tests"]]
recs = [dict(tcId=t["tcId"], len=t["len"], msg=t["msg"] if t["len"] else "", md=t["md"]) for t in aft if t["len"] % 8 == 0]
write("acvp/sha3_256_aft.txt", ["SHA3-256-2.0 internalProjection, AFT, byte-aligned messages only (std's SHA3 takes bytes)", hdr], recs)
mct = next(t for g in d["testGroups"] if g["testType"] == "MCT" for t in g["tests"])
recs = [dict(seed=mct["msg"])] + [dict(count=i, md=r["md"]) for i, r in enumerate(mct["resultsArray"])]
write("acvp/sha3_256_mct.txt", ["SHA3-256-2.0 internalProjection, MCT (standard): seed record, then 100 checkpoints", hdr], recs)
h = json.load(open(os.path.join(src, "acvp", "HMAC-SHA3-256-2.0", "internalProjection.json")))
recs = [dict(tcId=t["tcId"], key=t["key"], msg=t["msg"], mac=t["mac"]) for g in h["testGroups"] for t in g["tests"]]
write("acvp/hmac_sha3_256.txt", ["HMAC-SHA3-256-2.0 internalProjection, AFT (macLen 80-160 bits: truncated tags)", hdr], recs)
