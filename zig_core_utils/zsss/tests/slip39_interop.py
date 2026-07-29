#!/usr/bin/env python3
"""Cross-implementation round-trip: zsss (Zig) <-> python-shamir-mnemonic.

Direction A: zsss generates shares -> Python recovers the master secret.
Direction B: Python generates shares -> zsss recovers the master secret.

Both directions, with and without a passphrase, single-group and multi-group.
"""
import glob
import itertools
import os
import shutil
import subprocess
import sys
import tempfile

import shamir_mnemonic
from shamir_mnemonic import combine_mnemonics, generate_mnemonics

ZSSS = sys.argv[1] if len(sys.argv) > 1 else "./zig-out/bin/zsss"

CONFIGS = [
    # (label, cli_args_extra, groups_for_python, group_threshold, secret_len)
    ("1of1 single group", ["-t", "1", "-n", "1"], [(1, 1)], 1, 16),
    ("3of5 single group", ["-t", "3", "-n", "5"], [(3, 5)], 1, 16),
    ("2of3 single group, 256-bit", ["-t", "2", "-n", "3"], [(2, 3)], 1, 32),
    (
        "2 of 3 groups (1of1, 3of5, 2of3)",
        ["--groups", "1of1,3of5,2of3", "--group-threshold", "2"],
        [(1, 1), (3, 5), (2, 3)],
        2,
        16,
    ),
    (
        "3 of 4 groups, 256-bit",
        ["--groups", "2of3,2of3,1of1,4of6", "--group-threshold", "3"],
        [(2, 3), (2, 3), (1, 1), (4, 6)],
        3,
        32,
    ),
]

PASSPHRASES = ["", "TREZOR", "a longer pass phrase with spaces & symbols !#"]

results = []


def record(ok, label):
    results.append((ok, label))
    print(("  PASS  " if ok else "  FAIL  ") + label, flush=True)


_split_seq = itertools.count()


def zsss_split(workdir, secret, extra, passphrase, extendable=True):
    secret_path = os.path.join(workdir, "secret.bin")
    with open(secret_path, "wb") as f:
        f.write(secret)
    # A fresh directory per split: globbing a shared one would pick up shares
    # from an earlier configuration.
    out = os.path.join(workdir, f"shares-{next(_split_seq)}")
    cmd = [ZSSS, "split", "--slip39", "-i", secret_path, "-o", out] + extra
    if passphrase:
        cmd += ["--passphrase", passphrase]
    if not extendable:
        cmd += ["--no-extendable"]
    proc = subprocess.run(cmd, capture_output=True, text=True)
    if proc.returncode != 0:
        raise RuntimeError(f"zsss split failed: {proc.stdout}{proc.stderr}")
    files = sorted(glob.glob(os.path.join(out, "*.slip39")))
    mnemonics = {}
    for path in files:
        with open(path) as f:
            mnemonics[os.path.basename(path)] = f.read().strip()
    return mnemonics


def zsss_combine(workdir, mnemonic_list, passphrase):
    share_paths = []
    for i, m in enumerate(mnemonic_list):
        p = os.path.join(workdir, f"in-{i}.slip39")
        with open(p, "w") as f:
            f.write(m)
        share_paths.append(p)
    out = os.path.join(workdir, "recovered.bin")
    if os.path.exists(out):
        os.remove(out)
    cmd = [ZSSS, "combine", "--slip39", "-o", out]
    for p in share_paths:
        cmd += ["-s", p]
    if passphrase:
        cmd += ["--passphrase", passphrase]
    proc = subprocess.run(cmd, capture_output=True, text=True)
    if proc.returncode != 0:
        raise RuntimeError(f"zsss combine failed: {proc.stdout}{proc.stderr}")
    with open(out, "rb") as f:
        return f.read()


def pick_recovery_subset(groups, group_threshold, by_group):
    """Choose exactly group_threshold groups, member_threshold shares each."""
    chosen = []
    for gi in range(group_threshold):
        member_threshold = groups[gi][0]
        chosen.extend(by_group[gi][:member_threshold])
    return chosen


def main():
    print(f"zsss binary:        {ZSSS}")
    print(f"reference impl:     python-shamir-mnemonic {shamir_mnemonic.__version__ if hasattr(shamir_mnemonic, '__version__') else '0.3.0'}")
    print()

    workdir = tempfile.mkdtemp(prefix="slip39-interop-")
    try:
        for label, extra, groups, gt, secret_len in CONFIGS:
            for passphrase in PASSPHRASES:
                pp_label = f'passphrase={passphrase!r}'
                secret = bytes(range(1, secret_len + 1))

                # ---------- Direction A: zsss generates, Python recovers ----------
                try:
                    mnemonics = zsss_split(workdir, secret, extra, passphrase)
                    # zsss names files share-N (single group) or share-gG-M.
                    by_group = {}
                    for name, m in sorted(mnemonics.items()):
                        share = shamir_mnemonic.share.Share.from_mnemonic(m)
                        by_group.setdefault(share.group_index, []).append(m)
                    subset = pick_recovery_subset(groups, gt, by_group)
                    recovered = combine_mnemonics(subset, passphrase.encode())
                    ok = recovered == secret
                    record(ok, f"A zsss->python  {label:38s} {pp_label}")
                    if not ok:
                        print(f"        want {secret.hex()}\n        got  {recovered.hex()}")
                except Exception as e:
                    record(False, f"A zsss->python  {label:38s} {pp_label}: {e}")

                # ---------- Direction B: Python generates, zsss recovers ----------
                try:
                    py_groups = generate_mnemonics(
                        gt, groups, secret, passphrase.encode(), extendable=True
                    )
                    subset = []
                    for gi in range(gt):
                        subset.extend(py_groups[gi][: groups[gi][0]])
                    recovered = zsss_combine(workdir, subset, passphrase)
                    ok = recovered == secret
                    record(ok, f"B python->zsss  {label:38s} {pp_label}")
                    if not ok:
                        print(f"        want {secret.hex()}\n        got  {recovered.hex()}")
                except Exception as e:
                    record(False, f"B python->zsss  {label:38s} {pp_label}: {e}")

        # ---------- ext = 0 (non-extendable) both directions ----------
        secret = bytes(range(1, 17))
        for passphrase in ["", "TREZOR"]:
            pp_label = f"passphrase={passphrase!r}"
            try:
                mnemonics = zsss_split(
                    workdir, secret, ["-t", "2", "-n", "3"], passphrase, extendable=False
                )
                subset = sorted(mnemonics.values())[:2]
                assert not shamir_mnemonic.share.Share.from_mnemonic(
                    subset[0]
                ).extendable, "expected ext=0"
                recovered = combine_mnemonics(subset, passphrase.encode())
                record(recovered == secret, f"A zsss->python  ext=0 2of3 {'':28s} {pp_label}")
            except Exception as e:
                record(False, f"A zsss->python  ext=0 2of3 {'':28s} {pp_label}: {e}")

            try:
                py_groups = generate_mnemonics(
                    1, [(2, 3)], secret, passphrase.encode(), extendable=False
                )
                recovered = zsss_combine(workdir, py_groups[0][:2], passphrase)
                record(recovered == secret, f"B python->zsss  ext=0 2of3 {'':28s} {pp_label}")
            except Exception as e:
                record(False, f"B python->zsss  ext=0 2of3 {'':28s} {pp_label}: {e}")

        # ---------- non-default iteration exponent ----------
        try:
            py_groups = generate_mnemonics(
                1, [(2, 3)], secret, b"TREZOR", extendable=True, iteration_exponent=3
            )
            recovered = zsss_combine(workdir, py_groups[0][:2], "TREZOR")
            record(recovered == secret, "B python->zsss  iteration_exponent=3 2of3")
        except Exception as e:
            record(False, f"B python->zsss  iteration_exponent=3 2of3: {e}")

        # ---------- every subset of a 3-of-5 must recover, both ways ----------
        try:
            mnemonics = sorted(
                zsss_split(workdir, secret, ["-t", "3", "-n", "5"], "TREZOR").values()
            )
            bad = 0
            for combo in itertools.combinations(mnemonics, 3):
                if combine_mnemonics(list(combo), b"TREZOR") != secret:
                    bad += 1
            record(bad == 0, f"A zsss->python  all 10 3-of-5 subsets recover ({bad} bad)")
        except Exception as e:
            record(False, f"A zsss->python  all 3-of-5 subsets: {e}")

        try:
            py_group = generate_mnemonics(1, [(3, 5)], secret, b"TREZOR")[0]
            bad = 0
            for combo in itertools.combinations(py_group, 3):
                if zsss_combine(workdir, list(combo), "TREZOR") != secret:
                    bad += 1
            record(bad == 0, f"B python->zsss  all 10 3-of-5 subsets recover ({bad} bad)")
        except Exception as e:
            record(False, f"B python->zsss  all 3-of-5 subsets: {e}")

        # ---------- zsss must REJECT what Python rejects ----------
        try:
            py_group = generate_mnemonics(1, [(3, 5)], secret, b"TREZOR")[0]
            rejected = 0
            checks = 0
            # Too few shares.
            for subset in [py_group[:2], py_group[:1]]:
                checks += 1
                try:
                    zsss_combine(workdir, subset, "TREZOR")
                except RuntimeError:
                    rejected += 1
            # Corrupted checksum word.
            words = py_group[0].split()
            words[-1] = "zero" if words[-1] != "zero" else "academic"
            checks += 1
            try:
                zsss_combine(workdir, [" ".join(words)] + py_group[1:3], "TREZOR")
            except RuntimeError:
                rejected += 1
            # Shares from two independent splits of the same secret.
            other = generate_mnemonics(1, [(3, 5)], secret, b"TREZOR")[0]
            checks += 1
            try:
                zsss_combine(workdir, [py_group[0], py_group[1], other[2]], "TREZOR")
            except RuntimeError:
                rejected += 1
            record(rejected == checks, f"zsss rejects invalid sets ({rejected}/{checks})")
        except Exception as e:
            record(False, f"zsss rejects invalid sets: {e}")

    finally:
        shutil.rmtree(workdir, ignore_errors=True)

    print()
    passed = sum(1 for ok, _ in results if ok)
    print(f"{passed}/{len(results)} interop checks passed")
    return 0 if passed == len(results) else 1


if __name__ == "__main__":
    sys.exit(main())
