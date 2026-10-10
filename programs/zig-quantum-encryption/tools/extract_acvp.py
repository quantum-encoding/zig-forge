#!/usr/bin/env python3
"""Extract the ML-KEM-768 / ML-DSA-65 groups from NIST ACVP-Server gen-val JSON into
testdata/acvp/*.txt, the record files src/acvp_kats.zig embeds.

Run with `python3 -I tools/extract_acvp.py <ACVP-Server checkout or download dir> testdata/acvp`.
The input dir holds <Algorithm>/internalProjection.json as published at
https://github.com/usnistgov/ACVP-Server/tree/master/gen-val/json-files. Values are copied
verbatim (hex, upper case as published); nothing is computed here.

Record format: `key=value` lines, records separated by a blank line, `#` comments.
"""
import json, os, sys

src, out = sys.argv[1], sys.argv[2]
commit = sys.argv[3] if len(sys.argv) > 3 else "unknown"

def load(alg):
    with open(os.path.join(src, alg, "internalProjection.json")) as f:
        return json.load(f)

def write(name, header, records):
    with open(os.path.join(out, name), "w") as f:
        f.write(f"# {header}\n# Source: https://github.com/usnistgov/ACVP-Server/tree/{commit}/gen-val/json-files\n")
        f.write("# Extracted verbatim by tools/extract_acvp.py; do not edit.\n\n")
        for r in records:
            for k, v in r.items():
                if isinstance(v, bool):
                    v = "true" if v else "false"
                f.write(f"{k}={v}\n")
            f.write("\n")
    print(name, len(records))

def groups(d, **want):
    for g in d["testGroups"]:
        if all(g.get(k) == v for k, v in want.items()):
            yield g

kg = load("ML-KEM-keyGen-FIPS203")
write("mlkem768_keygen.txt", "ML-KEM-keyGen-FIPS203 internalProjection, ML-KEM-768 (AFT)",
      [dict(tgId=g["tgId"], tcId=t["tcId"], d=t["d"], z=t["z"], ek=t["ek"], dk=t["dk"])
       for g in groups(kg, parameterSet="ML-KEM-768") for t in g["tests"]])

ed = load("ML-KEM-encapDecap-FIPS203")
write("mlkem768_encaps.txt", "ML-KEM-encapDecap-FIPS203 internalProjection, ML-KEM-768 encapsulation (AFT)",
      [dict(tgId=g["tgId"], tcId=t["tcId"], ek=t["ek"], m=t["m"], c=t["c"], k=t["k"])
       for g in groups(ed, parameterSet="ML-KEM-768", function="encapsulation") for t in g["tests"]])
write("mlkem768_decaps.txt", "ML-KEM-encapDecap-FIPS203 internalProjection, ML-KEM-768 decapsulation (VAL)",
      [dict(tgId=g["tgId"], tcId=t["tcId"], reason=t.get("reason", ""), dk=t["dk"], c=t["c"], k=t["k"])
       for g in groups(ed, parameterSet="ML-KEM-768", function="decapsulation") for t in g["tests"]])
write("mlkem768_dkcheck.txt", "ML-KEM-encapDecap-FIPS203 internalProjection, ML-KEM-768 decapsulationKeyCheck (VAL)",
      [dict(tgId=g["tgId"], tcId=t["tcId"], passed=t["testPassed"], reason=t.get("reason", ""), dk=t["dk"])
       for g in groups(ed, parameterSet="ML-KEM-768", function="decapsulationKeyCheck") for t in g["tests"]])
write("mlkem768_ekcheck.txt", "ML-KEM-encapDecap-FIPS203 internalProjection, ML-KEM-768 encapsulationKeyCheck (VAL)",
      [dict(tgId=g["tgId"], tcId=t["tcId"], passed=t["testPassed"], reason=t.get("reason", ""), ek=t["ek"])
       for g in groups(ed, parameterSet="ML-KEM-768", function="encapsulationKeyCheck") for t in g["tests"]])

dk = load("ML-DSA-keyGen-FIPS204")
write("mldsa65_keygen.txt", "ML-DSA-keyGen-FIPS204 internalProjection, ML-DSA-65 (AFT)",
      [dict(tgId=g["tgId"], tcId=t["tcId"], seed=t["seed"], pk=t["pk"], sk=t["sk"])
       for g in groups(dk, parameterSet="ML-DSA-65") for t in g["tests"]])

# preHash (HashML-DSA) and externalMu groups are not implemented by ml_dsa.zig and are
# deliberately left out; docs/CRYPTO-CONFORMANCE.md lists them as N/A.
sg = load("ML-DSA-sigGen-FIPS204")
recs = []
for g in sg["testGroups"]:
    if g["parameterSet"] != "ML-DSA-65" or g["externalMu"] or g["preHash"] == "preHash":
        continue
    for t in g["tests"]:
        r = dict(tgId=g["tgId"], tcId=t["tcId"], interface=g["signatureInterface"],
                 deterministic=g["deterministic"], sk=t["sk"], message=t["message"])
        if g["signatureInterface"] == "external":
            r["context"] = t["context"]
        r["rnd"] = t.get("rnd", "00" * 32)
        r["signature"] = t["signature"]
        recs.append(r)
write("mldsa65_siggen.txt", "ML-DSA-sigGen-FIPS204 internalProjection, ML-DSA-65, pure external + internal, deterministic + hedged", recs)

sv = load("ML-DSA-sigVer-FIPS204")
recs = []
for g in sv["testGroups"]:
    if g["parameterSet"] != "ML-DSA-65" or g["externalMu"] or g["preHash"] == "preHash":
        continue
    for t in g["tests"]:
        r = dict(tgId=g["tgId"], tcId=t["tcId"], interface=g["signatureInterface"],
                 passed=t["testPassed"], reason=t.get("reason", ""), pk=t["pk"], message=t["message"])
        if g["signatureInterface"] == "external":
            r["context"] = t["context"]
        r["signature"] = t["signature"]
        recs.append(r)
write("mldsa65_sigver.txt", "ML-DSA-sigVer-FIPS204 internalProjection, ML-DSA-65, pure external + internal", recs)
